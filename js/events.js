// Events: list, create, edit, detail with verified-only progress, contributors, expenses, history.
import { state, activeGroup, groupById, isManagerRole } from "./state.js";
import { fetchEvents, fetchEvent, fetchFinancials, fetchEventFinancials, fetchContributions, fetchExpenses, fetchEventProgress, fetchClaimHints, fetchCollectorActive, buildActivity, finOrEmpty } from "./data.js";
import { rpc } from "./supabase.js";
import { navigate } from "./router.js";
import { html, formatRWF, formatDate, parseRWF, percent, daysUntil } from "./utils.js";
import {
  $, mount, on, icon, badge, toast, toastError, openModal, confirmDialog, loadInto, freshView, setBusy,
  field, formData, formMessage, formMsgSlot, setFieldError, clearFieldErrors, statCard, emptyState, eventProgressCard,
  skeletonPage, skeletonCards, progressBar,
} from "./ui.js";
import { expenseRow, activityRows, openReceipt } from "./components.js";
import { openExpenseDialog } from "./expenses.js";
import {
  payFields, readPayFields, savePayDetails, hasPayDetails, accountCard, bindCopyAndDial, progressSection, reminderText,
  claimsQueue, reviewClaim, confirmWithReceipt, openRecordDialog, returnsPanel, openReturnDialog, returnAll,
} from "./momo.js";
import { uploadGroupImage, removeGroupImage, PHOTO_TYPES } from "./media.js";
import { copyText } from "./utils.js";

// ---------------------------------------------------------------------------
// Create / edit dialog
// ---------------------------------------------------------------------------
function eventForm(ev) {
  return html`<form class="form" novalidate>
    ${field({ name: "name", label: "Event name", value: ev?.name ?? "", placeholder: "e.g. Aline & Eric's wedding", attrs: 'maxlength="80" autofocus' })}
    ${field({ name: "target", label: "Target amount", value: ev ? String(ev.target_amount) : "", prefix: "RWF", attrs: 'inputmode="numeric"', help: "Whole RWF, no decimals." })}
    ${field({ name: "date", label: "Event date (optional)", type: "date", value: ev?.event_date ?? "", required: false })}
    <div class="field" data-field="cover"><label for="f-cover">Event picture (optional)</label>
      ${ev?.cover_path ? html`<div class="cover sm" data-sbimg="${ev.cover_path}" role="img" aria-label="Current picture"></div>
        <label class="check" style="margin-top:8px"><input type="checkbox" name="cover_remove" value="yes"><span>Remove the current picture</span></label>` : ""}
      <input class="input" id="f-cover" name="cover" type="file" accept="${PHOTO_TYPES.join(",")}" aria-describedby="err-cover">
      <div class="help">${ev?.cover_path ? "Choose a new file to replace it. " : ""}A wide photo works best. Large pictures are shrunk automatically.</div>
      <div class="error" id="err-cover" role="alert"></div></div>
    ${payFields(ev)}
    ${formMsgSlot()}
    <div class="foot"><button class="btn ghost" type="button" data-cancel>Cancel</button><button class="btn primary" type="submit">${ev ? "Save changes" : "Create event"}</button></div>
  </form>`;
}

function bindEventForm(m, onSubmit) {
  const form = $("form", m.el);
  $("[data-cancel]", m.el).addEventListener("click", () => m.close());
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    clearFieldErrors(form);
    const v = formData(form);
    const name = v.name.trim();
    const target = parseRWF(v.target);
    if (name.length < 2 || name.length > 80) return setFieldError(form, "name", "Use 2 to 80 characters.");
    if (!target) return setFieldError(form, "target", "Enter a whole amount in RWF, e.g. 500000.");
    const paid = readPayFields(form);
    if (!paid) return;
    const file = form.elements.cover?.files?.[0] ?? null;
    if (file && !PHOTO_TYPES.includes(file.type)) return setFieldError(form, "cover", "Use a JPG, PNG or WebP picture.");
    const cover = { file, remove: v.cover_remove === "yes" && !file };
    const btn = $('button[type="submit"]', form);
    setBusy(btn, true, "Saving…");
    try {
      await onSubmit({ name, target, date: v.date || null, pay: paid.pay, cover });
      m.close();
    } catch (err) {
      formMessage(form, "error", err.message);
      setBusy(btn, false);
    }
  });
}

