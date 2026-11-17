-- Cashbook Supabase migration 8: compatibility corrections for the existing
-- Owner and Sales Rep PWAs.
--
-- This migration does not alter any financial records.  It tightens the
-- read-model contract so the Apps-Script-era screens continue to show the
-- right labels, counts and scope after their backend changes to Supabase.

-- The sales app needs an invoice count as well as money/quantity totals.  It
-- also needs its own expenses and customer receipts when a representative is
-- scoped to their own activity.  All figures remain derived from posted,
-- immutable documents and ledger rows.
create or replace function public.sales_totals_for_period(
  p_organization_id uuid,
  p_location_id uuid,
  p_user_id uuid,
  p_from date,
  p_to date
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
  v_membership public.memberships%rowtype;
  v_settings public.organization_settings%rowtype;
  v_location_id uuid;
  v_user_id uuid;
begin
  -- This helper is executable by PostgREST, so it must be safe even when it
  -- is called directly instead of through `get_catalog_snapshot`.
  v_membership := private.require_membership(p_organization_id);
  v_location_id := private.read_location(p_organization_id, p_location_id);
  select * into v_settings from public.organization_settings where organization_id = p_organization_id;
  if v_membership.role = 'REP'::public.cashbook_role then
    if p_user_id is not null and p_user_id <> auth.uid() then
      raise exception 'Sales staff may not request another user’s totals.' using errcode = '42501';
    end if;
    v_user_id := case when v_settings.reps_see_company_totals then null else auth.uid() end;
  else
    v_user_id := p_user_id;
  end if;
  with scoped_documents as (
    select d.id, d.kind, d.total, d.amount_paid
      from public.documents d
     where d.organization_id = p_organization_id
       and d.status = 'POSTED'::public.document_status
       and d.occurred_on between p_from and p_to
       and (v_location_id is null or d.location_id = v_location_id)
       and (v_user_id is null or d.created_by = v_user_id)
  ), sale_documents as (
    select * from scoped_documents where kind = 'SALE'::public.document_kind
  ), line_totals as (
    select coalesce(sum(l.quantity), 0) as qty,
           coalesce(sum(l.cost_of_goods), 0) as cogs
      from public.document_lines l
      join sale_documents d on d.id = l.document_id
  ), cash_totals as (
    select coalesce(sum(e.debit - e.credit), 0) as cash_net,
           coalesce(sum(e.debit) filter (where e.debit > 0), 0) as cash_in,
           coalesce(sum(e.credit) filter (where e.credit > 0), 0) as cash_out
      from public.ledger_entries e
      join scoped_documents d on d.id = e.document_id
     where e.account_code = 'CASH'
  ), expense_totals as (
    select coalesce(sum(e.debit - e.credit), 0) as expenses
      from public.ledger_entries e
      join scoped_documents d on d.id = e.document_id
     where e.account_code = 'EXPENSE' or e.account_code like 'EXPENSE:%'
  ), totals as (
    select coalesce((select count(*) from sale_documents), 0) as invoices,
           coalesce((select sum(total) from sale_documents), 0) as revenue,
           coalesce((select qty from line_totals), 0) as qty,
           coalesce((select cogs from line_totals), 0) as cogs,
           coalesce((select expenses from expense_totals), 0) as expenses,
           coalesce((select cash_in from cash_totals), 0) as cash_in,
           coalesce((select cash_out from cash_totals), 0) as cash_out,
           coalesce((select cash_net from cash_totals), 0) as cash_net
  )
  select jsonb_build_object(
    'invoices', invoices,
    'revenue', revenue,
    'cashIn', cash_in,
    'cashOut', cash_out,
    'cashNet', cash_net,
    'qty', qty,
    'cogs', cogs,
    'gross', revenue - cogs,
    'expenses', expenses,
    'net', revenue - cogs - expenses
  ) into v_result from totals;
  return v_result;
end;
$$;
-- Replace the early snapshot with one that honours the owner-configured
-- Sales Rep scope.  A representative is always constrained to the shop in
-- their membership; the setting controls whether their cards cover only
-- their activity or all activity at that shop.
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
  v_show_company_totals boolean;
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
  v_show_company_totals := v_membership.role <> 'REP'::public.cashbook_role
    or v_settings.reps_see_company_totals;
  v_scope_user := case when v_membership.role = 'REP'::public.cashbook_role
                              and not v_settings.reps_see_company_totals
                       then auth.uid() else null end;

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
      select p.sku::text as sku,
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
                                    and (v_location_id is null or l.location_id = v_location_id)), p.default_unit_cost, 0) end as display_cost,
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
    'version', 'supabase-production',
    'location', coalesce(v_location.code::text, ''),
    'locationName', coalesce(v_location.name, 'All shops'),
    'permissions', v_membership.permissions,
    'company', v_org.name,
    'currency', v_org.currency_symbol,
    'footer', v_settings.receipt_footer,
    'expenseCategories', v_settings.expense_categories,
    'paymentMethods', v_settings.payment_methods,
    'categories', v_categories,
    'showCompanyTotals', v_show_company_totals,
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

