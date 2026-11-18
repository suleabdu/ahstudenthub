-- Cashbook Supabase migration 3: deny-by-default data access, authenticated
-- context, and the one-time organisation bootstrap.
--
-- The browser never receives table-write permission.  It calls narrowly
-- scoped RPCs below with a Supabase Auth JWT; the RPC verifies membership and
-- runs the financial transaction as one database unit of work.

alter table public.organizations enable row level security;
alter table public.organization_settings enable row level security;
alter table public.locations enable row level security;
alter table public.profiles enable row level security;
alter table public.memberships enable row level security;
alter table public.products enable row level security;
alter table public.service_materials enable row level security;
alter table public.product_images enable row level security;
alter table public.product_import_batches enable row level security;
alter table public.product_import_rows enable row level security;
alter table public.parties enable row level security;
alter table public.documents enable row level security;
alter table public.document_lines enable row level security;
alter table public.payments enable row level security;
alter table public.inventory_lots enable row level security;
alter table public.inventory_movements enable row level security;
alter table public.lot_allocations enable row level security;
alter table public.ledger_entries enable row level security;
alter table public.audit_events enable row level security;
alter table public.sync_commands enable row level security;
alter table public.attention_acknowledgements enable row level security;

-- Supabase can expose the public schema through its Data API.  RLS plus these
-- explicit revokes keeps the database from becoming a browser-to-table API.
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

create or replace function private.try_numeric(p_value text)
returns numeric
language plpgsql
immutable
strict
set search_path = ''
as $$
begin
  if btrim(p_value) !~ '^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$' then
    return null;
  end if;
  return p_value::numeric;
end;
$$;

create or replace function private.require_membership(p_organization_id uuid)
returns public.memberships
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_membership public.memberships%rowtype;
begin
  select m.*
    into v_membership
    from public.memberships m
    join public.organizations o on o.id = m.organization_id and o.active
   where m.organization_id = p_organization_id
     and m.user_id = auth.uid()
     and m.active
   limit 1;

  if not found then
    raise exception 'You do not have access to this business.' using errcode = '42501';
  end if;
  return v_membership;
end;
$$;

create or replace function private.require_owner(p_organization_id uuid)
returns public.memberships
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_membership public.memberships%rowtype;
begin
  v_membership := private.require_membership(p_organization_id);
  if v_membership.role <> 'OWNER'::public.cashbook_role then
    raise exception 'You do not have permission to do that.' using errcode = '42501';
  end if;
  return v_membership;
end;
$$;

