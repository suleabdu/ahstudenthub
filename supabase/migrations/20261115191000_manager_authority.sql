-- Cashbook migration 11: distinguish business Owners, Managers and Sales
-- Representatives without weakening the accounting or tenancy boundary.
--
-- A Manager is an operational administrator: they can run normal management
-- workflows and manage Sales Representatives. Only a true Owner can create or
-- alter Owner/Manager accounts or run destructive recovery operations.

create or replace function private.require_operational_admin(p_organization_id uuid)
returns public.memberships
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_membership public.memberships%rowtype;
begin
  v_membership := private.require_membership(p_organization_id);
  if v_membership.role not in ('OWNER'::public.cashbook_role, 'MANAGER'::public.cashbook_role) then
    raise exception 'You need an Owner or Manager account to do that.' using errcode = '42501';
  end if;
  return v_membership;
end;
$$;

create or replace function private.require_true_owner(p_organization_id uuid)
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
    raise exception 'Only a business Owner may do that.' using errcode = '42501';
  end if;
  return v_membership;
end;
$$;

-- Existing operational RPCs use this legacy helper. Retaining its name keeps
-- the Apps Script-shaped interface compatible; new irreversible operations
-- call `require_true_owner` explicitly.
create or replace function private.require_owner(p_organization_id uuid)
returns public.memberships
language plpgsql
security definer
set search_path = ''
as $$
begin
  return private.require_operational_admin(p_organization_id);
end;
$$;

-- PIN resets use the service-role Auth API, so validate the selected account
-- under the caller's database role first. Managers may reset Sales Reps only.
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
  v_actor public.memberships%rowtype;
  v_membership public.memberships%rowtype;
  v_profile public.profiles%rowtype;
begin
  v_actor := private.require_operational_admin(p_organization_id);
  select m.* into v_membership
    from public.memberships m
   where m.organization_id = p_organization_id and m.user_id = p_user_id
   for share;
  if not found then
    raise exception 'That account is not part of this business.' using errcode = 'P0001';
  end if;
  if v_actor.role = 'MANAGER'::public.cashbook_role
     and v_membership.role <> 'REP'::public.cashbook_role then
    raise exception 'Managers may reset PINs for Sales Rep accounts only.' using errcode = '42501';
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

-- Auth accounts are created by the Edge Function; this function applies the
-- business profile/membership half. It remains authoritative about role
-- boundaries, so a manager cannot bypass the interface with a raw RPC.
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
  v_actor public.memberships%rowtype;
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
  v_actor := private.require_operational_admin(p_organization_id);
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
  if v_role_text not in ('OWNER', 'MANAGER', 'REP') then
    raise exception 'Choose Owner, Manager or Sales Rep.' using errcode = 'P0001';
  end if;
  v_role := v_role_text::public.cashbook_role;

  -- Managers may create and administer Sales Rep accounts only. This checks
  -- both the requested role and an existing target role.
  if v_actor.role = 'MANAGER'::public.cashbook_role then
    if v_role <> 'REP'::public.cashbook_role
       or (v_had_membership and v_membership.role <> 'REP'::public.cashbook_role) then
      raise exception 'Managers may add or change Sales Rep accounts only.' using errcode = '42501';
    end if;
  end if;

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
    -- Owners and Managers are deliberately company-wide administrators.
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
      'permissions', v_permissions, 'managedByRole', v_actor.role::text)
  );
  return jsonb_build_object(
    'saved', true, 'userId', p_user_id::text, 'username', v_username,
    'fullName', v_display_name, 'email', v_email, 'role', v_role::text,
    'location', coalesce(v_location_id::text, ''), 'permissions', v_permissions,
    'active', v_active
  );
end;
$$;
