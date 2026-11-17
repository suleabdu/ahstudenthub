-- Defined before the snapshot read model so PL/pgSQL can resolve the helper
-- while compiling `get_catalog_snapshot` on every supported PostgreSQL build.
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
