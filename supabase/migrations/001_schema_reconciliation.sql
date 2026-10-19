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
