-- Cashbook Supabase migration 7: production operations that sit beside the
-- immutable accounting engine.
--
-- This file intentionally does not grant browser table access.  The Edge
-- compatibility function remains responsible for Supabase Auth user creation,
-- password resets and private Storage.  These RPCs only validate the owner or
-- staff JWT, preserve a durable audit trail, and make the current Apps Script
-- screens safe to run against the relational core.

-- Owner-maintained recipients are operational data, not ledger data.  They
-- are kept in the tenant database so a sales representative can prepare (but
-- never silently send) the daily WhatsApp summary for the approved people.
create table public.whatsapp_recipients (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 160),
  whatsapp text not null check (whatsapp ~ '^[0-9]{8,15}$'),
  position text not null check (position in ('Chairman', 'CEO')),
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, whatsapp)
);
create index whatsapp_recipients_org_active_idx
  on public.whatsapp_recipients (organization_id, active, position, name);
create trigger whatsapp_recipients_touch_updated_at before update on public.whatsapp_recipients
for each row execute function private.touch_updated_at();
alter table public.whatsapp_recipients enable row level security;
revoke all on public.whatsapp_recipients from anon, authenticated;

-- This target lookup is deliberately separate from the mutating operation.
-- The Edge function calls it immediately before using the service-role Admin
-- API for a PIN reset, so it can never reset an arbitrary Supabase Auth user.
create or replace function public.assert_manageable_cashbook_user(
  p_organization_id uuid,
  p_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_membership public.memberships%rowtype;
  v_profile public.profiles%rowtype;
begin
  perform private.require_owner(p_organization_id);
  select m.* into v_membership
    from public.memberships m
   where m.organization_id = p_organization_id and m.user_id = p_user_id
   for share;
  if not found then
    raise exception 'That account is not part of this business.' using errcode = 'P0001';
  end if;
  if not v_membership.active then
    raise exception 'Switch this account on before resetting its PIN.' using errcode = 'P0001';
  end if;
  select * into v_profile from public.profiles where user_id = p_user_id;
  if not found then
    raise exception 'That account profile is incomplete. Contact an administrator.' using errcode = 'P0001';
  end if;
  return jsonb_build_object(
    'userId', p_user_id::text,
    'username', v_profile.username::text,
    'email', coalesce(v_profile.email::text, ''),
    'role', v_membership.role::text,
    'active', v_membership.active
  );
end;
$$;

-- The Edge function creates an Auth account first (or updates one through
-- the Admin API) and then invokes this function using the authenticated
-- owner's JWT.  Keeping this database half owner-checked prevents a service
-- implementation bug from silently assigning an unrelated Auth account to a
-- business.
create or replace function public.upsert_cashbook_user_profile(
  p_organization_id uuid,
  p_user_id uuid,
  p_user jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner public.memberships%rowtype;
  v_profile public.profiles%rowtype;
  v_membership public.memberships%rowtype;
  v_auth_email text;
  v_username text;
  v_display_name text;
  v_email text;
  v_role_text text;
  v_role public.cashbook_role;
  v_active boolean;
  v_location_id uuid;
  v_location_text text;
  v_permissions jsonb := '[]'::jsonb;
  v_permission text;
  v_had_profile boolean := false;
  v_had_membership boolean := false;
  v_boolean_text text;
begin
  v_owner := private.require_owner(p_organization_id);
  if p_user_id is null then
    raise exception 'A staff account is required.' using errcode = 'P0001';
  end if;
  if p_user is null or jsonb_typeof(p_user) <> 'object' then
    raise exception 'Staff account details are required.' using errcode = 'P0001';
  end if;

  select lower(nullif(btrim(u.email), '')) into v_auth_email
    from auth.users u where u.id = p_user_id;
  if v_auth_email is null then
    raise exception 'The authentication account was not found. Create the account again.' using errcode = 'P0001';
  end if;

  select * into v_profile from public.profiles where user_id = p_user_id for update;
  v_had_profile := found;
  select * into v_membership
    from public.memberships m
   where m.organization_id = p_organization_id and m.user_id = p_user_id
   for update;
  v_had_membership := found;

  v_username := lower(nullif(btrim(coalesce(p_user->>'username', case when v_had_profile then v_profile.username::text else '' end)), ''));
  v_display_name := nullif(btrim(coalesce(p_user->>'fullName', p_user->>'displayName', case when v_had_profile then v_profile.display_name else '' end)), '');
  v_email := lower(nullif(btrim(coalesce(p_user->>'email', v_auth_email)), ''));
  if v_username is null or v_username !~ '^[a-z0-9][a-z0-9._-]{2,59}$' then
    raise exception 'Username must use 3–60 lowercase letters, numbers, dot, underscore, or dash.' using errcode = 'P0001';
  end if;
  if v_display_name is null or char_length(v_display_name) > 160 then
    raise exception 'Full name is required and may not exceed 160 characters.' using errcode = 'P0001';
  end if;
  if v_email is distinct from v_auth_email then
    raise exception 'The account email must match its Supabase Auth email.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.profiles p where p.username = v_username and p.user_id <> p_user_id) then
    raise exception 'That username is already in use.' using errcode = 'P0001';
  end if;

  v_role_text := upper(nullif(btrim(coalesce(p_user->>'role', case when v_had_membership then v_membership.role::text else 'REP' end)), ''));
  if v_role_text not in ('OWNER', 'REP') then
    raise exception 'Choose Owner / manager or Sales staff.' using errcode = 'P0001';
  end if;
  v_role := v_role_text::public.cashbook_role;

  if p_user ? 'active' then
    v_boolean_text := lower(btrim(coalesce(p_user->>'active', '')));
    if v_boolean_text not in ('true', 'false') then
      raise exception 'Account status must be on or off.' using errcode = 'P0001';
    end if;
    v_active := (v_boolean_text = 'true');
  elsif v_had_membership then
    v_active := v_membership.active;
  else
    v_active := true;
  end if;

  -- Do not strand the organization without an active owner.  An owner may
  -- edit their own name, PIN or email through Auth, but cannot remove the
  -- final account able to administer the books.
  if v_had_membership and v_membership.role = 'OWNER'::public.cashbook_role and v_membership.active
     and ((not v_active) or v_role <> 'OWNER'::public.cashbook_role)
     and not exists (
       select 1 from public.memberships m
        where m.organization_id = p_organization_id and m.active
          and m.role = 'OWNER'::public.cashbook_role and m.user_id <> p_user_id
     ) then
    raise exception 'You cannot switch off or demote the last owner account.' using errcode = 'P0001';
  end if;

  if v_role = 'REP'::public.cashbook_role then
    v_location_text := nullif(btrim(coalesce(p_user->>'location', case when v_had_membership then v_membership.location_id::text else '' end)), '');
    v_location_id := private.owner_location(p_organization_id, v_location_text, false);
    if p_user ? 'permissions' then
      if jsonb_typeof(p_user->'permissions') <> 'array' then
        raise exception 'Permissions must be a list.' using errcode = 'P0001';
      end if;
      for v_permission in select value from jsonb_array_elements_text(p_user->'permissions') x(value)
      loop
        v_permission := upper(btrim(v_permission));
        if v_permission not in ('STOCK_IN', 'ADD_PRODUCT') then
          raise exception 'Unknown staff permission.' using errcode = 'P0001';
        end if;
        if not (v_permissions ? v_permission) then
          v_permissions := v_permissions || jsonb_build_array(v_permission);
        end if;
      end loop;
    elsif v_had_membership and v_membership.role = 'REP'::public.cashbook_role then
      v_permissions := coalesce(v_membership.permissions, '[]'::jsonb);
    end if;
  else
    -- Owners manage all active shops.  Keeping this null is intentional: a
    -- location-bound owner cannot see full reports or resolve cross-shop work.
    v_location_id := null;
    v_permissions := '[]'::jsonb;
  end if;

  insert into public.profiles (user_id, username, display_name, email)
  values (p_user_id, v_username, v_display_name, v_email)
  on conflict (user_id) do update
    set username = excluded.username,
        display_name = excluded.display_name,
        email = excluded.email;

  insert into public.memberships (organization_id, user_id, role, location_id, permissions, active)
  values (p_organization_id, p_user_id, v_role, v_location_id, v_permissions, v_active)
  on conflict (organization_id, user_id) do update
    set role = excluded.role,
        location_id = excluded.location_id,
        permissions = excluded.permissions,
        active = excluded.active;

  update public.organization_settings
     set data_epoch = data_epoch + 1
   where organization_id = p_organization_id;
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, detail)
  values (
    p_organization_id, auth.uid(),
    case when v_had_membership then 'STAFF_ACCOUNT_UPDATED' else 'STAFF_ACCOUNT_CREATED' end,
    'user', p_user_id,
    jsonb_build_object('username', v_username, 'role', v_role::text,
      'locationId', coalesce(v_location_id::text, ''), 'active', v_active,
      'permissions', v_permissions)
  );
  return jsonb_build_object(
    'saved', true, 'userId', p_user_id::text, 'username', v_username,
    'fullName', v_display_name, 'email', v_email, 'role', v_role::text,
    'location', coalesce(v_location_id::text, ''), 'permissions', v_permissions,
    'active', v_active
  );
end;
$$;

-- Staff-created products do not become sellable automatically.  They are
-- inactive until an owner reviews them through `upsert_product`, which keeps
-- an offline rep's retry durable without allowing uncosted goods into a sale.
create or replace function public.post_staff_product_request(
  p_organization_id uuid,
  p_client_id text,
  p_product jsonb
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
  v_sku text;
  v_name text;
  v_category text;
  v_unit text;
  v_kind public.product_kind;
  v_price numeric;
  v_reorder numeric;
  v_price_editable boolean := false;
  v_product public.products%rowtype;
  v_response jsonb;
begin
  if nullif(btrim(coalesce(p_client_id, '')), '') is null or char_length(btrim(p_client_id)) > 200 then
    return jsonb_build_object('clientId', coalesce(p_client_id, ''), 'status', 'ERROR', 'message', 'This saved product needs a valid client reference.');
  end if;
  v_membership := private.require_membership(p_organization_id);
  v_started := private.begin_cashbook_command(p_organization_id, p_client_id, 'ADD_PRODUCT', p_product);
  if coalesce((v_started->>'duplicate')::boolean, false) then
    return v_started->'response';
  end if;
  v_command_id := (v_started->>'commandId')::uuid;
  begin
    if v_membership.role = 'REP'::public.cashbook_role and not (coalesce(v_membership.permissions, '[]'::jsonb) ? 'ADD_PRODUCT') then
      raise exception 'You are not permitted to add products.' using errcode = 'P0001';
    end if;
    if p_product is null or jsonb_typeof(p_product) <> 'object' then
      raise exception 'Product details are required.' using errcode = 'P0001';
    end if;
    v_sku := upper(btrim(coalesce(p_product->>'sku', '')));
    v_name := btrim(coalesce(p_product->>'name', ''));
    v_category := btrim(coalesce(p_product->>'category', ''));
    v_kind := case upper(coalesce(p_product->>'kind', p_product->>'type', 'ITEM'))
      when 'SERVICE' then 'SERVICE'::public.product_kind else 'ITEM'::public.product_kind end;
    v_unit := left(coalesce(nullif(btrim(p_product->>'unit'), ''), case when v_kind = 'SERVICE'::public.product_kind then 'job' else 'unit' end), 60);
    v_price := coalesce(private.try_numeric(p_product->>'price'), private.try_numeric(p_product->>'sellingPrice'));
    v_reorder := coalesce(private.try_numeric(p_product->>'reorder'), private.try_numeric(p_product->>'reorderLevel'), 0);
    if v_sku !~ '^[A-Z0-9._/#-]{1,40}$' then
      raise exception 'SKU may contain 1–40 letters, numbers, dot, underscore, slash, hash or dash characters.' using errcode = 'P0001';
    end if;
    if char_length(v_name) < 1 or char_length(v_name) > 240 then
      raise exception 'Product name is required and may not exceed 240 characters.' using errcode = 'P0001';
    end if;
    if char_length(v_category) < 1 or char_length(v_category) > 160 then
      raise exception 'Choose a category of up to 160 characters.' using errcode = 'P0001';
    end if;
    if v_price is null or v_price < 0 or v_price > 1000000000 then
      raise exception 'Enter a valid selling price.' using errcode = 'P0001';
    end if;
    if v_reorder < 0 or abs(v_reorder - round(v_reorder, 4)) > 0.00000001 then
      raise exception 'Reorder level must be zero or more with up to four decimal places.' using errcode = 'P0001';
    end if;
    if p_product ? 'priceEditable' then
      v_price_editable := coalesce((p_product->>'priceEditable')::boolean, false);
    end if;
    if exists (select 1 from public.products p where p.organization_id = p_organization_id and p.sku = v_sku) then
      raise exception 'A product with SKU % already exists. Search for it instead of adding another one.', v_sku using errcode = 'P0001';
    end if;
    insert into public.products (
      organization_id, sku, name, category, unit, kind, selling_price,
      reorder_level, price_editable, service_cost, default_unit_cost, active,
      reviewed, reviewed_at, created_by
    ) values (
      p_organization_id, v_sku, v_name, v_category, v_unit, v_kind,
      round(v_price, 2), case when v_kind = 'SERVICE'::public.product_kind then 0 else round(v_reorder, 4) end,
      case when v_kind = 'SERVICE'::public.product_kind then v_price_editable else false end,
      0, 0, false, false, null, auth.uid()
    ) returning * into v_product;
  exception
    when sqlstate 'P0001' then
      return private.finish_failed_command(v_command_id, p_client_id, sqlerrm, 'USER');
    when unique_violation then
      return private.finish_failed_command(v_command_id, p_client_id, 'That product code already exists. Refresh and search before retrying.', 'USER');
    when others then
      return private.finish_failed_command(v_command_id, p_client_id, 'The product request could not be saved. It was not recorded; retry or review the action.', 'SERVER');
  end;
  v_response := jsonb_build_object(
    'clientId', p_client_id, 'status', 'OK', 'docNo', '', 'sku', v_product.sku::text,
    'flags', jsonb_build_array('NEW_PRODUCT_REVIEW'), 'total', v_product.selling_price, 'paid', 0
  );
  perform private.complete_cashbook_command(v_command_id, null, v_response);
  update public.organization_settings set data_epoch = data_epoch + 1 where organization_id = p_organization_id;
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, client_id, detail)
  values (p_organization_id, auth.uid(), 'STAFF_PRODUCT_REQUESTED', 'product', v_product.id, p_client_id,
    jsonb_build_object('sku', v_product.sku::text, 'name', v_product.name, 'kind', v_product.kind::text));
  return v_response;
end;
$$;

create or replace function public.get_whatsapp_recipients(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_membership(p_organization_id);
  return jsonb_build_object('rows', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', r.id::text, 'name', r.name, 'whatsapp', r.whatsapp,
      'position', r.position
    ) order by case when r.position = 'Chairman' then 0 else 1 end, lower(r.name))
      from public.whatsapp_recipients r
     where r.organization_id = p_organization_id and r.active
  ), '[]'::jsonb));
