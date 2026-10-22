# SquadVault 🇷🇼

**Save together. Celebrate together.**
Private savings groups in Rwanda (RWF only) for weddings, birthdays, trips and shared goals.

**Stack:** plain HTML + CSS + JavaScript (ES modules). No framework, no bundler, no build step, no npm runtime dependencies.
Backend: Supabase (Auth, Postgres + RLS, RPC, Storage) and three small Edge Functions written in plain JavaScript.

---

## 1. What is verified and what is not

| Area | Status |
|---|---|
| All 10 pages render, desktop + mobile, no console errors, no horizontal overflow | ✅ Verified in headless Chromium (`tests/e2e-smoke.mjs`) against a **fake** Supabase client |
| XSS-safe rendering of hostile names | ✅ Verified (same test) |
| SQL migrations 001–006 apply cleanly **and re-run cleanly** | ✅ Verified on a local PostgreSQL 16 with a Supabase stand-in |
| RLS, no direct writes, role-escalation blocks, invitation rules (invalid / expired / revoked / exhausted / rate-limited / double-join), payment idempotency, amount/currency/provider mismatch, expense limits, last-admin protection | ✅ Verified by `tests/sql/security.test.sql` (all assertions pass) |
| Unit tests (money, phone, invite codes, escaping) | ✅ 7/7 pass |
| Your **real** Supabase project (schema, key, Auth emails, deployed functions, storage uploads) | ❌ **Not verified.** I had no access to it from here. You must run the steps below. |
| Real IntaSend payments | ❌ **Not verified, needs your credentials.** I also could **not confirm that IntaSend supports MTN/Airtel Mobile Money collections in Rwanda**. Confirm with IntaSend before going live. Simulated mode works without it. |

Nothing in this repo claims your database is connected or migrated. It is not, until you do section 3.

---

## 2. Run it locally (30 seconds)

```bash
node scripts/serve.mjs        # or:  npm start      -> http://localhost:5173
# alternative with no Node:    python3 -m http.server 5173
```

Always use a local HTTP server. Opening `index.html` as `file://` will not work (ES modules).

Until you add your key, the app shows a friendly "Connect SquadVault to Supabase" screen.

## 3. Connect to Supabase (once)

### 3.1 Check what already exists (read-only)

Run in the Supabase SQL editor and compare with the five core tables:

```sql
select table_name from information_schema.tables where table_schema = 'public' order by 1;
select proname, pg_get_function_identity_arguments(oid) from pg_proc where pronamespace = 'public'::regnamespace order by 1;
select schemaname, tablename, policyname, cmd from pg_policies where schemaname in ('public','storage') order by 1,2;
```

### 3.2 Run the migrations, in this order

Paste each file from `supabase/migrations/` into the SQL editor (or `supabase db push` after `supabase link`):

| # | File | What it does |
|---|---|---|
| 1 | `001_schema_reconciliation.sql` | profiles + signup trigger, payment columns, `payment_events`, indexes, caps, RLS helper functions in a **non-exposed** `private` schema |
| 2 | `002_invitation_system.sql` | `invitation_codes` (SHA-256 hashes only), `create_savings_group`, `create_invitation_code`, `revoke_invitation_code`, `join_group_with_code`, rate limiting |
| 3 | `003_rls_policies.sql` | Replaces all policies on these tables with member-only `SELECT`, grants **SELECT only** to the browser role, creates the `event_financials` view |
| 4 | `004_storage_policies.sql` | Private `receipts` bucket (5 MB, JPG/PNG/WebP/PDF), public `avatars` bucket (1 MB), storage policies |
| 5 | `005_app_functions.sql` | Event / role / membership / expense / profile functions with role checks |
| 6 | `006_payment_functions.sql` | Payment state machine, callable **only** by the service role |

**Already have your own SQL applied?** These migrations are written to upgrade it in place, and the SQL tests start from your exact original schema (core tables, `invitation_codes` with `uses_count`, your read policies and your three original functions). Differences you will see: `uses_count` is renamed to `use_count`; `create_invitation_code` now returns JSON `{id, code, expires_at, max_uses}` and `join_group_with_code` returns JSON `{ok, group_id, already_member}` (generic errors, rate limiting, no double-count). **The front end expects these new return shapes, so run 002 and don't keep your older function versions.** Codes made by your old function still work.

All are **non-destructive** (no table is dropped, recreated or emptied) and safe to re-run. 003 drops and recreates *policies only* on purpose: Postgres ORs permissive policies together, so one forgotten `using (true)` would leak data. 002 drops and recreates three small *functions* by exact signature so their return types match the app. If a legacy plaintext `invitation_codes.code` column exists, 002 makes it nullable and prints a notice. It never reads or deletes it.

