-- Cashbook Supabase migration 2: immutable accounting and FIFO inventory.
-- All currency uses NUMERIC rather than floating-point values.  Quantities use
-- four decimal places so fractional units remain traceable.

create table public.parties (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  kind public.party_kind not null,
  name text not null check (char_length(btrim(name)) between 1 and 240),
  phone text,
  address text,
  credit_limit numeric(18, 2) not null default 0 check (credit_limit >= 0),
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, kind, name)
);
create index parties_org_kind_active_idx on public.parties(organization_id, kind, active, name);
create unique index parties_org_kind_lower_name_idx on public.parties(organization_id, kind, lower(name));
create trigger parties_touch_updated_at before update on public.parties
for each row execute function private.touch_updated_at();

create table public.documents (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  location_id uuid references public.locations(id) on delete restrict,
  kind public.document_kind not null,
  status public.document_status not null default 'POSTED',
  document_number text not null,
  occurred_on date not null,
  party_id uuid references public.parties(id) on delete restrict,
  source_client_id text,
  subtotal numeric(18, 2) not null default 0 check (subtotal >= 0),
  total numeric(18, 2) not null default 0 check (total >= 0),
  amount_paid numeric(18, 2) not null default 0 check (amount_paid >= 0),
  balance_due numeric(18, 2) not null default 0 check (balance_due >= 0),
  payment_method text,
  notes text,
  reversed_document_id uuid references public.documents(id) on delete restrict,
  created_by uuid references auth.users(id) on delete set null,
  posted_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  unique (organization_id, document_number),
  -- `source_client_id` is the browser idempotency reference.  PostgreSQL's
  -- ordinary UNIQUE semantics intentionally allow many manual documents
  -- without one, while still preventing duplicate non-null client IDs.
  unique (organization_id, source_client_id),
  check (amount_paid <= total),
  check (balance_due = total - amount_paid)
);
create index documents_org_date_idx on public.documents(organization_id, occurred_on desc, posted_at desc);
create index documents_org_party_idx on public.documents(organization_id, party_id, occurred_on desc) where party_id is not null;
create index documents_org_location_idx on public.documents(organization_id, location_id, occurred_on desc);

create table public.document_lines (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.documents(id) on delete restrict,
  organization_id uuid not null references public.organizations(id) on delete cascade,
  line_number integer not null check (line_number > 0),
  product_id uuid references public.products(id) on delete restrict,
  description text not null,
  quantity numeric(18, 4) not null check (quantity > 0),
  unit_price numeric(18, 2) not null default 0 check (unit_price >= 0),
  unit_cost numeric(18, 2) not null default 0 check (unit_cost >= 0),
  line_total numeric(18, 2) not null check (line_total >= 0),
  cost_of_goods numeric(18, 2) not null default 0 check (cost_of_goods >= 0),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (document_id, line_number)
);
create index document_lines_org_product_idx on public.document_lines(organization_id, product_id);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  document_id uuid not null references public.documents(id) on delete restrict,
  party_id uuid references public.parties(id) on delete restrict,
  payment_method text not null,
  amount numeric(18, 2) not null check (amount > 0),
  paid_on date not null,
  reference text,
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index payments_org_date_idx on public.payments(organization_id, paid_on desc);
create index payments_org_party_idx on public.payments(organization_id, party_id, paid_on desc) where party_id is not null;

