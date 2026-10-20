// Read-side data access. Every query runs as the signed-in user, so Row Level Security decides what
// comes back. There are no writes in this file: all writes go through RPCs / Edge Functions.
import { supabase, must, rpc } from "./supabase.js";
import { toInt } from "./utils.js";

export async function fetchProfile(uid) {
  const data = must(await supabase.from("profiles").select("id,display_name,avatar_path").eq("id", uid).maybeSingle());
  return data ?? { id: uid, display_name: "Member", avatar_path: null };
}

export async function fetchProfiles(ids) {
  const unique = [...new Set(ids.filter(Boolean))];
  if (!unique.length) return new Map();
  const rows = must(await supabase.from("profiles").select("id,display_name,avatar_path").in("id", unique)) ?? [];
  return new Map(rows.map((p) => [p.id, p]));
}

export async function fetchGroups(uid) {
  const rows = must(
    await supabase
      .from("group_members")
      .select("role,joined_at,savings_groups(id,name,currency,created_at)")
      .eq("user_id", uid)
      .order("joined_at", { ascending: true }),
  ) ?? [];
  return rows
    .filter((r) => r.savings_groups)
    .map((r) => ({ ...r.savings_groups, role: r.role, joined_at: r.joined_at }));
}

export async function fetchMembers(groupId) {
  const rows = must(await supabase.from("group_members").select("user_id,role,joined_at").eq("group_id", groupId)) ?? [];
  const profiles = await fetchProfiles(rows.map((r) => r.user_id));
  const order = { admin: 0, treasurer: 1, member: 2 };
  return rows
    .map((r) => ({ ...r, name: profiles.get(r.user_id)?.display_name ?? "Member", avatar_path: profiles.get(r.user_id)?.avatar_path ?? null }))
    .sort((a, b) => order[a.role] - order[b.role] || a.name.localeCompare(b.name));
}

const EVENT_COLS = "id,group_id,name,target_amount,event_date,status,created_at,pay_provider,pay_kind,pay_account,pay_account_name,expected_per_member,cover_path";

export async function fetchEvents(groupIds) {
  if (!groupIds.length) return [];
  return must(
    await supabase.from("events").select(EVENT_COLS).in("group_id", groupIds).order("created_at", { ascending: false }),
  ) ?? [];
}

export async function fetchEvent(eventId) {
  return must(await supabase.from("events").select(EVENT_COLS).eq("id", eventId).maybeSingle());
}

/** Map<event_id, financials row>. Numbers are integer RWF. */
export async function fetchFinancials(groupIds) {
  if (!groupIds.length) return new Map();
  const rows = must(await supabase.from("event_financials").select("*").in("group_id", groupIds)) ?? [];
  return new Map(rows.map((r) => [r.event_id, normalizeFin(r)]));
}

export async function fetchEventFinancials(eventId) {
  const row = must(await supabase.from("event_financials").select("*").eq("event_id", eventId).maybeSingle());
  return row ? normalizeFin(row) : emptyFin();
}

const emptyFin = () => ({ paid_total: 0, pending_total: 0, failed_total: 0, refunded_total: 0, expenses_total: 0, available_funds: 0, remaining_amount: 0, target_amount: 0 });
function normalizeFin(r) {
  return {
    ...r,
    target_amount: toInt(r.target_amount),
    paid_total: toInt(r.paid_total),
    pending_total: toInt(r.pending_total),
    failed_total: toInt(r.failed_total),
    refunded_total: toInt(r.refunded_total),
    expenses_total: toInt(r.expenses_total),
    available_funds: toInt(r.available_funds),
    remaining_amount: toInt(r.remaining_amount),
  };
}
export const finOrEmpty = (map, id) => map.get(id) ?? emptyFin();

const CONTRIB_COLS =
  "id,event_id,user_id,amount,status,payment_method,provider,provider_ref,sender_name,note,payment_reference,is_simulated,failure_reason,paid_at,created_at,events!inner(id,name,group_id)";

export async function fetchContributions({ groupId = null, eventId = null, userId = null, status = null, limit = 100 } = {}) {
  let q = supabase.from("contributions").select(CONTRIB_COLS).order("created_at", { ascending: false }).limit(limit);
  if (groupId) q = q.eq("events.group_id", groupId);
  if (eventId) q = q.eq("event_id", eventId);
  if (userId) q = q.eq("user_id", userId);
  if (status) q = q.eq("status", status);
  const rows = must(await q) ?? [];
  const profiles = await fetchProfiles(rows.map((r) => r.user_id));
  return rows.map((r) => ({
    ...r,
    amount: toInt(r.amount),
    event_name: r.events?.name ?? "Event",
    group_id: r.events?.group_id,
    name: profiles.get(r.user_id)?.display_name ?? "Member",
    avatar_path: profiles.get(r.user_id)?.avatar_path ?? null,
  }));
}

const EXPENSE_COLS = "id,event_id,amount,description,receipt_path,recorded_by,created_at,events!inner(id,name,group_id)";

