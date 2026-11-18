-- Cashbook Supabase migration 4: safe read models and reviewed product import.
-- These functions expose the existing app's useful JSON shapes without
-- granting a browser raw table access.

create or replace function private.read_location(
  p_organization_id uuid,
  p_requested_location_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_membership public.memberships%rowtype;
begin
  v_membership := private.require_membership(p_organization_id);
  if v_membership.location_id is not null then
    if p_requested_location_id is not null and p_requested_location_id <> v_membership.location_id then
      raise exception 'You do not have access to the selected shop.' using errcode = '42501';
    end if;
    return v_membership.location_id;
  end if;
  return p_requested_location_id;
end;
$$;

create or replace function private.party_balance(
  p_organization_id uuid,
  p_party_id uuid,
  p_kind public.party_kind
)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(
    case
      when p_kind = 'CUSTOMER'::public.party_kind and e.account_code = 'ACCOUNTS_RECEIVABLE' then e.debit - e.credit
      when p_kind = 'SUPPLIER'::public.party_kind and e.account_code = 'ACCOUNTS_PAYABLE' then e.credit - e.debit
      else 0
    end
  ), 0)::numeric(18,2)
  from public.ledger_entries e
  where e.organization_id = p_organization_id
    and e.party_id = p_party_id;
$$;

create or replace function public.get_catalog_snapshot(
  p_organization_id uuid,
  p_location_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_membership public.memberships%rowtype;
  v_location_id uuid;
  v_settings public.organization_settings%rowtype;
  v_org public.organizations%rowtype;
  v_location public.locations%rowtype;
  v_products jsonb;
  v_customers jsonb;
  v_suppliers jsonb;
  v_categories jsonb;
  v_today date;
  v_week date;
  v_month date;
  v_scope_user uuid;
begin
  v_membership := private.require_membership(p_organization_id);
  v_location_id := private.read_location(p_organization_id, p_location_id);
  select * into v_settings from public.organization_settings s where s.organization_id = p_organization_id;
  select * into v_org from public.organizations o where o.id = p_organization_id;
  if v_location_id is not null then
    select * into v_location from public.locations l where l.id = v_location_id;
  end if;

  v_today := (now() at time zone v_org.timezone)::date;
  v_week := v_today - ((extract(isodow from v_today)::integer) - 1);
  v_month := date_trunc('month', v_today)::date;
  v_scope_user := case when v_membership.role = 'REP'::public.cashbook_role then auth.uid() else null end;

  select coalesce(jsonb_agg(jsonb_build_object(
    'sku', x.sku,
    'name', x.name,
    'category', x.category,
    'unit', x.unit,
    'price', x.selling_price,
    'cost', x.display_cost,
    'type', x.kind,
    'editable', x.price_editable,
    'costReady', x.cost_ready,
    'stock', x.stock
  ) order by lower(x.name), x.sku), '[]'::jsonb)
    into v_products
    from (
      select
        p.sku::text as sku,
        p.name,
        p.category,
        p.unit,
        p.selling_price,
        p.kind::text as kind,
        p.price_editable,
        case when p.kind = 'SERVICE'::public.product_kind then p.service_cost
             else coalesce((select sum(l.quantity_remaining * l.unit_cost) / nullif(sum(l.quantity_remaining), 0)
                              from public.inventory_lots l
                             where l.organization_id = p_organization_id
                               and l.product_id = p.id
                               and l.status = 'OPEN'
                               and (v_location_id is null or l.location_id = v_location_id)), 0) end as display_cost,
        case when p.kind = 'SERVICE'::public.product_kind then true
             else exists (select 1 from public.inventory_lots l
                            where l.organization_id = p_organization_id
                              and l.product_id = p.id
                              and l.status = 'OPEN'
                              and l.quantity_remaining > 0
                              and (v_location_id is null or l.location_id = v_location_id)) end as cost_ready,
        case when p.kind = 'SERVICE'::public.product_kind then null
             else coalesce((select sum(m.quantity_delta)
                              from public.inventory_movements m
                             where m.organization_id = p_organization_id
                               and m.product_id = p.id
                               and (v_location_id is null or m.location_id = v_location_id)), 0) end as stock
      from public.products p
      where p.organization_id = p_organization_id and p.active
    ) x;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id::text, 'name', p.name, 'phone', coalesce(p.phone, ''),
      'balance', private.party_balance(p_organization_id, p.id, p.kind)
    ) order by lower(p.name)), '[]'::jsonb)
    into v_customers
    from public.parties p
   where p.organization_id = p_organization_id
     and p.kind = 'CUSTOMER'::public.party_kind
     and p.active;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id::text, 'name', p.name,
      'balance', private.party_balance(p_organization_id, p.id, p.kind)
    ) order by lower(p.name)), '[]'::jsonb)
    into v_suppliers
    from public.parties p
   where p.organization_id = p_organization_id
     and p.kind = 'SUPPLIER'::public.party_kind
     and p.active;

  select coalesce(jsonb_agg(distinct p.category order by p.category), '[]'::jsonb)
    into v_categories
    from public.products p
   where p.organization_id = p_organization_id and p.category <> '';

  return jsonb_build_object(
    'serverTime', now(),
    'today', v_today,
    'version', 'supabase-migration',
    'location', coalesce(v_location.code::text, ''),
    'locationName', coalesce(v_location.name, 'All shops'),
    'permissions', v_membership.permissions,
    'company', v_org.name,
    'currency', v_org.currency_symbol,
    'footer', v_settings.receipt_footer,
    'expenseCategories', v_settings.expense_categories,
    'paymentMethods', v_settings.payment_methods,
    'categories', v_categories,
    'showCompanyTotals', v_membership.role <> 'REP'::public.cashbook_role,
    'oversellPolicy', v_settings.oversell_policy,
    'epoch', v_settings.data_epoch,
    'products', v_products,
    'customers', v_customers,
    'suppliers', case when v_membership.role = 'REP'::public.cashbook_role and not (v_membership.permissions ? 'STOCK_IN') then '[]'::jsonb else v_suppliers end,
    'totals', jsonb_build_object(
      'today', public.sales_totals_for_period(p_organization_id, v_location_id, v_scope_user, v_today, v_today),
      'week', public.sales_totals_for_period(p_organization_id, v_location_id, v_scope_user, v_week, v_today),
      'month', public.sales_totals_for_period(p_organization_id, v_location_id, v_scope_user, v_month, v_today)
    )
  );
