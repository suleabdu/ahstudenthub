-- Cashbook Supabase migration 5: atomic sale and opening-stock commands.
--
-- The important invariant is that a sale either creates its document, payment,
-- FIFO allocations, inventory movements, ledger entries, audit event, and
-- idempotency result together, or creates none of those business records.

create or replace function public.post_sale(
  p_organization_id uuid,
  p_client_id text,
  p_sale jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_membership public.memberships%rowtype;
  v_settings public.organization_settings%rowtype;
  v_org public.organizations%rowtype;
  v_command public.sync_commands%rowtype;
  v_command_id uuid;
  v_response jsonb;
  v_location_id uuid;
  v_date date;
  v_today date;
  v_doc_no text;
  v_items jsonb := coalesce(p_sale->'items', '[]'::jsonb);
  v_normalized_items jsonb := '[]'::jsonb;
  v_item jsonb;
  v_normalized jsonb;
  v_product public.products%rowtype;
  v_party public.parties%rowtype;
  v_sku text;
  v_qty numeric;
  v_requested_price numeric;
  v_unit_price numeric;
  v_line_total numeric(18,2);
  v_total numeric(18,2) := 0;
  v_amount_paid numeric(18,2);
  v_balance numeric(18,2);
  v_party_id uuid;
  v_party_text text;
  v_new_party_name text;
  v_new_party_phone text;
  v_existing_balance numeric(18,2);
  v_document_id uuid;
  v_line_id uuid;
  v_line_number integer := 0;
  v_line_cogs numeric(18,2);
  v_service_material record;
  v_lot record;
  v_allocation jsonb;
  v_plan jsonb;
  v_need numeric(18,4);
  v_remaining numeric(18,4);
  v_take numeric(18,4);
  v_alloc_product_id uuid;
  v_alloc_lot_id uuid;
  v_alloc_unit_cost numeric(18,2);
  v_flags jsonb := '[]'::jsonb;
  v_method text;
  v_notes text;
begin
  if nullif(btrim(coalesce(p_client_id, '')), '') is null or char_length(btrim(p_client_id)) > 200 then
    return jsonb_build_object('clientId', coalesce(p_client_id, ''), 'status', 'ERROR', 'message', 'This saved action has no valid client reference. It was not posted.');
  end if;

  v_membership := private.require_membership(p_organization_id);
  if v_membership.role not in ('OWNER'::public.cashbook_role, 'MANAGER'::public.cashbook_role, 'REP'::public.cashbook_role) then
    raise exception 'You do not have permission to record a sale.' using errcode = '42501';
  end if;

  -- Lock the command row before validating. A successful retry returns the
  -- original document rather than posting another sale. A prior failed
  -- command is deliberately retried because stock or data may have been
  -- corrected after the first attempt.
  select * into v_command
    from public.sync_commands c
   where c.organization_id = p_organization_id and c.client_id = btrim(p_client_id)
   for update;
  if found and v_command.status = 'SUCCEEDED'::public.command_status then
    return jsonb_set(coalesce(v_command.response, '{}'::jsonb), '{status}', '"DUPLICATE"'::jsonb, true);
  elsif found then
    update public.sync_commands
       set status = 'PROCESSING'::public.command_status,
           request = coalesce(p_sale, '{}'::jsonb), response = null,
           error_code = null, error_message = null, completed_at = null
     where id = v_command.id
     returning id into v_command_id;
  else
    insert into public.sync_commands (organization_id, client_id, actor_id, action, request)
    values (p_organization_id, btrim(p_client_id), auth.uid(), 'SALE', coalesce(p_sale, '{}'::jsonb))
    returning id into v_command_id;
  end if;

  select * into v_settings from public.organization_settings s where s.organization_id = p_organization_id;
  select * into v_org from public.organizations o where o.id = p_organization_id;
  v_today := (now() at time zone v_org.timezone)::date;
  if coalesce(p_sale->>'type', 'SALE') <> 'SALE' then
    return private.finish_failed_command(v_command_id, p_client_id, 'This command is not a sale.');
  end if;
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 or jsonb_array_length(v_items) > 200 then
    return private.finish_failed_command(v_command_id, p_client_id, 'Add between 1 and 200 sale lines.');
  end if;
  begin
    v_date := coalesce(nullif(btrim(p_sale->>'date'), '')::date, v_today);
  exception when others then
    return private.finish_failed_command(v_command_id, p_client_id, 'Enter a valid sale date.');
  end;
  if v_date > v_today then
    return private.finish_failed_command(v_command_id, p_client_id, 'A sale cannot be dated in the future.');
  end if;
  if v_settings.closed_until is not null and v_date <= v_settings.closed_until then
    return private.finish_failed_command(v_command_id, p_client_id, 'This accounting period is closed.');
  end if;
  begin
    v_location_id := private.resolve_posting_location(p_organization_id, v_membership,
      coalesce(p_sale->>'locationId', p_sale->>'location'));
  exception when others then
    return private.finish_failed_command(v_command_id, p_client_id, 'Choose a shop you are allowed to use.');
  end;
  -- FIFO quantities at one shop are deliberately serialized. This avoids
  -- cross-product deadlocks while still allowing separate shops to post in
  -- parallel; a second sale waits, then sees the first sale's true stock.
  perform pg_advisory_xact_lock(hashtextextended(p_organization_id::text || ':' || v_location_id::text, 0));

  -- Normalize every browser-supplied line before any financial or inventory
  -- row is written. In particular, a zero selling price is never saleable.
  for v_item in select value from jsonb_array_elements(v_items)
  loop
    v_sku := upper(btrim(coalesce(v_item->>'sku', '')));
    v_qty := private.try_numeric(v_item->>'qty');
    if v_sku = '' or v_qty is null or v_qty <= 0 or v_qty > 1000000000 or abs(v_qty - round(v_qty, 4)) > 0.00000001 then
      return private.finish_failed_command(v_command_id, p_client_id, 'Each sale line needs a product and a positive quantity with up to four decimal places.');
    end if;
    select * into v_product
      from public.products p
     where p.organization_id = p_organization_id and p.sku = v_sku and p.active
     for share;
    if not found then
      return private.finish_failed_command(v_command_id, p_client_id, 'Product ' || v_sku || ' is not active in this cashbook.');
    end if;
    v_requested_price := private.try_numeric(v_item->>'price');
    if v_requested_price is not null and v_membership.role = 'OWNER'::public.cashbook_role and v_product.price_editable then
      v_unit_price := v_requested_price;
    else
      v_unit_price := v_product.selling_price;
      if v_requested_price is not null and abs(v_requested_price - v_unit_price) > 0.004 and not v_product.price_editable then
        return private.finish_failed_command(v_command_id, p_client_id, 'The selling price for ' || v_product.name || ' changed. Refresh the sale before saving it.');
      end if;
    end if;
    if v_unit_price is null or v_unit_price <= 0 then
      return private.finish_failed_command(v_command_id, p_client_id, 'Selling price for ' || v_product.name || ' must be above zero before saving.');
    end if;
    v_line_total := round(v_qty * v_unit_price, 2);
    v_total := v_total + v_line_total;
    v_normalized_items := v_normalized_items || jsonb_build_array(jsonb_build_object(
      'productId', v_product.id::text, 'sku', v_product.sku::text, 'name', v_product.name,
      'kind', v_product.kind::text, 'quantity', v_qty, 'unitPrice', v_unit_price,
      'serviceCost', v_product.service_cost, 'lineTotal', v_line_total
    ));
  end loop;
  v_total := round(v_total, 2);

  if not (p_sale ? 'amountPaid') then
    return private.finish_failed_command(v_command_id, p_client_id, 'Specify the amount actually received for this sale.');
  end if;
  v_amount_paid := private.try_numeric(p_sale->>'amountPaid');
  if v_amount_paid is null or v_amount_paid < 0 or v_amount_paid > v_total then
    return private.finish_failed_command(v_command_id, p_client_id, 'Amount received must be between zero and the sale total. Change due is not an overpayment.');
  end if;
  v_amount_paid := round(v_amount_paid, 2);
  v_balance := v_total - v_amount_paid;
  v_method := coalesce(nullif(btrim(p_sale->>'method'), ''), 'Cash');
  v_notes := nullif(btrim(coalesce(p_sale->>'notes', '')), '');

  v_party_text := nullif(btrim(coalesce(p_sale->>'partyId', '')), '');
  if v_party_text is not null then
    begin
      v_party_id := v_party_text::uuid;
    exception when others then
      return private.finish_failed_command(v_command_id, p_client_id, 'Choose a valid customer.');
    end;
    select * into v_party from public.parties p
     where p.id = v_party_id and p.organization_id = p_organization_id
       and p.kind = 'CUSTOMER'::public.party_kind and p.active
      for update;
    if not found then
      return private.finish_failed_command(v_command_id, p_client_id, 'Choose an active customer for this sale.');
    end if;
  elsif jsonb_typeof(p_sale->'newParty') = 'object' then
    v_new_party_name := nullif(btrim(coalesce(p_sale->'newParty'->>'name', '')), '');
    v_new_party_phone := nullif(btrim(coalesce(p_sale->'newParty'->>'phone', '')), '');
    if v_new_party_name is null then
      return private.finish_failed_command(v_command_id, p_client_id, 'Enter the new customer name.');
    end if;
    select * into v_party from public.parties p
     where p.organization_id = p_organization_id and p.kind = 'CUSTOMER'::public.party_kind
       and lower(p.name) = lower(v_new_party_name) limit 1
     for update;
    if found then
      v_party_id := v_party.id;
    end if;
  end if;
  if v_balance > 0 and v_party_id is null and v_new_party_name is null then
    return private.finish_failed_command(v_command_id, p_client_id, 'Walk-in sales must be paid in full. Choose a customer for part payment or pay later.');
  end if;
  if v_balance > 0 and v_party.credit_limit > 0 then
    v_existing_balance := private.party_balance(p_organization_id, v_party_id, 'CUSTOMER'::public.party_kind);
    if v_existing_balance + v_balance > v_party.credit_limit then
      return private.finish_failed_command(v_command_id, p_client_id, 'This sale would exceed the customer credit limit.');
    end if;
  end if;

  v_doc_no := nullif(btrim(coalesce(p_sale->>'docNo', '')), '');
  if v_doc_no is null then
    v_doc_no := 'SAL-' || to_char(v_date, 'YYYYMMDD') || '-' || upper(substr(md5(p_client_id), 1, 8));
  end if;
  if char_length(v_doc_no) > 120 then
    return private.finish_failed_command(v_command_id, p_client_id, 'Receipt number is too long.');
  end if;

  begin
    -- Create a new customer only inside the same protected posting block. If
    -- a stock or validation error later rejects the sale, no orphan customer
    -- record is left behind.
    if v_party_id is null and v_new_party_name is not null then
      insert into public.parties (organization_id, kind, name, phone, created_by)
      values (p_organization_id, 'CUSTOMER'::public.party_kind, v_new_party_name, v_new_party_phone, auth.uid())
      on conflict do nothing
      returning * into v_party;
      if not found then
        select * into v_party from public.parties p
         where p.organization_id = p_organization_id and p.kind = 'CUSTOMER'::public.party_kind
           and lower(p.name) = lower(v_new_party_name)
         limit 1 for update;
      end if;
      v_party_id := v_party.id;
      if v_party_id is null then
        raise exception 'Could not create or find the named customer.' using errcode = 'P0001';
      end if;
    end if;
    insert into public.documents (
      organization_id, location_id, kind, document_number, occurred_on, party_id,
      source_client_id, subtotal, total, amount_paid, balance_due, payment_method,
      notes, created_by
    ) values (
      p_organization_id, v_location_id, 'SALE'::public.document_kind, v_doc_no, v_date,
      v_party_id, btrim(p_client_id), v_total, v_total, v_amount_paid, v_balance,
      v_method, v_notes, auth.uid()
    ) returning id into v_document_id;

    for v_normalized in select value from jsonb_array_elements(v_normalized_items)
    loop
      v_line_number := v_line_number + 1;
      v_line_id := gen_random_uuid();
      v_plan := '[]'::jsonb;
      v_line_cogs := 0;

      if (v_normalized->>'kind') = 'ITEM' then
        v_need := (v_normalized->>'quantity')::numeric;
        v_remaining := v_need;
        for v_lot in
          select l.id, l.product_id, l.quantity_remaining, l.unit_cost
            from public.inventory_lots l
           where l.organization_id = p_organization_id
             and l.location_id = v_location_id
             and l.product_id = (v_normalized->>'productId')::uuid
             and l.status = 'OPEN' and l.quantity_remaining > 0
           order by l.received_on, l.created_at, l.id
           for update
        loop
          exit when v_remaining <= 0;
          v_take := least(v_remaining, v_lot.quantity_remaining);
          v_plan := v_plan || jsonb_build_array(jsonb_build_object(
            'lotId', v_lot.id::text, 'productId', v_lot.product_id::text,
            'quantity', v_take, 'unitCost', v_lot.unit_cost
          ));
          v_line_cogs := v_line_cogs + (v_take * v_lot.unit_cost);
          v_remaining := v_remaining - v_take;
        end loop;
        if v_remaining > 0 then
          raise exception 'Not enough recorded stock for %. Record the delivery first or correct the stock count.', v_normalized->>'name' using errcode = 'P0001';
        end if;
      else
        v_line_cogs := round(coalesce((v_normalized->>'serviceCost')::numeric, 0) * (v_normalized->>'quantity')::numeric, 2);
        for v_service_material in
          select sm.material_product_id, sm.quantity_per_service
            from public.service_materials sm
           where sm.organization_id = p_organization_id
             and sm.service_product_id = (v_normalized->>'productId')::uuid
        loop
          v_need := (v_normalized->>'quantity')::numeric * v_service_material.quantity_per_service;
          v_remaining := v_need;
          for v_lot in
            select l.id, l.product_id, l.quantity_remaining, l.unit_cost
              from public.inventory_lots l
             where l.organization_id = p_organization_id
               and l.location_id = v_location_id
               and l.product_id = v_service_material.material_product_id
               and l.status = 'OPEN' and l.quantity_remaining > 0
             order by l.received_on, l.created_at, l.id
             for update
          loop
            exit when v_remaining <= 0;
            v_take := least(v_remaining, v_lot.quantity_remaining);
            v_plan := v_plan || jsonb_build_array(jsonb_build_object(
              'lotId', v_lot.id::text, 'productId', v_lot.product_id::text,
              'quantity', v_take, 'unitCost', v_lot.unit_cost
            ));
            v_line_cogs := v_line_cogs + (v_take * v_lot.unit_cost);
            v_remaining := v_remaining - v_take;
          end loop;
          if v_remaining > 0 then
            raise exception 'Not enough recorded stock for a material used by %.', v_normalized->>'name' using errcode = 'P0001';
          end if;
        end loop;
      end if;

      v_line_cogs := round(v_line_cogs, 2);
      insert into public.document_lines (
        id, document_id, organization_id, line_number, product_id, description,
        quantity, unit_price, unit_cost, line_total, cost_of_goods, metadata
      ) values (
        v_line_id, v_document_id, p_organization_id, v_line_number,
        (v_normalized->>'productId')::uuid, v_normalized->>'name',
        round((v_normalized->>'quantity')::numeric, 4), round((v_normalized->>'unitPrice')::numeric, 2),
        case when (v_normalized->>'quantity')::numeric > 0 then round(v_line_cogs / (v_normalized->>'quantity')::numeric, 2) else 0 end,
        round((v_normalized->>'lineTotal')::numeric, 2), v_line_cogs,
        jsonb_build_object('sku', v_normalized->>'sku')
      );

      for v_allocation in select value from jsonb_array_elements(v_plan)
      loop
        v_alloc_lot_id := (v_allocation->>'lotId')::uuid;
        v_alloc_product_id := (v_allocation->>'productId')::uuid;
        v_take := (v_allocation->>'quantity')::numeric;
        v_alloc_unit_cost := (v_allocation->>'unitCost')::numeric;
        update public.inventory_lots
           set quantity_remaining = quantity_remaining - v_take,
               status = case when quantity_remaining - v_take <= 0 then 'DEPLETED' else 'OPEN' end
         where id = v_alloc_lot_id and quantity_remaining >= v_take;
        if not found then
          raise exception 'Stock changed while the sale was being saved. Refresh and try again.' using errcode = 'P0001';
        end if;
        insert into public.lot_allocations (organization_id, sale_line_id, lot_id, quantity, unit_cost)
        values (p_organization_id, v_line_id, v_alloc_lot_id, v_take, v_alloc_unit_cost);
        insert into public.inventory_movements (
          organization_id, location_id, product_id, lot_id, document_id, document_line_id,
          kind, occurred_on, quantity_delta, unit_cost, notes, created_by
        ) values (
          p_organization_id, v_location_id, v_alloc_product_id, v_alloc_lot_id, v_document_id, v_line_id,
          'SALE'::public.inventory_movement_kind, v_date, -v_take, v_alloc_unit_cost, v_notes, auth.uid()
        );
      end loop;
    end loop;

    if v_amount_paid > 0 then
      insert into public.payments (organization_id, document_id, party_id, payment_method, amount, paid_on, notes, created_by)
      values (p_organization_id, v_document_id, v_party_id, v_method, v_amount_paid, v_date, v_notes, auth.uid());
      insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, party_id, memo, created_by)
      values (p_organization_id, v_document_id, v_date, 'CASH', v_amount_paid, 0, v_party_id, 'Sale payment ' || v_doc_no, auth.uid());
    end if;
    if v_balance > 0 then
      insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, party_id, memo, created_by)
      values (p_organization_id, v_document_id, v_date, 'ACCOUNTS_RECEIVABLE', v_balance, 0, v_party_id, 'Sale balance ' || v_doc_no, auth.uid());
    end if;
    insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, party_id, memo, created_by)
    values (p_organization_id, v_document_id, v_date, 'SALES_REVENUE', 0, v_total, v_party_id, 'Sale ' || v_doc_no, auth.uid());
    select coalesce(sum(l.cost_of_goods), 0) into v_line_cogs from public.document_lines l where l.document_id = v_document_id;
    if v_line_cogs > 0 then
      insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, memo, created_by)
      values (p_organization_id, v_document_id, v_date, 'COST_OF_GOODS_SOLD', v_line_cogs, 0, 'Cost of sale ' || v_doc_no, auth.uid()),
             (p_organization_id, v_document_id, v_date, 'INVENTORY', 0, v_line_cogs, 'Inventory used ' || v_doc_no, auth.uid());
    end if;
  exception
    when sqlstate 'P0001' then
      return private.finish_failed_command(v_command_id, p_client_id, sqlerrm, 'USER');
    when unique_violation then
      return private.finish_failed_command(v_command_id, p_client_id, 'Receipt number is already in use. Refresh and retry this sale.', 'USER');
    when others then
      return private.finish_failed_command(v_command_id, p_client_id, 'The sale could not be saved. It was not recorded; retry or review the action.', 'SERVER');
  end;

  v_response := jsonb_build_object('clientId', p_client_id, 'status', 'OK', 'docNo', v_doc_no, 'flags', v_flags);
  update public.sync_commands
     set status = 'SUCCEEDED'::public.command_status, response = v_response,
         document_id = v_document_id, completed_at = now()
   where id = v_command_id;
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, client_id, detail)
  values (p_organization_id, auth.uid(), 'SALE_POSTED', 'document', v_document_id, p_client_id,
    jsonb_build_object('documentNumber', v_doc_no, 'total', v_total, 'amountPaid', v_amount_paid, 'locationId', v_location_id::text));
  return v_response;
