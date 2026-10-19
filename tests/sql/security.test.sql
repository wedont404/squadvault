-- Behavioural security tests for the SquadVault migrations. Run via tests/run-sql-tests.sh
-- (needs a scratch Postgres with supabase_stub.sql + migrations 001-008 applied). Everything runs in
-- one transaction that is rolled back at the end. Any failed assertion aborts with a message.
\set ON_ERROR_STOP on
begin;

create schema t;
grant usage on schema t to anon, authenticated, service_role;
create function t.expect_err(p_sql text, p_expected text) returns void language plpgsql as $$
declare ok boolean := false;
begin
  begin
    execute p_sql; ok := true;
  exception when others then
    if position(p_expected in sqlerrm) = 0 then
      raise exception 'WRONG ERROR for [%]: expected "%", got "%"', p_sql, p_expected, sqlerrm;
    end if;
  end;
  if ok then raise exception 'SHOULD HAVE FAILED with "%": %', p_expected, p_sql; end if;
end $$;
grant execute on function t.expect_err(text, text) to anon, authenticated, service_role;

insert into auth.users (id, email, raw_user_meta_data) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a@x.rw', '{"display_name":"Alice"}'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b@x.rw', '{"display_name":"Bob"}'),
  ('cccccccc-cccc-cccc-cccc-cccccccccccc', 'c@x.rw', '{}'),
  ('dddddddd-dddd-dddd-dddd-dddddddddddd', 'd@x.rw', '{}');

do $$ begin assert (select count(*) from public.profiles) = 4, 'profile trigger/backfill'; end $$;

-- ===== A creates a group and an event ====================================================
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.create_savings_group('  Kigali Squad ') as g \gset
select set_config('t.g', :'g', true);
do $$ begin
  assert (select role from public.group_members where group_id = current_setting('t.g')::uuid) = 'admin', 'creator is admin';
  assert (select name from public.savings_groups) = 'Kigali Squad', 'name trimmed';
end $$;
select public.create_event(:'g', 'Wedding', 100000, current_date + 30) as e \gset
select set_config('t.e', :'e', true);

-- direct writes are impossible from the browser role
select t.expect_err($$insert into public.savings_groups (name) values ('x')$$, 'permission denied');
select t.expect_err($$update public.group_members set role = 'admin'$$, 'permission denied');
select t.expect_err($$insert into public.contributions (event_id, user_id, amount, status) values (current_setting('t.e')::uuid, auth.uid(), 5000, 'paid')$$, 'permission denied');
select t.expect_err($$update public.contributions set status = 'paid'$$, 'permission denied');
select t.expect_err($$delete from public.events$$, 'permission denied');
select t.expect_err($$select * from public.invitation_codes$$, 'permission denied');
select t.expect_err($$select * from public.payment_events$$, 'permission denied');
select t.expect_err($$select public.payment_settle('r','intasend','e1','COMPLETE',1,'RWF',null,'{}')$$, 'permission denied');
select t.expect_err($$select public.payment_create_pending(auth.uid(), current_setting('t.e')::uuid, 5000, 'mtn_momo', 'SV-PAY-AAAAAAAAAAAAAAAAAAAAAAAA', false)$$, 'permission denied');

-- ===== invitations ==========================================================================
select public.create_invitation_code(:'g', 2, 7) ->> 'code' as code \gset
select set_config('t.code', :'code', true);
do $$ begin assert current_setting('t.code') ~ '^SV-[0-9A-F]{12}$', 'code format'; end $$;
reset role;
do $$
declare found int;
begin
  assert (select code_hash from public.invitation_codes) = encode(extensions.digest(current_setting('t.code'), 'sha256'), 'hex'), 'sha256 hash stored';
  select count(*) into found from public.invitation_codes ic where ic::text like '%' || current_setting('t.code') || '%';
  assert found = 0, 'plaintext code must not be stored';
end $$;

-- B joins
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
do $$ begin assert (select count(*) from public.savings_groups) = 0, 'non-member sees no groups'; end $$;
select t.expect_err($$select public.create_event(current_setting('t.g')::uuid, 'Hack', 5, null)$$, 'not_allowed');
select t.expect_err($$select public.create_invitation_code(current_setting('t.g')::uuid, 5, 7)$$, 'not_allowed');
select (public.join_group_with_code(:'code') ->> 'ok')::boolean as ok1 \gset
select (public.join_group_with_code(lower(:'code')) ->> 'already_member')::boolean as dup \gset
do $$ begin
  assert (select role from public.group_members where user_id = auth.uid()) = 'member', 'joiner is plain member';
  assert (select count(*) from public.savings_groups) = 1, 'member sees group';
