-- Cashbook Supabase migration 6: owner administration and read models.
--
-- This migration deliberately keeps all accounting writes in posting command
-- functions.  The routines below provide the owner screens with the same
-- shapes used by the Apps Script implementation while retaining a
-- deny-by-default database: every routine validates membership/ownership and
-- no browser receives table-write privileges.

-- Products need a remembered incoming-cost reference for product editing and
-- for explaining an item that has not yet received a FIFO lot. Historic FIFO
-- lots remain the source of truth for historical sales cost.
alter table public.products
  add column if not exists default_unit_cost numeric(18, 2) not null default 0
    check (default_unit_cost >= 0),
  add column if not exists reviewed boolean not null default true,
  add column if not exists reviewed_at timestamptz;

-- These are operational preferences rather than accounting facts. Keeping
-- them in the one-row settings table lets the Owner UI retain its current
-- configuration contract without adding a browser-writable settings table.
alter table public.organization_settings
  add column if not exists reps_see_company_totals boolean not null default false,
  add column if not exists service_categories jsonb not null default '[]'::jsonb
    check (jsonb_typeof(service_categories) = 'array'),
  add column if not exists alert_email text,
  add column if not exists backup_keep_days integer not null default 60
    check (backup_keep_days >= 7 and backup_keep_days <= 3650);

-- Financial command migrations may attach review flags to documents. The
-- column is optional for the accounting engine but gives the Attention inbox a
-- durable, non-destructive source for records needing review.
alter table public.documents
  add column if not exists flags jsonb not null default '[]'::jsonb
    check (jsonb_typeof(flags) = 'array');

create or replace function private.owner_location(
  p_organization_id uuid,
  p_requested text default null,
  p_allow_all boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_requested text := nullif(btrim(coalesce(p_requested, '')), '');
  v_location_id uuid;
begin
  perform private.require_owner(p_organization_id);
  if v_requested is null then
    if p_allow_all then return null; end if;
    select l.id into v_location_id
      from public.locations l
     where l.organization_id = p_organization_id and l.active
     order by case when upper(l.code::text) = 'MAIN' then 0 else 1 end, l.created_at, l.id
     limit 1;
    if v_location_id is null then
      raise exception 'Choose an active shop.' using errcode = 'P0001';
    end if;
    return v_location_id;
  end if;

  select l.id into v_location_id
    from public.locations l
   where l.organization_id = p_organization_id
     and l.active
     and (l.id::text = v_requested or upper(l.code::text) = upper(v_requested))
   limit 1;
  if v_location_id is null then
    raise exception 'Choose an active shop.' using errcode = 'P0001';
  end if;
  return v_location_id;
end;
$$;

create or replace function private.owner_text_array(p_value jsonb)
returns jsonb
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_text text;
begin
  if p_value is null or p_value = 'null'::jsonb then return '[]'::jsonb; end if;
  if jsonb_typeof(p_value) = 'array' then
    return coalesce((
      select jsonb_agg(value order by lower(value), value)
        from (
          select distinct btrim(value) as value
            from jsonb_array_elements_text(p_value) x(value)
           where btrim(value) <> '' and char_length(btrim(value)) <= 100
        ) normalized
    ), '[]'::jsonb);
  end if;
  if jsonb_typeof(p_value) <> 'string' then
    raise exception 'A settings list must be text or an array.' using errcode = 'P0001';
  end if;
  v_text := trim(both '"' from p_value::text);
  return coalesce((
    select jsonb_agg(value order by lower(value), value)
      from (
        select distinct btrim(value) as value
          from unnest(string_to_array(v_text, ',')) x(value)
         where btrim(value) <> '' and char_length(btrim(value)) <= 100
      ) normalized
  ), '[]'::jsonb);
end;
$$;

create or replace function private.owner_json_list(p_values jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select coalesce(string_agg(value, ', ' order by ordinality), '')
    from jsonb_array_elements_text(coalesce(p_values, '[]'::jsonb)) with ordinality x(value, ordinality);
$$;

-- Command functions retain workflow flags in document metadata; the explicit
-- flags column is also accepted so later command versions can promote a flag
-- without breaking old records.  The UI sees one clean, de-duplicated list.
create or replace function private.owner_document_flags(
  p_flags jsonb,
  p_metadata jsonb
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce((
    select jsonb_agg(value order by value)
      from (
        select distinct btrim(value) as value
          from jsonb_array_elements_text(
            (case when jsonb_typeof(coalesce(p_flags, '[]'::jsonb)) = 'array' then p_flags else '[]'::jsonb end)
            ||
            (case when jsonb_typeof(coalesce(p_metadata->'flags', '[]'::jsonb)) = 'array' then p_metadata->'flags' else '[]'::jsonb end)
          ) x(value)
         where btrim(value) <> ''
      ) normalized
  ), '[]'::jsonb);
$$;

create or replace function private.owner_product_cost(
  p_organization_id uuid,
  p_product_id uuid,
  p_location_id uuid default null
)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select sum(l.quantity_remaining * l.unit_cost) / nullif(sum(l.quantity_remaining), 0)
       from public.inventory_lots l
      where l.organization_id = p_organization_id
        and l.product_id = p_product_id
        and l.status = 'OPEN'
        and l.quantity_remaining > 0
        and (p_location_id is null or l.location_id = p_location_id)),
    (select p.default_unit_cost from public.products p where p.id = p_product_id),
    0
  )::numeric(18,2);
$$;

-- Owner equivalent of Apps Script `lists`: non-financial configuration and
-- presentation data only.  Stock/cost figures are derived from immutable
-- inventory records rather than stored browser totals.
create or replace function public.get_lists(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_settings public.organization_settings%rowtype;
  v_org public.organizations%rowtype;
  v_products jsonb;
  v_parties jsonb;
  v_locations jsonb;
begin
  perform private.require_owner(p_organization_id);
  select * into v_settings from public.organization_settings where organization_id = p_organization_id;
  select * into v_org from public.organizations where id = p_organization_id;

  select coalesce(jsonb_agg(row_to_json(x)::jsonb order by lower(x.name), x.sku), '[]'::jsonb)
    into v_products
    from (
      select p.sku::text as sku, p.name, p.unit, p.category,
             p.selling_price as price,
             case when p.kind = 'SERVICE'::public.product_kind then null
                  else coalesce((select sum(m.quantity_delta) from public.inventory_movements m
                                  where m.organization_id = p_organization_id and m.product_id = p.id), 0) end as stock,
             case when p.kind = 'SERVICE'::public.product_kind then null
                  else coalesce((select jsonb_object_agg(z.location_id::text, z.quantity)
                                  from (
                                    select m.location_id, sum(m.quantity_delta) as quantity
                                      from public.inventory_movements m
                                     where m.organization_id = p_organization_id and m.product_id = p.id
                                     group by m.location_id
                                  ) z), '{}'::jsonb) end as "byLoc",
             private.owner_product_cost(p_organization_id, p.id, null) as "lastCost",
             case when p.kind = 'SERVICE'::public.product_kind then true
                  when exists (select 1 from public.inventory_lots l where l.organization_id = p_organization_id and l.product_id = p.id and l.status = 'OPEN' and l.quantity_remaining > 0)
                       or p.default_unit_cost > 0 then true else false end as "costReady",
             case when p.kind = 'ITEM'::public.product_kind and p.default_unit_cost <= 0
                       and not exists (select 1 from public.inventory_lots l where l.organization_id = p_organization_id and l.product_id = p.id and l.status = 'OPEN' and l.quantity_remaining > 0)
                  then 'Set an incoming cost before selling or adding stock.' else '' end as "costIssue",
             p.active, p.kind::text as type, p.price_editable as editable
        from public.products p
       where p.organization_id = p_organization_id
    ) x;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id::text, 'type', p.kind::text, 'name', p.name,
      'phone', coalesce(p.phone, ''), 'address', coalesce(p.address, ''),
      'creditLimit', p.credit_limit, 'balance', private.party_balance(p_organization_id, p.id, p.kind), 'active', p.active
    ) order by p.kind, lower(p.name)), '[]'::jsonb)
    into v_parties
    from public.parties p where p.organization_id = p_organization_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id', l.id::text, 'name', l.name, 'address', coalesce(l.address, ''), 'active', l.active, 'code', l.code::text
    ) order by case when upper(l.code::text) = 'MAIN' then 0 else 1 end, lower(l.name)), '[]'::jsonb)
    into v_locations
    from public.locations l where l.organization_id = p_organization_id;

  return jsonb_build_object(
    'products', v_products,
    'parties', v_parties,
    'locations', v_locations,
    'currency', v_org.currency_symbol,
    'company', v_org.name,
    'targetMargin', v_settings.target_margin_pct,
    'categories', coalesce((select jsonb_agg(category order by lower(category)) from (select distinct p.category from public.products p where p.organization_id = p_organization_id and p.category <> '') c(category)), '[]'::jsonb),
    'expenseCategories', v_settings.expense_categories,
    'paymentMethods', v_settings.payment_methods,
    'footer', v_settings.receipt_footer,
    'closedUntil', v_settings.closed_until,
    'permissions', jsonb_build_array('STOCK_IN', 'ADD_PRODUCT'),
    'oversellPolicy', v_settings.oversell_policy,
    'epoch', v_settings.data_epoch
  );
end;
$$;

