-- 003_rls_policies.sql
-- Row Level Security + least-privilege grants + the read-only financial summary view.
-- Safe to re-run. No table or row is dropped. Only POLICIES are dropped and recreated.
--
-- Prerequisites: 001_schema_reconciliation.sql, 002_invitation_system.sql
--
-- Security model
--   * Every table below has RLS enabled.
--   * The browser (role `authenticated`) gets SELECT only, filtered by group membership.
--   * ALL writes go through SECURITY DEFINER RPC functions (002, 005) or the service role
--     (Edge Functions, 006). The browser can never insert/update/delete financial rows.
--   * `anon` has no access to any of these tables.
--   * invitation_codes is not readable at all from the browser (it holds hashes);
--     managers list invitations through public.list_invitations().
--
-- Policies that already exist on these tables are dropped first, because permissive
-- policies are OR-ed together and one forgotten `using (true)` policy would leak data.

begin;

-- ---------------------------------------------------------------------------
-- 1. Make sure RLS is on everywhere
-- ---------------------------------------------------------------------------
alter table public.savings_groups   enable row level security;
alter table public.group_members    enable row level security;
alter table public.events           enable row level security;
alter table public.contributions    enable row level security;
alter table public.expenses         enable row level security;
alter table public.profiles         enable row level security;
alter table public.invitation_codes enable row level security;
alter table public.invitation_attempts enable row level security;
alter table public.payment_events   enable row level security;

-- ---------------------------------------------------------------------------
-- 2. Grants: anon gets nothing, authenticated gets SELECT only
-- ---------------------------------------------------------------------------
revoke all on public.savings_groups, public.group_members, public.events,
              public.contributions, public.expenses, public.profiles,
              public.invitation_codes, public.invitation_attempts, public.payment_events
  from anon;

revoke insert, update, delete, truncate, references, trigger on
  public.savings_groups, public.group_members, public.events,
  public.contributions, public.expenses, public.profiles
  from authenticated;

revoke all on public.invitation_codes, public.invitation_attempts, public.payment_events from authenticated;

grant select on public.savings_groups, public.group_members, public.events,
                public.contributions, public.expenses, public.profiles
  to authenticated;

-- The service role (Edge Functions only; its key never reaches the browser) needs explicit access
-- so the payment functions work even on projects whose default privileges were changed.
grant select, insert, update, delete on public.savings_groups, public.group_members, public.events,
  public.contributions, public.expenses, public.profiles, public.invitation_codes,
  public.invitation_attempts, public.payment_events to service_role;

-- ---------------------------------------------------------------------------
-- 3. Drop every existing policy on these tables, then create the intended ones
-- ---------------------------------------------------------------------------
do $$
declare r record;
begin
  for r in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('savings_groups', 'group_members', 'events', 'contributions',
                        'expenses', 'profiles', 'invitation_codes', 'invitation_attempts', 'payment_events')
  loop
    execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;

-- savings_groups: visible to its members only
create policy savings_groups_select_members on public.savings_groups
  for select to authenticated
  using (private.is_group_member(id));

-- group_members: you see the roster of groups you belong to
create policy group_members_select_same_group on public.group_members
  for select to authenticated
  using (private.is_group_member(group_id));

-- events: members of the owning group
create policy events_select_members on public.events
  for select to authenticated
  using (private.is_group_member(group_id));

-- contributions: members of the group that owns the event
create policy contributions_select_members on public.contributions
  for select to authenticated
  using (private.is_group_member(private.event_group_id(event_id)));

-- expenses: members of the group that owns the event
create policy expenses_select_members on public.expenses
  for select to authenticated
  using (private.is_group_member(private.event_group_id(event_id)));

-- profiles: your own profile, plus people you share a group with
create policy profiles_select_self_or_group on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or private.shares_group_with(id));

-- invitation_codes, invitation_attempts, payment_events: RLS on, no policies, no grants
-- => unreachable from the API. Reached only through SECURITY DEFINER functions / service role.

-- ---------------------------------------------------------------------------
-- 4. profiles.avatar_path (private path inside the public `avatars` bucket)
--    Written only by public.update_profile() (005), never by the browser directly.
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists avatar_path text;

-- ---------------------------------------------------------------------------
-- 5. Financial model (single source of truth)
--
--   collected   = SUM(contributions.amount) WHERE status = 'paid'
--   pending     = SUM(...)                  WHERE status = 'pending'   (NEVER counted as money)
--   failed      = SUM(...)                  WHERE status = 'failed'
--   refunded    = SUM(...)                  WHERE status = 'refunded'  (NOT counted as collected)
--   spent       = SUM(expenses.amount)
--   available   = collected - spent
--   remaining   = GREATEST(target - collected, 0)
--
-- security_invoker => the view runs with the CALLER's rights, so the RLS policies above
-- apply and nobody can read totals for a group they do not belong to.
-- ---------------------------------------------------------------------------
create or replace view public.event_financials
with (security_invoker = true) as
select
  e.id         as event_id,
  e.group_id   as group_id,
  e.target_amount,
  e.status     as event_status,
  coalesce(c.paid, 0)::bigint      as paid_total,
  coalesce(c.pending, 0)::bigint   as pending_total,
  coalesce(c.failed, 0)::bigint    as failed_total,
  coalesce(c.refunded, 0)::bigint  as refunded_total,
  coalesce(x.spent, 0)::bigint     as expenses_total,
  (coalesce(c.paid, 0) - coalesce(x.spent, 0))::bigint as available_funds,
  greatest(e.target_amount - coalesce(c.paid, 0), 0)::bigint as remaining_amount
from public.events e
left join lateral (
  select
    sum(k.amount) filter (where k.status = 'paid')     as paid,
    sum(k.amount) filter (where k.status = 'pending')  as pending,
    sum(k.amount) filter (where k.status = 'failed')   as failed,
    sum(k.amount) filter (where k.status = 'refunded') as refunded
  from public.contributions k
  where k.event_id = e.id
) c on true
left join lateral (
  select sum(x1.amount) as spent from public.expenses x1 where x1.event_id = e.id
) x on true;

revoke all on public.event_financials from anon;
grant select on public.event_financials to authenticated;

commit;
