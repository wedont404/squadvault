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
