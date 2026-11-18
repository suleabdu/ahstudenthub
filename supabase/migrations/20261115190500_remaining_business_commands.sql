-- Cashbook Supabase migration 5: remaining daily business commands.
--
-- These commands retain the Apps Script entry vocabulary while posting every
-- money, stock and party effect as an immutable, balanced database transaction.
-- A browser retry with the same clientId is idempotent: it returns the first
-- successful result and never posts a second financial document.

alter table public.documents
  add column if not exists metadata jsonb not null default '{}'::jsonb;

create index if not exists documents_org_workflow_idx
  on public.documents (organization_id, ((metadata ->> 'workflow')), occurred_on desc);

-- A return consumes the exact original FIFO allocation even where returned
-- goods cannot be re-sold. This prevents two partial returns from restoring the
-- same historic lot twice and leaves a trace from the return to the sale line.
create table public.return_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  return_line_id uuid not null references public.document_lines(id) on delete restrict,
  source_sale_line_id uuid not null references public.document_lines(id) on delete restrict,
  lot_id uuid not null references public.inventory_lots(id) on delete restrict,
  quantity numeric(18, 4) not null check (quantity > 0),
  unit_cost numeric(18, 2) not null check (unit_cost >= 0),
  restocked boolean not null default true,
  created_at timestamptz not null default now(),
  unique (return_line_id, lot_id)
);
create index return_allocations_source_idx
  on public.return_allocations (organization_id, source_sale_line_id, lot_id);
alter table public.return_allocations enable row level security;
revoke all on public.return_allocations from anon, authenticated;
create trigger return_allocations_immutable before update or delete on public.return_allocations
for each row execute function private.reject_immutable_mutation();

-- Start or recover an idempotent browser command. The caller validates the
-- client reference first so malformed input never creates a command row.
create or replace function private.begin_cashbook_command(
  p_organization_id uuid,
  p_client_id text,
  p_action text,
  p_request jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_command public.sync_commands%rowtype;
  v_id uuid;
begin
  select * into v_command
    from public.sync_commands c
   where c.organization_id = p_organization_id
     and c.client_id = btrim(p_client_id)
   for update;

  if found and v_command.status = 'SUCCEEDED'::public.command_status then
    return jsonb_build_object(
      'duplicate', true,
      'response', jsonb_set(coalesce(v_command.response, '{}'::jsonb), '{status}', '"DUPLICATE"'::jsonb, true)
    );
  elsif found then
    update public.sync_commands
       set status = 'PROCESSING'::public.command_status,
           actor_id = auth.uid(),
           action = p_action,
           request = coalesce(p_request, '{}'::jsonb),
           response = null,
           error_code = null,
           error_message = null,
           completed_at = null
     where id = v_command.id
     returning id into v_id;
  else
    insert into public.sync_commands (organization_id, client_id, actor_id, action, request)
    values (p_organization_id, btrim(p_client_id), auth.uid(), p_action, coalesce(p_request, '{}'::jsonb))
    returning id into v_id;
  end if;

  return jsonb_build_object('duplicate', false, 'commandId', v_id::text);
end;
$$;

create or replace function private.complete_cashbook_command(
  p_command_id uuid,
  p_document_id uuid,
  p_response jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.sync_commands
     set status = 'SUCCEEDED'::public.command_status,
         response = p_response,
         document_id = p_document_id,
         completed_at = now()
   where id = p_command_id;
end;
$$;

-- Dates are business-timezone based and cannot be back-posted into a closed
-- period. Each transactional function catches this user error and preserves
-- the failed command in the durable Sync Centre.
create or replace function private.cashbook_posting_date(
  p_organization_id uuid,
  p_text text,
  p_label text default 'date'
)
returns date
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_timezone text;
  v_closed_until date;
  v_today date;
  v_date date;
begin
  select o.timezone, s.closed_until
    into v_timezone, v_closed_until
    from public.organizations o
    join public.organization_settings s on s.organization_id = o.id
   where o.id = p_organization_id;
  if v_timezone is null then
    raise exception 'Cashbook organization was not found.' using errcode = 'P0001';
  end if;
  v_today := (now() at time zone v_timezone)::date;
  begin
    v_date := coalesce(nullif(btrim(coalesce(p_text, '')), '')::date, v_today);
  exception when others then
    raise exception 'Enter a valid %.', p_label using errcode = 'P0001';
  end;
  if v_date > v_today then
    raise exception 'A % cannot be dated in the future.', p_label using errcode = 'P0001';
  end if;
  if v_closed_until is not null and v_date <= v_closed_until then
    raise exception 'This accounting period is closed.' using errcode = 'P0001';
  end if;
  return v_date;
end;
$$;

-- Receive a supplier purchase / STOCK_IN. Opening stock intentionally remains
-- on its separate `post_opening_stock` path so it never invents a supplier or
-- a cash movement.
create or replace function public.post_purchase(
  p_organization_id uuid,
  p_client_id text,
  p_purchase jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_membership public.memberships%rowtype;
  v_started jsonb;
  v_command_id uuid;
  v_date date;
  v_location_id uuid;
  v_type text;
  v_items jsonb := coalesce(p_purchase->'items', '[]'::jsonb);
  v_item jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_seen jsonb := '{}'::jsonb;
  v_product public.products%rowtype;
  v_sku text;
  v_qty numeric(18,4);
  v_cost numeric(18,2);
  v_total numeric(18,2) := 0;
  v_paid numeric(18,2);
  v_balance numeric(18,2);
  v_method text;
  v_notes text;
  v_party_id uuid;
  v_party_text text;
  v_party public.parties%rowtype;
  v_new_party_name text;
  v_new_party_phone text;
  v_document_id uuid;
  v_line_id uuid;
  v_lot_id uuid;
  v_line_no integer := 0;
  v_doc_no text;
  v_flags jsonb := '[]'::jsonb;
  v_response jsonb;
  v_line jsonb;
begin
  if nullif(btrim(coalesce(p_client_id, '')), '') is null or char_length(btrim(p_client_id)) > 200 then
    return jsonb_build_object('clientId', coalesce(p_client_id, ''), 'status', 'ERROR', 'message', 'This saved purchase needs a valid client reference.');
  end if;
  v_membership := private.require_membership(p_organization_id);
  if v_membership.role = 'REP'::public.cashbook_role and not (coalesce(v_membership.permissions, '[]'::jsonb) ? 'STOCK_IN') then
    return jsonb_build_object('clientId', p_client_id, 'status', 'ERROR', 'message', 'You are not permitted to receive stock.');
  end if;
  v_started := private.begin_cashbook_command(p_organization_id, p_client_id, 'PURCHASE', p_purchase);
  if coalesce((v_started->>'duplicate')::boolean, false) then return v_started->'response'; end if;
  v_command_id := (v_started->>'commandId')::uuid;

  begin
    v_type := upper(coalesce(nullif(btrim(p_purchase->>'type'), ''), 'STOCK_IN'));
    if v_type not in ('STOCK_IN', 'PURCHASE') then
      raise exception 'This command is not a stock purchase.' using errcode = 'P0001';
    end if;
    if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 or jsonb_array_length(v_items) > 500 then
      raise exception 'Add between 1 and 500 purchase lines.' using errcode = 'P0001';
    end if;
    v_date := private.cashbook_posting_date(p_organization_id, p_purchase->>'date', 'purchase date');
    v_location_id := private.resolve_posting_location(p_organization_id, v_membership,
      coalesce(p_purchase->>'locationId', p_purchase->>'location'));
    perform pg_advisory_xact_lock(hashtextextended(p_organization_id::text || ':' || v_location_id::text, 0));

    for v_item in select value from jsonb_array_elements(v_items)
    loop
      v_sku := upper(btrim(coalesce(v_item->>'sku', '')));
      v_qty := private.try_numeric(coalesce(v_item->>'qty', v_item->>'quantity'));
      v_cost := private.try_numeric(coalesce(v_item->>'unitCost', v_item->>'cost'));
      if v_sku = '' or v_qty is null or v_qty <= 0 or abs(v_qty - round(v_qty, 4)) > 0.00000001
         or v_cost is null or v_cost <= 0 then
        raise exception 'Each purchase line needs an active stock item, a positive quantity, and a unit cost above zero.' using errcode = 'P0001';
      end if;
      if v_seen ? v_sku then
        raise exception 'Product % appears more than once. Combine its quantities first.', v_sku using errcode = 'P0001';
      end if;
      v_seen := v_seen || jsonb_build_object(v_sku, true);
      select * into v_product
        from public.products p
       where p.organization_id = p_organization_id and p.sku = v_sku and p.active
       for share;
      if not found or v_product.kind <> 'ITEM'::public.product_kind then
        raise exception 'Product % is not an active stock item.', v_sku using errcode = 'P0001';
      end if;
      v_qty := round(v_qty, 4);
      v_cost := round(v_cost, 2);
      v_total := v_total + round(v_qty * v_cost, 2);
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'productId', v_product.id::text, 'sku', v_product.sku::text, 'name', v_product.name,
        'qty', v_qty, 'unitCost', v_cost, 'lineTotal', round(v_qty * v_cost, 2)
      ));
    end loop;
    v_total := round(v_total, 2);
    v_paid := private.try_numeric(p_purchase->>'amountPaid');
    if v_paid is null then v_paid := v_total; end if;
    if v_paid < 0 or v_paid > v_total then
      raise exception 'Amount paid must be between zero and the purchase total. Change due is not an overpayment.' using errcode = 'P0001';
    end if;
    v_paid := round(v_paid, 2);
    v_balance := v_total - v_paid;
    v_method := coalesce(nullif(btrim(p_purchase->>'method'), ''), 'Cash');
    v_notes := nullif(btrim(coalesce(p_purchase->>'notes', '')), '');

    v_party_text := nullif(btrim(coalesce(p_purchase->>'partyId', '')), '');
    if v_party_text is not null then
      begin v_party_id := v_party_text::uuid;
      exception when others then raise exception 'Choose a valid supplier.' using errcode = 'P0001'; end;
      select * into v_party from public.parties p
       where p.id = v_party_id and p.organization_id = p_organization_id
         and p.kind = 'SUPPLIER'::public.party_kind and p.active
       for update;
      if not found then raise exception 'Choose an active supplier.' using errcode = 'P0001'; end if;
    elsif jsonb_typeof(p_purchase->'newParty') = 'object' then
      v_new_party_name := nullif(btrim(coalesce(p_purchase->'newParty'->>'name', '')), '');
      v_new_party_phone := nullif(btrim(coalesce(p_purchase->'newParty'->>'phone', '')), '');
      if v_new_party_name is null then raise exception 'Enter the new supplier name.' using errcode = 'P0001'; end if;
    end if;
    if v_balance > 0 and v_party_id is null and v_new_party_name is null then
      raise exception 'A cash purchase must be paid in full. Choose or add a supplier before recording part payment.' using errcode = 'P0001';
    end if;

    if v_party_id is null and v_new_party_name is not null then
      select * into v_party from public.parties p
       where p.organization_id = p_organization_id and p.kind = 'SUPPLIER'::public.party_kind
         and lower(p.name) = lower(v_new_party_name)
       limit 1 for update;
      if not found then
        insert into public.parties (organization_id, kind, name, phone, created_by)
        values (p_organization_id, 'SUPPLIER'::public.party_kind, v_new_party_name, v_new_party_phone, auth.uid())
        returning * into v_party;
      end if;
      v_party_id := v_party.id;
    end if;

    if v_membership.role = 'REP'::public.cashbook_role then
      v_flags := jsonb_build_array('REP_STOCK_IN');
    end if;
    v_doc_no := coalesce(nullif(btrim(p_purchase->>'docNo'), ''),
      'PUR-' || to_char(v_date, 'YYYYMMDD') || '-' || upper(substr(md5(p_client_id), 1, 8)));
    if char_length(v_doc_no) > 120 then raise exception 'Purchase number is too long.' using errcode = 'P0001'; end if;

    insert into public.documents (
      organization_id, location_id, kind, document_number, occurred_on, party_id, source_client_id,
      subtotal, total, amount_paid, balance_due, payment_method, notes, metadata, created_by
    ) values (
      p_organization_id, v_location_id, 'PURCHASE'::public.document_kind, v_doc_no, v_date, v_party_id, btrim(p_client_id),
      v_total, v_total, v_paid, v_balance, v_method, v_notes,
      jsonb_build_object('workflow', 'PURCHASE', 'flags', v_flags), auth.uid()
    ) returning id into v_document_id;

    for v_line in select value from jsonb_array_elements(v_lines)
    loop
      v_line_no := v_line_no + 1;
      insert into public.document_lines (
        document_id, organization_id, line_number, product_id, description, quantity,
        unit_price, unit_cost, line_total, cost_of_goods, metadata
      ) values (
        v_document_id, p_organization_id, v_line_no, (v_line->>'productId')::uuid, v_line->>'name',
        (v_line->>'qty')::numeric, 0, (v_line->>'unitCost')::numeric, 0, 0,
        jsonb_build_object('sku', v_line->>'sku', 'purchaseValue', v_line->>'lineTotal')
      ) returning id into v_line_id;
      insert into public.inventory_lots (
        organization_id, location_id, product_id, source_document_id, source_line_id,
        received_on, received_quantity, quantity_remaining, unit_cost, party_id, reference, notes
      ) values (
        p_organization_id, v_location_id, (v_line->>'productId')::uuid, v_document_id, v_line_id,
        v_date, (v_line->>'qty')::numeric, (v_line->>'qty')::numeric, (v_line->>'unitCost')::numeric,
        v_party_id, v_doc_no, v_notes
      ) returning id into v_lot_id;
      insert into public.inventory_movements (
        organization_id, location_id, product_id, lot_id, document_id, document_line_id,
        kind, occurred_on, quantity_delta, unit_cost, notes, created_by
      ) values (
        p_organization_id, v_location_id, (v_line->>'productId')::uuid, v_lot_id, v_document_id, v_line_id,
        'PURCHASE'::public.inventory_movement_kind, v_date, (v_line->>'qty')::numeric,
        (v_line->>'unitCost')::numeric, v_notes, auth.uid()
      );
    end loop;

    if v_paid > 0 then
      insert into public.payments (organization_id, document_id, party_id, payment_method, amount, paid_on, reference, notes, created_by)
      values (p_organization_id, v_document_id, v_party_id, v_method, v_paid, v_date, 'AT_PURCHASE', v_notes, auth.uid());
    end if;
    insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, party_id, memo, created_by)
    values (p_organization_id, v_document_id, v_date, 'INVENTORY', v_total, 0, v_party_id, 'Purchase ' || v_doc_no, auth.uid());
    if v_paid > 0 then
      insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, party_id, memo, created_by)
      values (p_organization_id, v_document_id, v_date, 'CASH', 0, v_paid, v_party_id, 'Purchase payment ' || v_doc_no, auth.uid());
    end if;
    if v_balance > 0 then
      insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, party_id, memo, created_by)
      values (p_organization_id, v_document_id, v_date, 'ACCOUNTS_PAYABLE', 0, v_balance, v_party_id, 'Supplier balance ' || v_doc_no, auth.uid());
    end if;
  exception
    when sqlstate 'P0001' then return private.finish_failed_command(v_command_id, p_client_id, sqlerrm, 'USER');
    when unique_violation then return private.finish_failed_command(v_command_id, p_client_id, 'Purchase number is already in use. Refresh and retry.', 'USER');
    when others then return private.finish_failed_command(v_command_id, p_client_id, 'The purchase could not be saved. It was not recorded; retry or review the action.', 'SERVER');
  end;

  v_response := jsonb_build_object('clientId', p_client_id, 'status', 'OK', 'docNo', v_doc_no, 'flags', v_flags, 'total', v_total, 'paid', v_paid);
  perform private.complete_cashbook_command(v_command_id, v_document_id, v_response);
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, client_id, detail)
  values (p_organization_id, auth.uid(), 'PURCHASE_POSTED', 'document', v_document_id, p_client_id,
    jsonb_build_object('documentNumber', v_doc_no, 'total', v_total, 'amountPaid', v_paid, 'locationId', v_location_id::text));
  return v_response;
