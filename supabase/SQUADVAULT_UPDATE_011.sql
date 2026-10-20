-- SQUADVAULT UPDATE 011: confirm your email later (chat and photo sharing need a confirmed email; sign-up itself is instant). Needs UPDATES 007-010 first.
-- Paste the WHOLE file into Supabase -> SQL Editor -> Run. Safe to run again. Never deletes data. Existing accounts count as confirmed.

-- 011_email_verify.sql
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
