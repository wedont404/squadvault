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