end;
$$;

-- Record a daily operating expense. Expenses are cash movements and never
-- change stock quantity or supplier/customer balances.
create or replace function public.post_expense(
  p_organization_id uuid,
  p_client_id text,
  p_expense jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_membership public.memberships%rowtype;
  v_started jsonb;
  v_command_id uuid;
  v_date date;
  v_location_id uuid;
  v_amount numeric(18,2);
  v_category text;
  v_method text;
  v_notes text;
  v_doc_no text;
  v_document_id uuid;
  v_line_id uuid;
  v_response jsonb;
begin
  if nullif(btrim(coalesce(p_client_id, '')), '') is null or char_length(btrim(p_client_id)) > 200 then
    return jsonb_build_object('clientId', coalesce(p_client_id, ''), 'status', 'ERROR', 'message', 'This saved expense needs a valid client reference.');
  end if;
  v_membership := private.require_membership(p_organization_id);
  v_started := private.begin_cashbook_command(p_organization_id, p_client_id, 'EXPENSE', p_expense);
  if coalesce((v_started->>'duplicate')::boolean, false) then return v_started->'response'; end if;
  v_command_id := (v_started->>'commandId')::uuid;
  begin
    if upper(coalesce(nullif(btrim(p_expense->>'type'), ''), 'EXPENSE')) <> 'EXPENSE' then
      raise exception 'This command is not an expense.' using errcode = 'P0001';
    end if;
    v_amount := private.try_numeric(p_expense->>'amount');
    if v_amount is null or v_amount <= 0 then raise exception 'Enter a valid expense amount.' using errcode = 'P0001'; end if;
    v_amount := round(v_amount, 2);
    v_category := nullif(btrim(coalesce(p_expense->>'category', '')), '');
    if v_category is null or char_length(v_category) > 120 then raise exception 'Choose a valid expense category.' using errcode = 'P0001'; end if;
    v_date := private.cashbook_posting_date(p_organization_id, p_expense->>'date', 'expense date');
    v_location_id := private.resolve_posting_location(p_organization_id, v_membership,
      coalesce(p_expense->>'locationId', p_expense->>'location'));
    v_method := coalesce(nullif(btrim(p_expense->>'method'), ''), 'Cash');
    v_notes := nullif(btrim(coalesce(p_expense->>'notes', '')), '');
    v_doc_no := coalesce(nullif(btrim(p_expense->>'docNo'), ''),
      'EXP-' || to_char(v_date, 'YYYYMMDD') || '-' || upper(substr(md5(p_client_id), 1, 8)));
    if char_length(v_doc_no) > 120 then raise exception 'Expense number is too long.' using errcode = 'P0001'; end if;

    insert into public.documents (
      organization_id, location_id, kind, document_number, occurred_on, source_client_id,
      subtotal, total, amount_paid, balance_due, payment_method, notes, metadata, created_by
    ) values (
      p_organization_id, v_location_id, 'EXPENSE'::public.document_kind, v_doc_no, v_date, btrim(p_client_id),
      v_amount, v_amount, v_amount, 0, v_method, v_notes,
      jsonb_build_object('workflow', 'EXPENSE', 'category', v_category), auth.uid()
    ) returning id into v_document_id;
    insert into public.document_lines (
      document_id, organization_id, line_number, description, quantity, unit_price, unit_cost, line_total, cost_of_goods, metadata
    ) values (
      v_document_id, p_organization_id, 1, v_category, 1, v_amount, 0, v_amount, 0,
      jsonb_build_object('category', v_category)
    ) returning id into v_line_id;
    insert into public.payments (organization_id, document_id, payment_method, amount, paid_on, reference, notes, created_by)
    values (p_organization_id, v_document_id, v_method, v_amount, v_date, 'EXPENSE', v_notes, auth.uid());
    insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, memo, created_by)
    values (p_organization_id, v_document_id, v_date, 'EXPENSE', v_amount, 0, v_category || ' · ' || v_doc_no, auth.uid()),
           (p_organization_id, v_document_id, v_date, 'CASH', 0, v_amount, 'Expense payment ' || v_doc_no, auth.uid());
  exception
    when sqlstate 'P0001' then return private.finish_failed_command(v_command_id, p_client_id, sqlerrm, 'USER');
    when unique_violation then return private.finish_failed_command(v_command_id, p_client_id, 'Expense number is already in use. Refresh and retry.', 'USER');
    when others then return private.finish_failed_command(v_command_id, p_client_id, 'The expense could not be saved. It was not recorded; retry or review the action.', 'SERVER');
  end;
  v_response := jsonb_build_object('clientId', p_client_id, 'status', 'OK', 'docNo', v_doc_no, 'flags', '[]'::jsonb, 'total', v_amount, 'paid', v_amount);
  perform private.complete_cashbook_command(v_command_id, v_document_id, v_response);
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, client_id, detail)
  values (p_organization_id, auth.uid(), 'EXPENSE_POSTED', 'document', v_document_id, p_client_id,
    jsonb_build_object('documentNumber', v_doc_no, 'amount', v_amount, 'category', v_category, 'locationId', v_location_id::text));
  return v_response;
end;
$$;