export async function fetchExpenses({ groupId = null, eventId = null, limit = 100 } = {}) {
  let q = supabase.from("expenses").select(EXPENSE_COLS).order("created_at", { ascending: false }).limit(limit);
  if (groupId) q = q.eq("events.group_id", groupId);
  if (eventId) q = q.eq("event_id", eventId);
  const rows = must(await q) ?? [];
  const profiles = await fetchProfiles(rows.map((r) => r.recorded_by));
  return rows.map((r) => ({
    ...r,
    amount: toInt(r.amount),
    event_name: r.events?.name ?? "Event",
    group_id: r.events?.group_id,
    recorder: profiles.get(r.recorded_by)?.display_name ?? "Member",
  }));
}

/** Merge contributions + expenses into one chronological activity feed. */
export function buildActivity(contributions, expenses, limit = 12) {
  const items = [
    ...contributions.map((c) => ({ kind: "contribution", at: c.created_at, ...c })),
    ...expenses.map((x) => ({ kind: "expense", at: x.created_at, ...x })),
  ];
  return items.sort((a, b) => new Date(b.at) - new Date(a.at)).slice(0, limit);
}

/** Aggregate verified (paid) contributions per person. */
export function contributorTotals(contributions) {
  const m = new Map();
  for (const c of contributions) {
    if (c.status !== "paid") continue;
    const cur = m.get(c.user_id) ?? { user_id: c.user_id, name: c.name, avatar_path: c.avatar_path, total: 0, count: 0 };
    cur.total += c.amount;
    cur.count += 1;
    m.set(c.user_id, cur);
  }
  return [...m.values()].sort((a, b) => b.total - a.total);
}

/** Map<group_id, number of members>. */
export async function fetchMemberCounts(groupIds) {
  if (!groupIds.length) return new Map();
  const rows = must(await supabase.from("group_members").select("group_id").in("group_id", groupIds)) ?? [];
  const m = new Map();
  rows.forEach((r) => m.set(r.group_id, (m.get(r.group_id) ?? 0) + 1));
  return m;
}

/** Per-member payment progress for one event (who paid, who has not). Integer RWF. */
export async function fetchEventProgress(eventId) {
  const rows = (await rpc("event_member_progress", { p_event_id: eventId })) ?? [];
  const profiles = await fetchProfiles(rows.map((r) => r.user_id));
  return rows.map((r) => ({
    user_id: r.user_id,
    role: r.role,
    paid_total: toInt(r.paid_total),
    paid_count: toInt(r.paid_count),
    pending_total: toInt(r.pending_total),
    pending_count: toInt(r.pending_count),
    last_paid_at: r.last_paid_at,
    name: profiles.get(r.user_id)?.display_name ?? "Member",
    avatar_path: profiles.get(r.user_id)?.avatar_path ?? null,
  }));
}

/** Leader only. Suggested MoMo-SMS matches for the waiting claims of an event (empty on any error). */
export async function fetchClaimHints(eventId) {
  try { return (await rpc("claim_match_hints", { p_event_id: eventId })) ?? []; } catch { return []; }
}
export async function fetchCollectorActive(groupId) {
  try { return Boolean((await rpc("collector_status", { p_group_id: groupId }))?.active); } catch { return false; }
}
export async function fetchContributionStatus(id) {
  const row = must(await supabase.from("contributions").select("status").eq("id", id).maybeSingle());
  return row?.status ?? null;
}

// ---------------------------------------------------------------------------
// Squad: chat, photos, games (reads only; writes are RPCs in hub.js)
// ---------------------------------------------------------------------------
/** Newest 80 messages, oldest first, with names. */
export async function fetchMessages(groupId, limit = 80) {
  const rows = must(await supabase.from("group_messages").select("id,user_id,body,created_at").eq("group_id", groupId).order("created_at", { ascending: false }).limit(limit)) ?? [];
  const profiles = await fetchProfiles(rows.map((r) => r.user_id));
  return rows.reverse().map((r) => ({ ...r, name: profiles.get(r.user_id)?.display_name ?? "Member", avatar_path: profiles.get(r.user_id)?.avatar_path ?? null }));
}

export async function fetchPhotos(groupId) {
  const rows = (await rpc("list_group_photos", { p_group_id: groupId, p_limit: 60 })) ?? [];
  const profiles = await fetchProfiles(rows.map((r) => r.user_id));
  return rows.map((r) => ({ ...r, like_count: toInt(r.like_count), name: profiles.get(r.user_id)?.display_name ?? "Member" }));
}

export async function fetchGames(groupId) {
  const rows = (await rpc("list_games", { p_group_id: groupId })) ?? [];
  const ids = rows.flatMap((g) => [g.created_by, ...(g.top ?? []).map((t) => t.user_id)]);
  const profiles = await fetchProfiles(ids);
  const nm = (id) => profiles.get(id)?.display_name ?? "Member";
  return rows.map((g) => ({
    ...g,
    answer: g.answer == null ? null : toInt(g.answer),
    my_guess: g.my_guess == null ? null : toInt(g.my_guess),
    entries: toInt(g.entries),
    creator: nm(g.created_by),
    top: (g.top ?? []).map((t) => ({ ...t, guess: toInt(t.guess), diff: toInt(t.diff), name: nm(t.user_id) })),
  }));
}
