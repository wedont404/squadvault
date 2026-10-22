-- SQUADVAULT: ALL MISSING PIECES IN ONE FILE (migrations 001-010, in order).
-- Paste the WHOLE file into Supabase -> SQL Editor -> Run. Safe to run again. Never deletes your data.
-- Run it AFTER your existing tables/functions SQL. Do NOT re-run your older create_*/join_* functions afterwards.

-- ===== 001_schema_reconciliation.sql =====
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

-- ===== 002_invitation_system.sql =====
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

-- ===== 003_rls_policies.sql =====
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

-- ===== 004_storage_policies.sql =====
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

-- ===== 005_app_functions.sql =====
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
drop function if exists public.list_invitations(uuid);
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

-- ===== 006_payment_functions.sql =====
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

-- ===== 007_manual_momo.sql =====
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

-- ===== 008_sms_verification.sql =====
-- 008_sms_verification.sql
-- Automatic checking of Mobile Money payments, WITHOUT a payment-provider API.
--
-- How it works
--   The leader's Android phone receives the normal "You have received ... RWF" MoMo SMS from MTN/Airtel.
--   A free SMS-forwarder app on that phone sends each SMS to ingest_momo_sms() together with a secret
--   collector token. We parse out amount + transaction ID (+ the payer's name as a hint) and store ONLY those
--   fields (never the raw SMS). A member's "I've paid" claim is confirmed automatically when its transaction
--   ID and amount match one unused receipt exactly. Anything weaker is only SHOWN to the leader as a suggestion.
--
-- Safety properties
--   * Each receipt can confirm at most one claim (unique index), and each transaction ID is stored once per group.
--   * Auto-confirmation requires an exact transaction ID AND exact amount. Amount-only matches are suggestions.
--   * The token is random (128 bit), stored only as a SHA-256 hash, shown once, revocable.
--   * ingest_momo_sms is the ONLY function the anonymous role may run; it answers every bad token the same way.
--
-- Safe to re-run. Prerequisites: 001-007.

begin;

-- ---------------------------------------------------------------------------
-- Tables (RLS on, no policies, no grants: reachable only through the functions below)
-- ---------------------------------------------------------------------------
create table if not exists public.momo_collectors (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.savings_groups (id) on delete cascade,
  token_hash text not null unique,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now(),
  last_seen_at timestamptz,
  revoked_at timestamptz
);
create unique index if not exists momo_collectors_one_active on public.momo_collectors (group_id) where revoked_at is null;

create table if not exists public.momo_receipts (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.savings_groups (id) on delete cascade,
  txn_id text,
  amount bigint not null check (amount > 0 and amount <= 1000000000000),
  payer_hint text,
  msg_hash text not null,
  received_at timestamptz not null default now(),
  matched_contribution_id uuid references public.contributions (id) on delete set null,
  constraint momo_receipts_msg_unique unique (group_id, msg_hash)
);
create unique index if not exists momo_receipts_txn_uidx on public.momo_receipts (group_id, txn_id) where txn_id is not null;
create unique index if not exists momo_receipts_match_uidx on public.momo_receipts (matched_contribution_id) where matched_contribution_id is not null;
create index if not exists momo_receipts_group_time_idx on public.momo_receipts (group_id, received_at desc);

alter table public.momo_collectors enable row level security;
alter table public.momo_receipts enable row level security;
revoke all on public.momo_collectors, public.momo_receipts from anon, authenticated;
grant select, insert, update, delete on public.momo_collectors, public.momo_receipts to service_role;

-- ---------------------------------------------------------------------------
-- SMS parser. Deliberately conservative: only "money received" messages count, outgoing ones never do.
-- The exact wording of MTN / Airtel SMS can change, so the app has a "test a sample SMS" box.
-- ---------------------------------------------------------------------------
create or replace function private.parse_momo_sms(p_msg text)
returns table (is_receipt boolean, amount bigint, txn_id text, payer_hint text)
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := btrim(regexp_replace(coalesce(p_msg, ''), '\s+', ' ', 'g'));
  m text[];
  n numeric;
begin
  is_receipt := false; amount := null; txn_id := null; payer_hint := null;
  if char_length(v) < 10 or char_length(v) > 1000 then return next; return; end if;
  if v !~* '(received|wakiriye|yakiriye|kwakira|reçu|recu)' then return next; return; end if;
  if v ~* 'you have (sent|paid|transferred)' then return next; return; end if;

  m := regexp_match(v, 'received\s+(?:an?\s+)?(?:amount\s+of\s+)?(?:RWF|FRW)?\s*([0-9][0-9,]*(?:\.[0-9]+)?)', 'i');
  if m is null then
    m := regexp_match(v, '([0-9][0-9,]*(?:\.[0-9]+)?)\s*(?:RWF|FRW)', 'i');
  end if;
  if m is null then return next; return; end if;
  n := replace(m[1], ',', '')::numeric;
  if n < 1 or n > 1000000000000 then return next; return; end if;
  amount := floor(n)::bigint;

  m := regexp_match(v, 'transaction\s*(?:id|ref(?:erence)?|no\.?)?\s*(?:is|:|-|#)?\s*:?\s*([0-9]{6,20})', 'i');
  if m is null then
    m := regexp_match(v, '\y(?:txid|trx\s*id|ref(?:erence)?)\y\s*(?:is|:|-|#)?\s*:?\s*([0-9A-Z]{6,20})', 'i');
  end if;
  if m is not null then txn_id := upper(m[1]); end if;

  m := regexp_match(v, '\yfrom\s+([A-Za-z][A-Za-z .''-]{1,40})', 'i');
  if m is not null then
    payer_hint := nullif(left(btrim(regexp_replace(m[1], '\s+(on|at|to|with)(\s.*)?$', '', 'i')), 40), '');
  end if;

  is_receipt := true;
  return next;
end;
$$;
revoke all on function private.parse_momo_sms(text) from public, anon;
grant execute on function private.parse_momo_sms(text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Collector token management (managers only)
-- ---------------------------------------------------------------------------
create or replace function public.create_collector_token(p_group_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_token text := 'SVC-' || upper(encode(extensions.gen_random_bytes(16), 'hex'));
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_manager(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  update public.momo_collectors set revoked_at = now() where group_id = p_group_id and revoked_at is null;
  insert into public.momo_collectors (group_id, token_hash, created_by)
  values (p_group_id, encode(extensions.digest(v_token, 'sha256'), 'hex'), auth.uid());
  return v_token;
end;
$$;

create or replace function public.revoke_collector_token(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_manager(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  update public.momo_collectors set revoked_at = now() where group_id = p_group_id and revoked_at is null;
end;
$$;

create or replace function public.collector_status(p_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c record;
  v_count integer;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_manager(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  select mc.created_at, mc.last_seen_at into c from public.momo_collectors mc
   where mc.group_id = p_group_id and mc.revoked_at is null;
  select count(*) into v_count from public.momo_receipts r
   where r.group_id = p_group_id and r.received_at > now() - interval '30 days';
  return jsonb_build_object(
    'active', c.created_at is not null,
    'created_at', c.created_at,
    'last_seen_at', c.last_seen_at,
    'receipts_30d', v_count
  );
end;
$$;

-- Parse a sample SMS WITHOUT storing anything (lets the leader check the parser on a real message).
create or replace function public.preview_momo_sms(p_message text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  p record;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into p from private.parse_momo_sms(left(coalesce(p_message, ''), 1000));
  return jsonb_build_object('is_receipt', p.is_receipt, 'amount', p.amount, 'txn_id', p.txn_id, 'payer_hint', p.payer_hint);
end;
$$;

-- ---------------------------------------------------------------------------
-- ingest_momo_sms: called by the SMS-forwarder app on the leader's phone (anonymous role + secret token).
-- Always answers a bad token the same way. Never stores the raw SMS.
-- ---------------------------------------------------------------------------
create or replace function public.ingest_momo_sms(p_token text, p_message text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tok text := upper(btrim(coalesce(p_token, '')));
  v_cid uuid;
  v_gid uuid;
  v_recent integer;
  p record;
  v_hash text;
  v_rid uuid;
  v_claim uuid;
begin
  if v_tok !~ '^SVC-[0-9A-F]{32}$' then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  select c.id, c.group_id into v_cid, v_gid
    from public.momo_collectors c
   where c.token_hash = encode(extensions.digest(v_tok, 'sha256'), 'hex') and c.revoked_at is null;
  if v_cid is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;

  update public.momo_collectors set last_seen_at = now() where id = v_cid;

  select count(*) into v_recent from public.momo_receipts r
   where r.group_id = v_gid and r.received_at > now() - interval '1 minute';
  if v_recent >= 30 then return jsonb_build_object('ok', false, 'error', 'slow_down'); end if;

  select * into p from private.parse_momo_sms(left(coalesce(p_message, ''), 1000));
  if not p.is_receipt then return jsonb_build_object('ok', true, 'stored', false, 'reason', 'not_a_receipt'); end if;

  v_hash := encode(extensions.digest(lower(regexp_replace(coalesce(p_message, ''), '\s+', ' ', 'g')), 'sha256'), 'hex');
  insert into public.momo_receipts (group_id, txn_id, amount, payer_hint, msg_hash)
  values (v_gid, p.txn_id, p.amount, p.payer_hint, v_hash)
  on conflict do nothing
  returning id into v_rid;
  if v_rid is null then return jsonb_build_object('ok', true, 'stored', false, 'reason', 'duplicate'); end if;

  -- exact transaction ID + exact amount => confirm the waiting claim
  if p.txn_id is not null then
    select c.id into v_claim
      from public.contributions c
      join public.events e on e.id = c.event_id
     where e.group_id = v_gid and e.status = 'active'
       and c.provider = 'manual' and c.status = 'pending'
       and c.provider_ref = p.txn_id and c.amount = p.amount
     order by c.created_at
     limit 1
       for update of c skip locked;
    if v_claim is not null then
      update public.contributions
         set status = 'paid', paid_at = now(), failure_reason = null, reviewed_at = now(),
             note = 'Auto-verified from MoMo SMS', updated_at = now()
       where id = v_claim;
      update public.momo_receipts set matched_contribution_id = v_claim where id = v_rid;
    end if;
  end if;

  return jsonb_build_object('ok', true, 'stored', true, 'matched', v_claim is not null);
end;
$$;

-- ---------------------------------------------------------------------------
-- submit_payment_claim (replaces 007): if the member gives the transaction ID and a matching unused receipt
-- already arrived, the claim is confirmed immediately.
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
  v_rid uuid;
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

  if v_txn is not null then
    select r.id into v_rid from public.momo_receipts r
     where r.group_id = v_group and r.txn_id = v_txn and r.amount = p_amount and r.matched_contribution_id is null
       for update;
    if v_rid is not null then
      update public.contributions
         set status = 'paid', paid_at = now(), reviewed_at = now(), note = 'Auto-verified from MoMo SMS', updated_at = now()
       where id = v_id;
      update public.momo_receipts set matched_contribution_id = v_id where id = v_rid;
    end if;
  end if;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- claim_match_hints: for the leader, which received-SMS records could belong to each waiting claim.
--   strength 'id'     = same transaction ID (the amount may differ: the app flags that)
--   strength 'amount' = same amount, received around the time of the claim (a suggestion only)
-- ---------------------------------------------------------------------------
drop function if exists public.claim_match_hints(uuid);
create or replace function public.claim_match_hints(p_event_id uuid)
returns table (
  contribution_id uuid,
  receipt_id uuid,
  strength text,
  receipt_amount bigint,
  payer_hint text,
  received_at timestamptz,
  txn_id text
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
  if v_group is null or not private.is_group_manager(v_group) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return query
    select x.cid, x.rid, x.strength, x.amt, x.hint, x.at, x.tid
      from (
        select c.id as cid, r.id as rid,
               case when r.txn_id is not null and r.txn_id = c.provider_ref then 'id' else 'amount' end as strength,
               r.amount as amt, r.payer_hint as hint, r.received_at as at, r.txn_id as tid,
               row_number() over (
                 partition by c.id
                 order by (r.txn_id is not null and r.txn_id = c.provider_ref) desc, r.received_at desc
               ) as rn
          from public.contributions c
          join public.momo_receipts r on r.group_id = v_group and r.matched_contribution_id is null
         where c.event_id = p_event_id and c.provider = 'manual' and c.status = 'pending'
           and (
             (c.provider_ref is not null and r.txn_id = c.provider_ref)
             or (
               r.amount = c.amount
               and (c.provider_ref is null or r.txn_id is null)
               and r.received_at between c.created_at - interval '2 days' and c.created_at + interval '1 day'
             )
           )
      ) x
     where x.rn <= 3;
end;
$$;

-- ---------------------------------------------------------------------------
-- confirm_with_receipt: the leader confirms a waiting claim against a specific received SMS (exact amount).
-- ---------------------------------------------------------------------------
create or replace function public.confirm_with_receipt(p_contribution_id uuid, p_receipt_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_user uuid;
  v_status text;
  v_provider text;
  v_amount bigint;
  v_event uuid;
  v_group uuid;
  v_ev_status text;
  r_group uuid;
  r_amount bigint;
  r_matched uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select c.user_id, c.status, c.provider, c.amount, c.event_id
    into v_user, v_status, v_provider, v_amount, v_event
    from public.contributions c where c.id = p_contribution_id for update;
  if v_event is null then raise exception 'not_found' using errcode = 'P0002'; end if;
  select e.group_id, e.status into v_group, v_ev_status from public.events e where e.id = v_event;
  if v_group is null or not private.is_group_manager(v_group) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if v_provider is distinct from 'manual' then raise exception 'not_manual' using errcode = '22023'; end if;
  if v_status <> 'pending' then raise exception 'invalid_transition' using errcode = '22023'; end if;
  if v_ev_status = 'cancelled' then raise exception 'event_not_active' using errcode = '22023'; end if;
  if v_user = v_uid and private.group_role(v_group) <> 'admin' then
    raise exception 'cannot_review_own' using errcode = '42501';
  end if;

  select r.group_id, r.amount, r.matched_contribution_id into r_group, r_amount, r_matched
    from public.momo_receipts r where r.id = p_receipt_id for update;
  if r_group is distinct from v_group then raise exception 'not_found' using errcode = 'P0002'; end if;
  if r_matched is not null then raise exception 'receipt_used' using errcode = '22023'; end if;
  if r_amount <> v_amount then raise exception 'amount_mismatch' using errcode = '22023'; end if;

  update public.contributions
     set status = 'paid', paid_at = now(), failure_reason = null, reviewed_by = v_uid, reviewed_at = now(),
         note = 'Confirmed against MoMo SMS', updated_at = now()
   where id = p_contribution_id;
  update public.momo_receipts set matched_contribution_id = p_contribution_id where id = p_receipt_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants. ingest_momo_sms is the one function the anonymous role may call.
-- ---------------------------------------------------------------------------
revoke all on function public.create_collector_token(uuid) from public, anon;
revoke all on function public.revoke_collector_token(uuid) from public, anon;
revoke all on function public.collector_status(uuid) from public, anon;
revoke all on function public.preview_momo_sms(text) from public, anon;
revoke all on function public.ingest_momo_sms(text, text) from public;
revoke all on function public.submit_payment_claim(uuid, bigint, text) from public, anon;
revoke all on function public.claim_match_hints(uuid) from public, anon;
revoke all on function public.confirm_with_receipt(uuid, uuid) from public, anon;

grant execute on function public.create_collector_token(uuid) to authenticated;
grant execute on function public.revoke_collector_token(uuid) to authenticated;
grant execute on function public.collector_status(uuid) to authenticated;
grant execute on function public.preview_momo_sms(text) to authenticated;
grant execute on function public.ingest_momo_sms(text, text) to anon, authenticated;
grant execute on function public.submit_payment_claim(uuid, bigint, text) to authenticated;
grant execute on function public.claim_match_hints(uuid) to authenticated;
grant execute on function public.confirm_with_receipt(uuid, uuid) to authenticated;

commit;

-- ===== 009_community.sql =====
-- 009_community.sql
-- 1. Invitation codes stay visible to leaders (no more generating codes just to see one).
-- 2. Sender-name checking: members say the name MoMo shows, new MoMo messages are re-checked against waiting
--    claims by name + amount (when the leader allows it).
-- 3. Event pictures, group chat, photo wall (with hearts), group games (polls + "guess the number").
--
-- Safe to re-run. Prerequisites: 001-008. Never deletes data.

begin;

-- ===========================================================================
-- 1. Invitation codes the leader can look at again
--    The code is kept next to its hash so managers can re-read it. It is only ever returned by
--    list_invitations(), which is manager-only. Codes made before this update can't be recovered.
-- ===========================================================================
alter table public.invitation_codes add column if not exists code_plain text;

create or replace function public.create_invitation_code(
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
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_manager(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if v_max < 1 or v_max > 100 then raise exception 'invalid_max_uses' using errcode = '22023'; end if;
  if v_days < 1 or v_days > 30 then raise exception 'invalid_valid_days' using errcode = '22023'; end if;
  if (select count(*) from public.invitation_codes ic
      where ic.group_id = p_group_id and ic.revoked_at is null and ic.expires_at > now()) >= 25 then
    raise exception 'too_many_active_invitations' using errcode = '53400';
  end if;

  v_code := 'SV-' || upper(encode(extensions.gen_random_bytes(6), 'hex'));
  v_hash := encode(extensions.digest(v_code, 'sha256'), 'hex');
  v_expires := now() + make_interval(days => v_days);

  insert into public.invitation_codes (group_id, code_hash, code_plain, created_by, max_uses, expires_at)
  values (p_group_id, v_hash, v_code, v_uid, v_max, v_expires)
  returning id into v_id;

  return jsonb_build_object('id', v_id, 'code', v_code, 'expires_at', v_expires, 'max_uses', v_max);
end;
$$;

drop function if exists public.list_invitations(uuid);
create function public.list_invitations(p_group_id uuid)
returns table (
  id uuid, created_by uuid, created_at timestamptz, expires_at timestamptz,
  max_uses integer, use_count integer, revoked_at timestamptz, status text, code text
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
           end,
           case when ic.revoked_at is null and ic.expires_at > now() and ic.use_count < ic.max_uses then ic.code_plain end
    from public.invitation_codes ic
    where ic.group_id = p_group_id
    order by ic.created_at desc
    limit 50;
end;
$$;
revoke all on function public.list_invitations(uuid) from public, anon;
grant execute on function public.list_invitations(uuid) to authenticated;

-- ===========================================================================
-- 2. Sender names + automatic re-checking of waiting claims
-- ===========================================================================
alter table public.contributions add column if not exists sender_name text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'contributions_sender_name_len') then
    alter table public.contributions add constraint contributions_sender_name_len
      check (sender_name is null or char_length(sender_name) <= 60);
  end if;
end $$;

alter table public.momo_collectors add column if not exists auto_by_name boolean not null default true;

-- Lower-case letters only, accents folded, tokens of 2+ letters, de-duplicated.
create or replace function private.name_tokens(p_name text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(array_agg(distinct t), '{}'::text[])
    from unnest(regexp_split_to_array(
           btrim(regexp_replace(
             translate(lower(coalesce(p_name, '')), 'áàâäãéèêëíìîïóòôöõúùûüç', 'aaaaaeeeeiiiiooooouuuuc'),
             '[^a-z]+', ' ', 'g')), '\s+')) as t
   where char_length(t) >= 2;
$$;

-- 0..100: share of the shorter name's words that also appear in the other name.
create or replace function private.name_score(p_a text, p_b text)
returns integer
language sql
immutable
set search_path = ''
as $$
  with t as (select private.name_tokens(p_a) as a, private.name_tokens(p_b) as b)
  select case
    when coalesce(array_length(a, 1), 0) = 0 or coalesce(array_length(b, 1), 0) = 0 then 0
    else (100 * (select count(*) from unnest(a) x where x = any (b))
          / least(array_length(a, 1), array_length(b, 1)))::integer
  end
  from t;
$$;

-- "Strong" = every word of the shorter name is in the other one, and it is at least two words
-- (or both names are the same single word). One shared first name is never enough on its own.
create or replace function private.name_strong(p_a text, p_b text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  with t as (select private.name_tokens(p_a) as a, private.name_tokens(p_b) as b)
  select coalesce(
    private.name_score(p_a, p_b) = 100
    and (least(array_length(a, 1), array_length(b, 1)) >= 2
         or (array_length(a, 1) = 1 and array_length(b, 1) = 1)),
    false)
  from t;
$$;
revoke all on function private.name_tokens(text), private.name_score(text, text), private.name_strong(text, text) from public, anon;
grant execute on function private.name_tokens(text), private.name_score(text, text), private.name_strong(text, text) to authenticated, service_role;

-- The one place that decides automatic confirmation. Called whenever a MoMo message arrives and
-- whenever a claim is submitted, so a claim and its message are matched whichever comes first.
--   rule 1: same transaction ID and same amount
--   rule 2: (leader allows it) claim has no transaction ID, same amount, close in time, the MoMo sender name
--           matches the name the member gave (or their profile name) strongly, AND the pairing is unique
--           from both sides (one candidate message for the claim, one candidate claim for the message).
-- Anything ambiguous is left for the leader, with the suggestion visible.
create or replace function private.auto_match_group(p_group uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_claim uuid;
  v_by_name boolean;
  v_n integer := 0;
  v_cands integer;
  v_back integer;
begin
  select coalesce((select mc.auto_by_name from public.momo_collectors mc
                    where mc.group_id = p_group and mc.revoked_at is null), false) into v_by_name;

  for r in
    select * from public.momo_receipts
     where group_id = p_group and matched_contribution_id is null and received_at > now() - interval '3 days'
     order by received_at
     limit 200
       for update skip locked
  loop
    v_claim := null;

    if r.txn_id is not null then
      select c.id into v_claim
        from public.contributions c join public.events e on e.id = c.event_id
       where e.group_id = p_group and e.status = 'active'
         and c.provider = 'manual' and c.status = 'pending'
         and c.provider_ref = r.txn_id and c.amount = r.amount
       order by c.created_at limit 1
         for update of c skip locked;
      if v_claim is not null then
        update public.contributions
           set status = 'paid', paid_at = now(), failure_reason = null, reviewed_at = now(),
               note = 'Auto-verified from MoMo SMS', updated_at = now()
         where id = v_claim;
      end if;
    end if;

    if v_claim is null and v_by_name and r.payer_hint is not null then
      -- claims that could belong to this message
      select count(*) into v_cands
        from public.contributions c
        join public.events e on e.id = c.event_id
        join public.profiles p on p.id = c.user_id
       where e.group_id = p_group and e.status = 'active'
         and c.provider = 'manual' and c.status = 'pending' and c.provider_ref is null
         and c.amount = r.amount
         and r.received_at between c.created_at - interval '2 days' and c.created_at + interval '1 day'
         and private.name_strong(coalesce(c.sender_name, p.display_name), r.payer_hint);
      if v_cands = 1 then
        select c.id into v_claim
          from public.contributions c
          join public.events e on e.id = c.event_id
          join public.profiles p on p.id = c.user_id
         where e.group_id = p_group and e.status = 'active'
           and c.provider = 'manual' and c.status = 'pending' and c.provider_ref is null
           and c.amount = r.amount
           and r.received_at between c.created_at - interval '2 days' and c.created_at + interval '1 day'
           and private.name_strong(coalesce(c.sender_name, p.display_name), r.payer_hint)
           for update of c skip locked;
        if v_claim is not null then
          -- from the claim's side: it must have exactly one candidate message too
          select count(*) into v_back
            from public.momo_receipts r2, public.contributions c, public.profiles p
           where c.id = v_claim and p.id = c.user_id
             and r2.group_id = p_group and r2.matched_contribution_id is null
             and r2.amount = c.amount
             and r2.received_at between c.created_at - interval '2 days' and c.created_at + interval '1 day'
             and r2.payer_hint is not null
             and private.name_strong(coalesce(c.sender_name, p.display_name), r2.payer_hint);
          if v_back = 1 then
            update public.contributions
               set status = 'paid', paid_at = now(), failure_reason = null, reviewed_at = now(),
                   note = 'Auto-verified from MoMo SMS (sender name and amount)', updated_at = now()
             where id = v_claim;
          else
            v_claim := null;
          end if;
        end if;
      end if;
    end if;

    if v_claim is not null then
      update public.momo_receipts set matched_contribution_id = v_claim where id = r.id;
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end;
$$;
revoke all on function private.auto_match_group(uuid) from public, anon, authenticated;

-- ingest: store the message, then re-check every waiting claim of the group.
create or replace function public.ingest_momo_sms(p_token text, p_message text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tok text := upper(btrim(coalesce(p_token, '')));
  v_cid uuid;
  v_gid uuid;
  v_recent integer;
  p record;
  v_hash text;
  v_rid uuid;
  v_matched boolean;
begin
  if v_tok !~ '^SVC-[0-9A-F]{32}$' then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  select c.id, c.group_id into v_cid, v_gid
    from public.momo_collectors c
   where c.token_hash = encode(extensions.digest(v_tok, 'sha256'), 'hex') and c.revoked_at is null;
  if v_cid is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;

  update public.momo_collectors set last_seen_at = now() where id = v_cid;

  select count(*) into v_recent from public.momo_receipts r
   where r.group_id = v_gid and r.received_at > now() - interval '1 minute';
  if v_recent >= 30 then return jsonb_build_object('ok', false, 'error', 'slow_down'); end if;

  select * into p from private.parse_momo_sms(left(coalesce(p_message, ''), 1000));
  if not p.is_receipt then return jsonb_build_object('ok', true, 'stored', false, 'reason', 'not_a_receipt'); end if;

  v_hash := encode(extensions.digest(lower(regexp_replace(coalesce(p_message, ''), '\s+', ' ', 'g')), 'sha256'), 'hex');
  insert into public.momo_receipts (group_id, txn_id, amount, payer_hint, msg_hash)
  values (v_gid, p.txn_id, p.amount, p.payer_hint, v_hash)
  on conflict do nothing
  returning id into v_rid;
  if v_rid is null then return jsonb_build_object('ok', true, 'stored', false, 'reason', 'duplicate'); end if;

  perform private.auto_match_group(v_gid);
  select (r.matched_contribution_id is not null) into v_matched from public.momo_receipts r where r.id = v_rid;
  return jsonb_build_object('ok', true, 'stored', true, 'matched', coalesce(v_matched, false));
end;
$$;
revoke all on function public.ingest_momo_sms(text, text) from public;
grant execute on function public.ingest_momo_sms(text, text) to anon, authenticated;

-- claim: now takes the name MoMo shows for the sender (optional) and re-checks right away.
drop function if exists public.submit_payment_claim(uuid, bigint, text);
create or replace function public.submit_payment_claim(
  p_event_id uuid,
  p_amount bigint,
  p_txn_ref text default null,
  p_sender_name text default null
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
  v_name text := left(nullif(btrim(regexp_replace(coalesce(p_sender_name, ''), '\s+', ' ', 'g')), ''), 60);
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
    insert into public.contributions (event_id, user_id, amount, status, payment_method, provider, provider_ref, payment_reference, is_simulated, sender_name)
    values (p_event_id, v_uid, p_amount, 'pending', v_provider, 'manual', v_txn,
            'SV-M-' || replace(gen_random_uuid()::text, '-', ''), false, v_name)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'duplicate_reference' using errcode = '23505';
  end;

  perform private.auto_match_group(v_group);
  return v_id;
end;
$$;
revoke all on function public.submit_payment_claim(uuid, bigint, text, text) from public, anon;
grant execute on function public.submit_payment_claim(uuid, bigint, text, text) to authenticated;

-- Hints for the leader now include a name score and the name the member gave.
drop function if exists public.claim_match_hints(uuid);
create function public.claim_match_hints(p_event_id uuid)
returns table (
  contribution_id uuid,
  receipt_id uuid,
  strength text,
  receipt_amount bigint,
  payer_hint text,
  received_at timestamptz,
  txn_id text,
  name_score integer
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
  if v_group is null or not private.is_group_manager(v_group) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return query
    select x.cid, x.rid, x.strength, x.amt, x.hint, x.at, x.tid, x.ns
      from (
        select c.id as cid, r.id as rid,
               case when r.txn_id is not null and r.txn_id = c.provider_ref then 'id'
                    when private.name_score(coalesce(c.sender_name, p.display_name), r.payer_hint) >= 50 then 'name'
                    else 'amount' end as strength,
               r.amount as amt, r.payer_hint as hint, r.received_at as at, r.txn_id as tid,
               private.name_score(coalesce(c.sender_name, p.display_name), r.payer_hint) as ns,
               row_number() over (
                 partition by c.id
                 order by (r.txn_id is not null and r.txn_id = c.provider_ref) desc,
                          private.name_score(coalesce(c.sender_name, p.display_name), r.payer_hint) desc,
                          r.received_at desc
               ) as rn
          from public.contributions c
          join public.profiles p on p.id = c.user_id
          join public.momo_receipts r on r.group_id = v_group and r.matched_contribution_id is null
         where c.event_id = p_event_id and c.provider = 'manual' and c.status = 'pending'
           and (
             (c.provider_ref is not null and r.txn_id = c.provider_ref)
             or (
               r.amount = c.amount
               and (c.provider_ref is null or r.txn_id is null)
               and r.received_at between c.created_at - interval '2 days' and c.created_at + interval '1 day'
             )
           )
      ) x
     where x.rn <= 3;
end;
$$;
revoke all on function public.claim_match_hints(uuid) from public, anon;
grant execute on function public.claim_match_hints(uuid) to authenticated;

-- collector_status gains the name-matching switch; the leader can flip it.
create or replace function public.collector_status(p_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  c record;
  v_count integer;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_manager(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  select mc.created_at, mc.last_seen_at, mc.auto_by_name into c from public.momo_collectors mc
   where mc.group_id = p_group_id and mc.revoked_at is null;
  select count(*) into v_count from public.momo_receipts r
   where r.group_id = p_group_id and r.received_at > now() - interval '30 days';
  return jsonb_build_object(
    'active', c.created_at is not null,
    'created_at', c.created_at,
    'last_seen_at', c.last_seen_at,
    'receipts_30d', v_count,
    'auto_by_name', coalesce(c.auto_by_name, true)
  );
end;
$$;

create or replace function public.set_auto_by_name(p_group_id uuid, p_on boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_manager(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  update public.momo_collectors set auto_by_name = coalesce(p_on, true)
   where group_id = p_group_id and revoked_at is null;
  if coalesce(p_on, true) then perform private.auto_match_group(p_group_id); end if;
end;
$$;
revoke all on function public.set_auto_by_name(uuid, boolean) from public, anon;
grant execute on function public.set_auto_by_name(uuid, boolean) to authenticated;

-- ===========================================================================
-- 3a. Pictures: private bucket "group-photos", path = <group>/<uploader>/<file>.<ext>
-- ===========================================================================
alter table public.events add column if not exists cover_path text;

create or replace function private.photo_path_group(p_name text)
returns uuid
language sql immutable
set search_path = ''
as $$
  select case
    when p_name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.(jpg|png|webp)$'
    then split_part(p_name, '/', 1)::uuid
  end;
$$;
create or replace function private.photo_path_valid(p_name text, p_group uuid)
returns boolean
language sql stable
set search_path = ''
as $$
  select private.photo_path_group(p_name) = p_group
     and split_part(p_name, '/', 2) = (select auth.uid())::text;
$$;
create or replace function private.photo_upload_allowed(p_name text)
returns boolean
language sql stable security definer
set search_path = ''
as $$
  select coalesce(private.photo_path_group(p_name) is not null
                  and private.is_group_member(private.photo_path_group(p_name))
                  and split_part(p_name, '/', 2) = (select auth.uid())::text, false);
$$;
revoke all on function private.photo_path_group(text), private.photo_path_valid(text, uuid), private.photo_upload_allowed(text) from public, anon;
grant execute on function private.photo_path_group(text), private.photo_path_valid(text, uuid), private.photo_upload_allowed(text) to authenticated, service_role;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('group-photos', 'group-photos', false, 3145728, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists squadvault_photos_select on storage.objects;
drop policy if exists squadvault_photos_insert on storage.objects;
drop policy if exists squadvault_photos_delete on storage.objects;
create policy squadvault_photos_select on storage.objects for select to authenticated
  using (bucket_id = 'group-photos' and private.is_group_member(private.photo_path_group(name)));
create policy squadvault_photos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'group-photos' and private.photo_upload_allowed(name));
create policy squadvault_photos_delete on storage.objects for delete to authenticated
  using (bucket_id = 'group-photos' and split_part(name, '/', 2) = (select auth.uid())::text);

create table if not exists public.group_photos (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.savings_groups (id) on delete cascade,
  event_id uuid references public.events (id) on delete set null,
  user_id uuid not null references auth.users (id) on delete cascade,
  path text not null,
  caption text check (caption is null or char_length(caption) <= 140),
  created_at timestamptz not null default now(),
  constraint group_photos_path_unique unique (path)
);
create index if not exists group_photos_group_idx on public.group_photos (group_id, created_at desc);

create table if not exists public.photo_likes (
  photo_id uuid not null references public.group_photos (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  group_id uuid not null references public.savings_groups (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (photo_id, user_id)
);

alter table public.group_photos enable row level security;
alter table public.photo_likes enable row level security;
drop policy if exists group_photos_select on public.group_photos;
drop policy if exists photo_likes_select on public.photo_likes;
create policy group_photos_select on public.group_photos for select to authenticated using (private.is_group_member(group_id));
create policy photo_likes_select on public.photo_likes for select to authenticated using (private.is_group_member(group_id));
revoke all on public.group_photos, public.photo_likes from anon, authenticated;
grant select on public.group_photos, public.photo_likes to authenticated;
grant select, insert, update, delete on public.group_photos, public.photo_likes to service_role;

create or replace function public.set_event_cover(p_event_id uuid, p_path text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_group uuid;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select e.group_id into v_group from public.events e where e.id = p_event_id;
  if v_group is null or not private.is_group_manager(v_group) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_path is not null then
    if private.photo_path_group(p_path) is distinct from v_group
       or not exists (select 1 from storage.objects o where o.bucket_id = 'group-photos' and o.name = p_path) then
      raise exception 'invalid_photo' using errcode = '22023';
    end if;
  end if;
  update public.events set cover_path = p_path where id = p_event_id;
end;
$$;

create or replace function public.add_group_photo(p_group_id uuid, p_path text, p_caption text default null, p_event_id uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_cap text := left(nullif(btrim(coalesce(p_caption, '')), ''), 140);
  v_id uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_member(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if private.photo_path_group(p_path) is distinct from p_group_id
     or split_part(p_path, '/', 2) <> v_uid::text
     or not exists (select 1 from storage.objects o where o.bucket_id = 'group-photos' and o.name = p_path) then
    raise exception 'invalid_photo' using errcode = '22023';
  end if;
  if p_event_id is not null and not exists (select 1 from public.events e where e.id = p_event_id and e.group_id = p_group_id) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if (select count(*) from public.group_photos g where g.user_id = v_uid and g.created_at > now() - interval '1 day') >= 30 then
    raise exception 'rate_limited' using errcode = '53400';
  end if;
  insert into public.group_photos (group_id, event_id, user_id, path, caption)
  values (p_group_id, p_event_id, v_uid, p_path, v_cap)
  returning id into v_id;
  return v_id;
end;
$$;

-- Returns the storage path so the browser can remove the file too.
create or replace function public.delete_group_photo(p_photo_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  g record;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into g from public.group_photos where id = p_photo_id;
  if g.id is null then raise exception 'not_found' using errcode = 'P0002'; end if;
  if g.user_id <> v_uid and not private.is_group_manager(g.group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  update public.events set cover_path = null where cover_path = g.path;
  delete from public.group_photos where id = p_photo_id;
  return g.path;
end;
$$;

create or replace function public.toggle_photo_like(p_photo_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_group uuid;
  v_liked boolean;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select g.group_id into v_group from public.group_photos g where g.id = p_photo_id;
  if v_group is null or not private.is_group_member(v_group) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  delete from public.photo_likes where photo_id = p_photo_id and user_id = v_uid;
  if found then v_liked := false;
  else
    insert into public.photo_likes (photo_id, user_id, group_id) values (p_photo_id, v_uid, v_group);
    v_liked := true;
  end if;
  return jsonb_build_object('liked', v_liked, 'count', (select count(*) from public.photo_likes where photo_id = p_photo_id));
end;
$$;

create or replace function public.list_group_photos(p_group_id uuid, p_limit integer default 60)
returns table (id uuid, user_id uuid, path text, caption text, event_id uuid, created_at timestamptz, like_count bigint, liked_by_me boolean)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_member(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return query
    select g.id, g.user_id, g.path, g.caption, g.event_id, g.created_at,
           (select count(*) from public.photo_likes l where l.photo_id = g.id),
           exists (select 1 from public.photo_likes l where l.photo_id = g.id and l.user_id = auth.uid())
      from public.group_photos g
     where g.group_id = p_group_id
     order by g.created_at desc
     limit least(greatest(coalesce(p_limit, 60), 1), 200);
end;
$$;

-- ===========================================================================
-- 3b. Group chat
-- ===========================================================================
create table if not exists public.group_messages (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.savings_groups (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  body text not null check (char_length(body) between 1 and 1000),
  created_at timestamptz not null default now()
);
create index if not exists group_messages_group_idx on public.group_messages (group_id, created_at desc);
alter table public.group_messages enable row level security;
drop policy if exists group_messages_select on public.group_messages;
create policy group_messages_select on public.group_messages for select to authenticated using (private.is_group_member(group_id));
revoke all on public.group_messages from anon, authenticated;
grant select on public.group_messages to authenticated;
grant select, insert, update, delete on public.group_messages to service_role;

create or replace function public.post_group_message(p_group_id uuid, p_body text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_body text := btrim(coalesce(p_body, ''));
  v_id uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_member(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if char_length(v_body) < 1 or char_length(v_body) > 1000 then raise exception 'invalid_message' using errcode = '22023'; end if;
  if (select count(*) from public.group_messages m where m.user_id = v_uid and m.created_at > now() - interval '1 minute') >= 20 then
    raise exception 'rate_limited' using errcode = '53400';
  end if;
  insert into public.group_messages (group_id, user_id, body) values (p_group_id, v_uid, v_body) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.delete_group_message(p_message_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  m record;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into m from public.group_messages where id = p_message_id;
  if m.id is null then return; end if;
  if m.user_id <> v_uid and not private.is_group_manager(m.group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  delete from public.group_messages where id = p_message_id;
end;
$$;

-- ===========================================================================
-- 3c. Games: poll + "guess the number" (closest guess wins). No direct table access at all.
-- ===========================================================================
create table if not exists public.group_games (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.savings_groups (id) on delete cascade,
  kind text not null check (kind in ('poll', 'guess')),
  title text not null check (char_length(title) between 3 and 120),
  options text[],
  status text not null default 'open' check (status in ('open', 'closed')),
  answer bigint,
  created_by uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  closed_at timestamptz
);
create index if not exists group_games_group_idx on public.group_games (group_id, created_at desc);

create table if not exists public.game_entries (
  game_id uuid not null references public.group_games (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  choice integer,
  guess bigint,
  created_at timestamptz not null default now(),
  primary key (game_id, user_id)
);
alter table public.group_games enable row level security;
alter table public.game_entries enable row level security;
revoke all on public.group_games, public.game_entries from anon, authenticated;
grant select, insert, update, delete on public.group_games, public.game_entries to service_role;

create or replace function public.create_game(p_group_id uuid, p_kind text, p_title text, p_options text[] default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_title text := btrim(coalesce(p_title, ''));
  v_opts text[];
  v_id uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_member(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_kind not in ('poll', 'guess') then raise exception 'invalid_game' using errcode = '22023'; end if;
  if char_length(v_title) < 3 or char_length(v_title) > 120 then raise exception 'invalid_game' using errcode = '22023'; end if;
  if p_kind = 'poll' then
    select array_agg(left(btrim(o), 60)) into v_opts from unnest(coalesce(p_options, '{}')) o where btrim(o) <> '';
    if coalesce(array_length(v_opts, 1), 0) < 2 or array_length(v_opts, 1) > 6 then
      raise exception 'invalid_game' using errcode = '22023';
    end if;
  end if;
  if (select count(*) from public.group_games g where g.group_id = p_group_id and g.created_by = v_uid and g.status = 'open') >= 5 then
    raise exception 'too_many_games' using errcode = '53400';
  end if;
  insert into public.group_games (group_id, kind, title, options, created_by)
  values (p_group_id, p_kind, v_title, v_opts, v_uid) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.play_game(p_game_id uuid, p_choice integer default null, p_guess bigint default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  g record;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into g from public.group_games where id = p_game_id for update;
  if g.id is null or not private.is_group_member(g.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if g.status <> 'open' then raise exception 'game_closed' using errcode = '22023'; end if;
  if g.kind = 'poll' then
    if p_choice is null or p_choice < 1 or p_choice > array_length(g.options, 1) then raise exception 'invalid_game' using errcode = '22023'; end if;
    insert into public.game_entries (game_id, user_id, choice) values (p_game_id, v_uid, p_choice)
    on conflict (game_id, user_id) do update set choice = excluded.choice, created_at = now();
  else
    if p_guess is null or p_guess < 0 or p_guess > 1000000000000 then raise exception 'invalid_game' using errcode = '22023'; end if;
    insert into public.game_entries (game_id, user_id, guess) values (p_game_id, v_uid, p_guess)
    on conflict (game_id, user_id) do update set guess = excluded.guess, created_at = now();
  end if;
end;
$$;

create or replace function public.close_game(p_game_id uuid, p_answer bigint default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  g record;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into g from public.group_games where id = p_game_id for update;
  if g.id is null then raise exception 'not_found' using errcode = 'P0002'; end if;
  if g.created_by <> v_uid and not private.is_group_manager(g.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if g.status <> 'open' then return; end if;
  if g.kind = 'guess' and (p_answer is null or p_answer < 0 or p_answer > 1000000000000) then
    raise exception 'invalid_game' using errcode = '22023';
  end if;
  update public.group_games set status = 'closed', closed_at = now(), answer = case when g.kind = 'guess' then p_answer end
   where id = p_game_id;
end;
$$;

create or replace function public.delete_game(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  g record;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into g from public.group_games where id = p_game_id;
  if g.id is null then return; end if;
  if g.created_by <> v_uid and not private.is_group_manager(g.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  delete from public.group_games where id = p_game_id;
end;
$$;

-- Everything the screen needs, in one call. Other people's guesses stay hidden until the game is closed.
create or replace function public.list_games(p_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_member(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(x.j order by x.created_at desc)
      from (
        select g.created_at,
          jsonb_build_object(
            'id', g.id, 'kind', g.kind, 'title', g.title, 'options', to_jsonb(g.options), 'status', g.status,
            'answer', g.answer, 'created_by', g.created_by, 'created_at', g.created_at,
            'entries', (select count(*) from public.game_entries e where e.game_id = g.id),
            'my_choice', (select e.choice from public.game_entries e where e.game_id = g.id and e.user_id = v_uid),
            'my_guess', (select e.guess from public.game_entries e where e.game_id = g.id and e.user_id = v_uid),
            'counts', case when g.kind = 'poll' then
                (select jsonb_agg(coalesce(c.n, 0) order by i.i)
                   from generate_series(1, array_length(g.options, 1)) as i(i)
                   left join (select e.choice, count(*) as n from public.game_entries e where e.game_id = g.id group by e.choice) c on c.choice = i.i)
              end,
            'top', case when g.kind = 'guess' and g.status = 'closed' then
                (select jsonb_agg(jsonb_build_object('user_id', t.user_id, 'guess', t.guess, 'diff', abs(t.guess - g.answer)) order by abs(t.guess - g.answer), t.created_at)
                   from (select e.user_id, e.guess, e.created_at from public.game_entries e
                          where e.game_id = g.id and e.guess is not null
                          order by abs(e.guess - g.answer), e.created_at limit 10) t)
              end
          ) as j
          from public.group_games g
         where g.group_id = p_group_id
         order by g.created_at desc
         limit 30
      ) x
  ), '[]'::jsonb);
end;
$$;

-- ===========================================================================
-- Grants
-- ===========================================================================
revoke all on function public.set_event_cover(uuid, text), public.add_group_photo(uuid, text, text, uuid),
  public.delete_group_photo(uuid), public.toggle_photo_like(uuid), public.list_group_photos(uuid, integer),
  public.post_group_message(uuid, text), public.delete_group_message(uuid),
  public.create_game(uuid, text, text, text[]), public.play_game(uuid, integer, bigint),
  public.close_game(uuid, bigint), public.delete_game(uuid), public.list_games(uuid),
  public.collector_status(uuid), public.create_invitation_code(uuid, integer, integer) from public, anon;
grant execute on function public.set_event_cover(uuid, text), public.add_group_photo(uuid, text, text, uuid),
  public.delete_group_photo(uuid), public.toggle_photo_like(uuid), public.list_group_photos(uuid, integer),
  public.post_group_message(uuid, text), public.delete_group_message(uuid),
  public.create_game(uuid, text, text, text[]), public.play_game(uuid, integer, bigint),
  public.close_game(uuid, bigint), public.delete_game(uuid), public.list_games(uuid),
  public.collector_status(uuid), public.create_invitation_code(uuid, integer, integer) to authenticated;

commit;

-- ===== 010_plans.sql =====
-- 010_plans.sql
-- Plans (Free / Plus / Pro) per group, enforced in the database, plus upgrade requests that the platform
-- owner approves by hand after receiving the MoMo payment. Members always stay free.
--
-- * Limits are only enforced when something NEW is added (a member, an active event, a photo, a collector token).
--   Nothing that already exists is ever deleted or locked.
-- * Groups that already exist get Plus free for 60 days (one time), so nobody is surprised.
-- * To become the owner (able to approve requests), run once in the SQL Editor:
--     insert into public.platform_admins (user_id) select id from auth.users where email = 'YOUR@EMAIL';
--
-- Safe to re-run. Prerequisites: 001-009.

begin;

create table if not exists public.plans (
  code text primary key check (code in ('free', 'plus', 'pro')),
  name text not null,
  sort integer not null,
  max_members integer not null,
  max_events integer,               -- null = unlimited active events
  max_photos integer not null,
  auto_check boolean not null default false,
  price_month bigint not null default 0,
  price_year bigint not null default 0
);
insert into public.plans (code, name, sort, max_members, max_events, max_photos, auto_check, price_month, price_year) values
  ('free', 'Free', 1, 15, 2, 30, false, 0, 0),
  ('plus', 'Plus', 2, 150, null, 500, true, 2000, 20000),
  ('pro',  'Pro',  3, 1000, null, 5000, true, 10000, 100000)
on conflict (code) do nothing;   -- prices and limits you edit later are kept
alter table public.plans enable row level security;
drop policy if exists plans_select on public.plans;
create policy plans_select on public.plans for select to authenticated using (true);
revoke all on public.plans from anon, authenticated;
grant select on public.plans to authenticated;
grant select, insert, update, delete on public.plans to service_role;

do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'savings_groups' and column_name = 'plan') then
    alter table public.savings_groups add column plan text not null default 'free';
    alter table public.savings_groups add column plan_until timestamptz;
    -- one-time welcome gift for groups that already exist
    update public.savings_groups set plan = 'plus', plan_until = now() + interval '60 days';
  end if;
end $$;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'savings_groups_plan_check') then
    alter table public.savings_groups add constraint savings_groups_plan_check check (plan in ('free', 'plus', 'pro'));
  end if;
end $$;

create table if not exists public.platform_admins (user_id uuid primary key references auth.users (id) on delete cascade);
alter table public.platform_admins enable row level security;
revoke all on public.platform_admins from anon, authenticated;
grant select, insert, update, delete on public.platform_admins to service_role;

create table if not exists public.plan_requests (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.savings_groups (id) on delete cascade,
  requested_by uuid not null references auth.users (id) on delete cascade,
  plan text not null check (plan in ('plus', 'pro')),
  period text not null check (period in ('month', 'year')),
  amount bigint not null check (amount > 0),
  txn_ref text not null check (txn_ref ~ '^[A-Z0-9]{6,20}$'),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  note text,
  created_at timestamptz not null default now(),
  reviewed_by uuid references auth.users (id),
  reviewed_at timestamptz
);
create unique index if not exists plan_requests_txn_uidx on public.plan_requests (txn_ref);
create unique index if not exists plan_requests_one_pending on public.plan_requests (group_id) where status = 'pending';
alter table public.plan_requests enable row level security;
revoke all on public.plan_requests from anon, authenticated;
grant select, insert, update, delete on public.plan_requests to service_role;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function private.group_plan_code(p_group uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select case when g.plan <> 'free' and g.plan_until > now() then g.plan else 'free' end
                     from public.savings_groups g where g.id = p_group), 'free');
$$;

create or replace function private.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.platform_admins a where a.user_id = (select auth.uid()));
$$;
revoke all on function private.group_plan_code(uuid), private.is_platform_admin() from public, anon;
grant execute on function private.group_plan_code(uuid), private.is_platform_admin() to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Enforcement (triggers, so every path that adds something is covered, including old functions)
-- ---------------------------------------------------------------------------
create or replace function private.enforce_member_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  l public.plans;
begin
  select * into l from public.plans where code = private.group_plan_code(new.group_id);
  if (select count(*) from public.group_members m where m.group_id = new.group_id) >= l.max_members then
    raise exception 'plan_limit_members' using errcode = '53400';
  end if;
  return new;
end;
$$;
drop trigger if exists squadvault_member_limit on public.group_members;
create trigger squadvault_member_limit before insert on public.group_members
  for each row execute function private.enforce_member_limit();

create or replace function private.enforce_event_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  l public.plans;
begin
  if new.status is distinct from 'active' then return new; end if;
  if tg_op = 'UPDATE' and old.status = 'active' then return new; end if;
  select * into l from public.plans where code = private.group_plan_code(new.group_id);
  if l.max_events is not null
     and (select count(*) from public.events e where e.group_id = new.group_id and e.status = 'active') >= l.max_events then
    raise exception 'plan_limit_events' using errcode = '53400';
  end if;
  return new;
end;
$$;
drop trigger if exists squadvault_event_limit on public.events;
create trigger squadvault_event_limit before insert or update of status on public.events
  for each row execute function private.enforce_event_limit();

create or replace function private.enforce_photo_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  l public.plans;
begin
  select * into l from public.plans where code = private.group_plan_code(new.group_id);
  if (select count(*) from public.group_photos p where p.group_id = new.group_id) >= l.max_photos then
    raise exception 'plan_limit_photos' using errcode = '53400';
  end if;
  return new;
end;
$$;
drop trigger if exists squadvault_photo_limit on public.group_photos;
create trigger squadvault_photo_limit before insert on public.group_photos
  for each row execute function private.enforce_photo_limit();

create or replace function private.enforce_autocheck_feature()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not coalesce((select p.auto_check from public.plans p where p.code = private.group_plan_code(new.group_id)), false) then
    raise exception 'plan_feature_autocheck' using errcode = '53400';
  end if;
  return new;
end;
$$;
drop trigger if exists squadvault_autocheck_feature on public.momo_collectors;
create trigger squadvault_autocheck_feature before insert on public.momo_collectors
  for each row execute function private.enforce_autocheck_feature();

-- Automatic matching only runs for groups whose plan includes it (same function as 009 plus that check).
create or replace function private.auto_match_group(p_group uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  r record;
  v_claim uuid;
  v_by_name boolean;
  v_n integer := 0;
  v_cands integer;
  v_back integer;
begin
  -- Automatic checking is a paid feature: when the group's plan doesn't include it, nothing is auto-confirmed.
  if not coalesce((select p.auto_check from public.plans p where p.code = private.group_plan_code(p_group)), false) then
    return 0;
  end if;
  select coalesce((select mc.auto_by_name from public.momo_collectors mc
                    where mc.group_id = p_group and mc.revoked_at is null), false) into v_by_name;

  for r in
    select * from public.momo_receipts
     where group_id = p_group and matched_contribution_id is null and received_at > now() - interval '3 days'
     order by received_at
     limit 200
       for update skip locked
  loop
    v_claim := null;

    if r.txn_id is not null then
      select c.id into v_claim
        from public.contributions c join public.events e on e.id = c.event_id
       where e.group_id = p_group and e.status = 'active'
         and c.provider = 'manual' and c.status = 'pending'
         and c.provider_ref = r.txn_id and c.amount = r.amount
       order by c.created_at limit 1
         for update of c skip locked;
      if v_claim is not null then
        update public.contributions
           set status = 'paid', paid_at = now(), failure_reason = null, reviewed_at = now(),
               note = 'Auto-verified from MoMo SMS', updated_at = now()
         where id = v_claim;
      end if;
    end if;

    if v_claim is null and v_by_name and r.payer_hint is not null then
      -- claims that could belong to this message
      select count(*) into v_cands
        from public.contributions c
        join public.events e on e.id = c.event_id
        join public.profiles p on p.id = c.user_id
       where e.group_id = p_group and e.status = 'active'
         and c.provider = 'manual' and c.status = 'pending' and c.provider_ref is null
         and c.amount = r.amount
         and r.received_at between c.created_at - interval '2 days' and c.created_at + interval '1 day'
         and private.name_strong(coalesce(c.sender_name, p.display_name), r.payer_hint);
      if v_cands = 1 then
        select c.id into v_claim
          from public.contributions c
          join public.events e on e.id = c.event_id
          join public.profiles p on p.id = c.user_id
         where e.group_id = p_group and e.status = 'active'
           and c.provider = 'manual' and c.status = 'pending' and c.provider_ref is null
           and c.amount = r.amount
           and r.received_at between c.created_at - interval '2 days' and c.created_at + interval '1 day'
           and private.name_strong(coalesce(c.sender_name, p.display_name), r.payer_hint)
           for update of c skip locked;
        if v_claim is not null then
          -- from the claim's side: it must have exactly one candidate message too
          select count(*) into v_back
            from public.momo_receipts r2, public.contributions c, public.profiles p
           where c.id = v_claim and p.id = c.user_id
             and r2.group_id = p_group and r2.matched_contribution_id is null
             and r2.amount = c.amount
             and r2.received_at between c.created_at - interval '2 days' and c.created_at + interval '1 day'
             and r2.payer_hint is not null
             and private.name_strong(coalesce(c.sender_name, p.display_name), r2.payer_hint);
          if v_back = 1 then
            update public.contributions
               set status = 'paid', paid_at = now(), failure_reason = null, reviewed_at = now(),
                   note = 'Auto-verified from MoMo SMS (sender name and amount)', updated_at = now()
             where id = v_claim;
          else
            v_claim := null;
          end if;
        end if;
      end if;
    end if;

    if v_claim is not null then
      update public.momo_receipts set matched_contribution_id = v_claim where id = r.id;
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end;
$$;
revoke all on function private.auto_match_group(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Group admins: see the plan and ask for an upgrade
-- ---------------------------------------------------------------------------
create or replace function public.plan_overview(p_group_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  g record;
  v_code text;
  l public.plans;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_manager(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  select * into g from public.savings_groups where id = p_group_id;
  v_code := private.group_plan_code(p_group_id);
  select * into l from public.plans where code = v_code;
  return jsonb_build_object(
    'plan', v_code,
    'plan_name', l.name,
    'booked_plan', g.plan,
    'until', case when v_code <> 'free' then g.plan_until end,
    'expired', g.plan <> 'free' and g.plan_until is not null and g.plan_until <= now(),
    'limits', jsonb_build_object('members', l.max_members, 'events', l.max_events, 'photos', l.max_photos, 'auto_check', l.auto_check),
    'usage', jsonb_build_object(
      'members', (select count(*) from public.group_members m where m.group_id = p_group_id),
      'events', (select count(*) from public.events e where e.group_id = p_group_id and e.status = 'active'),
      'photos', (select count(*) from public.group_photos p where p.group_id = p_group_id)),
    'is_admin', private.group_role(p_group_id) = 'admin',
    'pending', (select jsonb_build_object('id', r.id, 'plan', r.plan, 'period', r.period, 'amount', r.amount, 'txn_ref', r.txn_ref, 'created_at', r.created_at)
                  from public.plan_requests r where r.group_id = p_group_id and r.status = 'pending'),
    'last_rejected', (select jsonb_build_object('note', r.note, 'reviewed_at', r.reviewed_at)
                        from public.plan_requests r where r.group_id = p_group_id and r.status = 'rejected'
                        order by r.reviewed_at desc limit 1),
    'plans', (select jsonb_agg(jsonb_build_object('code', p.code, 'name', p.name, 'members', p.max_members, 'events', p.max_events,
                'photos', p.max_photos, 'auto_check', p.auto_check, 'price_month', p.price_month, 'price_year', p.price_year) order by p.sort)
                from public.plans p)
  );
end;
$$;

create or replace function public.request_plan_upgrade(p_group_id uuid, p_plan text, p_period text, p_txn_ref text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_txn text := upper(btrim(coalesce(p_txn_ref, '')));
  v_amount bigint;
  v_id uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or private.group_role(p_group_id) is distinct from 'admin' then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_plan not in ('plus', 'pro') or p_period not in ('month', 'year') then raise exception 'invalid_plan' using errcode = '22023'; end if;
  if v_txn !~ '^[A-Z0-9]{6,20}$' then raise exception 'invalid_reference' using errcode = '22023'; end if;
  select case when p_period = 'year' then p.price_year else p.price_month end into v_amount from public.plans p where p.code = p_plan;
  if v_amount is null or v_amount <= 0 then raise exception 'invalid_plan' using errcode = '22023'; end if;
  if exists (select 1 from public.plan_requests r where r.group_id = p_group_id and r.status = 'pending') then
    raise exception 'request_pending' using errcode = '22023';
  end if;
  if (select count(*) from public.plan_requests r where r.group_id = p_group_id and r.created_at > now() - interval '1 day') >= 5 then
    raise exception 'rate_limited' using errcode = '53400';
  end if;
  begin
    insert into public.plan_requests (group_id, requested_by, plan, period, amount, txn_ref)
    values (p_group_id, v_uid, p_plan, p_period, v_amount, v_txn) returning id into v_id;
  exception when unique_violation then
    raise exception 'duplicate_reference' using errcode = '23505';
  end;
  return v_id;
end;
$$;

create or replace function public.cancel_plan_request(p_group_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or private.group_role(p_group_id) is distinct from 'admin' then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  delete from public.plan_requests where group_id = p_group_id and status = 'pending';
end;
$$;

-- ---------------------------------------------------------------------------
-- Owner tools (platform_admins only)
-- ---------------------------------------------------------------------------
create or replace function public.owner_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then return jsonb_build_object('is_owner', false); end if;
  if not private.is_platform_admin() then return jsonb_build_object('is_owner', false); end if;
  return jsonb_build_object('is_owner', true, 'pending', (select count(*) from public.plan_requests where status = 'pending'));
end;
$$;

create or replace function public.owner_list_plan_requests()
returns table (id uuid, group_id uuid, group_name text, plan text, period text, amount bigint, txn_ref text, status text,
               created_at timestamptz, requester_name text, requester_email text, reviewed_at timestamptz, note text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not private.is_platform_admin() then raise exception 'not_allowed' using errcode = '42501'; end if;
  return query
    select r.id, r.group_id, g.name, r.plan, r.period, r.amount, r.txn_ref, r.status, r.created_at,
           p.display_name, u.email::text, r.reviewed_at, r.note
      from public.plan_requests r
      join public.savings_groups g on g.id = r.group_id
      left join public.profiles p on p.id = r.requested_by
      left join auth.users u on u.id = r.requested_by
     order by (r.status = 'pending') desc, r.created_at desc
     limit 100;
end;
$$;

create or replace function public.owner_decide_plan_request(p_request_id uuid, p_approve boolean, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.plan_requests;
  g public.savings_groups;
  v_start timestamptz;
  v_note text := left(nullif(btrim(coalesce(p_note, '')), ''), 200);
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not private.is_platform_admin() then raise exception 'not_allowed' using errcode = '42501'; end if;
  select * into r from public.plan_requests where id = p_request_id for update;
  if r.id is null then raise exception 'not_found' using errcode = 'P0002'; end if;
  if r.status <> 'pending' then raise exception 'invalid_transition' using errcode = '22023'; end if;
  if coalesce(p_approve, false) then
    select * into g from public.savings_groups where id = r.group_id for update;
    -- renewing the same plan extends it; switching plan starts now
    v_start := case when g.plan = r.plan and g.plan_until > now() then g.plan_until else now() end;
    update public.savings_groups
       set plan = r.plan,
           plan_until = v_start + case when r.period = 'year' then interval '1 year' else interval '1 month' end
     where id = r.group_id;
    update public.plan_requests set status = 'approved', reviewed_by = auth.uid(), reviewed_at = now(), note = v_note where id = r.id;
  else
    update public.plan_requests set status = 'rejected', reviewed_by = auth.uid(), reviewed_at = now(), note = coalesce(v_note, 'Payment not found') where id = r.id;
  end if;
end;
$$;

create or replace function public.owner_set_plan(p_group_id uuid, p_plan text, p_days integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not private.is_platform_admin() then raise exception 'not_allowed' using errcode = '42501'; end if;
  if p_plan not in ('free', 'plus', 'pro') or p_days is null or p_days < 0 or p_days > 3660 then raise exception 'invalid_plan' using errcode = '22023'; end if;
  update public.savings_groups set plan = p_plan, plan_until = case when p_plan = 'free' then null else now() + make_interval(days => p_days) end where id = p_group_id;
end;
$$;

revoke all on function public.plan_overview(uuid), public.request_plan_upgrade(uuid, text, text, text), public.cancel_plan_request(uuid),
  public.owner_summary(), public.owner_list_plan_requests(), public.owner_decide_plan_request(uuid, boolean, text),
  public.owner_set_plan(uuid, text, integer) from public, anon;
grant execute on function public.plan_overview(uuid), public.request_plan_upgrade(uuid, text, text, text), public.cancel_plan_request(uuid),
  public.owner_summary(), public.owner_list_plan_requests(), public.owner_decide_plan_request(uuid, boolean, text),
  public.owner_set_plan(uuid, text, integer) to authenticated;

commit;


-- ===== 011_email_verify.sql =====
-- 011_email_verify.sql
-- Deferred email confirmation. People can sign up instantly (Supabase "Confirm email" switched OFF), and are asked
-- to prove their email only when they want to CHAT or SHARE PHOTOS.
--
-- How the proof works: the app sends a one-time sign-in link ("magic link") to the person's address. Opening it gives
-- a session whose token says it came from an email one-time code (the "amr" claim). confirm_my_email() accepts that
-- and stamps profiles.email_verified_at. Nobody can fake the claim without receiving the email.
--
-- Everyone who already has an account when this runs counts as verified (one time), so nobody is locked out.
-- Safe to re-run. Prerequisites: 001-010.

begin;

do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles' and column_name = 'email_verified_at') then
    alter table public.profiles add column email_verified_at timestamptz;
    update public.profiles set email_verified_at = now();
  end if;
end $$;

create or replace function public.confirm_my_email()
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_at timestamptz;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if not exists (
    select 1
      from jsonb_array_elements(case when jsonb_typeof(auth.jwt() -> 'amr') = 'array' then auth.jwt() -> 'amr' else '[]'::jsonb end) a
     where a ->> 'method' in ('otp', 'magiclink', 'email')
       and coalesce((a ->> 'timestamp')::bigint, 0) > extract(epoch from now())::bigint - 3600
  ) then
    raise exception 'email_not_proven' using errcode = '42501';
  end if;
  update public.profiles set email_verified_at = coalesce(email_verified_at, now()) where id = v_uid
  returning email_verified_at into v_at;
  return v_at;
end;
$$;
revoke all on function public.confirm_my_email() from public, anon;
grant execute on function public.confirm_my_email() to authenticated;

-- Chat and photos need a confirmed email (reading is always allowed).
create or replace function private.require_verified_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.profiles p where p.id = new.user_id and p.email_verified_at is not null) then
    raise exception 'email_unverified' using errcode = '42501';
  end if;
  return new;
end;
$$;
drop trigger if exists squadvault_verified_chat on public.group_messages;
create trigger squadvault_verified_chat before insert on public.group_messages
  for each row execute function private.require_verified_email();
drop trigger if exists squadvault_verified_photos on public.group_photos;
create trigger squadvault_verified_photos before insert on public.group_photos
  for each row execute function private.require_verified_email();

commit;

-- ===== 012_multiplayer.sql =====
-- 012_multiplayer.sql
-- Live multiplayer games inside a squad: Tic-Tac-Toe, Connect 4, Rock-Paper-Scissors (first to 2) and a Trivia Race
-- where everyone answers the same question at the same time (faster correct answers score more).
--
-- Rules of the house: the SERVER is the referee. Browsers only ask to join, start or make a move; every move is
-- checked (is it your turn, is the cell free, is the time up) inside SECURITY DEFINER functions. Hidden information
-- (a Rock-Paper-Scissors choice before both players have chosen, trivia answers before the reveal) lives in a column
-- nobody can read directly. No money is involved: the app keeps wins and a squad leaderboard, nothing else.
--
-- Trivia has no background worker: the room moves on whenever somebody asks for its state (the screens do that every
-- second or two), which is enough for a live game and needs no extra infrastructure.
-- Safe to re-run. Prerequisites: 001-011.

begin;

-- ---------------------------------------------------------------------------
-- Tables (no direct access for browsers)
-- ---------------------------------------------------------------------------
create table if not exists public.trivia_questions (
  id serial primary key,
  topic text not null,
  question text not null unique,
  options text[] not null check (array_length(options, 1) = 4),
  answer smallint not null check (answer between 0 and 3)
);

create table if not exists public.game_rooms (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.savings_groups (id) on delete cascade,
  kind text not null check (kind in ('tictactoe', 'connect4', 'rps', 'trivia')),
  status text not null default 'lobby' check (status in ('lobby', 'playing', 'finished')),
  host_id uuid not null references auth.users (id) on delete cascade,
  state jsonb not null default '{}'::jsonb,
  secret jsonb not null default '{}'::jsonb,
  winner_id uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists game_rooms_group_idx on public.game_rooms (group_id, created_at desc);

create table if not exists public.game_room_players (
  room_id uuid not null references public.game_rooms (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  seat smallint not null check (seat >= 0),
  score integer not null default 0,
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id),
  unique (room_id, seat)
);
create index if not exists game_room_players_user_idx on public.game_room_players (user_id);

alter table public.trivia_questions enable row level security;
alter table public.game_rooms enable row level security;
alter table public.game_room_players enable row level security;
revoke all on public.trivia_questions, public.game_rooms, public.game_room_players from anon, authenticated;
grant select, insert, update, delete on public.trivia_questions, public.game_rooms, public.game_room_players to service_role;
revoke all on sequence public.trivia_questions_id_seq from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Question bank (Rwanda, Africa, general knowledge, money sense)
-- ---------------------------------------------------------------------------
insert into public.trivia_questions (topic, question, options, answer) values
 ('Rwanda', 'What is the capital city of Rwanda?', array['Huye', 'Musanze', 'Kigali', 'Rubavu'], 2),
 ('Rwanda', 'Which is the largest lake inside Rwanda''s borders?', array['Lake Kivu', 'Lake Muhazi', 'Lake Ruhondo', 'Lake Burera'], 0),
 ('Rwanda', 'Which animals do visitors trek to see in Volcanoes National Park?', array['Lions', 'Mountain gorillas', 'Elephants', 'Giraffes'], 1),
 ('Rwanda', 'What is the currency of Rwanda?', array['Rwandan franc', 'Rwandan shilling', 'Rwandan dollar', 'Rwandan birr'], 0),
 ('Rwanda', 'Umuganda, the national community work day, happens on which day?', array['Every Friday', 'The first Monday of the month', 'Every Sunday', 'The last Saturday of the month'], 3),
 ('Rwanda', 'On which date is Rwanda''s Independence Day celebrated?', array['4 July', '1 July', '1 January', '1 August'], 1),
 ('Rwanda', 'Which is the highest volcano in Rwanda?', array['Bisoke', 'Sabyinyo', 'Karisimbi', 'Muhabura'], 2),
 ('Rwanda', 'In which part of Rwanda is Akagera National Park?', array['East', 'West', 'North', 'South-west'], 0),
 ('Rwanda', 'Which national park has a canopy walkway and is home to chimpanzees?', array['Akagera', 'Nyungwe', 'Volcanoes', 'Gishwati'], 1),
 ('Rwanda', 'What is an "ikimina"?', array['A traditional dance', 'A cooking pot', 'A savings group', 'A school uniform'], 2),
 ('Rwanda', 'Which of these is a traditional Rwandan dance?', array['Salsa', 'Intore', 'Flamenco', 'Tango'], 1),
 ('Rwanda', 'What is an "agaseke"?', array['A woven basket', 'A drum', 'A river', 'A type of bean'], 0),
 ('Rwanda', 'Umuganura is a celebration of what?', array['A wedding', 'Independence', 'The harvest', 'A new school year'], 2),
 ('Rwanda', 'Which country does NOT share a border with Rwanda?', array['Uganda', 'Tanzania', 'Burundi', 'Kenya'], 3),
 ('Rwanda', 'Which of these is NOT an official language of Rwanda?', array['Kinyarwanda', 'English', 'Spanish', 'French'], 2),
 ('Rwanda', 'What is the nickname of Rwanda''s national football team?', array['Amavubi', 'Harambee Stars', 'Cranes', 'Taifa Stars'], 0),
 ('Rwanda', 'Inyambo, famous in Rwandan culture, are cattle known for their...', array['Short tails', 'Spotted coats', 'Long horns', 'No horns'], 2),
 ('Africa', 'Which city is the capital of Kenya?', array['Mombasa', 'Nairobi', 'Kisumu', 'Nakuru'], 1),
 ('Africa', 'Which city is the capital of Uganda?', array['Kampala', 'Entebbe', 'Jinja', 'Gulu'], 0),
 ('Africa', 'Which city is the official capital of Tanzania?', array['Dar es Salaam', 'Arusha', 'Dodoma', 'Mwanza'], 2),
 ('Africa', 'What is the longest river in Africa?', array['Congo', 'Niger', 'Zambezi', 'Nile'], 3),
 ('Africa', 'What is the highest mountain in Africa?', array['Mount Kenya', 'Kilimanjaro', 'Karisimbi', 'Mount Stanley'], 1),
 ('Africa', 'What is the largest lake in Africa?', array['Lake Victoria', 'Lake Tanganyika', 'Lake Malawi', 'Lake Kivu'], 0),
 ('General', 'Which is the largest planet in our solar system?', array['Saturn', 'Earth', 'Jupiter', 'Neptune'], 2),
 ('General', 'What is the chemical formula of water?', array['CO2', 'H2O', 'O2', 'NaCl'], 1),
 ('General', 'What is 12 x 12?', array['124', '122', '134', '144'], 3),
 ('General', 'How many bones does an adult human body have?', array['206', '186', '256', '306'], 0),
 ('General', 'Which is the fastest land animal?', array['Lion', 'Horse', 'Cheetah', 'Antelope'], 2),
 ('General', 'Which is the largest ocean on Earth?', array['Atlantic', 'Indian', 'Arctic', 'Pacific'], 3),
 ('General', 'How many continents are there?', array['5', '6', '7', '8'], 2),
 ('General', 'Which country won the 2022 FIFA World Cup?', array['Argentina', 'France', 'Brazil', 'Croatia'], 0),
 ('General', 'Which gas do plants take in from the air?', array['Oxygen', 'Carbon dioxide', 'Nitrogen', 'Hydrogen'], 1),
 ('General', 'What is the square root of 81?', array['7', '8', '9', '11'], 2),
 ('General', 'What is the smallest prime number?', array['0', '1', '3', '2'], 3),
 ('General', 'Which organ pumps blood around the body?', array['Heart', 'Liver', 'Lungs', 'Kidney'], 0),
 ('General', 'How many days are there in a leap year?', array['365', '366', '364', '367'], 1),
 ('General', 'What is the hardest natural material?', array['Gold', 'Iron', 'Diamond', 'Granite'], 2),
 ('General', 'The Sun is a...', array['Planet', 'Moon', 'Comet', 'Star'], 3),
 ('Money sense', 'You save 2,000 RWF every week. How much do you have after 10 weeks?', array['20,000 RWF', '12,000 RWF', '22,000 RWF', '2,000 RWF'], 0),
 ('Money sense', 'What is 10% of 50,000 RWF?', array['500 RWF', '50 RWF', '5,000 RWF', '10,000 RWF'], 2),
 ('Money sense', '5 members each put in 3,000 RWF. What is the total?', array['8,000 RWF', '15,000 RWF', '12,000 RWF', '18,000 RWF'], 1),
 ('Money sense', 'A goal costs 120,000 RWF and 12 people share it equally. How much does each person pay?', array['1,000 RWF', '12,000 RWF', '20,000 RWF', '10,000 RWF'], 3),
 ('Money sense', 'Which of these is a "want" and not a "need"?', array['A new game console', 'Clean water', 'School fees', 'Food'], 0),
 ('Money sense', 'What is a budget?', array['A kind of loan', 'A plan for how you will spend and save', 'A bank account', 'A tax'], 1)
on conflict (question) do nothing;

-- ---------------------------------------------------------------------------
-- Private helpers
-- ---------------------------------------------------------------------------
create or replace function private.room_max_players(p_kind text)
returns integer language sql immutable set search_path = '' as $$
  select case p_kind when 'trivia' then 12 else 2 end
$$;

-- the three cells that make a line, or null
create or replace function private.ttt_line(p_board text, p_mark text)
returns integer[] language plpgsql immutable set search_path = '' as $$
declare
  v_lines integer[] := array[0,1,2, 3,4,5, 6,7,8, 0,3,6, 1,4,7, 2,5,8, 0,4,8, 2,4,6];
  i integer;
begin
  for i in 0..7 loop
    if substr(p_board, v_lines[i*3+1] + 1, 1) = p_mark
       and substr(p_board, v_lines[i*3+2] + 1, 1) = p_mark
       and substr(p_board, v_lines[i*3+3] + 1, 1) = p_mark then
      return array[v_lines[i*3+1], v_lines[i*3+2], v_lines[i*3+3]];
    end if;
  end loop;
  return null;
end;
$$;

-- the four cells that make a line on a 6 rows x 7 columns board (row 0 is the top), or null
create or replace function private.c4_line(p_board text, p_mark text)
returns integer[] language plpgsql immutable set search_path = '' as $$
declare
  v_dr integer[] := array[0, 1, 1, 1];
  v_dc integer[] := array[1, 0, 1, -1];
  r integer; c integer; d integer; k integer; rr integer; cc integer; v_ok boolean;
begin
  for r in 0..5 loop
    for c in 0..6 loop
      if substr(p_board, r*7 + c + 1, 1) = p_mark then
        for d in 1..4 loop
          v_ok := true;
          for k in 1..3 loop
            rr := r + v_dr[d]*k; cc := c + v_dc[d]*k;
            if rr < 0 or rr > 5 or cc < 0 or cc > 6 or substr(p_board, rr*7 + cc + 1, 1) <> p_mark then v_ok := false; exit; end if;
          end loop;
          if v_ok then
            return array[r*7 + c, (r + v_dr[d])*7 + c + v_dc[d], (r + 2*v_dr[d])*7 + c + 2*v_dc[d], (r + 3*v_dr[d])*7 + c + 3*v_dc[d]];
          end if;
        end loop;
      end if;
    end loop;
  end loop;
  return null;
end;
$$;

create or replace function private.room_finish(p_room uuid, p_winner uuid, p_state jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.game_rooms
     set status = 'finished', winner_id = p_winner, state = p_state, finished_at = now(), updated_at = now()
   where id = p_room;
end;
$$;

-- Opens trivia question number p_idx (0-based). Stores who may answer and a fifteen second clock.
create or replace function private.trivia_open(p_room uuid, p_idx integer)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.game_rooms%rowtype;
  q public.trivia_questions%rowtype;
begin
  select * into r from public.game_rooms where id = p_room;
  select * into q from public.trivia_questions where id = (r.secret -> 'ids' ->> p_idx)::integer;
  update public.game_rooms
     set state = jsonb_build_object(
           'q', p_idx, 'total', jsonb_array_length(r.secret -> 'ids'), 'phase', 'question', 'topic', q.topic,
           'question', q.question, 'options', to_jsonb(q.options),
           'until', now() + interval '15 seconds', 'answered', '[]'::jsonb),
         secret = jsonb_set(r.secret, '{answers}', '{}'::jsonb),
         updated_at = now()
   where id = p_room;
end;
$$;

-- Moves a trivia room forward when it is time: question -> reveal (everyone answered or time is up),
-- reveal -> next question (or the end). The caller must already hold the row lock.
create or replace function private.trivia_tick(p_room uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.game_rooms%rowtype;
  v_idx integer; v_total integer; v_correct integer; v_results jsonb; v_winner uuid; v_top integer;
begin
  select * into r from public.game_rooms where id = p_room;
  if r.id is null or r.kind <> 'trivia' or r.status <> 'playing' then return; end if;
  v_idx := (r.state ->> 'q')::integer;
  v_total := (r.state ->> 'total')::integer;

  if r.state ->> 'phase' = 'question' then
    if now() >= (r.state ->> 'until')::timestamptz
       or (select count(*) from jsonb_object_keys(r.secret -> 'answers')) >= (select count(*) from public.game_room_players where room_id = p_room) then
      select answer into v_correct from public.trivia_questions where id = (r.secret -> 'ids' ->> v_idx)::integer;
      select coalesce(jsonb_agg(jsonb_build_object('user_id', x.user_id, 'choice', x.c, 'points', x.p) order by x.seat), '[]'::jsonb)
        into v_results
        from (select pl.user_id, pl.seat,
                     (r.secret -> 'answers' -> pl.user_id::text ->> 'c')::integer as c,
                     case when (r.secret -> 'answers' -> pl.user_id::text ->> 'c')::integer = v_correct then
                       100 + floor(50 * greatest(0, extract(epoch from ((r.state ->> 'until')::timestamptz - (r.secret -> 'answers' -> pl.user_id::text ->> 'at')::timestamptz))) / 15)::integer
                     else 0 end as p
                from public.game_room_players pl where pl.room_id = p_room) x;
      update public.game_room_players gp
         set score = gp.score + (e ->> 'points')::integer
        from jsonb_array_elements(v_results) e
       where gp.room_id = p_room and gp.user_id = (e ->> 'user_id')::uuid;
      update public.game_rooms
         set state = r.state || jsonb_build_object('phase', 'reveal', 'correct', v_correct, 'results', v_results, 'until', now() + interval '5 seconds'),
             updated_at = now()
       where id = p_room;
    end if;
  elsif r.state ->> 'phase' = 'reveal' and now() >= (r.state ->> 'until')::timestamptz then
    if v_idx + 1 < v_total then
      perform private.trivia_open(p_room, v_idx + 1);
    else
      select max(score) into v_top from public.game_room_players where room_id = p_room;
      if v_top > 0 and (select count(*) from public.game_room_players where room_id = p_room and score = v_top) = 1 then
        select user_id into v_winner from public.game_room_players where room_id = p_room and score = v_top;
      end if;
      perform private.room_finish(p_room, v_winner, r.state || jsonb_build_object('phase', 'done'));
    end if;
  end if;
end;
$$;

revoke all on function private.room_max_players(text), private.ttt_line(text, text), private.c4_line(text, text),
  private.room_finish(uuid, uuid, jsonb), private.trivia_open(uuid, integer), private.trivia_tick(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Lobby: create, join, leave, start, delete
-- ---------------------------------------------------------------------------
create or replace function public.create_room(p_group_id uuid, p_kind text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_member(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_kind is null or p_kind not in ('tictactoe', 'connect4', 'rps', 'trivia') then
    raise exception 'invalid_game' using errcode = '22023';
  end if;
  if (select count(*) from public.game_rooms where group_id = p_group_id and host_id = v_uid and status <> 'finished') >= 3 then
    raise exception 'too_many_games' using errcode = 'P0001';
  end if;
  insert into public.game_rooms (group_id, kind, host_id) values (p_group_id, p_kind, v_uid) returning id into v_id;
  insert into public.game_room_players (room_id, user_id, seat) values (v_id, v_uid, 0);
  return v_id;
end;
$$;

create or replace function public.join_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.game_rooms%rowtype;
  v_seat integer;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id for update;
  if r.id is null or not private.is_group_member(r.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if exists (select 1 from public.game_room_players where room_id = p_room_id and user_id = v_uid) then return; end if;
  if r.status <> 'lobby' then raise exception 'game_started' using errcode = 'P0001'; end if;
  select min(s) into v_seat from generate_series(0, private.room_max_players(r.kind) - 1) s
   where not exists (select 1 from public.game_room_players where room_id = p_room_id and seat = s);
  if v_seat is null then raise exception 'game_full' using errcode = 'P0001'; end if;
  insert into public.game_room_players (room_id, user_id, seat) values (p_room_id, v_uid, v_seat);
  update public.game_rooms set updated_at = now() where id = p_room_id;
end;
$$;

-- In the lobby: step out (the host passes the room on, or it closes when empty).
-- During a two-player game: leaving forfeits, so the other person wins.
create or replace function public.leave_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.game_rooms%rowtype;
  v_other uuid;
  v_next uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id for update;
  if r.id is null or not exists (select 1 from public.game_room_players where room_id = p_room_id and user_id = v_uid) then return; end if;
  if r.status = 'lobby' then
    delete from public.game_room_players where room_id = p_room_id and user_id = v_uid;
    select user_id into v_next from public.game_room_players where room_id = p_room_id order by seat limit 1;
    if v_next is null then
      delete from public.game_rooms where id = p_room_id;
    elsif r.host_id = v_uid then
      update public.game_rooms set host_id = v_next, updated_at = now() where id = p_room_id;
    end if;
  elsif r.status = 'playing' and r.kind <> 'trivia' then
    select user_id into v_other from public.game_room_players where room_id = p_room_id and user_id <> v_uid limit 1;
    perform private.room_finish(p_room_id, v_other, r.state || jsonb_build_object('forfeit', v_uid));
  end if;
end;
$$;

create or replace function public.start_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.game_rooms%rowtype;
  v_ids jsonb;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id for update;
  if r.id is null or not private.is_group_member(r.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if r.host_id <> v_uid then raise exception 'not_allowed' using errcode = '42501'; end if;
  if r.status <> 'lobby' then raise exception 'game_started' using errcode = 'P0001'; end if;
  if (select count(*) from public.game_room_players where room_id = p_room_id) < 2 then
    raise exception 'not_enough_players' using errcode = 'P0001';
  end if;

  if r.kind = 'tictactoe' then
    update public.game_rooms set status = 'playing', state = jsonb_build_object('board', '.........', 'turn', 0), updated_at = now() where id = p_room_id;
  elsif r.kind = 'connect4' then
    update public.game_rooms set status = 'playing', state = jsonb_build_object('board', repeat('.', 42), 'turn', 0), updated_at = now() where id = p_room_id;
  elsif r.kind = 'rps' then
    update public.game_rooms set status = 'playing',
      state = jsonb_build_object('round', 1, 'wins', jsonb_build_array(0, 0), 'target', 2, 'moved', '[]'::jsonb),
      secret = jsonb_build_object('choices', '{}'::jsonb), updated_at = now() where id = p_room_id;
  else
    select jsonb_agg(id) into v_ids from (select id from public.trivia_questions order by random() limit 8) q;
    update public.game_rooms set status = 'playing', secret = jsonb_build_object('ids', v_ids, 'answers', '{}'::jsonb), updated_at = now() where id = p_room_id;
    perform private.trivia_open(p_room_id, 0);
  end if;
end;
$$;

create or replace function public.delete_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.game_rooms%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id;
  if r.id is null then return; end if;
  if r.host_id <> v_uid and not private.is_group_manager(r.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  delete from public.game_rooms where id = p_room_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- The one move function: cell (0-8), column (0-6), choice (1 rock, 2 paper, 3 scissors) or option (0-3)
-- ---------------------------------------------------------------------------
create or replace function public.make_move(p_room_id uuid, p_move integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.game_rooms%rowtype;
  me public.game_room_players%rowtype;
  v_board text; v_mark text; v_line integer[]; v_row integer; v_i integer;
  v_choices jsonb; v_c0 integer; v_c1 integer; v_res integer; v_wins jsonb; v_w0 integer; v_w1 integer; v_round integer; v_win_seat integer; v_win uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id for update;
  if r.id is null or not private.is_group_member(r.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  select * into me from public.game_room_players where room_id = p_room_id and user_id = v_uid;
  if me.user_id is null then raise exception 'not_in_game' using errcode = '42501'; end if;
  if r.kind = 'trivia' then
    perform private.trivia_tick(p_room_id);
    select * into r from public.game_rooms where id = p_room_id;
  end if;
  if r.status <> 'playing' then raise exception 'game_over' using errcode = 'P0001'; end if;
  if p_move is null then raise exception 'invalid_move' using errcode = '22023'; end if;

  -- Tic-Tac-Toe ------------------------------------------------------------
  if r.kind = 'tictactoe' then
    if (r.state ->> 'turn')::integer <> me.seat then raise exception 'not_your_turn' using errcode = 'P0001'; end if;
    if p_move < 0 or p_move > 8 then raise exception 'invalid_move' using errcode = '22023'; end if;
    v_board := r.state ->> 'board';
    if substr(v_board, p_move + 1, 1) <> '.' then raise exception 'cell_taken' using errcode = 'P0001'; end if;
    v_mark := case when me.seat = 0 then 'X' else 'O' end;
    v_board := overlay(v_board placing v_mark from p_move + 1 for 1);
    v_line := private.ttt_line(v_board, v_mark);
    if v_line is not null then
      update public.game_room_players set score = 1 where room_id = p_room_id and user_id = v_uid;
      perform private.room_finish(p_room_id, v_uid, jsonb_build_object('board', v_board, 'turn', me.seat, 'last', p_move, 'line', to_jsonb(v_line)));
    elsif position('.' in v_board) = 0 then
      perform private.room_finish(p_room_id, null, jsonb_build_object('board', v_board, 'turn', me.seat, 'last', p_move, 'draw', true));
    else
      update public.game_rooms set state = jsonb_build_object('board', v_board, 'turn', 1 - me.seat, 'last', p_move), updated_at = now() where id = p_room_id;
    end if;

  -- Connect 4 --------------------------------------------------------------
  elsif r.kind = 'connect4' then
    if (r.state ->> 'turn')::integer <> me.seat then raise exception 'not_your_turn' using errcode = 'P0001'; end if;
    if p_move < 0 or p_move > 6 then raise exception 'invalid_move' using errcode = '22023'; end if;
    v_board := r.state ->> 'board';
    v_row := null;
    for v_i in reverse 5..0 loop
      if substr(v_board, v_i*7 + p_move + 1, 1) = '.' then v_row := v_i; exit; end if;
    end loop;
    if v_row is null then raise exception 'column_full' using errcode = 'P0001'; end if;
    v_mark := case when me.seat = 0 then 'R' else 'Y' end;
    v_board := overlay(v_board placing v_mark from v_row*7 + p_move + 1 for 1);
    v_line := private.c4_line(v_board, v_mark);
    if v_line is not null then
      update public.game_room_players set score = 1 where room_id = p_room_id and user_id = v_uid;
      perform private.room_finish(p_room_id, v_uid, jsonb_build_object('board', v_board, 'turn', me.seat, 'last', v_row*7 + p_move, 'line', to_jsonb(v_line)));
    elsif position('.' in v_board) = 0 then
      perform private.room_finish(p_room_id, null, jsonb_build_object('board', v_board, 'turn', me.seat, 'last', v_row*7 + p_move, 'draw', true));
    else
      update public.game_rooms set state = jsonb_build_object('board', v_board, 'turn', 1 - me.seat, 'last', v_row*7 + p_move), updated_at = now() where id = p_room_id;
    end if;

  -- Rock-Paper-Scissors, first to 2 -------------------------------------------
  elsif r.kind = 'rps' then
    if p_move < 1 or p_move > 3 then raise exception 'invalid_move' using errcode = '22023'; end if;
    v_choices := coalesce(r.secret -> 'choices', '{}'::jsonb);
    if v_choices ? me.seat::text then raise exception 'already_moved' using errcode = 'P0001'; end if;
    v_choices := v_choices || jsonb_build_object(me.seat::text, p_move);
    if not (v_choices ? '0' and v_choices ? '1') then
      update public.game_rooms
         set secret = jsonb_set(r.secret, '{choices}', v_choices),
             state = jsonb_set(r.state, '{moved}', coalesce(r.state -> 'moved', '[]'::jsonb) || to_jsonb(me.seat)),
             updated_at = now()
       where id = p_room_id;
    else
      v_c0 := (v_choices ->> '0')::integer; v_c1 := (v_choices ->> '1')::integer;
      v_res := case when v_c0 = v_c1 then -1
                    when (v_c0 = 1 and v_c1 = 3) or (v_c0 = 2 and v_c1 = 1) or (v_c0 = 3 and v_c1 = 2) then 0
                    else 1 end;
      v_w0 := (r.state -> 'wins' ->> 0)::integer + case when v_res = 0 then 1 else 0 end;
      v_w1 := (r.state -> 'wins' ->> 1)::integer + case when v_res = 1 then 1 else 0 end;
      v_round := (r.state ->> 'round')::integer;
      v_wins := jsonb_build_array(v_w0, v_w1);
      update public.game_room_players set score = v_w0 where room_id = p_room_id and seat = 0;
      update public.game_room_players set score = v_w1 where room_id = p_room_id and seat = 1;
      if v_w0 >= 2 or v_w1 >= 2 then
        v_win_seat := case when v_w0 >= 2 then 0 else 1 end;
        select user_id into v_win from public.game_room_players where room_id = p_room_id and seat = v_win_seat;
        perform private.room_finish(p_room_id, v_win, jsonb_build_object('round', v_round, 'wins', v_wins, 'target', 2, 'moved', '[]'::jsonb,
          'last', jsonb_build_object('c', jsonb_build_array(v_c0, v_c1), 'result', v_res)));
      else
        update public.game_rooms
           set secret = jsonb_set(r.secret, '{choices}', '{}'::jsonb),
               state = jsonb_build_object('round', v_round + 1, 'wins', v_wins, 'target', 2, 'moved', '[]'::jsonb,
                         'last', jsonb_build_object('c', jsonb_build_array(v_c0, v_c1), 'result', v_res)),
               updated_at = now()
         where id = p_room_id;
      end if;
    end if;

  -- Trivia race ------------------------------------------------------------
  else
    if r.state ->> 'phase' <> 'question' or now() >= (r.state ->> 'until')::timestamptz then
      raise exception 'too_late' using errcode = 'P0001';
    end if;
    if p_move < 0 or p_move > 3 then raise exception 'invalid_move' using errcode = '22023'; end if;
    if (r.secret -> 'answers') ? v_uid::text then raise exception 'already_moved' using errcode = 'P0001'; end if;
    update public.game_rooms
       set secret = jsonb_set(r.secret, '{answers}', coalesce(r.secret -> 'answers', '{}'::jsonb) || jsonb_build_object(v_uid::text, jsonb_build_object('c', p_move, 'at', now()))),
           state = jsonb_set(r.state, '{answered}', coalesce(r.state -> 'answered', '[]'::jsonb) || to_jsonb(v_uid)),
           updated_at = now()
     where id = p_room_id;
    perform private.trivia_tick(p_room_id);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reading: one room (public parts only), and the lobby with a leaderboard
-- ---------------------------------------------------------------------------
create or replace function public.get_room(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.game_rooms%rowtype;
  v_me public.game_room_players%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id;
  if r.id is null or not private.is_group_member(r.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if r.kind = 'trivia' and r.status = 'playing' then
    perform 1 from public.game_rooms where id = p_room_id for update;
    perform private.trivia_tick(p_room_id);
    select * into r from public.game_rooms where id = p_room_id;
  end if;
  select * into v_me from public.game_room_players where room_id = p_room_id and user_id = v_uid;
  return jsonb_build_object(
    'id', r.id, 'group_id', r.group_id, 'kind', r.kind, 'status', r.status, 'host_id', r.host_id,
    'winner_id', r.winner_id, 'max_players', private.room_max_players(r.kind), 'state', r.state,
    'me_seat', v_me.seat, 'in_room', v_me.user_id is not null,
    'my_answer', case when r.kind = 'trivia' and r.status = 'playing' then (r.secret -> 'answers' -> v_uid::text ->> 'c')::integer end,
    'my_choice', case when r.kind = 'rps' and r.status = 'playing' and v_me.user_id is not null then (r.secret -> 'choices' ->> v_me.seat::text)::integer end,
    'server_now', now(), 'created_at', r.created_at,
    'players', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', p.user_id, 'seat', p.seat, 'score', p.score,
                                          'name', coalesce(pr.display_name, 'Member'), 'avatar_path', pr.avatar_path) order by p.seat)
        from public.game_room_players p left join public.profiles pr on pr.id = p.user_id
       where p.room_id = p_room_id), '[]'::jsonb));
end;
$$;

create or replace function public.list_rooms(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_member(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  -- rooms nobody touched for six hours are closed
  update public.game_rooms
     set status = 'finished', finished_at = now(), state = state || '{"abandoned": true}'::jsonb
   where group_id = p_group_id and status <> 'finished' and updated_at < now() - interval '6 hours';
  return jsonb_build_object(
    'rooms', coalesce((
      select jsonb_agg(x.j order by x.rank, x.created_at desc)
        from (
          select g.created_at, case when g.status = 'finished' then 1 else 0 end as rank,
            jsonb_build_object(
              'id', g.id, 'kind', g.kind, 'status', g.status, 'host_id', g.host_id, 'winner_id', g.winner_id,
              'created_at', g.created_at, 'max_players', private.room_max_players(g.kind),
              'abandoned', coalesce((g.state ->> 'abandoned')::boolean, false),
              'in_room', exists (select 1 from public.game_room_players p where p.room_id = g.id and p.user_id = v_uid),
              'players', coalesce((select jsonb_agg(jsonb_build_object('user_id', p.user_id, 'seat', p.seat, 'score', p.score,
                                       'name', coalesce(pr.display_name, 'Member')) order by p.seat)
                                     from public.game_room_players p left join public.profiles pr on pr.id = p.user_id
                                    where p.room_id = g.id), '[]'::jsonb)) as j
            from public.game_rooms g
           where g.group_id = p_group_id
             and (g.status <> 'finished' or g.id in (select id from public.game_rooms where group_id = p_group_id and status = 'finished' order by finished_at desc nulls last limit 5))
           order by case when g.status = 'finished' then 1 else 0 end, g.created_at desc
           limit 30
        ) x), '[]'::jsonb),
    'leaderboard', coalesce((
      select jsonb_agg(l.j order by l.wins desc, l.played asc, l.name)
        from (
          select count(*) filter (where r.winner_id = p.user_id) as wins, count(*) as played, coalesce(pr.display_name, 'Member') as name,
                 jsonb_build_object('user_id', p.user_id, 'name', coalesce(pr.display_name, 'Member'),
                                    'wins', count(*) filter (where r.winner_id = p.user_id), 'played', count(*)) as j
            from public.game_room_players p
            join public.game_rooms r on r.id = p.room_id and r.status = 'finished' and r.group_id = p_group_id
                                    and not coalesce((r.state ->> 'abandoned')::boolean, false)
            left join public.profiles pr on pr.id = p.user_id
           group by p.user_id, pr.display_name
           order by 1 desc, 2 asc limit 10
        ) l), '[]'::jsonb));
end;
$$;

revoke all on function public.create_room(uuid, text), public.join_room(uuid), public.leave_room(uuid), public.start_room(uuid),
  public.delete_room(uuid), public.make_move(uuid, integer), public.get_room(uuid), public.list_rooms(uuid) from public, anon;
grant execute on function public.create_room(uuid, text), public.join_room(uuid), public.leave_room(uuid), public.start_room(uuid),
  public.delete_room(uuid), public.make_move(uuid, integer), public.get_room(uuid), public.list_rooms(uuid) to authenticated;

commit;

-- ===== 013_game_night.sql =====
-- 013_game_night.sql
-- Game night, part 2. Adds seven new live games on top of 012:
--   clash    (2 players)   battle: strike / heavy / guard / heal, picked in secret each round
--   penalty  (2 players)   football penalty shootout, shooter and keeper pick a corner in secret
--   race     (2-10)        street race to the finish line, pick a gear each round (boost can spin you out)
--   emoji    (2-12)        emoji decode: same engine as the trivia race, with emoji puzzles
--   likely   (3-12)        "Most likely to...": vote for a squadmate, most votes wears the crown
--   rather   (2-12)        "Would you rather...": pick a side, the majority side scores
--   pot      (2-10)        "Risk It": everyone puts squad coins in the pot, rolls two dice, may re-roll once (at their own risk),
--                          highest total takes the pot
--
-- SQUAD COINS ARE PRETEND. They are not money, can't be bought, sold, withdrawn or paid out, and no Mobile Money moves.
-- Everyone starts with 200 coins per squad and can claim +50 once a day, so nobody is ever locked out.
-- The server rolls every die and keeps secrets (picks, dice, answers) until the moment of reveal.
-- Safe to re-run. Prerequisites: 001-012.

begin;

alter table public.game_rooms drop constraint if exists game_rooms_kind_check;
alter table public.game_rooms add constraint game_rooms_kind_check
  check (kind in ('tictactoe', 'connect4', 'rps', 'trivia', 'clash', 'penalty', 'race', 'emoji', 'likely', 'rather', 'pot'));
alter table public.game_rooms add column if not exists stake integer not null default 0;
alter table public.game_rooms drop constraint if exists game_rooms_stake_check;
alter table public.game_rooms add constraint game_rooms_stake_check check (stake in (0, 10, 25, 50, 100));

create table if not exists public.squad_wallets (
  group_id uuid not null references public.savings_groups (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  balance integer not null default 200 check (balance >= 0),
  last_claim date,
  primary key (group_id, user_id)
);

create table if not exists public.vibe_prompts (
  id serial primary key,
  kind text not null check (kind in ('likely', 'rather')),
  prompt text not null unique,
  option_a text,
  option_b text
);

alter table public.squad_wallets enable row level security;
alter table public.vibe_prompts enable row level security;
revoke all on public.squad_wallets, public.vibe_prompts from anon, authenticated;
grant select, insert, update, delete on public.squad_wallets, public.vibe_prompts to service_role;
revoke all on sequence public.vibe_prompts_id_seq from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Content: emoji puzzles, slang and football trivia, "most likely" and "would you rather"
-- ---------------------------------------------------------------------------
insert into public.trivia_questions (topic, question, options, answer) values
 ('Emoji', 'Guess the movie: 🦁👑', array['The Lion King', 'Madagascar', 'Jumanji', 'Zootopia'], 0),
 ('Emoji', 'Guess the movie: ❄️👸⛄', array['Tangled', 'Frozen', 'Moana', 'Cinderella'], 1),
 ('Emoji', 'Guess the movie: 🕷️🧑', array['Ant-Man', 'Venom', 'Spider-Man', 'Black Widow'], 2),
 ('Emoji', 'Guess the movie: 🐠🔍', array['Shark Tale', 'Finding Nemo', 'The Little Mermaid', 'Aquaman'], 1),
 ('Emoji', 'Guess the movie: 🧸🤠🚀', array['Toy Story', 'Cars', 'Up', 'Coco'], 0),
 ('Emoji', 'Guess the movie: 🐼🥋', array['Madagascar', 'Kung Fu Panda', 'Rio', 'Sing'], 1),
 ('Emoji', 'Guess the movie: 🖤🐆👑', array['The Lion King', 'Creed', 'Black Panther', 'Wakanda Rising'], 2),
 ('Emoji', 'Guess the movie: 🦈🌊😱', array['Jaws', 'Moana', 'Titanic', 'Aquaman'], 0),
 ('Emoji', 'Guess the movie: 🏎️⚡😎', array['Fast & Furious', 'Cars', 'Transformers', 'Speed'], 1),
 ('Emoji', 'Guess the movie: 🧙‍♂️💍🌋', array['Harry Potter', 'The Hobbit', 'The Lord of the Rings', 'Narnia'], 2),
 ('Emoji', 'Guess the movie: 🦇🧔', array['Batman', 'Dracula', 'Venom', 'Joker'], 0),
 ('Emoji', 'Guess the movie: 👻🚫', array['Casper', 'Coco', 'Ghostbusters', 'Scary Movie'], 2),
 ('Emoji', 'What does 💀 mean in a chat?', array['Someone died', 'I''m dying laughing', 'I''m scared', 'Halloween'], 1),
 ('Emoji', 'What does 🍵 mean when girls text it?', array['Let''s drink tea', 'Spill the gossip', 'I''m sleepy', 'Good morning'], 1),
 ('Emoji', 'What does 🧢 mean in a comment?', array['That''s a lie, cap', 'Nice hat', 'School time', 'Football fan'], 0),
 ('Emoji', 'What does 🐐 mean?', array['Farm animal', 'Greatest of all time', 'Very slow', 'Hungry'], 1),
 ('Emoji', 'What does 😭 often mean in a chat?', array['Truly devastated only', 'So funny or so relatable', 'Allergies', 'Sleepy'], 1),
 ('Emoji', 'What does 🫶 mean?', array['Love and support', 'Stop it', 'Please pay me', 'Clap for me'], 0),
 ('Emoji', 'What does 💅 mean when someone posts it?', array['Time for nails only', 'Slay, unbothered and confident', 'I''m angry', 'Goodbye'], 1),
 ('Emoji', 'What does 🙄 mean?', array['Eye roll, annoyed', 'I''m so excited', 'Looking for you', 'Dizzy'], 0),
 ('Slang', 'What does "no cap" mean?', array['No hat', 'No lie, for real', 'No problem', 'No money'], 1),
 ('Slang', 'If someone says "that''s a W", it means...', array['It''s a win', 'It''s wrong', 'It''s weird', 'It''s waiting'], 0),
 ('Slang', 'What does "rizz" mean?', array['Being very tired', 'Charm and flirting skill', 'Being rich', 'A type of rice'], 1),
 ('Slang', 'If your friend says you "ate", you...', array['Had lunch', 'Did something really well', 'Were rude', 'Were late'], 1),
 ('Slang', 'What does "delulu" mean?', array['Delivered late', 'Delusional, living in a fantasy', 'Delicious', 'Very tall'], 1),
 ('Slang', 'What does "mid" mean?', array['Amazing', 'Average and not impressive', 'Midnight', 'Middle child'], 1),
 ('Slang', 'What does "ghosting" someone mean?', array['Scaring them', 'Cutting contact with no explanation', 'Dressing as a ghost', 'Calling them at night'], 1),
 ('Slang', 'What does "FOMO" stand for?', array['Fear of missing out', 'Friends of my office', 'Food on my order', 'Fun on my own'], 0),
 ('Slang', 'What does "GOAT" stand for?', array['Great on all tracks', 'Greatest of all time', 'Good at online trading', 'Going out and talking'], 1),
 ('Slang', 'What does "L" mean in "that''s an L"?', array['A loss', 'A lot', 'A letter', 'Late'], 0),
 ('Slang', 'If you are "cooked", you are...', array['Hungry', 'In serious trouble', 'Very rich', 'Very famous'], 1),
 ('Slang', 'What is a "vibe check"?', array['A phone update', 'Checking the mood or energy', 'A medical test', 'A song contest'], 1),
 ('Football', 'How many players does one team have on the pitch?', array['9', '10', '11', '12'], 2),
 ('Football', 'What is a "hat-trick"?', array['Three goals by one player', 'Two red cards', 'A special corner', 'A goal from the halfway line'], 0),
 ('Football', 'Which club plays its home games at Camp Nou?', array['Real Madrid', 'FC Barcelona', 'Manchester City', 'Juventus'], 1),
 ('Football', 'Which country hosted the 2010 FIFA World Cup?', array['Brazil', 'Germany', 'South Africa', 'Russia'], 2),
 ('Football', 'How long is a normal football match without extra time?', array['60 minutes', '80 minutes', '90 minutes', '100 minutes'], 2),
 ('Football', 'What colour card means a player must leave the pitch?', array['Yellow', 'Red', 'Blue', 'Green'], 1)
on conflict (question) do nothing;

insert into public.vibe_prompts (kind, prompt) values
 ('likely', 'Most likely to be late to their own birthday party'),
 ('likely', 'Most likely to cry at a wedding'),
 ('likely', 'Most likely to go viral on TikTok'),
 ('likely', 'Most likely to reply after 3 days'),
 ('likely', 'Most likely to win the squad savings challenge'),
 ('likely', 'Most likely to start the group chat drama'),
 ('likely', 'Most likely to forget their phone charger'),
 ('likely', 'Most likely to become a millionaire first'),
 ('likely', 'Most likely to ghost the group chat'),
 ('likely', 'Most likely to have the best outfit at the next event'),
 ('likely', 'Most likely to say "I''ll pay you back tomorrow"'),
 ('likely', 'Most likely to know all the gossip'),
 ('likely', 'Most likely to get lost with the map open'),
 ('likely', 'Most likely to be everyone''s free therapist'),
 ('likely', 'Most likely to eat the last piece of food'),
 ('likely', 'Most likely to dance first at the party'),
 ('likely', 'Most likely to say "one more minute" for an hour'),
 ('likely', 'Most likely to have 100 unread messages'),
 ('likely', 'Most likely to be the squad''s main character'),
 ('likely', 'Most likely to save the most money this year')
on conflict (prompt) do nothing;

insert into public.vibe_prompts (kind, prompt, option_a, option_b) values
 ('rather', 'Would you rather never use social media again, or never watch another movie or series?', 'Never use social media again', 'Never watch movies or series again'),
 ('rather', 'Would you rather always be 10 minutes late, or always be 20 minutes early?', 'Always 10 minutes late', 'Always 20 minutes early'),
 ('rather', 'Would you rather lose your phone for a week, or lose your best shoes forever?', 'Lose my phone for a week', 'Lose my best shoes forever'),
 ('rather', 'Would you rather eat only chips forever, or only pizza forever?', 'Only chips forever', 'Only pizza forever'),
 ('rather', 'Would you rather have unlimited data, or unlimited airtime?', 'Unlimited data', 'Unlimited airtime'),
 ('rather', 'Would you rather go viral for a dance, or be known for a great business?', 'Viral dance', 'Great business'),
 ('rather', 'Would you rather speak every language, or talk to animals?', 'Speak every language', 'Talk to animals'),
 ('rather', 'Would you rather wake up at 5am every day, or stay up until 3am every day?', 'Wake up at 5am daily', 'Stay up until 3am daily'),
 ('rather', 'Would you rather get 1,000,000 RWF now, or 1,000 RWF every day for life?', '1,000,000 RWF now', '1,000 RWF every day for life'),
 ('rather', 'Would you rather live in Kigali forever, or travel to a new country every year?', 'Kigali forever', 'A new country every year'),
 ('rather', 'Would you rather have perfect hair every day, or perfect skin every day?', 'Perfect hair', 'Perfect skin'),
 ('rather', 'Would you rather be able to fly, or be invisible?', 'Fly', 'Be invisible'),
 ('rather', 'Would you rather match outfits with your bestie daily, or never repeat an outfit?', 'Match outfits with my bestie', 'Never repeat an outfit'),
 ('rather', 'Would you rather sing in public, or dance in public?', 'Sing in public', 'Dance in public'),
 ('rather', 'Would you rather your crush replies instantly but is boring, or replies slowly but is fun?', 'Instant but boring', 'Slow but fun'),
 ('rather', 'Would you rather have a free ride everywhere, or free food everywhere?', 'Free rides everywhere', 'Free food everywhere'),
 ('rather', 'Would you rather read everyone''s mind, or have everyone love you?', 'Read minds', 'Be loved by everyone'),
 ('rather', 'Would you rather get a surprise party, or plan your own perfect party?', 'Surprise party', 'Plan my own')
on conflict (prompt) do nothing;
update public.vibe_prompts set option_a = null, option_b = null where kind = 'likely';

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function private.room_max_players(p_kind text)
returns integer language sql immutable set search_path = '' as $$
  select case p_kind when 'trivia' then 12 when 'emoji' then 12 when 'likely' then 12 when 'rather' then 12
                     when 'race' then 10 when 'pot' then 10 else 2 end
$$;

create or replace function private.room_min_players(p_kind text)
returns integer language sql immutable set search_path = '' as $$
  select case p_kind when 'likely' then 3 else 2 end
$$;

-- squad coins: +/- an amount. Fails with not_enough_coins instead of going below zero.
create or replace function private.wallet_add(p_group uuid, p_user uuid, p_delta integer)
returns integer language plpgsql security definer set search_path = '' as $$
declare v_bal integer;
begin
  insert into public.squad_wallets (group_id, user_id) values (p_group, p_user) on conflict do nothing;
  begin
    update public.squad_wallets set balance = balance + p_delta where group_id = p_group and user_id = p_user returning balance into v_bal;
  exception when check_violation then
    raise exception 'not_enough_coins' using errcode = 'P0001';
  end;
  return v_bal;
end;
$$;

-- give every player of a lobby their stake back
create or replace function private.pot_refund(p_room uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.game_rooms%rowtype; p record;
begin
  select * into r from public.game_rooms where id = p_room;
  if r.id is null or r.kind <> 'pot' or r.stake = 0 then return; end if;
  for p in select user_id from public.game_room_players where room_id = p_room loop
    perform private.wallet_add(r.group_id, p.user_id, r.stake);
  end loop;
end;
$$;

-- two dice, with the house flavour: double sixes count 13, snake eyes count 0
create or replace function private.dice_total(p_a integer, p_b integer)
returns integer language sql immutable set search_path = '' as $$
  select case when p_a = 6 and p_b = 6 then 13 when p_a = 1 and p_b = 1 then 0 else p_a + p_b end
$$;

create or replace function private.roll_die()
returns integer language sql volatile set search_path = '' as $$ select 1 + floor(random() * 6)::integer $$;

-- Risk It: everyone's dice are revealed, highest total takes the pot (a tie splits it). Undecided players hold.
create or replace function private.pot_resolve(p_room uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.game_rooms%rowtype;
  v_n integer; v_pot integer; v_best integer; v_winners uuid[]; v_share integer; v_rest integer; v_results jsonb; w uuid; i integer := 0;
begin
  select * into r from public.game_rooms where id = p_room;
  if r.id is null or r.kind <> 'pot' or r.status <> 'playing' then return; end if;
  select count(*) into v_n from public.game_room_players where room_id = p_room;
  v_pot := r.stake * v_n;
  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', pl.user_id, 'seat', pl.seat,
           'dice', r.secret -> 'rolls' -> pl.user_id::text -> 'd',
           'rerolled', coalesce((r.secret -> 'rolls' -> pl.user_id::text ->> 'rerolled')::boolean, false),
           'total', private.dice_total((r.secret -> 'rolls' -> pl.user_id::text -> 'd' ->> 0)::integer, (r.secret -> 'rolls' -> pl.user_id::text -> 'd' ->> 1)::integer)
         ) order by pl.seat), '[]'::jsonb)
    into v_results
    from public.game_room_players pl where pl.room_id = p_room;
  select max((e ->> 'total')::integer) into v_best from jsonb_array_elements(v_results) e;
  select array_agg((e ->> 'user_id')::uuid order by (e ->> 'seat')::integer) into v_winners
    from jsonb_array_elements(v_results) e where (e ->> 'total')::integer = v_best;
  v_share := v_pot / cardinality(v_winners);
  v_rest := v_pot - v_share * cardinality(v_winners);
  foreach w in array v_winners loop
    i := i + 1;
    perform private.wallet_add(r.group_id, w, v_share + case when i = 1 then v_rest else 0 end);
  end loop;
  update public.game_room_players gp set score = (e ->> 'total')::integer
    from jsonb_array_elements(v_results) e where gp.room_id = p_room and gp.user_id = (e ->> 'user_id')::uuid;
  perform private.room_finish(p_room, case when cardinality(v_winners) = 1 then v_winners[1] end,
    jsonb_build_object('phase', 'done', 'stake', r.stake, 'pot', v_pot, 'winners', to_jsonb(v_winners), 'results', v_results));
end;
$$;

create or replace function private.pot_tick(p_room uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.game_rooms%rowtype;
begin
  select * into r from public.game_rooms where id = p_room;
  if r.id is null or r.kind <> 'pot' or r.status <> 'playing' then return; end if;
  if now() >= (r.state ->> 'until')::timestamptz
     or (select count(*) from jsonb_each(r.secret -> 'rolls') e where (e.value ->> 'decided')::boolean) >= (select count(*) from public.game_room_players where room_id = p_room) then
    perform private.pot_resolve(p_room);
  end if;
end;
$$;

-- Trivia and emoji decode share one engine (replaces the 012 version so both kinds are covered)
create or replace function private.trivia_tick(p_room uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.game_rooms%rowtype;
  v_idx integer; v_total integer; v_correct integer; v_results jsonb; v_winner uuid; v_top integer;
begin
  select * into r from public.game_rooms where id = p_room;
  if r.id is null or r.kind not in ('trivia', 'emoji') or r.status <> 'playing' then return; end if;
  v_idx := (r.state ->> 'q')::integer;
  v_total := (r.state ->> 'total')::integer;

  if r.state ->> 'phase' = 'question' then
    if now() >= (r.state ->> 'until')::timestamptz
       or (select count(*) from jsonb_object_keys(r.secret -> 'answers')) >= (select count(*) from public.game_room_players where room_id = p_room) then
      select answer into v_correct from public.trivia_questions where id = (r.secret -> 'ids' ->> v_idx)::integer;
      select coalesce(jsonb_agg(jsonb_build_object('user_id', x.user_id, 'choice', x.c, 'points', x.p) order by x.seat), '[]'::jsonb)
        into v_results
        from (select pl.user_id, pl.seat,
                     (r.secret -> 'answers' -> pl.user_id::text ->> 'c')::integer as c,
                     case when (r.secret -> 'answers' -> pl.user_id::text ->> 'c')::integer = v_correct then
                       100 + floor(50 * greatest(0, extract(epoch from ((r.state ->> 'until')::timestamptz - (r.secret -> 'answers' -> pl.user_id::text ->> 'at')::timestamptz))) / 15)::integer
                     else 0 end as p
                from public.game_room_players pl where pl.room_id = p_room) x;
      update public.game_room_players gp
         set score = gp.score + (e ->> 'points')::integer
        from jsonb_array_elements(v_results) e
       where gp.room_id = p_room and gp.user_id = (e ->> 'user_id')::uuid;
      update public.game_rooms
         set state = r.state || jsonb_build_object('phase', 'reveal', 'correct', v_correct, 'results', v_results, 'until', now() + interval '5 seconds'),
             updated_at = now()
       where id = p_room;
    end if;
  elsif r.state ->> 'phase' = 'reveal' and now() >= (r.state ->> 'until')::timestamptz then
    if v_idx + 1 < v_total then
      perform private.trivia_open(p_room, v_idx + 1);
    else
      select max(score) into v_top from public.game_room_players where room_id = p_room;
      if v_top > 0 and (select count(*) from public.game_room_players where room_id = p_room and score = v_top) = 1 then
        select user_id into v_winner from public.game_room_players where room_id = p_room and score = v_top;
      end if;
      perform private.room_finish(p_room, v_winner, r.state || jsonb_build_object('phase', 'done'));
    end if;
  end if;
end;
$$;

-- "Most likely to" / "Would you rather": opens round p_idx
create or replace function private.vibe_open(p_room uuid, p_idx integer)
returns void language plpgsql security definer set search_path = '' as $$
declare r public.game_rooms%rowtype; q public.vibe_prompts%rowtype;
begin
  select * into r from public.game_rooms where id = p_room;
  select * into q from public.vibe_prompts where id = (r.secret -> 'ids' ->> p_idx)::integer;
  update public.game_rooms
     set state = jsonb_build_object('q', p_idx, 'total', jsonb_array_length(r.secret -> 'ids'), 'phase', 'question',
           'prompt', q.prompt, 'option_a', q.option_a, 'option_b', q.option_b,
           'until', now() + interval '20 seconds', 'answered', '[]'::jsonb),
         secret = jsonb_set(r.secret, '{answers}', '{}'::jsonb),
         updated_at = now()
   where id = p_room;
end;
$$;

create or replace function private.vibe_tick(p_room uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.game_rooms%rowtype;
  v_idx integer; v_total integer; v_results jsonb; v_top integer; v_winner uuid; v_maj integer; v_a integer; v_b integer;
begin
  select * into r from public.game_rooms where id = p_room;
  if r.id is null or r.kind not in ('likely', 'rather') or r.status <> 'playing' then return; end if;
  v_idx := (r.state ->> 'q')::integer;
  v_total := (r.state ->> 'total')::integer;

  if r.state ->> 'phase' = 'question' then
    if now() >= (r.state ->> 'until')::timestamptz
       or (select count(*) from jsonb_object_keys(r.secret -> 'answers')) >= (select count(*) from public.game_room_players where room_id = p_room) then
      if r.kind = 'likely' then
        select coalesce(jsonb_agg(jsonb_build_object('seat', pl.seat, 'user_id', pl.user_id, 'n', x.n) order by pl.seat), '[]'::jsonb)
          into v_results
          from public.game_room_players pl
          left join lateral (select count(*)::integer as n from jsonb_each(r.secret -> 'answers') a where (a.value ->> 'c')::integer = pl.seat) x on true
         where pl.room_id = p_room;
        select max((e ->> 'n')::integer) into v_top from jsonb_array_elements(v_results) e;
        if v_top > 0 then
          update public.game_room_players gp set score = gp.score + 1
            from jsonb_array_elements(v_results) e
           where gp.room_id = p_room and gp.user_id = (e ->> 'user_id')::uuid and (e ->> 'n')::integer = v_top;
        end if;
        update public.game_rooms
           set state = r.state || jsonb_build_object('phase', 'reveal', 'votes', v_results, 'top', coalesce(v_top, 0), 'until', now() + interval '5 seconds'), updated_at = now()
         where id = p_room;
      else
        select count(*) filter (where (a.value ->> 'c')::integer = 0), count(*) filter (where (a.value ->> 'c')::integer = 1)
          into v_a, v_b from jsonb_each(r.secret -> 'answers') a;
        v_maj := case when v_a > v_b then 0 when v_b > v_a then 1 end;
        if v_maj is not null then
          update public.game_room_players gp set score = gp.score + 1
           where gp.room_id = p_room and (r.secret -> 'answers' -> gp.user_id::text ->> 'c')::integer = v_maj;
        end if;
        update public.game_rooms
           set state = r.state || jsonb_build_object('phase', 'reveal', 'a', v_a, 'b', v_b, 'majority', v_maj, 'until', now() + interval '5 seconds'), updated_at = now()
         where id = p_room;
      end if;
    end if;
  elsif r.state ->> 'phase' = 'reveal' and now() >= (r.state ->> 'until')::timestamptz then
    if v_idx + 1 < v_total then
      perform private.vibe_open(p_room, v_idx + 1);
    else
      select max(score) into v_top from public.game_room_players where room_id = p_room;
      if v_top > 0 and (select count(*) from public.game_room_players where room_id = p_room and score = v_top) = 1 then
        select user_id into v_winner from public.game_room_players where room_id = p_room and score = v_top;
      end if;
      perform private.room_finish(p_room, v_winner, r.state || jsonb_build_object('phase', 'done'));
    end if;
  end if;
end;
$$;

-- Street race: resolves a round when everyone has picked a gear or the 10 seconds are up
create or replace function private.race_tick(p_room uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  r public.game_rooms%rowtype;
  p record;
  v_gear integer; v_delta integer; v_crash boolean; v_pos jsonb; v_used jsonb; v_last jsonb := '[]'::jsonb; v_cur integer; v_new integer;
  v_goal integer; v_win uuid; v_best integer;
begin
  select * into r from public.game_rooms where id = p_room;
  if r.id is null or r.kind <> 'race' or r.status <> 'playing' then return; end if;
  if not (now() >= (r.state ->> 'until')::timestamptz
          or (select count(*) from jsonb_object_keys(r.secret -> 'gears')) >= (select count(*) from public.game_room_players where room_id = p_room)) then
    return;
  end if;
  v_goal := (r.state ->> 'goal')::integer;
  v_pos := r.state -> 'pos';
  v_used := r.state -> 'used';
  for p in select user_id, seat from public.game_room_players where room_id = p_room order by seat loop
    v_gear := coalesce((r.secret -> 'gears' ->> p.user_id::text)::integer, 1);
    if v_gear = 3 and (v_used ? p.seat::text) then v_gear := 1; end if;
    v_crash := false;
    if v_gear = 1 then v_delta := 3;
    elsif v_gear = 2 then
      if random() < 0.65 then v_delta := 7; else v_delta := -2; v_crash := true; end if;
    else v_delta := 9; v_used := v_used || jsonb_build_object(p.seat::text, true);
    end if;
    v_cur := (v_pos ->> p.seat::text)::integer;
    v_new := greatest(0, v_cur + v_delta);
    v_pos := v_pos || jsonb_build_object(p.seat::text, v_new);
    v_last := v_last || jsonb_build_object('seat', p.seat, 'gear', v_gear, 'delta', v_new - v_cur, 'crashed', v_crash);
    update public.game_room_players set score = v_new where room_id = p_room and user_id = p.user_id;
  end loop;
  select max(value::integer) into v_best from jsonb_each_text(v_pos);
  if v_best >= v_goal then
    -- photo finish: the server flips for it
    select pl.user_id into v_win from public.game_room_players pl
      where pl.room_id = p_room and (v_pos ->> pl.seat::text)::integer = v_best order by random() limit 1;
    perform private.room_finish(p_room, v_win, jsonb_build_object('round', (r.state ->> 'round')::integer, 'goal', v_goal, 'pos', v_pos, 'used', v_used, 'answered', '[]'::jsonb, 'last', v_last, 'phase', 'done'));
  else
    update public.game_rooms
       set state = jsonb_build_object('round', (r.state ->> 'round')::integer + 1, 'goal', v_goal, 'pos', v_pos, 'used', v_used,
                     'answered', '[]'::jsonb, 'last', v_last, 'phase', 'pick', 'until', now() + interval '10 seconds'),
           secret = jsonb_set(r.secret, '{gears}', '{}'::jsonb), updated_at = now()
     where id = p_room;
  end if;
end;
$$;

-- one call that moves whichever timed game this room is
create or replace function private.room_tick(p_room uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_kind text;
begin
  select kind into v_kind from public.game_rooms where id = p_room;
  if v_kind in ('trivia', 'emoji') then perform private.trivia_tick(p_room);
  elsif v_kind in ('likely', 'rather') then perform private.vibe_tick(p_room);
  elsif v_kind = 'race' then perform private.race_tick(p_room);
  elsif v_kind = 'pot' then perform private.pot_tick(p_room);
  end if;
end;
$$;

revoke all on function private.room_min_players(text), private.wallet_add(uuid, uuid, integer), private.pot_refund(uuid),
  private.dice_total(integer, integer), private.roll_die(), private.pot_resolve(uuid), private.pot_tick(uuid),
  private.vibe_open(uuid, integer), private.vibe_tick(uuid), private.race_tick(uuid), private.room_tick(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Lobby: create (with an optional coin stake), join (stake goes in the pot), leave (stake comes back), start, delete
-- ---------------------------------------------------------------------------
drop function if exists public.create_room(uuid, text);

create or replace function public.create_room(p_group_id uuid, p_kind text, p_stake integer default 0)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
  v_stake integer := coalesce(p_stake, 0);
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_member(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_kind is null or p_kind not in ('tictactoe', 'connect4', 'rps', 'trivia', 'clash', 'penalty', 'race', 'emoji', 'likely', 'rather', 'pot') then
    raise exception 'invalid_game' using errcode = '22023';
  end if;
  if p_kind = 'pot' then
    if v_stake not in (10, 25, 50, 100) then raise exception 'invalid_stake' using errcode = '22023'; end if;
  elsif v_stake <> 0 then
    raise exception 'invalid_stake' using errcode = '22023';
  end if;
  if (select count(*) from public.game_rooms where group_id = p_group_id and host_id = v_uid and status <> 'finished') >= 3 then
    raise exception 'too_many_games' using errcode = 'P0001';
  end if;
  if v_stake > 0 then perform private.wallet_add(p_group_id, v_uid, -v_stake); end if;
  insert into public.game_rooms (group_id, kind, host_id, stake) values (p_group_id, p_kind, v_uid, v_stake) returning id into v_id;
  insert into public.game_room_players (room_id, user_id, seat) values (v_id, v_uid, 0);
  return v_id;
end;
$$;

create or replace function public.join_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.game_rooms%rowtype;
  v_seat integer;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id for update;
  if r.id is null or not private.is_group_member(r.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if exists (select 1 from public.game_room_players where room_id = p_room_id and user_id = v_uid) then return; end if;
  if r.status <> 'lobby' then raise exception 'game_started' using errcode = 'P0001'; end if;
  select min(s) into v_seat from generate_series(0, private.room_max_players(r.kind) - 1) s
   where not exists (select 1 from public.game_room_players where room_id = p_room_id and seat = s);
  if v_seat is null then raise exception 'game_full' using errcode = 'P0001'; end if;
  if r.stake > 0 then perform private.wallet_add(r.group_id, v_uid, -r.stake); end if;
  insert into public.game_room_players (room_id, user_id, seat) values (p_room_id, v_uid, v_seat);
  update public.game_rooms set updated_at = now() where id = p_room_id;
end;
$$;

create or replace function public.leave_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.game_rooms%rowtype;
  v_other uuid;
  v_next uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id for update;
  if r.id is null or not exists (select 1 from public.game_room_players where room_id = p_room_id and user_id = v_uid) then return; end if;
  if r.status = 'lobby' then
    if r.stake > 0 then perform private.wallet_add(r.group_id, v_uid, r.stake); end if;
    delete from public.game_room_players where room_id = p_room_id and user_id = v_uid;
    select user_id into v_next from public.game_room_players where room_id = p_room_id order by seat limit 1;
    if v_next is null then
      delete from public.game_rooms where id = p_room_id;
    elsif r.host_id = v_uid then
      update public.game_rooms set host_id = v_next, updated_at = now() where id = p_room_id;
    end if;
  elsif r.status = 'playing' and r.kind in ('tictactoe', 'connect4', 'rps', 'clash', 'penalty') then
    select user_id into v_other from public.game_room_players where room_id = p_room_id and user_id <> v_uid limit 1;
    perform private.room_finish(p_room_id, v_other, r.state || jsonb_build_object('forfeit', v_uid));
  end if;
end;
$$;

create or replace function public.start_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.game_rooms%rowtype;
  v_ids jsonb;
  v_pos jsonb := '{}'::jsonb;
  v_rolls jsonb := '{}'::jsonb;
  p record;
  v_n integer;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id for update;
  if r.id is null or not private.is_group_member(r.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if r.host_id <> v_uid then raise exception 'not_allowed' using errcode = '42501'; end if;
  if r.status <> 'lobby' then raise exception 'game_started' using errcode = 'P0001'; end if;
  select count(*) into v_n from public.game_room_players where room_id = p_room_id;
  if v_n < private.room_min_players(r.kind) then raise exception 'not_enough_players' using errcode = 'P0001'; end if;

  if r.kind = 'tictactoe' then
    update public.game_rooms set status = 'playing', state = jsonb_build_object('board', '.........', 'turn', 0), updated_at = now() where id = p_room_id;
  elsif r.kind = 'connect4' then
    update public.game_rooms set status = 'playing', state = jsonb_build_object('board', repeat('.', 42), 'turn', 0), updated_at = now() where id = p_room_id;
  elsif r.kind = 'rps' then
    update public.game_rooms set status = 'playing',
      state = jsonb_build_object('round', 1, 'wins', jsonb_build_array(0, 0), 'target', 2, 'moved', '[]'::jsonb),
      secret = jsonb_build_object('choices', '{}'::jsonb), updated_at = now() where id = p_room_id;
  elsif r.kind = 'clash' then
    update public.game_rooms set status = 'playing',
      state = jsonb_build_object('round', 1, 'hp', jsonb_build_array(100, 100), 'heals', jsonb_build_array(2, 2), 'moved', '[]'::jsonb),
      secret = jsonb_build_object('choices', '{}'::jsonb), updated_at = now() where id = p_room_id;
    update public.game_room_players set score = 100 where room_id = p_room_id;
  elsif r.kind = 'penalty' then
    update public.game_rooms set status = 'playing',
      state = jsonb_build_object('kick', 0, 'scores', jsonb_build_array(0, 0), 'moved', '[]'::jsonb, 'hist', '[]'::jsonb),
      secret = jsonb_build_object('choices', '{}'::jsonb), updated_at = now() where id = p_room_id;
  elsif r.kind = 'race' then
    for p in select seat from public.game_room_players where room_id = p_room_id loop
      v_pos := v_pos || jsonb_build_object(p.seat::text, 0);
    end loop;
    update public.game_rooms set status = 'playing',
      state = jsonb_build_object('round', 1, 'goal', 30, 'pos', v_pos, 'used', '{}'::jsonb, 'answered', '[]'::jsonb, 'last', null,
                                 'phase', 'pick', 'until', now() + interval '10 seconds'),
      secret = jsonb_build_object('gears', '{}'::jsonb), updated_at = now() where id = p_room_id;
  elsif r.kind = 'pot' then
    for p in select user_id from public.game_room_players where room_id = p_room_id loop
      v_rolls := v_rolls || jsonb_build_object(p.user_id::text, jsonb_build_object('d', jsonb_build_array(private.roll_die(), private.roll_die()), 'rerolled', false, 'decided', false));
    end loop;
    update public.game_rooms set status = 'playing',
      state = jsonb_build_object('phase', 'roll', 'stake', r.stake, 'pot', r.stake * v_n, 'answered', '[]'::jsonb, 'until', now() + interval '20 seconds'),
      secret = jsonb_build_object('rolls', v_rolls), updated_at = now() where id = p_room_id;
  elsif r.kind in ('likely', 'rather') then
    select jsonb_agg(id) into v_ids from (select id from public.vibe_prompts where kind = r.kind order by random() limit 6) q;
    update public.game_rooms set status = 'playing', secret = jsonb_build_object('ids', v_ids, 'answers', '{}'::jsonb), updated_at = now() where id = p_room_id;
    perform private.vibe_open(p_room_id, 0);
  else
    select jsonb_agg(id) into v_ids from (select id from public.trivia_questions
       where (r.kind = 'emoji' and topic = 'Emoji') or (r.kind = 'trivia' and topic <> 'Emoji') order by random() limit 8) q;
    update public.game_rooms set status = 'playing', secret = jsonb_build_object('ids', v_ids, 'answers', '{}'::jsonb), updated_at = now() where id = p_room_id;
    perform private.trivia_open(p_room_id, 0);
  end if;
end;
$$;

create or replace function public.delete_room(p_room_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.game_rooms%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id for update;
  if r.id is null then return; end if;
  if r.host_id <> v_uid and not private.is_group_manager(r.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if r.kind = 'pot' and r.status = 'playing' then raise exception 'game_started' using errcode = 'P0001'; end if;
  if r.kind = 'pot' and r.status = 'lobby' then perform private.pot_refund(p_room_id); end if;
  delete from public.game_rooms where id = p_room_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Moves
--   tictactoe: cell 0-8      connect4: column 0-6     rps: 1 rock 2 paper 3 scissors
--   clash: 1 strike 2 heavy 3 guard 4 heal             penalty: 0 left 1 middle 2 right (shooter aims, keeper dives)
--   race: 1 cruise 2 boost 3 nitro (once)              trivia / emoji: option 0-3
--   likely: the seat number you vote for                rather: 0 or 1
--   pot: 0 hold your dice, 1 re-roll (final)
-- ---------------------------------------------------------------------------
create or replace function public.make_move(p_room_id uuid, p_move integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.game_rooms%rowtype;
  me public.game_room_players%rowtype;
  v_board text; v_mark text; v_line integer[]; v_row integer; v_i integer;
  v_choices jsonb; v_c0 integer; v_c1 integer; v_res integer; v_wins jsonb; v_w0 integer; v_w1 integer; v_round integer; v_win_seat integer; v_win uuid;
  -- clash
  v_hp0 integer; v_hp1 integer; v_heals jsonb; v_d0 integer := 0; v_d1 integer := 0; v_h0 integer := 0; v_h1 integer := 0; v_base integer; v_hp jsonb;
  -- penalty
  v_kick integer; v_shooter integer; v_shot integer; v_dive integer; v_result text; v_scores jsonb; v_hist jsonb; v_s0 integer; v_s1 integer; v_done integer;
  v_roll jsonb;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id for update;
  if r.id is null or not private.is_group_member(r.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  select * into me from public.game_room_players where room_id = p_room_id and user_id = v_uid;
  if me.user_id is null then raise exception 'not_in_game' using errcode = '42501'; end if;
  if r.kind in ('trivia', 'emoji', 'likely', 'rather', 'race', 'pot') then
    perform private.room_tick(p_room_id);
    select * into r from public.game_rooms where id = p_room_id;
  end if;
  if r.status <> 'playing' then raise exception 'game_over' using errcode = 'P0001'; end if;
  if p_move is null then raise exception 'invalid_move' using errcode = '22023'; end if;

  -- Tic-Tac-Toe ------------------------------------------------------------
  if r.kind = 'tictactoe' then
    if (r.state ->> 'turn')::integer <> me.seat then raise exception 'not_your_turn' using errcode = 'P0001'; end if;
    if p_move < 0 or p_move > 8 then raise exception 'invalid_move' using errcode = '22023'; end if;
    v_board := r.state ->> 'board';
    if substr(v_board, p_move + 1, 1) <> '.' then raise exception 'cell_taken' using errcode = 'P0001'; end if;
    v_mark := case when me.seat = 0 then 'X' else 'O' end;
    v_board := overlay(v_board placing v_mark from p_move + 1 for 1);
    v_line := private.ttt_line(v_board, v_mark);
    if v_line is not null then
      update public.game_room_players set score = 1 where room_id = p_room_id and user_id = v_uid;
      perform private.room_finish(p_room_id, v_uid, jsonb_build_object('board', v_board, 'turn', me.seat, 'last', p_move, 'line', to_jsonb(v_line)));
    elsif position('.' in v_board) = 0 then
      perform private.room_finish(p_room_id, null, jsonb_build_object('board', v_board, 'turn', me.seat, 'last', p_move, 'draw', true));
    else
      update public.game_rooms set state = jsonb_build_object('board', v_board, 'turn', 1 - me.seat, 'last', p_move), updated_at = now() where id = p_room_id;
    end if;

  -- Connect 4 --------------------------------------------------------------
  elsif r.kind = 'connect4' then
    if (r.state ->> 'turn')::integer <> me.seat then raise exception 'not_your_turn' using errcode = 'P0001'; end if;
    if p_move < 0 or p_move > 6 then raise exception 'invalid_move' using errcode = '22023'; end if;
    v_board := r.state ->> 'board';
    v_row := null;
    for v_i in reverse 5..0 loop
      if substr(v_board, v_i*7 + p_move + 1, 1) = '.' then v_row := v_i; exit; end if;
    end loop;
    if v_row is null then raise exception 'column_full' using errcode = 'P0001'; end if;
    v_mark := case when me.seat = 0 then 'R' else 'Y' end;
    v_board := overlay(v_board placing v_mark from v_row*7 + p_move + 1 for 1);
    v_line := private.c4_line(v_board, v_mark);
    if v_line is not null then
      update public.game_room_players set score = 1 where room_id = p_room_id and user_id = v_uid;
      perform private.room_finish(p_room_id, v_uid, jsonb_build_object('board', v_board, 'turn', me.seat, 'last', v_row*7 + p_move, 'line', to_jsonb(v_line)));
    elsif position('.' in v_board) = 0 then
      perform private.room_finish(p_room_id, null, jsonb_build_object('board', v_board, 'turn', me.seat, 'last', v_row*7 + p_move, 'draw', true));
    else
      update public.game_rooms set state = jsonb_build_object('board', v_board, 'turn', 1 - me.seat, 'last', v_row*7 + p_move), updated_at = now() where id = p_room_id;
    end if;

  -- Rock-Paper-Scissors, first to 2 -------------------------------------------
  elsif r.kind = 'rps' then
    if p_move < 1 or p_move > 3 then raise exception 'invalid_move' using errcode = '22023'; end if;
    v_choices := coalesce(r.secret -> 'choices', '{}'::jsonb);
    if v_choices ? me.seat::text then raise exception 'already_moved' using errcode = 'P0001'; end if;
    v_choices := v_choices || jsonb_build_object(me.seat::text, p_move);
    if not (v_choices ? '0' and v_choices ? '1') then
      update public.game_rooms
         set secret = jsonb_set(r.secret, '{choices}', v_choices),
             state = jsonb_set(r.state, '{moved}', coalesce(r.state -> 'moved', '[]'::jsonb) || to_jsonb(me.seat)),
             updated_at = now()
       where id = p_room_id;
    else
      v_c0 := (v_choices ->> '0')::integer; v_c1 := (v_choices ->> '1')::integer;
      v_res := case when v_c0 = v_c1 then -1
                    when (v_c0 = 1 and v_c1 = 3) or (v_c0 = 2 and v_c1 = 1) or (v_c0 = 3 and v_c1 = 2) then 0
                    else 1 end;
      v_w0 := (r.state -> 'wins' ->> 0)::integer + case when v_res = 0 then 1 else 0 end;
      v_w1 := (r.state -> 'wins' ->> 1)::integer + case when v_res = 1 then 1 else 0 end;
      v_round := (r.state ->> 'round')::integer;
      v_wins := jsonb_build_array(v_w0, v_w1);
      update public.game_room_players set score = v_w0 where room_id = p_room_id and seat = 0;
      update public.game_room_players set score = v_w1 where room_id = p_room_id and seat = 1;
      if v_w0 >= 2 or v_w1 >= 2 then
        v_win_seat := case when v_w0 >= 2 then 0 else 1 end;
        select user_id into v_win from public.game_room_players where room_id = p_room_id and seat = v_win_seat;
        perform private.room_finish(p_room_id, v_win, jsonb_build_object('round', v_round, 'wins', v_wins, 'target', 2, 'moved', '[]'::jsonb,
          'last', jsonb_build_object('c', jsonb_build_array(v_c0, v_c1), 'result', v_res)));
      else
        update public.game_rooms
           set secret = jsonb_set(r.secret, '{choices}', '{}'::jsonb),
               state = jsonb_build_object('round', v_round + 1, 'wins', v_wins, 'target', 2, 'moved', '[]'::jsonb,
                         'last', jsonb_build_object('c', jsonb_build_array(v_c0, v_c1), 'result', v_res)),
               updated_at = now()
         where id = p_room_id;
      end if;
    end if;

  -- Clash: strike beats heavy (it interrupts), heavy beats guard (it breaks through), guard beats strike (and counters) ------
  elsif r.kind = 'clash' then
    if p_move < 1 or p_move > 4 then raise exception 'invalid_move' using errcode = '22023'; end if;
    if p_move = 4 and (r.state -> 'heals' ->> me.seat)::integer <= 0 then raise exception 'invalid_move' using errcode = '22023'; end if;
    v_choices := coalesce(r.secret -> 'choices', '{}'::jsonb);
    if v_choices ? me.seat::text then raise exception 'already_moved' using errcode = 'P0001'; end if;
    v_choices := v_choices || jsonb_build_object(me.seat::text, p_move);
    if not (v_choices ? '0' and v_choices ? '1') then
      update public.game_rooms
         set secret = jsonb_set(r.secret, '{choices}', v_choices),
             state = jsonb_set(r.state, '{moved}', coalesce(r.state -> 'moved', '[]'::jsonb) || to_jsonb(me.seat)),
             updated_at = now()
       where id = p_room_id;
    else
      v_c0 := (v_choices ->> '0')::integer; v_c1 := (v_choices ->> '1')::integer;
      v_hp0 := (r.state -> 'hp' ->> 0)::integer; v_hp1 := (r.state -> 'hp' ->> 1)::integer;
      v_heals := r.state -> 'heals';
      -- seat 0 attacks seat 1
      if v_c0 = 1 then
        v_base := 14 + floor(random() * 9)::integer;
        if v_c1 = 3 then v_d1 := v_d1 + round(v_base * 0.25)::integer; v_d0 := v_d0 + 8; else v_d1 := v_d1 + v_base; end if;
      elsif v_c0 = 2 and v_c1 <> 1 then
        v_d1 := v_d1 + 28 + floor(random() * 13)::integer;
      end if;
      -- seat 1 attacks seat 0
      if v_c1 = 1 then
        v_base := 14 + floor(random() * 9)::integer;
        if v_c0 = 3 then v_d0 := v_d0 + round(v_base * 0.25)::integer; v_d1 := v_d1 + 8; else v_d0 := v_d0 + v_base; end if;
      elsif v_c1 = 2 and v_c0 <> 1 then
        v_d0 := v_d0 + 28 + floor(random() * 13)::integer;
      end if;
      if v_c0 = 4 then v_h0 := 18 + floor(random() * 7)::integer; v_heals := jsonb_set(v_heals, '{0}', to_jsonb((v_heals ->> 0)::integer - 1)); end if;
      if v_c1 = 4 then v_h1 := 18 + floor(random() * 7)::integer; v_heals := jsonb_set(v_heals, '{1}', to_jsonb((v_heals ->> 1)::integer - 1)); end if;
      v_hp0 := least(100, v_hp0 - v_d0 + v_h0);
      v_hp1 := least(100, v_hp1 - v_d1 + v_h1);
      v_round := (r.state ->> 'round')::integer;
      v_hp := jsonb_build_array(greatest(v_hp0, 0), greatest(v_hp1, 0));
      update public.game_room_players set score = greatest(v_hp0, 0) where room_id = p_room_id and seat = 0;
      update public.game_room_players set score = greatest(v_hp1, 0) where room_id = p_room_id and seat = 1;
      if v_hp0 <= 0 or v_hp1 <= 0 or v_round >= 12 then
        v_win_seat := case when v_hp0 > v_hp1 then 0 when v_hp1 > v_hp0 then 1 end;
        if v_win_seat is not null then select user_id into v_win from public.game_room_players where room_id = p_room_id and seat = v_win_seat; else v_win := null; end if;
        perform private.room_finish(p_room_id, v_win, jsonb_build_object('round', v_round, 'hp', v_hp, 'heals', v_heals, 'moved', '[]'::jsonb,
          'last', jsonb_build_object('m', jsonb_build_array(v_c0, v_c1), 'dmg', jsonb_build_array(v_d0, v_d1), 'heal', jsonb_build_array(v_h0, v_h1))));
      else
        update public.game_rooms
           set secret = jsonb_set(r.secret, '{choices}', '{}'::jsonb),
               state = jsonb_build_object('round', v_round + 1, 'hp', v_hp, 'heals', v_heals, 'moved', '[]'::jsonb,
                         'last', jsonb_build_object('m', jsonb_build_array(v_c0, v_c1), 'dmg', jsonb_build_array(v_d0, v_d1), 'heal', jsonb_build_array(v_h0, v_h1))),
               updated_at = now()
         where id = p_room_id;
      end if;
    end if;

  -- Penalty shootout ----------------------------------------------------------
  elsif r.kind = 'penalty' then
    if p_move < 0 or p_move > 2 then raise exception 'invalid_move' using errcode = '22023'; end if;
    v_choices := coalesce(r.secret -> 'choices', '{}'::jsonb);
    if v_choices ? me.seat::text then raise exception 'already_moved' using errcode = 'P0001'; end if;
    v_choices := v_choices || jsonb_build_object(me.seat::text, p_move);
    if not (v_choices ? '0' and v_choices ? '1') then
      update public.game_rooms
         set secret = jsonb_set(r.secret, '{choices}', v_choices),
             state = jsonb_set(r.state, '{moved}', coalesce(r.state -> 'moved', '[]'::jsonb) || to_jsonb(me.seat)),
             updated_at = now()
       where id = p_room_id;
    else
      v_kick := (r.state ->> 'kick')::integer;
      v_shooter := v_kick % 2;
      v_shot := (v_choices ->> v_shooter::text)::integer;
      v_dive := (v_choices ->> (1 - v_shooter)::text)::integer;
      v_result := case when random() < 0.12 then 'missed' when v_shot = v_dive then 'saved' else 'goal' end;
      v_s0 := (r.state -> 'scores' ->> 0)::integer + case when v_result = 'goal' and v_shooter = 0 then 1 else 0 end;
      v_s1 := (r.state -> 'scores' ->> 1)::integer + case when v_result = 'goal' and v_shooter = 1 then 1 else 0 end;
      v_scores := jsonb_build_array(v_s0, v_s1);
      v_hist := coalesce(r.state -> 'hist', '[]'::jsonb) || jsonb_build_object('k', v_kick, 's', v_shooter, 'shot', v_shot, 'dive', v_dive, 'r', v_result);
      v_done := v_kick + 1;
      update public.game_room_players set score = v_s0 where room_id = p_room_id and seat = 0;
      update public.game_room_players set score = v_s1 where room_id = p_room_id and seat = 1;
      if (v_done >= 10 and v_done % 2 = 0 and v_s0 <> v_s1) or v_done >= 20 then
        v_win_seat := case when v_s0 > v_s1 then 0 when v_s1 > v_s0 then 1 end;
        if v_win_seat is not null then select user_id into v_win from public.game_room_players where room_id = p_room_id and seat = v_win_seat; else v_win := null; end if;
        perform private.room_finish(p_room_id, v_win, jsonb_build_object('kick', v_done, 'scores', v_scores, 'moved', '[]'::jsonb, 'hist', v_hist));
      else
        update public.game_rooms
           set secret = jsonb_set(r.secret, '{choices}', '{}'::jsonb),
               state = jsonb_build_object('kick', v_done, 'scores', v_scores, 'moved', '[]'::jsonb, 'hist', v_hist),
               updated_at = now()
         where id = p_room_id;
      end if;
    end if;

  -- Street race ---------------------------------------------------------------
  elsif r.kind = 'race' then
    if p_move < 1 or p_move > 3 then raise exception 'invalid_move' using errcode = '22023'; end if;
    if p_move = 3 and (r.state -> 'used') ? me.seat::text then raise exception 'invalid_move' using errcode = '22023'; end if;
    if (r.secret -> 'gears') ? v_uid::text then raise exception 'already_moved' using errcode = 'P0001'; end if;
    update public.game_rooms
       set secret = jsonb_set(r.secret, '{gears}', coalesce(r.secret -> 'gears', '{}'::jsonb) || jsonb_build_object(v_uid::text, p_move)),
           state = jsonb_set(r.state, '{answered}', coalesce(r.state -> 'answered', '[]'::jsonb) || to_jsonb(v_uid)),
           updated_at = now()
     where id = p_room_id;
    perform private.race_tick(p_room_id);

  -- Risk It -------------------------------------------------------------------
  elsif r.kind = 'pot' then
    if p_move not in (0, 1) then raise exception 'invalid_move' using errcode = '22023'; end if;
    v_roll := r.secret -> 'rolls' -> v_uid::text;
    if coalesce((v_roll ->> 'decided')::boolean, false) then raise exception 'already_moved' using errcode = 'P0001'; end if;
    if p_move = 1 then
      v_roll := jsonb_build_object('d', jsonb_build_array(private.roll_die(), private.roll_die()), 'rerolled', true, 'decided', true);
    else
      v_roll := v_roll || jsonb_build_object('decided', true);
    end if;
    update public.game_rooms
       set secret = jsonb_set(r.secret, array['rolls', v_uid::text], v_roll),
           state = jsonb_set(r.state, '{answered}', coalesce(r.state -> 'answered', '[]'::jsonb) || to_jsonb(v_uid)),
           updated_at = now()
     where id = p_room_id;
    perform private.pot_tick(p_room_id);

  -- Trivia race / emoji decode / most likely / would you rather -------------------
  else
    if r.state ->> 'phase' <> 'question' or now() >= (r.state ->> 'until')::timestamptz then
      raise exception 'too_late' using errcode = 'P0001';
    end if;
    if r.kind = 'likely' then
      if not exists (select 1 from public.game_room_players where room_id = p_room_id and seat = p_move) then raise exception 'invalid_move' using errcode = '22023'; end if;
    elsif r.kind = 'rather' then
      if p_move not in (0, 1) then raise exception 'invalid_move' using errcode = '22023'; end if;
    elsif p_move < 0 or p_move > 3 then
      raise exception 'invalid_move' using errcode = '22023';
    end if;
    if (r.secret -> 'answers') ? v_uid::text then raise exception 'already_moved' using errcode = 'P0001'; end if;
    update public.game_rooms
       set secret = jsonb_set(r.secret, '{answers}', coalesce(r.secret -> 'answers', '{}'::jsonb) || jsonb_build_object(v_uid::text, jsonb_build_object('c', p_move, 'at', now()))),
           state = jsonb_set(r.state, '{answered}', coalesce(r.state -> 'answered', '[]'::jsonb) || to_jsonb(v_uid)),
           updated_at = now()
     where id = p_room_id;
    perform private.room_tick(p_room_id);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Coins
-- ---------------------------------------------------------------------------
create or replace function public.my_wallet(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  w public.squad_wallets%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_member(p_group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  insert into public.squad_wallets (group_id, user_id) values (p_group_id, v_uid) on conflict do nothing;
  select * into w from public.squad_wallets where group_id = p_group_id and user_id = v_uid;
  return jsonb_build_object('balance', w.balance, 'can_claim', w.last_claim is distinct from (now() at time zone 'Africa/Kigali')::date);
end;
$$;

create or replace function public.claim_daily_coins(p_group_id uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_today date := (now() at time zone 'Africa/Kigali')::date;
  v_bal integer;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_member(p_group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  insert into public.squad_wallets (group_id, user_id) values (p_group_id, v_uid) on conflict do nothing;
  update public.squad_wallets set balance = balance + 50, last_claim = v_today
   where group_id = p_group_id and user_id = v_uid and last_claim is distinct from v_today
   returning balance into v_bal;
  if v_bal is null then raise exception 'already_claimed' using errcode = 'P0001'; end if;
  return v_bal;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------
create or replace function public.get_room(p_room_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  r public.game_rooms%rowtype;
  v_me public.game_room_players%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select * into r from public.game_rooms where id = p_room_id;
  if r.id is null or not private.is_group_member(r.group_id) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if r.kind in ('trivia', 'emoji', 'likely', 'rather', 'race', 'pot') and r.status = 'playing' then
    perform 1 from public.game_rooms where id = p_room_id for update;
    perform private.room_tick(p_room_id);
    select * into r from public.game_rooms where id = p_room_id;
  end if;
  select * into v_me from public.game_room_players where room_id = p_room_id and user_id = v_uid;
  return jsonb_build_object(
    'id', r.id, 'group_id', r.group_id, 'kind', r.kind, 'status', r.status, 'host_id', r.host_id, 'stake', r.stake,
    'winner_id', r.winner_id, 'max_players', private.room_max_players(r.kind), 'min_players', private.room_min_players(r.kind), 'state', r.state,
    'me_seat', v_me.seat, 'in_room', v_me.user_id is not null,
    'my_answer', case when r.kind in ('trivia', 'emoji', 'likely', 'rather') and r.status = 'playing' then (r.secret -> 'answers' -> v_uid::text ->> 'c')::integer end,
    'my_choice', case when r.status <> 'playing' or v_me.user_id is null then null
                      when r.kind in ('rps', 'clash', 'penalty') then (r.secret -> 'choices' ->> v_me.seat::text)::integer
                      when r.kind = 'race' then (r.secret -> 'gears' ->> v_uid::text)::integer end,
    'my_dice', case when r.kind = 'pot' and r.status = 'playing' and v_me.user_id is not null then r.secret -> 'rolls' -> v_uid::text end,
    'server_now', now(), 'created_at', r.created_at,
    'players', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', p.user_id, 'seat', p.seat, 'score', p.score,
                                          'name', coalesce(pr.display_name, 'Member'), 'avatar_path', pr.avatar_path) order by p.seat)
        from public.game_room_players p left join public.profiles pr on pr.id = p.user_id
       where p.room_id = p_room_id), '[]'::jsonb));
end;
$$;

create or replace function public.list_rooms(p_group_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_stale record;
  w public.squad_wallets%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_group_id is null or not private.is_group_member(p_group_id) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  -- rooms nobody touched for six hours are closed (coin stakes in an unstarted table are returned)
  for v_stale in select id, kind, status from public.game_rooms
                  where group_id = p_group_id and status <> 'finished' and updated_at < now() - interval '6 hours' for update loop
    if v_stale.kind = 'pot' and v_stale.status = 'playing' then
      perform private.pot_resolve(v_stale.id);
    else
      if v_stale.kind = 'pot' and v_stale.status = 'lobby' then perform private.pot_refund(v_stale.id); end if;
      update public.game_rooms set status = 'finished', finished_at = now(), state = state || '{"abandoned": true}'::jsonb where id = v_stale.id;
    end if;
  end loop;
  insert into public.squad_wallets (group_id, user_id) values (p_group_id, v_uid) on conflict do nothing;
  select * into w from public.squad_wallets where group_id = p_group_id and user_id = v_uid;
  return jsonb_build_object(
    'wallet', jsonb_build_object('balance', w.balance, 'can_claim', w.last_claim is distinct from (now() at time zone 'Africa/Kigali')::date),
    'rooms', coalesce((
      select jsonb_agg(x.j order by x.rank, x.created_at desc)
        from (
          select g.created_at, case when g.status = 'finished' then 1 else 0 end as rank,
            jsonb_build_object(
              'id', g.id, 'kind', g.kind, 'status', g.status, 'host_id', g.host_id, 'winner_id', g.winner_id, 'stake', g.stake,
              'created_at', g.created_at, 'max_players', private.room_max_players(g.kind),
              'abandoned', coalesce((g.state ->> 'abandoned')::boolean, false),
              'in_room', exists (select 1 from public.game_room_players p where p.room_id = g.id and p.user_id = v_uid),
              'players', coalesce((select jsonb_agg(jsonb_build_object('user_id', p.user_id, 'seat', p.seat, 'score', p.score,
                                       'name', coalesce(pr.display_name, 'Member')) order by p.seat)
                                     from public.game_room_players p left join public.profiles pr on pr.id = p.user_id
                                    where p.room_id = g.id), '[]'::jsonb)) as j
            from public.game_rooms g
           where g.group_id = p_group_id
             and (g.status <> 'finished' or g.id in (select id from public.game_rooms where group_id = p_group_id and status = 'finished' order by finished_at desc nulls last limit 5))
           order by case when g.status = 'finished' then 1 else 0 end, g.created_at desc
           limit 30
        ) x), '[]'::jsonb),
    'leaderboard', coalesce((
      select jsonb_agg(l.j order by l.wins desc, l.played asc, l.name)
        from (
          select count(*) filter (where r.winner_id = p.user_id) as wins, count(*) as played, coalesce(pr.display_name, 'Member') as name,
                 jsonb_build_object('user_id', p.user_id, 'name', coalesce(pr.display_name, 'Member'),
                                    'wins', count(*) filter (where r.winner_id = p.user_id), 'played', count(*)) as j
            from public.game_room_players p
            join public.game_rooms r on r.id = p.room_id and r.status = 'finished' and r.group_id = p_group_id
                                    and not coalesce((r.state ->> 'abandoned')::boolean, false)
            left join public.profiles pr on pr.id = p.user_id
           group by p.user_id, pr.display_name
           order by 1 desc, 2 asc limit 10
        ) l), '[]'::jsonb),
    'rich', coalesce((
      select jsonb_agg(jsonb_build_object('user_id', b.user_id, 'name', b.name, 'balance', b.balance) order by b.balance desc, b.name)
        from (select sw.user_id, sw.balance, coalesce(pr.display_name, 'Member') as name
                from public.squad_wallets sw left join public.profiles pr on pr.id = sw.user_id
               where sw.group_id = p_group_id and exists (select 1 from public.group_members gm where gm.group_id = p_group_id and gm.user_id = sw.user_id)
               order by sw.balance desc limit 10) b), '[]'::jsonb));
end;
$$;

revoke all on function public.create_room(uuid, text, integer), public.join_room(uuid), public.leave_room(uuid), public.start_room(uuid),
  public.delete_room(uuid), public.make_move(uuid, integer), public.get_room(uuid), public.list_rooms(uuid),
  public.my_wallet(uuid), public.claim_daily_coins(uuid) from public, anon;
grant execute on function public.create_room(uuid, text, integer), public.join_room(uuid), public.leave_room(uuid), public.start_room(uuid),
  public.delete_room(uuid), public.make_move(uuid, integer), public.get_room(uuid), public.list_rooms(uuid),
  public.my_wallet(uuid), public.claim_daily_coins(uuid) to authenticated;

commit;
