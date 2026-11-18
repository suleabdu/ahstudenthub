-- Cashbook migration 12: owner-only recovery and role-safe team removal.
--
-- A factory reset is for a deliberately empty/test cashbook before daily use.
-- It is never an accounting correction. The UI requires a current-password
-- check and the literal DELETE phrase; this migration repeats the Owner check
-- so a Manager or crafted RPC cannot bypass either boundary.

-- Immutable records stay immutable for normal commands. The one narrowly
-- scoped exception is a security-definer factory-reset transaction, which
-- sets this local setting immediately before it clears selected test records.
create or replace function private.reject_immutable_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if current_setting('cashbook.factory_reset', true) = 'on' then
    return old;
  end if;
  raise exception 'Cashbook accounting records are append-only; post a reversal or adjustment instead.'
    using errcode = 'P0001';
end;
$$;

-- Removing a person from this business must not silently destroy their Auth
-- identity or membership in another business. The Edge function calls this
-- RPC for the Team "Remove" action after its own role check.
create or replace function public.remove_cashbook_user(
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
  v_target public.memberships%rowtype;
  v_username text;
begin
  v_actor := private.require_operational_admin(p_organization_id);
  if p_user_id is null then
    raise exception 'Choose a team member to remove.' using errcode = 'P0001';
  end if;
  if p_user_id = auth.uid() then
    raise exception 'You cannot remove the account currently signed in. Ask another Owner if it must be removed.' using errcode = 'P0001';
  end if;
  select m.* into v_target
    from public.memberships m
   where m.organization_id = p_organization_id and m.user_id = p_user_id
   for update;
  if not found then
    raise exception 'That account is not part of this business.' using errcode = 'P0001';
  end if;
  if v_actor.role = 'MANAGER'::public.cashbook_role
     and v_target.role <> 'REP'::public.cashbook_role then
    raise exception 'Managers may remove Sales Rep accounts only.' using errcode = '42501';
  end if;
  if v_target.role = 'OWNER'::public.cashbook_role and v_target.active
     and not exists (
       select 1 from public.memberships m
        where m.organization_id = p_organization_id
          and m.active
          and m.role = 'OWNER'::public.cashbook_role
          and m.user_id <> p_user_id
     ) then
    raise exception 'You cannot remove the last active Owner account.' using errcode = 'P0001';
  end if;
  select p.username::text into v_username from public.profiles p where p.user_id = p_user_id;
  delete from public.memberships
   where organization_id = p_organization_id and user_id = p_user_id;
  update public.organization_settings
     set data_epoch = data_epoch + 1
   where organization_id = p_organization_id;
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, detail)
  values (
    p_organization_id, auth.uid(), 'TEAM_MEMBER_REMOVED', 'membership', p_user_id,
    jsonb_build_object('username', coalesce(v_username, ''), 'role', v_target.role::text,
      'removedByRole', v_actor.role::text, 'authAccountRetained', true)
  );
  return jsonb_build_object(
    'removed', true, 'userId', p_user_id::text, 'username', coalesce(v_username, ''),
    'role', v_target.role::text,
    'message', 'The account was removed from this Cashbook business. Its sign-in was not deleted globally.'
  );
end;
$$;

