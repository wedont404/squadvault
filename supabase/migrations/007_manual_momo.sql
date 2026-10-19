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