-- Owner capital movements are deliberately kept out of revenue and expenses.
create or replace function public.post_owner_money(
  p_organization_id uuid,
  p_client_id text,
  p_money jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner public.memberships%rowtype;
  v_started jsonb;
  v_command_id uuid;
  v_type text;
  v_date date;
  v_location_id uuid;
  v_amount numeric(18,2);
  v_method text;
  v_notes text;
  v_doc_no text;
  v_document_id uuid;
  v_kind public.document_kind;
  v_response jsonb;
begin
  if nullif(btrim(coalesce(p_client_id, '')), '') is null or char_length(btrim(p_client_id)) > 200 then
    return jsonb_build_object('clientId', coalesce(p_client_id, ''), 'status', 'ERROR', 'message', 'This owner-money record needs a valid client reference.');
  end if;
  v_owner := private.require_owner(p_organization_id);
  v_started := private.begin_cashbook_command(p_organization_id, p_client_id, 'OWNER_MONEY', p_money);
  if coalesce((v_started->>'duplicate')::boolean, false) then return v_started->'response'; end if;
  v_command_id := (v_started->>'commandId')::uuid;
  begin
    v_type := upper(btrim(coalesce(p_money->>'type', '')));
    if v_type not in ('OWNER_CONTRIBUTION', 'OWNER_WITHDRAWAL') then
      raise exception 'Choose an owner contribution or withdrawal.' using errcode = 'P0001';
    end if;
    v_amount := private.try_numeric(p_money->>'amount');
    if v_amount is null or v_amount <= 0 then raise exception 'Enter a valid owner-money amount.' using errcode = 'P0001'; end if;
    v_amount := round(v_amount, 2);
    v_date := private.cashbook_posting_date(p_organization_id, p_money->>'date', 'owner-money date');
    v_location_id := private.resolve_posting_location(p_organization_id, v_owner,
      coalesce(p_money->>'locationId', p_money->>'location'));
    v_method := coalesce(nullif(btrim(p_money->>'method'), ''), 'Cash');
    v_notes := nullif(btrim(coalesce(p_money->>'notes', '')), '');
    v_kind := case when v_type = 'OWNER_CONTRIBUTION' then 'OWNER_CONTRIBUTION'::public.document_kind else 'OWNER_WITHDRAWAL'::public.document_kind end;
    v_doc_no := coalesce(nullif(btrim(p_money->>'docNo'), ''),
      case when v_type = 'OWNER_CONTRIBUTION' then 'CON-' else 'DRW-' end || to_char(v_date, 'YYYYMMDD') || '-' || upper(substr(md5(p_client_id), 1, 8)));
    if char_length(v_doc_no) > 120 then raise exception 'Owner-money document number is too long.' using errcode = 'P0001'; end if;
    insert into public.documents (
      organization_id, location_id, kind, document_number, occurred_on, source_client_id,
      subtotal, total, amount_paid, balance_due, payment_method, notes, metadata, created_by
    ) values (
      p_organization_id, v_location_id, v_kind, v_doc_no, v_date, btrim(p_client_id),
      v_amount, v_amount, v_amount, 0, v_method, v_notes,
      jsonb_build_object('workflow', v_type), auth.uid()
    ) returning id into v_document_id;
    insert into public.payments (organization_id, document_id, payment_method, amount, paid_on, reference, notes, created_by)
    values (p_organization_id, v_document_id, v_method, v_amount, v_date, v_type, v_notes, auth.uid());
    if v_type = 'OWNER_CONTRIBUTION' then
      insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, memo, created_by)
      values (p_organization_id, v_document_id, v_date, 'CASH', v_amount, 0, 'Owner contribution ' || v_doc_no, auth.uid()),
             (p_organization_id, v_document_id, v_date, 'OWNER_CAPITAL', 0, v_amount, 'Owner contribution ' || v_doc_no, auth.uid());
    else
      insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, memo, created_by)
      values (p_organization_id, v_document_id, v_date, 'OWNER_DRAWINGS', v_amount, 0, 'Owner withdrawal ' || v_doc_no, auth.uid()),
             (p_organization_id, v_document_id, v_date, 'CASH', 0, v_amount, 'Owner withdrawal ' || v_doc_no, auth.uid());
    end if;
  exception
    when sqlstate 'P0001' then return private.finish_failed_command(v_command_id, p_client_id, sqlerrm, 'USER');
    when unique_violation then return private.finish_failed_command(v_command_id, p_client_id, 'Owner-money document number is already in use. Refresh and retry.', 'USER');
    when others then return private.finish_failed_command(v_command_id, p_client_id, 'The owner-money movement could not be saved. It was not recorded; retry or review the action.', 'SERVER');
  end;
  v_response := jsonb_build_object('clientId', p_client_id, 'status', 'OK', 'docNo', v_doc_no, 'flags', '[]'::jsonb, 'total', v_amount, 'paid', v_amount);
  perform private.complete_cashbook_command(v_command_id, v_document_id, v_response);
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, client_id, detail)
  values (p_organization_id, auth.uid(), v_type || '_POSTED', 'document', v_document_id, p_client_id,
    jsonb_build_object('documentNumber', v_doc_no, 'amount', v_amount, 'locationId', v_location_id::text));
  return v_response;
end;
$$;

-- Receive a customer repayment or pay a supplier. A single payment may settle
-- several oldest outstanding documents; the immutable payment rows retain the
-- allocation while document balances remain an efficient current read model.
create or replace function public.post_party_payment(
  p_organization_id uuid,
  p_client_id text,
  p_payment jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_membership public.memberships%rowtype;
  v_started jsonb;
  v_command_id uuid;
  v_type text;
  v_party_kind public.party_kind;
  v_document_kind public.document_kind;
  v_date date;
  v_location_id uuid;
  v_party_id uuid;
  v_party public.parties%rowtype;
  v_amount numeric(18,2);
  v_remaining numeric(18,2);
  v_apply numeric(18,2);
  v_method text;
  v_notes text;
  v_doc_no text;
  v_document_id uuid;
  v_target record;
  v_allocations jsonb := '[]'::jsonb;
  v_response jsonb;
begin
  if nullif(btrim(coalesce(p_client_id, '')), '') is null or char_length(btrim(p_client_id)) > 200 then
    return jsonb_build_object('clientId', coalesce(p_client_id, ''), 'status', 'ERROR', 'message', 'This payment needs a valid client reference.');
  end if;
  v_membership := private.require_membership(p_organization_id);
  v_started := private.begin_cashbook_command(p_organization_id, p_client_id, 'PARTY_PAYMENT', p_payment);
  if coalesce((v_started->>'duplicate')::boolean, false) then return v_started->'response'; end if;
  v_command_id := (v_started->>'commandId')::uuid;

  begin
    v_type := upper(btrim(coalesce(p_payment->>'type', '')));
    if v_type not in ('PAYMENT_IN', 'PAYMENT_OUT') then
      raise exception 'Choose a customer receipt or supplier payment.' using errcode = 'P0001';
    end if;
    if v_type = 'PAYMENT_OUT' and v_membership.role = 'REP'::public.cashbook_role then
      raise exception 'Sales staff cannot make supplier payments.' using errcode = 'P0001';
    end if;
    v_party_kind := case when v_type = 'PAYMENT_IN' then 'CUSTOMER'::public.party_kind else 'SUPPLIER'::public.party_kind end;
    v_document_kind := case when v_type = 'PAYMENT_IN' then 'PAYMENT_IN'::public.document_kind else 'PAYMENT_OUT'::public.document_kind end;
    begin v_party_id := nullif(btrim(coalesce(p_payment->>'partyId', '')), '')::uuid;
    exception when others then raise exception 'Choose a valid %.', lower(v_party_kind::text) using errcode = 'P0001'; end;
    if v_party_id is null then raise exception 'Choose a %.', lower(v_party_kind::text) using errcode = 'P0001'; end if;
    select * into v_party from public.parties p
     where p.id = v_party_id and p.organization_id = p_organization_id and p.kind = v_party_kind and p.active
     for update;
    if not found then raise exception 'Choose an active %.', lower(v_party_kind::text) using errcode = 'P0001'; end if;
    v_amount := private.try_numeric(p_payment->>'amount');
    if v_amount is null or v_amount <= 0 then raise exception 'Enter a valid payment amount.' using errcode = 'P0001'; end if;
    v_amount := round(v_amount, 2);
    v_date := private.cashbook_posting_date(p_organization_id, p_payment->>'date', 'payment date');
    v_location_id := private.resolve_posting_location(p_organization_id, v_membership,
      coalesce(p_payment->>'locationId', p_payment->>'location'));
    v_method := coalesce(nullif(btrim(p_payment->>'method'), ''), 'Cash');
    v_notes := nullif(btrim(coalesce(p_payment->>'notes', '')), '');
    v_doc_no := coalesce(nullif(btrim(p_payment->>'docNo'), ''),
      case when v_type = 'PAYMENT_IN' then 'RCT-' else 'PYT-' end || to_char(v_date, 'YYYYMMDD') || '-' || upper(substr(md5(p_client_id), 1, 8)));
    if char_length(v_doc_no) > 120 then raise exception 'Payment number is too long.' using errcode = 'P0001'; end if;

    v_remaining := v_amount;
    for v_target in
      select d.id, d.document_number, d.balance_due
        from public.documents d
       where d.organization_id = p_organization_id
         and d.party_id = v_party_id
         and d.status = 'POSTED'::public.document_status
         and d.balance_due > 0
         and (
           (v_type = 'PAYMENT_IN' and (d.kind = 'SALE'::public.document_kind or d.metadata->>'workflow' = 'OPENING_BALANCE'))
           or
           (v_type = 'PAYMENT_OUT' and (d.kind = 'PURCHASE'::public.document_kind or d.metadata->>'workflow' = 'OPENING_BALANCE'))
         )
       order by d.occurred_on, d.posted_at, d.id
       for update
    loop
      exit when v_remaining <= 0;
      v_apply := least(v_remaining, v_target.balance_due);
      update public.documents
         set amount_paid = amount_paid + v_apply,
             balance_due = balance_due - v_apply
       where id = v_target.id;
      insert into public.payments (organization_id, document_id, party_id, payment_method, amount, paid_on, reference, notes, created_by)
      values (p_organization_id, v_target.id, v_party_id, v_method, v_apply, v_date, v_doc_no, v_notes, auth.uid());
      v_allocations := v_allocations || jsonb_build_array(jsonb_build_object(
        'documentId', v_target.id::text, 'documentNumber', v_target.document_number, 'amount', v_apply
      ));
      v_remaining := round(v_remaining - v_apply, 2);
    end loop;
    if v_remaining > 0 then
      raise exception 'Payment is more than the outstanding % balance. Enter only the amount owed.', lower(v_party_kind::text) using errcode = 'P0001';
    end if;

    insert into public.documents (
      organization_id, location_id, kind, document_number, occurred_on, party_id, source_client_id,
      subtotal, total, amount_paid, balance_due, payment_method, notes, metadata, created_by
    ) values (
      p_organization_id, v_location_id, v_document_kind, v_doc_no, v_date, v_party_id, btrim(p_client_id),
      v_amount, v_amount, v_amount, 0, v_method, v_notes,
      jsonb_build_object('workflow', 'PARTY_PAYMENT', 'direction', v_type, 'allocations', v_allocations), auth.uid()
    ) returning id into v_document_id;
    if v_type = 'PAYMENT_IN' then
      insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, party_id, memo, created_by)
      values (p_organization_id, v_document_id, v_date, 'CASH', v_amount, 0, v_party_id, 'Customer payment ' || v_doc_no, auth.uid()),
             (p_organization_id, v_document_id, v_date, 'ACCOUNTS_RECEIVABLE', 0, v_amount, v_party_id, 'Customer payment ' || v_doc_no, auth.uid());
    else
      insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, party_id, memo, created_by)
      values (p_organization_id, v_document_id, v_date, 'ACCOUNTS_PAYABLE', v_amount, 0, v_party_id, 'Supplier payment ' || v_doc_no, auth.uid()),
             (p_organization_id, v_document_id, v_date, 'CASH', 0, v_amount, v_party_id, 'Supplier payment ' || v_doc_no, auth.uid());
    end if;
  exception
    when sqlstate 'P0001' then return private.finish_failed_command(v_command_id, p_client_id, sqlerrm, 'USER');
    when unique_violation then return private.finish_failed_command(v_command_id, p_client_id, 'Payment number is already in use. Refresh and retry.', 'USER');
    when others then return private.finish_failed_command(v_command_id, p_client_id, 'The payment could not be saved. It was not recorded; retry or review the action.', 'SERVER');
  end;
  v_response := jsonb_build_object('clientId', p_client_id, 'status', 'OK', 'docNo', v_doc_no, 'flags', '[]'::jsonb, 'total', v_amount, 'paid', v_amount);
  perform private.complete_cashbook_command(v_command_id, v_document_id, v_response);
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, client_id, detail)
  values (p_organization_id, auth.uid(), v_type || '_POSTED', 'document', v_document_id, p_client_id,
    jsonb_build_object('documentNumber', v_doc_no, 'amount', v_amount, 'partyId', v_party_id::text, 'allocations', v_allocations));
  return v_response;
