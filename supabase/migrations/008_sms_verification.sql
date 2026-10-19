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