end $$;
select set_config('t.jt', (:'ok1'::boolean and :'dup'::boolean)::text, true);
do $$ begin assert current_setting('t.jt')::boolean, 'join ok + second join reports already_member'; end $$;
reset role;
do $$ begin assert (select use_count from public.invitation_codes) = 1, 'second join must not consume a use'; end $$;

-- role escalation attempts by B
set local role authenticated;
select t.expect_err($$select public.set_member_role(current_setting('t.g')::uuid, auth.uid(), 'admin')$$, 'not_allowed');
select t.expect_err($$update public.group_members set role = 'admin' where user_id = auth.uid()$$, 'permission denied');
select t.expect_err($$select public.record_expense((select id from public.events limit 1), 1, 'steal', null)$$, 'not_allowed');
do $$ begin assert (select count(*) from public.profiles) = 2, 'B sees own + Alice profile only (C shares no group)'; end $$;

-- C: bad / used-up / expired / revoked codes, then rate limiting
reset role;
select set_config('request.jwt.claim.sub', 'cccccccc-cccc-cccc-cccc-cccccccccccc', true);
set local role authenticated;
do $$ begin
  assert (select count(*) from public.events) = 0 and (select count(*) from public.event_financials) = 0, 'outsider sees no events/financials';
  assert (select count(*) from public.profiles) = 1, 'outsider sees only self';
  assert public.join_group_with_code('SV-000000000000') ->> 'error' = 'invalid_code', 'unknown code';
  assert public.join_group_with_code('garbage') ->> 'error' = 'invalid_code', 'bad format';
end $$;
reset role;
-- exhaust: max_uses=2, use_count 1 -> C joins consuming #2, then a third user would be rejected
update public.invitation_codes set use_count = 2;
set local role authenticated;
do $$ begin assert public.join_group_with_code(current_setting('t.code')) ->> 'error' = 'invalid_code', 'exhausted code rejected'; end $$;
reset role;
update public.invitation_codes set use_count = 1, expires_at = now() - interval '1 minute';
set local role authenticated;
do $$ begin assert public.join_group_with_code(current_setting('t.code')) ->> 'error' = 'invalid_code', 'expired code rejected'; end $$;
reset role;
update public.invitation_codes set expires_at = now() + interval '1 day', revoked_at = now();
set local role authenticated;
do $$ begin assert public.join_group_with_code(current_setting('t.code')) ->> 'error' = 'invalid_code', 'revoked code rejected'; end $$;
do $$ declare i int; begin
  for i in 1..8 loop perform public.join_group_with_code('SV-FFFFFFFFFFFF'); end loop;
  assert public.join_group_with_code('SV-FFFFFFFFFFFF') ->> 'error' = 'rate_limited', 'rate limited after repeated failures';
end $$;
do $$ begin assert not exists (select 1 from public.group_members where user_id = auth.uid()), 'C never joined'; end $$;
reset role;