end;
$$;

-- A physical stock-count correction is an explicit, reasoned event. A loss
-- consumes real FIFO lots; stock found starts a new audited lot at an explicit
-- cost, never by silently revaluing historical sales.
create or replace function public.post_stock_adjustment(
  p_organization_id uuid,
  p_client_id text,
  p_adjustment jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner public.memberships%rowtype;
  v_started jsonb;
  v_command_id uuid;
  v_date date;
  v_location_id uuid;
  v_sku text;
  v_product public.products%rowtype;
  v_delta numeric(18,4);
  v_cost numeric(18,2);
  v_reason text;
  v_reason_type text;
  v_notes text;
  v_doc_no text;
  v_document_id uuid;
  v_line_id uuid;
  v_lot_id uuid;
  v_lot record;
  v_take numeric(18,4);
  v_remaining numeric(18,4);
  v_value numeric(18,2) := 0;
  v_plan jsonb := '[]'::jsonb;
  v_part jsonb;
  v_response jsonb;
begin
  if nullif(btrim(coalesce(p_client_id, '')), '') is null or char_length(btrim(p_client_id)) > 200 then
    return jsonb_build_object('clientId', coalesce(p_client_id, ''), 'status', 'ERROR', 'message', 'This stock correction needs a valid client reference.');
  end if;
  v_owner := private.require_owner(p_organization_id);
  v_started := private.begin_cashbook_command(p_organization_id, p_client_id, 'STOCK_ADJUSTMENT', p_adjustment);
  if coalesce((v_started->>'duplicate')::boolean, false) then return v_started->'response'; end if;
  v_command_id := (v_started->>'commandId')::uuid;
  begin
    if upper(coalesce(nullif(btrim(p_adjustment->>'type'), ''), 'ADJUSTMENT')) <> 'ADJUSTMENT' then
      raise exception 'This command is not a stock correction.' using errcode = 'P0001';
    end if;
    v_sku := upper(btrim(coalesce(p_adjustment->>'sku', '')));
    v_delta := private.try_numeric(coalesce(p_adjustment->>'qty', p_adjustment->>'quantityDelta'));
    if v_sku = '' or v_delta is null or v_delta = 0 or abs(v_delta - round(v_delta, 4)) > 0.00000001 then
      raise exception 'Enter a stock item and a non-zero quantity correction with up to four decimal places.' using errcode = 'P0001';
    end if;
    v_delta := round(v_delta, 4);
    select * into v_product from public.products p
     where p.organization_id = p_organization_id and p.sku = v_sku and p.active
     for share;
    if not found or v_product.kind <> 'ITEM'::public.product_kind then raise exception 'Product % is not an active stock item.', v_sku using errcode = 'P0001'; end if;
    v_reason := nullif(btrim(coalesce(p_adjustment->>'reason', p_adjustment->>'notes', '')), '');
    if v_reason is null or char_length(v_reason) < 3 then raise exception 'Give a reason for this physical stock correction.' using errcode = 'P0001'; end if;
    v_reason_type := coalesce(nullif(btrim(p_adjustment->>'reasonType'), ''), 'Count correction');
    v_notes := v_reason;
    v_date := private.cashbook_posting_date(p_organization_id, p_adjustment->>'date', 'stock-correction date');
    v_location_id := private.resolve_posting_location(p_organization_id, v_owner,
      coalesce(p_adjustment->>'locationId', p_adjustment->>'location'));
    perform pg_advisory_xact_lock(hashtextextended(p_organization_id::text || ':' || v_location_id::text, 0));
    v_doc_no := coalesce(nullif(btrim(p_adjustment->>'docNo'), ''),
      'ADJ-' || to_char(v_date, 'YYYYMMDD') || '-' || upper(substr(md5(p_client_id), 1, 8)));
    if char_length(v_doc_no) > 120 then raise exception 'Stock-correction number is too long.' using errcode = 'P0001'; end if;

    if v_delta > 0 then
      v_cost := private.try_numeric(coalesce(p_adjustment->>'unitCost', p_adjustment->>'cost'));
      if v_cost is null or v_cost <= 0 then
        raise exception 'Stock found needs an explicit unit cost so inventory value and profit remain accurate.' using errcode = 'P0001';
      end if;
      v_cost := round(v_cost, 2);
      v_value := round(v_delta * v_cost, 2);
    else
      v_remaining := -v_delta;
      for v_lot in
        select l.id, l.quantity_remaining, l.unit_cost
          from public.inventory_lots l
         where l.organization_id = p_organization_id and l.location_id = v_location_id
           and l.product_id = v_product.id and l.status = 'OPEN' and l.quantity_remaining > 0
         order by l.received_on, l.created_at, l.id
         for update
      loop
        exit when v_remaining <= 0;
        v_take := least(v_remaining, v_lot.quantity_remaining);
        v_plan := v_plan || jsonb_build_array(jsonb_build_object('lotId', v_lot.id::text, 'qty', v_take, 'unitCost', v_lot.unit_cost));
        v_value := v_value + round(v_take * v_lot.unit_cost, 2);
        v_remaining := round(v_remaining - v_take, 4);
      end loop;
      if v_remaining > 0 then raise exception 'Cannot write off more than the stock recorded at this shop.' using errcode = 'P0001'; end if;
      v_value := round(v_value, 2);
    end if;

    insert into public.documents (
      organization_id, location_id, kind, document_number, occurred_on, source_client_id,
      subtotal, total, amount_paid, balance_due, notes, metadata, created_by
    ) values (
      p_organization_id, v_location_id, 'STOCK_ADJUSTMENT'::public.document_kind, v_doc_no, v_date, btrim(p_client_id),
      0, 0, 0, 0, v_notes,
      jsonb_build_object('workflow', 'ADJUSTMENT', 'reasonType', v_reason_type, 'reason', v_reason), auth.uid()
    ) returning id into v_document_id;

    if v_delta > 0 then
      insert into public.document_lines (
        document_id, organization_id, line_number, product_id, description, quantity, unit_price, unit_cost, line_total, cost_of_goods, metadata
      ) values (
        v_document_id, p_organization_id, 1, v_product.id, v_product.name, v_delta, 0, v_cost, 0, 0,
        jsonb_build_object('sku', v_product.sku::text, 'direction', 'IN', 'reasonType', v_reason_type)
      ) returning id into v_line_id;
      insert into public.inventory_lots (
        organization_id, location_id, product_id, source_document_id, source_line_id, received_on,
        received_quantity, quantity_remaining, unit_cost, reference, notes
      ) values (
        p_organization_id, v_location_id, v_product.id, v_document_id, v_line_id, v_date,
        v_delta, v_delta, v_cost, v_doc_no, v_notes
      ) returning id into v_lot_id;
      insert into public.inventory_movements (
        organization_id, location_id, product_id, lot_id, document_id, document_line_id,
        kind, occurred_on, quantity_delta, unit_cost, notes, created_by
      ) values (
        p_organization_id, v_location_id, v_product.id, v_lot_id, v_document_id, v_line_id,
        'ADJUSTMENT'::public.inventory_movement_kind, v_date, v_delta, v_cost, v_notes, auth.uid()
      );
      insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, product_id, memo, created_by)
      values (p_organization_id, v_document_id, v_date, 'INVENTORY', v_value, 0, v_product.id, 'Stock found ' || v_doc_no, auth.uid()),
             (p_organization_id, v_document_id, v_date, 'STOCK_ADJUSTMENT_GAIN', 0, v_value, v_product.id, 'Stock found ' || v_doc_no, auth.uid());
    else
      insert into public.document_lines (
        document_id, organization_id, line_number, product_id, description, quantity, unit_price, unit_cost, line_total, cost_of_goods, metadata
      ) values (
        v_document_id, p_organization_id, 1, v_product.id, v_product.name, -v_delta, 0,
        case when -v_delta > 0 then round(v_value / (-v_delta), 2) else 0 end, 0, v_value,
        jsonb_build_object('sku', v_product.sku::text, 'direction', 'OUT', 'reasonType', v_reason_type, 'allocations', v_plan)
      ) returning id into v_line_id;
      for v_part in select value from jsonb_array_elements(v_plan)
      loop
        update public.inventory_lots
           set quantity_remaining = quantity_remaining - (v_part->>'qty')::numeric,
               status = case when quantity_remaining - (v_part->>'qty')::numeric <= 0 then 'DEPLETED' else 'OPEN' end
         where id = (v_part->>'lotId')::uuid and quantity_remaining >= (v_part->>'qty')::numeric;
        if not found then raise exception 'Stock changed while the correction was being saved. Refresh and retry.' using errcode = 'P0001'; end if;
        insert into public.inventory_movements (
          organization_id, location_id, product_id, lot_id, document_id, document_line_id,
          kind, occurred_on, quantity_delta, unit_cost, notes, created_by
        ) values (
          p_organization_id, v_location_id, v_product.id, (v_part->>'lotId')::uuid, v_document_id, v_line_id,
          'ADJUSTMENT'::public.inventory_movement_kind, v_date, -(v_part->>'qty')::numeric,
          (v_part->>'unitCost')::numeric, v_notes, auth.uid()
        );
      end loop;
      insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, product_id, memo, created_by)
      values (p_organization_id, v_document_id, v_date, 'INVENTORY_SHRINKAGE', v_value, 0, v_product.id, v_reason_type || ' ' || v_doc_no, auth.uid()),
             (p_organization_id, v_document_id, v_date, 'INVENTORY', 0, v_value, v_product.id, 'Stock reduction ' || v_doc_no, auth.uid());
    end if;
  exception
    when sqlstate 'P0001' then return private.finish_failed_command(v_command_id, p_client_id, sqlerrm, 'USER');
    when unique_violation then return private.finish_failed_command(v_command_id, p_client_id, 'Stock-correction number is already in use. Refresh and retry.', 'USER');
    when others then return private.finish_failed_command(v_command_id, p_client_id, 'The stock correction could not be saved. It was not recorded; retry or review the action.', 'SERVER');
  end;
  v_response := jsonb_build_object('clientId', p_client_id, 'status', 'OK', 'docNo', v_doc_no, 'flags', '[]'::jsonb, 'total', 0, 'paid', 0);
  perform private.complete_cashbook_command(v_command_id, v_document_id, v_response);
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, client_id, detail)
  values (p_organization_id, auth.uid(), 'STOCK_ADJUSTMENT_POSTED', 'document', v_document_id, p_client_id,
    jsonb_build_object('documentNumber', v_doc_no, 'sku', v_product.sku::text, 'quantityDelta', v_delta, 'value', v_value, 'locationId', v_location_id::text));
  return v_response;