create or replace function public.get_products(
  p_organization_id uuid,
  p_location text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
  v_settings public.organization_settings%rowtype;
  v_rows jsonb;
  v_stock_value numeric(18,2);
begin
  v_location_id := private.owner_location(p_organization_id, p_location, true);
  select * into v_settings from public.organization_settings where organization_id = p_organization_id;

  select coalesce(jsonb_agg(row_to_json(x)::jsonb order by lower(x.name), x.sku), '[]'::jsonb)
    into v_rows
    from (
      select p.sku::text as sku, p.name, p.category, p.unit, p.selling_price as price,
             p.reorder_level as reorder, p.active, p.kind::text as type,
             case when p.kind = 'SERVICE'::public.product_kind then null
                  else coalesce((select sum(m.quantity_delta) from public.inventory_movements m where m.organization_id = p_organization_id and m.product_id = p.id and (v_location_id is null or m.location_id = v_location_id)), 0) end as stock,
             case when p.kind = 'SERVICE'::public.product_kind then '{}'::jsonb else coalesce((select jsonb_object_agg(q.location_id::text, q.quantity) from (select m.location_id, sum(m.quantity_delta) as quantity from public.inventory_movements m where m.organization_id = p_organization_id and m.product_id = p.id group by m.location_id) q), '{}'::jsonb) end as "byLoc",
             0::numeric as backorder,
             p.default_unit_cost as "lastCost",
             case when p.kind = 'SERVICE'::public.product_kind then 0 else coalesce((select sum(l.quantity_remaining * l.unit_cost) from public.inventory_lots l where l.organization_id = p_organization_id and l.product_id = p.id and l.status = 'OPEN' and (v_location_id is null or l.location_id = v_location_id)), 0) end as "fifoValue",
             private.owner_product_cost(p_organization_id, p.id, v_location_id) as "avgCost",
             case when p.selling_price > 0 then round(((p.selling_price - private.owner_product_cost(p_organization_id, p.id, v_location_id)) / p.selling_price) * 100, 2) else 0 end as margin,
             case when p.default_unit_cost > 0 and v_settings.target_margin_pct < 100 then round(p.default_unit_cost / (1 - (v_settings.target_margin_pct / 100)), 2) else 0 end as suggested,
             p.service_cost as "serviceCost",
             coalesce((select jsonb_agg(jsonb_build_object('sku', mp.sku::text, 'name', mp.name, 'qty', sm.quantity_per_service, 'unitCost', private.owner_product_cost(p_organization_id, mp.id, v_location_id), 'cost', round(sm.quantity_per_service * private.owner_product_cost(p_organization_id, mp.id, v_location_id),2)) order by lower(mp.name)) from public.service_materials sm join public.products mp on mp.id = sm.material_product_id where sm.organization_id = p_organization_id and sm.service_product_id = p.id), '[]'::jsonb) as materials,
             case when p.kind = 'SERVICE'::public.product_kind then true else p.default_unit_cost > 0 or exists (select 1 from public.inventory_lots l where l.organization_id=p_organization_id and l.product_id=p.id and l.status='OPEN' and l.quantity_remaining>0 and (v_location_id is null or l.location_id=v_location_id)) end as "costReady",
             case when p.kind = 'ITEM'::public.product_kind and p.default_unit_cost <= 0 and not exists (select 1 from public.inventory_lots l where l.organization_id=p_organization_id and l.product_id=p.id and l.status='OPEN' and l.quantity_remaining>0 and (v_location_id is null or l.location_id=v_location_id)) then 'Set an incoming cost before selling or adding stock.' else '' end as "costIssue",
             p.price_editable as "priceEditable", p.reviewed, coalesce(pr.username, '') as "addedBy"
        from public.products p
        left join public.profiles pr on pr.user_id = p.created_by
       where p.organization_id = p_organization_id
    ) x;

  select coalesce(sum(l.quantity_remaining * l.unit_cost), 0) into v_stock_value
    from public.inventory_lots l
   where l.organization_id = p_organization_id and l.status = 'OPEN'
     and (v_location_id is null or l.location_id = v_location_id);
  return jsonb_build_object('rows', v_rows, 'stockValue', v_stock_value, 'targetMargin', v_settings.target_margin_pct);
end;
$$;

create or replace function public.get_parties(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_owner(p_organization_id);
  return jsonb_build_object('rows', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', p.id::text, 'type', p.kind::text, 'name', p.name,
      'phone', coalesce(p.phone, ''), 'address', coalesce(p.address, ''),
      'creditLimit', p.credit_limit, 'balance', private.party_balance(p_organization_id, p.id, p.kind), 'active', p.active
    ) order by p.kind, lower(p.name))
    from public.parties p where p.organization_id = p_organization_id
  ), '[]'::jsonb));
end;
$$;

-- Owner-only catalogue maintenance. Quantities, FIFO lots and historical cost
-- are deliberately *not* mutated here; stock changes must use the audited
-- financial posting commands (opening stock, purchase or adjustment).
create or replace function public.upsert_product(
  p_organization_id uuid,
  p_product jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner public.memberships%rowtype;
  v_product public.products%rowtype;
  v_existing public.products%rowtype;
  v_sku text;
  v_name text;
  v_kind public.product_kind;
  v_price numeric;
  v_reorder numeric;
  v_service_cost numeric;
  v_default_cost numeric;
  v_material jsonb;
  v_material_product public.products%rowtype;
  v_qty numeric;
  v_seen uuid[] := '{}';
  v_has_stock boolean;
begin
  v_owner := private.require_owner(p_organization_id);
  if p_product is null or jsonb_typeof(p_product) <> 'object' then
    raise exception 'Product details are required.' using errcode = 'P0001';
  end if;
  if p_product ? 'stockQuantity' or p_product ? 'applyCostToStock' then
    raise exception 'Use opening stock, Buy stock, or Correct stock count for quantity and FIFO cost changes.' using errcode = 'P0001';
  end if;
  v_sku := upper(btrim(coalesce(p_product->>'sku', '')));
  v_name := btrim(coalesce(p_product->>'name', ''));
  if v_sku !~ '^[A-Z0-9._/#-]{1,40}$' then
    raise exception 'SKU may contain 1–40 letters, numbers, dot, underscore, slash, hash or dash characters.' using errcode = 'P0001';
  end if;
  if char_length(v_name) < 1 or char_length(v_name) > 240 then
    raise exception 'Product name is required and may not exceed 240 characters.' using errcode = 'P0001';
  end if;
  v_kind := case upper(coalesce(p_product->>'type', 'ITEM')) when 'SERVICE' then 'SERVICE'::public.product_kind else 'ITEM'::public.product_kind end;
  v_price := private.try_numeric(p_product->>'sellingPrice');
  if v_price is null then v_price := private.try_numeric(p_product->>'price'); end if;
  if v_price is null or v_price < 0 then raise exception 'Enter a valid selling price.' using errcode = 'P0001'; end if;
  v_reorder := coalesce(private.try_numeric(p_product->>'reorderLevel'), private.try_numeric(p_product->>'reorder'), 0);
  if v_reorder < 0 or abs(v_reorder - round(v_reorder, 4)) > 0.00000001 then raise exception 'Reorder level must be zero or more with up to four decimal places.' using errcode = 'P0001'; end if;
  v_service_cost := coalesce(private.try_numeric(p_product->>'serviceCost'), 0);
  v_default_cost := coalesce(private.try_numeric(p_product->>'defaultUnitCost'), private.try_numeric(p_product->>'costPrice'), private.try_numeric(p_product->>'lastCost'), 0);
  if v_service_cost < 0 or v_default_cost < 0 then raise exception 'Costs cannot be negative.' using errcode = 'P0001'; end if;

  select * into v_existing
    from public.products p
   where p.organization_id = p_organization_id and p.sku = v_sku
   for update;
  if found then
    v_has_stock := exists (
      select 1 from public.inventory_lots l
       where l.organization_id = p_organization_id and l.product_id = v_existing.id
         and l.status = 'OPEN' and l.quantity_remaining > 0
    );
    if v_existing.kind <> v_kind and v_has_stock then
      raise exception 'This product still has stock. Correct or transfer the stock before changing it into a service.' using errcode = 'P0001';
    end if;
    update public.products
       set name = v_name,
           category = left(btrim(coalesce(p_product->>'category', category)), 160),
           unit = left(coalesce(nullif(btrim(p_product->>'unit'), ''), unit), 60),
           kind = v_kind,
           selling_price = round(v_price, 2),
           reorder_level = case when v_kind = 'SERVICE'::public.product_kind then 0 else round(v_reorder, 4) end,
           price_editable = case when v_kind = 'SERVICE'::public.product_kind then coalesce((p_product->>'priceEditable')::boolean, false) else false end,
           service_cost = case when v_kind = 'SERVICE'::public.product_kind then round(v_service_cost, 2) else 0 end,
           default_unit_cost = case when v_kind = 'ITEM'::public.product_kind then round(v_default_cost, 2) else 0 end,
           active = coalesce((p_product->>'active')::boolean, active),
           reviewed = true,
           reviewed_at = now()
     where id = v_existing.id
     returning * into v_product;
  else
    insert into public.products (
      organization_id, sku, name, category, unit, kind, selling_price,
      reorder_level, price_editable, service_cost, default_unit_cost, active,
      reviewed, reviewed_at, created_by
    ) values (
      p_organization_id, v_sku, v_name, left(btrim(coalesce(p_product->>'category', '')), 160),
      left(coalesce(nullif(btrim(p_product->>'unit'), ''), case when v_kind = 'SERVICE'::public.product_kind then 'job' else 'unit' end), 60),
      v_kind, round(v_price, 2), case when v_kind = 'SERVICE'::public.product_kind then 0 else round(v_reorder, 4) end,
      case when v_kind = 'SERVICE'::public.product_kind then coalesce((p_product->>'priceEditable')::boolean, false) else false end,
      case when v_kind = 'SERVICE'::public.product_kind then round(v_service_cost, 2) else 0 end,
      case when v_kind = 'ITEM'::public.product_kind then round(v_default_cost, 2) else 0 end,
      coalesce((p_product->>'active')::boolean, true), true, now(), auth.uid()
    ) returning * into v_product;
  end if;

  -- Recipe changes affect only future service sales; completed document lines
  -- preserve their original recorded cost.
  delete from public.service_materials sm
   where sm.organization_id = p_organization_id and sm.service_product_id = v_product.id;
  if v_product.kind = 'SERVICE'::public.product_kind and jsonb_typeof(coalesce(p_product->'materials', '[]'::jsonb)) = 'array' then
    for v_material in select value from jsonb_array_elements(p_product->'materials')
    loop
      v_qty := private.try_numeric(v_material->>'qty');
      if v_qty is null or v_qty <= 0 or abs(v_qty - round(v_qty, 4)) > 0.00000001 then
        raise exception 'Each service material needs a positive quantity with up to four decimal places.' using errcode = 'P0001';
      end if;
      select * into v_material_product from public.products p
       where p.organization_id = p_organization_id and p.sku = upper(btrim(coalesce(v_material->>'sku', '')))
       for share;
      if not found or v_material_product.kind <> 'ITEM'::public.product_kind then
        raise exception 'Each service material must be an existing stock item.' using errcode = 'P0001';
      end if;
      if v_material_product.id = v_product.id or v_material_product.id = any(v_seen) then
        raise exception 'A service material may appear only once and cannot be the service itself.' using errcode = 'P0001';
      end if;
      v_seen := array_append(v_seen, v_material_product.id);
      insert into public.service_materials (organization_id, service_product_id, material_product_id, quantity_per_service)
      values (p_organization_id, v_product.id, v_material_product.id, round(v_qty, 4));
    end loop;
  end if;

  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, detail)
  values (p_organization_id, auth.uid(), case when v_existing.id is null then 'PRODUCT_CREATED' else 'PRODUCT_UPDATED' end,
          'product', v_product.id, jsonb_build_object('sku', v_product.sku::text, 'name', v_product.name));
  return jsonb_build_object('saved', true, 'sku', v_product.sku::text,
    'stockAdjusted', false, 'stockDocNo', '', 'stockBefore', null, 'stockAfter', null,
    'defaultCost', v_product.default_unit_cost, 'costDocNo', '', 'costRevalued', 0);
