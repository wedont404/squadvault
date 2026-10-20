// Groups: list, create, detail (events, members & roles, invitations, contributions, expenses, activity).
import { state, groupById, isManagerRole, setActiveGroup } from "./state.js";
import { fetchEvents, fetchFinancials, fetchMembers, fetchContributions, fetchExpenses, fetchMemberCounts, buildActivity, finOrEmpty } from "./data.js";
import { rpc } from "./supabase.js";
import { reloadGroups } from "./session.js";
import { navigate } from "./router.js";
import { html, formatRWF, sum, formatDate } from "./utils.js";
import {
  $, mount, on, icon, badge, avatar, toast, toastError, openModal, confirmDialog, loadInto, freshView, setBusy,
  field, formData, formMessage, formMsgSlot, setFieldError, clearFieldErrors, statCard, emptyState, eventProgressCard, skeletonPage, skeletonCards,
} from "./ui.js";
import { contributionRow, expenseRow, activityRows, openReceipt } from "./components.js";
import { openCreateEventDialog } from "./events.js";
import { mountInvitationPanel } from "./invitations.js";
import { openAddMemberDialog, returnsAlert } from "./momo.js";

// ---------------------------------------------------------------------------
// Create group
// ---------------------------------------------------------------------------
export function openCreateGroupDialog() {
  const m = openModal({
    title: "Create a group",
    content: html`<form class="form" novalidate>
      <p class="muted">You'll be the admin. Invite your squad with a private code once it's created.</p>
      ${field({ name: "name", label: "Group name", placeholder: "e.g. Kigali Besties", attrs: 'maxlength="60" autofocus' })}
      ${formMsgSlot()}
      <div class="foot"><button class="btn ghost" type="button" data-cancel>Cancel</button><button class="btn primary" type="submit">Create group</button></div>
    </form>`,
  });
  const form = $("form", m.el);
  $("[data-cancel]", m.el).addEventListener("click", () => m.close());
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    clearFieldErrors(form);
    const name = formData(form).name.trim();
    if (name.length < 2 || name.length > 60) return setFieldError(form, "name", "Use 2 to 60 characters.");
    const btn = $('button[type="submit"]', form);
    setBusy(btn, true, "Creating…");
    try {
      const id = await rpc("create_savings_group", { p_name: name });
      await reloadGroups(id);
      m.close();
      toast("Group created. You're the admin.", "success");
      navigate(`/groups/${id}`);
    } catch (err) {
      formMessage(form, "error", err.message);
      setBusy(btn, false);
    }
  });
}

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------
export async function renderGroups({ outlet, isCurrent }) {
  await loadInto(outlet, {
    isCurrent,
    skeleton: skeletonCards(3),
    load: async () => {
      const ids = state.groups.map((g) => g.id);
      const [counts, fin] = await Promise.all([fetchMemberCounts(ids), fetchFinancials(ids)]);
      const totals = new Map();
      for (const f of fin.values()) totals.set(f.group_id, (totals.get(f.group_id) ?? 0) + f.paid_total);
      return { counts, totals };
    },
    render: ({ counts, totals }) => {
      mount(outlet, html`<div class="page-head"><div><h1>My Groups</h1><p class="sub">Every squad you save with.</p></div>
        <div class="actions"><button class="btn" type="button" data-join>${icon("link")} Join with a code</button>
        <button class="btn primary" type="button" data-create>${icon("plus")} New group</button></div></div>
        ${state.groups.length
          ? html`<div class="grid auto">${state.groups.map((g) => html`<a class="card link" href="#/groups/${g.id}">
              <div class="row between"><h3>${g.name}</h3>${badge(g.role)}</div>
              <div class="stat" style="margin-top:14px"><div class="label">Verified savings</div><div class="value" style="color:var(--green)">${formatRWF(totals.get(g.id) ?? 0)}</div></div>
              <div class="progress-meta"><span>${counts.get(g.id) ?? 1} member${(counts.get(g.id) ?? 1) === 1 ? "" : "s"}</span><span>${g.id === state.activeGroupId ? "Current group" : `Joined ${formatDate(g.joined_at)}`}</span></div></a>`)}</div>`
          : emptyState({ iconName: "users", title: "No groups yet", text: "Create a private group, or join one with an invitation code.", actions: html`<button class="btn primary" type="button" data-create>${icon("plus")} Create a group</button>` })}`);
      on(outlet, "click", "[data-create]", () => openCreateGroupDialog());
      on(outlet, "click", "[data-join]", async () => (await import("./invitations.js")).openJoinDialog());
    },
  });
}

