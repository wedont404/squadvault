-- 005_app_functions.sql
-- Authorised write paths for the browser: events, roles, membership, expenses, profile,
-- and the manager-only invitation listing.
--
-- Every function: SECURITY DEFINER, fixed empty search_path, identity from auth.uid()
-- (never from a parameter), role check inside, EXECUTE granted to `authenticated` only.
-- Safe to re-run (CREATE OR REPLACE on stable signatures).
--
-- Prerequisites: 001, 002, 003, 004

begin;

-- ---------------------------------------------------------------------------
-- create_event(p_group_id, p_name, p_target_amount, p_event_date) -> uuid
-- ---------------------------------------------------------------------------
create or replace function public.create_event(
  p_group_id uuid,
  p_name text,
  p_target_amount bigint,
  p_event_date date default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_id uuid;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_manager(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 80 then
    raise exception 'invalid_event_name' using errcode = '22023';
  end if;
  if p_target_amount is null or p_target_amount < 1 or p_target_amount > 1000000000000 then
    raise exception 'invalid_amount' using errcode = '22023';
  end if;
  if p_event_date is not null and (p_event_date < date '2000-01-01' or p_event_date > date '2100-01-01') then
    raise exception 'invalid_date' using errcode = '22023';
  end if;

  insert into public.events (group_id, name, target_amount, event_date, status)
  values (p_group_id, v_name, p_target_amount, p_event_date, 'active')
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- update_event(p_event_id, p_name, p_target_amount, p_event_date) -> void   (active events only)
-- ---------------------------------------------------------------------------
create or replace function public.update_event(
  p_event_id uuid,
  p_name text,
  p_target_amount bigint,
  p_event_date date default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
  v_group uuid;
  v_status text;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select e.group_id, e.status into v_group, v_status from public.events e where e.id = p_event_id for update;
  if v_group is null or not private.is_group_manager(v_group) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if v_status <> 'active' then raise exception 'event_not_active' using errcode = '22023'; end if;
  if char_length(v_name) < 2 or char_length(v_name) > 80 then
    raise exception 'invalid_event_name' using errcode = '22023';
  end if;
  if p_target_amount is null or p_target_amount < 1 or p_target_amount > 1000000000000 then
    raise exception 'invalid_amount' using errcode = '22023';
  end if;
  if p_event_date is not null and (p_event_date < date '2000-01-01' or p_event_date > date '2100-01-01') then
    raise exception 'invalid_date' using errcode = '22023';
  end if;
  update public.events set name = v_name, target_amount = p_target_amount, event_date = p_event_date
   where id = p_event_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- set_event_status(p_event_id, p_status) -> void
--   admin/treasurer: active -> completed | cancelled
--   admin only:      completed | cancelled -> active (reopen)
--   NOTE: cancelling does NOT refund anything. Refunds are a manual / provider action.
-- ---------------------------------------------------------------------------
create or replace function public.set_event_status(p_event_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group uuid;
  v_old text;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_status is null or p_status not in ('active', 'completed', 'cancelled') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;
  select e.group_id, e.status into v_group, v_old from public.events e where e.id = p_event_id for update;
  if v_group is null or not private.is_group_manager(v_group) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_status = 'active' and v_old <> 'active' and private.group_role(v_group) <> 'admin' then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  update public.events set status = p_status where id = p_event_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Membership: roles, removal, leaving. The last admin can never be demoted/removed/leave
-- while other members remain.
-- ---------------------------------------------------------------------------
create or replace function public.set_member_role(p_group_id uuid, p_user_id uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old text;
  v_admins integer;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if private.group_role(p_group_id) is distinct from 'admin' then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_role is null or p_role not in ('admin', 'treasurer', 'member') then
    raise exception 'invalid_role' using errcode = '22023';
  end if;

  perform 1 from public.group_members gm where gm.group_id = p_group_id and gm.role = 'admin' for update;
  select gm.role into v_old from public.group_members gm where gm.group_id = p_group_id and gm.user_id = p_user_id;
  if v_old is null then raise exception 'not_found' using errcode = 'P0002'; end if;

  if v_old = 'admin' and p_role <> 'admin' then
    select count(*) into v_admins from public.group_members gm where gm.group_id = p_group_id and gm.role = 'admin';
    if v_admins <= 1 then raise exception 'last_admin' using errcode = '22023'; end if;
  end if;

  update public.group_members set role = p_role where group_id = p_group_id and user_id = p_user_id;
end;
$$;

create or replace function public.remove_member(p_group_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old text;
  v_admins integer;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if private.group_role(p_group_id) is distinct from 'admin' then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_user_id = auth.uid() then raise exception 'use_leave_group' using errcode = '22023'; end if;

  perform 1 from public.group_members gm where gm.group_id = p_group_id and gm.role = 'admin' for update;
  select gm.role into v_old from public.group_members gm where gm.group_id = p_group_id and gm.user_id = p_user_id;
  if v_old is null then raise exception 'not_found' using errcode = 'P0002'; end if;
  if v_old = 'admin' then
    select count(*) into v_admins from public.group_members gm where gm.group_id = p_group_id and gm.role = 'admin';
    if v_admins <= 1 then raise exception 'last_admin' using errcode = '22023'; end if;
  end if;
  delete from public.group_members where group_id = p_group_id and user_id = p_user_id;
end;
$$;

create or replace function public.leave_group(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_role text;
  v_admins integer;
  v_members integer;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  perform 1 from public.group_members gm where gm.group_id = p_group_id and gm.role = 'admin' for update;
  select gm.role into v_role from public.group_members gm where gm.group_id = p_group_id and gm.user_id = v_uid;
  if v_role is null then raise exception 'not_found' using errcode = 'P0002'; end if;

  if v_role = 'admin' then
    select count(*) into v_admins from public.group_members gm where gm.group_id = p_group_id and gm.role = 'admin';
    select count(*) into v_members from public.group_members gm where gm.group_id = p_group_id;
    if v_admins <= 1 and v_members > 1 then
      raise exception 'last_admin' using errcode = '22023';
    end if;
  end if;
  delete from public.group_members where group_id = p_group_id and user_id = v_uid;
end;
$$;

-- ---------------------------------------------------------------------------
-- list_invitations(p_group_id): managers only. Never returns code hashes.
-- ---------------------------------------------------------------------------
create or replace function public.list_invitations(p_group_id uuid)
returns table (
  id uuid,
  created_by uuid,
  created_at timestamptz,
  expires_at timestamptz,
  max_uses integer,
  use_count integer,
  revoked_at timestamptz,
  status text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_manager(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return query
    select ic.id, ic.created_by, ic.created_at, ic.expires_at, ic.max_uses, ic.use_count, ic.revoked_at,
           case
             when ic.revoked_at is not null then 'revoked'
             when ic.expires_at <= now() then 'expired'
             when ic.use_count >= ic.max_uses then 'exhausted'
             else 'active'
           end
    from public.invitation_codes ic
    where ic.group_id = p_group_id
    order by ic.created_at desc
    limit 50;
end;
$$;

-- ---------------------------------------------------------------------------
-- Receipt path validation: must be <group>/<event>/<uuid>.<ext>, bound to THIS event,
-- and the object must really exist in the private bucket. Arbitrary URLs are impossible.
-- ---------------------------------------------------------------------------
create or replace function private.valid_receipt_path(p_group uuid, p_event uuid, p_path text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select p_path ~ ('^' || p_group::text || '/' || p_event::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp|pdf)$')
     and exists (select 1 from storage.objects o where o.bucket_id = 'receipts' and o.name = p_path);
$$;
revoke all on function private.valid_receipt_path(uuid, uuid, text) from public, anon;
grant execute on function private.valid_receipt_path(uuid, uuid, text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- record_expense(p_event_id, p_amount, p_description, p_receipt_path) -> uuid
--   Rule: an expense may not exceed available funds (verified paid - recorded expenses).
--   The event row is locked so two concurrent expenses cannot overspend.
-- ---------------------------------------------------------------------------
create or replace function public.record_expense(
  p_event_id uuid,
  p_amount bigint,
  p_description text,
  p_receipt_path text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_group uuid;
  v_status text;
  v_desc text := btrim(coalesce(p_description, ''));
  v_paid numeric;
  v_spent numeric;
  v_id uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select e.group_id, e.status into v_group, v_status from public.events e where e.id = p_event_id for update;
  if v_group is null or not private.is_group_manager(v_group) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if v_status = 'cancelled' then raise exception 'event_not_active' using errcode = '22023'; end if;
  if p_amount is null or p_amount < 1 or p_amount > 1000000000000 then
    raise exception 'invalid_amount' using errcode = '22023';
  end if;
  if char_length(v_desc) < 2 or char_length(v_desc) > 200 then
    raise exception 'invalid_description' using errcode = '22023';
  end if;
  if p_receipt_path is not null and not private.valid_receipt_path(v_group, p_event_id, p_receipt_path) then
    raise exception 'invalid_receipt' using errcode = '22023';
  end if;

  select coalesce(sum(c.amount) filter (where c.status = 'paid'), 0) into v_paid from public.contributions c where c.event_id = p_event_id;
  select coalesce(sum(x.amount), 0) into v_spent from public.expenses x where x.event_id = p_event_id;
  if p_amount > v_paid - v_spent then
    raise exception 'insufficient_funds' using errcode = '22023';
  end if;

  insert into public.expenses (event_id, amount, description, receipt_path, recorded_by)
  values (p_event_id, p_amount, v_desc, p_receipt_path, v_uid)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- update_expense(...) -> void. Keeps the receipt unless a new path is given or p_clear_receipt.
-- ---------------------------------------------------------------------------
create or replace function public.update_expense(
  p_expense_id uuid,
  p_amount bigint,
  p_description text,
  p_receipt_path text default null,
  p_clear_receipt boolean default false
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event uuid;
  v_group uuid;
  v_desc text := btrim(coalesce(p_description, ''));
  v_paid numeric;
  v_spent_other numeric;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select x.event_id into v_event from public.expenses x where x.id = p_expense_id;
  if v_event is null then raise exception 'not_found' using errcode = 'P0002'; end if;
  select e.group_id into v_group from public.events e where e.id = v_event for update;
  if v_group is null or not private.is_group_manager(v_group) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_amount is null or p_amount < 1 or p_amount > 1000000000000 then
    raise exception 'invalid_amount' using errcode = '22023';
  end if;
  if char_length(v_desc) < 2 or char_length(v_desc) > 200 then
    raise exception 'invalid_description' using errcode = '22023';
  end if;
  if p_receipt_path is not null and not private.valid_receipt_path(v_group, v_event, p_receipt_path) then
    raise exception 'invalid_receipt' using errcode = '22023';
  end if;

  select coalesce(sum(c.amount) filter (where c.status = 'paid'), 0) into v_paid from public.contributions c where c.event_id = v_event;
  select coalesce(sum(x.amount), 0) into v_spent_other from public.expenses x where x.event_id = v_event and x.id <> p_expense_id;
  if p_amount > v_paid - v_spent_other then
    raise exception 'insufficient_funds' using errcode = '22023';
  end if;

  update public.expenses
     set amount = p_amount,
         description = v_desc,
         receipt_path = case when p_clear_receipt then null else coalesce(p_receipt_path, receipt_path) end,
         updated_at = now()
   where id = p_expense_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- update_profile(p_display_name, p_avatar_path, p_clear_avatar) -> void
--   Avatar must be an existing object inside the caller's own folder of the avatars bucket.
-- ---------------------------------------------------------------------------
create or replace function public.update_profile(
  p_display_name text,
  p_avatar_path text default null,
  p_clear_avatar boolean default false
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_name text := btrim(coalesce(p_display_name, ''));
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if char_length(v_name) < 1 or char_length(v_name) > 60 then
    raise exception 'invalid_display_name' using errcode = '22023';
  end if;
  if p_avatar_path is not null then
    if p_avatar_path !~ ('^' || v_uid::text || '/[A-Za-z0-9._-]{1,80}\.(jpg|png|webp)$')
       or not exists (select 1 from storage.objects o where o.bucket_id = 'avatars' and o.name = p_avatar_path) then
      raise exception 'invalid_avatar' using errcode = '22023';
    end if;
  end if;
  update public.profiles
     set display_name = v_name,
         avatar_path = case when p_clear_avatar then null else coalesce(p_avatar_path, avatar_path) end,
         updated_at = now()
   where id = v_uid;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on function public.create_event(uuid, text, bigint, date) from public, anon;
revoke all on function public.update_event(uuid, text, bigint, date) from public, anon;
revoke all on function public.set_event_status(uuid, text) from public, anon;
revoke all on function public.set_member_role(uuid, uuid, text) from public, anon;
revoke all on function public.remove_member(uuid, uuid) from public, anon;
revoke all on function public.leave_group(uuid) from public, anon;
revoke all on function public.list_invitations(uuid) from public, anon;
revoke all on function public.record_expense(uuid, bigint, text, text) from public, anon;
revoke all on function public.update_expense(uuid, bigint, text, text, boolean) from public, anon;
revoke all on function public.update_profile(text, text, boolean) from public, anon;

grant execute on function public.create_event(uuid, text, bigint, date) to authenticated;
grant execute on function public.update_event(uuid, text, bigint, date) to authenticated;
grant execute on function public.set_event_status(uuid, text) to authenticated;
grant execute on function public.set_member_role(uuid, uuid, text) to authenticated;
grant execute on function public.remove_member(uuid, uuid) to authenticated;
grant execute on function public.leave_group(uuid) to authenticated;
grant execute on function public.list_invitations(uuid) to authenticated;
grant execute on function public.record_expense(uuid, bigint, text, text) to authenticated;
grant execute on function public.update_expense(uuid, bigint, text, text, boolean) to authenticated;
grant execute on function public.update_profile(text, text, boolean) to authenticated;

commit;