-- Owners may inspect the exact scope before confirming a reset. Managers are
-- intentionally excluded, even though they use all normal daily workflows.
create or replace function public.get_reset_preview(p_organization_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.require_true_owner(p_organization_id);
  return jsonb_build_object(
    'canReset', true,
    'message', 'Factory reset is only for clearing selected test/start-up data. It cannot be undone; download and verify an external backup first.',
    'scopes', jsonb_build_object(
      'transactions', 'Transactions, payments, FIFO layers and browser command history',
      'products', 'Products, services, staged imports and product photos',
      'parties', 'Customers and suppliers',
      'staff', 'Other Cashbook team memberships',
      'shops', 'Extra shops (the first shop is kept)',
      'audit', 'Existing audit history (a reset event is retained)',
      'settings', 'Operating settings and approved WhatsApp recipients'
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

create or replace function public.factory_reset_cashbook(
  p_organization_id uuid,
  p_scopes jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_owner public.memberships%rowtype;
  v_scope text;
  v_scopes text[] := array[]::text[];
  v_keep_location uuid;
  v_storage_paths jsonb := '[]'::jsonb;
  v_auth_deletion_candidates jsonb := '[]'::jsonb;
begin
  v_owner := private.require_true_owner(p_organization_id);
  if p_scopes is null or jsonb_typeof(p_scopes) <> 'array' or jsonb_array_length(p_scopes) = 0 then
    raise exception 'Choose at least one reset scope.' using errcode = 'P0001';
  end if;
  for v_scope in select lower(btrim(value)) from jsonb_array_elements_text(p_scopes) x(value)
  loop
    if v_scope not in ('transactions', 'products', 'parties', 'staff', 'shops', 'audit', 'settings') then
      raise exception 'Unknown factory-reset scope: %.', v_scope using errcode = 'P0001';
    end if;
    if array_position(v_scopes, v_scope) is null then
      v_scopes := array_append(v_scopes, v_scope);
    end if;
  end loop;
  if (array_position(v_scopes, 'products') is not null
      or array_position(v_scopes, 'parties') is not null
      or array_position(v_scopes, 'shops') is not null)
     and array_position(v_scopes, 'transactions') is null then
    raise exception 'Clear transactions before removing products, people, or shops that may be referenced by them.' using errcode = 'P0001';
  end if;

  select l.id into v_keep_location
    from public.locations l
   where l.organization_id = p_organization_id and l.active
   order by case when upper(l.code::text) = 'MAIN' then 0 else 1 end, l.created_at, l.id
   limit 1;
  if v_keep_location is null then
    raise exception 'This Cashbook has no active shop to keep. Contact support before resetting it.' using errcode = 'P0001';
  end if;

  if array_position(v_scopes, 'products') is not null then
    select coalesce(jsonb_agg(pi.storage_path order by pi.storage_path), '[]'::jsonb)
      into v_storage_paths
      from public.product_images pi
     where pi.organization_id = p_organization_id;
  end if;
  if array_position(v_scopes, 'staff') is not null then
    -- Only candidates with no other Cashbook membership are offered to the
    -- Edge layer for Auth deletion after this database transaction commits.
    select coalesce(jsonb_agg(m.user_id::text order by m.user_id::text), '[]'::jsonb)
      into v_auth_deletion_candidates
      from public.memberships m
     where m.organization_id = p_organization_id
       and m.user_id <> auth.uid()
       and not exists (
         select 1 from public.memberships elsewhere
          where elsewhere.user_id = m.user_id
            and elsewhere.organization_id <> p_organization_id
       );
  end if;

  -- The setting is transaction-local and is visible only to the immutable
  -- triggers while this controlled recovery function is deleting rows.
  perform set_config('cashbook.factory_reset', 'on', true);

  if array_position(v_scopes, 'transactions') is not null then
    delete from public.attention_acknowledgements where organization_id = p_organization_id;
    delete from public.return_allocations where organization_id = p_organization_id;
    delete from public.lot_allocations where organization_id = p_organization_id;
    delete from public.inventory_movements where organization_id = p_organization_id;
    delete from public.payments where organization_id = p_organization_id;
    delete from public.ledger_entries where organization_id = p_organization_id;
    delete from public.inventory_lots where organization_id = p_organization_id;
    delete from public.document_lines where organization_id = p_organization_id;
    update public.documents set reversed_document_id = null where organization_id = p_organization_id;
    delete from public.documents where organization_id = p_organization_id;
    delete from public.sync_commands where organization_id = p_organization_id;
  end if;

  if array_position(v_scopes, 'products') is not null then
    delete from public.service_materials where organization_id = p_organization_id;
    delete from public.product_import_batches where organization_id = p_organization_id;
    delete from public.products where organization_id = p_organization_id;
  end if;

  if array_position(v_scopes, 'parties') is not null then
    delete from public.parties where organization_id = p_organization_id;
  end if;

  if array_position(v_scopes, 'staff') is not null then
    -- Acknowledgements reference Auth users with RESTRICT; clear former team
    -- members' acknowledgements before the Edge layer may remove their Auth
    -- identity. The underlying financial records are unaffected.
    delete from public.attention_acknowledgements
     where organization_id = p_organization_id and acknowledged_by <> auth.uid();
    delete from public.memberships
     where organization_id = p_organization_id and user_id <> auth.uid();
  end if;

  if array_position(v_scopes, 'shops') is not null then
    -- Reps assigned to a removed shop remain staff, safely moved to the
    -- retained main shop rather than accidentally gaining all-shop access.
    update public.memberships
       set location_id = v_keep_location
     where organization_id = p_organization_id
       and role = 'REP'::public.cashbook_role
       and (location_id is null or location_id <> v_keep_location);
    delete from public.locations
     where organization_id = p_organization_id and id <> v_keep_location;
  end if;

  if array_position(v_scopes, 'settings') is not null then
    delete from public.whatsapp_recipients where organization_id = p_organization_id;
    update public.organization_settings
       set closed_until = null,
           oversell_policy = 'BLOCK',
           payment_methods = '["Cash", "Transfer", "POS", "Cheque"]'::jsonb,
           expense_categories = '[]'::jsonb,
           receipt_footer = 'Thank you for your patronage.',
           target_margin_pct = 30,
           reps_see_company_totals = false,
           service_categories = '[]'::jsonb,
           alert_email = null,
           backup_keep_days = 60,
           data_epoch = data_epoch + 1
     where organization_id = p_organization_id;
  else
    update public.organization_settings
       set data_epoch = data_epoch + 1
     where organization_id = p_organization_id;
  end if;

  if array_position(v_scopes, 'audit') is not null then
    delete from public.audit_events where organization_id = p_organization_id;
  end if;
  insert into public.audit_events (organization_id, actor_id, action, entity_type, entity_id, detail)
  values (
    p_organization_id, auth.uid(), 'FACTORY_RESET', 'organization', p_organization_id,
    jsonb_build_object('scopes', to_jsonb(v_scopes), 'initiatedByRole', v_owner.role::text,
      'externalBackupRequired', true, 'authCleanupCandidates', v_auth_deletion_candidates)
  );

  return jsonb_build_object(
    'scopes', to_jsonb(v_scopes),
    'storagePaths', v_storage_paths,
    'authDeletionCandidates', v_auth_deletion_candidates,
    'message', 'Selected Cashbook data was reset. Review the audit event and any cleanup warning before using the new books.'
  );
end;
$$;

revoke all on function private.require_operational_admin(uuid) from public;
revoke all on function private.require_true_owner(uuid) from public;
revoke all on function public.remove_cashbook_user(uuid, uuid) from public, anon;
revoke all on function public.factory_reset_cashbook(uuid, jsonb) from public, anon;
revoke all on function public.get_reset_preview(uuid) from public, anon;
grant execute on function public.remove_cashbook_user(uuid, uuid) to authenticated;
grant execute on function public.factory_reset_cashbook(uuid, jsonb) to authenticated;
grant execute on function public.get_reset_preview(uuid) to authenticated;