-- Translate Supabase's compact accounting document types back to the names
-- used in the existing Owner transaction screen.  For example, a stock
-- purchase is still displayed as “Stock in”, while its immutable database
-- document remains `PURCHASE` for accounting/reporting purposes.
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
  if p_from is not null and p_to is not null and p_from > p_to then
    raise exception 'The start date must not be after the end date.' using errcode = 'P0001';
  end if;

  with shaped as (
    select d.id,
           d.document_number,
           d.occurred_on,
           d.status,
           d.total,
           d.amount_paid,
           d.notes,
           d.metadata,
           d.posted_at,
           p.id as party_id,
           p.name as party_name,
           l.name as location_name,
           coalesce(pr.username, '') as rep,
           case
             when d.metadata->>'workflow' = 'TRANSFER' then 'TRANSFER'
             when d.metadata->>'workflow' = 'OPENING_BALANCE' then 'OPENING_BAL'
             when d.metadata->>'workflow' in ('COST_REVALUE', 'PURCHASE_COST_RESET') then 'COST_REVALUE'
             when d.kind in ('PURCHASE'::public.document_kind, 'OPENING_STOCK'::public.document_kind) then 'STOCK_IN'
             else d.kind::text
           end as display_type,
           private.owner_document_flags(d.flags, d.metadata) as flags,
           coalesce((select sum(dl.cost_of_goods) from public.document_lines dl where dl.document_id = d.id), 0) as cogs,
           coalesce((select jsonb_agg(jsonb_build_object(
             'sku', coalesce(dl.metadata->>'sku', ''), 'product', dl.description,
             'qty', dl.quantity, 'price', dl.unit_price, 'cost', dl.unit_cost,
             'amount', dl.line_total, 'cogs', dl.cost_of_goods
           ) order by dl.line_number) from public.document_lines dl where dl.document_id = d.id), '[]'::jsonb) as lines
      from public.documents d
      left join public.parties p on p.id = d.party_id
      left join public.locations l on l.id = d.location_id
      left join public.profiles pr on pr.user_id = d.created_by
     where d.organization_id = p_organization_id
       and (v_location_id is null or d.location_id = v_location_id)
       and (p_from is null or d.occurred_on >= p_from)
       and (p_to is null or d.occurred_on <= p_to)
       and (v_query is null or lower(concat_ws(' ', d.document_number, d.notes,
             coalesce(p.name, ''), coalesce((select string_agg(coalesce(dl.description,'') || ' ' || coalesce(dl.metadata->>'sku',''), ' ')
                                               from public.document_lines dl where dl.document_id = d.id), ''))) like '%' || v_query || '%')
  ), filtered as (
    select * from shaped where v_type is null or display_type = v_type
  )
  select count(*) into v_total from filtered;

  with shaped as (
    select d.id,
           d.document_number,
           d.occurred_on,
           d.status,
           d.total,
           d.amount_paid,
           d.notes,
           d.metadata,
           d.posted_at,
           p.id as party_id,
           p.name as party_name,
           l.name as location_name,
           coalesce(pr.username, '') as rep,
           case
             when d.metadata->>'workflow' = 'TRANSFER' then 'TRANSFER'
             when d.metadata->>'workflow' = 'OPENING_BALANCE' then 'OPENING_BAL'
             when d.metadata->>'workflow' in ('COST_REVALUE', 'PURCHASE_COST_RESET') then 'COST_REVALUE'
             when d.kind in ('PURCHASE'::public.document_kind, 'OPENING_STOCK'::public.document_kind) then 'STOCK_IN'
             else d.kind::text
           end as display_type,
           private.owner_document_flags(d.flags, d.metadata) as flags,
           coalesce((select sum(dl.cost_of_goods) from public.document_lines dl where dl.document_id = d.id), 0) as cogs,
           coalesce((select jsonb_agg(jsonb_build_object(
             'sku', coalesce(dl.metadata->>'sku', ''), 'product', dl.description,
             'qty', dl.quantity, 'price', dl.unit_price, 'cost', dl.unit_cost,
             'amount', dl.line_total, 'cogs', dl.cost_of_goods
           ) order by dl.line_number) from public.document_lines dl where dl.document_id = d.id), '[]'::jsonb) as lines
      from public.documents d
      left join public.parties p on p.id = d.party_id
      left join public.locations l on l.id = d.location_id
      left join public.profiles pr on pr.user_id = d.created_by
     where d.organization_id = p_organization_id
       and (v_location_id is null or d.location_id = v_location_id)
       and (p_from is null or d.occurred_on >= p_from)
       and (p_to is null or d.occurred_on <= p_to)
       and (v_query is null or lower(concat_ws(' ', d.document_number, d.notes,
             coalesce(p.name, ''), coalesce((select string_agg(coalesce(dl.description,'') || ' ' || coalesce(dl.metadata->>'sku',''), ' ')
                                               from public.document_lines dl where dl.document_id = d.id), ''))) like '%' || v_query || '%')
  ), filtered as (
    select * from shaped where v_type is null or display_type = v_type
  ), limited as (
    select * from filtered order by occurred_on desc, posted_at desc, document_number desc limit v_limit
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'docNo', document_number,
    'date', occurred_on,
    'type', display_type,
    'party', coalesce(party_name, ''),
    'partyId', party_id::text,
    'category', coalesce(metadata->>'category', ''),
    'rep', rep,
    'shop', coalesce(location_name, ''),
    'amount', total,
    'paid', amount_paid,
    'refunded', case when display_type = 'RETURN' then amount_paid else 0 end,
    'cogs', cogs,
    'lines', lines,
    'materials', '[]'::jsonb,
    'flags', coalesce((select string_agg(value, '; ' order by ordinality)
                         from jsonb_array_elements_text(flags) with ordinality x(value, ordinality)), ''),
    'notes', coalesce(notes, ''),
    'reversed', status <> 'POSTED'::public.document_status,
    'ts', posted_at
  ) order by occurred_on desc, posted_at desc, document_number desc), '[]'::jsonb)
    into v_docs from limited;

  return jsonb_build_object('total', v_total, 'docs', v_docs);
end;
$$;

revoke all on function public.sales_totals_for_period(uuid, uuid, uuid, date, date) from public, anon;
revoke all on function public.get_catalog_snapshot(uuid, uuid) from public, anon;
revoke all on function public.get_ledger(uuid, text, date, date, text, text, integer) from public, anon;
grant execute on function public.sales_totals_for_period(uuid, uuid, uuid, date, date) to authenticated;
grant execute on function public.get_catalog_snapshot(uuid, uuid) to authenticated;
grant execute on function public.get_ledger(uuid, text, date, date, text, text, integer) to authenticated;