end;
$$;

-- Kept public only so PostgREST can invoke it; callers get no direct ledger
-- access and it validates membership through its parent functions.
create or replace function public.sales_totals_for_period(
  p_organization_id uuid,
  p_location_id uuid,
  p_user_id uuid,
  p_from date,
  p_to date
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with sale_docs as (
    select d.id, d.total, d.amount_paid
      from public.documents d
     where d.organization_id = p_organization_id
       and d.kind = 'SALE'::public.document_kind
       and d.status = 'POSTED'::public.document_status
       and d.occurred_on between p_from and p_to
       and (p_location_id is null or d.location_id = p_location_id)
       and (p_user_id is null or d.created_by = p_user_id)
  ), line_totals as (
    select coalesce(sum(l.quantity), 0) as qty, coalesce(sum(l.cost_of_goods), 0) as cogs
      from public.document_lines l
      join sale_docs d on d.id = l.document_id
  )
  select jsonb_build_object(
    'revenue', coalesce((select sum(total) from sale_docs), 0),
    'cashIn', coalesce((select sum(amount_paid) from sale_docs), 0),
    'qty', coalesce((select qty from line_totals), 0),
    'cogs', coalesce((select cogs from line_totals), 0),
    'gross', coalesce((select sum(total) from sale_docs), 0) - coalesce((select cogs from line_totals), 0),
    'expenses', 0,
    'net', coalesce((select sum(total) from sale_docs), 0) - coalesce((select cogs from line_totals), 0)
  );
$$;

-- PostgreSQL resolves functions when they are first called, allowing the
-- snapshot definition above to remain close to the accounting/read model.

create or replace function public.get_dashboard_summary(
  p_organization_id uuid,
  p_location_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_membership public.memberships%rowtype;
  v_location_id uuid;
  v_org public.organizations%rowtype;
  v_settings public.organization_settings%rowtype;
  v_today date;
  v_week date;
  v_month date;
  v_year date;
  v_stock_value numeric;
  v_low_stock jsonb;
  v_receivables numeric;
  v_payables numeric;
begin
  v_membership := private.require_owner(p_organization_id);
  v_location_id := private.read_location(p_organization_id, p_location_id);
  select * into v_org from public.organizations o where o.id = p_organization_id;
  select * into v_settings from public.organization_settings s where s.organization_id = p_organization_id;
  v_today := (now() at time zone v_org.timezone)::date;
  v_week := v_today - ((extract(isodow from v_today)::integer) - 1);
  v_month := date_trunc('month', v_today)::date;
  v_year := date_trunc('year', v_today)::date;

  select coalesce(sum(l.quantity_remaining * l.unit_cost), 0)
    into v_stock_value
    from public.inventory_lots l
   where l.organization_id = p_organization_id
     and l.status = 'OPEN'
     and (v_location_id is null or l.location_id = v_location_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'sku', x.sku, 'name', x.name, 'stock', x.stock, 'reorder', x.reorder_level,
    'unit', x.unit, 'shop', x.location_name
  ) order by x.stock, lower(x.name)), '[]'::jsonb)
    into v_low_stock
    from (
      select p.sku::text as sku, p.name, p.reorder_level, p.unit,
             coalesce(sum(m.quantity_delta), 0) as stock,
             case when v_location_id is null then '' else coalesce((select name from public.locations where id = v_location_id), '') end as location_name
        from public.products p
        left join public.inventory_movements m on m.organization_id = p_organization_id
          and m.product_id = p.id and (v_location_id is null or m.location_id = v_location_id)
       where p.organization_id = p_organization_id
         and p.active and p.kind = 'ITEM'::public.product_kind
       group by p.id, p.sku, p.name, p.reorder_level, p.unit
      having coalesce(sum(m.quantity_delta), 0) <= case when p.reorder_level > 0 then p.reorder_level else 0 end
    ) x;

  select coalesce(sum(greatest(private.party_balance(p_organization_id, p.id, p.kind), 0)), 0)
    into v_receivables
    from public.parties p
   where p.organization_id = p_organization_id and p.kind = 'CUSTOMER'::public.party_kind;
  select coalesce(sum(greatest(private.party_balance(p_organization_id, p.id, p.kind), 0)), 0)
    into v_payables
    from public.parties p
   where p.organization_id = p_organization_id and p.kind = 'SUPPLIER'::public.party_kind;

  return jsonb_build_object(
    'periods', jsonb_build_object('today', v_today, 'week', v_week, 'month', v_month, 'year', v_year),
    'location', coalesce((select code::text from public.locations where id = v_location_id), ''),
    'today', public.sales_totals_for_period(p_organization_id, v_location_id, null, v_today, v_today),
    'week', public.sales_totals_for_period(p_organization_id, v_location_id, null, v_week, v_today),
    'month', public.sales_totals_for_period(p_organization_id, v_location_id, null, v_month, v_today),
    'year', public.sales_totals_for_period(p_organization_id, v_location_id, null, v_year, v_today),
    'receivables', v_receivables,
    'payables', v_payables,
    'stockValue', v_stock_value,
    'lowStock', v_low_stock,
    'productCount', (select count(*) from public.products p where p.organization_id = p_organization_id),
    'flagged', '[]'::jsonb,
    'toReview', '[]'::jsonb,
    'uncosted', '[]'::jsonb,
    'rejected', '[]'::jsonb,
    'closedUntil', v_settings.closed_until
  );