-- One receipt/purchase layer equals one FIFO lot.  Quantity remaining is the
-- only mutable accounting inventory field and is changed exclusively by
-- transactional posting functions.
create table public.inventory_lots (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  source_document_id uuid references public.documents(id) on delete restrict,
  source_line_id uuid references public.document_lines(id) on delete restrict,
  received_on date not null,
  received_quantity numeric(18, 4) not null check (received_quantity > 0),
  quantity_remaining numeric(18, 4) not null check (quantity_remaining >= 0),
  unit_cost numeric(18, 2) not null check (unit_cost >= 0),
  party_id uuid references public.parties(id) on delete restrict,
  reference text,
  status text not null default 'OPEN' check (status in ('OPEN', 'DEPLETED', 'VOID')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (quantity_remaining <= received_quantity)
);
create index inventory_lots_fifo_idx on public.inventory_lots(organization_id, location_id, product_id, received_on, created_at)
where quantity_remaining > 0 and status = 'OPEN';
create trigger inventory_lots_touch_updated_at before update on public.inventory_lots
for each row execute function private.touch_updated_at();

create table public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  location_id uuid not null references public.locations(id) on delete restrict,
  product_id uuid not null references public.products(id) on delete restrict,
  lot_id uuid references public.inventory_lots(id) on delete restrict,
  document_id uuid references public.documents(id) on delete restrict,
  document_line_id uuid references public.document_lines(id) on delete restrict,
  kind public.inventory_movement_kind not null,
  occurred_on date not null,
  quantity_delta numeric(18, 4) not null check (quantity_delta <> 0),
  unit_cost numeric(18, 2) not null default 0 check (unit_cost >= 0),
  notes text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index inventory_movements_balance_idx on public.inventory_movements(organization_id, location_id, product_id, occurred_on);

-- The allocation table freezes the exact FIFO cost used by every sale line.
-- Historical COGS consequently never changes when a later purchase price does.
create table public.lot_allocations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  sale_line_id uuid not null references public.document_lines(id) on delete restrict,
  lot_id uuid not null references public.inventory_lots(id) on delete restrict,
  quantity numeric(18, 4) not null check (quantity > 0),
  unit_cost numeric(18, 2) not null check (unit_cost >= 0),
  created_at timestamptz not null default now(),
  unique (sale_line_id, lot_id)
);
create index lot_allocations_lot_idx on public.lot_allocations(lot_id);

-- Double-entry rows are append-only.  Account balances and reports are views
-- over this audit trail rather than mutable spreadsheet totals.
create table public.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  document_id uuid references public.documents(id) on delete restrict,
  entry_date date not null,
  account_code text not null check (char_length(btrim(account_code)) between 1 and 80),
  debit numeric(18, 2) not null default 0 check (debit >= 0),
  credit numeric(18, 2) not null default 0 check (credit >= 0),
  party_id uuid references public.parties(id) on delete restrict,
  product_id uuid references public.products(id) on delete restrict,
  memo text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check ((debit = 0 and credit > 0) or (credit = 0 and debit > 0))
);
create index ledger_entries_org_date_idx on public.ledger_entries(organization_id, entry_date desc, created_at desc);
create index ledger_entries_org_account_idx on public.ledger_entries(organization_id, account_code, entry_date);
create index ledger_entries_org_party_idx on public.ledger_entries(organization_id, party_id, entry_date) where party_id is not null;

create table public.audit_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  action text not null check (char_length(btrim(action)) between 1 and 120),
  entity_type text,
  entity_id uuid,
  client_id text,
  outcome text not null default 'OK',
  detail jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);
create index audit_events_org_time_idx on public.audit_events(organization_id, occurred_at desc);

-- Client IDs are durable idempotency keys for the browser's offline outbox.
-- A device retry can always recover the original result rather than double
-- posting a sale, payment, or stock movement.
create table public.sync_commands (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  client_id text not null check (char_length(btrim(client_id)) between 1 and 200),
  actor_id uuid references auth.users(id) on delete set null,
  action text not null check (char_length(btrim(action)) between 1 and 80),
  status public.command_status not null default 'PROCESSING',
  request jsonb not null default '{}'::jsonb,
  response jsonb,
  error_code text,
  error_message text,
  document_id uuid references public.documents(id) on delete set null,
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  unique (organization_id, client_id)
);
create index sync_commands_org_status_idx on public.sync_commands(organization_id, status, created_at desc);

-- Attention is an acknowledgement layer over source records.  Resolving an
-- issue never deletes a failed command or financial/audit evidence.
create table public.attention_acknowledgements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  attention_key text not null,
  acknowledged_by uuid not null references auth.users(id) on delete restrict,
  resolution text not null check (resolution in ('RESOLVED', 'DISMISSED')),
  note text,
  acknowledged_at timestamptz not null default now(),
  unique (organization_id, attention_key)
);

create or replace function private.reject_immutable_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Cashbook accounting records are append-only; post a reversal or adjustment instead.'
    using errcode = 'P0001';
end;
$$;

create trigger document_lines_immutable before update or delete on public.document_lines
for each row execute function private.reject_immutable_mutation();
create trigger payments_immutable before update or delete on public.payments
for each row execute function private.reject_immutable_mutation();
create trigger inventory_movements_immutable before update or delete on public.inventory_movements
for each row execute function private.reject_immutable_mutation();
create trigger lot_allocations_immutable before update or delete on public.lot_allocations
for each row execute function private.reject_immutable_mutation();
create trigger ledger_entries_immutable before update or delete on public.ledger_entries
for each row execute function private.reject_immutable_mutation();
create trigger audit_events_immutable before update or delete on public.audit_events
for each row execute function private.reject_immutable_mutation();
