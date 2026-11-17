-- Keep the catalog's suggested next purchase cost aligned with actual receipts.
-- This never changes a historic sale allocation or an existing FIFO lot: it
-- only remembers the most recent incoming cost for the product editor.

create or replace function private.remember_received_product_cost()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_source_kind public.document_kind;
begin
  if new.source_document_id is null then
    return new;
  end if;

  select d.kind
    into v_source_kind
    from public.documents d
   where d.id = new.source_document_id
     and d.organization_id = new.organization_id;

  -- Transfers and physical-count corrections deliberately do not overwrite a
  -- product's future purchase cost. A supplier purchase or first opening
  -- stock receipt is an explicit, auditable incoming-cost source.
  if v_source_kind in ('PURCHASE'::public.document_kind, 'OPENING_STOCK'::public.document_kind) then
    update public.products p
       set default_unit_cost = new.unit_cost,
           reviewed = true,
           reviewed_at = now()
     where p.id = new.product_id
       and p.organization_id = new.organization_id
       and p.kind = 'ITEM'::public.product_kind;
  end if;

  return new;
end;
$$;

drop trigger if exists inventory_lots_remember_received_cost on public.inventory_lots;
create trigger inventory_lots_remember_received_cost
after insert on public.inventory_lots
for each row execute function private.remember_received_product_cost();

-- Existing projects may have been populated before this trigger was added.
-- Populate only blank catalog costs, preserving an owner's explicitly set
-- future purchase cost. Reversed source documents are excluded.
with latest_received_cost as (
  select distinct on (l.product_id)
    l.product_id,
    l.unit_cost
  from public.inventory_lots l
  join public.documents d on d.id = l.source_document_id
  where d.kind in ('PURCHASE'::public.document_kind, 'OPENING_STOCK'::public.document_kind)
    and d.status = 'POSTED'::public.document_status
  order by l.product_id, d.occurred_on desc, l.created_at desc, l.id desc
)
update public.products p
   set default_unit_cost = c.unit_cost,
       reviewed = true,
       reviewed_at = coalesce(p.reviewed_at, now())
  from latest_received_cost c
 where p.id = c.product_id
   and p.kind = 'ITEM'::public.product_kind
   and p.default_unit_cost = 0;

revoke all on function private.remember_received_product_cost() from public;