end;
$$;

-- Record a genuine customer return and optional refund. It is deliberately
-- separate from `reverse_cashbook_document`: the original sale remains an
-- historical event, revenue is reduced, and only resellable goods return to
-- FIFO inventory at their original historic cost.
create or replace function public.post_customer_return(
  p_organization_id uuid,
  p_client_id text,
  p_return jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner public.memberships%rowtype;
  v_started jsonb;
  v_command_id uuid;
  v_source_doc_no text;
  v_source_doc public.documents%rowtype;
  v_date date;
  v_location_id uuid;
  v_items jsonb := coalesce(p_return->'items', '[]'::jsonb);
  v_item jsonb;
  v_seen jsonb := '{}'::jsonb;
  v_product public.products%rowtype;
  v_sku text;
  v_requested numeric(18,4);
  v_needed numeric(18,4);
  v_restock boolean;
  v_source_line record;
  v_prior_returned numeric(18,4);
  v_available numeric(18,4);
  v_take numeric(18,4);
  v_piece_value numeric(18,2);
  v_piece_cost numeric(18,2);
  v_item_value numeric(18,2);
  v_item_cost numeric(18,2);
  v_item_refund numeric(18,2);
  v_return_total numeric(18,2) := 0;
  v_refund_total numeric(18,2) := 0;
  v_prior_refunds numeric(18,2);
  v_restock_value numeric(18,2) := 0;
  v_alloc_remaining numeric(18,4);
  v_alloc_available numeric(18,4);
  v_alloc_take numeric(18,4);
  v_alloc record;
  v_alloc_plan jsonb;
  v_alloc_part jsonb;
  v_document_id uuid;
  v_return_line_id uuid;
  v_line_no integer := 0;
  v_doc_no text;
  v_method text;
  v_notes text;
  v_party_text text;
  v_response jsonb;
begin
  if nullif(btrim(coalesce(p_client_id, '')), '') is null or char_length(btrim(p_client_id)) > 200 then
    return jsonb_build_object('clientId', coalesce(p_client_id, ''), 'status', 'ERROR', 'message', 'This return needs a valid client reference.');
  end if;
  v_owner := private.require_owner(p_organization_id);
  v_started := private.begin_cashbook_command(p_organization_id, p_client_id, 'RETURN', p_return);
  if coalesce((v_started->>'duplicate')::boolean, false) then return v_started->'response'; end if;
  v_command_id := (v_started->>'commandId')::uuid;

  begin
    if upper(coalesce(nullif(btrim(p_return->>'type'), ''), 'RETURN')) <> 'RETURN' then
      raise exception 'This command is not a customer return.' using errcode = 'P0001';
    end if;
    v_source_doc_no := nullif(btrim(coalesce(p_return->>'saleDocNo', p_return->>'sourceDocNo', p_return->>'originalDocNo', '')), '');
    if v_source_doc_no is null then raise exception 'Choose the original sale before recording a return.' using errcode = 'P0001'; end if;
    select * into v_source_doc from public.documents d
     where d.organization_id = p_organization_id and d.document_number = v_source_doc_no
       and d.kind = 'SALE'::public.document_kind and d.status = 'POSTED'::public.document_status
     for update;
    if not found then raise exception 'The original sale was not found or has already been cancelled.' using errcode = 'P0001'; end if;
    if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 or jsonb_array_length(v_items) > 100 then
      raise exception 'Add between 1 and 100 returned items.' using errcode = 'P0001';
    end if;
    v_date := private.cashbook_posting_date(p_organization_id, p_return->>'date', 'return date');
    v_location_id := v_source_doc.location_id;
    if v_location_id is null then raise exception 'The original sale has no shop and cannot be returned automatically.' using errcode = 'P0001'; end if;
    perform pg_advisory_xact_lock(hashtextextended(p_organization_id::text || ':' || v_location_id::text, 0));
    v_party_text := nullif(btrim(coalesce(p_return->>'partyId', '')), '');
    if v_party_text is not null and (v_source_doc.party_id is null or v_party_text <> v_source_doc.party_id::text) then
      raise exception 'The selected customer does not match the original sale.' using errcode = 'P0001';
    end if;
    v_method := coalesce(nullif(btrim(p_return->>'method'), ''), 'Cash');
    v_notes := nullif(btrim(coalesce(p_return->>'notes', '')), '');
    v_doc_no := coalesce(nullif(btrim(p_return->>'docNo'), ''),
      'RTN-' || to_char(v_date, 'YYYYMMDD') || '-' || upper(substr(md5(p_client_id), 1, 8)));
    if char_length(v_doc_no) > 120 then raise exception 'Return number is too long.' using errcode = 'P0001'; end if;

    -- Insert with zero totals first. The protected block updates it only after
    -- every line has passed availability/allocation validation; an error rolls
    -- the entire subtransaction back.
    insert into public.documents (
      organization_id, location_id, kind, document_number, occurred_on, party_id, source_client_id,
      subtotal, total, amount_paid, balance_due, payment_method, notes, metadata, created_by
    ) values (
      p_organization_id, v_location_id, 'RETURN'::public.document_kind, v_doc_no, v_date, v_source_doc.party_id, btrim(p_client_id),
      0, 0, 0, 0, v_method, v_notes,
      jsonb_build_object('workflow', 'RETURN', 'sourceDocumentId', v_source_doc.id::text, 'sourceDocumentNumber', v_source_doc.document_number), auth.uid()
    ) returning id into v_document_id;

    for v_item in select value from jsonb_array_elements(v_items)
    loop
      v_sku := upper(btrim(coalesce(v_item->>'sku', '')));
      v_requested := private.try_numeric(coalesce(v_item->>'qty', v_item->>'quantity'));
      if v_sku = '' or v_requested is null or v_requested <= 0 or abs(v_requested - round(v_requested, 4)) > 0.00000001 then
        raise exception 'Each return line needs a sold product and a positive quantity with up to four decimal places.' using errcode = 'P0001';
      end if;
      if v_seen ? v_sku then raise exception 'Product % appears more than once. Combine its return quantities first.', v_sku using errcode = 'P0001'; end if;
      v_seen := v_seen || jsonb_build_object(v_sku, true);
      select * into v_product from public.products p
       where p.organization_id = p_organization_id and p.sku = v_sku
       for share;
      if not found then raise exception 'Product % is not part of this cashbook.', v_sku using errcode = 'P0001'; end if;
      if v_item ? 'restock' then
        v_restock := lower(coalesce(v_item->>'restock', 'true')) not in ('false', '0', 'no');
      elsif p_return ? 'restock' then
        v_restock := lower(coalesce(p_return->>'restock', 'true')) not in ('false', '0', 'no');
      else
        v_restock := true;
      end if;
      if v_restock and v_product.kind <> 'ITEM'::public.product_kind then
        raise exception '% is a service and cannot be returned to sellable stock.', v_product.name using errcode = 'P0001';
      end if;

      v_needed := round(v_requested, 4);
      v_item_value := 0;
      v_item_cost := 0;
      for v_source_line in
        select l.* from public.document_lines l
         where l.document_id = v_source_doc.id and l.product_id = v_product.id
         order by l.line_number, l.id
         for update
      loop
        exit when v_needed <= 0;
        select coalesce(sum(rl.quantity), 0) into v_prior_returned
          from public.document_lines rl
          join public.documents rd on rd.id = rl.document_id
         where rd.organization_id = p_organization_id
           and rd.kind = 'RETURN'::public.document_kind
           and rd.status = 'POSTED'::public.document_status
           and rl.metadata->>'sourceSaleLineId' = v_source_line.id::text;
        v_available := round(greatest(0, v_source_line.quantity - v_prior_returned), 4);
        v_take := least(v_needed, v_available);
        if v_take <= 0 then continue; end if;
        v_piece_value := round(v_source_line.line_total * v_take / nullif(v_source_line.quantity, 0), 2);
        v_piece_cost := 0;
        v_alloc_plan := '[]'::jsonb;
        if v_product.kind = 'ITEM'::public.product_kind then
          v_alloc_remaining := v_take;
          for v_alloc in
            select la.lot_id, la.quantity, la.unit_cost,
                   coalesce((select sum(ra.quantity) from public.return_allocations ra
                              where ra.organization_id = p_organization_id
                                and ra.source_sale_line_id = v_source_line.id
                                and ra.lot_id = la.lot_id), 0) as already_returned
              from public.lot_allocations la
             where la.organization_id = p_organization_id and la.sale_line_id = v_source_line.id
             order by la.created_at, la.id
          loop
            exit when v_alloc_remaining <= 0;
            v_alloc_available := round(greatest(0, v_alloc.quantity - v_alloc.already_returned), 4);
            v_alloc_take := least(v_alloc_remaining, v_alloc_available);
            if v_alloc_take <= 0 then continue; end if;
            v_alloc_plan := v_alloc_plan || jsonb_build_array(jsonb_build_object(
              'lotId', v_alloc.lot_id::text, 'qty', v_alloc_take, 'unitCost', v_alloc.unit_cost
            ));
            v_piece_cost := v_piece_cost + round(v_alloc_take * v_alloc.unit_cost, 2);
            v_alloc_remaining := round(v_alloc_remaining - v_alloc_take, 4);
          end loop;
          if v_alloc_remaining > 0 then
            raise exception 'The original FIFO allocation for % is incomplete. Use a supervised stock correction instead.', v_product.name using errcode = 'P0001';
          end if;
        else
          v_piece_cost := round(v_source_line.cost_of_goods * v_take / nullif(v_source_line.quantity, 0), 2);
        end if;
        v_line_no := v_line_no + 1;
        insert into public.document_lines (
          document_id, organization_id, line_number, product_id, description, quantity, unit_price, unit_cost, line_total, cost_of_goods, metadata
        ) values (
          v_document_id, p_organization_id, v_line_no, v_product.id, v_product.name, v_take,
          case when v_take > 0 then round(v_piece_value / v_take, 2) else 0 end,
          case when v_take > 0 then round(v_piece_cost / v_take, 2) else 0 end,
          v_piece_value, case when v_restock then v_piece_cost else 0 end,
          jsonb_build_object(
            'sku', v_product.sku::text, 'sourceSaleLineId', v_source_line.id::text,
            'sourceDocumentId', v_source_doc.id::text, 'sourceDocumentNumber', v_source_doc.document_number,
            'restock', v_restock, 'historicCost', v_piece_cost, 'allocations', v_alloc_plan
          )
        ) returning id into v_return_line_id;
        for v_alloc_part in select value from jsonb_array_elements(v_alloc_plan)
        loop
          insert into public.return_allocations (organization_id, return_line_id, source_sale_line_id, lot_id, quantity, unit_cost, restocked)
          values (
            p_organization_id, v_return_line_id, v_source_line.id, (v_alloc_part->>'lotId')::uuid,
            (v_alloc_part->>'qty')::numeric, (v_alloc_part->>'unitCost')::numeric, v_restock
          );
          if v_restock then
            update public.inventory_lots
               set quantity_remaining = quantity_remaining + (v_alloc_part->>'qty')::numeric,
                   status = 'OPEN'
             where id = (v_alloc_part->>'lotId')::uuid;
            insert into public.inventory_movements (
              organization_id, location_id, product_id, lot_id, document_id, document_line_id,
              kind, occurred_on, quantity_delta, unit_cost, notes, created_by
            ) values (
              p_organization_id, v_location_id, v_product.id, (v_alloc_part->>'lotId')::uuid, v_document_id, v_return_line_id,
              'RETURN'::public.inventory_movement_kind, v_date, (v_alloc_part->>'qty')::numeric,
              (v_alloc_part->>'unitCost')::numeric, v_notes, auth.uid()
            );
          end if;
        end loop;
        v_item_value := v_item_value + v_piece_value;
        v_item_cost := v_item_cost + v_piece_cost;
        v_needed := round(v_needed - v_take, 4);
      end loop;
      if v_needed > 0 then
        raise exception 'Only % of % remains available to return from %.', round(v_requested - v_needed, 4), v_product.name, v_source_doc.document_number using errcode = 'P0001';
      end if;
      if v_item ? 'refundAmount' and nullif(btrim(coalesce(v_item->>'refundAmount', '')), '') is not null then
        v_item_refund := private.try_numeric(v_item->>'refundAmount');
        if v_item_refund is null or v_item_refund < 0 or v_item_refund > v_item_value then
          raise exception 'Refund for % must be between zero and %.', v_product.name, v_item_value using errcode = 'P0001';
        end if;
      else
        v_item_refund := v_item_value;
      end if;
      v_return_total := round(v_return_total + v_item_value, 2);
      v_refund_total := round(v_refund_total + v_item_refund, 2);
      if v_restock then v_restock_value := round(v_restock_value + v_item_cost, 2); end if;
    end loop;
    if v_line_no = 0 then raise exception 'No eligible sale lines were returned.' using errcode = 'P0001'; end if;
    if v_source_doc.party_id is null and abs(v_refund_total - v_return_total) > 0.004 then
      raise exception 'A walk-in return must be refunded in full because there is no customer balance to reduce.' using errcode = 'P0001';
    end if;
    select coalesce(sum(rd.amount_paid), 0) into v_prior_refunds
      from public.documents rd
     where rd.organization_id = p_organization_id
       and rd.kind = 'RETURN'::public.document_kind
       and rd.status = 'POSTED'::public.document_status
       and rd.metadata->>'sourceDocumentId' = v_source_doc.id::text;
    if v_refund_total + v_prior_refunds > v_source_doc.amount_paid + 0.004 then
      raise exception 'Refund cannot exceed cash actually received against the original sale.' using errcode = 'P0001';
    end if;
    update public.documents
       set subtotal = v_return_total,
           total = v_return_total,
           amount_paid = v_refund_total,
           balance_due = v_return_total - v_refund_total,
           metadata = metadata || jsonb_build_object('refundTotal', v_refund_total, 'restockedValue', v_restock_value)
     where id = v_document_id;
    if v_refund_total > 0 then
      insert into public.payments (organization_id, document_id, party_id, payment_method, amount, paid_on, reference, notes, created_by)
      values (p_organization_id, v_document_id, v_source_doc.party_id, v_method, v_refund_total, v_date, 'RETURN_REFUND', v_notes, auth.uid());
    end if;
    insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, party_id, memo, created_by)
    values (p_organization_id, v_document_id, v_date, 'SALES_REVENUE', v_return_total, 0, v_source_doc.party_id, 'Customer return ' || v_doc_no, auth.uid());
    if v_refund_total > 0 then
      insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, party_id, memo, created_by)
      values (p_organization_id, v_document_id, v_date, 'CASH', 0, v_refund_total, v_source_doc.party_id, 'Refund ' || v_doc_no, auth.uid());
    end if;
    if v_return_total - v_refund_total > 0 then
      insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, party_id, memo, created_by)
      values (p_organization_id, v_document_id, v_date, 'ACCOUNTS_RECEIVABLE', 0, v_return_total - v_refund_total, v_source_doc.party_id, 'Return credit ' || v_doc_no, auth.uid());
    end if;
    if v_restock_value > 0 then
      insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, memo, created_by)
      values (p_organization_id, v_document_id, v_date, 'INVENTORY', v_restock_value, 0, 'Returned goods ' || v_doc_no, auth.uid()),
             (p_organization_id, v_document_id, v_date, 'COST_OF_GOODS_SOLD', 0, v_restock_value, 'Returned goods ' || v_doc_no, auth.uid());
    end if;
  exception
    when sqlstate 'P0001' then return private.finish_failed_command(v_command_id, p_client_id, sqlerrm, 'USER');
    when unique_violation then return private.finish_failed_command(v_command_id, p_client_id, 'Return number is already in use. Refresh and retry.', 'USER');
    when others then return private.finish_failed_command(v_command_id, p_client_id, 'The return could not be saved. It was not recorded; retry or review the action.', 'SERVER');
  end;
  v_response := jsonb_build_object('clientId', p_client_id, 'status', 'OK', 'docNo', v_doc_no, 'flags', '[]'::jsonb, 'total', v_return_total, 'paid', v_refund_total);
  perform private.complete_cashbook_command(v_command_id, v_document_id, v_response);
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, client_id, detail)
  values (p_organization_id, auth.uid(), 'RETURN_POSTED', 'document', v_document_id, p_client_id,
    jsonb_build_object('documentNumber', v_doc_no, 'sourceDocumentNumber', v_source_doc.document_number, 'total', v_return_total, 'refunded', v_refund_total, 'restockedValue', v_restock_value));
  return v_response;
