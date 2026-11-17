-- Cashbook Supabase migration 1: tenancy, identity, catalogue and imports.
--
-- This schema is deliberately independent of the legacy spreadsheet.  No
-- data is copied during a migration.  Product rows enter through the staging
-- tables/RPC in a later migration, after a human has reviewed the import.

create extension if not exists pgcrypto;
create extension if not exists citext;

create schema if not exists private;
revoke all on schema private from public;

create type public.cashbook_role as enum ('OWNER', 'MANAGER', 'REP');
create type public.product_kind as enum ('ITEM', 'SERVICE');
create type public.party_kind as enum ('CUSTOMER', 'SUPPLIER');
create type public.document_kind as enum (
  'SALE', 'PURCHASE', 'EXPENSE', 'PAYMENT_IN', 'PAYMENT_OUT',
  'OPENING_STOCK', 'STOCK_ADJUSTMENT', 'RETURN', 'OWNER_CONTRIBUTION',
  'OWNER_WITHDRAWAL', 'REVERSAL'
);
create type public.document_status as enum ('POSTED', 'REVERSED', 'CANCELLED');
create type public.command_status as enum ('PROCESSING', 'SUCCEEDED', 'FAILED');
create type public.inventory_movement_kind as enum ('OPENING', 'PURCHASE', 'SALE', 'RETURN', 'ADJUSTMENT', 'REVERSAL');

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  slug citext not null unique,
  name text not null check (char_length(btrim(name)) between 1 and 160),
  currency_code text not null default 'NGN' check (currency_code ~ '^[A-Z]{3}$'),
  currency_symbol text not null default '₦' check (char_length(currency_symbol) between 1 and 8),
  timezone text not null default 'Africa/Lagos',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.organization_settings (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  closed_until date,
  data_epoch bigint not null default 1 check (data_epoch > 0),
  oversell_policy text not null default 'BLOCK' check (oversell_policy in ('BLOCK', 'FLAG')),
  payment_methods jsonb not null default '["Cash", "Transfer", "POS", "Cheque"]'::jsonb,
  expense_categories jsonb not null default '[]'::jsonb,
  receipt_footer text not null default 'Thank you for your patronage.',
  target_margin_pct numeric(7, 2) not null default 30 check (target_margin_pct >= 0 and target_margin_pct <= 100),
  updated_at timestamptz not null default now()
);

create table public.locations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  code citext not null,
  name text not null check (char_length(btrim(name)) between 1 and 120),
  address text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, code)
);

create table public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  username citext not null unique check (btrim(username::text) <> ''),
  display_name text not null check (char_length(btrim(display_name)) between 1 and 160),
  email citext,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.memberships (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role public.cashbook_role not null,
  location_id uuid references public.locations(id) on delete set null,
  permissions jsonb not null default '[]'::jsonb check (jsonb_typeof(permissions) = 'array'),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, user_id)
);
create index memberships_user_active_idx on public.memberships(user_id) where active;
create index memberships_org_location_idx on public.memberships(organization_id, location_id) where active;

create table public.products (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  sku citext not null,
  name text not null check (char_length(btrim(name)) between 1 and 240),
  category text not null default '',
  unit text not null default 'unit' check (char_length(btrim(unit)) between 1 and 60),
  kind public.product_kind not null default 'ITEM',
  selling_price numeric(18, 2) not null default 0 check (selling_price >= 0),
  reorder_level numeric(18, 4) not null default 0 check (reorder_level >= 0),
  price_editable boolean not null default false,
  service_cost numeric(18, 2) not null default 0 check (service_cost >= 0),
  active boolean not null default true,
  legacy_drive_file_id text,
  legacy_image_name text,
  legacy_image_fingerprint text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (organization_id, sku),
  check (btrim(sku::text) <> '')
);
create index products_org_active_idx on public.products(organization_id, active, name);

create table public.service_materials (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  service_product_id uuid not null references public.products(id) on delete cascade,
  material_product_id uuid not null references public.products(id) on delete restrict,
  quantity_per_service numeric(18, 4) not null check (quantity_per_service > 0),
  created_at timestamptz not null default now(),
  unique (service_product_id, material_product_id),
  check (service_product_id <> material_product_id)
);

create table public.product_images (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  storage_path text not null,
  file_name text not null,
  mime_type text,
  fingerprint text,
  is_primary boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (organization_id, storage_path)
);
create unique index product_images_one_primary_idx on public.product_images(product_id) where is_primary;

-- Imports are staged and reviewed before they alter the catalogue.  Stock is
-- intentionally absent: opening stock must use a FIFO-aware posting command.
create table public.product_import_batches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  source_name text,
  status text not null default 'DRAFT' check (status in ('DRAFT', 'READY', 'PROMOTED', 'REJECTED')),
  created_by uuid not null references auth.users(id) on delete restrict,
  reviewed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  promoted_at timestamptz,
  summary jsonb not null default '{}'::jsonb
);

create table public.product_import_rows (
  id uuid primary key default gen_random_uuid(),
  batch_id uuid not null references public.product_import_batches(id) on delete cascade,
  row_number integer not null check (row_number > 0),
  raw jsonb not null,
  sku citext,
  name text,
  category text,
  unit text,
  kind public.product_kind,
  selling_price numeric(18, 2),
  reorder_level numeric(18, 4),
  price_editable boolean,
  service_cost numeric(18, 2),
  legacy_drive_file_id text,
  legacy_image_name text,
  validation_errors jsonb not null default '[]'::jsonb,
  valid boolean not null default false,
  promoted_product_id uuid references public.products(id) on delete set null,
  unique (batch_id, row_number)
);
create index product_import_rows_batch_valid_idx on public.product_import_rows(batch_id, valid);

-- Keep timestamps database-owned, not browser-owned.
create or replace function private.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger organizations_touch_updated_at before update on public.organizations
for each row execute function private.touch_updated_at();
create trigger organization_settings_touch_updated_at before update on public.organization_settings
for each row execute function private.touch_updated_at();
create trigger locations_touch_updated_at before update on public.locations
for each row execute function private.touch_updated_at();
create trigger profiles_touch_updated_at before update on public.profiles
for each row execute function private.touch_updated_at();
create trigger memberships_touch_updated_at before update on public.memberships
for each row execute function private.touch_updated_at();
create trigger products_touch_updated_at before update on public.products
for each row execute function private.touch_updated_at();

-- Storage is private by default.  The bucket is created here so image upload
-- policy can be version-controlled along with the rest of the application.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-images', 'product-images', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;