end;
$$;

-- Saving uses replace-as-a-set semantics.  Missing rows are made inactive,
-- rather than deleted, so a recipient change remains explainable in audit.
create or replace function public.save_whatsapp_recipients(
  p_organization_id uuid,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row jsonb;
  v_name text;
  v_whatsapp text;
  v_position text;
  -- Object keys make the duplicate check exact; using a JSON array here would
  -- not detect a number stored inside an object appended to that array.
  v_seen jsonb := '{}'::jsonb;
  v_count integer := 0;
begin
  perform private.require_owner(p_organization_id);
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    raise exception 'Recipients must be a list.' using errcode = 'P0001';
  end if;
  if jsonb_array_length(p_rows) > 50 then
    raise exception 'Add no more than 50 approved recipients.' using errcode = 'P0001';
  end if;

  -- Validate every row before changing the active set.
  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_name := nullif(btrim(coalesce(v_row->>'name', '')), '');
    v_whatsapp := regexp_replace(coalesce(v_row->>'whatsapp', v_row->>'number', ''), '[^0-9]', '', 'g');
    v_position := case lower(btrim(coalesce(v_row->>'position', '')))
      when 'chairman' then 'Chairman' when 'ceo' then 'CEO' else null end;
    if v_name is null or char_length(v_name) > 160 then
      raise exception 'Each recipient needs a name of up to 160 characters.' using errcode = 'P0001';
    end if;
    if v_whatsapp !~ '^[0-9]{8,15}$' then
      raise exception 'Each WhatsApp number needs 8–15 digits including its country code.' using errcode = 'P0001';
    end if;
    if v_position is null then
      raise exception 'Only Chairman and CEO recipients may receive a sales summary.' using errcode = 'P0001';
    end if;
    if v_seen ? v_whatsapp then
      raise exception 'Each WhatsApp number may appear once.' using errcode = 'P0001';
    end if;
    v_seen := v_seen || jsonb_build_object(v_whatsapp, true);
  end loop;

  update public.whatsapp_recipients
     set active = false
   where organization_id = p_organization_id and active;
  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_name := btrim(v_row->>'name');
    v_whatsapp := regexp_replace(coalesce(v_row->>'whatsapp', v_row->>'number', ''), '[^0-9]', '', 'g');
    v_position := case lower(btrim(v_row->>'position')) when 'chairman' then 'Chairman' else 'CEO' end;
    insert into public.whatsapp_recipients (organization_id, name, whatsapp, position, active, created_by)
    values (p_organization_id, v_name, v_whatsapp, v_position, true, auth.uid())
    on conflict (organization_id, whatsapp) do update
      set name = excluded.name, position = excluded.position, active = true;
    v_count := v_count + 1;
  end loop;
  insert into public.audit_events (organization_id, actor_id, action, entity_type, detail)
  values (p_organization_id, auth.uid(), 'WHATSAPP_RECIPIENTS_SAVED', 'recipient_list',
    jsonb_build_object('activeRecipients', v_count));
  return public.get_whatsapp_recipients(p_organization_id);
end;
$$;

-- A non-destructive consistency check.  It is intentionally read-only: the
-- append-only ledger is the evidence, and an automated "repair" must never
-- invent balancing rows or rewrite historical FIFO allocations.
create or replace function public.get_integrity_check(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_issues jsonb;
begin
  perform private.require_owner(p_organization_id);
  with issues as (
    select 'LEDGER_IMBALANCE'::text as kind,
           'Ledger is not balanced for ' || d.document_number as msg,
           'Do not post further corrections for this record. Export the audit trail and contact support.' as hint
      from public.documents d
      join public.ledger_entries e on e.document_id = d.id
     where d.organization_id = p_organization_id
     group by d.id, d.document_number
    having round(coalesce(sum(e.debit), 0) - coalesce(sum(e.credit), 0), 2) <> 0
    union all
    select 'MISSING_LEDGER', 'Posted document ' || d.document_number || ' has no ledger entries',
           'This should never occur. Preserve the database logs and contact support.'
      from public.documents d
     where d.organization_id = p_organization_id and d.status = 'POSTED'::public.document_status
       and not exists (select 1 from public.ledger_entries e where e.document_id = d.id)
    union all
    select 'PAYMENT_MISMATCH', 'Payment total differs from document ' || d.document_number,
           'Check the document and payment audit trail before posting any correction.'
      from public.documents d
      left join public.payments p on p.document_id = d.id
     where d.organization_id = p_organization_id and d.status = 'POSTED'::public.document_status
     group by d.id, d.document_number, d.amount_paid
    having round(coalesce(sum(p.amount), 0), 2) <> round(d.amount_paid, 2)
    union all
    select 'STOCK_LOT_MISMATCH', 'Stock movements and FIFO lots differ for ' || p.sku::text || ' at ' || l.name,
           'Do not overwrite stock. Review the stock card and audit log, then use an audited correction if appropriate.'
      from (
        select coalesce(m.organization_id, il.organization_id) as organization_id,
               coalesce(m.location_id, il.location_id) as location_id,
               coalesce(m.product_id, il.product_id) as product_id,
               coalesce(m.quantity, 0) as movement_qty,
               coalesce(il.quantity, 0) as lot_qty
          from (
            select organization_id, location_id, product_id, sum(quantity_delta) as quantity
              from public.inventory_movements where organization_id = p_organization_id
             group by organization_id, location_id, product_id
          ) m
          full join (
            select organization_id, location_id, product_id, sum(quantity_remaining) as quantity
              from public.inventory_lots where organization_id = p_organization_id
             group by organization_id, location_id, product_id
          ) il on il.organization_id = m.organization_id and il.location_id = m.location_id and il.product_id = m.product_id
      ) x
      join public.products p on p.id = x.product_id
      join public.locations l on l.id = x.location_id
     where abs(x.movement_qty - x.lot_qty) > 0.0001
    union all
    select 'RETURN_ALLOCATION_EXCESS', 'A return allocation exceeds the source sale allocation.',
           'Do not process another return for this sale until support has reviewed the immutable allocation trail.'
      from public.return_allocations r
      join public.document_lines sl on sl.id = r.source_sale_line_id
      left join public.lot_allocations a on a.sale_line_id = r.source_sale_line_id and a.lot_id = r.lot_id
     where r.organization_id = p_organization_id
     group by r.source_sale_line_id, r.lot_id, a.quantity
    having sum(r.quantity) > coalesce(a.quantity, 0) + 0.0001
    union all
    select 'STUCK_SYNC_COMMAND', 'A saved browser command is still processing.',
           'Open Sync centre on the originating device. Do not create a second sale, payment, or purchase.'
      from public.sync_commands c
     where c.organization_id = p_organization_id and c.status = 'PROCESSING'::public.command_status
       and c.created_at < now() - interval '15 minutes'
  )
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'msg', msg, 'hint', hint) order by kind, msg), '[]'::jsonb)
    into v_issues from issues;
  return jsonb_build_object('ok', jsonb_array_length(v_issues) = 0, 'issues', v_issues, 'checkedAt', now());
