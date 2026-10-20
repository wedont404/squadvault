# Tests

| What | Command | Needs |
|---|---|---|
| Unit tests (money, phone, invite codes, XSS-safe templating) | `npm test` | Node 20+ |
| Syntax check of every JS file | `npm run check` | Node 20+ |
| Browser smoke test: every page, desktop + mobile, XSS, simulated payment, overflow | `node tests/e2e-smoke.mjs` | `playwright` installed (`npm i -g playwright`) + Chromium. Uses a **fake** Supabase client, so no project or credentials. Add `SHOTS=/some/dir` to save screenshots. |
| SQL security tests (RLS, role escalation, invitations, payment state machine, expense limits, manual MoMo claims / review / progress / add member / sender-name matching / photos, chat, games) | `tests/run-sql-tests.sh postgresql://user@localhost:5432` | `psql` and a **throwaway** local Postgres. It creates and drops its own database and applies a small Supabase stand-in (`sql/supabase_stub.sql`). **Never point it at your real Supabase project.** |

## What is NOT covered by automated tests

These need your real Supabase project and/or provider credentials. Use the manual steps in the root README:

- Real Supabase Auth (email confirmation, password-reset emails)
- The actual deployed Edge Functions and storage uploads
- Real IntaSend collection / webhook (needs your account; coverage for MTN/Airtel Rwanda is unconfirmed)
- Two-browser concurrency on invitation redemption (the row lock is exercised by design, not load-tested)
