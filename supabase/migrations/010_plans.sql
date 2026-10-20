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
