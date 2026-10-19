-- SQUADVAULT: ALL MISSING PIECES IN ONE FILE (migrations 001-007, in order).
-- Paste the WHOLE file into Supabase -> SQL Editor -> Run. Safe to run again. Never deletes your data.
-- Run it AFTER your existing tables/functions SQL. Do NOT re-run your older create_*/join_* functions afterwards.

-- ===================== 001_schema_reconciliation.sql =====================
-- 001_schema_reconciliation.sql
-- Non-destructive. Safe to re-run. Never drops, truncates or recreates existing tables.
--
-- What this does
--   * Ensures pgcrypto is available (in the `extensions` schema, as on Supabase).
--   * Creates a `private` schema (NOT exposed through the API) for RLS helper functions.
--   * Adds the profiles table plus new columns that the payment flow needs on contributions/expenses.
--   * Adds payment_events (idempotency / audit log for provider callbacks).
--   * Adds indexes and sanity constraints (NOT VALID, so existing rows never block the migration).
--
-- Assumes the five core tables already exist exactly as documented
-- (savings_groups, group_members, events, contributions, expenses).
-- Run the inspection query at the bottom first if you are unsure.
--
-- Rollback (new objects only, never your existing data):
--   drop table if exists public.payment_events;
--   drop table if exists public.profiles;  -- loses display names only
--   alter table public.contributions drop column if exists payment_method, drop column if exists provider, ...
--   (see README "Rollback")

begin;

create extension if not exists pgcrypto with schema extensions;
-- If pgcrypto was installed earlier WITHOUT a schema it may live in `public`, where the functions
-- below (which call extensions.gen_random_bytes / extensions.digest) can't find it. Move it.
do $$
begin
  if exists (select 1 from pg_extension e join pg_namespace n on n.oid = e.extnamespace where e.extname = 'pgcrypto' and n.nspname = 'public') then
    alter extension pgcrypto set schema extensions;
  end if;
end $$;

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default 'Member',
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_display_name_len check (char_length(display_name) between 1 and 60),
  constraint profiles_avatar_https check (avatar_url is null or (avatar_url ~* '^https://' and char_length(avatar_url) <= 500))
);

-- Backfill profiles for users that existed before this migration.
insert into public.profiles (id, display_name)
select u.id,
       left(coalesce(nullif(trim(u.raw_user_meta_data ->> 'display_name'), ''), split_part(u.email, '@', 1), 'Member'), 60)
from auth.users u
on conflict (id) do nothing;

-- Create a profile automatically for every new signup.
create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    left(coalesce(nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''), split_part(new.email, '@', 1), 'Member'), 60)
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_squadvault on auth.users;
create trigger on_auth_user_created_squadvault
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- ---------------------------------------------------------------------------
-- contributions: payment tracking columns
-- ---------------------------------------------------------------------------
alter table public.contributions add column if not exists payment_method text;
alter table public.contributions add column if not exists provider text;
alter table public.contributions add column if not exists provider_ref text;      -- provider invoice / checkout id
alter table public.contributions add column if not exists is_simulated boolean not null default false;
alter table public.contributions add column if not exists failure_reason text;
alter table public.contributions add column if not exists paid_at timestamptz;
alter table public.contributions add column if not exists updated_at timestamptz not null default now();

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'contributions_payment_method_check') then
    alter table public.contributions
      add constraint contributions_payment_method_check
      check (payment_method is null or payment_method in ('mtn_momo', 'airtel_money')) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'contributions_amount_cap_check') then
    alter table public.contributions
      add constraint contributions_amount_cap_check
      check (amount <= 1000000000000) not valid;   -- keeps every value and sum inside JS safe-integer range
  end if;
  if not exists (select 1 from pg_constraint where conname = 'events_target_cap_check') then
    alter table public.events
      add constraint events_target_cap_check
      check (target_amount <= 1000000000000) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'expenses_amount_cap_check') then
    alter table public.expenses
      add constraint expenses_amount_cap_check
      check (amount <= 1000000000000) not valid;
  end if;
end $$;

create unique index if not exists contributions_provider_ref_uidx
  on public.contributions (provider, provider_ref) where provider_ref is not null;

-- ---------------------------------------------------------------------------
-- expenses: private storage path (replaces free-form receipt_url for new rows)
-- ---------------------------------------------------------------------------
alter table public.expenses add column if not exists receipt_path text;
alter table public.expenses add column if not exists updated_at timestamptz not null default now();

-- ---------------------------------------------------------------------------
-- payment_events: one row per provider notification; unique key gives idempotency
-- ---------------------------------------------------------------------------
create table if not exists public.payment_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null,
  provider_event_id text not null,
  contribution_id uuid references public.contributions (id) on delete set null,
  payment_reference text,
  provider_state text,
  amount bigint,
  currency text,
  outcome text,
  payload jsonb not null default '{}'::jsonb,
  received_at timestamptz not null default now(),
  constraint payment_events_unique unique (provider, provider_event_id)
);
alter table public.payment_events enable row level security;
revoke all on public.payment_events from anon, authenticated;
-- No policies: only the service role (Edge Functions) can touch this table.

-- ---------------------------------------------------------------------------
-- Indexes for the app's common queries
-- ---------------------------------------------------------------------------
create index if not exists group_members_user_idx on public.group_members (user_id);
create index if not exists events_group_idx on public.events (group_id, status, event_date);
create index if not exists contributions_event_idx on public.contributions (event_id, status);
create index if not exists contributions_user_idx on public.contributions (user_id, created_at desc);
create index if not exists expenses_event_idx on public.expenses (event_id, created_at desc);
create index if not exists payment_events_contribution_idx on public.payment_events (contribution_id);

-- ---------------------------------------------------------------------------
-- RLS helper functions (private schema, never exposed by PostgREST)
-- SECURITY DEFINER avoids RLS recursion on group_members. Fixed search_path,
-- identity always from auth.uid().
-- ---------------------------------------------------------------------------
create or replace function private.is_group_member(p_group_id uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.group_members gm
    where gm.group_id = p_group_id and gm.user_id = (select auth.uid())
  );