end;
$$;

create or replace function public.upsert_party(
  p_organization_id uuid,
  p_party jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_party public.parties%rowtype;
  v_kind public.party_kind;
  v_name text;
  v_id uuid;
  v_credit numeric;
begin
  perform private.require_owner(p_organization_id);
  if p_party is null or jsonb_typeof(p_party) <> 'object' then raise exception 'Party details are required.' using errcode = 'P0001'; end if;
  v_name := btrim(coalesce(p_party->>'name', ''));
  if char_length(v_name) < 1 or char_length(v_name) > 240 then raise exception 'Name is required and may not exceed 240 characters.' using errcode = 'P0001'; end if;
  v_credit := coalesce(private.try_numeric(p_party->>'creditLimit'), 0);
  if v_credit < 0 then raise exception 'Credit limit cannot be negative.' using errcode = 'P0001'; end if;
  begin v_id := nullif(btrim(coalesce(p_party->>'id', '')), '')::uuid; exception when others then v_id := null; end;
  if v_id is not null then
    select * into v_party from public.parties p where p.id = v_id and p.organization_id = p_organization_id for update;
    if not found then raise exception 'Customer or supplier not found.' using errcode = 'P0001'; end if;
    update public.parties
       set name = v_name, phone = nullif(left(btrim(coalesce(p_party->>'phone', '')), 80), ''),
           address = nullif(left(btrim(coalesce(p_party->>'address', '')), 500), ''),
           credit_limit = round(v_credit, 2), active = coalesce((p_party->>'active')::boolean, active)
     where id = v_id returning * into v_party;
  else
    begin v_kind := upper(btrim(coalesce(p_party->>'type', '')))::public.party_kind;
    exception when others then raise exception 'Choose customer or supplier.' using errcode = 'P0001'; end;
    insert into public.parties (organization_id, kind, name, phone, address, credit_limit, active, created_by)
    values (p_organization_id, v_kind, v_name, nullif(left(btrim(coalesce(p_party->>'phone', '')),80), ''),
            nullif(left(btrim(coalesce(p_party->>'address', '')),500), ''), round(v_credit,2), coalesce((p_party->>'active')::boolean, true), auth.uid())
    returning * into v_party;
  end if;
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, detail)
  values (p_organization_id, auth.uid(), 'PARTY_SAVED', 'party', v_party.id,
          jsonb_build_object('kind', v_party.kind::text, 'name', v_party.name));
  return jsonb_build_object('saved', true, 'id', v_party.id::text);
end;
$$;

create or replace function public.upsert_location(
  p_organization_id uuid,
  p_location jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location public.locations%rowtype;
  v_id uuid;
  v_name text;
  v_code text;
  v_active boolean;
begin
  perform private.require_owner(p_organization_id);
  if p_location is null or jsonb_typeof(p_location) <> 'object' then raise exception 'Shop details are required.' using errcode = 'P0001'; end if;
  v_name := btrim(coalesce(p_location->>'name', ''));
  if char_length(v_name) < 1 or char_length(v_name) > 120 then raise exception 'Give the shop a name of up to 120 characters.' using errcode = 'P0001'; end if;
  begin v_id := nullif(btrim(coalesce(p_location->>'id', '')), '')::uuid; exception when others then v_id := null; end;
  v_active := coalesce((p_location->>'active')::boolean, true);
  if v_id is not null then
    select * into v_location from public.locations l where l.id = v_id and l.organization_id = p_organization_id for update;
    if not found then raise exception 'Shop not found.' using errcode = 'P0001'; end if;
    if not v_active and v_location.active then
      if (select count(*) from public.locations l where l.organization_id = p_organization_id and l.active) <= 1 then raise exception 'You cannot close your only shop.' using errcode = 'P0001'; end if;
      if exists (select 1 from public.inventory_lots l where l.organization_id = p_organization_id and l.location_id = v_location.id and l.status = 'OPEN' and l.quantity_remaining > 0) then raise exception 'This shop still holds stock. Transfer it before closing the shop.' using errcode = 'P0001'; end if;
      if exists (select 1 from public.memberships m where m.organization_id = p_organization_id and m.location_id = v_location.id and m.active) then raise exception 'Move or deactivate staff assigned to this shop before closing it.' using errcode = 'P0001'; end if;
    end if;
    update public.locations set name = v_name, address = nullif(left(btrim(coalesce(p_location->>'address', '')),500), ''), active = v_active
     where id = v_location.id returning * into v_location;
  else
    v_code := upper(regexp_replace(coalesce(nullif(btrim(p_location->>'code'), ''), 'SHOP-' || substr(md5(gen_random_uuid()::text),1,8)), '[^A-Za-z0-9_-]', '', 'g'));
    if v_code = '' or char_length(v_code) > 60 then raise exception 'Shop code is invalid.' using errcode = 'P0001'; end if;
    insert into public.locations (organization_id, code, name, address, active)
    values (p_organization_id, v_code, v_name, nullif(left(btrim(coalesce(p_location->>'address', '')),500), ''), true)
    returning * into v_location;
  end if;
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, detail)
  values (p_organization_id, auth.uid(), 'LOCATION_SAVED', 'location', v_location.id, jsonb_build_object('code', v_location.code::text, 'name', v_location.name));
  return jsonb_build_object('saved', true, 'id', v_location.id::text, 'code', v_location.code::text);
end;
$$;