end;
$$;

-- Opening stock is deliberately separate from a purchase. It creates FIFO
-- lots and an opening-equity ledger entry but no fictional supplier/payment.
create or replace function public.post_opening_stock(
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
  v_command public.sync_commands%rowtype;
  v_command_id uuid;
  v_org public.organizations%rowtype;
  v_date date;
  v_today date;
  v_location_id uuid;
  v_items jsonb := coalesce(p_opening->'items', '[]'::jsonb);
  v_item jsonb;
  v_product public.products%rowtype;
  v_sku text;
  v_qty numeric;
  v_cost numeric;
  v_document_id uuid;
  v_line_id uuid;
  v_opening_lot_id uuid;
  v_line_number integer := 0;
  v_value numeric(18,2) := 0;
  v_doc_no text;
  v_response jsonb;
begin
  if nullif(btrim(coalesce(p_client_id, '')), '') is null or char_length(btrim(p_client_id)) > 200 then
    return jsonb_build_object('clientId', coalesce(p_client_id, ''), 'status', 'ERROR', 'message', 'Opening stock needs a valid client reference.');
  end if;
  v_owner := private.require_owner(p_organization_id);
  select * into v_command from public.sync_commands c
   where c.organization_id = p_organization_id and c.client_id = btrim(p_client_id) for update;
  if found and v_command.status = 'SUCCEEDED'::public.command_status then
    return jsonb_set(coalesce(v_command.response, '{}'::jsonb), '{status}', '"DUPLICATE"'::jsonb, true);
  elsif found then
    update public.sync_commands set status = 'PROCESSING'::public.command_status, request = coalesce(p_opening, '{}'::jsonb), response = null, completed_at = null
     where id = v_command.id returning id into v_command_id;
  else
    insert into public.sync_commands (organization_id, client_id, actor_id, action, request)
    values (p_organization_id, btrim(p_client_id), auth.uid(), 'OPENING_STOCK', coalesce(p_opening, '{}'::jsonb))
    returning id into v_command_id;
  end if;
  if jsonb_typeof(v_items) <> 'array' or jsonb_array_length(v_items) = 0 or jsonb_array_length(v_items) > 5000 then
    return private.finish_failed_command(v_command_id, p_client_id, 'Add between 1 and 5,000 opening-stock rows.');
  end if;
  select * into v_org from public.organizations o where o.id = p_organization_id;
  v_today := (now() at time zone v_org.timezone)::date;
  begin v_date := coalesce(nullif(btrim(p_opening->>'date'), '')::date, v_today);
  exception when others then return private.finish_failed_command(v_command_id, p_client_id, 'Enter a valid opening-stock date.'); end;
  if v_date > v_today then return private.finish_failed_command(v_command_id, p_client_id, 'Opening stock cannot be dated in the future.'); end if;
  begin v_location_id := private.resolve_posting_location(p_organization_id, v_owner, coalesce(p_opening->>'locationId', p_opening->>'location'));
  exception when others then return private.finish_failed_command(v_command_id, p_client_id, 'Choose an active shop before saving opening stock.'); end;
  perform pg_advisory_xact_lock(hashtextextended(p_organization_id::text || ':' || v_location_id::text, 0));
  v_doc_no := coalesce(nullif(btrim(p_opening->>'docNo'), ''), 'OPEN-' || to_char(v_date, 'YYYYMMDD') || '-' || upper(substr(md5(p_client_id), 1, 8)));

  begin
    insert into public.documents (organization_id, location_id, kind, document_number, occurred_on, source_client_id, subtotal, total, amount_paid, balance_due, notes, created_by)
    values (p_organization_id, v_location_id, 'OPENING_STOCK'::public.document_kind, v_doc_no, v_date, btrim(p_client_id), 0, 0, 0, 0,
      nullif(btrim(coalesce(p_opening->>'notes', '')), ''), auth.uid()) returning id into v_document_id;
    for v_item in select value from jsonb_array_elements(v_items)
    loop
      v_sku := upper(btrim(coalesce(v_item->>'sku', '')));
      v_qty := private.try_numeric(v_item->>'qty');
      v_cost := private.try_numeric(coalesce(v_item->>'unitCost', v_item->>'cost'));
      if v_sku = '' or v_qty is null or v_qty <= 0 or abs(v_qty - round(v_qty, 4)) > 0.00000001 or v_cost is null or v_cost <= 0 then
        raise exception 'Each opening-stock row needs an active product, a positive quantity, and a unit cost above zero.' using errcode = 'P0001';
      end if;
      select * into v_product from public.products p where p.organization_id = p_organization_id and p.sku = v_sku and p.active for share;
      if not found or v_product.kind <> 'ITEM'::public.product_kind then
        raise exception 'Opening stock product % is not an active stock item.', v_sku using errcode = 'P0001';
      end if;
      v_line_number := v_line_number + 1;
      v_line_id := gen_random_uuid();
      v_value := v_value + round(v_qty * v_cost, 2);
      insert into public.document_lines (id, document_id, organization_id, line_number, product_id, description, quantity, unit_price, unit_cost, line_total, cost_of_goods, metadata)
      values (v_line_id, v_document_id, p_organization_id, v_line_number, v_product.id, v_product.name, round(v_qty,4), 0, round(v_cost,2), 0, 0,
        jsonb_build_object('sku', v_product.sku::text, 'opening', true));
      insert into public.inventory_lots (organization_id, location_id, product_id, source_document_id, source_line_id, received_on, received_quantity, quantity_remaining, unit_cost, reference, notes)
      values (p_organization_id, v_location_id, v_product.id, v_document_id, v_line_id, v_date, round(v_qty,4), round(v_qty,4), round(v_cost,2), v_doc_no,
        nullif(btrim(coalesce(p_opening->>'notes', '')), '')) returning id into v_opening_lot_id;
      insert into public.inventory_movements (organization_id, location_id, product_id, lot_id, document_id, document_line_id, kind, occurred_on, quantity_delta, unit_cost, notes, created_by)
      values (p_organization_id, v_location_id, v_product.id, v_opening_lot_id, v_document_id, v_line_id, 'OPENING'::public.inventory_movement_kind, v_date, round(v_qty,4), round(v_cost,2),
        nullif(btrim(coalesce(p_opening->>'notes', '')), ''), auth.uid());
    end loop;
    if v_line_number = 0 then raise exception 'Add at least one opening-stock row.' using errcode = 'P0001'; end if;
    insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, memo, created_by)
    values (p_organization_id, v_document_id, v_date, 'INVENTORY', v_value, 0, 'Opening stock ' || v_doc_no, auth.uid()),
           (p_organization_id, v_document_id, v_date, 'OPENING_EQUITY', 0, v_value, 'Opening stock ' || v_doc_no, auth.uid());
  exception
    when sqlstate 'P0001' then return private.finish_failed_command(v_command_id, p_client_id, sqlerrm, 'USER');
    when unique_violation then return private.finish_failed_command(v_command_id, p_client_id, 'Opening-stock receipt number is already in use. Refresh and retry.', 'USER');
    when others then return private.finish_failed_command(v_command_id, p_client_id, 'Opening stock could not be saved. It was not recorded; retry or review the action.', 'SERVER');
  end;
  v_response := jsonb_build_object('clientId', p_client_id, 'status', 'OK', 'docNo', v_doc_no, 'flags', '[]'::jsonb);
  update public.sync_commands set status = 'SUCCEEDED'::public.command_status, response = v_response, document_id = v_document_id, completed_at = now() where id = v_command_id;
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, client_id, detail)
  values (p_organization_id, auth.uid(), 'OPENING_STOCK_POSTED', 'document', v_document_id, p_client_id,
    jsonb_build_object('documentNumber', v_doc_no, 'value', v_value, 'locationId', v_location_id::text));
  return v_response;
end;
$$;

revoke all on function public.post_sale(uuid, text, jsonb) from public, anon;
revoke all on function public.post_opening_stock(uuid, text, jsonb) from public, anon;
grant execute on function public.post_sale(uuid, text, jsonb) to authenticated;
grant execute on function public.post_opening_stock(uuid, text, jsonb) to authenticated;