-- Staff are bound to their assigned location.  Owners without a location may
-- select an active location by UUID or familiar location code; when omitted,
-- MAIN (or the first active location) is used for a posting command.
create or replace function private.resolve_posting_location(
  p_organization_id uuid,
  p_membership public.memberships,
  p_requested text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_location_id uuid;
  v_requested_clean text := nullif(btrim(coalesce(p_requested, '')), '');
begin
  if p_membership.location_id is not null then
    if v_requested_clean is null then
      return p_membership.location_id;
    end if;
    select l.id
      into v_location_id
      from public.locations l
     where l.organization_id = p_organization_id
       and l.active
       and (l.id::text = v_requested_clean or lower(l.code::text) = lower(v_requested_clean))
     limit 1;
    if v_location_id is distinct from p_membership.location_id then
      raise exception 'You do not have access to the selected shop.' using errcode = '42501';
    end if;
    return p_membership.location_id;
  end if;

  select l.id
    into v_location_id
    from public.locations l
   where l.organization_id = p_organization_id
     and l.active
     and (v_requested_clean is null or l.id::text = v_requested_clean or lower(l.code::text) = lower(v_requested_clean))
   order by case when upper(l.code::text) = 'MAIN' then 0 else 1 end, l.created_at, l.id
   limit 1;
  if v_location_id is null then
    raise exception 'Choose an active shop before posting.' using errcode = 'P0001';
  end if;
  return v_location_id;
end;
$$;

create or replace function private.finish_failed_command(
  p_command_id uuid,
  p_client_id text,
  p_message text,
  p_code text default 'USER'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_response jsonb := jsonb_build_object(
    'clientId', coalesce(p_client_id, ''),
    'status', 'ERROR',
    'message', left(coalesce(p_message, 'This action could not be saved.'), 500)
  );
begin
  update public.sync_commands
     set status = 'FAILED'::public.command_status,
         response = v_response,
         error_code = coalesce(p_code, 'USER'),
         error_message = left(coalesce(p_message, ''), 1000),
         completed_at = now()
   where id = p_command_id;
  return v_response;
end;
$$;

create or replace function public.current_cashbook_context()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_profile public.profiles%rowtype;
  v_memberships jsonb;
  v_default_organization text;
begin
  if auth.uid() is null then
    return null;
  end if;

  select p.* into v_profile from public.profiles p where p.user_id = auth.uid();
  if not found then
    return null;
  end if;

  select
    coalesce(jsonb_agg(jsonb_build_object(
      'organizationId', m.organization_id::text,
      'locationId', m.location_id::text,
      'role', m.role::text,
      'permissions', m.permissions
    ) order by m.created_at, m.id), '[]'::jsonb),
    (array_agg(m.organization_id::text order by m.created_at, m.id))[1]
    into v_memberships, v_default_organization
    from public.memberships m
    join public.organizations o on o.id = m.organization_id and o.active
   where m.user_id = auth.uid() and m.active;

  return jsonb_build_object(
    'userId', auth.uid()::text,
    'username', v_profile.username::text,
    'displayName', v_profile.display_name,
    'defaultOrganizationId', v_default_organization,
    'memberships', v_memberships
  );
end;
$$;

-- This RPC is deliberately service-role-only.  It is used by the separate
-- setup function once, after it has created the first Supabase Auth user.
-- It cannot be called by a browser and refuses to create a second initial
-- organisation accidentally.
create or replace function public.bootstrap_cashbook(
  p_user_id uuid,
  p_email text,
  p_username text,
  p_display_name text,
  p_organization_name text,
  p_organization_slug text,
  p_location_name text default 'Main shop',
  p_currency_code text default 'NGN',
  p_currency_symbol text default '₦'
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid;
  v_location_id uuid;
begin
  if not exists (select 1 from auth.users u where u.id = p_user_id) then
    raise exception 'The initial Auth user does not exist.' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.organizations) then
    raise exception 'Cashbook is already initialised. Use owner administration to add another business.' using errcode = 'P0001';
  end if;
  if btrim(coalesce(p_username, '')) = '' or btrim(coalesce(p_display_name, '')) = '' then
    raise exception 'Owner username and name are required.' using errcode = 'P0001';
  end if;
  if btrim(coalesce(p_organization_name, '')) = '' or coalesce(p_organization_slug, '') !~ '^[a-z0-9][a-z0-9-]{1,62}$' then
    raise exception 'Enter a business name and a lowercase slug using letters, numbers, and dashes.' using errcode = 'P0001';
  end if;

  insert into public.organizations (slug, name, currency_code, currency_symbol)
  values (lower(p_organization_slug), btrim(p_organization_name), upper(coalesce(nullif(btrim(p_currency_code), ''), 'NGN')), coalesce(nullif(btrim(p_currency_symbol), ''), '₦'))
  returning id into v_organization_id;

  insert into public.organization_settings (organization_id)
  values (v_organization_id);

  insert into public.locations (organization_id, code, name)
  values (v_organization_id, 'MAIN', coalesce(nullif(btrim(p_location_name), ''), 'Main shop'))
  returning id into v_location_id;

  insert into public.profiles (user_id, username, display_name, email)
  values (p_user_id, lower(btrim(p_username)), btrim(p_display_name), lower(nullif(btrim(p_email), '')))
  on conflict (user_id) do update
    set username = excluded.username,
        display_name = excluded.display_name,
        email = excluded.email;

  insert into public.memberships (organization_id, user_id, role, location_id, permissions)
  values (v_organization_id, p_user_id, 'OWNER'::public.cashbook_role, null, '["STOCK_IN", "ADD_PRODUCT"]'::jsonb);

  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, detail)
  values (v_organization_id, p_user_id, 'CASHBOOK_BOOTSTRAPPED', 'organization', v_organization_id,
    jsonb_build_object('locationId', v_location_id::text));

  return jsonb_build_object('organizationId', v_organization_id::text, 'locationId', v_location_id::text);
end;
$$;

revoke all on function private.try_numeric(text) from public;
revoke all on function private.require_membership(uuid) from public;
revoke all on function private.require_owner(uuid) from public;
revoke all on function private.resolve_posting_location(uuid, public.memberships, text) from public;
revoke all on function private.finish_failed_command(uuid, text, text, text) from public;
revoke all on function public.current_cashbook_context() from public, anon;
grant execute on function public.current_cashbook_context() to authenticated;
revoke all on function public.bootstrap_cashbook(uuid, text, text, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function public.bootstrap_cashbook(uuid, text, text, text, text, text, text, text, text) to service_role;