create or replace function public.get_config(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org public.organizations%rowtype;
  v_settings public.organization_settings%rowtype;
begin
  perform private.require_owner(p_organization_id);
  select * into v_org from public.organizations where id = p_organization_id;
  select * into v_settings from public.organization_settings where organization_id = p_organization_id;
  return jsonb_build_object(
    'values', jsonb_build_object(
      'OversellPolicy', v_settings.oversell_policy,
      'CompanyName', v_org.name,
      'Currency', v_org.currency_symbol,
      'RepsSeeCompanyTotals', case when v_settings.reps_see_company_totals then 'TRUE' else 'FALSE' end,
      'ExpenseCategories', private.owner_json_list(v_settings.expense_categories),
      'PaymentMethods', private.owner_json_list(v_settings.payment_methods),
      'AlertEmail', coalesce(v_settings.alert_email, ''),
      'ReceiptFooter', v_settings.receipt_footer,
      'BackupKeepDays', v_settings.backup_keep_days::text,
      'TargetMarginPct', v_settings.target_margin_pct::text,
      'ServiceCategories', private.owner_json_list(v_settings.service_categories),
      'ClosedUntil', coalesce(v_settings.closed_until::text, '')
    ),
    'webAppUrl', '',
    'version', 'supabase-production',
    'today', (now() at time zone v_org.timezone)::date,
    'timezone', v_org.timezone
  );
end;
$$;

create or replace function public.update_settings(
  p_organization_id uuid,
  p_values jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_settings public.organization_settings%rowtype;
  v_company text;
  v_currency text;
  v_policy text;
  v_margin numeric;
  v_days integer;
  v_email text;
begin
  perform private.require_owner(p_organization_id);
  if p_values is null or jsonb_typeof(p_values) <> 'object' then raise exception 'Settings values are required.' using errcode = 'P0001'; end if;
  select * into v_settings from public.organization_settings where organization_id = p_organization_id for update;

  if p_values ? 'CompanyName' then
    v_company := btrim(coalesce(p_values->>'CompanyName', ''));
    if char_length(v_company) < 1 or char_length(v_company) > 160 then raise exception 'Company name is required and may not exceed 160 characters.' using errcode = 'P0001'; end if;
    update public.organizations set name = v_company where id = p_organization_id;
  end if;
  if p_values ? 'Currency' then
    v_currency := btrim(coalesce(p_values->>'Currency', ''));
    if char_length(v_currency) < 1 or char_length(v_currency) > 8 then raise exception 'Currency symbol must contain 1–8 characters.' using errcode = 'P0001'; end if;
    update public.organizations set currency_symbol = v_currency where id = p_organization_id;
  end if;
  v_policy := upper(coalesce(p_values->>'OversellPolicy', v_settings.oversell_policy));
  if v_policy not in ('BLOCK', 'FLAG') then raise exception 'Choose Block or Flag for overselling.' using errcode = 'P0001'; end if;
  v_margin := coalesce(private.try_numeric(p_values->>'TargetMarginPct'), v_settings.target_margin_pct);
  if v_margin < 1 or v_margin >= 95 then raise exception 'Target margin must be between 1 and 94.' using errcode = 'P0001'; end if;
  v_days := coalesce(private.try_numeric(p_values->>'BackupKeepDays')::integer, v_settings.backup_keep_days);
  if v_days < 7 or v_days > 3650 then raise exception 'Keep backups for at least 7 days.' using errcode = 'P0001'; end if;
  v_email := nullif(btrim(coalesce(p_values->>'AlertEmail', v_settings.alert_email, '')), '');
  if v_email is not null and v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'Alert email does not look valid.' using errcode = 'P0001'; end if;

  update public.organization_settings
     set oversell_policy = v_policy,
         reps_see_company_totals = case when p_values ? 'RepsSeeCompanyTotals' then upper(coalesce(p_values->>'RepsSeeCompanyTotals','FALSE')) = 'TRUE' else reps_see_company_totals end,
         expense_categories = case when p_values ? 'ExpenseCategories' then private.owner_text_array(p_values->'ExpenseCategories') else expense_categories end,
         payment_methods = case when p_values ? 'PaymentMethods' then private.owner_text_array(p_values->'PaymentMethods') else payment_methods end,
         service_categories = case when p_values ? 'ServiceCategories' then private.owner_text_array(p_values->'ServiceCategories') else service_categories end,
         alert_email = v_email,
         receipt_footer = case when p_values ? 'ReceiptFooter' then left(btrim(coalesce(p_values->>'ReceiptFooter','')), 1000) else receipt_footer end,
         backup_keep_days = v_days,
         target_margin_pct = round(v_margin,2)
   where organization_id = p_organization_id;
  insert into public.audit_events (organization_id, actor_id, action, entity_type, detail)
  values (p_organization_id, auth.uid(), 'SETTINGS_UPDATED', 'settings', jsonb_build_object('updated', true));
  return jsonb_build_object('saved', true);
end;
$$;

create or replace function public.close_period(
  p_organization_id uuid,
  p_date date
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org public.organizations%rowtype;
  v_current date;
  v_today date;
begin
  perform private.require_owner(p_organization_id);
  if p_date is null then raise exception 'Choose a valid date.' using errcode = 'P0001'; end if;
  select * into v_org from public.organizations where id = p_organization_id;
  v_today := (now() at time zone v_org.timezone)::date;
  if p_date >= v_today then raise exception 'You can only close dates before today.' using errcode = 'P0001'; end if;
  select closed_until into v_current from public.organization_settings where organization_id = p_organization_id for update;
  if v_current is not null and p_date < v_current then raise exception 'That period is already closed and cannot be shortened.' using errcode = 'P0001'; end if;
  update public.organization_settings set closed_until = p_date where organization_id = p_organization_id;
  insert into public.audit_events (organization_id, actor_id, action, entity_type, detail)
  values (p_organization_id, auth.uid(), 'PERIOD_CLOSED', 'settings', jsonb_build_object('closedUntil', p_date));
  return jsonb_build_object('closedUntil', p_date);
end;
$$;

-- Acknowledgements only hide inbox prompts; source documents, failed commands
-- and audit evidence are never removed.
create or replace function public.acknowledge_attention(
  p_organization_id uuid,
  p_keys jsonb,
  p_resolution text default 'RESOLVED',
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_key text;
  v_resolution text := upper(btrim(coalesce(p_resolution, 'RESOLVED')));
  v_changed integer := 0;
begin
  perform private.require_owner(p_organization_id);
  if v_resolution = 'CLEAR' then v_resolution := 'DISMISSED'; end if;
  if v_resolution not in ('RESOLVED', 'DISMISSED') then raise exception 'Choose Resolve or Clear.' using errcode = 'P0001'; end if;
  if jsonb_typeof(coalesce(p_keys, '[]'::jsonb)) <> 'array' or jsonb_array_length(p_keys) = 0 or jsonb_array_length(p_keys) > 200 then
    raise exception 'Select between 1 and 200 attention items.' using errcode = 'P0001';
  end if;
  for v_key in select distinct btrim(value) from jsonb_array_elements_text(p_keys) x(value)
  loop
    if v_key = '' or char_length(v_key) > 250 or v_key !~ '^[A-Za-z0-9:_-]+$' then
      raise exception 'An attention key is invalid.' using errcode = 'P0001';
    end if;
    insert into public.attention_acknowledgements (organization_id, attention_key, acknowledged_by, resolution, note)
    values (p_organization_id, v_key, auth.uid(), v_resolution, nullif(left(btrim(coalesce(p_note, '')),500), ''))
    on conflict (organization_id, attention_key) do update
      set acknowledged_by = excluded.acknowledged_by, resolution = excluded.resolution,
          note = excluded.note, acknowledged_at = now();
    v_changed := v_changed + 1;
  end loop;
  insert into public.audit_events (organization_id, actor_id, action, entity_type, detail)
  values (p_organization_id, auth.uid(), 'ATTENTION_' || v_resolution, 'attention', jsonb_build_object('changed', v_changed));
  return jsonb_build_object('saved', true, 'changed', v_changed, 'action', case when v_resolution = 'DISMISSED' then 'CLEAR' else 'RESOLVE' end);
end;
$$;

-- Transaction-history read model. It deliberately returns presentation JSON,
-- not raw accounting rows, so browser clients cannot use this endpoint as a
-- general database proxy.
create or replace function public.get_ledger(
  p_organization_id uuid,
  p_type text default null,
  p_from date default null,
  p_to date default null,
  p_location text default null,
  p_query text default null,
  p_limit integer default 150
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
  v_limit integer := greatest(1, least(coalesce(p_limit, 150), 500));
  v_type text := upper(nullif(btrim(coalesce(p_type, '')), ''));
  v_query text := lower(nullif(btrim(coalesce(p_query, '')), ''));
  v_docs jsonb;
  v_total integer;
begin
  v_location_id := private.owner_location(p_organization_id, p_location, true);
  with filtered as (
    select d.*
      from public.documents d
     where d.organization_id = p_organization_id
       and (v_location_id is null or d.location_id = v_location_id)
       and (p_from is null or d.occurred_on >= p_from)
       and (p_to is null or d.occurred_on <= p_to)
       and (v_type is null or upper(d.kind::text) = v_type)
       and (v_query is null or lower(concat_ws(' ', d.document_number, d.notes, coalesce((select p.name from public.parties p where p.id = d.party_id), ''), coalesce((select string_agg(coalesce(l.description,'') || ' ' || coalesce(l.metadata->>'sku',''), ' ') from public.document_lines l where l.document_id = d.id), ''))) like '%' || v_query || '%')
  ), shaped as (
    select d.id, d.document_number, d.occurred_on, d.kind, d.status, d.total, d.amount_paid,
           d.notes, private.owner_document_flags(d.flags, d.metadata) as flags, d.posted_at,
           p.id as party_id, p.name as party_name,
           l.name as location_name,
           coalesce(pr.username, '') as rep,
           coalesce((select sum(dl.cost_of_goods) from public.document_lines dl where dl.document_id = d.id), 0) as cogs,
           coalesce((select jsonb_agg(jsonb_build_object(
             'sku', coalesce(dl.metadata->>'sku', ''), 'product', dl.description,
             'qty', dl.quantity, 'price', dl.unit_price, 'cost', dl.unit_cost,
             'amount', dl.line_total, 'cogs', dl.cost_of_goods
           ) order by dl.line_number) from public.document_lines dl where dl.document_id = d.id), '[]'::jsonb) as lines
      from filtered d
      left join public.parties p on p.id = d.party_id
      left join public.locations l on l.id = d.location_id
      left join public.profiles pr on pr.user_id = d.created_by
  )
  select count(*) into v_total from shaped;
  with filtered as (
    select d.*
      from public.documents d
     where d.organization_id = p_organization_id
       and (v_location_id is null or d.location_id = v_location_id)
       and (p_from is null or d.occurred_on >= p_from)
       and (p_to is null or d.occurred_on <= p_to)
       and (v_type is null or upper(d.kind::text) = v_type)
       and (v_query is null or lower(concat_ws(' ', d.document_number, d.notes, coalesce((select p.name from public.parties p where p.id = d.party_id), ''), coalesce((select string_agg(coalesce(dl.description,'') || ' ' || coalesce(dl.metadata->>'sku',''), ' ') from public.document_lines dl where dl.document_id = d.id), ''))) like '%' || v_query || '%')
  ), shaped as (
    select d.id, d.document_number, d.occurred_on, d.kind, d.status, d.total, d.amount_paid,
           d.notes, private.owner_document_flags(d.flags, d.metadata) as flags, d.posted_at, p.id as party_id, p.name as party_name,
           l.name as location_name, coalesce(pr.username, '') as rep,
           coalesce((select sum(dl.cost_of_goods) from public.document_lines dl where dl.document_id = d.id), 0) as cogs,
           coalesce((select jsonb_agg(jsonb_build_object(
             'sku', coalesce(dl.metadata->>'sku', ''), 'product', dl.description,
             'qty', dl.quantity, 'price', dl.unit_price, 'cost', dl.unit_cost,
             'amount', dl.line_total, 'cogs', dl.cost_of_goods
           ) order by dl.line_number) from public.document_lines dl where dl.document_id = d.id), '[]'::jsonb) as lines
      from filtered d
      left join public.parties p on p.id = d.party_id
      left join public.locations l on l.id = d.location_id
      left join public.profiles pr on pr.user_id = d.created_by
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'docNo', document_number, 'date', occurred_on, 'type', kind::text,
    'party', coalesce(party_name, ''), 'partyId', party_id::text, 'rep', rep,
    'shop', coalesce(location_name, ''), 'amount', total, 'paid', amount_paid,
    'refunded', case when kind = 'RETURN'::public.document_kind then amount_paid else 0 end,
    'cogs', cogs, 'lines', lines, 'materials', '[]'::jsonb,
    'flags', coalesce((select string_agg(value, '; ' order by ordinality) from jsonb_array_elements_text(flags) with ordinality x(value, ordinality)), ''),
    'notes', coalesce(notes, ''), 'reversed', status <> 'POSTED'::public.document_status,
    'ts', posted_at
  ) order by occurred_on desc, posted_at desc, document_number desc), '[]'::jsonb)
  into v_docs from shaped;
  return jsonb_build_object('total', v_total, 'docs', v_docs);
end;
$$;

create or replace function public.get_statement(
  p_organization_id uuid,
  p_party_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_party public.parties%rowtype;
  v_rows jsonb;
begin
  perform private.require_owner(p_organization_id);
  select * into v_party from public.parties p where p.id = p_party_id and p.organization_id = p_organization_id;
  if not found then raise exception 'Party not found.' using errcode = 'P0001'; end if;
  with entries as (
    select e.entry_date, d.document_number, e.memo, e.created_at, e.id,
           case when v_party.kind = 'CUSTOMER'::public.party_kind then e.debit else e.credit end as debit,
           case when v_party.kind = 'CUSTOMER'::public.party_kind then e.credit else e.debit end as credit
      from public.ledger_entries e
      left join public.documents d on d.id = e.document_id
     where e.organization_id = p_organization_id and e.party_id = v_party.id
       and ((v_party.kind = 'CUSTOMER'::public.party_kind and e.account_code = 'ACCOUNTS_RECEIVABLE')
         or (v_party.kind = 'SUPPLIER'::public.party_kind and e.account_code = 'ACCOUNTS_PAYABLE'))
  ), running as (
    select *, sum(debit - credit) over (order by entry_date, created_at, id) as balance from entries
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'date', entry_date, 'docNo', coalesce(document_number, ''),
    'desc', coalesce(memo, ''), 'debit', debit, 'credit', credit, 'balance', balance
  ) order by entry_date, created_at, id), '[]'::jsonb) into v_rows from running;
  return jsonb_build_object('party', jsonb_build_object(
    'id', v_party.id::text, 'name', v_party.name, 'phone', coalesce(v_party.phone, ''),
    'type', v_party.kind::text, 'balance', private.party_balance(p_organization_id, v_party.id, v_party.kind)
  ), 'rows', v_rows);
end;
$$;

create or replace function public.get_stock_card(
  p_organization_id uuid,
  p_sku text,
  p_location text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
  v_product public.products%rowtype;
  v_rows jsonb;
  v_stock numeric(18,4);
  v_sold numeric(18,4);
  v_revenue numeric(18,2);
begin
  v_location_id := private.owner_location(p_organization_id, p_location, true);
  select * into v_product from public.products p where p.organization_id = p_organization_id and p.sku = upper(btrim(coalesce(p_sku, '')));
  if not found then raise exception 'Product not found.' using errcode = 'P0001'; end if;
  if v_product.kind = 'SERVICE'::public.product_kind then
    with service_rows as (
      select d.occurred_on, d.document_number, d.kind, d.status, l.name as shop, party.name as party,
             dl.quantity, dl.line_total, d.notes, d.posted_at, dl.id
        from public.document_lines dl
        join public.documents d on d.id = dl.document_id
        left join public.locations l on l.id = d.location_id
        left join public.parties party on party.id = d.party_id
       where dl.organization_id = p_organization_id and dl.product_id = v_product.id
         and d.kind in ('SALE'::public.document_kind, 'RETURN'::public.document_kind)
         and (v_location_id is null or d.location_id = v_location_id)
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'date', occurred_on, 'docNo', document_number,
      'type', case when status <> 'POSTED'::public.document_status then 'REVERSED ' else '' end || replace(kind::text, '_', ' '),
      'shop', coalesce(shop,''), 'inQty', null, 'outQty', case when kind = 'SALE'::public.document_kind then quantity else null end,
      'balance', null, 'party', coalesce(party,''), 'notes', coalesce(notes,'')
    ) order by occurred_on desc, posted_at desc, id desc), '[]'::jsonb),
    coalesce(sum(case when kind = 'SALE'::public.document_kind then quantity else -quantity end),0),
    coalesce(sum(case when kind = 'SALE'::public.document_kind then line_total else -line_total end),0)
    into v_rows, v_sold, v_revenue from service_rows;
    return jsonb_build_object('product', jsonb_build_object('sku', v_product.sku::text, 'name', v_product.name, 'unit', v_product.unit, 'type', 'SERVICE', 'stock', null), 'totals', jsonb_build_object('sold', v_sold, 'revenue', v_revenue), 'rows', v_rows);
  end if;

  with moves as (
    select m.*, l.name as shop, d.document_number, d.notes, party.name as party,
           sum(m.quantity_delta) over (order by m.occurred_on, m.created_at, m.id) as running_balance
      from public.inventory_movements m
      left join public.locations l on l.id = m.location_id
      left join public.documents d on d.id = m.document_id
      left join public.parties party on party.id = d.party_id
     where m.organization_id = p_organization_id and m.product_id = v_product.id
       and (v_location_id is null or m.location_id = v_location_id)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'date', occurred_on, 'docNo', coalesce(document_number, ''), 'type', replace(kind::text, '_', ' '),
      'shop', coalesce(shop, ''), 'inQty', case when quantity_delta > 0 then quantity_delta else null end,
      'outQty', case when quantity_delta < 0 then -quantity_delta else null end,
      'balance', running_balance, 'party', coalesce(party, ''), 'notes', coalesce(notes, '')
    ) order by occurred_on desc, created_at desc, id desc), '[]'::jsonb),
    coalesce(sum(case when kind = 'SALE'::public.inventory_movement_kind then -quantity_delta else 0 end),0),
    coalesce((select sum(case when d.kind = 'SALE'::public.document_kind then dl.line_total when d.kind = 'RETURN'::public.document_kind then -dl.line_total else 0 end)
      from public.document_lines dl join public.documents d on d.id = dl.document_id
      where dl.organization_id=p_organization_id and dl.product_id=v_product.id and (v_location_id is null or d.location_id=v_location_id) and d.status='POSTED'::public.document_status),0)
    into v_rows, v_sold, v_revenue from moves;
  select coalesce(sum(m.quantity_delta),0) into v_stock from public.inventory_movements m
   where m.organization_id = p_organization_id and m.product_id = v_product.id and (v_location_id is null or m.location_id = v_location_id);
  return jsonb_build_object('product', jsonb_build_object('sku', v_product.sku::text, 'name', v_product.name, 'unit', v_product.unit, 'type', 'ITEM', 'stock', v_stock), 'totals', jsonb_build_object('sold', v_sold, 'revenue', v_revenue), 'rows', v_rows);
