-- Behavioural security tests for the SquadVault migrations. Run via tests/run-sql-tests.sh
-- (needs a scratch Postgres with supabase_stub.sql + migrations 001-009 applied). Everything runs in
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
-- 011 gates chat and photos on a confirmed email; the older tests use verified people (the gate has its own block)
update public.profiles set email_verified_at = now();
create function t.autoverify() returns trigger language plpgsql as $$ begin new.email_verified_at := now(); return new; end $$;
create trigger t_autoverify before insert on public.profiles for each row execute function t.autoverify();

-- ===== A creates a group and an event ====================================================
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.create_savings_group('  Kigali Squad ') as g \gset
select set_config('t.g', :'g', true);
reset role;
-- the earlier tests exercise paid features, so this group is on Pro (plan limits have their own block below)
update public.savings_groups set plan = 'pro', plan_until = now() + interval '1 year' where id = :'g';
set local role authenticated;
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
  -- since 009 the code is kept in code_plain so leaders can read it again; redemption still uses the hash
  select count(*) into found from public.invitation_codes ic where ic.code_hash like '%' || current_setting('t.code') || '%';
  assert found = 0, 'the hash column never holds the plaintext';
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


-- ===== 009: visible invite codes, sender-name checks, pictures, chat, photos, games ===========
reset role;
insert into auth.users (id, email, raw_user_meta_data) values
  ('f0f0f0f0-f0f0-f0f0-f0f0-f0f0f0f0f0f0', 'f@x.rw', '{"display_name":"Fiona Mukamana"}'),
  ('90909090-9090-9090-9090-909090909090', 'g9@x.rw', '{"display_name":"Gad Habimana"}'),
  ('12121212-1212-1212-1212-121212121212', 'h@x.rw', '{"display_name":"Outsider Hh"}');
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.add_member_by_email(:'g', 'f@x.rw');
select public.add_member_by_email(:'g', 'g9@x.rw');
-- leader can read an active code again; members can't list; spent/revoked ones show no code
select public.create_invitation_code(:'g', 3, 5) as inv \gset
select set_config('t.inv', :'inv', true);
do $$ declare v_code text := (current_setting('t.inv')::jsonb ->> 'code'); begin
  assert (select l.code from public.list_invitations(current_setting('t.g')::uuid) l where l.id = (current_setting('t.inv')::jsonb ->> 'id')::uuid) = v_code, 'leader can read an active code again';
  assert (select count(*) from public.list_invitations(current_setting('t.g')::uuid) l where l.status <> 'active' and l.code is not null) = 0, 'only active codes are shown';