end;
$$;

create or replace function public.preview_product_import(
  p_organization_id uuid,
  p_source_name text,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner public.memberships%rowtype;
  v_batch_id uuid;
  v_raw jsonb;
  v_sequence integer := 0;
  v_sku text;
  v_name text;
  v_category text;
  v_unit text;
  v_type_text text;
  v_kind public.product_kind;
  v_price numeric;
  v_reorder numeric;
  v_errors jsonb;
  v_valid integer := 0;
  v_invalid integer := 0;
begin
  v_owner := private.require_owner(p_organization_id);
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception 'The product import must contain a list of rows.' using errcode = 'P0001';
  end if;
  if jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 5000 then
    raise exception 'Import between 1 and 5,000 products at a time.' using errcode = 'P0001';
  end if;

  insert into public.product_import_batches (organization_id, source_name, created_by)
  values (p_organization_id, left(coalesce(p_source_name, 'product-import.csv'), 240), auth.uid())
  returning id into v_batch_id;

  for v_raw in select value from jsonb_array_elements(p_rows)
  loop
    v_sequence := v_sequence + 1;
    v_sku := upper(btrim(coalesce(v_raw->>'sku', '')));
    v_name := btrim(coalesce(v_raw->>'name', ''));
    v_category := coalesce(nullif(btrim(coalesce(v_raw->>'category', '')), ''), 'General');
    v_unit := btrim(coalesce(v_raw->>'unit', ''));
    v_type_text := upper(coalesce(nullif(btrim(coalesce(v_raw->>'type', '')), ''), 'ITEM'));
    v_price := private.try_numeric(v_raw->>'sellingPrice');
    v_reorder := private.try_numeric(v_raw->>'reorderLevel');
    v_errors := '[]'::jsonb;
    v_kind := null;

    if v_sku = '' then v_errors := v_errors || jsonb_build_array('SKU is required.');
    elsif v_sku !~ '^[A-Z0-9][A-Z0-9._/#-]{0,79}$' then v_errors := v_errors || jsonb_build_array('SKU contains unsupported characters.');
    elsif exists (select 1 from public.products p where p.organization_id = p_organization_id and upper(p.sku::text) = v_sku) then v_errors := v_errors || jsonb_build_array('SKU already exists in the catalogue.');
    elsif exists (select 1 from public.product_import_rows r where r.batch_id = v_batch_id and upper(coalesce(r.sku::text, '')) = v_sku) then v_errors := v_errors || jsonb_build_array('Duplicate SKU in this import.');
    end if;
    if v_name = '' then v_errors := v_errors || jsonb_build_array('Product name is required.'); end if;
    if v_unit = '' then v_errors := v_errors || jsonb_build_array('Unit is required.'); end if;
    if v_price is null or v_price < 0 or v_price > 1000000000000 then v_errors := v_errors || jsonb_build_array('Selling price must be a number from 0 upward.'); end if;
    if (v_reorder is null and nullif(btrim(coalesce(v_raw->>'reorderLevel', '')), '') is not null) or v_reorder < 0 or v_reorder > 1000000000000 then v_errors := v_errors || jsonb_build_array('Reorder level must be a number from 0 upward.'); end if;
    if v_type_text not in ('ITEM', 'SERVICE') then v_errors := v_errors || jsonb_build_array('Type must be ITEM or SERVICE.');
    else v_kind := v_type_text::public.product_kind;
    end if;

    insert into public.product_import_rows (
      batch_id, row_number, raw, sku, name, category, unit, kind, selling_price,
      reorder_level, legacy_drive_file_id, legacy_image_name, validation_errors, valid
    ) values (
      v_batch_id, v_sequence, v_raw, nullif(v_sku, ''), nullif(v_name, ''), v_category,
      nullif(v_unit, ''), v_kind, v_price, coalesce(v_reorder, 0),
      nullif(btrim(coalesce(v_raw->>'legacyDriveFileId', '')), ''),
      nullif(btrim(coalesce(v_raw->>'imageName', '')), ''), v_errors, jsonb_array_length(v_errors) = 0
    );
    if jsonb_array_length(v_errors) = 0 then v_valid := v_valid + 1; else v_invalid := v_invalid + 1; end if;
  end loop;

  update public.product_import_batches
     set status = case when v_invalid = 0 then 'READY' else 'REJECTED' end,
         summary = jsonb_build_object('rows', v_sequence, 'valid', v_valid, 'invalid', v_invalid)
   where id = v_batch_id;
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, detail)
  values (p_organization_id, auth.uid(), 'PRODUCT_IMPORT_PREVIEW', 'product_import_batch', v_batch_id,
    jsonb_build_object('rows', v_sequence, 'valid', v_valid, 'invalid', v_invalid));

  return jsonb_build_object('batchId', v_batch_id::text, 'ok', v_invalid = 0,
    'valid', v_valid, 'invalid', v_invalid,
    'rows', coalesce((select jsonb_agg(jsonb_build_object('row', r.row_number, 'sku', r.sku, 'name', r.name, 'type', r.kind, 'errors', r.validation_errors, 'valid', r.valid) order by r.row_number)
                        from public.product_import_rows r where r.batch_id = v_batch_id), '[]'::jsonb));