Rollback for everything the migrations added: `supabase/ROLLBACK.sql` (kept outside `migrations/` so it never runs automatically).

### 3.3 Frontend configuration

`js/config.js` already contains your project URL and publishable key (`sb_publishable_VlPy…`). To use a different project, change both there. URL: `https://mdvgvhnceouabyuhsbio.supabase.co`.
The publishable key is public by design; RLS protects the data. **Never** put the service-role key, DB password, IntaSend secret or webhook challenge in the frontend.

### 3.4 Supabase Auth settings

Authentication → URL Configuration:
- **Site URL**: your deployed URL (for local testing `http://localhost:5173`)
- **Redirect URLs**: add `http://localhost:5173` and your production URL (the app uses them for email confirmation and password reset)

Authentication → Providers → Email: keep **Confirm email** on for production. For quick local tests you may turn it off.
Recommended: raise the minimum password length to 8 in Auth settings (the UI already requires 8+ with a letter and a number).

### 3.5 Storage

Created by migration 004 (buckets + policies). Nothing to click. Receipts are private and opened through 60-second signed URLs.

### 3.6 Edge Functions (payments)

Functions are plain JS in `supabase/functions/` (`create-payment`, `verify-payment`, `payment-webhook`, shared code in `_shared/`).

```bash
supabase link --project-ref mdvgvhnceouabyuhsbio
cp .env.example .env            # edit values; .env is git-ignored
supabase secrets set --env-file ./.env
supabase functions deploy create-payment verify-payment payment-webhook
```

`config.toml` sets `verify_jwt = false`; the two user-facing functions verify the caller with `auth.getUser(token)` themselves (this works with both legacy and new-style keys), and the webhook is called by the provider, which has no Supabase JWT.

`PAYMENT_MODE` (a secret, never in the browser):
- unset → payments **disabled** (safe default; the UI shows a clear message)
- `simulated` → no provider calls, no real money; payments are labelled **Simulated**
- `live` → real IntaSend (see 6)

---

## 4. Test it

**Sign up, group, invite, join**
1. Open the app → *Create an account* → confirm your email (if enabled) → sign in.
2. *My Groups → New group* → you are the **admin**.
3. *Invitations → Generate code* → copy `SV-XXXXXXXXXXXX` (shown **once**).
4. Open a private window, create a second account, *Join with a code* → you land in the group as a **member**.
5. Try the same code again (no extra use consumed), an edited code, and after *Revoke* → all rejected with one generic message.
6. As the member, check that *New event* and invitation controls are absent, and that calling them directly fails with "permission".

**Events, money, expenses**: create an event (target in RWF) → contribute → watch progress count **only verified** payments → as admin/treasurer record an expense with a receipt.

**Payments without moving real money**: deploy with `PAYMENT_MODE=simulated`, contribute, then press **Simulate success / failure** on the pending screen. Rows carry a purple *Simulated* badge. Turn `simulated` off before real use.

**Automated**: `npm test`, `npm run check`, `node tests/e2e-smoke.mjs`, `tests/run-sql-tests.sh <throwaway-postgres-url>`. See `tests/README.md`.

---

## 5. Security model (short)

- **RLS on every table.** The browser role gets `SELECT` only, filtered by membership. All writes are `SECURITY DEFINER` RPCs (fixed empty `search_path`, identity from `auth.uid()`, role checks, `EXECUTE` to `authenticated` only) or the service role.
- **No browser can mark money as paid.** Only `payment_settle` (service role) can, after provider verification.
- **Invitations:** `SV-` + 12 hex from `gen_random_bytes`; only the SHA-256 hash is stored; plaintext returned once; 7-day / 10-use defaults; revocable; row-locked so concurrent redemptions can't overshoot; 8 failed attempts / 15 min rate limit; every failure returns the same message.
- **Roles:** only admins change roles; the last admin can't be demoted, removed or leave while others remain.
- **Receipts:** private bucket; path must be `<group>/<event>/<uuid>.<ext>` and the object must exist; arbitrary URLs are impossible.
- **XSS:** every dynamic value goes through an escaping template; no `innerHTML` with raw user data.
- **Secrets:** none in the frontend; `.env` is git-ignored; the dev server refuses to serve `.env`, SQL, tests and dotfiles.

### Financial model (explicit)