-- ===== payments (service role only) ========================================================
select set_config('t.b', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role service_role;
select public.payment_create_pending(current_setting('t.b')::uuid, current_setting('t.e')::uuid, 40000, 'mtn_momo', 'SV-PAY-111111111111111111111111', false) as c1 \gset
select t.expect_err($$select public.payment_create_pending('cccccccc-cccc-cccc-cccc-cccccccccccc'::uuid, current_setting('t.e')::uuid, 5000, 'mtn_momo', 'SV-PAY-222222222222222222222222', false)$$, 'not_allowed');
select t.expect_err($$select public.payment_create_pending(current_setting('t.b')::uuid, current_setting('t.e')::uuid, 50, 'mtn_momo', 'SV-PAY-333333333333333333333333', false)$$, 'invalid_amount');
select t.expect_err($$select public.payment_create_pending(current_setting('t.b')::uuid, current_setting('t.e')::uuid, 5000, 'paypal', 'SV-PAY-333333333333333333333333', false)$$, 'invalid_method');
reset role;

select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
do $$ begin
  assert (select paid_total from public.event_financials) = 0, 'pending is not paid';
  assert (select pending_total from public.event_financials) = 40000, 'pending tracked separately';
  assert (select available_funds from public.event_financials) = 0, 'pending never available';
end $$;
reset role;

set local role service_role;
do $$ declare r jsonb; begin
  r := public.payment_settle('SV-PAY-111111111111111111111111','intasend','INV1:COMPLETE','COMPLETE',39999,'RWF','INV1','{}');
  assert r ->> 'outcome' = 'amount_mismatch', 'wrong amount must not pay: ' || r::text;
  r := public.payment_settle('SV-PAY-111111111111111111111111','intasend','INV1:COMPLETE2','COMPLETE',40000,'USD','INV1','{}');
  assert r ->> 'outcome' = 'amount_mismatch', 'wrong currency must not pay';
  assert (select status from public.contributions) = 'pending', 'still pending after mismatches';
  r := public.payment_settle('SV-PAY-111111111111111111111111','simulated','sim:1:COMPLETE','COMPLETE',40000,'RWF',null,'{}');
  assert r ->> 'outcome' = 'provider_mismatch', 'simulated settle cannot pay a live contribution';
  perform public.payment_attach_provider('SV-PAY-111111111111111111111111', 'INV1');
  r := public.payment_settle('SV-PAY-111111111111111111111111','intasend','INV1:COMPLETE3','COMPLETE',40000,'RWF','OTHER','{}');
  assert r ->> 'outcome' = 'ref_mismatch' and (select status from public.contributions) = 'pending', 'a different provider invoice cannot settle this contribution';
  r := public.payment_settle('SV-PAY-111111111111111111111111','intasend','INV1:COMPLETE4','COMPLETE',40000,'RWF','INV1','{}');
  assert r ->> 'outcome' = 'paid', 'correct payment settles: ' || r::text;
  r := public.payment_settle('SV-PAY-111111111111111111111111','intasend','INV1:COMPLETE4','COMPLETE',40000,'RWF','INV1','{}');
  assert r ->> 'outcome' = 'duplicate', 'replayed callback is a no-op';
  r := public.payment_settle('SV-PAY-111111111111111111111111','intasend','INV1:COMPLETE5','COMPLETE',40000,'RWF','INV1','{}');
  assert r ->> 'outcome' = 'already_paid', 'second complete does not double count';
  r := public.payment_settle('SV-PAY-111111111111111111111111','intasend','INV1:FAILED','FAILED',40000,'RWF','INV1','{}');
  assert r ->> 'outcome' = 'ignored_paid', 'paid never reverts to failed';
  r := public.payment_settle('SV-PAY-UNKNOWN','intasend','X:COMPLETE','COMPLETE',1,'RWF','X','{}');
  assert r ->> 'outcome' = 'unknown_reference', 'unknown reference';
end $$;
reset role;

-- ===== money model + expenses ===============================================================
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
do $$ begin
  assert (select paid_total from public.event_financials) = 40000, 'paid counted once';
  assert (select remaining_amount from public.event_financials) = 60000, 'remaining';
  assert (select available_funds from public.event_financials) = 40000, 'available';
end $$;
select t.expect_err($$select public.record_expense(current_setting('t.e')::uuid, 40001, 'too much', null)$$, 'insufficient_funds');
select t.expect_err($$select public.record_expense(current_setting('t.e')::uuid, 100, 'bad receipt', 'https://evil.example/x.png')$$, 'invalid_receipt');
select t.expect_err($$select public.record_expense(current_setting('t.e')::uuid, 100, 'missing file', current_setting('t.g') || '/' || current_setting('t.e') || '/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.png')$$, 'invalid_receipt');
select public.record_expense(:'e', 15000, 'Venue deposit', null) as x1 \gset
do $$ begin assert (select available_funds from public.event_financials) = 25000, 'available after expense'; end $$;
select t.expect_err($$select public.record_expense(current_setting('t.e')::uuid, 25001, 'overspend', null)$$, 'insufficient_funds');
select public.update_expense(:'x1', 20000, 'Venue deposit (final)', null, false);
do $$ begin assert (select available_funds from public.event_financials) = 20000, 'available after edit'; end $$;

-- ===== storage policy helper + last-admin rules ====================================
reset role;
insert into storage.objects (bucket_id, name) values ('receipts', current_setting('t.g') || '/' || current_setting('t.e') || '/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.pdf');
set local role authenticated;
select public.record_expense(:'e', 1000, 'Printing', :'g' || '/' || :'e' || '/bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb.pdf');
do $$ begin
  assert private.receipt_upload_allowed(current_setting('t.g') || '/' || current_setting('t.e') || '/cccccccc-cccc-cccc-cccc-cccccccccccc.png'), 'manager may upload for own event';
  assert not private.receipt_upload_allowed('../../etc/passwd'), 'path traversal rejected';
  assert not private.receipt_upload_allowed(current_setting('t.g') || '/' || 'cccccccc-cccc-cccc-cccc-cccccccccccc' || '/cccccccc-cccc-cccc-cccc-cccccccccccc.png'), 'event must belong to the group';
end $$;
select t.expect_err($$select public.set_member_role(current_setting('t.g')::uuid, auth.uid(), 'member')$$, 'last_admin');
select t.expect_err($$select public.leave_group(current_setting('t.g')::uuid)$$, 'last_admin');
select public.set_member_role(:'g', current_setting('t.b')::uuid, 'treasurer');

-- treasurer B: can manage events/invites/expenses, cannot manage roles
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
select set_config('t.tre', (public.create_invitation_code(:'g', 3, 5) ->> 'code' is not null)::text, true);
do $$ begin assert current_setting('t.tre')::boolean, 'treasurer can invite'; end $$;
select t.expect_err($$select public.set_member_role(current_setting('t.g')::uuid, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid, 'member')$$, 'not_allowed');
select t.expect_err($$select public.remove_member(current_setting('t.g')::uuid, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'::uuid)$$, 'not_allowed');
select public.set_event_status(:'e', 'completed');
select t.expect_err($$select public.set_event_status(current_setting('t.e')::uuid, 'active')$$, 'not_allowed');  -- reopen = admin only
select t.expect_err($$select public.update_event(current_setting('t.e')::uuid, 'x', 5, null)$$, 'event_not_active');
do $$ begin assert (select count(*) from public.list_invitations(current_setting('t.g')::uuid)) = 2, 'invitation listing hides hashes, shows rows'; end $$;
reset role;

-- ===== upgrade path from the ORIGINAL schema ===============================================
do $$ begin
  assert not exists (select 1 from information_schema.columns where table_name = 'invitation_codes' and column_name = 'uses_count'), 'old uses_count column renamed, not duplicated';
  assert exists (select 1 from information_schema.columns where table_name = 'invitation_codes' and column_name = 'use_count'), 'use_count exists';
end $$;
-- a code created by the original function (hash of the LOWER-case code) still works
insert into public.invitation_codes (group_id, code_hash, created_by, max_uses, expires_at)
values (current_setting('t.g')::uuid, encode(extensions.digest(lower('SV-ABCDEF012345'), 'sha256'), 'hex'), 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 5, now() + interval '1 day');
select set_config('request.jwt.claim.sub', 'dddddddd-dddd-dddd-dddd-dddddddddddd', true);
set local role authenticated;
do $$ begin assert (public.join_group_with_code('sv-abcdef012345') ->> 'ok')::boolean, 'legacy-hashed code is redeemable'; end $$;
reset role;

-- ===== 007: manual MoMo collection ========================================================
reset role;
insert into auth.users (id, email, raw_user_meta_data) values ('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', 'e@x.rw', '{}');
do $$ begin
  assert (select role from public.group_members where group_id = current_setting('t.g')::uuid and user_id = 'dddddddd-dddd-dddd-dddd-dddddddddddd') = 'member', 'D is a plain member';
end $$;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.create_event(:'g', 'Manual Event', 100000, null) as m \gset
select set_config('t.m', :'m', true);
-- validation of payment details
select t.expect_err($$select public.set_event_payment_details(current_setting('t.m')::uuid, 'mtn_momo', 'number', '0721234567')$$, 'phone_network_mismatch');
select t.expect_err($$select public.set_event_payment_details(current_setting('t.m')::uuid, 'mtn_momo', 'number', '12345')$$, 'invalid_phone');
select t.expect_err($$select public.set_event_payment_details(current_setting('t.m')::uuid, 'mtn_momo', 'code', '12ab')$$, 'invalid_pay_code');
select t.expect_err($$select public.set_event_payment_details(current_setting('t.m')::uuid, 'visa', 'code', '123456')$$, 'invalid_method');
select t.expect_err($$select public.submit_payment_claim(current_setting('t.m')::uuid, 5000, null)$$, 'payment_details_missing');
select public.set_event_payment_details(:'m', 'mtn_momo', 'number', '+250 788-123-456', 'Pop Leader', 20000);
do $$ begin
  assert (select pay_account from public.events where id = current_setting('t.m')::uuid) = '0788123456', 'number normalised';
  assert (select expected_per_member from public.events where id = current_setting('t.m')::uuid) = 20000, 'expected saved';
end $$;
-- a plain member cannot set details, review, record or add members
select set_config('request.jwt.claim.sub', 'dddddddd-dddd-dddd-dddd-dddddddddddd', true);
select t.expect_err($$select public.set_event_payment_details(current_setting('t.m')::uuid, 'mtn_momo', 'code', '123456')$$, 'not_allowed');
select t.expect_err($$select public.record_manual_contribution(current_setting('t.m')::uuid, 'dddddddd-dddd-dddd-dddd-dddddddddddd'::uuid, 5000)$$, 'not_allowed');
select t.expect_err($$select public.add_member_by_email(current_setting('t.g')::uuid, 'e@x.rw')$$, 'not_allowed');
-- member claims; bounds and duplicates
select t.expect_err($$select public.submit_payment_claim(current_setting('t.m')::uuid, 50, null)$$, 'invalid_amount');
select t.expect_err($$select public.submit_payment_claim(current_setting('t.m')::uuid, 5000, 'bad id!')$$, 'invalid_reference');
select public.submit_payment_claim(:'m', 20000, 'mp2610abc123') as k1 \gset
select set_config('t.k1', :'k1', true);
select t.expect_err($$select public.submit_payment_claim(current_setting('t.m')::uuid, 20000, 'MP2610ABC123')$$, 'duplicate_reference');
do $$ begin
  assert (select status from public.contributions where id = current_setting('t.k1')::uuid) = 'pending', 'claim is pending';
  assert (select paid_total from public.event_financials where event_id = current_setting('t.m')::uuid) = 0, 'pending claim is NOT money';
end $$;
select t.expect_err($$select public.review_contribution(current_setting('t.k1')::uuid, 'paid')$$, 'not_allowed');  -- cannot self-approve
reset role;
-- outsider E cannot claim or see progress
select set_config('request.jwt.claim.sub', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', true);
set local role authenticated;
select t.expect_err($$select public.submit_payment_claim(current_setting('t.m')::uuid, 5000, null)$$, 'not_allowed');
select t.expect_err($$select * from public.event_member_progress(current_setting('t.m')::uuid)$$, 'not_allowed');
reset role;
-- treasurer B reviews
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.review_contribution(:'k1', 'paid') as r1 \gset
do $$ begin
  assert (select paid_total from public.event_financials where event_id = current_setting('t.m')::uuid) = 20000, 'confirmed claim counts';
end $$;
select t.expect_err($$select public.review_contribution(current_setting('t.k1')::uuid, 'failed')$$, 'invalid_transition');
select public.record_manual_contribution(:'m', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 20000, 'cash');
select public.record_manual_contribution(:'m', 'dddddddd-dddd-dddd-dddd-dddddddddddd', 10000, null) as k2 \gset
select t.expect_err($$select public.record_manual_contribution(current_setting('t.m')::uuid, 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'::uuid, 5000)$$, 'not_found');
select public.review_contribution(:'k2', 'refunded', 'wrong person');
do $$ begin
  assert (select paid_total from public.event_financials where event_id = current_setting('t.m')::uuid) = 40000, 'paid 20k+20k, refunded excluded';
  assert (select refunded_total from public.event_financials where event_id = current_setting('t.m')::uuid) = 10000, 'refund tracked';
end $$;
-- provider-verified rows cannot be reviewed here
reset role;
insert into public.contributions (event_id, user_id, amount, status, provider, payment_reference)
values (current_setting('t.m')::uuid, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 5000, 'pending', 'intasend', 'SV-PAY-ZZZZZZZZZZZZZZZZZZZZZZZZ') returning id as ip \gset
select set_config('t.ip', :'ip', true);
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select t.expect_err($$select public.review_contribution(current_setting('t.ip')::uuid, 'paid')$$, 'not_manual');
-- progress reflects everyone, hiding nobody
do $$ begin
  assert (select paid_total from public.event_member_progress(current_setting('t.m')::uuid) where user_id = 'dddddddd-dddd-dddd-dddd-dddddddddddd') = 20000, 'D: confirmed claim counts, refunded manual does not';
  assert (select count(*) from public.event_member_progress(current_setting('t.m')::uuid)) >= 3, 'all members listed (even with zero paid)';
  assert (select sum(paid_total) from public.event_member_progress(current_setting('t.m')::uuid)) = 40000, 'progress totals equal the event total';
end $$;
-- add / remove members
select t.expect_err($$select public.add_member_by_email(current_setting('t.g')::uuid, 'nobody@x.rw')$$, 'no_such_user');
select t.expect_err($$select public.add_member_by_email(current_setting('t.g')::uuid, 'not an email')$$, 'invalid_email');
select t.expect_err($$select public.add_member_by_email(current_setting('t.g')::uuid, 'D@X.RW')$$, 'already_member');
select public.add_member_by_email(:'g', ' E@x.rw ');
do $$ begin assert exists (select 1 from public.group_members where group_id = current_setting('t.g')::uuid and user_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee' and role = 'member'), 'E added as member'; end $$;
select public.remove_member(:'g', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee');
do $$ begin assert not exists (select 1 from public.group_members where group_id = current_setting('t.g')::uuid and user_id = 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'), 'E removed'; end $$;
-- a removed member's confirmed money still shows in progress (role null)
select public.remove_member(:'g', 'dddddddd-dddd-dddd-dddd-dddddddddddd');
do $$ begin assert (select role from public.event_member_progress(current_setting('t.m')::uuid) where user_id = 'dddddddd-dddd-dddd-dddd-dddddddddddd') is null, 'former member kept in progress with null role'; end $$;
-- clearing details
select public.set_event_payment_details(:'m', null, null, '', null, null);
do $$ begin assert (select pay_account from public.events where id = current_setting('t.m')::uuid) is null, 'details cleared'; end $$;
reset role;
-- anon cannot call any of them
set local role anon;
select t.expect_err($$select public.submit_payment_claim(gen_random_uuid(), 5000, null)$$, 'permission denied');
select t.expect_err($$select public.add_member_by_email(gen_random_uuid(), 'a@x.rw')$$, 'permission denied');
reset role;

-- ===== 008: automatic checking from forwarded MoMo SMS ===================================
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.add_member_by_email(:'g', 'e@x.rw');
select public.create_event(:'g', 'SMS Event', 500000, null) as s \gset
select set_config('t.s', :'s', true);
select public.set_event_payment_details(:'s', 'mtn_momo', 'number', '0788123456', 'Leader', null);
do $$ declare p record; begin
  select * into p from private.parse_momo_sms('You have received 20,000 RWF from John Doe (*****123) on your Mobile Money account at 2026-10-19 10:00:00. Your new balance: 70000 RWF. Financial Transaction Id: 123456789012.');
  assert p.is_receipt and p.amount = 20000 and p.txn_id = '123456789012' and p.payer_hint = 'John Doe', 'parses a typical received-money SMS: ' || coalesce(p::text, 'null');
  select * into p from private.parse_momo_sms('You have received RWF 5000.00 from Eric on your account. Transaction ID: 99887766.');
  assert p.is_receipt and p.amount = 5000 and p.txn_id = '99887766' and p.payer_hint = 'Eric', 'parses another wording: ' || coalesce(p::text, 'null');
  select * into p from private.parse_momo_sms('You have sent 5000 RWF to Aline. Transaction Id: 555555555.');
  assert not p.is_receipt, 'outgoing SMS is never a receipt';
  select * into p from private.parse_momo_sms('Your balance is 5000 RWF. Dial *182# for more.');
  assert not p.is_receipt, 'balance SMS is not a receipt';
  select * into p from private.parse_momo_sms('hello');
  assert not p.is_receipt, 'junk is not a receipt';
end $$;
select set_config('t.pv', public.preview_momo_sms('You have received 1,500 RWF from Marie. Financial Transaction Id: 424242424242.')::text, true);
do $$ begin assert (current_setting('t.pv')::jsonb ->> 'amount') = '1500' and (current_setting('t.pv')::jsonb ->> 'txn_id') = '424242424242', 'preview parses without storing'; end $$;
reset role;
-- members cannot manage collectors; treasurer can
select set_config('request.jwt.claim.sub', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', true);
set local role authenticated;
select t.expect_err($$select public.create_collector_token(current_setting('t.g')::uuid)$$, 'not_allowed');
select t.expect_err($$select public.collector_status(current_setting('t.g')::uuid)$$, 'not_allowed');
select t.expect_err($$select * from public.claim_match_hints(current_setting('t.s')::uuid)$$, 'not_allowed');
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.create_collector_token(:'g') as tok \gset
select set_config('t.tok', :'tok', true);
do $$ begin
  assert current_setting('t.tok') ~ '^SVC-[0-9A-F]{32}$', 'token format';
  assert (public.collector_status(current_setting('t.g')::uuid) ->> 'active')::boolean, 'collector active';
end $$;
reset role;
do $$ begin assert (select token_hash from public.momo_collectors where revoked_at is null) = encode(extensions.digest(current_setting('t.tok'), 'sha256'), 'hex'), 'only the hash is stored';
  assert (select count(*) from public.momo_collectors where token_hash like '%' || current_setting('t.tok') || '%') = 0, 'plain token not stored'; end $$;

-- anonymous phone app: bad token is rejected, good token stores receipts
set local role anon;
do $$ begin
  assert public.ingest_momo_sms('nope', 'You have received 100 RWF from X. Transaction Id: 1') ->> 'error' = 'invalid_token', 'bad token format';
  assert public.ingest_momo_sms('SVC-00000000000000000000000000000000', 'You have received 20000 RWF from X. Transaction Id: 100000000001') ->> 'error' = 'invalid_token', 'unknown token';
  assert public.ingest_momo_sms(current_setting('t.tok'), 'Your balance is 5000 RWF') ->> 'reason' = 'not_a_receipt', 'non-receipt ignored';
  assert (public.ingest_momo_sms(current_setting('t.tok'), 'You have received 20,000 RWF from Eric Kamanzi on your account. Financial Transaction Id: 111111111111.') ->> 'stored')::boolean, 'receipt 1 stored';
  assert public.ingest_momo_sms(current_setting('t.tok'), 'You have received 20,000 RWF from Eric Kamanzi on your account. Financial Transaction Id: 111111111111.') ->> 'reason' = 'duplicate', 'identical SMS is not stored twice';
  assert public.ingest_momo_sms(current_setting('t.tok'), 'You have received 20,000 RWF from Eric K on your account (resent). Financial Transaction Id: 111111111111.') ->> 'reason' = 'duplicate', 'same transaction ID is not stored twice';
end $$;
select t.expect_err($$select * from public.momo_receipts$$, 'permission denied');
select t.expect_err($$select * from public.momo_collectors$$, 'permission denied');
select t.expect_err($$select public.create_collector_token(gen_random_uuid())$$, 'permission denied');
select t.expect_err($$select public.claim_match_hints(gen_random_uuid())$$, 'permission denied');
reset role;

-- member E claims with the real transaction ID -> verified automatically (receipt arrived first)
select set_config('request.jwt.claim.sub', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', true);
set local role authenticated;
select public.submit_payment_claim(:'s', 20000, '111111111111') as k1 \gset
select public.submit_payment_claim(:'s', 20000, '222222222222') as k2 \gset
select public.submit_payment_claim(:'s', 5000, '333333333333') as k3 \gset
select public.submit_payment_claim(:'s', 7000, null) as k4 \gset
select public.submit_payment_claim(:'s', 9000, '999999999999') as k5 \gset
select set_config('t.k1', :'k1', true), set_config('t.k2', :'k2', true), set_config('t.k3', :'k3', true), set_config('t.k4', :'k4', true), set_config('t.k5', :'k5', true);
do $$ begin
  assert (select status from public.contributions where id = current_setting('t.k1')::uuid) = 'paid', 'receipt already there -> claim auto-verified';
  assert (select note from public.contributions where id = current_setting('t.k1')::uuid) = 'Auto-verified from MoMo SMS', 'note says auto-verified';
  assert (select status from public.contributions where id = current_setting('t.k2')::uuid) = 'pending', 'no receipt yet -> pending';
end $$;
reset role;
set local role anon;
do $$ begin
  assert (public.ingest_momo_sms(current_setting('t.tok'), 'You have received 20000 RWF from Eric. Financial Transaction Id: 222222222222.') ->> 'matched')::boolean, 'receipt arrives later -> waiting claim auto-verified';
  assert not (public.ingest_momo_sms(current_setting('t.tok'), 'You have received 4000 RWF from Eric. Financial Transaction Id: 333333333333.') ->> 'matched')::boolean, 'same ID but different amount is NOT auto-verified';
  assert not (public.ingest_momo_sms(current_setting('t.tok'), 'You have received 7000 RWF from Marie. Financial Transaction Id: 444444444444.') ->> 'matched')::boolean, 'claim without ID is never auto-verified';
end $$;
reset role;
do $$ begin
  assert (select status from public.contributions where id = current_setting('t.k2')::uuid) = 'paid', 'k2 paid';
  assert (select status from public.contributions where id = current_setting('t.k3')::uuid) = 'pending', 'k3 (amount differs) still pending';
  assert (select status from public.contributions where id = current_setting('t.k4')::uuid) = 'pending', 'k4 (no ID) still pending';
  assert (select status from public.contributions where id = current_setting('t.k5')::uuid) = 'pending', 'k5 (fake ID, no receipt) still pending';
end $$;

-- leader sees suggestions and can confirm against a specific SMS
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
do $$ begin
  assert (select strength from public.claim_match_hints(current_setting('t.s')::uuid) where contribution_id = current_setting('t.k3')::uuid) = 'id', 'same-ID hint';
  assert (select receipt_amount from public.claim_match_hints(current_setting('t.s')::uuid) where contribution_id = current_setting('t.k3')::uuid) = 4000, 'hint shows the SMS amount';
  assert (select strength from public.claim_match_hints(current_setting('t.s')::uuid) where contribution_id = current_setting('t.k4')::uuid) = 'amount', 'amount-only hint';
  assert not exists (select 1 from public.claim_match_hints(current_setting('t.s')::uuid) where contribution_id = current_setting('t.k5')::uuid), 'fake ID gets no hint';
end $$;
select receipt_id as rid3 from public.claim_match_hints(:'s') where contribution_id = current_setting('t.k3')::uuid limit 1 \gset
select receipt_id as rid4 from public.claim_match_hints(:'s') where contribution_id = current_setting('t.k4')::uuid limit 1 \gset
select set_config('t.rid3', :'rid3', true), set_config('t.rid4', :'rid4', true);
select t.expect_err($$select public.confirm_with_receipt(current_setting('t.k3')::uuid, current_setting('t.rid3')::uuid)$$, 'amount_mismatch');
select public.confirm_with_receipt(:'k4', :'rid4');
select t.expect_err($$select public.confirm_with_receipt(current_setting('t.k5')::uuid, current_setting('t.rid4')::uuid)$$, 'receipt_used');  -- a used SMS cannot confirm a second claim
do $$ begin
  assert (select status from public.contributions where id = current_setting('t.k4')::uuid) = 'paid', 'leader confirmed against the SMS';
  assert (select note from public.contributions where id = current_setting('t.k4')::uuid) = 'Confirmed against MoMo SMS', 'note';
  -- money model: 20000 + 20000 + 7000 are counted; the 5000 and 9000 claims are not
  assert (select paid_total from public.event_financials where event_id = current_setting('t.s')::uuid) = 47000, 'only verified claims count';
  assert (select pending_total from public.event_financials where event_id = current_setting('t.s')::uuid) = 14000, 'unverified claims stay pending';
end $$;
-- a receipt can only be used once
reset role;
select set_config('request.jwt.claim.sub', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', true);
set local role authenticated;
select public.submit_payment_claim(:'s', 7000, null) as k6 \gset
select set_config('t.k6', :'k6', true);
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select t.expect_err($$select public.confirm_with_receipt(current_setting('t.k6')::uuid, current_setting('t.rid4')::uuid)$$, 'receipt_used');
-- a leader cannot confirm their own claim (only the admin can)
select public.submit_payment_claim(:'s', 1000, null) as k7 \gset
select set_config('t.k7', :'k7', true);
select t.expect_err($$select public.review_contribution(current_setting('t.k7')::uuid, 'paid')$$, 'cannot_review_own');
select public.revoke_collector_token(:'g');
reset role;
set local role anon;
do $$ begin assert public.ingest_momo_sms(current_setting('t.tok'), 'You have received 1000 RWF from X. Transaction Id: 777777777') ->> 'error' = 'invalid_token', 'revoked token stops working'; end $$;
reset role;

-- anon has nothing
set local role anon;
select t.expect_err($$select * from public.events$$, 'permission denied');
select t.expect_err($$select * from public.event_financials$$, 'permission denied');
select t.expect_err($$select public.create_savings_group('x')$$, 'permission denied');
reset role;

rollback;
\echo ALL SQL SECURITY TESTS PASSED