end;
$$;

-- Opening customer/supplier balances are distinct from sales, purchases and
-- cash. They establish receivable/payable carry-forward against opening equity.
create or replace function public.post_opening_balance(
  p_organization_id uuid,
  p_client_id text,
  p_opening jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner public.memberships%rowtype;
  v_started jsonb;
  v_command_id uuid;
  v_party_id uuid;
  v_party public.parties%rowtype;
  v_amount numeric(18,2);
  v_date date;
  v_location_id uuid;
  v_doc_no text;
  v_document_id uuid;
  v_kind public.document_kind;
  v_response jsonb;
begin
  if nullif(btrim(coalesce(p_client_id, '')), '') is null or char_length(btrim(p_client_id)) > 200 then
    return jsonb_build_object('clientId', coalesce(p_client_id, ''), 'status', 'ERROR', 'message', 'This opening balance needs a valid client reference.');
  end if;
  v_owner := private.require_owner(p_organization_id);
  v_started := private.begin_cashbook_command(p_organization_id, p_client_id, 'OPENING_BALANCE', p_opening);
  if coalesce((v_started->>'duplicate')::boolean, false) then return v_started->'response'; end if;
  v_command_id := (v_started->>'commandId')::uuid;
  begin
    if upper(coalesce(nullif(btrim(p_opening->>'type'), ''), 'OPENING_BAL')) not in ('OPENING_BAL', 'OPENING_BALANCE') then
      raise exception 'This command is not an opening balance.' using errcode = 'P0001';
    end if;
    begin v_party_id := nullif(btrim(coalesce(p_opening->>'partyId', '')), '')::uuid;
    exception when others then raise exception 'Choose a valid customer or supplier.' using errcode = 'P0001'; end;
    if v_party_id is null then raise exception 'Choose a customer or supplier.' using errcode = 'P0001'; end if;
    select * into v_party from public.parties p
     where p.id = v_party_id and p.organization_id = p_organization_id and p.active
     for update;
    if not found then raise exception 'Choose an active customer or supplier.' using errcode = 'P0001'; end if;
    v_amount := private.try_numeric(p_opening->>'amount');
    if v_amount is null or v_amount <= 0 then raise exception 'Enter the amount owed at go-live.' using errcode = 'P0001'; end if;
    v_amount := round(v_amount, 2);
    v_date := private.cashbook_posting_date(p_organization_id, p_opening->>'date', 'opening-balance date');
    v_location_id := private.resolve_posting_location(p_organization_id, v_owner,
      coalesce(p_opening->>'locationId', p_opening->>'location'));
    v_doc_no := coalesce(nullif(btrim(p_opening->>'docNo'), ''),
      'OBL-' || to_char(v_date, 'YYYYMMDD') || '-' || upper(substr(md5(p_client_id), 1, 8)));
    if char_length(v_doc_no) > 120 then raise exception 'Opening-balance number is too long.' using errcode = 'P0001'; end if;
    v_kind := case when v_party.kind = 'CUSTOMER'::public.party_kind then 'PAYMENT_IN'::public.document_kind else 'PAYMENT_OUT'::public.document_kind end;
    insert into public.documents (
      organization_id, location_id, kind, document_number, occurred_on, party_id, source_client_id,
      subtotal, total, amount_paid, balance_due, notes, metadata, created_by
    ) values (
      p_organization_id, v_location_id, v_kind, v_doc_no, v_date, v_party_id, btrim(p_client_id),
      v_amount, v_amount, 0, v_amount, nullif(btrim(coalesce(p_opening->>'notes', '')), ''),
      jsonb_build_object('workflow', 'OPENING_BALANCE', 'partyKind', v_party.kind::text), auth.uid()
    ) returning id into v_document_id;
    if v_party.kind = 'CUSTOMER'::public.party_kind then
      insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, party_id, memo, created_by)
      values (p_organization_id, v_document_id, v_date, 'ACCOUNTS_RECEIVABLE', v_amount, 0, v_party_id, 'Opening customer balance ' || v_doc_no, auth.uid()),
             (p_organization_id, v_document_id, v_date, 'OPENING_EQUITY', 0, v_amount, v_party_id, 'Opening customer balance ' || v_doc_no, auth.uid());
    else
      insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, party_id, memo, created_by)
      values (p_organization_id, v_document_id, v_date, 'OPENING_EQUITY', v_amount, 0, v_party_id, 'Opening supplier balance ' || v_doc_no, auth.uid()),
             (p_organization_id, v_document_id, v_date, 'ACCOUNTS_PAYABLE', 0, v_amount, v_party_id, 'Opening supplier balance ' || v_doc_no, auth.uid());
    end if;
  exception
    when sqlstate 'P0001' then return private.finish_failed_command(v_command_id, p_client_id, sqlerrm, 'USER');
    when unique_violation then return private.finish_failed_command(v_command_id, p_client_id, 'Opening-balance number is already in use. Refresh and retry.', 'USER');
    when others then return private.finish_failed_command(v_command_id, p_client_id, 'The opening balance could not be saved. It was not recorded; retry or review the action.', 'SERVER');
  end;
  v_response := jsonb_build_object('clientId', p_client_id, 'status', 'OK', 'docNo', v_doc_no, 'flags', '[]'::jsonb, 'total', v_amount, 'paid', 0);
  perform private.complete_cashbook_command(v_command_id, v_document_id, v_response);
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, client_id, detail)
  values (p_organization_id, auth.uid(), 'OPENING_BALANCE_POSTED', 'document', v_document_id, p_client_id,
    jsonb_build_object('documentNumber', v_doc_no, 'amount', v_amount, 'partyId', v_party_id::text));
  return v_response;