end;
$$;

-- Common business summary used by dashboard/report reads. The financial
-- command layer posts named accounts (SALES_REVENUE, COST_OF_GOODS_SOLD,
-- EXPENSE, CASH, INVENTORY_SHRINKAGE and STOCK_ADJUSTMENT_GAIN).  The
-- alternate names below keep the read model compatible with a future
-- category-qualified chart of accounts, while reports always follow immutable
-- accounting entries rather than recalculating old costs.
create or replace function private.owner_period_summary(
  p_organization_id uuid,
  p_location_id uuid,
  p_from date,
  p_to date
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  with relevant_documents as (
    select d.*
      from public.documents d
     where d.organization_id = p_organization_id
       and d.status = 'POSTED'::public.document_status
       and d.occurred_on between p_from and p_to
       and (p_location_id is null or d.location_id = p_location_id)
  ), relevant_ledger as (
    select e.*
      from public.ledger_entries e
      left join public.documents d on d.id = e.document_id
     where e.organization_id = p_organization_id
       and e.entry_date between p_from and p_to
       and (d.id is null or (d.status = 'POSTED'::public.document_status and (p_location_id is null or d.location_id = p_location_id)))
  ), sale_lines as (
    select dl.*, d.kind
      from public.document_lines dl join relevant_documents d on d.id = dl.document_id
     where d.kind in ('SALE'::public.document_kind, 'RETURN'::public.document_kind)
  ), totals as (
    select
      coalesce((select count(*) from relevant_documents where kind = 'SALE'::public.document_kind), 0) as invoices,
      coalesce((select sum(case when kind = 'SALE'::public.document_kind then quantity else -quantity end) from sale_lines), 0) as qty,
      coalesce((select sum(credit - debit) from relevant_ledger where account_code = 'SALES_REVENUE'), 0) as revenue,
      coalesce((select sum(debit - credit) from relevant_ledger where account_code = 'COST_OF_GOODS_SOLD'), 0) as cogs,
      coalesce((select sum(debit - credit) from relevant_ledger where account_code = 'EXPENSE' or account_code like 'EXPENSE:%'), 0) as expenses,
      coalesce((select sum(debit - credit) from relevant_ledger where account_code = 'CASH'), 0) as cash_net,
      coalesce((select sum(debit) from relevant_ledger where account_code = 'CASH' and document_id in (select id from relevant_documents where kind in ('SALE'::public.document_kind, 'PAYMENT_IN'::public.document_kind))), 0) as cash_in,
      coalesce((select sum(credit) from relevant_ledger where account_code = 'CASH' and document_id in (select id from relevant_documents where kind in ('PAYMENT_OUT'::public.document_kind, 'RETURN'::public.document_kind))), 0) as cash_out,
      coalesce((select sum(total) from relevant_documents where kind = 'PURCHASE'::public.document_kind), 0) as purchases,
      coalesce((select sum(total) from relevant_documents where kind = 'OWNER_CONTRIBUTION'::public.document_kind), 0) as owner_contributions,
      coalesce((select sum(total) from relevant_documents where kind = 'OWNER_WITHDRAWAL'::public.document_kind), 0) as owner_withdrawals,
      coalesce((select sum(debit - credit) from relevant_ledger where account_code in ('INVENTORY_SHRINKAGE', 'STOCK_LOSS')), 0) as stock_losses,
      coalesce((select sum(credit - debit) from relevant_ledger where account_code in ('STOCK_ADJUSTMENT_GAIN', 'STOCK_GAIN')), 0) as stock_found
  )
  select jsonb_build_object(
    'invoices', invoices, 'qty', qty, 'revenue', revenue, 'cogs', cogs,
    'writeoffs', stock_losses - stock_found, 'stockLosses', stock_losses,
    'stockFound', stock_found, 'stockAdjustments', stock_losses - stock_found,
    'expenses', expenses, 'cashIn', cash_in, 'cashOut', cash_out, 'purchases', purchases,
    'ownerContributions', owner_contributions, 'ownerWithdrawals', owner_withdrawals,
    'gross', revenue - cogs, 'net', revenue - cogs - expenses - stock_losses + stock_found,
    'cashNet', cash_net
  ) from totals;
$$;

create or replace function public.get_report(
  p_organization_id uuid,
  p_group text default 'day',
  p_from date default null,
  p_to date default null,
  p_location text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
  v_org public.organizations%rowtype;
  v_from date;
  v_to date;
  v_group text := lower(btrim(coalesce(p_group, 'day')));
  v_columns jsonb;
  v_rows jsonb := '[]'::jsonb;
  v_summary jsonb;
begin
  v_location_id := private.owner_location(p_organization_id, p_location, true);
  select * into v_org from public.organizations where id = p_organization_id;
  v_to := coalesce(p_to, (now() at time zone v_org.timezone)::date);
  v_from := coalesce(p_from, v_to);
  if v_from > v_to then raise exception 'The report start date must not be after the end date.' using errcode = 'P0001'; end if;
  v_summary := private.owner_period_summary(p_organization_id, v_location_id, v_from, v_to);

  if v_group in ('day', 'month') then
    v_columns := jsonb_build_array(case when v_group = 'day' then 'Date' else 'Month' end, 'Invoices', 'Qty sold', 'Revenue', 'Cost of goods', 'Gross profit', 'Goods lost', 'Stock found', 'Expenses', 'Net profit', 'Owner money in', 'Owner money out', 'Cash movement');
    if v_group = 'day' then
      select coalesce(jsonb_agg(jsonb_build_array(k, (s->>'invoices')::numeric, (s->>'qty')::numeric, (s->>'revenue')::numeric, (s->>'cogs')::numeric, (s->>'gross')::numeric, (s->>'stockLosses')::numeric, (s->>'stockFound')::numeric, (s->>'expenses')::numeric, (s->>'net')::numeric, (s->>'ownerContributions')::numeric, (s->>'ownerWithdrawals')::numeric, (s->>'cashNet')::numeric) order by k), '[]'::jsonb)
        into v_rows from (
          select d.day::date::text as k, private.owner_period_summary(p_organization_id, v_location_id, d.day::date, d.day::date) as s
          from generate_series(v_from, v_to, interval '1 day') d(day)
        ) q;
    else
      select coalesce(jsonb_agg(jsonb_build_array(k, (s->>'invoices')::numeric, (s->>'qty')::numeric, (s->>'revenue')::numeric, (s->>'cogs')::numeric, (s->>'gross')::numeric, (s->>'stockLosses')::numeric, (s->>'stockFound')::numeric, (s->>'expenses')::numeric, (s->>'net')::numeric, (s->>'ownerContributions')::numeric, (s->>'ownerWithdrawals')::numeric, (s->>'cashNet')::numeric) order by k), '[]'::jsonb)
        into v_rows from (
          select to_char(d.day::date, 'YYYY-MM') as k,
                 private.owner_period_summary(p_organization_id, v_location_id, date_trunc('month', d.day)::date, (date_trunc('month', d.day) + interval '1 month - 1 day')::date) as s
          from generate_series(date_trunc('month', v_from), date_trunc('month', v_to), interval '1 month') d(day)
        ) q;
    end if;
  elsif v_group = 'shop' then
    v_columns := jsonb_build_array('Shop', 'Invoices', 'Qty sold', 'Revenue', 'Cost of goods', 'Gross profit', 'Lost stock (net)', 'Expenses', 'Net profit', 'Owner money in', 'Owner money out', 'Cash movement');
    select coalesce(jsonb_agg(jsonb_build_array(l.name, (s.summary->>'invoices')::numeric, (s.summary->>'qty')::numeric, (s.summary->>'revenue')::numeric, (s.summary->>'cogs')::numeric, (s.summary->>'gross')::numeric, (s.summary->>'stockAdjustments')::numeric, (s.summary->>'expenses')::numeric, (s.summary->>'net')::numeric, (s.summary->>'ownerContributions')::numeric, (s.summary->>'ownerWithdrawals')::numeric, (s.summary->>'cashNet')::numeric) order by lower(l.name)), '[]'::jsonb)
      into v_rows
      from public.locations l cross join lateral private.owner_period_summary(p_organization_id, l.id, v_from, v_to) s(summary)
     where l.organization_id = p_organization_id and l.active and (v_location_id is null or l.id = v_location_id);
  elsif v_group = 'rep' then
    v_columns := jsonb_build_array('Rep', 'Invoices', 'Qty sold', 'Revenue', 'Cash collected', 'Expenses');
    select coalesce(jsonb_agg(jsonb_build_array(coalesce(pr.username,'Unknown'), x.invoices, x.qty, x.revenue, x.cash_in, x.expenses) order by lower(coalesce(pr.username,'Unknown'))), '[]'::jsonb)
      into v_rows
      from (
        select per_doc.created_by,
               count(*) filter (where per_doc.kind = 'SALE'::public.document_kind) as invoices,
               coalesce(sum(per_doc.qty),0) as qty, coalesce(sum(per_doc.revenue),0) as revenue,
               coalesce(sum(per_doc.cash_in),0) as cash_in, coalesce(sum(per_doc.expenses),0) as expenses
          from (
            select d.id, d.created_by, d.kind,
                   coalesce((select sum(case when d.kind='SALE'::public.document_kind then dl.quantity when d.kind='RETURN'::public.document_kind then -dl.quantity else 0 end) from public.document_lines dl where dl.document_id=d.id),0) as qty,
                   coalesce((select sum(case when e.account_code='SALES_REVENUE' then e.credit-e.debit else 0 end) from public.ledger_entries e where e.document_id=d.id),0) as revenue,
                   coalesce((select sum(case when e.account_code='CASH' and e.debit>0 then e.debit else 0 end) from public.ledger_entries e where e.document_id=d.id),0) as cash_in,
                   coalesce((select sum(case when e.account_code = 'EXPENSE' or e.account_code like 'EXPENSE:%' then e.debit-e.credit else 0 end) from public.ledger_entries e where e.document_id=d.id),0) as expenses
              from public.documents d
             where d.organization_id=p_organization_id and d.status='POSTED'::public.document_status and d.occurred_on between v_from and v_to and (v_location_id is null or d.location_id=v_location_id)
          ) per_doc
         group by per_doc.created_by
      ) x left join public.profiles pr on pr.user_id=x.created_by;
  elsif v_group in ('product', 'services') then
    v_columns := case when v_group = 'services' then jsonb_build_array('SKU', 'Service', 'Units', 'Charged', 'Cost', 'Profit', 'Margin %', 'Avg charged / unit', 'Avg cost / unit', 'Suggested price') else jsonb_build_array('SKU', 'Product', 'Qty sold', 'Revenue', 'Cost of goods', 'Gross profit', 'Margin %') end;
    if v_group = 'services' then
      select coalesce(jsonb_agg(jsonb_build_array(sku, name, qty, revenue, cogs, revenue-cogs, case when revenue <> 0 then round((revenue-cogs)/revenue*100,2) else 0 end, case when qty <> 0 then round(revenue/qty,2) else 0 end, case when qty <> 0 then round(cogs/qty,2) else 0 end, case when qty <> 0 and cogs > 0 then round((cogs/qty)/(1-(select target_margin_pct/100 from public.organization_settings where organization_id=p_organization_id)),2) else 0 end) order by lower(name)), '[]'::jsonb)
        into v_rows from (
          select p.sku::text as sku, p.name,
                 coalesce(sum(case when d.kind='SALE'::public.document_kind then dl.quantity else -dl.quantity end),0) qty,
                 coalesce(sum(case when d.kind='SALE'::public.document_kind then dl.line_total else -dl.line_total end),0) revenue,
                 coalesce(sum(case when d.kind='SALE'::public.document_kind then dl.cost_of_goods else -dl.cost_of_goods end),0) cogs
            from public.products p join public.document_lines dl on dl.product_id=p.id join public.documents d on d.id=dl.document_id
           where p.organization_id=p_organization_id and p.kind='SERVICE'::public.product_kind and d.kind in ('SALE'::public.document_kind,'RETURN'::public.document_kind) and d.status='POSTED'::public.document_status and d.occurred_on between v_from and v_to and (v_location_id is null or d.location_id=v_location_id)
           group by p.id, p.sku, p.name
        ) q;
    else
      select coalesce(jsonb_agg(jsonb_build_array(sku, name, qty, revenue, cogs, revenue-cogs, case when revenue <> 0 then round((revenue-cogs)/revenue*100,2) else 0 end) order by lower(name)), '[]'::jsonb)
        into v_rows from (
          select p.sku::text as sku, p.name,
                 coalesce(sum(case when d.kind='SALE'::public.document_kind then dl.quantity else -dl.quantity end),0) qty,
                 coalesce(sum(case when d.kind='SALE'::public.document_kind then dl.line_total else -dl.line_total end),0) revenue,
                 coalesce(sum(case when d.kind='SALE'::public.document_kind then dl.cost_of_goods else -dl.cost_of_goods end),0) cogs
            from public.products p join public.document_lines dl on dl.product_id=p.id join public.documents d on d.id=dl.document_id
           where p.organization_id=p_organization_id and d.kind in ('SALE'::public.document_kind,'RETURN'::public.document_kind) and d.status='POSTED'::public.document_status and d.occurred_on between v_from and v_to and (v_location_id is null or d.location_id=v_location_id)
           group by p.id, p.sku, p.name
        ) q;
    end if;
  elsif v_group = 'expense' then
    v_columns := jsonb_build_array('Category', 'Entries', 'Total');
    select coalesce(jsonb_agg(jsonb_build_array(category, entries, total) order by lower(category)), '[]'::jsonb) into v_rows from (
      select coalesce(nullif(d.metadata->>'category',''), nullif(split_part(e.account_code, ':', 2),''),'Other') as category, count(distinct e.document_id) as entries, sum(e.debit-e.credit) as total
        from public.ledger_entries e left join public.documents d on d.id=e.document_id
       where e.organization_id=p_organization_id and (e.account_code = 'EXPENSE' or e.account_code like 'EXPENSE:%') and e.entry_date between v_from and v_to and (d.id is null or (d.status='POSTED'::public.document_status and (v_location_id is null or d.location_id=v_location_id)))
       group by 1
    ) q;
  elsif v_group = 'customer' then
    v_columns := jsonb_build_array('Customer', 'Invoices', 'Revenue', 'Net paid', 'Owes (now)');
    select coalesce(jsonb_agg(jsonb_build_array(p.name, x.invoices, x.revenue, x.net_paid, private.party_balance(p_organization_id,p.id,p.kind)) order by lower(p.name)), '[]'::jsonb)
      into v_rows from public.parties p left join lateral (
        select count(*) filter (where per_doc.kind='SALE'::public.document_kind) as invoices,
               coalesce(sum(per_doc.revenue),0) as revenue, coalesce(sum(per_doc.net_paid),0) as net_paid
          from (
            select d.id, d.kind,
                   coalesce((select sum(case when e.account_code='SALES_REVENUE' then e.credit-e.debit else 0 end) from public.ledger_entries e where e.document_id=d.id),0) as revenue,
                   coalesce((select sum(case when e.account_code='CASH' then e.debit-e.credit else 0 end) from public.ledger_entries e where e.document_id=d.id),0) as net_paid
              from public.documents d
             where d.organization_id=p_organization_id and d.party_id=p.id and d.status='POSTED'::public.document_status and d.occurred_on between v_from and v_to and (v_location_id is null or d.location_id=v_location_id)
          ) per_doc
      ) x on true
     where p.organization_id=p_organization_id and p.kind='CUSTOMER'::public.party_kind;
  elsif v_group = 'stockmove' then
    v_columns := jsonb_build_array('SKU', 'Product', 'Opening', 'Received', 'Sold', 'Used in services', 'Adjusted', 'Moved between shops', 'Closing', 'Returned to stock');
    select coalesce(jsonb_agg(jsonb_build_array(sku, name, opening, received, sold, used, adjusted, transferred, opening+received-sold-used+adjusted+transferred, returned) order by lower(name)), '[]'::jsonb)
      into v_rows from (
        select p.sku::text as sku, p.name,
          coalesce(sum(m.quantity_delta) filter (where m.occurred_on < v_from),0) as opening,
          coalesce(sum(m.quantity_delta) filter (where m.occurred_on between v_from and v_to and m.kind in ('OPENING'::public.inventory_movement_kind,'PURCHASE'::public.inventory_movement_kind)),0) as received,
          coalesce(-sum(m.quantity_delta) filter (where m.occurred_on between v_from and v_to and m.kind='SALE'::public.inventory_movement_kind),0) as sold,
          0::numeric as used,
          coalesce(sum(m.quantity_delta) filter (where m.occurred_on between v_from and v_to and m.kind='ADJUSTMENT'::public.inventory_movement_kind),0) as adjusted,
          0::numeric as transferred,
          coalesce(sum(m.quantity_delta) filter (where m.occurred_on between v_from and v_to and m.kind='RETURN'::public.inventory_movement_kind),0) as returned
        from public.products p left join public.inventory_movements m on m.product_id=p.id and m.organization_id=p_organization_id and (v_location_id is null or m.location_id=v_location_id) and m.occurred_on <= v_to
       where p.organization_id=p_organization_id and p.kind='ITEM'::public.product_kind
       group by p.id,p.sku,p.name
    ) q where opening<>0 or received<>0 or sold<>0 or adjusted<>0 or returned<>0;
  else
    raise exception 'Unknown report type.' using errcode = 'P0001';
  end if;
  return jsonb_build_object('columns', v_columns, 'rows', v_rows, 'summary', v_summary, 'from', v_from, 'to', v_to);
end;
$$;

create or replace function public.get_attention(
  p_organization_id uuid,
  p_location text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
  v_items jsonb;
begin
  v_location_id := private.owner_location(p_organization_id, p_location, true);
  with acknowledgements as (
    select a.attention_key from public.attention_acknowledgements a where a.organization_id = p_organization_id
  ), raw_items as (
    select 'review:' || p.id::text as key, 'NEW_PRODUCT'::text as kind,
           p.name || ' needs review' as title,
           concat_ws(' · ', p.sku::text, p.kind::text, 'Added by ' || coalesce(pr.username, 'staff')) as detail,
           'products'::text as route, p.sku::text as sku, null::text as doc_no, true as can_resolve
      from public.products p left join public.profiles pr on pr.user_id=p.created_by
     where p.organization_id=p_organization_id and not p.reviewed
    union all
    select 'cost:' || p.id::text || ':' || extract(epoch from p.updated_at)::bigint::text, 'MISSING_COST',
           p.name || ' needs a cost', concat_ws(' · ',p.sku::text,'Set an incoming cost before stock is sold or corrected.'),
           'products', p.sku::text, null::text, false
      from public.products p
     where p.organization_id=p_organization_id and p.active and p.kind='ITEM'::public.product_kind and p.default_unit_cost<=0
       and not exists (select 1 from public.inventory_lots l where l.organization_id=p_organization_id and l.product_id=p.id and l.status='OPEN' and l.quantity_remaining>0 and (v_location_id is null or l.location_id=v_location_id))
    union all
    select 'flag:' || d.id::text, 'FLAGGED_RECORD', d.document_number || ' needs review',
           concat_ws(' · ', d.occurred_on::text, d.kind::text, (select string_agg(value, '; ' order by ordinality) from jsonb_array_elements_text(private.owner_document_flags(d.flags, d.metadata)) with ordinality x(value, ordinality))),
           'transactions', null::text, d.document_number, false
      from public.documents d
     where d.organization_id=p_organization_id and d.status='POSTED'::public.document_status
       and jsonb_array_length(private.owner_document_flags(d.flags, d.metadata))>0 and (v_location_id is null or d.location_id=v_location_id)
    union all
    select 'rejected:' || c.id::text, 'REJECTED_ACTION', 'A browser action was rejected',
           concat_ws(' · ', c.created_at::text, coalesce(pr.username,'unknown'), coalesce(c.error_message,'The server rejected this action.')),
           'sync', null::text, null::text, false
      from public.sync_commands c left join public.profiles pr on pr.user_id=c.actor_id
     where c.organization_id=p_organization_id and c.status='FAILED'::public.command_status
  ), active_items as (
    select r.* from raw_items r where not exists (select 1 from acknowledgements a where a.attention_key=r.key)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'key', key, 'kind', kind, 'title', title, 'detail', detail, 'route', route,
    'sku', sku, 'docNo', doc_no, 'canResolve', can_resolve
  ) order by kind, title), '[]'::jsonb) into v_items from active_items;
  return jsonb_build_object(
    'items', v_items, 'location', coalesce(p_location,''), 'generatedAt', now(),
    'counts', jsonb_build_object(
      'flagged', coalesce((select count(*) from jsonb_array_elements(v_items) item where item->>'kind'='FLAGGED_RECORD'),0),
      'newProducts', coalesce((select count(*) from jsonb_array_elements(v_items) item where item->>'kind'='NEW_PRODUCT'),0),
      'missingCosts', coalesce((select count(*) from jsonb_array_elements(v_items) item where item->>'kind'='MISSING_COST'),0),
      'rejected', coalesce((select count(*) from jsonb_array_elements(v_items) item where item->>'kind'='REJECTED_ACTION'),0)
    )
  );
end;
$$;

create or replace function public.get_audit(
  p_organization_id uuid,
  p_limit integer default 200
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit,200),500));
begin
  perform private.require_owner(p_organization_id);
  return jsonb_build_object('rows', coalesce((
    select jsonb_agg(jsonb_build_object(
      'time', a.occurred_at, 'user', coalesce(p.username,''), 'action', a.action,
      'result', a.outcome, 'detail', left(a.detail::text, 500)
    ) order by a.occurred_at desc)
      from (
        select * from public.audit_events where organization_id=p_organization_id order by occurred_at desc limit v_limit
      ) a left join public.profiles p on p.user_id=a.actor_id
  ), '[]'::jsonb));
