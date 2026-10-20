-- ROLLBACK.sql: NOT part of supabase/migrations on purpose (the CLI must never run it automatically).
-- Reverts only objects that SquadVault migrations 003-006 ADDED. It never drops your five core
-- tables, and it never deletes rows from them. Run the blocks you need, in the SQL editor.

-- ---- 006 payment functions -------------------------------------------------
drop function if exists public.payment_create_pending(uuid, uuid, bigint, text, text, boolean);
drop function if exists public.payment_attach_provider(text, text);
drop function if exists public.payment_mark_failed(text, text);
drop function if exists public.payment_settle(text, text, text, text, bigint, text, text, jsonb);
drop function if exists public.payment_expire_stale(integer);

-- ---- 005 app functions -----------------------------------------------------
drop function if exists public.create_event(uuid, text, bigint, date);
drop function if exists public.update_event(uuid, text, bigint, date);
drop function if exists public.set_event_status(uuid, text);
drop function if exists public.set_member_role(uuid, uuid, text);
drop function if exists public.remove_member(uuid, uuid);
drop function if exists public.leave_group(uuid);
drop function if exists public.list_invitations(uuid);
drop function if exists public.record_expense(uuid, bigint, text, text);
drop function if exists public.update_expense(uuid, bigint, text, text, boolean);
drop function if exists public.update_profile(text, text, boolean);
drop function if exists private.valid_receipt_path(uuid, uuid, text);

-- ---- 004 storage (policies only; files in the buckets are NOT touched) ------
drop policy if exists squadvault_receipts_select on storage.objects;
drop policy if exists squadvault_receipts_insert on storage.objects;
drop policy if exists squadvault_avatars_insert on storage.objects;
drop policy if exists squadvault_avatars_update on storage.objects;
drop policy if exists squadvault_avatars_delete on storage.objects;
drop function if exists private.receipt_upload_allowed(text);
drop function if exists private.receipt_group_id(text);

-- ---- 003 view + policies ----------------------------------------------------
drop view if exists public.event_financials;
-- Policies on the core tables: dropping them leaves RLS enabled with NO policy,
-- which means "deny everything". That is the safe direction. Recreate by re-running 003.
-- alter table public.profiles drop column if exists avatar_path;   -- loses avatar paths only

-- ---- 002 invitation system (loses invitation history, not groups/members) ----
-- drop function if exists public.join_group_with_code(text);
-- drop function if exists public.create_invitation_code(uuid, integer, integer);
-- drop function if exists public.revoke_invitation_code(uuid);
-- drop table if exists public.invitation_attempts;
-- drop table if exists public.invitation_codes;

-- ---- 001 (new objects only) -------------------------------------------------
-- drop table if exists public.payment_events;
-- drop trigger if exists on_auth_user_created_squadvault on auth.users;
-- drop table if exists public.profiles;   -- loses display names only
-- alter table public.contributions
--   drop column if exists payment_method, drop column if exists provider, drop column if exists provider_ref,
--   drop column if exists is_simulated,   drop column if exists failure_reason, drop column if exists paid_at,
--   drop column if exists updated_at;
-- alter table public.expenses drop column if exists receipt_path, drop column if exists updated_at;

-- 007_manual_momo.sql (functions only; the new columns hold data, so they are kept)
drop function if exists public.set_event_payment_details(uuid, text, text, text, text, bigint);
drop function if exists public.submit_payment_claim(uuid, bigint, text);
drop function if exists public.review_contribution(uuid, text, text);
drop function if exists public.record_manual_contribution(uuid, uuid, bigint, text);
drop function if exists public.event_member_progress(uuid);
drop function if exists public.add_member_by_email(uuid, text);

-- 008_sms_verification.sql (the two tables hold records, so they are kept; functions are removed)
drop function if exists public.create_collector_token(uuid);
drop function if exists public.revoke_collector_token(uuid);
drop function if exists public.collector_status(uuid);
drop function if exists public.preview_momo_sms(text);
drop function if exists public.ingest_momo_sms(text, text);
drop function if exists public.claim_match_hints(uuid);
drop function if exists public.confirm_with_receipt(uuid, uuid);
drop function if exists private.parse_momo_sms(text);

-- 009_community.sql (tables hold members' chat, photos and game entries, so they are kept; functions are removed)
drop function if exists public.set_event_cover(uuid, text);
drop function if exists public.add_group_photo(uuid, text, text, uuid);
drop function if exists public.delete_group_photo(uuid);
drop function if exists public.toggle_photo_like(uuid);
drop function if exists public.list_group_photos(uuid, integer);
drop function if exists public.post_group_message(uuid, text);
drop function if exists public.delete_group_message(uuid);
drop function if exists public.create_game(uuid, text, text, text[]);
drop function if exists public.play_game(uuid, integer, bigint);
drop function if exists public.close_game(uuid, bigint);
drop function if exists public.delete_game(uuid);
drop function if exists public.list_games(uuid);
drop function if exists public.set_auto_by_name(uuid, boolean);
drop function if exists private.auto_match_group(uuid);

-- 010_plans.sql (tables hold plans and requests, so they are kept; limits stop being enforced)
drop trigger if exists squadvault_member_limit on public.group_members;
drop trigger if exists squadvault_event_limit on public.events;
drop trigger if exists squadvault_photo_limit on public.group_photos;
drop trigger if exists squadvault_autocheck_feature on public.momo_collectors;
drop function if exists private.enforce_member_limit();
drop function if exists private.enforce_event_limit();
drop function if exists private.enforce_photo_limit();
drop function if exists private.enforce_autocheck_feature();
drop function if exists public.plan_overview(uuid);
drop function if exists public.request_plan_upgrade(uuid, text, text, text);
drop function if exists public.cancel_plan_request(uuid);
drop function if exists public.owner_summary();
drop function if exists public.owner_list_plan_requests();
drop function if exists public.owner_decide_plan_request(uuid, boolean, text);
drop function if exists public.owner_set_plan(uuid, text, integer);

-- 011 email verification
drop trigger if exists squadvault_verified_chat on public.group_messages;
drop trigger if exists squadvault_verified_photos on public.group_photos;
drop function if exists private.require_verified_email();
drop function if exists public.confirm_my_email();