/** Picture step of the event form. The event itself is already saved, so a failure here only warns. */
async function applyCover(eventId, groupId, cover) {
  if (!cover?.file && !cover?.remove) return;
  let path = null;
  try {
    if (cover.file) {
      path = await uploadGroupImage(groupId, state.user.id, cover.file);
      await rpc("set_event_cover", { p_event_id: eventId, p_path: path });
    } else {
      await rpc("set_event_cover", { p_event_id: eventId, p_path: null });
    }
  } catch (err) {
    if (path) removeGroupImage(path);
    toastError(err);
    toast("The event was saved, but the picture wasn't. Open the event and tap Edit to try again.", "info");
  }
}

export function openCreateEventDialog(group, onDone) {
  const m = openModal({ title: `New event in ${group.name}`, content: eventForm(null) });
  bindEventForm(m, async ({ name, target, date, pay, cover }) => {
    const id = await rpc("create_event", { p_group_id: group.id, p_name: name, p_target_amount: target, p_event_date: date });
    await applyCover(id, group.id, cover);
    if (pay.account || pay.expected) {
      try { await savePayDetails(id, pay); }
      catch (err) { toastError(err); toast("Event created, but the payment details weren't saved. Open the event and tap Edit.", "info"); }
    }
    toast("Event created.", "success");
    if (onDone) onDone(id); else navigate(`/events/${id}`);
  });
}

function openEditEventDialog(ev, onDone) {
  const m = openModal({ title: "Edit event", content: eventForm(ev) });
  bindEventForm(m, async ({ name, target, date, pay, cover }) => {
    await rpc("update_event", { p_event_id: ev.id, p_name: name, p_target_amount: target, p_event_date: date });
    await applyCover(ev.id, ev.group_id, cover);
    await savePayDetails(ev.id, pay);
    toast("Event updated.", "success");
    onDone();
  });
}

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------
const FILTERS = [["active", "Active"], ["completed", "Completed"], ["cancelled", "Cancelled"], ["all", "All"]];