end;
$$;

create or replace function public.promote_product_import(
  p_organization_id uuid,
  p_batch_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner public.memberships%rowtype;
  v_batch public.product_import_batches%rowtype;
  v_row public.product_import_rows%rowtype;
  v_product_id uuid;
  v_added integer := 0;
begin
  v_owner := private.require_owner(p_organization_id);
  select * into v_batch from public.product_import_batches b
   where b.id = p_batch_id and b.organization_id = p_organization_id for update;
  if not found then raise exception 'Product import preview was not found.' using errcode = 'P0001'; end if;
  if v_batch.status <> 'READY' then raise exception 'Only a clean, reviewed product preview can be saved.' using errcode = 'P0001'; end if;
  if exists (
    select 1 from public.product_import_rows r
    join public.products p on p.organization_id = p_organization_id and upper(p.sku::text) = upper(r.sku::text)
    where r.batch_id = p_batch_id and r.valid
  ) then
    raise exception 'The product catalogue changed after the preview. Create a new preview before saving.' using errcode = 'P0001';
  end if;

  for v_row in select * from public.product_import_rows r where r.batch_id = p_batch_id and r.valid order by r.row_number
  loop
    insert into public.products (
      organization_id, sku, name, category, unit, kind, selling_price, reorder_level,
      price_editable, service_cost, legacy_drive_file_id, legacy_image_name, created_by
    ) values (
      p_organization_id, v_row.sku, v_row.name, coalesce(v_row.category, 'General'),
      v_row.unit, v_row.kind, round(v_row.selling_price, 2), round(v_row.reorder_level, 4),
      coalesce(v_row.price_editable, false), coalesce(v_row.service_cost, 0),
      v_row.legacy_drive_file_id, v_row.legacy_image_name, auth.uid()
    ) returning id into v_product_id;
    update public.product_import_rows set promoted_product_id = v_product_id where id = v_row.id;
    v_added := v_added + 1;
  end loop;

  update public.product_import_batches
     set status = 'PROMOTED', reviewed_by = auth.uid(), reviewed_at = now(), promoted_at = now()
   where id = p_batch_id;
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, detail)
  values (p_organization_id, auth.uid(), 'PRODUCT_IMPORT_PROMOTED', 'product_import_batch', p_batch_id,
    jsonb_build_object('added', v_added));
  return jsonb_build_object('batchId', p_batch_id::text, 'added', v_added, 'skipped', '[]'::jsonb);
end;
$$;

revoke all on function private.read_location(uuid, uuid) from public;
revoke all on function private.party_balance(uuid, uuid, public.party_kind) from public;
revoke all on function public.sales_totals_for_period(uuid, uuid, uuid, date, date) from public, anon, authenticated;
revoke all on function public.get_catalog_snapshot(uuid, uuid) from public, anon;
revoke all on function public.get_dashboard_summary(uuid, uuid) from public, anon;
revoke all on function public.preview_product_import(uuid, text, jsonb) from public, anon;
revoke all on function public.promote_product_import(uuid, uuid) from public, anon;
grant execute on function public.get_catalog_snapshot(uuid, uuid) to authenticated;
grant execute on function public.get_dashboard_summary(uuid, uuid) to authenticated;
grant execute on function public.preview_product_import(uuid, text, jsonb) to authenticated;
grant execute on function public.promote_product_import(uuid, uuid) to authenticated;