$$;

create or replace function private.group_role(p_group_id uuid)
returns text
language sql stable security definer
set search_path = ''
as $$
  select gm.role from public.group_members gm
  where gm.group_id = p_group_id and gm.user_id = (select auth.uid());
$$;

create or replace function private.is_group_manager(p_group_id uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce(private.group_role(p_group_id) in ('admin', 'treasurer'), false);
$$;

create or replace function private.event_group_id(p_event_id uuid)
returns uuid
language sql stable security definer
set search_path = ''
as $$
  select e.group_id from public.events e where e.id = p_event_id;
$$;

create or replace function private.shares_group_with(p_other uuid)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.group_members me
    join public.group_members other on other.group_id = me.group_id
    where me.user_id = (select auth.uid()) and other.user_id = p_other
  );
$$;

revoke all on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated, service_role;

commit;

-- ---------------------------------------------------------------------------
-- Optional inspection queries (run manually in the SQL editor; read-only)
-- ---------------------------------------------------------------------------
-- select table_name from information_schema.tables where table_schema = 'public' order by 1;
-- select conrelid::regclass, conname, pg_get_constraintdef(oid) from pg_constraint where connamespace = 'public'::regnamespace;
-- select proname, pg_get_function_identity_arguments(oid) from pg_proc where pronamespace = 'public'::regnamespace order by 1;
-- select schemaname, tablename, policyname, cmd from pg_policies where schemaname in ('public','storage') order by 1,2;

-- ===================== 002_invitation_system.sql =====================
-- 002_invitation_system.sql
-- Invitation codes: SV- + 12 hex chars, SHA-256 hashed at rest, expiring, usage-limited,
-- revocable, atomically redeemed, rate-limited.
-- Safe to re-run. Existing tables/data are never dropped. Only the three RPC functions below
-- are dropped-and-recreated by exact signature (functions hold no data) so their return
-- types are guaranteed to match what the frontend expects.
--
-- Prerequisite: 001_schema_reconciliation.sql

begin;

-- ---------------------------------------------------------------------------
-- invitation_codes
-- ---------------------------------------------------------------------------
create table if not exists public.invitation_codes (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.savings_groups (id) on delete cascade,
  code_hash text not null,
  created_by uuid not null references auth.users (id),
  max_uses integer not null default 10,
  use_count integer not null default 0,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  created_at timestamptz not null default now()
);

-- Your original table named the counter `uses_count`. Rename it (data and its CHECK follow the rename)
-- so there is a single counter column, `use_count`, used by every function below.
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'invitation_codes' and column_name = 'uses_count')
     and not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'invitation_codes' and column_name = 'use_count') then
    alter table public.invitation_codes rename column uses_count to use_count;
  end if;
end $$;

-- If a table with this name existed from an earlier attempt, bring it up to shape.
alter table public.invitation_codes add column if not exists code_hash text;
alter table public.invitation_codes add column if not exists created_by uuid references auth.users (id);
alter table public.invitation_codes add column if not exists max_uses integer not null default 10;
alter table public.invitation_codes add column if not exists use_count integer not null default 0;
alter table public.invitation_codes add column if not exists expires_at timestamptz;
alter table public.invitation_codes add column if not exists revoked_at timestamptz;
alter table public.invitation_codes add column if not exists created_at timestamptz not null default now();

-- A legacy plaintext `code` column must not block inserts and must never be written again.
do $$
begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'invitation_codes' and column_name = 'code') then
    alter table public.invitation_codes alter column code drop not null;
    raise notice 'invitation_codes.code (legacy plaintext) exists. New rows leave it NULL. Review and drop it manually once you have confirmed it holds nothing you need.';
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'invitation_codes_limits_check') then
    alter table public.invitation_codes
      add constraint invitation_codes_limits_check
      check (max_uses between 1 and 100 and use_count >= 0 and use_count <= max_uses) not valid;
  end if;
end $$;

create unique index if not exists invitation_codes_hash_uidx on public.invitation_codes (code_hash) where code_hash is not null;
create index if not exists invitation_codes_group_idx on public.invitation_codes (group_id, created_at desc);

alter table public.invitation_codes enable row level security;

-- ---------------------------------------------------------------------------
-- invitation_attempts: rate limiting for redemption attempts. Service/definer access only.
-- ---------------------------------------------------------------------------
create table if not exists public.invitation_attempts (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  succeeded boolean not null,
  attempted_at timestamptz not null default now()
);
create index if not exists invitation_attempts_user_idx on public.invitation_attempts (user_id, attempted_at desc);
alter table public.invitation_attempts enable row level security;
revoke all on public.invitation_attempts from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Functions. Replace by exact signature only.
-- ---------------------------------------------------------------------------
drop function if exists public.create_savings_group(text);
drop function if exists public.create_invitation_code(uuid, integer, integer);
drop function if exists public.join_group_with_code(text);
drop function if exists public.revoke_invitation_code(uuid);