end;
$$;

-- The legacy UI offers a Repair button.  In the Supabase architecture it is a
-- safe re-check: immutable accounting needs an explicit, reviewed adjustment,
-- not a blind rewrite of ledger or FIFO facts.
create or replace function public.recalculate_cashbook_read_models(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_check jsonb;
begin
  perform private.require_owner(p_organization_id);
  v_check := public.get_integrity_check(p_organization_id);
  return jsonb_build_object(
    'fixed', 0,
    'remaining', coalesce(v_check->'issues', '[]'::jsonb),
    'details', jsonb_build_array('No automatic ledger or FIFO rewrite was performed. Use an audited correction or contact support for an integrity issue.'),
    'message', 'Read models are calculated from immutable accounting records; no destructive repair is available.'
  );
end;
$$;

-- A production reset is intentionally not an in-app write.  The preview lets
-- the existing screen explain the scope, while the Edge layer can direct an
-- owner to a reviewed backup/PITR runbook instead of deleting a live ledger.
create or replace function public.get_reset_preview(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_owner(p_organization_id);
  return jsonb_build_object(
    'canReset', false,
    'message', 'Factory reset is disabled for a production Supabase cashbook. Restore a verified backup into a separate project and reconcile deliberately.',
    'scopes', jsonb_build_object(
      'transactions', 'Transactions and stock layers',
      'products', 'Products and services',
      'parties', 'Customers and suppliers',
      'staff', 'Other staff accounts',
      'shops', 'Extra shops',
      'audit', 'Audit log',
      'settings', 'Business settings'
    ),
    'counts', jsonb_build_object(
      'transactions', (select count(*) from public.documents where organization_id = p_organization_id),
      'batches', (select count(*) from public.inventory_lots where organization_id = p_organization_id),
      'products', (select count(*) from public.products where organization_id = p_organization_id),
      'parties', (select count(*) from public.parties where organization_id = p_organization_id),
      'staff', (select count(*) from public.memberships where organization_id = p_organization_id and user_id <> auth.uid()),
      'shops', (select greatest(count(*) - 1, 0) from public.locations where organization_id = p_organization_id),
      'audit', (select count(*) from public.audit_events where organization_id = p_organization_id)
    )
  );
end;
$$;

-- Correcting the incoming cost is not a historical sale rewrite.  If asked,
-- this function revalues only quantity still in open FIFO lots and posts the
-- balancing inventory/gain-or-loss entries in a zero-cash adjustment record.
create or replace function public.reset_purchase_costs(
  p_organization_id uuid,
  p_updates jsonb,
  p_apply_to_stock boolean default true,
  p_reason text default '',
  p_confirmation text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner public.memberships%rowtype;
  v_update jsonb;
  v_product public.products%rowtype;
  v_sku text;
  v_cost numeric(18,2);
  v_location_id uuid;
  v_seen jsonb := '{}'::jsonb;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
  v_date date;
  v_document_id uuid;
  v_doc_no text;
  v_line_no integer := 0;
  v_lot public.inventory_lots%rowtype;
  v_delta numeric(18,2);
  v_updated integer := 0;
  v_revalued numeric(18,4) := 0;
  v_details jsonb := '[]'::jsonb;
begin
  v_owner := private.require_owner(p_organization_id);
  if p_updates is null or jsonb_typeof(p_updates) <> 'array' or jsonb_array_length(p_updates) = 0 then
    raise exception 'Select at least one product whose purchase cost you want to reset.' using errcode = 'P0001';
  end if;
  if jsonb_array_length(p_updates) > 500 then
    raise exception 'Too many products in one cost reset (max 500).' using errcode = 'P0001';
  end if;
  if upper(btrim(coalesce(p_confirmation, ''))) <> 'RESET COSTS' then
    raise exception 'Type RESET COSTS to confirm this cost update.' using errcode = 'P0001';
  end if;
  if v_reason is null or char_length(v_reason) < 3 or char_length(v_reason) > 160 then
    raise exception 'Please give a short reason of 3–160 characters for the cost update.' using errcode = 'P0001';
  end if;
  v_date := private.cashbook_posting_date(p_organization_id, null, 'cost correction date');
  perform pg_advisory_xact_lock(hashtextextended(p_organization_id::text || ':purchase-cost-reset', 0));

  -- Validate and update the future purchase costs first.  Any later raised
  -- exception rolls the full function back, including these updates.
  for v_update in select value from jsonb_array_elements(p_updates)
  loop
    v_sku := upper(btrim(coalesce(v_update->>'sku', '')));
    v_cost := private.try_numeric(coalesce(v_update->>'cost', v_update->>'unitCost'));
    if v_sku = '' or v_cost is null or v_cost <= 0 or v_cost > 1000000000 then
      raise exception 'Each selected product needs a purchase cost above zero.' using errcode = 'P0001';
    end if;
    if v_seen ? v_sku then
      raise exception 'Each product may appear only once in a cost reset.' using errcode = 'P0001';
    end if;
    v_seen := v_seen || jsonb_build_object(v_sku, true);
    select * into v_product from public.products p
     where p.organization_id = p_organization_id and p.sku = v_sku for update;
    if not found or v_product.kind <> 'ITEM'::public.product_kind then
      raise exception 'Unknown stock item: %.', v_sku using errcode = 'P0001';
    end if;
    perform private.owner_location(p_organization_id, nullif(btrim(coalesce(v_update->>'location', '')), ''), true);
    update public.products set default_unit_cost = round(v_cost, 2), reviewed = true, reviewed_at = now() where id = v_product.id;
    v_updated := v_updated + 1;
  end loop;

  if coalesce(p_apply_to_stock, true) then
    for v_update in select value from jsonb_array_elements(p_updates)
    loop
      v_sku := upper(btrim(v_update->>'sku'));
      v_cost := round(private.try_numeric(coalesce(v_update->>'cost', v_update->>'unitCost')), 2);
      v_location_id := private.owner_location(p_organization_id, nullif(btrim(coalesce(v_update->>'location', '')), ''), true);
      select * into v_product from public.products p where p.organization_id = p_organization_id and p.sku = v_sku;
      for v_lot in
        select * from public.inventory_lots l
         where l.organization_id = p_organization_id and l.product_id = v_product.id
           and l.status = 'OPEN' and l.quantity_remaining > 0
           and (v_location_id is null or l.location_id = v_location_id)
         order by l.location_id, l.received_on, l.created_at, l.id
         for update
      loop
        v_delta := round((v_cost - v_lot.unit_cost) * v_lot.quantity_remaining, 2);
        if v_delta = 0 then continue; end if;
        if v_document_id is null then
          v_doc_no := 'CRV-' || to_char(v_date, 'YYYYMMDD') || '-' || upper(substr(md5(random()::text), 1, 8));
          insert into public.documents (
            organization_id, kind, document_number, occurred_on, subtotal, total,
            amount_paid, balance_due, notes, metadata, flags, created_by
          ) values (
            p_organization_id, 'STOCK_ADJUSTMENT'::public.document_kind, v_doc_no, v_date,
            0, 0, 0, 0, v_reason,
            jsonb_build_object('workflow', 'PURCHASE_COST_RESET', 'reason', v_reason),
            jsonb_build_array('COST_REVALUATION'), auth.uid()
          ) returning id into v_document_id;
        end if;
        v_line_no := v_line_no + 1;
        insert into public.document_lines (
          document_id, organization_id, line_number, product_id, description, quantity,
          unit_price, unit_cost, line_total, cost_of_goods, metadata
        ) values (
          v_document_id, p_organization_id, v_line_no, v_product.id, v_product.name,
          v_lot.quantity_remaining, 0, v_cost, abs(v_delta), 0,
          jsonb_build_object('sku', v_sku, 'lotId', v_lot.id::text, 'oldUnitCost', v_lot.unit_cost,
            'newUnitCost', v_cost, 'valueChange', v_delta, 'reason', v_reason)
        );
        update public.inventory_lots set unit_cost = v_cost where id = v_lot.id;
        if v_delta > 0 then
          insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, product_id, memo, created_by)
          values (p_organization_id, v_document_id, v_date, 'INVENTORY', v_delta, 0, v_product.id, 'Cost revaluation ' || v_doc_no, auth.uid()),
                 (p_organization_id, v_document_id, v_date, 'STOCK_ADJUSTMENT_GAIN', 0, v_delta, v_product.id, 'Cost revaluation gain ' || v_doc_no, auth.uid());
        else
          insert into public.ledger_entries (organization_id, document_id, entry_date, account_code, debit, credit, product_id, memo, created_by)
          values (p_organization_id, v_document_id, v_date, 'INVENTORY_SHRINKAGE', abs(v_delta), 0, v_product.id, 'Cost revaluation loss ' || v_doc_no, auth.uid()),
                 (p_organization_id, v_document_id, v_date, 'INVENTORY', 0, abs(v_delta), v_product.id, 'Cost revaluation ' || v_doc_no, auth.uid());
        end if;
        v_revalued := v_revalued + v_lot.quantity_remaining;
        v_details := v_details || jsonb_build_array(v_sku || ' / ' || v_lot.location_id::text || ' (' || v_lot.quantity_remaining::text || ')');
      end loop;
    end loop;
  end if;
  update public.organization_settings set data_epoch = data_epoch + 1 where organization_id = p_organization_id;
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, detail)
  values (p_organization_id, auth.uid(), 'PURCHASE_COST_RESET', 'product_cost', v_document_id,
    jsonb_build_object('updated', v_updated, 'revaluedQuantity', v_revalued,
      'applyToStock', coalesce(p_apply_to_stock, true), 'reason', v_reason, 'documentNumber', coalesce(v_doc_no, '')));
  return jsonb_build_object('updated', v_updated, 'revalued', v_revalued,
    'docNo', coalesce(v_doc_no, ''), 'applyToStock', coalesce(p_apply_to_stock, true), 'details', v_details);
end;
$$;

revoke all on function public.assert_manageable_cashbook_user(uuid, uuid) from public, anon;
revoke all on function public.upsert_cashbook_user_profile(uuid, uuid, jsonb) from public, anon;
revoke all on function public.post_staff_product_request(uuid, text, jsonb) from public, anon;
revoke all on function public.get_whatsapp_recipients(uuid) from public, anon;
revoke all on function public.save_whatsapp_recipients(uuid, jsonb) from public, anon;
revoke all on function public.get_integrity_check(uuid) from public, anon;
revoke all on function public.recalculate_cashbook_read_models(uuid) from public, anon;
revoke all on function public.get_reset_preview(uuid) from public, anon;
revoke all on function public.reset_purchase_costs(uuid, jsonb, boolean, text, text) from public, anon;

grant execute on function public.assert_manageable_cashbook_user(uuid, uuid) to authenticated;
grant execute on function public.upsert_cashbook_user_profile(uuid, uuid, jsonb) to authenticated;
grant execute on function public.post_staff_product_request(uuid, text, jsonb) to authenticated;
grant execute on function public.get_whatsapp_recipients(uuid) to authenticated;
grant execute on function public.save_whatsapp_recipients(uuid, jsonb) to authenticated;
grant execute on function public.get_integrity_check(uuid) to authenticated;
grant execute on function public.recalculate_cashbook_read_models(uuid) to authenticated;
grant execute on function public.get_reset_preview(uuid) to authenticated;
grant execute on function public.reset_purchase_costs(uuid, jsonb, boolean, text, text) to authenticated;