end;
$$;

-- Move FIFO inventory between two active shops without creating income,
-- expense, supplier debt or a new cost. Each destination lot preserves the
-- source lot's historic unit cost and traceable source document.
create or replace function public.post_inventory_transfer(
  p_organization_id uuid,
  p_client_id text,
  p_transfer jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner public.memberships%rowtype;
  v_started jsonb;
  v_command_id uuid;
  v_date date;
  v_from_text text;
  v_to_text text;
  v_from_id uuid;
  v_to_id uuid;
  v_items jsonb := coalesce(p_transfer->'items', '[]'::jsonb);
  v_item jsonb;
  v_product public.products%rowtype;
  v_sku text;
  v_qty numeric(18,4);
  v_remaining numeric(18,4);
  v_take numeric(18,4);
  v_lot record;
  v_plan jsonb;
  v_plan_part jsonb;
  v_line_cost numeric(18,2);
  v_doc_no text;
  v_document_id uuid;
  v_line_id uuid;
  v_dest_lot_id uuid;
  v_line_no integer := 0;
  v_seen jsonb := '{}'::jsonb;
  v_response jsonb;
begin
  if nullif(btrim(coalesce(p_client_id, '')), '') is null or char_length(btrim(p_client_id)) > 200 then
    return jsonb_build_object('clientId', coalesce(p_client_id, ''), 'status', 'ERROR', 'message', 'This transfer needs a valid client reference.');
  end if;
  v_owner := private.require_owner(p_organization_id);
  v_started := private.begin_cashbook_command(p_organization_id, p_client_id, 'TRANSFER', p_transfer);
  if coalesce((v_started->>'duplicate')::boolean, false) then return v_started->'response'; end if;
  v_command_id := (v_started->>'commandId')::uuid;
  begin
    if upper(coalesce(nullif(btrim(p_transfer->>'type'), ''), 'TRANSFER')) <> 'TRANSFER' then
      raise exception 'This command is not a stock transfer.' using errcode = 'P0001';
    end if;
    if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 or jsonb_array_length(v_items) > 500 then
      raise exception 'Add between 1 and 500 transfer lines.' using errcode = 'P0001';
    end if;
    v_from_text := nullif(btrim(coalesce(p_transfer->>'from', p_transfer->>'fromLocationId', '')), '');
    v_to_text := nullif(btrim(coalesce(p_transfer->>'to', p_transfer->>'toLocationId', '')), '');
    if v_from_text is null or v_to_text is null then raise exception 'Choose both the source and destination shops.' using errcode = 'P0001'; end if;
    select l.id into v_from_id from public.locations l
     where l.organization_id = p_organization_id and l.active
       and (l.id::text = v_from_text or lower(l.code::text) = lower(v_from_text)) limit 1;
    select l.id into v_to_id from public.locations l
     where l.organization_id = p_organization_id and l.active
       and (l.id::text = v_to_text or lower(l.code::text) = lower(v_to_text)) limit 1;
    if v_from_id is null or v_to_id is null or v_from_id = v_to_id then raise exception 'Choose two different active shops.' using errcode = 'P0001'; end if;
    v_date := private.cashbook_posting_date(p_organization_id, p_transfer->>'date', 'transfer date');
    -- A stable combined key serializes opposing transfers and prevents lock-order deadlocks.
    perform pg_advisory_xact_lock(hashtextextended(p_organization_id::text || ':' || least(v_from_id::text, v_to_id::text) || ':' || greatest(v_from_id::text, v_to_id::text), 0));
    v_doc_no := coalesce(nullif(btrim(p_transfer->>'docNo'), ''),
      'TRF-' || to_char(v_date, 'YYYYMMDD') || '-' || upper(substr(md5(p_client_id), 1, 8)));
    if char_length(v_doc_no) > 120 then raise exception 'Transfer number is too long.' using errcode = 'P0001'; end if;
    insert into public.documents (
      organization_id, location_id, kind, document_number, occurred_on, source_client_id,
      subtotal, total, amount_paid, balance_due, notes, metadata, created_by
    ) values (
      p_organization_id, v_from_id, 'STOCK_ADJUSTMENT'::public.document_kind, v_doc_no, v_date, btrim(p_client_id),
      0, 0, 0, 0, nullif(btrim(coalesce(p_transfer->>'notes', '')), ''),
      jsonb_build_object('workflow', 'TRANSFER', 'fromLocationId', v_from_id::text, 'toLocationId', v_to_id::text), auth.uid()
    ) returning id into v_document_id;

    for v_item in select value from jsonb_array_elements(v_items)
    loop
      v_sku := upper(btrim(coalesce(v_item->>'sku', '')));
      v_qty := private.try_numeric(coalesce(v_item->>'qty', v_item->>'quantity'));
      if v_sku = '' or v_qty is null or v_qty <= 0 or abs(v_qty - round(v_qty, 4)) > 0.00000001 then
        raise exception 'Each transfer line needs a stock item and a positive quantity.' using errcode = 'P0001';
      end if;
      if v_seen ? v_sku then raise exception 'Product % appears more than once. Combine its quantities first.', v_sku using errcode = 'P0001'; end if;
      v_seen := v_seen || jsonb_build_object(v_sku, true);
      select * into v_product from public.products p
       where p.organization_id = p_organization_id and p.sku = v_sku and p.active
       for share;
      if not found or v_product.kind <> 'ITEM'::public.product_kind then raise exception 'Product % is not an active stock item.', v_sku using errcode = 'P0001'; end if;
      v_remaining := round(v_qty, 4);
      v_plan := '[]'::jsonb;
      v_line_cost := 0;
      for v_lot in
        select l.id, l.quantity_remaining, l.unit_cost
          from public.inventory_lots l
         where l.organization_id = p_organization_id and l.location_id = v_from_id and l.product_id = v_product.id
           and l.status = 'OPEN' and l.quantity_remaining > 0
         order by l.received_on, l.created_at, l.id
         for update
      loop
        exit when v_remaining <= 0;
        v_take := least(v_remaining, v_lot.quantity_remaining);
        v_plan := v_plan || jsonb_build_array(jsonb_build_object('lotId', v_lot.id::text, 'qty', v_take, 'unitCost', v_lot.unit_cost));
        v_line_cost := v_line_cost + round(v_take * v_lot.unit_cost, 2);
        v_remaining := round(v_remaining - v_take, 4);
      end loop;
      if v_remaining > 0 then raise exception 'Not enough recorded stock for % at the source shop.', v_product.name using errcode = 'P0001'; end if;
      v_line_no := v_line_no + 1;
      insert into public.document_lines (
        document_id, organization_id, line_number, product_id, description, quantity, unit_price, unit_cost, line_total, cost_of_goods, metadata
      ) values (
        v_document_id, p_organization_id, v_line_no, v_product.id, v_product.name, round(v_qty, 4), 0,
        round(v_line_cost / v_qty, 2), 0, 0,
        jsonb_build_object('sku', v_product.sku::text, 'fromLocationId', v_from_id::text, 'toLocationId', v_to_id::text, 'allocations', v_plan)
      ) returning id into v_line_id;
      for v_plan_part in select value from jsonb_array_elements(v_plan)
      loop
        update public.inventory_lots
           set quantity_remaining = quantity_remaining - (v_plan_part->>'qty')::numeric,
               status = case when quantity_remaining - (v_plan_part->>'qty')::numeric <= 0 then 'DEPLETED' else 'OPEN' end
         where id = (v_plan_part->>'lotId')::uuid and quantity_remaining >= (v_plan_part->>'qty')::numeric;
        if not found then raise exception 'Stock changed while the transfer was being saved. Refresh and retry.' using errcode = 'P0001'; end if;
        insert into public.inventory_movements (organization_id, location_id, product_id, lot_id, document_id, document_line_id, kind, occurred_on, quantity_delta, unit_cost, notes, created_by)
        values (p_organization_id, v_from_id, v_product.id, (v_plan_part->>'lotId')::uuid, v_document_id, v_line_id,
          'ADJUSTMENT'::public.inventory_movement_kind, v_date, -(v_plan_part->>'qty')::numeric, (v_plan_part->>'unitCost')::numeric,
          'Transfer to destination shop', auth.uid());
        insert into public.inventory_lots (
          organization_id, location_id, product_id, source_document_id, source_line_id, received_on, received_quantity, quantity_remaining, unit_cost, reference, notes
        ) values (
          p_organization_id, v_to_id, v_product.id, v_document_id, v_line_id, v_date,
          (v_plan_part->>'qty')::numeric, (v_plan_part->>'qty')::numeric, (v_plan_part->>'unitCost')::numeric, v_doc_no, 'Transfer from source shop'
        ) returning id into v_dest_lot_id;
        insert into public.inventory_movements (organization_id, location_id, product_id, lot_id, document_id, document_line_id, kind, occurred_on, quantity_delta, unit_cost, notes, created_by)
        values (p_organization_id, v_to_id, v_product.id, v_dest_lot_id, v_document_id, v_line_id,
          'ADJUSTMENT'::public.inventory_movement_kind, v_date, (v_plan_part->>'qty')::numeric, (v_plan_part->>'unitCost')::numeric,
          'Transfer from source shop', auth.uid());
      end loop;
    end loop;
  exception
    when sqlstate 'P0001' then return private.finish_failed_command(v_command_id, p_client_id, sqlerrm, 'USER');
    when unique_violation then return private.finish_failed_command(v_command_id, p_client_id, 'Transfer number is already in use. Refresh and retry.', 'USER');
    when others then return private.finish_failed_command(v_command_id, p_client_id, 'The stock transfer could not be saved. It was not recorded; retry or review the action.', 'SERVER');
  end;
  v_response := jsonb_build_object('clientId', p_client_id, 'status', 'OK', 'docNo', v_doc_no, 'flags', '[]'::jsonb, 'total', 0, 'paid', 0);
  perform private.complete_cashbook_command(v_command_id, v_document_id, v_response);
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, client_id, detail)
  values (p_organization_id, auth.uid(), 'TRANSFER_POSTED', 'document', v_document_id, p_client_id,
    jsonb_build_object('documentNumber', v_doc_no, 'fromLocationId', v_from_id::text, 'toLocationId', v_to_id::text));
  return v_response;
end;
$$;