-- create_savings_group(p_name) -> uuid of the new group. Caller becomes admin.
create function public.create_savings_group(p_name text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_name text := btrim(coalesce(p_name, ''));
  v_group_id uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 60 then
    raise exception 'invalid_group_name' using errcode = '22023';
  end if;
  -- crude abuse limit: at most 20 groups created per user
  if (select count(*) from public.savings_groups g where g.created_by = v_uid) >= 20 then
    raise exception 'group_limit_reached' using errcode = '53400';
  end if;

  insert into public.savings_groups (name, currency, created_by)
  values (v_name, 'RWF', v_uid)
  returning id into v_group_id;

  insert into public.group_members (group_id, user_id, role)
  values (v_group_id, v_uid, 'admin');

  return v_group_id;
end;
$$;

-- create_invitation_code(p_group_id, p_max_uses, p_valid_days) -> jsonb { id, code, expires_at, max_uses }
-- The plaintext code is returned exactly once and is never stored or logged.
create function public.create_invitation_code(
  p_group_id uuid,
  p_max_uses integer default 10,
  p_valid_days integer default 7
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_code text;
  v_hash text;
  v_id uuid;
  v_expires timestamptz;
  v_max integer := coalesce(p_max_uses, 10);
  v_days integer := coalesce(p_valid_days, 7);
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_group_id is null or not private.is_group_manager(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if v_max < 1 or v_max > 100 then
    raise exception 'invalid_max_uses' using errcode = '22023';
  end if;
  if v_days < 1 or v_days > 30 then
    raise exception 'invalid_valid_days' using errcode = '22023';
  end if;
  -- cap live invitations per group so the table cannot be spammed
  if (select count(*) from public.invitation_codes ic
      where ic.group_id = p_group_id and ic.revoked_at is null and ic.expires_at > now()) >= 25 then
    raise exception 'too_many_active_invitations' using errcode = '53400';
  end if;

  v_code := 'SV-' || upper(encode(extensions.gen_random_bytes(6), 'hex'));   -- 6 bytes = 12 hex chars
  v_hash := encode(extensions.digest(v_code, 'sha256'), 'hex');
  v_expires := now() + make_interval(days => v_days);

  insert into public.invitation_codes (group_id, code_hash, created_by, max_uses, expires_at)
  values (p_group_id, v_hash, v_uid, v_max, v_expires)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'code', v_code, 'expires_at', v_expires, 'max_uses', v_max);
end;
$$;

-- revoke_invitation_code(p_invitation_id) -> void
create function public.revoke_invitation_code(p_invitation_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group uuid;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  select ic.group_id into v_group from public.invitation_codes ic where ic.id = p_invitation_id;
  if v_group is null or not private.is_group_manager(v_group) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  update public.invitation_codes
     set revoked_at = now()
   where id = p_invitation_id and revoked_at is null;
end;
$$;

-- join_group_with_code(p_code) -> jsonb
--   success: { ok: true, group_id, already_member }
--   failure: { ok: false, error: 'invalid_code' | 'rate_limited' }
-- Every failure mode (bad format, unknown, expired, revoked, exhausted) returns the SAME
-- generic 'invalid_code' so callers cannot probe which codes exist. Failures are returned,
-- not raised, so the attempt log row is committed and rate limiting actually works.
create function public.join_group_with_code(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_code text := upper(btrim(coalesce(p_code, '')));
  v_hash text;
  v_hash_legacy text;
  v_inv public.invitation_codes%rowtype;
  v_fails integer;
  v_inserted integer;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  delete from public.invitation_attempts where attempted_at < now() - interval '1 day';

  select count(*) into v_fails
  from public.invitation_attempts a
  where a.user_id = v_uid and not a.succeeded and a.attempted_at > now() - interval '15 minutes';
  if v_fails >= 8 then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;

  if v_code !~ '^SV-[0-9A-F]{12}$' then
    insert into public.invitation_attempts (user_id, succeeded) values (v_uid, false);
    return jsonb_build_object('ok', false, 'error', 'invalid_code');
  end if;

  v_hash := encode(extensions.digest(v_code, 'sha256'), 'hex');
  -- Codes made by the original function were hashed from the LOWER-case code; accept both forms.
  v_hash_legacy := encode(extensions.digest(lower(v_code), 'sha256'), 'hex');

  -- Row lock serialises concurrent redemptions of the same code, so use_count never overshoots.
  select * into v_inv
  from public.invitation_codes ic
  where ic.code_hash in (v_hash, v_hash_legacy)
  for update;

  if not found
     or v_inv.revoked_at is not null
     or v_inv.expires_at <= now()
     or v_inv.use_count >= v_inv.max_uses then
    insert into public.invitation_attempts (user_id, succeeded) values (v_uid, false);
    return jsonb_build_object('ok', false, 'error', 'invalid_code');
  end if;

  -- Already a member: succeed without consuming a use.
  if exists (select 1 from public.group_members gm where gm.group_id = v_inv.group_id and gm.user_id = v_uid) then
    insert into public.invitation_attempts (user_id, succeeded) values (v_uid, true);
    return jsonb_build_object('ok', true, 'group_id', v_inv.group_id, 'already_member', true);
  end if;

  insert into public.group_members (group_id, user_id, role)
  values (v_inv.group_id, v_uid, 'member')
  on conflict (group_id, user_id) do nothing;
  get diagnostics v_inserted = row_count;

  if v_inserted > 0 then
    update public.invitation_codes set use_count = use_count + 1 where id = v_inv.id;
  end if;

  insert into public.invitation_attempts (user_id, succeeded) values (v_uid, true);
  return jsonb_build_object('ok', true, 'group_id', v_inv.group_id, 'already_member', v_inserted = 0);
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants: callable by signed-in users only
-- ---------------------------------------------------------------------------
revoke all on function public.create_savings_group(text) from public, anon;
revoke all on function public.create_invitation_code(uuid, integer, integer) from public, anon;
revoke all on function public.revoke_invitation_code(uuid) from public, anon;
revoke all on function public.join_group_with_code(text) from public, anon;
grant execute on function public.create_savings_group(text) to authenticated;
grant execute on function public.create_invitation_code(uuid, integer, integer) to authenticated;
grant execute on function public.revoke_invitation_code(uuid) to authenticated;
grant execute on function public.join_group_with_code(text) to authenticated;

commit;

-- ===================== 003_rls_policies.sql =====================
-- 003_rls_policies.sql
-- Row Level Security + least-privilege grants + the read-only financial summary view.
-- Safe to re-run. No table or row is dropped. Only POLICIES are dropped and recreated.
--
-- Prerequisites: 001_schema_reconciliation.sql, 002_invitation_system.sql
--
-- Security model
--   * Every table below has RLS enabled.
--   * The browser (role `authenticated`) gets SELECT only, filtered by group membership.
--   * ALL writes go through SECURITY DEFINER RPC functions (002, 005) or the service role
--     (Edge Functions, 006). The browser can never insert/update/delete financial rows.
--   * `anon` has no access to any of these tables.
--   * invitation_codes is not readable at all from the browser (it holds hashes);
--     managers list invitations through public.list_invitations().
--
-- Policies that already exist on these tables are dropped first, because permissive
-- policies are OR-ed together and one forgotten `using (true)` policy would leak data.

begin;

-- ---------------------------------------------------------------------------
-- 1. Make sure RLS is on everywhere
-- ---------------------------------------------------------------------------
alter table public.savings_groups   enable row level security;
alter table public.group_members    enable row level security;
alter table public.events           enable row level security;
alter table public.contributions    enable row level security;
alter table public.expenses         enable row level security;
alter table public.profiles         enable row level security;
alter table public.invitation_codes enable row level security;
alter table public.invitation_attempts enable row level security;
alter table public.payment_events   enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Grants: anon gets nothing, authenticated gets SELECT only
-- ---------------------------------------------------------------------------
revoke all on public.savings_groups, public.group_members, public.events,
              public.contributions, public.expenses, public.profiles,
              public.invitation_codes, public.invitation_attempts, public.payment_events
  from anon;

revoke insert, update, delete, truncate, references, trigger on
  public.savings_groups, public.group_members, public.events,
  public.contributions, public.expenses, public.profiles
  from authenticated;

revoke all on public.invitation_codes, public.invitation_attempts, public.payment_events from authenticated;

grant select on public.savings_groups, public.group_members, public.events,
                public.contributions, public.expenses, public.profiles
  to authenticated;

-- The service role (Edge Functions only; its key never reaches the browser) needs explicit access
-- so the payment functions work even on projects whose default privileges were changed.
grant select, insert, update, delete on public.savings_groups, public.group_members, public.events,
  public.contributions, public.expenses, public.profiles, public.invitation_codes,
  public.invitation_attempts, public.payment_events to service_role;

-- ---------------------------------------------------------------------------
-- 3. Drop every existing policy on these tables, then create the intended ones
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('savings_groups', 'group_members', 'events', 'contributions',
                        'expenses', 'profiles', 'invitation_codes', 'invitation_attempts', 'payment_events')
  loop
    execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;

-- savings_groups: visible to its members only
create policy savings_groups_select_members on public.savings_groups
  for select to authenticated
  using (private.is_group_member(id));

-- group_members: you see the roster of groups you belong to
create policy group_members_select_same_group on public.group_members
  for select to authenticated
  using (private.is_group_member(group_id));

-- events: members of the owning group
create policy events_select_members on public.events
  for select to authenticated
  using (private.is_group_member(group_id));

-- contributions: members of the group that owns the event
create policy contributions_select_members on public.contributions
  for select to authenticated
  using (private.is_group_member(private.event_group_id(event_id)));

-- expenses: members of the group that owns the event
create policy expenses_select_members on public.expenses
  for select to authenticated
  using (private.is_group_member(private.event_group_id(event_id)));

-- profiles: your own profile, plus people you share a group with
create policy profiles_select_self_or_group on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or private.shares_group_with(id));

-- invitation_codes, invitation_attempts, payment_events: RLS on, no policies, no grants
-- => unreachable from the API. Reached only through SECURITY DEFINER functions / service role.

-- ---------------------------------------------------------------------------
-- 4. profiles.avatar_path (private path inside the public `avatars` bucket)
--    Written only by public.update_profile() (005), never by the browser directly.
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists avatar_path text;

-- ---------------------------------------------------------------------------
-- 5. Financial model (single source of truth)
--
--   collected   = SUM(contributions.amount) WHERE status = 'paid'
--   pending     = SUM(...)                  WHERE status = 'pending'   (NEVER counted as money)
--   failed      = SUM(...)                  WHERE status = 'failed'
--   refunded    = SUM(...)                  WHERE status = 'refunded'  (NOT counted as collected)
--   spent       = SUM(expenses.amount)
--   available   = collected - spent
--   remaining   = GREATEST(target - collected, 0)
--
-- security_invoker => the view runs with the CALLER's rights, so the RLS policies above
-- apply and nobody can read totals for a group they do not belong to.
-- ---------------------------------------------------------------------------
create or replace view public.event_financials
with (security_invoker = true) as
select
  e.id         as event_id,
  e.group_id   as group_id,
  e.target_amount,
  e.status     as event_status,
  coalesce(c.paid, 0)::bigint      as paid_total,
  coalesce(c.pending, 0)::bigint   as pending_total,
  coalesce(c.failed, 0)::bigint    as failed_total,
  coalesce(c.refunded, 0)::bigint  as refunded_total,
  coalesce(x.spent, 0)::bigint     as expenses_total,
  (coalesce(c.paid, 0) - coalesce(x.spent, 0))::bigint as available_funds,
  greatest(e.target_amount - coalesce(c.paid, 0), 0)::bigint as remaining_amount
from public.events e
left join lateral (
  select
    sum(k.amount) filter (where k.status = 'paid')     as paid,
    sum(k.amount) filter (where k.status = 'pending')  as pending,
    sum(k.amount) filter (where k.status = 'failed')   as failed,
    sum(k.amount) filter (where k.status = 'refunded') as refunded
  from public.contributions k
  where k.event_id = e.id
) c on true
left join lateral (
  select sum(x1.amount) as spent from public.expenses x1 where x1.event_id = e.id
) x on true;

revoke all on public.event_financials from anon;
grant select on public.event_financials to authenticated;

commit;

-- ===================== 004_storage_policies.sql =====================
-- 004_storage_policies.sql
-- Storage buckets and policies.
--
--   receipts  PRIVATE. Path: <group_id>/<event_id>/<uuid>.<jpg|png|webp|pdf>, max 5 MB.
--             Upload: admins/treasurers of that group, for an event of that group.
--             Read:   any member of that group (via short-lived signed URLs).
--             No UPDATE/DELETE policy => files cannot be overwritten or removed from the browser.
--   avatars   PUBLIC read (profile pictures). Path: <user_id>/<name>.<jpg|png|webp>, max 1 MB.
--             Users can write/delete only inside their own folder.
--
-- Safe to re-run. Only policies whose names start with `squadvault_` are dropped/recreated;
-- policies for any other bucket are left alone.
-- Prerequisite: 001 (private helper functions).

begin;

-- ---------------------------------------------------------------------------
-- Helper functions. Regex is checked BEFORE any uuid cast so malformed names can
-- never raise a cast error inside a policy.
-- ---------------------------------------------------------------------------
create or replace function private.receipt_group_id(p_name text)
returns uuid
language sql immutable
set search_path = ''
as $$
  select case
    when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp|pdf)$'
    then split_part(p_name, '/', 1)::uuid
  end;
$$;

create or replace function private.receipt_upload_allowed(p_name text)
returns boolean
language plpgsql stable security definer
set search_path = ''
as $$
declare
  v_group uuid := private.receipt_group_id(p_name);
  v_event uuid;
begin
  if v_group is null then
    return false;
  end if;
  v_event := split_part(p_name, '/', 2)::uuid;
  return coalesce(private.is_group_manager(v_group) and private.event_group_id(v_event) = v_group, false);
end;
$$;

revoke all on function private.receipt_group_id(text) from public, anon;
revoke all on function private.receipt_upload_allowed(text) from public, anon;
grant execute on function private.receipt_group_id(text) to authenticated, service_role;
grant execute on function private.receipt_upload_allowed(text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Buckets
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 5242880,
        array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 1048576,
        array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ---------------------------------------------------------------------------
-- Policies on storage.objects
-- ---------------------------------------------------------------------------
drop policy if exists squadvault_receipts_select on storage.objects;
drop policy if exists squadvault_receipts_insert on storage.objects;
drop policy if exists squadvault_avatars_insert on storage.objects;
drop policy if exists squadvault_avatars_update on storage.objects;
drop policy if exists squadvault_avatars_delete on storage.objects;

create policy squadvault_receipts_select on storage.objects
  for select to authenticated
  using (bucket_id = 'receipts' and private.is_group_member(private.receipt_group_id(name)));

create policy squadvault_receipts_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'receipts' and private.receipt_upload_allowed(name));

create policy squadvault_avatars_insert on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy squadvault_avatars_update on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy squadvault_avatars_delete on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

commit;

-- ===================== 005_app_functions.sql =====================
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

-- ===================== 006_payment_functions.sql =====================
-- 006_payment_functions.sql
-- Trusted payment state machine. These functions are callable ONLY by the service role
-- (the Edge Functions). `authenticated` and `anon` cannot execute them, so the browser can
-- never create a "paid" contribution or flip a status.
--
-- State machine for contributions.status:
--   pending --COMPLETE--> paid --REFUNDED--> refunded
--   pending --FAILED / expiry--> failed
--   (paid is never reverted to pending/failed; duplicates and replays are no-ops)
--
-- Idempotency: payment_events has UNIQUE (provider, provider_event_id). The Edge Functions
-- build the key as "<invoice_id>:<state>", so the same notification can never be applied twice.
--
-- Prerequisite: 001 (payment_events, contributions columns)

begin;

-- ---------------------------------------------------------------------------
-- payment_create_pending: validates and inserts a PENDING contribution
-- ---------------------------------------------------------------------------
create or replace function public.payment_create_pending(
  p_user_id uuid,
  p_event_id uuid,
  p_amount bigint,
  p_method text,
  p_reference text,
  p_simulated boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group uuid;
  v_status text;
  v_recent integer;
  v_id uuid;
begin
  if p_user_id is null or p_event_id is null or p_reference is null or char_length(p_reference) < 12 then
    raise exception 'invalid_request' using errcode = '22023';
  end if;
  if p_method is null or p_method not in ('mtn_momo', 'airtel_money') then
    raise exception 'invalid_method' using errcode = '22023';
  end if;
  if p_amount is null or p_amount < 100 or p_amount > 5000000 then
    raise exception 'invalid_amount' using errcode = '22023';
  end if;

  select e.group_id, e.status into v_group, v_status from public.events e where e.id = p_event_id;
  if v_group is null then raise exception 'event_not_found' using errcode = 'P0002'; end if;
  if not exists (select 1 from public.group_members gm where gm.group_id = v_group and gm.user_id = p_user_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if v_status <> 'active' then raise exception 'event_not_active' using errcode = '22023'; end if;

  select count(*) into v_recent from public.contributions c
   where c.user_id = p_user_id and c.status = 'pending' and c.created_at > now() - interval '10 minutes';
  if v_recent >= 5 then raise exception 'too_many_pending' using errcode = '53400'; end if;

  insert into public.contributions (event_id, user_id, amount, status, payment_reference, payment_method, provider, is_simulated)
  values (p_event_id, p_user_id, p_amount, 'pending', p_reference, p_method,
          case when p_simulated then 'simulated' else 'intasend' end, p_simulated)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- payment_attach_provider: stores the provider's invoice/checkout id on a pending row
-- ---------------------------------------------------------------------------
create or replace function public.payment_attach_provider(p_reference text, p_provider_ref text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.contributions
     set provider_ref = p_provider_ref, updated_at = now()
   where payment_reference = p_reference and status = 'pending' and provider_ref is null;
end;
$$;

-- ---------------------------------------------------------------------------
-- payment_mark_failed: pending -> failed (provider refused / could not be reached)
-- ---------------------------------------------------------------------------
create or replace function public.payment_mark_failed(p_reference text, p_reason text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.contributions
     set status = 'failed', failure_reason = left(coalesce(p_reason, 'failed'), 200), updated_at = now()
   where payment_reference = p_reference and status = 'pending';
end;
$$;

-- ---------------------------------------------------------------------------
-- payment_settle: the ONLY place a contribution becomes paid / failed / refunded.
-- Call it only with data the Edge Function has verified with the provider (or, in
-- simulated mode, with provider = 'simulated').
-- Returns jsonb { outcome: ... }.
-- ---------------------------------------------------------------------------
create or replace function public.payment_settle(
  p_reference text,
  p_provider text,
  p_provider_event_id text,
  p_state text,            -- COMPLETE | FAILED | REFUNDED | PENDING | PROCESSING
  p_amount bigint,
  p_currency text,
  p_provider_ref text,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_c public.contributions%rowtype;
  v_outcome text;
  v_inserted integer;
begin
  select * into v_c from public.contributions c where c.payment_reference = p_reference for update;

  insert into public.payment_events (provider, provider_event_id, contribution_id, payment_reference, provider_state, amount, currency, payload)
  values (p_provider, p_provider_event_id, v_c.id, p_reference, p_state, p_amount, p_currency, coalesce(p_payload, '{}'::jsonb))
  on conflict (provider, provider_event_id) do nothing;
  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    return jsonb_build_object('outcome', 'duplicate');
  end if;

  if v_c.id is null then
    v_outcome := 'unknown_reference';
  elsif (p_provider = 'simulated') is distinct from v_c.is_simulated or p_provider is distinct from v_c.provider then
    v_outcome := 'provider_mismatch';
  elsif v_c.provider_ref is not null and p_provider_ref is not null and v_c.provider_ref <> p_provider_ref then
    v_outcome := 'ref_mismatch';
  elsif p_state = 'COMPLETE' then
    if v_c.status = 'paid' then
      v_outcome := 'already_paid';
    elsif v_c.status <> 'pending' then
      v_outcome := 'ignored_' || v_c.status;
    elsif p_amount is distinct from v_c.amount or upper(coalesce(p_currency, '')) <> 'RWF' then
      v_outcome := 'amount_mismatch';           -- left pending for manual review, never paid
    else
      update public.contributions
         set status = 'paid', paid_at = now(), failure_reason = null, updated_at = now(),
             provider_ref = coalesce(provider_ref, p_provider_ref)
       where id = v_c.id;
      v_outcome := 'paid';
    end if;
  elsif p_state = 'FAILED' then
    if v_c.status = 'pending' then
      update public.contributions
         set status = 'failed', failure_reason = left(coalesce(p_payload ->> 'failed_reason', 'failed'), 200),
             updated_at = now(), provider_ref = coalesce(provider_ref, p_provider_ref)
       where id = v_c.id;
      v_outcome := 'failed';
    else
      v_outcome := 'ignored_' || v_c.status;
    end if;
  elsif p_state = 'REFUNDED' then
    if v_c.status = 'paid' then
      update public.contributions set status = 'refunded', updated_at = now() where id = v_c.id;
      v_outcome := 'refunded';
    else
      v_outcome := 'ignored_' || v_c.status;
    end if;
  else
    if v_c.status = 'pending' and v_c.provider_ref is null and p_provider_ref is not null then
      update public.contributions set provider_ref = p_provider_ref, updated_at = now() where id = v_c.id;
    end if;
    v_outcome := 'noop';
  end if;

  update public.payment_events
     set outcome = v_outcome
   where provider = p_provider and provider_event_id = p_provider_event_id;

  return jsonb_build_object('outcome', v_outcome, 'contribution_id', v_c.id);
end;
$$;

-- ---------------------------------------------------------------------------
-- payment_expire_stale: pending rows older than p_hours become failed ("expired").
-- Optional: schedule with pg_cron or call from a scheduled Edge Function.
-- ---------------------------------------------------------------------------
create or replace function public.payment_expire_stale(p_hours integer default 24)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_n integer;
begin
  update public.contributions
     set status = 'failed', failure_reason = 'expired', updated_at = now()
   where status = 'pending' and created_at < now() - make_interval(hours => greatest(p_hours, 1));
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------------
-- Service role only
-- ---------------------------------------------------------------------------
revoke all on function public.payment_create_pending(uuid, uuid, bigint, text, text, boolean) from public, anon, authenticated;
revoke all on function public.payment_attach_provider(text, text) from public, anon, authenticated;
revoke all on function public.payment_mark_failed(text, text) from public, anon, authenticated;
revoke all on function public.payment_settle(text, text, text, text, bigint, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.payment_expire_stale(integer) from public, anon, authenticated;

grant execute on function public.payment_create_pending(uuid, uuid, bigint, text, text, boolean) to service_role;
grant execute on function public.payment_attach_provider(text, text) to service_role;
grant execute on function public.payment_mark_failed(text, text) to service_role;
grant execute on function public.payment_settle(text, text, text, text, bigint, text, text, jsonb) to service_role;
grant execute on function public.payment_expire_stale(integer) to service_role;

commit;



-- ===================== 007_manual_momo.sql =====================
-- 007_manual_momo.sql
-- Leader-managed Mobile Money collection (no payment provider needed).
--
--   * The group leader (admin/treasurer) saves a MoMo number or MoMo code on each event.
--   * Members see it, pay from their own phone (the network asks for their PIN itself),
--     then tell SquadVault "I've paid" (a PENDING claim, never counted as money).
--   * The leader confirms (-> paid) or rejects (-> failed) each claim, or records a payment received
--     in person. Only confirmed (paid) rows count toward totals, exactly like before.
--   * event_member_progress() shows who has paid and who has not.
--   * add_member_by_email() lets an admin add someone who already has a SquadVault account.
--
-- Safe to re-run. Never drops data. Prerequisites: 001-006.

begin;

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------
alter table public.events add column if not exists pay_provider text;          -- mtn_momo | airtel_money
alter table public.events add column if not exists pay_kind text;              -- number | code
alter table public.events add column if not exists pay_account text;           -- 07XXXXXXXX or digits of a MoMo code
alter table public.events add column if not exists pay_account_name text;      -- name the network shows (optional)
alter table public.events add column if not exists expected_per_member bigint; -- optional share per member

alter table public.contributions add column if not exists reviewed_by uuid references auth.users (id);
alter table public.contributions add column if not exists reviewed_at timestamptz;
alter table public.contributions add column if not exists note text;

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'events_pay_provider_check') then
    alter table public.events add constraint events_pay_provider_check
      check (pay_provider is null or pay_provider in ('mtn_momo', 'airtel_money')) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'events_pay_kind_check') then
    alter table public.events add constraint events_pay_kind_check
      check (pay_kind is null or pay_kind in ('number', 'code')) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'events_pay_account_check') then
    alter table public.events add constraint events_pay_account_check
      check (pay_account is null or pay_account ~ '^[0-9]{4,10}$') not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'events_expected_check') then
    alter table public.events add constraint events_expected_check
      check (expected_per_member is null or expected_per_member between 1 and 1000000000000) not valid;
  end if;
end $$;

create index if not exists contributions_event_user_idx on public.contributions (event_id, user_id);

-- ---------------------------------------------------------------------------
-- set_event_payment_details: manager only. An empty account CLEARS the details.
-- ---------------------------------------------------------------------------
create or replace function public.set_event_payment_details(
  p_event_id uuid,
  p_provider text,
  p_kind text,
  p_account text,
  p_account_name text default null,
  p_expected_per_member bigint default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group uuid;
  v_status text;
  v_acc text := regexp_replace(coalesce(p_account, ''), '[\s\-]', '', 'g');
  v_name text := nullif(btrim(coalesce(p_account_name, '')), '');
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select e.group_id, e.status into v_group, v_status from public.events e where e.id = p_event_id for update;
  if v_group is null or not private.is_group_manager(v_group) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if v_status <> 'active' then raise exception 'event_not_active' using errcode = '22023'; end if;
  if p_expected_per_member is not null and (p_expected_per_member < 1 or p_expected_per_member > 1000000000000) then
    raise exception 'invalid_amount' using errcode = '22023';
  end if;
  if v_name is not null and char_length(v_name) > 60 then
    raise exception 'invalid_account_name' using errcode = '22023';
  end if;

  if v_acc = '' then
    update public.events
       set pay_provider = null, pay_kind = null, pay_account = null, pay_account_name = null,
           expected_per_member = p_expected_per_member
     where id = p_event_id;
    return;
  end if;

  if p_provider is null or p_provider not in ('mtn_momo', 'airtel_money') then
    raise exception 'invalid_method' using errcode = '22023';
  end if;
  if p_kind is null or p_kind not in ('number', 'code') then
    raise exception 'invalid_pay_kind' using errcode = '22023';
  end if;

  if p_kind = 'number' then
    if v_acc ~ '^\+?250' then v_acc := '0' || regexp_replace(v_acc, '^\+?250', ''); end if;
    if v_acc !~ '^07[2389][0-9]{7}$' then raise exception 'invalid_phone' using errcode = '22023'; end if;
    if (p_provider = 'mtn_momo' and substr(v_acc, 2, 2) not in ('78', '79'))
       or (p_provider = 'airtel_money' and substr(v_acc, 2, 2) not in ('72', '73')) then
      raise exception 'phone_network_mismatch' using errcode = '22023';
    end if;
  else
    if v_acc !~ '^[0-9]{4,10}$' then raise exception 'invalid_pay_code' using errcode = '22023'; end if;
  end if;

  update public.events
     set pay_provider = p_provider, pay_kind = p_kind, pay_account = v_acc, pay_account_name = v_name,
         expected_per_member = p_expected_per_member
   where id = p_event_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- submit_payment_claim: a member says "I paid". Creates a PENDING row (never counted).
-- ---------------------------------------------------------------------------
create or replace function public.submit_payment_claim(
  p_event_id uuid,
  p_amount bigint,
  p_txn_ref text default null
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
  v_provider text;
  v_account text;
  v_txn text := upper(nullif(btrim(coalesce(p_txn_ref, '')), ''));
  v_open integer;
  v_id uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select e.group_id, e.status, e.pay_provider, e.pay_account
    into v_group, v_status, v_provider, v_account
    from public.events e where e.id = p_event_id;
  if v_group is null or not private.is_group_member(v_group) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if v_status <> 'active' then raise exception 'event_not_active' using errcode = '22023'; end if;
  if v_account is null then raise exception 'payment_details_missing' using errcode = '22023'; end if;
  if p_amount is null or p_amount < 100 or p_amount > 5000000 then
    raise exception 'invalid_amount' using errcode = '22023';
  end if;
  if v_txn is not null and v_txn !~ '^[A-Z0-9]{6,20}$' then
    raise exception 'invalid_reference' using errcode = '22023';
  end if;

  select count(*) into v_open from public.contributions c
   where c.user_id = v_uid and c.event_id = p_event_id and c.status = 'pending' and c.provider = 'manual';
  if v_open >= 5 then raise exception 'too_many_pending' using errcode = '53400'; end if;

  begin
    insert into public.contributions (event_id, user_id, amount, status, payment_method, provider, provider_ref, payment_reference, is_simulated)
    values (p_event_id, v_uid, p_amount, 'pending', v_provider, 'manual', v_txn,
            'SV-M-' || replace(gen_random_uuid()::text, '-', ''), false)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'duplicate_reference' using errcode = '23505';
  end;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- review_contribution: manager confirms / rejects a manual claim, or marks a confirmed one refunded.
--   pending -> paid | failed        paid -> refunded
-- Provider-verified rows (IntaSend) are never touched here. Only the admin may review their own claim.
-- ---------------------------------------------------------------------------
create or replace function public.review_contribution(
  p_contribution_id uuid,
  p_decision text,
  p_reason text default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_user uuid;
  v_status text;
  v_provider text;
  v_event uuid;
  v_group uuid;
  v_ev_status text;
  v_reason text := left(nullif(btrim(coalesce(p_reason, '')), ''), 120);
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_decision is null or p_decision not in ('paid', 'failed', 'refunded') then
    raise exception 'invalid_status' using errcode = '22023';
  end if;
  select c.user_id, c.status, c.provider, c.event_id
    into v_user, v_status, v_provider, v_event
    from public.contributions c where c.id = p_contribution_id for update;
  if v_event is null then raise exception 'not_found' using errcode = 'P0002'; end if;
  select e.group_id, e.status into v_group, v_ev_status from public.events e where e.id = v_event;
  if v_group is null or not private.is_group_manager(v_group) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if v_provider is distinct from 'manual' then raise exception 'not_manual' using errcode = '22023'; end if;
  if v_user = v_uid and private.group_role(v_group) <> 'admin' then
    raise exception 'cannot_review_own' using errcode = '42501';
  end if;

  if p_decision = 'refunded' then
    if v_status <> 'paid' then raise exception 'invalid_transition' using errcode = '22023'; end if;
    update public.contributions
       set status = 'refunded', failure_reason = coalesce(v_reason, 'Refunded by the leader'),
           reviewed_by = v_uid, reviewed_at = now(), updated_at = now()
     where id = p_contribution_id;
    return 'refunded';
  end if;

  if v_status <> 'pending' then raise exception 'invalid_transition' using errcode = '22023'; end if;
  if p_decision = 'paid' then
    if v_ev_status = 'cancelled' then raise exception 'event_not_active' using errcode = '22023'; end if;
    update public.contributions
       set status = 'paid', paid_at = now(), failure_reason = null,
           reviewed_by = v_uid, reviewed_at = now(), updated_at = now()
     where id = p_contribution_id;
    return 'paid';
  end if;

  update public.contributions
     set status = 'failed', failure_reason = coalesce(v_reason, 'Not received by the leader'),
         reviewed_by = v_uid, reviewed_at = now(), updated_at = now()
   where id = p_contribution_id;
  return 'failed';
end;
$$;

-- ---------------------------------------------------------------------------
-- record_manual_contribution: manager records money received (cash, or MoMo seen on their phone)
-- for a current member. Stored already confirmed.
-- ---------------------------------------------------------------------------
create or replace function public.record_manual_contribution(
  p_event_id uuid,
  p_user_id uuid,
  p_amount bigint,
  p_note text default null
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
  v_provider text;
  v_note text := left(nullif(btrim(coalesce(p_note, '')), ''), 120);
  v_id uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select e.group_id, e.status, e.pay_provider into v_group, v_status, v_provider
    from public.events e where e.id = p_event_id for update;
  if v_group is null or not private.is_group_manager(v_group) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if v_status <> 'active' then raise exception 'event_not_active' using errcode = '22023'; end if;
  if not exists (select 1 from public.group_members gm where gm.group_id = v_group and gm.user_id = p_user_id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if p_amount is null or p_amount < 100 or p_amount > 5000000 then
    raise exception 'invalid_amount' using errcode = '22023';
  end if;

  insert into public.contributions (event_id, user_id, amount, status, payment_method, provider, payment_reference,
                                    is_simulated, paid_at, reviewed_by, reviewed_at, note)
  values (p_event_id, p_user_id, p_amount, 'paid', v_provider, 'manual', 'SV-M-' || replace(gen_random_uuid()::text, '-', ''),
          false, now(), v_uid, now(), v_note)
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- event_member_progress: who has paid and who has not. Any group member may read it (the same
-- contributions are already visible to them through RLS). Includes people who contributed and have
-- since left, so the per-person totals always add up to the event total (role is NULL for them).
-- ---------------------------------------------------------------------------
create or replace function public.event_member_progress(p_event_id uuid)
returns table (
  user_id uuid,
  role text,
  paid_total bigint,
  paid_count integer,
  pending_total bigint,
  pending_count integer,
  last_paid_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_group uuid;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select e.group_id into v_group from public.events e where e.id = p_event_id;
  if v_group is null or not private.is_group_member(v_group) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return query
    with ids as (
      select gm.user_id as uid from public.group_members gm where gm.group_id = v_group
      union
      select c.user_id from public.contributions c where c.event_id = p_event_id
    )
    select i.uid,
           gm.role,
           coalesce(sum(c.amount) filter (where c.status = 'paid'), 0)::bigint,
           (count(*) filter (where c.status = 'paid'))::integer,
           coalesce(sum(c.amount) filter (where c.status = 'pending'), 0)::bigint,
           (count(*) filter (where c.status = 'pending'))::integer,
           max(c.paid_at) filter (where c.status = 'paid')
      from ids i
      left join public.group_members gm on gm.group_id = v_group and gm.user_id = i.uid
      left join public.contributions c on c.event_id = p_event_id and c.user_id = i.uid
     group by i.uid, gm.role;
end;
$$;

-- ---------------------------------------------------------------------------
-- add_member_by_email: admin adds someone who ALREADY has a SquadVault account.
-- (Everyone else can use an invitation code.) Admin-only, so the lookup is not a public oracle.
-- ---------------------------------------------------------------------------
create or replace function public.add_member_by_email(p_group_id uuid, p_email text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_email text := lower(btrim(coalesce(p_email, '')));
  v_user uuid;
  v_count integer;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or private.group_role(p_group_id) is distinct from 'admin' then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if char_length(v_email) < 5 or char_length(v_email) > 254 or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid_email' using errcode = '22023';
  end if;
  select u.id into v_user from auth.users u where lower(u.email) = v_email limit 1;
  if v_user is null then raise exception 'no_such_user' using errcode = 'P0002'; end if;
  if exists (select 1 from public.group_members gm where gm.group_id = p_group_id and gm.user_id = v_user) then
    raise exception 'already_member' using errcode = '23505';
  end if;
  select count(*) into v_count from public.group_members gm where gm.group_id = p_group_id;
  if v_count >= 500 then raise exception 'group_full' using errcode = '22023'; end if;
  insert into public.group_members (group_id, user_id, role) values (p_group_id, v_user, 'member');
  return v_user;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on function public.set_event_payment_details(uuid, text, text, text, text, bigint) from public, anon;
revoke all on function public.submit_payment_claim(uuid, bigint, text) from public, anon;
revoke all on function public.review_contribution(uuid, text, text) from public, anon;
revoke all on function public.record_manual_contribution(uuid, uuid, bigint, text) from public, anon;
revoke all on function public.event_member_progress(uuid) from public, anon;
revoke all on function public.add_member_by_email(uuid, text) from public, anon;

grant execute on function public.set_event_payment_details(uuid, text, text, text, text, bigint) to authenticated;
grant execute on function public.submit_payment_claim(uuid, bigint, text) to authenticated;
grant execute on function public.review_contribution(uuid, text, text) to authenticated;
grant execute on function public.record_manual_contribution(uuid, uuid, bigint, text) to authenticated;
grant execute on function public.event_member_progress(uuid) to authenticated;
grant execute on function public.add_member_by_email(uuid, text) to authenticated;

commit;