end;
$$;

-- Account listing is deliberately read-only here. Creating/resetting Supabase
-- Auth users must run through a service-role Edge Function, never a database
-- RPC callable from a browser token.
create or replace function public.get_users(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_owner(p_organization_id);
  return jsonb_build_object('rows', coalesce((
    select jsonb_agg(jsonb_build_object(
      'userId', m.user_id::text, 'username', pr.username::text,
      'fullName', pr.display_name, 'role', m.role::text, 'active', m.active,
      'email', coalesce(pr.email,''), 'lastLogin', '',
      'location', coalesce(m.location_id::text,''), 'permissions', m.permissions
    ) order by case when m.role='OWNER'::public.cashbook_role then 0 else 1 end, lower(pr.display_name))
      from public.memberships m join public.profiles pr on pr.user_id=m.user_id
     where m.organization_id=p_organization_id
  ), '[]'::jsonb));
end;
$$;

-- Replace the initial migration's minimal sales-only dashboard with the full
-- Apps Script-compatible owner dashboard. All totals come from the immutable
-- ledger summary, so profit, cash movement and inventory remain explainable.
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
  v_location_id uuid;
  v_org public.organizations%rowtype;
  v_settings public.organization_settings%rowtype;
  v_today date;
  v_week date;
  v_month date;
  v_year date;
  v_stock_value numeric(18,2);
  v_debtors jsonb;
  v_creditors jsonb;
  v_low_stock jsonb;
  v_flagged jsonb;
  v_review jsonb;
  v_uncosted jsonb;
  v_rejected jsonb;
  v_shops jsonb;
  v_reps jsonb;
  v_series jsonb;
begin
  perform private.require_owner(p_organization_id);
  v_location_id := private.owner_location(p_organization_id, p_location_id::text, true);
  select * into v_org from public.organizations where id=p_organization_id;
  select * into v_settings from public.organization_settings where organization_id=p_organization_id;
  v_today := (now() at time zone v_org.timezone)::date;
  v_week := v_today - (extract(isodow from v_today)::integer - 1);
  v_month := date_trunc('month', v_today)::date;
  v_year := date_trunc('year', v_today)::date;

  select coalesce(sum(l.quantity_remaining*l.unit_cost),0) into v_stock_value
    from public.inventory_lots l where l.organization_id=p_organization_id and l.status='OPEN'
      and (v_location_id is null or l.location_id=v_location_id);
  select coalesce(jsonb_agg(jsonb_build_object('id',x.id::text,'name',x.name,'phone',coalesce(x.phone,''),'balance',x.balance) order by x.balance desc, lower(x.name)), '[]'::jsonb)
    into v_debtors
    from (
      select p.id, p.name, p.phone, private.party_balance(p_organization_id,p.id,p.kind) as balance
        from public.parties p
       where p.organization_id=p_organization_id and p.kind='CUSTOMER'::public.party_kind
       order by private.party_balance(p_organization_id,p.id,p.kind) desc, lower(p.name)
       limit 8
    ) x
   where x.balance > 0;
  select coalesce(jsonb_agg(jsonb_build_object('id',x.id::text,'name',x.name,'balance',x.balance) order by x.balance desc, lower(x.name)), '[]'::jsonb)
    into v_creditors
    from (
      select p.id, p.name, private.party_balance(p_organization_id,p.id,p.kind) as balance
        from public.parties p
       where p.organization_id=p_organization_id and p.kind='SUPPLIER'::public.party_kind
       order by private.party_balance(p_organization_id,p.id,p.kind) desc, lower(p.name)
       limit 5
    ) x
   where x.balance > 0;
  select coalesce(jsonb_agg(jsonb_build_object('sku',x.sku,'name',x.name,'stock',x.stock,'reorder',x.reorder,'unit',x.unit,'shop',x.shop) order by x.stock, lower(x.name)), '[]'::jsonb)
    into v_low_stock from (
      select p.sku::text as sku,p.name,p.reorder_level as reorder,p.unit,
             coalesce(sum(m.quantity_delta),0) as stock,coalesce(l.name,'') as shop
        from public.products p
        left join public.inventory_movements m on m.organization_id=p_organization_id and m.product_id=p.id and (v_location_id is null or m.location_id=v_location_id)
        left join public.locations l on l.id=v_location_id
       where p.organization_id=p_organization_id and p.active and p.kind='ITEM'::public.product_kind
       group by p.id,p.sku,p.name,p.reorder_level,p.unit,l.name
      having coalesce(sum(m.quantity_delta),0) <= case when p.reorder_level>0 then p.reorder_level else 0 end
    ) x;
  select coalesce(jsonb_agg(jsonb_build_object('docNo',d.document_number,'date',d.occurred_on,'rep',coalesce(pr.username,''),'flags',coalesce((select string_agg(value,'; ' order by ordinality) from jsonb_array_elements_text(private.owner_document_flags(d.flags, d.metadata)) with ordinality z(value,ordinality)),''),'type',d.kind::text,'shop',coalesce(l.name,'')) order by d.occurred_on desc,d.posted_at desc), '[]'::jsonb)
    into v_flagged from public.documents d left join public.profiles pr on pr.user_id=d.created_by left join public.locations l on l.id=d.location_id
   where d.organization_id=p_organization_id and d.status='POSTED'::public.document_status and jsonb_array_length(private.owner_document_flags(d.flags, d.metadata))>0 and (v_location_id is null or d.location_id=v_location_id)
     and not exists (select 1 from public.attention_acknowledgements a where a.organization_id=p_organization_id and a.attention_key='flag:'||d.id::text);
  select coalesce(jsonb_agg(jsonb_build_object('sku',p.sku::text,'name',p.name,'type',p.kind::text,'price',p.selling_price,'addedBy',coalesce(pr.username,'')) order by lower(p.name)), '[]'::jsonb)
    into v_review from public.products p left join public.profiles pr on pr.user_id=p.created_by
   where p.organization_id=p_organization_id and not p.reviewed and not exists (select 1 from public.attention_acknowledgements a where a.organization_id=p_organization_id and a.attention_key='review:'||p.id::text);
  select coalesce(jsonb_agg(jsonb_build_object('sku',p.sku::text,'name',p.name,'issue','Set an incoming cost before stock is sold or corrected.','type',p.kind::text,'attentionKey','cost:'||p.id::text||':'||extract(epoch from p.updated_at)::bigint::text) order by lower(p.name)), '[]'::jsonb)
    into v_uncosted from public.products p
   where p.organization_id=p_organization_id and p.active and p.kind='ITEM'::public.product_kind and p.default_unit_cost<=0
     and not exists (select 1 from public.inventory_lots il where il.organization_id=p_organization_id and il.product_id=p.id and il.status='OPEN' and il.quantity_remaining>0 and (v_location_id is null or il.location_id=v_location_id))
     and not exists (select 1 from public.attention_acknowledgements a where a.organization_id=p_organization_id and a.attention_key='cost:'||p.id::text||':'||extract(epoch from p.updated_at)::bigint::text);
  select coalesce(jsonb_agg(jsonb_build_object('time',c.created_at,'user',coalesce(pr.username,''),'clientId',c.client_id,'detail',coalesce(c.error_message,'The server rejected this action.')) order by c.created_at desc), '[]'::jsonb)
    into v_rejected from public.sync_commands c left join public.profiles pr on pr.user_id=c.actor_id
   where c.organization_id=p_organization_id and c.status='FAILED'::public.command_status and not exists (select 1 from public.attention_acknowledgements a where a.organization_id=p_organization_id and a.attention_key='rejected:'||c.id::text);
  select coalesce(jsonb_agg(jsonb_build_object('id',l.id::text,'name',l.name,'todayRevenue',(s.today->>'revenue')::numeric,'monthRevenue',(s.month->>'revenue')::numeric,'monthGross',(s.month->>'gross')::numeric,'monthStockAdjustments',(s.month->>'stockAdjustments')::numeric,'monthExpenses',(s.month->>'expenses')::numeric,'monthNet',(s.month->>'net')::numeric,'stockValue',coalesce((select sum(il.quantity_remaining*il.unit_cost) from public.inventory_lots il where il.organization_id=p_organization_id and il.location_id=l.id and il.status='OPEN'),0)) order by lower(l.name)), '[]'::jsonb)
    into v_shops from public.locations l cross join lateral (select private.owner_period_summary(p_organization_id,l.id,v_today,v_today) as today,private.owner_period_summary(p_organization_id,l.id,v_month,v_today) as month) s
   where l.organization_id=p_organization_id and l.active and (v_location_id is null or l.id=v_location_id);
  select coalesce(jsonb_agg(jsonb_build_object('rep',coalesce(pr.username,'Unknown'),'todayRevenue',coalesce(x.today_revenue,0),'todayQty',coalesce(x.today_qty,0),'todayCollected',coalesce(x.today_collected,0),'todayExpenses',coalesce(x.today_expenses,0),'weekRevenue',coalesce(x.week_revenue,0),'weekQty',coalesce(x.week_qty,0),'weekCollected',coalesce(x.week_collected,0),'weekExpenses',coalesce(x.week_expenses,0)) order by lower(coalesce(pr.username,'Unknown'))), '[]'::jsonb)
    into v_reps from (
      select d.created_by,
        coalesce(sum(case when d.occurred_on=v_today and e.account_code='SALES_REVENUE' then e.credit-e.debit else 0 end),0) as today_revenue,
        coalesce(sum(case when d.occurred_on=v_today and e.account_code='CASH' and e.debit>0 then e.debit else 0 end),0) as today_collected,
        coalesce(sum(case when d.occurred_on=v_today and (e.account_code = 'EXPENSE' or e.account_code like 'EXPENSE:%') then e.debit-e.credit else 0 end),0) as today_expenses,
        coalesce(sum(case when d.occurred_on between v_week and v_today and e.account_code='SALES_REVENUE' then e.credit-e.debit else 0 end),0) as week_revenue,
        coalesce(sum(case when d.occurred_on between v_week and v_today and e.account_code='CASH' and e.debit>0 then e.debit else 0 end),0) as week_collected,
        coalesce(sum(case when d.occurred_on between v_week and v_today and (e.account_code = 'EXPENSE' or e.account_code like 'EXPENSE:%') then e.debit-e.credit else 0 end),0) as week_expenses,
        coalesce((select sum(case when dd.occurred_on=v_today and dd.kind='SALE'::public.document_kind then dl.quantity when dd.occurred_on=v_today and dd.kind='RETURN'::public.document_kind then -dl.quantity else 0 end) from public.documents dd join public.document_lines dl on dl.document_id=dd.id where dd.organization_id=p_organization_id and dd.created_by=d.created_by and dd.status='POSTED'::public.document_status and (v_location_id is null or dd.location_id=v_location_id)),0) as today_qty,
        coalesce((select sum(case when dd.occurred_on between v_week and v_today and dd.kind='SALE'::public.document_kind then dl.quantity when dd.occurred_on between v_week and v_today and dd.kind='RETURN'::public.document_kind then -dl.quantity else 0 end) from public.documents dd join public.document_lines dl on dl.document_id=dd.id where dd.organization_id=p_organization_id and dd.created_by=d.created_by and dd.status='POSTED'::public.document_status and (v_location_id is null or dd.location_id=v_location_id)),0) as week_qty
      from public.documents d left join public.ledger_entries e on e.document_id=d.id
     where d.organization_id=p_organization_id and d.status='POSTED'::public.document_status and d.occurred_on between v_week and v_today and (v_location_id is null or d.location_id=v_location_id)
     group by d.created_by
    ) x left join public.profiles pr on pr.user_id=x.created_by;
  select coalesce(jsonb_agg(jsonb_build_object('d',q.day::date,'revenue',(q.s->>'revenue')::numeric,'net',(q.s->>'net')::numeric,'expenses',(q.s->>'expenses')::numeric) order by q.day), '[]'::jsonb)
    into v_series from (
      select d.day, private.owner_period_summary(p_organization_id,v_location_id,d.day::date,d.day::date) as s
        from generate_series(v_today-13,v_today,interval '1 day') d(day)
    ) q;
  return jsonb_build_object(
    'periods',jsonb_build_object('today',v_today,'week',v_week,'month',v_month,'year',v_year),
    'location',coalesce((select code::text from public.locations where id=v_location_id),''),
    'today',private.owner_period_summary(p_organization_id,v_location_id,v_today,v_today),
    'week',private.owner_period_summary(p_organization_id,v_location_id,v_week,v_today),
    'month',private.owner_period_summary(p_organization_id,v_location_id,v_month,v_today),
    'year',private.owner_period_summary(p_organization_id,v_location_id,v_year,v_today),
    'receivables',coalesce((select sum(greatest(private.party_balance(p_organization_id,p.id,p.kind),0)) from public.parties p where p.organization_id=p_organization_id and p.kind='CUSTOMER'::public.party_kind),0),
    'payables',coalesce((select sum(greatest(private.party_balance(p_organization_id,p.id,p.kind),0)) from public.parties p where p.organization_id=p_organization_id and p.kind='SUPPLIER'::public.party_kind),0),
    'debtors',v_debtors,'creditors',v_creditors,'stockValue',v_stock_value,'lowStock',v_low_stock,
    'productCount',(select count(*) from public.products where organization_id=p_organization_id),
    'flagged',v_flagged,'toReview',v_review,'uncosted',v_uncosted,'rejected',v_rejected,
    'closedUntil',v_settings.closed_until,'multiShop',(select count(*)>1 from public.locations where organization_id=p_organization_id and active),
    'shops',v_shops,'reps',v_reps,'series',v_series
  );
end;
$$;

revoke all on function private.owner_location(uuid, text, boolean) from public;
revoke all on function private.owner_text_array(jsonb) from public;
revoke all on function private.owner_json_list(jsonb) from public;
revoke all on function private.owner_document_flags(jsonb, jsonb) from public;
revoke all on function private.owner_product_cost(uuid, uuid, uuid) from public;
revoke all on function private.owner_period_summary(uuid, uuid, date, date) from public;

revoke all on function public.get_lists(uuid) from public, anon;
revoke all on function public.get_products(uuid, text) from public, anon;
revoke all on function public.get_parties(uuid) from public, anon;
revoke all on function public.upsert_product(uuid, jsonb) from public, anon;
revoke all on function public.upsert_party(uuid, jsonb) from public, anon;
revoke all on function public.upsert_location(uuid, jsonb) from public, anon;
revoke all on function public.get_config(uuid) from public, anon;
revoke all on function public.update_settings(uuid, jsonb) from public, anon;
revoke all on function public.close_period(uuid, date) from public, anon;
revoke all on function public.acknowledge_attention(uuid, jsonb, text, text) from public, anon;
revoke all on function public.get_ledger(uuid, text, date, date, text, text, integer) from public, anon;
revoke all on function public.get_statement(uuid, uuid) from public, anon;
revoke all on function public.get_stock_card(uuid, text, text) from public, anon;
revoke all on function public.get_report(uuid, text, date, date, text) from public, anon;
revoke all on function public.get_attention(uuid, text) from public, anon;
revoke all on function public.get_audit(uuid, integer) from public, anon;
revoke all on function public.get_users(uuid) from public, anon;

grant execute on function public.get_lists(uuid) to authenticated;
grant execute on function public.get_products(uuid, text) to authenticated;
grant execute on function public.get_parties(uuid) to authenticated;
grant execute on function public.upsert_product(uuid, jsonb) to authenticated;
grant execute on function public.upsert_party(uuid, jsonb) to authenticated;
grant execute on function public.upsert_location(uuid, jsonb) to authenticated;
grant execute on function public.get_config(uuid) to authenticated;
grant execute on function public.update_settings(uuid, jsonb) to authenticated;
grant execute on function public.close_period(uuid, date) to authenticated;
grant execute on function public.acknowledge_attention(uuid, jsonb, text, text) to authenticated;
grant execute on function public.get_ledger(uuid, text, date, date, text, text, integer) to authenticated;
grant execute on function public.get_statement(uuid, uuid) to authenticated;
grant execute on function public.get_stock_card(uuid, text, text) to authenticated;
grant execute on function public.get_report(uuid, text, date, date, text) to authenticated;
grant execute on function public.get_attention(uuid, text) to authenticated;
grant execute on function public.get_audit(uuid, integer) to authenticated;
grant execute on function public.get_users(uuid) to authenticated;