export async function renderEvents({ outlet, query, isCurrent }) {
  const group = activeGroup();
  if (!group) {
    mount(outlet, html`<div class="page-head"><h1>Events</h1></div>${emptyState({ iconName: "users", title: "Pick or create a group first", text: "Events live inside a savings group.", actions: html`<a class="btn primary" href="#/groups">Go to my groups</a>` })}`);
    return;
  }
  const filter = FILTERS.some(([k]) => k === query.status) ? query.status : "active";
  const manager = isManagerRole(group.role);

  await loadInto(outlet, {
    isCurrent,
    skeleton: skeletonCards(3),
    load: async () => {
      const [events, fin] = await Promise.all([fetchEvents([group.id]), fetchFinancials([group.id])]);
      return { events, fin };
    },
    render: ({ events, fin }) => {
      const shown = filter === "all" ? events : events.filter((e) => e.status === filter);
      mount(outlet, html`<div class="page-head"><div><h1>Events</h1><p class="sub">in ${group.name}</p></div>
        ${manager ? html`<button class="btn primary" type="button" data-new>${icon("plus")} New event</button>` : ""}</div>
        <div class="tabs" role="tablist" aria-label="Filter events">${FILTERS.map(([k, label]) => html`<button class="tab" role="tab" type="button" aria-selected="${k === filter}" data-filter="${k}">${label}${k === "all" ? ` (${events.length})` : ` (${events.filter((e) => e.status === k).length})`}</button>`)}</div>
        ${shown.length
          ? html`<div class="grid auto">${shown.map((e) => html`${eventProgressCard(e, finOrEmpty(fin, e.id), `#/events/${e.id}`)}`)}</div>`
          : emptyState({ iconName: "calendar", title: filter === "active" ? "No active events" : "Nothing here", text: manager ? "Create an event with a target amount to start collecting contributions." : "An admin or treasurer will create events for this group." })}`);
      on(outlet, "click", "[data-filter]", (_, b) => navigate(`/events?status=${b.dataset.filter}`));
      on(outlet, "click", "[data-new]", () => openCreateEventDialog(group));
    },
  });
}

// ---------------------------------------------------------------------------
// Detail
// ---------------------------------------------------------------------------
export async function renderEventDetail({ outlet, params, isCurrent }) {
  const eventId = params.id;
  const draw = async () => {
    const view = freshView(outlet);
    await loadInto(view, {
      isCurrent,
      skeleton: skeletonPage(),
      load: async () => {
        const event = await fetchEvent(eventId);
        if (!event) return { event: null };
        const mgr = isManagerRole(groupById(event.group_id)?.role);
        const [fin, contributions, expenses, progress, claims, hints, collectorActive] = await Promise.all([
          fetchEventFinancials(eventId), fetchContributions({ eventId, limit: 200 }), fetchExpenses({ eventId, limit: 100 }),
          fetchEventProgress(eventId),
          mgr ? fetchContributions({ eventId, status: "pending", limit: 100 }) : Promise.resolve([]),
          mgr ? fetchClaimHints(eventId) : Promise.resolve([]),
          mgr ? fetchCollectorActive(event.group_id) : Promise.resolve(false),
        ]);
        return { event, fin, contributions, expenses, progress, claims: claims.filter((c) => c.provider === "manual"), hints, collectorActive };
      },
      render: ({ event, fin, contributions, expenses, progress, claims, hints, collectorActive }) => {
        if (!event) {
          mount(view, emptyState({ iconName: "lock", title: "Event not found", text: "It may not exist, or it belongs to a group you're not in.", actions: html`<a class="btn" href="#/events">Back to events</a>` }));
          return;
        }
        const group = groupById(event.group_id);
        const manager = isManagerRole(group?.role);
        const admin = group?.role === "admin";
        const target = event.target_amount;
        const p = percent(fin.paid_total, target);
        const days = daysUntil(event.event_date);
        const when = event.event_date ? `${formatDate(event.event_date)}${event.status === "active" && days !== null ? (days > 0 ? ` · in ${days} day${days === 1 ? "" : "s"}` : days === 0 ? " · today" : " · past") : ""}` : "No date set";

        mount(view, html`
          ${event.cover_path ? html`<div class="cover hero" data-sbimg="${event.cover_path}" role="img" aria-label="Picture for ${event.name}"></div>` : ""}
          <div class="page-head"><div><p class="eyebrow">${group?.name ?? "Group"}</p>
            <h1 style="margin-top:6px">${event.name}</h1>
            <p class="sub">${when}  ${badge(event.status)}</p></div>
            <div class="actions">
              ${event.status === "active" ? html`<a class="btn primary" href="#/contributions?event=${event.id}">${icon("wallet")} Contribute</a>` : ""}
              ${manager && event.status === "active" ? html`<button class="btn" type="button" data-record-any>${icon("plus")} Record payment</button>
                <button class="btn" type="button" data-expense>${icon("receipt")} Add expense</button>
                <button class="btn" type="button" data-edit>${icon("edit")} Edit</button>
                <button class="btn" type="button" data-status="completed">${icon("check")} Mark completed</button>
                <button class="btn danger" type="button" data-status="cancelled">${icon("x")} Cancel event</button>` : ""}
              ${admin && event.status !== "active" ? html`<button class="btn" type="button" data-status="active">${icon("refresh")} Reopen</button>` : ""}
            </div></div>

          <div class="card glow">
            <div class="row between wrap"><div><div class="muted" style="font-size:var(--fs-sm)">Verified collected</div>
              <div class="mono" style="font-family:var(--font-display);font-size:var(--fs-2xl);font-weight:700;color:var(--green);letter-spacing:-0.03em">${formatRWF(fin.paid_total)}</div></div>
              <div style="text-align:right"><div class="muted" style="font-size:var(--fs-sm)">Target</div><div class="mono" style="font-family:var(--font-display);font-size:var(--fs-xl);font-weight:600">${formatRWF(target)}</div></div></div>
            <div style="margin-top:18px">${progressBar(p, { label: `${event.name} progress` })}</div>
            <div class="progress-meta"><span><strong style="color:var(--text)">${p}%</strong> of target verified</span><span>${formatRWF(fin.remaining_amount)} remaining</span></div>
          </div>

          <div class="grid cols-4 section">
            ${statCard({ label: "Pending", value: formatRWF(fin.pending_total), hint: "Waiting for the leader to confirm. Not counted.", iconName: "clock" })}
            ${statCard({ label: "Failed / refunded", value: formatRWF(fin.failed_total + fin.refunded_total), hint: "Never counted as collected", iconName: "alert" })}
            ${statCard({ label: "Expenses", value: formatRWF(fin.expenses_total), tone: "violet", iconName: "receipt" })}
            ${statCard({ label: "Available funds", value: formatRWF(fin.available_funds), hint: "Verified − expenses", tone: "cyan", iconName: "wallet" })}
          </div>

          ${event.status === "active" ? html`<div class="section"><div class="section-head"><h2>How to pay</h2></div>
            ${hasPayDetails(event)
              ? html`<div class="grid cols-2" style="align-items:start">${accountCard(event)}
                  <div class="stack"><p class="muted">${event.expected_per_member ? html`Each member's share: <strong style="color:var(--text)">${formatRWF(event.expected_per_member)}</strong>. ` : ""}Pay from your own phone, then tap <strong style="color:var(--text)">Contribute</strong> to tell the leader.</p>
                  <a class="btn primary" href="#/contributions?event=${event.id}">${icon("wallet")} Pay now</a></div></div>`
              : manager
                ? emptyState({ iconName: "wallet", title: "Add your MoMo number or code", text: "Members need somewhere to send their contribution.", actions: html`<button class="btn primary" type="button" data-edit>${icon("edit")} Add payment details</button>` })
                : html`<p class="muted">The leader hasn't added a MoMo number or code yet.</p>`}</div>` : ""}

          ${manager ? returnsPanel(event, fin, contributions) : ""}

          ${manager ? claimsQueue(claims, hints, collectorActive) : ""}

          <div class="grid cols-2 section" style="align-items:start">
            <div>${progressSection(progress, event, { manager })}</div>
            <div><div class="section-head"><h2>Expenses</h2></div>
              ${expenses.length
                ? html`<div class="card flush"><div class="list">${expenses.map((x) => expenseRow(x, { showEvent: false }))}</div></div>`
                : emptyState({ iconName: "receipt", title: "No expenses", text: "Money spent for this event is listed here with receipts." })}</div>
          </div>

          <div class="section"><div class="section-head"><h2>Transaction history</h2></div>
            ${(() => { const items = buildActivity(contributions, expenses, 25); return items.length ? html`<div class="card flush"><div class="list">${activityRows(items)}</div></div>` : html`<p class="muted">No transactions yet.</p>`; })()}
          </div>`);

        on(view, "click", "[data-receipt]", (_, b) => openReceipt(b.dataset.receipt));
        bindCopyAndDial(view);
        on(view, "click", "[data-confirm-receipt]", async (_, b) => { if (await confirmWithReceipt(b.dataset.id, b.dataset.receipt, b.dataset.strength)) draw(); });
        on(view, "click", "[data-review]", async (_, b) => { if (await reviewClaim(b.dataset.id, b.dataset.review)) draw(); });
        on(view, "click", "[data-return]", (_, b) => openReturnDialog({ id: b.dataset.return, name: b.dataset.name, amount: b.dataset.amount, onDone: () => draw() }));
        on(view, "click", "[data-return-all]", () => returnAll(contributions, () => draw()));
        on(view, "click", "[data-record]", (_, b) => openRecordDialog({ event, rows: progress, userId: b.dataset.record, owed: Number(b.dataset.owed) || 0, onDone: () => draw() }));
        on(view, "click", "[data-record-any]", () => openRecordDialog({ event, rows: progress, onDone: () => draw() }));
        on(view, "click", "[data-remind]", async () => { if (await copyText(reminderText(progress, event, group?.name ?? "SquadVault"))) toast("Reminder copied. Paste it in your group chat.", "success"); });
        on(view, "click", "[data-edit]", () => openEditEventDialog(event, () => draw()));
        on(view, "click", "[data-expense]", () => openExpenseDialog({ event, fin, onDone: () => draw() }));
        on(view, "click", "[data-status]", async (_, b) => {
          const status = b.dataset.status;
          const copy = {
            completed: ["Mark as completed?", "No more contributions will be accepted. Recorded expenses are still allowed."],
            cancelled: ["Cancel this event?", "Contributions stop. Money already collected is NOT sent back automatically. This page will then list every payment so you can return it and mark it as returned."],
            active: ["Reopen this event?", "It will accept contributions again."],
          }[status];
          if (!(await confirmDialog({ title: copy[0], message: copy[1], confirmLabel: status === "cancelled" ? "Cancel event" : "Confirm", danger: status === "cancelled" }))) return;
          try { await rpc("set_event_status", { p_event_id: event.id, p_status: status }); toast("Event updated.", "success"); }
          catch (err) { toastError(err); }
          draw();
        });
      },
    });
  };
  await draw();
}