```
collected  = Σ contributions where status = 'paid'        (the ONLY money counted)
pending / failed / refunded = shown separately, never collected
spent      = Σ expenses
available  = collected − spent        (an expense can't exceed it; checked under a row lock)
remaining  = max(target − collected, 0)      progress % = floor(collected·100 / target)
```
All amounts are integer RWF (`bigint`, capped at 10¹² so JS sums stay exact). Cancelling an event does **not** auto-refund; refunds are a manual provider action.

---

## 6. Going live with payments (needs you)

`supabase/functions/_shared/payments.js` contains the IntaSend adapter. From IntaSend's public docs I could confirm only the webhook payload (`invoice_id`, `state`, `api_ref`, `value`, `currency`, `challenge`; states `PENDING/PROCESSING/COMPLETE/FAILED`) and that status is fetched by `invoice_id`. **I could not confirm the raw REST paths or Rwanda mobile-money coverage**, so the paths are env-configurable and flagged as unverified. Before `PAYMENT_MODE=live`:

1. Confirm with IntaSend that MTN MoMo / Airtel Money **Rwanda** collections in **RWF** are available for your account; set `INTASEND_METHOD_MTN_MOMO` / `INTASEND_METHOD_AIRTEL_MONEY` and check `INTASEND_CHECKOUT_PATH` / `INTASEND_STATUS_PATH`. If they don't cover Rwanda, only `payments.js` needs replacing.
2. Register `https://<project>.supabase.co/functions/v1/payment-webhook` in IntaSend with your chosen challenge → `INTASEND_WEBHOOK_CHALLENGE`.
3. Test in IntaSend's sandbox (`INTASEND_TEST_MODE=true`) first.

The webhook never trusts its own body: it checks the challenge (constant-time), **re-fetches the invoice from IntaSend**, requires `api_ref` to be one of our references, and `payment_settle` re-checks amount + currency, is idempotent per `<invoice>:<state>`, and never reverts a paid row. Provider timeouts return 5xx so the provider retries; `verify-payment` covers a missed webhook; `payment_expire_stale()` can expire old pending rows.

---

## 7. Why it's fast

- ~**29 KB gzipped** for everything needed to first paint (HTML + CSS + core JS); the other 8 modules (~25 KB gz) load **on demand** per page.
- System fonts (no render-blocking font requests), dark background inlined before CSS loads, `modulepreload` + `preconnect` for the pinned Supabase client.
- Service worker (`sw.js`): repeat visits load from cache instantly and refresh in the background. It never touches Supabase requests, so money data is always live.
- Parallel queries per page, aggregates computed in the database (`event_financials`), `content-visibility` on long sections, skeletons instead of spinners.

## 8. Deploy (static hosting)

The `/` folder is the whole site; deploy it as-is to Cloudflare Pages, Netlify, Vercel (static) or GitHub Pages. No build command, publish directory = project root. Routing is hash-based, so no rewrite rules are needed. Then: add the live URL to Supabase Auth *Site URL / Redirect URLs*, and to `ALLOWED_ORIGINS` + `APP_URL` secrets (re-run `supabase secrets set`).
Upload only the web files (`index.html`, `css/`, `js/`, `assets/`, `sw.js`); `supabase/`, `tests/`, `scripts/` don't need to be public.
When you change JS/CSS, bump `CACHE` in `sw.js` to push updates to returning visitors immediately.

## 9. Known limitations

- Direct invitation/role/payment behaviour is tested in a local Postgres, **not** against your Supabase project.
- Uploaded receipts are not deleted if the expense save fails afterwards (no delete policy by design); they stay private and inert.
- Expenses can be edited but not deleted (audit trail). Refunds and cancellations of collected money are manual.
- No realtime push; pages refresh on navigation and pending payments poll every 5 s for ~5 minutes.
- Concurrency safety (row locks) is by design and covered by reasoning, not load-tested.


## Leader-managed Mobile Money (no payment provider needed)

This is the default way to collect. `config.onlinePayments` is `false`, so the IntaSend form is hidden.

1. Run `supabase/SQUADVAULT_UPDATE_007.sql` once in the Supabase SQL editor (already included in `SQUADVAULT_ALL_IN_ONE.sql` for new setups).
2. The leader (admin/treasurer) opens an event -> Edit, and adds an MTN or Airtel MoMo **number or code**, an optional account name and an optional amount per member.
3. Members open Contributions. They see the number, a dial string they can copy (`*182*1*1*<number>*<amount>#`; for a MoMo code `*182*8*1*<code>*<amount>#`) and a button that opens the phone dialer. MTN/Airtel then asks for the PIN on its own screen. SquadVault never sees a PIN.
4. After paying, the member taps **I've paid** (optionally with the SMS transaction ID). This creates a PENDING claim, which is never counted as money.
5. The leader sees it under "Waiting for your confirmation" and taps **Received** (counts) or **Not received**. The leader can also **Record** cash or MoMo they received for a member.
6. The event page shows "Who has paid" with a bar, the members still to pay, and a **Copy reminder** button for the group chat.
7. Admins can **Add member** by the email of an existing account (Group page), or remove a member with the bin button. Invitation codes still work for people without an account.