end $$;
select public.revoke_invitation_code((:'inv'::jsonb ->> 'id')::uuid);
do $$ begin assert (select l.code from public.list_invitations(current_setting('t.g')::uuid) l where l.id = (current_setting('t.inv')::jsonb ->> 'id')::uuid) is null, 'revoked code is hidden'; end $$;
reset role;
select set_config('request.jwt.claim.sub', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', true);
set local role authenticated;
select t.expect_err($$select * from public.list_invitations(current_setting('t.g')::uuid)$$, 'not_allowed');
reset role;

-- name scoring
do $$ begin
  assert private.name_score('Jean Paul Nshimiyimana', 'NSHIMIYIMANA Jean-Paul') = 100, 'order, case and hyphen do not matter';
  assert private.name_strong('Jean Paul', 'JEAN PAUL NSHIMIYIMANA'), 'every word of the shorter name present';
  assert not private.name_strong('Jean', 'Jean Bosco'), 'a shared first name alone is not strong';
  assert private.name_strong('Eric', 'ERIC'), 'identical single words are strong';
  assert private.name_score('Éric Kamanzi', 'eric kamanzi') = 100, 'accents are folded';
  assert private.name_score('Alice Uwase', 'Bob Habimana') = 0, 'different people score 0';
  assert private.name_score(null, 'Bob') = 0 and not private.name_strong('', 'x'), 'empty names never match';
end $$;

-- collector for the name tests
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.create_collector_token(:'g') as tok2 \gset
select set_config('t.tok2', :'tok2', true);
do $$ begin assert (public.collector_status(current_setting('t.g')::uuid) ->> 'auto_by_name')::boolean, 'name matching defaults to on'; end $$;
select public.create_event(:'g', 'Name Event', 900000, null) as n \gset
select set_config('t.n', :'n', true);
select public.set_event_payment_details(:'n', 'mtn_momo', 'number', '0788123456', 'Leader', null);
reset role;

-- F claims with the name MoMo shows, no transaction ID: waiting. The SMS arrives later -> auto-verified.
select set_config('request.jwt.claim.sub', 'f0f0f0f0-f0f0-f0f0-f0f0-f0f0f0f0f0f0', true);
set local role authenticated;
select public.submit_payment_claim(:'n', 15000, null, 'Fiona M. Mukamana') as f1 \gset
select set_config('t.f1', :'f1', true);
do $$ begin assert (select status from public.contributions where id = current_setting('t.f1')::uuid) = 'pending', 'nothing to compare with yet'; end $$;
reset role;
set local role anon;
do $$ begin
  assert not (public.ingest_momo_sms(current_setting('t.tok2'), 'You have received 15000 RWF from Someone Else on your account. Financial Transaction Id: 610000000001.') ->> 'matched')::boolean, 'right amount, wrong name: not auto-verified';
  assert (public.ingest_momo_sms(current_setting('t.tok2'), 'You have received 15000 RWF from FIONA MUKAMANA on your account. Financial Transaction Id: 610000000002.') ->> 'matched')::boolean, 'new SMS with the same name and amount re-checks the waiting claim';
end $$;
reset role;
do $$ begin
  assert (select status from public.contributions where id = current_setting('t.f1')::uuid) = 'paid', 'claim verified by sender name + amount';
  assert (select note from public.contributions where id = current_setting('t.f1')::uuid) like '%sender name and amount%', 'note says how';
end $$;

-- SMS first, claim second: matched at submit time (uses the profile name when no sender name is given)
set local role anon;
select public.ingest_momo_sms(current_setting('t.tok2'), 'You have received 8000 RWF from Gad Habimana on your account. Financial Transaction Id: 620000000001.');
reset role;
select set_config('request.jwt.claim.sub', '90909090-9090-9090-9090-909090909090', true);
set local role authenticated;
select public.submit_payment_claim(:'n', 8000, null) as g1 \gset
select set_config('t.g1', :'g1', true);
reset role;
do $$ begin assert (select status from public.contributions where id = current_setting('t.g1')::uuid) = 'paid', 'claim after the SMS is verified straight away'; end $$;

-- ambiguity: two claims with the same name and amount -> nobody is auto-verified, leader decides
select set_config('request.jwt.claim.sub', 'f0f0f0f0-f0f0-f0f0-f0f0-f0f0f0f0f0f0', true);
set local role authenticated;
select public.submit_payment_claim(:'n', 3000, null, 'Fiona Mukamana') as f2 \gset
select public.submit_payment_claim(:'n', 3000, null, 'Fiona Mukamana') as f3 \gset
select set_config('t.f2', :'f2', true), set_config('t.f3', :'f3', true);
reset role;
set local role anon;
do $$ begin assert not (public.ingest_momo_sms(current_setting('t.tok2'), 'You have received 3000 RWF from Fiona Mukamana. Financial Transaction Id: 630000000001.') ->> 'matched')::boolean, 'two identical claims: left for the leader'; end $$;
reset role;
do $$ begin assert (select count(*) from public.contributions where id in (current_setting('t.f2')::uuid, current_setting('t.f3')::uuid) and status = 'pending') = 2, 'both stay pending'; end $$;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
do $$ begin assert (select name_score from public.claim_match_hints(current_setting('t.n')::uuid) where contribution_id = current_setting('t.f2')::uuid limit 1) = 100, 'hint carries the name score'; end $$;
-- leader switches name matching off: nothing is auto-verified by name any more
select public.set_auto_by_name(:'g', false);
reset role;
select set_config('request.jwt.claim.sub', '90909090-9090-9090-9090-909090909090', true);
set local role authenticated;
select public.submit_payment_claim(:'n', 4100, null, 'Gad Habimana') as g2 \gset
select set_config('t.g2', :'g2', true);
reset role;
set local role anon;
do $$ begin assert not (public.ingest_momo_sms(current_setting('t.tok2'), 'You have received 4100 RWF from Gad Habimana. Financial Transaction Id: 640000000001.') ->> 'matched')::boolean, 'switch off: no automatic name matching'; end $$;
reset role;
do $$ begin assert (select status from public.contributions where id = current_setting('t.g2')::uuid) = 'pending', 'stays pending'; end $$;
select set_config('request.jwt.claim.sub', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', true);
set local role authenticated;
select t.expect_err($$select public.set_auto_by_name(current_setting('t.g')::uuid, true)$$, 'not_allowed');
reset role;
-- bad sender names are trimmed; very long ones cut
select set_config('request.jwt.claim.sub', '90909090-9090-9090-9090-909090909090', true);
set local role authenticated;
select public.submit_payment_claim(:'n', 1100, null, repeat('x', 200)) as g3 \gset
select set_config('t.g3', :'g3', true);
reset role;
do $$ begin assert (select char_length(sender_name) from public.contributions where id = current_setting('t.g3')::uuid) = 60, 'sender name capped at 60'; end $$;

-- ===== pictures, photo wall =================================================================
insert into storage.objects (bucket_id, name) values
  ('group-photos', current_setting('t.g') || '/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/11111111-1111-1111-1111-111111111111.jpg'),
  ('group-photos', current_setting('t.g') || '/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee/22222222-2222-2222-2222-222222222222.png'),
  ('group-photos', gen_random_uuid() || '/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/33333333-3333-3333-3333-333333333333.jpg');
select set_config('t.pX', (select name from storage.objects where name like '%33333333%'), true);
select set_config('t.pA', current_setting('t.g') || '/aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/11111111-1111-1111-1111-111111111111.jpg', true);
select set_config('t.pE', current_setting('t.g') || '/eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee/22222222-2222-2222-2222-222222222222.png', true);
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.set_event_cover(:'n', current_setting('t.pA'));
do $$ begin assert (select cover_path from public.events where id = current_setting('t.n')::uuid) = current_setting('t.pA'), 'leader sets an event picture'; end $$;
select t.expect_err($$select public.set_event_cover(current_setting('t.n')::uuid, 'not-a-path.jpg')$$, 'invalid_photo');
select t.expect_err($$select public.set_event_cover(current_setting('t.n')::uuid, current_setting('t.pX'))$$, 'invalid_photo');
select t.expect_err($$update public.events set cover_path = 'x' where id = current_setting('t.n')::uuid$$, 'permission denied');
reset role;
select set_config('request.jwt.claim.sub', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', true);
set local role authenticated;
select t.expect_err($$select public.set_event_cover(current_setting('t.n')::uuid, null)$$, 'not_allowed');
-- member adds a photo of their own, not someone else's folder
select t.expect_err($$select public.add_group_photo(current_setting('t.g')::uuid, current_setting('t.pA'), 'sneaky')$$, 'invalid_photo');
select public.add_group_photo(:'g', current_setting('t.pE'), 'Planning night', :'n') as ph \gset
select set_config('t.ph', :'ph', true);
select public.toggle_photo_like(:'ph');
do $$ begin
  assert (select like_count from public.list_group_photos(current_setting('t.g')::uuid) where id = current_setting('t.ph')::uuid) = 1, 'one heart';
  assert (select liked_by_me from public.list_group_photos(current_setting('t.g')::uuid) where id = current_setting('t.ph')::uuid), 'liked by me';
  assert (public.toggle_photo_like(current_setting('t.ph')::uuid) ->> 'liked')::boolean = false, 'tap again removes the heart';
end $$;
reset role;
select set_config('request.jwt.claim.sub', '12121212-1212-1212-1212-121212121212', true);
set local role authenticated;
select t.expect_err($$select * from public.list_group_photos(current_setting('t.g')::uuid)$$, 'not_allowed');
select t.expect_err($$select public.toggle_photo_like(current_setting('t.ph')::uuid)$$, 'not_allowed');
do $$ begin assert (select count(*) from public.group_photos) = 0, 'outsider sees no photos through RLS'; end $$;
reset role;
select set_config('request.jwt.claim.sub', '90909090-9090-9090-9090-909090909090', true);
set local role authenticated;
select t.expect_err($$select public.delete_group_photo(current_setting('t.ph')::uuid)$$, 'not_allowed');
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
do $$ begin assert public.delete_group_photo(current_setting('t.ph')::uuid) = current_setting('t.pE'), 'leader removes a photo and gets its path back'; end $$;
reset role;

-- ===== chat =================================================================================
select set_config('request.jwt.claim.sub', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', true);
set local role authenticated;
select public.post_group_message(:'g', '  Hello squad!  ') as m1 \gset
select set_config('t.m1', :'m1', true);
do $$ begin assert (select body from public.group_messages where id = current_setting('t.m1')::uuid) = 'Hello squad!', 'message is trimmed and stored'; end $$;
select t.expect_err($$select public.post_group_message(current_setting('t.g')::uuid, '   ')$$, 'invalid_message');
select t.expect_err($$select public.post_group_message(current_setting('t.g')::uuid, repeat('a', 1001))$$, 'invalid_message');
select t.expect_err($$insert into public.group_messages (group_id, user_id, body) values (current_setting('t.g')::uuid, auth.uid(), 'direct')$$, 'permission denied');
do $$ begin for i in 1..19 loop perform public.post_group_message(current_setting('t.g')::uuid, 'spam ' || i); end loop; end $$;
select t.expect_err($$select public.post_group_message(current_setting('t.g')::uuid, 'one too many')$$, 'rate_limited');
reset role;
select set_config('request.jwt.claim.sub', '12121212-1212-1212-1212-121212121212', true);
set local role authenticated;
select t.expect_err($$select public.post_group_message(current_setting('t.g')::uuid, 'let me in')$$, 'not_allowed');
do $$ begin assert (select count(*) from public.group_messages) = 0, 'outsider reads no chat'; end $$;
reset role;
select set_config('request.jwt.claim.sub', '90909090-9090-9090-9090-909090909090', true);
set local role authenticated;
select t.expect_err($$select public.delete_group_message(current_setting('t.m1')::uuid)$$, 'not_allowed');
do $$ begin assert (select count(*) from public.group_messages) = 20, 'a member reads the chat'; end $$;
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.delete_group_message(:'m1');
do $$ begin assert not exists (select 1 from public.group_messages where id = current_setting('t.m1')::uuid), 'leader can remove a message'; end $$;
reset role;

-- ===== games ================================================================================
select set_config('request.jwt.claim.sub', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', true);
set local role authenticated;
select public.create_game(:'g', 'poll', 'Where do we celebrate?', array['Kigali', 'Musanze', ' ', 'Rubavu']) as po \gset
select public.create_game(:'g', 'guess', 'How much will we save by Friday?') as gu \gset
select set_config('t.po', :'po', true), set_config('t.gu', :'gu', true);
select t.expect_err($$select public.create_game(current_setting('t.g')::uuid, 'poll', 'Only one option', array['a'])$$, 'invalid_game');
select t.expect_err($$select public.create_game(current_setting('t.g')::uuid, 'dice', 'Roll the dice please')$$, 'invalid_game');
select t.expect_err($$select * from public.group_games$$, 'permission denied');
select public.play_game(:'po', 2, null);
select public.play_game(:'po', 3, null);   -- changed my mind: still one vote
select public.play_game(:'gu', null, 480000);
select t.expect_err($$select public.play_game(current_setting('t.po')::uuid, 9, null)$$, 'invalid_game');
do $$ declare j jsonb; begin
  select x into j from jsonb_array_elements(public.list_games(current_setting('t.g')::uuid)) x where x ->> 'id' = current_setting('t.po');
  assert (j -> 'options') = '["Kigali","Musanze","Rubavu"]'::jsonb, 'blank options dropped';
  assert (j -> 'counts') = '[0,0,1]'::jsonb and (j ->> 'my_choice') = '3', 'one vote, the latest choice';
end $$;
reset role;
select set_config('request.jwt.claim.sub', '90909090-9090-9090-9090-909090909090', true);
set local role authenticated;
select public.play_game(:'gu', null, 500000);
do $$ declare j jsonb; begin
  select x into j from jsonb_array_elements(public.list_games(current_setting('t.g')::uuid)) x where x ->> 'id' = current_setting('t.gu');
  assert (j ->> 'entries') = '2' and (j -> 'top') = 'null'::jsonb, 'other guesses stay hidden while open';
  assert (j ->> 'my_guess') = '500000', 'I can see my own guess';
end $$;
select t.expect_err($$select public.close_game(current_setting('t.gu')::uuid, 1)$$, 'not_allowed');
reset role;
select set_config('request.jwt.claim.sub', 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee', true);
set local role authenticated;
select t.expect_err($$select public.close_game(current_setting('t.gu')::uuid, null)$$, 'invalid_game');
select public.close_game(:'gu', 495000);
select t.expect_err($$select public.play_game(current_setting('t.gu')::uuid, null, 1)$$, 'game_closed');
do $$ declare j jsonb; begin
  select x into j from jsonb_array_elements(public.list_games(current_setting('t.g')::uuid)) x where x ->> 'id' = current_setting('t.gu');
  assert (j -> 'top' -> 0 ->> 'user_id') = '90909090-9090-9090-9090-909090909090' and (j -> 'top' -> 0 ->> 'diff') = '5000', 'closest guess wins';
end $$;
reset role;
select set_config('request.jwt.claim.sub', '12121212-1212-1212-1212-121212121212', true);
set local role authenticated;
select t.expect_err($$select public.list_games(current_setting('t.g')::uuid)$$, 'not_allowed');
select t.expect_err($$select public.play_game(current_setting('t.po')::uuid, 1, null)$$, 'not_allowed');
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.delete_game(:'po');
do $$ begin assert (select count(*) from jsonb_array_elements(public.list_games(current_setting('t.g')::uuid))) = 1, 'leader can remove a game'; end $$;
reset role;
set local role anon;
select t.expect_err($$select public.list_games(gen_random_uuid())$$, 'permission denied');
select t.expect_err($$select public.post_group_message(gen_random_uuid(), 'x')$$, 'permission denied');
select t.expect_err($$select * from public.group_messages$$, 'permission denied');
reset role;


-- ===== 010: plans, limits, upgrade requests ====================================================
reset role;
insert into auth.users (id, email, raw_user_meta_data) values
  ('0a0a0a0a-0a0a-0a0a-0a0a-0a0a0a0a0a0a', 'owner@x.rw', '{"display_name":"Owner"}');
insert into public.platform_admins (user_id) values ('0a0a0a0a-0a0a-0a0a-0a0a-0a0a0a0a0a0a');
select set_config('request.jwt.claim.sub', 'dddddddd-dddd-dddd-dddd-dddddddddddd', true);
set local role authenticated;
select public.create_savings_group('Free Squad') as fg \gset
select set_config('t.fg', :'fg', true);
do $$ begin
  assert (public.plan_overview(current_setting('t.fg')::uuid) ->> 'plan') = 'free', 'new groups start on Free';
  assert (public.plan_overview(current_setting('t.fg')::uuid) -> 'limits' ->> 'members') = '15', 'free limit: 15 members';
end $$;
select public.create_event(:'fg', 'One', 1000, null);
select public.create_event(:'fg', 'Two', 1000, null) as fe2 \gset
select set_config('t.fe2', :'fe2', true);
select t.expect_err($$select public.create_event(current_setting('t.fg')::uuid, 'Three', 1000, null)$$, 'plan_limit_events');
-- a finished event frees a slot; reopening past the limit is blocked
select public.set_event_status(:'fe2', 'completed');
select public.create_event(:'fg', 'Three', 1000, null) as fe3 \gset
select t.expect_err($$select public.set_event_status(current_setting('t.fe2')::uuid, 'active')$$, 'plan_limit_events');
-- automatic checking is a paid feature
select t.expect_err($$select public.create_collector_token(current_setting('t.fg')::uuid)$$, 'plan_feature_autocheck');
-- members: fill to 15, the 16th is refused for every route (direct add)
reset role;
insert into auth.users (id, email, raw_user_meta_data)
  select gen_random_uuid(), 'bulk' || i || '@x.rw', '{}' from generate_series(1, 20) i;
select set_config('request.jwt.claim.sub', 'dddddddd-dddd-dddd-dddd-dddddddddddd', true);
set local role authenticated;
do $$ declare i int; begin
  for i in 1..14 loop perform public.add_member_by_email(current_setting('t.fg')::uuid, 'bulk' || i || '@x.rw'); end loop;
end $$;
select t.expect_err($$select public.add_member_by_email(current_setting('t.fg')::uuid, 'bulk15@x.rw')$$, 'plan_limit_members');
do $$ begin assert (public.plan_overview(current_setting('t.fg')::uuid) -> 'usage' ->> 'members') = '15', 'usage counted'; end $$;
-- upgrade request: only the admin, validated, one at a time, reference unique
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select t.expect_err($$select public.plan_overview(current_setting('t.fg')::uuid)$$, 'not_allowed');
select t.expect_err($$select public.request_plan_upgrade(current_setting('t.fg')::uuid, 'plus', 'month', 'ABC123456')$$, 'not_allowed');
reset role;
select set_config('request.jwt.claim.sub', 'dddddddd-dddd-dddd-dddd-dddddddddddd', true);
set local role authenticated;
select t.expect_err($$select public.request_plan_upgrade(current_setting('t.fg')::uuid, 'gold', 'month', 'ABC123456')$$, 'invalid_plan');
select t.expect_err($$select public.request_plan_upgrade(current_setting('t.fg')::uuid, 'plus', 'month', 'ab')$$, 'invalid_reference');
select public.request_plan_upgrade(:'fg', 'plus', 'year', 'mp26plus001') as rq \gset
select set_config('t.rq', :'rq', true);
do $$ begin
  assert (public.plan_overview(current_setting('t.fg')::uuid) -> 'pending' ->> 'amount') = '20000', 'amount comes from the plans table, not the browser';
  assert (public.plan_overview(current_setting('t.fg')::uuid) -> 'pending' ->> 'txn_ref') = 'MP26PLUS001', 'pending request visible';
end $$;
select t.expect_err($$select public.request_plan_upgrade(current_setting('t.fg')::uuid, 'pro', 'month', 'MP26OTHER02')$$, 'request_pending');
select t.expect_err($$select * from public.plan_requests$$, 'permission denied');
select t.expect_err($$select public.owner_list_plan_requests()$$, 'not_allowed');
select t.expect_err($$select public.owner_decide_plan_request(current_setting('t.rq')::uuid, true)$$, 'not_allowed');
select t.expect_err($$select public.owner_set_plan(current_setting('t.fg')::uuid, 'pro', 30)$$, 'not_allowed');
do $$ begin assert (public.owner_summary() ->> 'is_owner')::boolean = false, 'normal users are not owners'; end $$;
select t.expect_err($$update public.savings_groups set plan = 'pro'$$, 'permission denied');
reset role;
-- the owner approves
select set_config('request.jwt.claim.sub', '0a0a0a0a-0a0a-0a0a-0a0a-0a0a0a0a0a0a', true);
set local role authenticated;
do $$ begin
  assert (public.owner_summary() ->> 'is_owner')::boolean and (public.owner_summary() ->> 'pending') = '1', 'owner sees one pending request';
  assert (select requester_email from public.owner_list_plan_requests() limit 1) = 'd@x.rw', 'owner sees who asked';
end $$;
select public.owner_decide_plan_request(:'rq', true);
select t.expect_err($$select public.owner_decide_plan_request(current_setting('t.rq')::uuid, false)$$, 'invalid_transition');
reset role;
do $$ begin
  assert (select plan from public.savings_groups where id = current_setting('t.fg')::uuid) = 'plus', 'group is now on Plus';
  assert (select plan_until from public.savings_groups where id = current_setting('t.fg')::uuid) > now() + interval '360 days', 'a year of Plus';
end $$;
select set_config('request.jwt.claim.sub', 'dddddddd-dddd-dddd-dddd-dddddddddddd', true);
set local role authenticated;
select public.create_event(:'fg', 'Four', 1000, null);
select public.create_event(:'fg', 'Five', 1000, null);
select public.add_member_by_email(:'fg', 'bulk15@x.rw');
select public.create_collector_token(:'fg');
-- expiry drops the group back to Free, nothing is deleted, only new additions are blocked
reset role;
update public.savings_groups set plan_until = now() - interval '1 day' where id = :'fg';
set local role authenticated;
do $$ begin
  assert (public.plan_overview(current_setting('t.fg')::uuid) ->> 'plan') = 'free' and (public.plan_overview(current_setting('t.fg')::uuid) ->> 'expired')::boolean, 'expired plan reads as Free';
  assert (select count(*) from public.group_members where group_id = current_setting('t.fg')::uuid) = 16, 'existing members stay';
end $$;
select t.expect_err($$select public.add_member_by_email(current_setting('t.fg')::uuid, 'bulk16@x.rw')$$, 'plan_limit_members');
reset role;
-- rejected requests are recorded and don't change the plan
select set_config('request.jwt.claim.sub', 'dddddddd-dddd-dddd-dddd-dddddddddddd', true);
set local role authenticated;
select public.request_plan_upgrade(:'fg', 'pro', 'month', 'MP26PRO0003') as rq2 \gset
select set_config('t.rq2', :'rq2', true);
select public.cancel_plan_request(:'fg');
select public.request_plan_upgrade(:'fg', 'pro', 'month', 'MP26PRO0004') as rq3 \gset
select set_config('t.rq3', :'rq3', true);
reset role;
select set_config('request.jwt.claim.sub', '0a0a0a0a-0a0a-0a0a-0a0a-0a0a0a0a0a0a', true);
set local role authenticated;
select public.owner_decide_plan_request(:'rq3', false, 'No such payment');
select public.owner_set_plan(:'fg', 'pro', 30);
reset role;
do $$ begin
  assert (select status from public.plan_requests where id = current_setting('t.rq3')::uuid) = 'rejected', 'rejection recorded';
  assert (select plan from public.savings_groups where id = current_setting('t.fg')::uuid) = 'pro', 'owner can grant a plan by hand';
end $$;
set local role anon;
select t.expect_err($$select public.owner_summary()$$, 'permission denied');
select t.expect_err($$select * from public.plans$$, 'permission denied');
reset role;


-- ===== 011: deferred email confirmation ====================================================
reset role;
drop trigger t_autoverify on public.profiles;
insert into auth.users (id, email, raw_user_meta_data) values ('71717171-7171-7171-7171-717171717171', 'late@x.rw', '{"display_name":"Late"}');
do $$ begin assert (select email_verified_at from public.profiles where id = '71717171-7171-7171-7171-717171717171') is null, 'new people start unverified'; end $$;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.add_member_by_email(:'g', 'late@x.rw');
reset role;
select set_config('request.jwt.claim.sub', '71717171-7171-7171-7171-717171717171', true);
set local role authenticated;
select t.expect_err($$select public.post_group_message(current_setting('t.g')::uuid, 'hi')$$, 'email_unverified');
-- a normal password session can't prove the email
select set_config('request.jwt.claims', '{"sub":"71717171-7171-7171-7171-717171717171","amr":[{"method":"password","timestamp":' || extract(epoch from now())::bigint || '}]}', true);
select t.expect_err($$select public.confirm_my_email()$$, 'email_not_proven');
-- an old email code doesn't count
select set_config('request.jwt.claims', '{"sub":"71717171-7171-7171-7171-717171717171","amr":[{"method":"otp","timestamp":' || (extract(epoch from now())::bigint - 7200) || '}]}', true);
select t.expect_err($$select public.confirm_my_email()$$, 'email_not_proven');
-- no claim at all
select set_config('request.jwt.claims', '', true);
select t.expect_err($$select public.confirm_my_email()$$, 'email_not_proven');
-- a fresh email one-time-code session does
select set_config('request.jwt.claims', '{"sub":"71717171-7171-7171-7171-717171717171","amr":[{"method":"otp","timestamp":' || extract(epoch from now())::bigint || '}]}', true);
select public.confirm_my_email();
select set_config('request.jwt.claims', '', true);
select public.post_group_message(:'g', 'hello at last');
do $$ begin assert exists (select 1 from public.group_messages where body = 'hello at last'), 'verified person can chat'; end $$;
reset role;
set local role anon;
select t.expect_err($$select public.confirm_my_email()$$, 'permission denied');
reset role;

-- ===== 012: live multiplayer games ===========================================================
reset role;
insert into auth.users (id, email, raw_user_meta_data) values ('ffffffff-ffff-ffff-ffff-ffffffffffff', 'out@x.rw', '{"display_name":"Outsider"}');
insert into public.group_members (group_id, user_id, role) values (:'g', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'member') on conflict do nothing;
do $$ begin
  assert (select count(*) from public.trivia_questions) >= 40, 'question bank seeded';
  assert (select count(*) from public.group_members where group_id = current_setting('t.g')::uuid and user_id in ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '71717171-7171-7171-7171-717171717171')) = 3, 'A, B and L are all in the group';
end $$;

-- nobody reads or writes the tables directly (the secret column included)
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select t.expect_err($$select * from public.game_rooms$$, 'permission denied');
select t.expect_err($$select secret from public.game_rooms$$, 'permission denied');
select t.expect_err($$select * from public.game_room_players$$, 'permission denied');
select t.expect_err($$select * from public.trivia_questions$$, 'permission denied');
select t.expect_err($$insert into public.game_rooms (group_id, kind, host_id) values (current_setting('t.g')::uuid, 'rps', auth.uid())$$, 'permission denied');
select t.expect_err($$select public.create_room(current_setting('t.g')::uuid, 'poker')$$, 'invalid_game');

-- ---- Tic-Tac-Toe ----
select public.create_room(:'g', 'tictactoe') as r1 \gset
select set_config('t.r1', :'r1', true);
reset role;
select set_config('request.jwt.claim.sub', 'ffffffff-ffff-ffff-ffff-ffffffffffff', true);
set local role authenticated;
select t.expect_err($$select public.join_room(current_setting('t.r1')::uuid)$$, 'not_allowed');
select t.expect_err($$select public.get_room(current_setting('t.r1')::uuid)$$, 'not_allowed');
select t.expect_err($$select public.list_rooms(current_setting('t.g')::uuid)$$, 'not_allowed');
select t.expect_err($$select public.create_room(current_setting('t.g')::uuid, 'rps')$$, 'not_allowed');
select t.expect_err($$select public.make_move(current_setting('t.r1')::uuid, 0)$$, 'not_allowed');
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.join_room(:'r1');
select public.join_room(:'r1');
reset role;
select set_config('request.jwt.claim.sub', '71717171-7171-7171-7171-717171717171', true);
set local role authenticated;
select t.expect_err($$select public.join_room(current_setting('t.r1')::uuid)$$, 'game_full');
select t.expect_err($$select public.make_move(current_setting('t.r1')::uuid, 0)$$, 'not_in_game');
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select t.expect_err($$select public.start_room(current_setting('t.r1')::uuid)$$, 'not_allowed');
select t.expect_err($$select public.make_move(current_setting('t.r1')::uuid, 0)$$, 'game_over');
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.start_room(:'r1');
select t.expect_err($$select public.start_room(current_setting('t.r1')::uuid)$$, 'game_started');
select t.expect_err($$select public.make_move(current_setting('t.r1')::uuid, 9)$$, 'invalid_move');
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select t.expect_err($$select public.make_move(current_setting('t.r1')::uuid, 0)$$, 'not_your_turn');
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.make_move(:'r1', 0);
select t.expect_err($$select public.make_move(current_setting('t.r1')::uuid, 1)$$, 'not_your_turn');
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select t.expect_err($$select public.make_move(current_setting('t.r1')::uuid, 0)$$, 'cell_taken');
select public.make_move(:'r1', 3);
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.make_move(:'r1', 1);
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.make_move(:'r1', 4);
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.make_move(:'r1', 2);
do $$
declare g jsonb := public.get_room(current_setting('t.r1')::uuid);
begin
  assert g ->> 'status' = 'finished', 'ttt finished';
  assert g ->> 'winner_id' = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A wins with the top row';
  assert g -> 'state' -> 'line' = '[0,1,2]'::jsonb, 'winning line reported';
  assert g -> 'state' ->> 'board' = 'XXXOO....', 'board is as played';
  assert jsonb_array_length(g -> 'players') = 2, 'two players';
end $$;
select t.expect_err($$select public.make_move(current_setting('t.r1')::uuid, 8)$$, 'game_over');

-- ---- Rock-Paper-Scissors: hidden until both chose ----
select public.create_room(:'g', 'rps') as r2 \gset
select set_config('t.r2', :'r2', true);
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.join_room(:'r2');
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.start_room(:'r2');
select t.expect_err($$select public.make_move(current_setting('t.r2')::uuid, 4)$$, 'invalid_move');
select public.make_move(:'r2', 1);
select t.expect_err($$select public.make_move(current_setting('t.r2')::uuid, 2)$$, 'already_moved');
do $$
declare g jsonb := public.get_room(current_setting('t.r2')::uuid);
begin
  assert (g ->> 'my_choice')::int = 1, 'I can see my own choice';
  assert g::text not like '%choices%', 'the secret column never leaves the server';
end $$;
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
do $$
declare g jsonb := public.get_room(current_setting('t.r2')::uuid);
begin
  assert g -> 'my_choice' = 'null'::jsonb, 'the opponent sees nothing of A''s choice';
  assert g -> 'state' -> 'moved' = '[0]'::jsonb, 'only the fact that A has chosen is public';
end $$;
select public.make_move(:'r2', 3);
do $$
declare g jsonb := public.get_room(current_setting('t.r2')::uuid);
begin
  assert g -> 'state' -> 'wins' = '[1,0]'::jsonb, 'rock beats scissors';
  assert (g -> 'state' ->> 'round')::int = 2, 'next round';
  assert g -> 'state' -> 'last' -> 'c' = '[1,3]'::jsonb, 'both choices shown after the round';
end $$;
select public.make_move(:'r2', 2);
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.make_move(:'r2', 2);   -- paper vs paper: draw, replay
do $$
declare g jsonb := public.get_room(current_setting('t.r2')::uuid);
begin
  assert g -> 'state' -> 'wins' = '[1,0]'::jsonb, 'a draw changes nothing';
  assert (g -> 'state' -> 'last' ->> 'result')::int = -1, 'draw recorded';
end $$;
select public.make_move(:'r2', 1);
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.make_move(:'r2', 3);
do $$
declare g jsonb := public.get_room(current_setting('t.r2')::uuid);
begin
  assert g ->> 'status' = 'finished' and g ->> 'winner_id' = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'A reaches 2 wins first';
end $$;

-- ---- Connect 4 ----
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.create_room(:'g', 'connect4') as r3 \gset
select set_config('t.r3', :'r3', true);
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.join_room(:'r3');
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.start_room(:'r3');
select t.expect_err($$select public.make_move(current_setting('t.r3')::uuid, 7)$$, 'invalid_move');
select public.make_move(:'r3', 3);
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.make_move(:'r3', 4);
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.make_move(:'r3', 3);
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.make_move(:'r3', 4);
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.make_move(:'r3', 3);
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.make_move(:'r3', 4);
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.make_move(:'r3', 3);
do $$
declare g jsonb := public.get_room(current_setting('t.r3')::uuid);
begin
  assert g ->> 'status' = 'finished' and g ->> 'winner_id' = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'four in a column wins';
  assert jsonb_array_length(g -> 'state' -> 'line') = 4, 'line has four cells';
end $$;

-- ---- Trivia race ----
select public.create_room(:'g', 'trivia') as r4 \gset
select set_config('t.r4', :'r4', true);
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.join_room(:'r4');
reset role;
select set_config('request.jwt.claim.sub', '71717171-7171-7171-7171-717171717171', true);
set local role authenticated;
select public.join_room(:'r4');
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.start_room(:'r4');
do $$
declare g jsonb := public.get_room(current_setting('t.r4')::uuid);
begin
  assert g -> 'state' ->> 'phase' = 'question' and (g -> 'state' ->> 'total')::int = 8, 'first of eight questions';
  assert jsonb_array_length(g -> 'state' -> 'options') = 4, 'four options';
  assert not (g -> 'state' ? 'correct'), 'the right answer is hidden during the question';
  assert g::text not like '%"answers"%' and g::text not like '%"ids"%', 'secret stays secret';
end $$;
reset role;
select (select answer from public.trivia_questions where id = (secret -> 'ids' ->> 0)::int) as ans0 from public.game_rooms where id = :'r4' \gset
select set_config('t.ans0', :'ans0', true);
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.make_move(:'r4', current_setting('t.ans0')::int);
select t.expect_err($$select public.make_move(current_setting('t.r4')::uuid, 0)$$, 'already_moved');
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.make_move(:'r4', (current_setting('t.ans0')::int + 1) % 4);
reset role;
select set_config('request.jwt.claim.sub', '71717171-7171-7171-7171-717171717171', true);
set local role authenticated;
do $$ begin
  assert public.get_room(current_setting('t.r4')::uuid) -> 'state' ->> 'phase' = 'question', 'still waiting for the third player';
end $$;
select public.make_move(:'r4', (current_setting('t.ans0')::int + 2) % 4);
do $$
declare g jsonb := public.get_room(current_setting('t.r4')::uuid);
begin
  assert g -> 'state' ->> 'phase' = 'reveal', 'everyone answered, so the answer is revealed at once';
  assert (g -> 'state' ->> 'correct')::int = current_setting('t.ans0')::int, 'correct answer shown after the question';
  assert (select (p ->> 'score')::int from jsonb_array_elements(g -> 'players') p where p ->> 'user_id' = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') between 140 and 150, 'fast correct answer is worth 100 + speed bonus';
  assert (select (p ->> 'score')::int from jsonb_array_elements(g -> 'players') p where p ->> 'user_id' = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') = 0, 'wrong answer scores nothing';
end $$;
select t.expect_err($$select public.make_move(current_setting('t.r4')::uuid, 0)$$, 'too_late');
-- jump to the last reveal and let the clock run out
reset role;
update public.game_rooms set state = state || jsonb_build_object('q', 7, 'phase', 'reveal', 'until', now() - interval '1 second') where id = :'r4';
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
do $$
declare g jsonb := public.get_room(current_setting('t.r4')::uuid);
begin
  assert g ->> 'status' = 'finished' and g ->> 'winner_id' = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'top scorer wins the race';
end $$;

-- a question nobody answers closes when time is up
select public.create_room(:'g', 'trivia') as r5 \gset
select set_config('t.r5', :'r5', true);
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.join_room(:'r5');
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.start_room(:'r5');
reset role;
update public.game_rooms set state = jsonb_set(state, '{until}', to_jsonb(now() - interval '1 second')) where id = :'r5';
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select t.expect_err($$select public.make_move(current_setting('t.r5')::uuid, 0)$$, 'too_late');
do $$
declare g jsonb := public.get_room(current_setting('t.r5')::uuid);
begin
  assert g -> 'state' ->> 'phase' = 'reveal', 'time is up, so the question closes';
  assert not exists (select 1 from jsonb_array_elements(g -> 'players') p where (p ->> 'score')::int > 0), 'nobody scored';
end $$;

-- ---- lobby rules ----
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select t.expect_err($$select public.start_room(current_setting('t.r5')::uuid)$$, 'game_started');
select public.create_room(:'g', 'rps') as r6 \gset
select set_config('t.r6', :'r6', true);
select t.expect_err($$select public.start_room(current_setting('t.r6')::uuid)$$, 'not_enough_players');
select public.create_room(:'g', 'rps');
select t.expect_err($$select public.create_room(current_setting('t.g')::uuid, 'rps')$$, 'too_many_games');
-- leaving a lobby: host hands over, empty room disappears
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.join_room(:'r6');
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.leave_room(:'r6');
reset role;
do $$ begin assert (select host_id from public.game_rooms where id = current_setting('t.r6')::uuid) = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'host passed on'; end $$;
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select t.expect_err($$select public.start_room(current_setting('t.r6')::uuid)$$, 'not_allowed');
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.leave_room(:'r6');
reset role;
do $$ begin assert not exists (select 1 from public.game_rooms where id = current_setting('t.r6')::uuid), 'empty lobby closes'; end $$;
-- the host can start with both there, and walking out of a live game forfeits it
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.create_room(:'g', 'tictactoe') as r7 \gset
select set_config('t.r7', :'r7', true);
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.join_room(:'r7');
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.start_room(:'r7');
reset role;
select set_config('request.jwt.claim.sub', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', true);
set local role authenticated;
select public.leave_room(:'r7');
do $$
declare g jsonb := public.get_room(current_setting('t.r7')::uuid);
begin
  assert g ->> 'status' = 'finished' and g ->> 'winner_id' = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa' and g -> 'state' ->> 'forfeit' = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'leaving a live game forfeits';
end $$;
-- delete: host or manager only
reset role;
select set_config('request.jwt.claim.sub', '71717171-7171-7171-7171-717171717171', true);
set local role authenticated;
select t.expect_err($$select public.delete_room(current_setting('t.r7')::uuid)$$, 'not_allowed');
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.delete_room(:'r7');

-- ---- lobby screen and leaderboard ----
do $$
declare l jsonb := public.list_rooms(current_setting('t.g')::uuid);
begin
  assert jsonb_array_length(l -> 'rooms') >= 3, 'rooms listed';
  assert l -> 'leaderboard' -> 0 ->> 'name' = 'Alice', 'Alice leads';
  assert (l -> 'leaderboard' -> 0 ->> 'wins')::int = 4, 'four wins counted';
  assert l::text not like '%secret%', 'no secrets in the list';
end $$;
reset role;
-- stale rooms are closed after six hours
update public.game_rooms set updated_at = now() - interval '7 hours' where id = :'r5';
reset role;
select set_config('request.jwt.claim.sub', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', true);
set local role authenticated;
select public.list_rooms(:'g');
reset role;
do $$ begin
  assert (select status from public.game_rooms where id = current_setting('t.r5')::uuid) = 'finished', 'stale room closed';
  assert (select state ->> 'abandoned' from public.game_rooms where id = current_setting('t.r5')::uuid) = 'true', 'marked abandoned';
end $$;
reset role;
set local role anon;
select t.expect_err($$select public.list_rooms(gen_random_uuid())$$, 'permission denied');
select t.expect_err($$select public.make_move(gen_random_uuid(), 1)$$, 'permission denied');
reset role;

-- anon has nothing
set local role anon;
select t.expect_err($$select * from public.events$$, 'permission denied');
select t.expect_err($$select * from public.event_financials$$, 'permission denied');
select t.expect_err($$select public.create_savings_group('x')$$, 'permission denied');
reset role;

rollback;
\echo ALL SQL SECURITY TESTS PASSED