// ---------------------------------------------------------------------------
// Detail
// ---------------------------------------------------------------------------
export async function renderGroupDetail({ outlet, params, isCurrent }) {
  const groupId = params.id;
  const draw = async () => {
    const view = freshView(outlet);
    const group = groupById(groupId);
    if (!group) {
      mount(view, emptyState({ iconName: "lock", title: "Group not found", text: "It may not exist, or you may not be a member. Private groups are only visible to their members.", actions: html`<a class="btn" href="#/groups">Back to my groups</a>` }));
      return;
    }
    const manager = isManagerRole(group.role);
    const admin = group.role === "admin";

    await loadInto(view, {
      isCurrent,
      skeleton: skeletonPage(),
      load: async () => {
        const [members, events, fin, contributions, expenses] = await Promise.all([
          fetchMembers(groupId), fetchEvents([groupId]), fetchFinancials([groupId]),
          fetchContributions({ groupId, limit: 8 }), fetchExpenses({ groupId, limit: 8 }),
        ]);
        return { members, events, fin, contributions, expenses };
      },
      render: ({ members, events, fin, contributions, expenses }) => {
        const f = [...fin.values()];
        const memberCount = members.length;
        mount(view, html`
          <div class="page-head"><div><p class="eyebrow">${badge(group.role)} · ${memberCount} member${memberCount === 1 ? "" : "s"}</p>
            <h1 style="margin-top:6px">${group.name}</h1><p class="sub">Created ${formatDate(group.created_at)}</p></div>
            <div class="actions">
              ${group.id !== state.activeGroupId ? html`<button class="btn" type="button" data-make-current>${icon("check")} Make current</button>` : ""}
              <button class="btn ghost" type="button" data-leave>${icon("logout")} Leave group</button>
            </div></div>

          <div class="grid cols-4">
            ${statCard({ label: "Verified savings", value: formatRWF(sum(f, (x) => x.paid_total)), hint: "Paid contributions only", tone: "green", iconName: "shield" })}
            ${statCard({ label: "Pending", value: formatRWF(sum(f, (x) => x.pending_total)), hint: "Not counted as savings", iconName: "clock" })}
            ${statCard({ label: "Spent", value: formatRWF(sum(f, (x) => x.expenses_total)), hint: "Recorded expenses", tone: "violet", iconName: "receipt" })}
            ${statCard({ label: "Available", value: formatRWF(sum(f, (x) => x.available_funds)), hint: "Verified − expenses", tone: "cyan", iconName: "wallet" })}
          </div>

          ${manager ? returnsAlert(events, fin) : ""}

          <div class="section"><div class="section-head"><h2>Events</h2>
            ${manager ? html`<button class="btn sm primary" type="button" data-new-event>${icon("plus")} New event</button>` : ""}</div>
            ${events.length
              ? html`<div class="grid auto">${events.map((e) => eventProgressCard(e, finOrEmpty(fin, e.id), `#/events/${e.id}`))}</div>`
              : emptyState({ iconName: "calendar", title: "No events yet", text: manager ? "Create an event with a target to start saving." : "An admin or treasurer will add events here." })}
          </div>

          <div class="section"><div class="section-head"><h2>Members</h2>${admin ? html`<button class="btn sm primary" type="button" data-add-member>${icon("plus")} Add member</button>` : ""}</div>
            <div class="card flush"><div class="list">${members.map((m) => memberRow(m, { admin, me: state.user.id }))}</div></div></div>

          ${manager ? html`<div class="section"><div class="section-head"><h2>Invitations</h2></div><div data-invites></div></div>
            <div class="section"><div class="section-head"><h2>Payment checking</h2></div><div data-autocheck></div></div>` : ""}

          <div class="grid cols-2 section" style="align-items:start">
            <div><div class="section-head"><h2>Recent contributions</h2></div>
              ${contributions.length ? html`<div class="card flush"><div class="list">${contributions.map((c) => contributionRow(c))}</div></div>` : emptyState({ iconName: "wallet", title: "No contributions yet", text: "They'll appear here the moment someone contributes." })}</div>
            <div><div class="section-head"><h2>Expenses</h2><a href="#/expenses">Manage</a></div>
              ${expenses.length ? html`<div class="card flush"><div class="list">${expenses.map((x) => expenseRow(x, {}))}</div></div>` : emptyState({ iconName: "receipt", title: "No expenses", text: "Recorded expenses show up here with their receipts." })}</div>
          </div>

          <div class="section"><div class="section-head"><h2>Activity</h2></div>
            ${(() => { const a = buildActivity(contributions, expenses, 10); return a.length ? html`<div class="card flush"><div class="list">${activityRows(a)}</div></div>` : html`<p class="muted">No activity yet.</p>`; })()}
          </div>`);

        if (manager) {
          mountInvitationPanel($("[data-invites]", view), groupId);
          import("./autocheck.js").then((m) => m.mountAutoCheckPanel($("[data-autocheck]", view), group));
        }

        on(view, "click", "[data-make-current]", () => { setActiveGroup(groupId); toast(`Now viewing ${group.name}.`, "success"); draw(); });
        on(view, "click", "[data-add-member]", () => openAddMemberDialog(group, () => draw()));
        on(view, "click", "[data-new-event]", () => openCreateEventDialog(group, () => draw()));
        on(view, "click", "[data-receipt]", (_, b) => openReceipt(b.dataset.receipt));
        on(view, "change", "[data-role-select]", async (_, sel) => {
          const target = sel.dataset.roleSelect;
          const role = sel.value;
          if (!(await confirmDialog({ title: "Change role?", message: `Set this member's role to ${role}?`, confirmLabel: "Change role" }))) return draw();
          try { await rpc("set_member_role", { p_group_id: groupId, p_user_id: target, p_role: role }); toast("Role updated.", "success"); }
          catch (err) { toastError(err); }
          draw();
        });
        on(view, "click", "[data-remove]", async (_, b) => {
          if (!(await confirmDialog({ title: "Remove member?", message: `${b.dataset.name} will lose access to this group.`, confirmLabel: "Remove", danger: true }))) return;
          try { await rpc("remove_member", { p_group_id: groupId, p_user_id: b.dataset.remove }); toast("Member removed.", "success"); }
          catch (err) { toastError(err); }
          draw();
        });
        on(view, "click", "[data-leave]", async () => {
          if (!(await confirmDialog({ title: `Leave ${group.name}?`, message: "You'll lose access to this group's events and records. Your past contributions stay on record.", confirmLabel: "Leave group", danger: true }))) return;
          try {
            await rpc("leave_group", { p_group_id: groupId });
            await reloadGroups();
            toast("You left the group.", "success");
            navigate("/groups");
          } catch (err) { toastError(err); }
        });
      },
    });
  };
  await draw();
}

function memberRow(m, { admin, me }) {
  const self = m.user_id === me;
  return html`<div class="list-item">${avatar(m.name, m.avatar_path)}
    <div class="grow"><div class="title">${m.name}${self ? " (you)" : ""}</div><div class="sub">Joined ${formatDate(m.joined_at)}</div></div>
    ${admin && !self
      ? html`<label class="sr-only" for="role-${m.user_id}">Role for ${m.name}</label>
        <select class="select" style="width:auto;min-height:36px" id="role-${m.user_id}" data-role-select="${m.user_id}">
          ${["admin", "treasurer", "member"].map((r) => html`<option value="${r}" ${r === m.role ? "selected" : ""}>${r[0].toUpperCase() + r.slice(1)}</option>`)}</select>
        <button class="btn sm danger" type="button" data-remove="${m.user_id}" data-name="${m.name}" aria-label="Remove ${m.name}">${icon("trash")}</button>`
      : badge(m.role)}</div>`;
}
