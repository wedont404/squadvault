-- The owner's EXISTING database, exactly as they pasted it (core tables, invitation system, read policies,
-- and their original three RPC functions). The migrations must upgrade THIS state, not a clean slate.
create schema if not exists public;

create table public.savings_groups (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  currency text not null default 'RWF' check (currency = 'RWF'),
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);
create table public.group_members (
  group_id uuid not null references public.savings_groups(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  role text not null default 'member' check (role in ('admin', 'treasurer', 'member')),
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create table public.events (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.savings_groups(id) on delete cascade,
  name text not null,
  target_amount bigint not null check (target_amount > 0),
  event_date date,
  status text not null default 'active' check (status in ('active', 'completed', 'cancelled')),
  created_at timestamptz not null default now()
);
create table public.contributions (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id),
  user_id uuid not null references auth.users(id),
  amount bigint not null check (amount > 0),
  status text not null default 'pending' check (status in ('pending', 'paid', 'failed', 'refunded')),
  payment_reference text unique,
  created_at timestamptz not null default now()
);
create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id),
  amount bigint not null check (amount > 0),
  description text not null,
  receipt_url text,
  recorded_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);
alter table public.savings_groups enable row level security;
alter table public.group_members enable row level security;
alter table public.events enable row level security;
alter table public.contributions enable row level security;
alter table public.expenses enable row level security;
revoke insert, update, delete on public.contributions from anon, authenticated;
revoke insert, update, delete on public.savings_groups, public.group_members, public.events, public.expenses from anon, authenticated;

create schema if not exists private;
create table if not exists public.invitation_codes (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.savings_groups(id) on delete cascade,
  code_hash text not null unique,
  created_by uuid not null references auth.users(id),
  max_uses integer not null default 10 check (max_uses between 1 and 1000),
  uses_count integer not null default 0 check (uses_count >= 0),
  expires_at timestamptz not null default (now() + interval '7 days'),
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists invitation_codes_group_idx on public.invitation_codes(group_id);
alter table public.invitation_codes enable row level security;
revoke all on public.invitation_codes from public, anon, authenticated;
grant usage on schema private to authenticated;
create or replace function private.is_group_member(p_group_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.group_members gm where gm.group_id = p_group_id and gm.user_id = (select auth.uid()));
$$;
revoke all on function private.is_group_member(uuid) from public, anon;
grant execute on function private.is_group_member(uuid) to authenticated;

grant select on public.savings_groups, public.group_members, public.events, public.contributions, public.expenses to authenticated;
create policy "members_read_groups" on public.savings_groups for select to authenticated using ((select private.is_group_member(id)));
create policy "members_read_group_members" on public.group_members for select to authenticated using ((select private.is_group_member(group_id)));
create policy "members_read_events" on public.events for select to authenticated using ((select private.is_group_member(group_id)));
create policy "members_read_contributions" on public.contributions for select to authenticated using (exists (select 1 from public.events e where e.id = contributions.event_id and (select private.is_group_member(e.group_id))));
create policy "members_read_expenses" on public.expenses for select to authenticated using (exists (select 1 from public.events e where e.id = expenses.event_id and (select private.is_group_member(e.group_id))));
create index if not exists group_members_user_idx on public.group_members(user_id);
create index if not exists events_group_idx on public.events(group_id);
create index if not exists contributions_event_idx on public.contributions(event_id);
create index if not exists expenses_event_idx on public.expenses(event_id);

-- ---- the owner's original RPC functions (replaced by migration 002) ----

-- CREATE A GROUP AND MAKE ITS CREATOR ADMIN
create or replace function public.create_savings_group(
  p_name text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_group_id uuid;
begin
  if v_user is null then
    raise exception 'You must sign in first';
  end if;

  if p_name is null
     or length(trim(p_name)) < 2
     or length(trim(p_name)) > 100 then
    raise exception 'Group name must be 2-100 characters';
  end if;

  insert into public.savings_groups (name, created_by)
  values (trim(p_name), v_user)
  returning id into v_group_id;

  insert into public.group_members (
    group_id, user_id, role
  )
  values (v_group_id, v_user, 'admin');

  return v_group_id;
end;
$$;


-- GENERATE A RANDOM INVITATION CODE
create or replace function public.create_invitation_code(
  p_group_id uuid,
  p_max_uses integer default 10,
  p_valid_days integer default 7
)
returns table (
  invitation_code text,
  expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_code text;
  v_expiry timestamptz;
begin
  if v_user is null then
    raise exception 'You must sign in first';
  end if;

  if p_max_uses < 1 or p_max_uses > 1000
     or p_valid_days < 1 or p_valid_days > 90 then
    raise exception 'Invalid invitation limits';
  end if;

  if not exists (
    select 1
    from public.group_members gm
    where gm.group_id = p_group_id
      and gm.user_id = v_user
      and gm.role in ('admin', 'treasurer')
  ) then
    raise exception 'Only group admins or treasurers can invite members';
  end if;

  -- A 96-bit random code, displayed in readable groups.
  v_code := 'SV-' ||
    upper(encode(extensions.gen_random_bytes(6), 'hex'));

  v_expiry := now() + make_interval(days => p_valid_days);

  insert into public.invitation_codes (
    group_id, code_hash, created_by, max_uses, expires_at
  )
  values (
    p_group_id,
    encode(extensions.digest(lower(v_code), 'sha256'), 'hex'),
    v_user,
    p_max_uses,
    v_expiry
  );

  return query select v_code, v_expiry;
end;
$$;


-- JOIN A GROUP USING AN INVITATION CODE
create or replace function public.join_group_with_code(
  p_code text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_invite public.invitation_codes%rowtype;
begin
  if v_user is null then
    raise exception 'You must sign in first';
  end if;

  if p_code is null or length(trim(p_code)) <> 15 then
    raise exception 'Invalid invitation code';
  end if;

  select *
  into v_invite
  from public.invitation_codes ic
  where ic.code_hash =
    encode(
      extensions.digest(lower(trim(p_code)), 'sha256'),
      'hex'
    )
  for update;

  if not found
     or v_invite.revoked_at is not null
     or v_invite.expires_at <= now()
     or v_invite.uses_count >= v_invite.max_uses then
    raise exception 'Invitation is invalid, expired, or exhausted';
  end if;

  if exists (
    select 1
    from public.group_members gm
    where gm.group_id = v_invite.group_id
      and gm.user_id = v_user
  ) then
    raise exception 'You are already a member of this group';
  end if;

  insert into public.group_members (
    group_id, user_id, role
  )
  values (v_invite.group_id, v_user, 'member');

  update public.invitation_codes
  set uses_count = uses_count + 1
  where id = v_invite.id;

  return v_invite.group_id;
end;
$$;


-- ONLY SIGNED-IN USERS MAY CALL THESE FUNCTIONS
revoke all on function public.create_savings_group(text)
  from public, anon;

revoke all on function public.create_invitation_code(uuid, integer, integer)
  from public, anon;

revoke all on function public.join_group_with_code(text)
  from public, anon;

grant execute on function public.create_savings_group(text)
  to authenticated;

grant execute on function public.create_invitation_code(uuid, integer, integer)
  to authenticated;

grant execute on function public.join_group_with_code(text)
  to authenticated;