Unverified: the USSD shortcut formats. `*182*1*1*<number>*<amount>#` is the format supplied by the project owner; the merchant-code format `*182*8*1*<code>*<amount>#` and Airtel's `*500#` menu are not confirmed. Test them with a small amount on a real phone. If a shortcut fails, the page tells the member to dial `*182#` and enter the number manually.


## Game night part 2 (update 013)

Squad -> **Play** now has 11 games in four sections: **Battle & sport** (Clash duel, Penalty Kings shootout, Street Race for up to 10), **Girlies & vibes** (Main Character "most likely to", Hot Takes "would you rather", Emoji Decode), **Big brain** (Trivia Race, Tic-Tac-Toe, Connect 4, Rock Paper Scissors) and **High stakes** (Risk It, up to 10 players).
**Risk It uses pretend squad coins, never real money.** Everyone starts with 200 coins per squad and can claim +50 once a day (Kigali time). Hosting picks a stake of 10, 25, 50 or 100; everyone puts that into the pot, the server rolls two dice for each player in secret, people may hold or re-roll once (final), the highest total takes the pot and a tie splits it. Leaving or closing a table before it starts returns the coins. Coins can't be bought, sold or cashed out, and no Mobile Money is involved. This is deliberate: taking real-money bets would normally need a gambling licence and puts members' real savings at risk.
Run `supabase/SQUADVAULT_UPDATE_013.sql` once (needs 012 first). It adds the wallets, about 40 emoji / slang / football trivia questions and 38 "most likely to" / "would you rather" prompts. Add your own prompts with `insert into public.vibe_prompts (kind, prompt, option_a, option_b) values ('rather', 'Would you rather X or Y?', 'X', 'Y');` (use kind 'likely' and leave the options out for "most likely to").

## Live games (update 012)

Squad -> **Play**: Tic-Tac-Toe, Connect 4, Rock-Paper-Scissors (first to 2) and a Trivia Race (2 to 12 players, 8 questions, faster correct answers score 100 to 150). Someone hosts a table, friends tap **Join**, the host taps **Start**. A squad leaderboard counts wins. No money is involved.
The server is the referee: it checks whose turn it is, whether a square is free, and keeps hidden choices (a Rock-Paper-Scissors pick, a trivia answer) secret until everyone has played. Screens ask for fresh state every 1.5 seconds, so there is nothing extra to switch on in Supabase.
Run `supabase/SQUADVAULT_UPDATE_012.sql` once. It adds the tables, the functions and about 45 starter trivia questions (Rwanda, Africa, general knowledge, money sense). Add your own with `insert into public.trivia_questions (topic, question, options, answer) values ('Rwanda', 'Question?', array['A','B','C','D'], 0);` where the last number is the right option (0 = first).
The old polls and "guess the number" are now under the **Polls** tab.

## Confirm email later (update 011)

Sign-up is instant: nobody waits for an email. Turn **Confirm email OFF** in Supabase (Authentication -> Sign In / Providers -> Email).
Chatting and sharing photos need a confirmed email. On the Squad page people see a banner with **Send confirmation email**; the link in it confirms them and brings them back to Squad. Reading chat stays open to everyone.

1. Run `supabase/SQUADVAULT_UPDATE_011.sql` (existing accounts are treated as confirmed).
2. Supabase -> Authentication -> Email Templates -> **Magic Link**: paste `supabase/email-templates/magic-link.html`, subject "Confirm your email on SquadVault".
3. Authentication -> URL Configuration: Site URL `https://wedont404.github.io/squadvault/`, add the same as a Redirect URL.
4. Strongly recommended: custom SMTP (see email-templates/README.md). The built-in sender only allows a few emails per hour.

## Plans and making money (update 010)

Members are always free. Each **group** is on Free, Plus or Pro:

| | Free | Plus (2,000 RWF/month, 20,000/year) | Pro (10,000/month, 100,000/year) |
|---|---|---|---|
| Members | 15 | 150 | 1,000 |
| Active events | 2 | unlimited | unlimited |
| Photos on the wall | 30 | 500 | 5,000 |
| Automatic MoMo checking | no | yes | yes |