-- Cancellation/reversal is intentionally different from a customer return.
-- It creates an offsetting document and ledger trail; it never deletes source
-- evidence. Workflows with dependent returns, payments, or moved stock are
-- refused so the owner must use a specific corrective workflow instead.
create or replace function public.reverse_cashbook_document(
  p_organization_id uuid,
  p_client_id text,
  p_reversal jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner public.memberships%rowtype;
  v_started jsonb;
  v_command_id uuid;
  v_source_no text;
  v_source public.documents%rowtype;
  v_reason text;
  v_date date;
  v_doc_no text;
  v_document_id uuid;
  v_alloc record;
  v_lot public.inventory_lots%rowtype;
  v_payment_alloc jsonb;
  v_response jsonb;
begin
  if nullif(btrim(coalesce(p_client_id, '')), '') is null or char_length(btrim(p_client_id)) > 200 then
    return jsonb_build_object('clientId', coalesce(p_client_id, ''), 'status', 'ERROR', 'message', 'This reversal needs a valid client reference.');
  end if;
  v_owner := private.require_owner(p_organization_id);
  v_started := private.begin_cashbook_command(p_organization_id, p_client_id, 'REVERSAL', p_reversal);
  if coalesce((v_started->>'duplicate')::boolean, false) then return v_started->'response'; end if;
  v_command_id := (v_started->>'commandId')::uuid;
  begin
    if upper(coalesce(nullif(btrim(p_reversal->>'type'), ''), 'REVERSAL')) <> 'REVERSAL' then
      raise exception 'This command is not a reversal.' using errcode = 'P0001';
    end if;
    v_source_no := nullif(btrim(coalesce(p_reversal->>'docNo', p_reversal->>'sourceDocNo', '')), '');
    v_reason := nullif(btrim(coalesce(p_reversal->>'reason', '')), '');
    if v_source_no is null then raise exception 'Choose a document to reverse.' using errcode = 'P0001'; end if;
    if v_reason is null or char_length(v_reason) < 3 then raise exception 'Give a reason for the reversal.' using errcode = 'P0001'; end if;
    select * into v_source from public.documents d
     where d.organization_id = p_organization_id and d.document_number = v_source_no
     for update;
    if not found then raise exception 'Document % was not found.', v_source_no using errcode = 'P0001'; end if;
    if v_source.status <> 'POSTED'::public.document_status then raise exception 'This document has already been reversed or cancelled.' using errcode = 'P0001'; end if;
    if v_source.kind = 'RETURN'::public.document_kind or v_source.metadata->>'workflow' in ('TRANSFER', 'ADJUSTMENT') then
      raise exception 'Customer returns, transfers and stock corrections are real events. Record a specific corrective transaction instead of cancelling them.' using errcode = 'P0001';
    end if;
    if v_source.kind = 'SALE'::public.document_kind and exists (
      select 1 from public.document_lines rl
      join public.documents rd on rd.id = rl.document_id
       where rd.organization_id = p_organization_id and rd.kind = 'RETURN'::public.document_kind
         and rd.status = 'POSTED'::public.document_status and rl.metadata->>'sourceDocumentId' = v_source.id::text
    ) then
      raise exception 'This sale already has a customer return. Correct the return separately; do not cancel the original sale.' using errcode = 'P0001';
    end if;
    if v_source.kind in ('SALE'::public.document_kind, 'PURCHASE'::public.document_kind) and exists (
      select 1 from public.documents pd
       where pd.organization_id = p_organization_id and pd.status = 'POSTED'::public.document_status
         and pd.metadata->>'workflow' = 'PARTY_PAYMENT'
         and pd.metadata->'allocations' @> jsonb_build_array(jsonb_build_object('documentId', v_source.id::text))
    ) then
      raise exception 'This document has later party payments. Reverse or correct those payments first.' using errcode = 'P0001';
    end if;
    if v_source.kind in ('PURCHASE'::public.document_kind, 'OPENING_STOCK'::public.document_kind) and exists (
      select 1 from public.inventory_lots l
       where l.source_document_id = v_source.id
         and (l.status <> 'OPEN' or l.quantity_remaining <> l.received_quantity)
    ) then
      raise exception 'Stock from this document has been sold, moved, or corrected. Use a stock correction instead of cancelling it.' using errcode = 'P0001';
    end if;
    v_date := private.cashbook_posting_date(p_organization_id, p_reversal->>'date', 'reversal date');
    v_doc_no := coalesce(nullif(btrim(p_reversal->>'reversalDocNo'), ''),
      'REV-' || to_char(v_date, 'YYYYMMDD') || '-' || upper(substr(md5(p_client_id), 1, 8)));
    if char_length(v_doc_no) > 120 then raise exception 'Reversal number is too long.' using errcode = 'P0001'; end if;
    if v_source.location_id is not null then
      perform pg_advisory_xact_lock(hashtextextended(p_organization_id::text || ':' || v_source.location_id::text, 0));
    end if;
    insert into public.documents (
      organization_id, location_id, kind, document_number, occurred_on, party_id, source_client_id,
      subtotal, total, amount_paid, balance_due, notes, metadata, created_by
    ) values (
      p_organization_id, v_source.location_id, 'REVERSAL'::public.document_kind, v_doc_no, v_date, v_source.party_id, btrim(p_client_id),
      0, 0, 0, 0, 'Reversal of ' || v_source.document_number || ': ' || v_reason,
      jsonb_build_object('workflow', 'REVERSAL', 'sourceDocumentId', v_source.id::text, 'sourceDocumentNumber', v_source.document_number, 'reason', v_reason), auth.uid()
    ) returning id into v_document_id;

    -- Reverse any later payment allocation first so the source document's
    -- cached amount_paid/balance_due fields remain consistent with its ledger.
    if v_source.metadata->>'workflow' = 'PARTY_PAYMENT' then
      for v_payment_alloc in select value from jsonb_array_elements(coalesce(v_source.metadata->'allocations', '[]'::jsonb))
      loop
        update public.documents
           set amount_paid = amount_paid - (v_payment_alloc->>'amount')::numeric,
               balance_due = balance_due + (v_payment_alloc->>'amount')::numeric
         where id = (v_payment_alloc->>'documentId')::uuid
           and amount_paid >= (v_payment_alloc->>'amount')::numeric;
        if not found then raise exception 'A settled document changed after this payment. Do not reverse it automatically.' using errcode = 'P0001'; end if;
      end loop;
    end if;

    if v_source.kind = 'SALE'::public.document_kind then
      for v_alloc in
        select la.lot_id, la.quantity, la.unit_cost, dl.product_id
          from public.lot_allocations la
          join public.document_lines dl on dl.id = la.sale_line_id
         where la.organization_id = p_organization_id and dl.document_id = v_source.id
         order by la.created_at, la.id
         for update
      loop
        update public.inventory_lots
           set quantity_remaining = quantity_remaining + v_alloc.quantity,
               status = 'OPEN'
         where id = v_alloc.lot_id;
        insert into public.inventory_movements (organization_id, location_id, product_id, lot_id, document_id, kind, occurred_on, quantity_delta, unit_cost, notes, created_by)
        values (p_organization_id, v_source.location_id, v_alloc.product_id, v_alloc.lot_id, v_document_id,
          'REVERSAL'::public.inventory_movement_kind, v_date, v_alloc.quantity, v_alloc.unit_cost, 'Cancelled sale ' || v_source.document_number, auth.uid());
      end loop;
    elsif v_source.kind in ('PURCHASE'::public.document_kind, 'OPENING_STOCK'::public.document_kind) then
      for v_lot in
        select * from public.inventory_lots l where l.source_document_id = v_source.id for update
      loop
        update public.inventory_lots set quantity_remaining = 0, status = 'VOID' where id = v_lot.id;
        insert into public.inventory_movements (organization_id, location_id, product_id, lot_id, document_id, kind, occurred_on, quantity_delta, unit_cost, notes, created_by)
        values (p_organization_id, v_lot.location_id, v_lot.product_id, v_lot.id, v_document_id,
          'REVERSAL'::public.inventory_movement_kind, v_date, -v_lot.received_quantity, v_lot.unit_cost, 'Cancelled receipt ' || v_source.document_number, auth.uid());
      end loop;
    end if;

    insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, party_id, product_id, memo, created_by)
    select e.organization_id, v_document_id, v_date, e.account_code, e.credit, e.debit, e.party_id, e.product_id,
      'Reversal of ' || v_source.document_number || ': ' || v_reason, auth.uid()
      from public.ledger_entries e
     where e.document_id = v_source.id;
    update public.documents set status = 'REVERSED'::public.document_status, reversed_document_id = v_document_id where id = v_source.id;
  exception
    when sqlstate 'P0001' then return private.finish_failed_command(v_command_id, p_client_id, sqlerrm, 'USER');
    when unique_violation then return private.finish_failed_command(v_command_id, p_client_id, 'Reversal number is already in use. Refresh and retry.', 'USER');
    when others then return private.finish_failed_command(v_command_id, p_client_id, 'The reversal could not be saved. It was not recorded; retry or review the action.', 'SERVER');
  end;
  v_response := jsonb_build_object('clientId', p_client_id, 'status', 'OK', 'docNo', v_doc_no, 'sourceDocNo', v_source.document_number, 'flags', '[]'::jsonb, 'total', 0, 'paid', 0);
  perform private.complete_cashbook_command(v_command_id, v_document_id, v_response);
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, client_id, detail)
  values (p_organization_id, auth.uid(), 'DOCUMENT_REVERSED', 'document', v_document_id, p_client_id,
    jsonb_build_object('documentNumber', v_doc_no, 'sourceDocumentNumber', v_source.document_number, 'reason', v_reason));
  return v_response;
end;
$$;

revoke all on function private.begin_cashbook_command(uuid, text, text, jsonb) from public;
revoke all on function private.complete_cashbook_command(uuid, uuid, jsonb) from public;
revoke all on function private.cashbook_posting_date(uuid, text, text) from public;
revoke all on function public.post_purchase(uuid, text, jsonb) from public, anon;
revoke all on function public.post_expense(uuid, text, jsonb) from public, anon;
revoke all on function public.post_owner_money(uuid, text, jsonb) from public, anon;
revoke all on function public.post_party_payment(uuid, text, jsonb) from public, anon;
revoke all on function public.post_stock_adjustment(uuid, text, jsonb) from public, anon;
revoke all on function public.post_customer_return(uuid, text, jsonb) from public, anon;
revoke all on function public.post_opening_balance(uuid, text, jsonb) from public, anon;
revoke all on function public.post_inventory_transfer(uuid, text, jsonb) from public, anon;
revoke all on function public.reverse_cashbook_document(uuid, text, jsonb) from public, anon;
grant execute on function public.post_purchase(uuid, text, jsonb) to authenticated;
grant execute on function public.post_expense(uuid, text, jsonb) to authenticated;
grant execute on function public.post_owner_money(uuid, text, jsonb) to authenticated;
grant execute on function public.post_party_payment(uuid, text, jsonb) to authenticated;
grant execute on function public.post_stock_adjustment(uuid, text, jsonb) to authenticated;
grant execute on function public.post_customer_return(uuid, text, jsonb) to authenticated;
grant execute on function public.post_opening_balance(uuid, text, jsonb) to authenticated;
grant execute on function public.post_inventory_transfer(uuid, text, jsonb) to authenticated;
grant execute on function public.reverse_cashbook_document(uuid, text, jsonb) to authenticated;
