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