Prices and limits live in the `plans` table; edit them in the Supabase Table Editor any time. Limits are enforced in the database (triggers), only when something new is added. Nothing that exists is deleted when a plan ends. Existing groups got Plus free for 60 days when you ran update 010.

**Set up (once)**
1. Run `supabase/SQUADVAULT_UPDATE_010.sql`.
2. Make yourself the owner (SQL Editor): `insert into public.platform_admins (user_id) select id from auth.users where email = 'YOUR@EMAIL';`
3. In `js/config.js` fill `billing.momoNumber` and `billing.momoName` with YOUR MoMo, and `billing.contact` (WhatsApp or email) so groups know how to reach you. Until `momoNumber` is filled, the Upgrade button says upgrades aren't switched on.

**How a sale works**: a group admin taps *Upgrade*, sends the price to your MoMo, enters the transaction ID. You see it on the dashboard and in *Settings > Owner*. Check your MoMo messages for that ID and amount, then Approve. The plan switches on and renews from its end date. You can also grant a plan by hand: `select public.owner_set_plan('<group id>', 'plus', 30);` (run while signed in as the owner through the app, or as the database owner use an `update public.savings_groups set plan = 'plus', plan_until = now() + interval '30 days' where id = '<group id>'`).

## Squad extras, sender-name checks and returns (update 009)

Run `supabase/SQUADVAULT_UPDATE_009.sql` once in the Supabase SQL Editor (it is also in `SQUADVAULT_ALL_IN_ONE.sql` for new setups). It needs 007 and 008 first.

- **Invitation codes stay visible.** Admins and treasurers see the active code again on the Invitations page (with Copy and WhatsApp share). Codes made before 009 can't be recovered; they still work and can be revoked.
- **Sign-up errors.** "Email rate limit" is the free Supabase email sender, not the person. The app now says so, waits 60 s before allowing another try, offers "Resend confirmation email", and tells people when an email already has an account. The real cure is custom SMTP (see `supabase/email-templates/README.md`).
- **Sender-name checking.** Members type the name MoMo shows. Each new MoMo message from the leader's phone re-checks waiting claims: same amount + strongly matching sender name + close in time + only one claim fits = confirmed automatically. Anything unclear stays with the leader. The leader can turn this off in *Payment checking*.
- **Returning money.** Cancelled events (or completed/overfunded ones) show a "Return the money?" panel to leaders, and the dashboard flags cancelled events that still hold money. SquadVault only records the return; the leader sends the money from their own MoMo.
- **Event pictures** (Create/Edit event) and a **Squad** page with **chat**, a **photo wall** with hearts, and **games** (polls and "guess the number"). Pictures live in the private `group-photos` bucket and are shrunk on the phone before upload.

## Automatic payment checking (optional, Android)

No app can read MTN/Airtel records directly without a payment-provider API. SquadVault instead reads the leader's own
"you have received ... RWF" MoMo messages.

1. Run `supabase/SQUADVAULT_UPDATE_008.sql` once (included in `SQUADVAULT_ALL_IN_ONE.sql` for new setups).
2. Group page -> **Payment checking** -> **Turn on**. Copy the four values shown (shown once).
3. On the leader's Android phone, install an SMS-forwarder app that can POST JSON with custom headers and forward only the mobile money provider's messages.
4. Paste a real message into the **Test a sample MoMo message** box to confirm it is read correctly (amount, transaction ID).

Rules: a claim is confirmed automatically only when the **transaction ID and the amount both match** one unused message. A claim
without a transaction ID is never auto-confirmed. The leader sees a suggested match (amount and time) and confirms with one tap.
Each message can confirm one claim only. Only amount, transaction ID and the sender's name are stored, never the SMS text.
Unverified: the exact wording of MTN/Airtel messages. That is what the test box is for. If a real message is not recognised, the parser in
`private.parse_momo_sms` (008 SQL) needs adjusting.

Limit: a transaction ID is not secret. Someone who learns another member's ID and amount could claim it first. Auto-verified payments are labelled
"Auto-verified from MoMo SMS", and the leader can mark one as refunded if it is disputed.

## Emails, reset links, terms

See `supabase/email-templates/README.md` for branded emails, custom SMTP and the reset-link templates. The Terms & Conditions are in `js/terms.js`
(a plain-language template: have it reviewed before relying on it); set `contactEmail` in `js/config.js` to show a contact line.
