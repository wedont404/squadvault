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
