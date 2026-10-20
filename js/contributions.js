// Contributions: choose event + amount + network, start a payment through the trusted Edge Function,
// show pending / verified / failed states, and list contribution history.
// The browser can NEVER mark anything paid: status only changes server-side after provider verification.
import { state, activeGroup } from "./state.js";
import { fetchEvents, fetchEventFinancials, fetchContributions, fetchContributionStatus } from "./data.js";
import { invokeFunction } from "./supabase.js";
import { navigate, refresh } from "./router.js";
import { config } from "./config.js";
import { html, formatRWF, parseRWF, normalizeRwPhone, networkOfPhone, percent, sleep, formatNumber } from "./utils.js";
import {
  $, $$, mount, on, icon, toast, toastError, loadInto, freshView, setBusy, field, formData, formMessage, formMsgSlot,
  setFieldError, clearFieldErrors, emptyState, skeletonCards, progressBar, simBadge, badge,
} from "./ui.js";
import { contributionRow, methodLabel } from "./components.js";
import { hasPayDetails, accountCard, payInstructions, claimForm, submitClaim, bindCopyAndDial } from "./momo.js";
import { isManagerRole } from "./state.js";

const QUICK = [1000, 5000, 10000, 20000];
const POLL_MS = 5000;
const POLL_MAX = 60; // ~5 minutes

export async function renderContributions({ outlet, query, isCurrent }) {
  const group = activeGroup();
  if (!group) {
    mount(outlet, html`<div class="page-head"><h1>Contributions</h1></div>${emptyState({ iconName: "users", title: "Pick or create a group first", text: "Contributions go to an event inside a group.", actions: html`<a class="btn primary" href="#/groups">Go to my groups</a>` })}`);
    return;
  }
  const view = freshView(outlet);
  let scope = "mine";

  await loadInto(view, {
    isCurrent,
    skeleton: skeletonCards(2),
    load: async () => ({ events: (await fetchEvents([group.id])).filter((e) => e.status === "active") }),
    render: ({ events }) => {
      const selectedId = events.find((e) => e.id === query.event)?.id ?? events[0]?.id ?? null;

      mount(view, html`<div class="page-head"><div><h1>Contributions</h1><p class="sub">Save toward ${group.name}'s goals.</p></div></div>
        <div class="grid cols-2" style="align-items:start">
          <div class="card" data-pay-panel>${events.length ? panelFor(events, events.find((e) => e.id === selectedId), group) : emptyState({ iconName: "calendar", title: "No active events", text: "Ask an admin or treasurer to create an event first.", actions: html`<a class="btn" href="#/events">View events</a>` })}</div>
          <div data-summary></div>
        </div>
        <div class="section"><div class="section-head"><h2>History</h2>
          <div class="tabs" style="margin:0" role="tablist" aria-label="History scope">
            <button class="tab" role="tab" type="button" data-scope="mine" aria-selected="true">Mine</button>
            <button class="tab" role="tab" type="button" data-scope="group" aria-selected="false">Everyone</button></div></div>
          <div data-history></div></div>`);

      const refreshSummary = async () => {
        const id = $("select[name=event]", view)?.value ?? selectedId;
        const box = $("[data-summary]", view);
        if (!id || !box) return;
        const ev = events.find((e) => e.id === id);
        const fin = await fetchEventFinancials(id);
        if (!isCurrent()) return;
        const p = percent(fin.paid_total, ev.target_amount);
        mount(box, html`<div class="card"><p class="eyebrow">Event progress</p><h3 style="margin:6px 0 14px">${ev.name}</h3>
          <div class="mono"><strong style="font-family:var(--font-display);font-size:var(--fs-xl);color:var(--green)">${formatRWF(fin.paid_total)}</strong> <span class="muted">of ${formatRWF(ev.target_amount)}</span></div>
          <div style="margin-top:12px">${progressBar(p)}</div>
          <div class="progress-meta"><span>${p}% verified</span><span>${formatRWF(fin.remaining_amount)} to go</span></div>
          ${fin.pending_total > 0 ? html`<p class="faint" style="font-size:var(--fs-xs);margin-top:8px">${formatRWF(fin.pending_total)} pending. Counted only after confirmation.</p>` : ""}
          <p class="muted" style="font-size:var(--fs-sm);margin-top:14px">${icon("shield")} Only payments confirmed by your group leader count toward the target.</p></div>`);
      };

      const refreshHistory = async () => {
        const box = $("[data-history]", view);
        mount(box, html`<div class="skeleton sk-card" style="height:120px"></div>`);
        try {
          const rows = await fetchContributions({ groupId: group.id, userId: scope === "mine" ? state.user.id : null, limit: 50 });
          if (!isCurrent()) return;
          mount(box, rows.length
            ? html`<div class="card flush"><div class="list">${rows.map((c) => html`${contributionRow(c)}${c.user_id === state.user.id && c.status === "pending" ? pendingActions(c) : ""}`)}</div></div>`
            : emptyState({ iconName: "wallet", title: scope === "mine" ? "You haven't contributed yet" : "No contributions yet", text: "Your payments appear here with their live status." }));
        } catch (err) { toastError(err); mount(box, html`<p class="muted">Couldn't load history.</p>`); }
      };

      refreshSummary();
      refreshHistory();

      on(view, "change", "select[name=event]", () => { navigate(`/contributions?event=${$("select[name=event]", view).value}`); });
      on(view, "click", "[data-scope]", (_, b) => {
        scope = b.dataset.scope;
        $$("[data-scope]", view).forEach((t) => t.setAttribute("aria-selected", String(t === b)));
        refreshHistory();
      });
      on(view, "click", "[data-quick]", (_, b) => { const i = $("#f-amount", view); i.value = b.dataset.quick; i.focus(); i.dispatchEvent(new Event("input", { bubbles: true })); });
      bindCopyAndDial(view);
      const cur = events.find((e) => e.id === selectedId);
      const amountNow = () => { const a = parseRWF($("#f-amount", view)?.value ?? ""); return a && a >= config.limits.minContribution && a <= config.limits.maxContribution ? a : null; };
      on(view, "input", "#f-amount", () => {
        const box = $("[data-instructions]", view);
        if (box && cur && hasPayDetails(cur)) mount(box, payInstructions(cur, amountNow()));
      });
      const claim = $("form[data-claim]", view);
      claim?.addEventListener("submit", async (e) => {
        e.preventDefault();
        const panel = $("[data-pay-panel]", view);
        clearFieldErrors(panel);
        const amount = amountNow();
        if (!amount) { setFieldError(panel, "amount", `Enter between ${formatNumber(config.limits.minContribution)} and ${formatNumber(config.limits.maxContribution)} RWF.`); $("#f-amount", view)?.focus(); return; }
        const txnGiven = Boolean(String(new FormData(claim).get("txn") ?? "").trim());
        const newId = await submitClaim(claim, cur, amount);
        if (!newId) return;
        const verified = (await fetchContributionStatus(newId).catch(() => null)) === "paid";
        mount(panel, verified
          ? html`<div class="stack" style="text-align:center;justify-items:center"><div class="empty" style="border:0"><div class="ico">${icon("check")}</div><h3>Payment verified</h3>
            <p>${formatRWF(amount)} for ${cur.name} matched the leader's MoMo message and now counts toward the target. Thank you!</p></div>
            <button class="btn primary" type="button" data-again>Contribute again</button></div>`
          : html`<div class="stack" style="text-align:center;justify-items:center"><div class="empty" style="border:0"><div class="ico">${icon("clock")}</div><h3>Sent to your group leader</h3>
            <p>${formatRWF(amount)} for ${cur.name}. It counts toward the target as soon as the leader confirms it or the matching MoMo message arrives${txnGiven ? "" : " (your name and amount are checked automatically)"}. You'll see it as Verified in your history.</p></div>
            <button class="btn primary" type="button" data-again>Contribute again</button></div>`);
        refreshHistory(); refreshSummary();
      });
      on(view, "input", "#f-phone", () => {
        const n = normalizeRwPhone($("#f-phone", view).value);
        const net = n ? networkOfPhone(n) : null;
        if (net) { const r = $(`input[name=method][value=${net}]`, view); if (r) r.checked = true; }
      });
      on(view, "click", "[data-check]", async (_, b) => {
        setBusy(b, true, "Checking…");
        try { const r = await invokeFunction("verify-payment", { reference: b.dataset.check }); toast(statusToast(r.status), r.status === "paid" ? "success" : "info"); }
        catch (err) { toastError(err); }
        refreshHistory(); refreshSummary();
      });
      on(view, "click", "[data-sim]", async (_, b) => {
        setBusy(b, true, "Working…");
        try {
          const r = await invokeFunction("verify-payment", { reference: b.dataset.ref, simulate: b.dataset.sim });
          toast(statusToast(r.status), r.status === "paid" ? "success" : "info");
          if (r.status !== "pending" && $("[data-pending]", view)) { finish(r.status); return; }
        } catch (err) { toastError(err); }
        refreshHistory(); refreshSummary();
      });

      const form = $("form[data-pay]", view);
      form?.addEventListener("submit", (e) => { e.preventDefault(); submit(form); });

      async function submit(f) {
        clearFieldErrors(f);
        const v = formData(f);
        const amount = parseRWF(v.amount);
        const phone = normalizeRwPhone(v.phone);
        const bad = (n, m) => { setFieldError(f, n, m); $(`#f-${n}`, f)?.focus(); };
        if (!amount || amount < config.limits.minContribution || amount > config.limits.maxContribution) {
          return bad("amount", `Enter between ${formatNumber(config.limits.minContribution)} and ${formatNumber(config.limits.maxContribution)} RWF.`);
        }
        if (!v.method) return formMessage(f, "error", "Choose MTN Mobile Money or Airtel Money.");
        if (!phone) return bad("phone", "Enter a valid MTN (078/079) or Airtel (072/073) number.");
        if (networkOfPhone(phone) !== v.method) return bad("phone", `That number isn't on ${methodLabel(v.method)}.`);

        const btn = $('button[type="submit"]', f);
        setBusy(btn, true, "Starting payment…");
        try {
          const res = await invokeFunction("create-payment", { event_id: v.event, amount, method: v.method, phone });
          showPending($("[data-pay-panel]", view), res, amount, events.find((x) => x.id === v.event)?.name ?? "event");
          refreshHistory();
          poll(res);
        } catch (err) {
          formMessage(f, "error", err.message);
          setBusy(btn, false);
        }
      }

      async function poll(res) {
        if (res.mode !== "live") return; // simulated payments wait for the user's explicit simulate click
        for (let i = 0; i < POLL_MAX; i++) {
          await sleep(POLL_MS);
          if (!isCurrent()) return;
          try {
            const r = await invokeFunction("verify-payment", { reference: res.reference });
            if (r.status && r.status !== "pending") { finish(r.status); return; }
          } catch { /* transient: keep polling */ }
        }
        const slot = $("[data-pending-note]", view);
        if (slot) mount(slot, html`<p class="muted">Still waiting. You can leave this page. We'll keep checking, and your history shows the final status.</p>`);
      }

      function finish(status) {
        const panel = $("[data-pay-panel]", view);
        if (!panel) return;
        mount(panel, status === "paid"
          ? html`<div class="stack" style="text-align:center;justify-items:center"><div class="empty" style="border:0"><div class="ico">${icon("check")}</div><h3>Payment verified</h3><p>Thank you! Your contribution now counts toward the target.</p></div>
              <button class="btn primary" type="button" data-again>Contribute again</button></div>`
          : html`<div class="stack" style="text-align:center;justify-items:center"><div class="empty" style="border:0"><div class="ico" style="color:var(--danger)">${icon("alert")}</div><h3>Payment ${status}</h3><p>Nothing was added to the event. You can try again.</p></div>
              <button class="btn primary" type="button" data-again>Try again</button></div>`);
        refreshHistory(); refreshSummary();
      }
      on(view, "click", "[data-again]", () => refresh());
    },
  });
}

function statusToast(s) {
  return s === "paid" ? "Payment verified. Thank you!" : s === "failed" ? "That payment failed. Nothing was charged to the event." : s === "refunded" ? "That payment was refunded." : "Still pending. We'll keep checking.";
}

function pendingActions(c) {
  return html`<div class="list-item" style="background:rgba(251,191,36,.05);justify-content:flex-end;padding-top:8px;padding-bottom:8px">
    <span class="muted" style="font-size:var(--fs-sm);margin-right:auto">${c.provider === "manual" ? "Waiting for your group leader to confirm it." : "Waiting for confirmation."} Pending money isn't counted.</span>
    ${c.provider === "manual" ? "" : c.is_simulated
      ? html`<button class="btn sm" type="button" data-sim="success" data-ref="${c.payment_reference}">Simulate success</button><button class="btn sm ghost" type="button" data-sim="fail" data-ref="${c.payment_reference}">Simulate failure</button>`
      : html`<button class="btn sm" type="button" data-check="${c.payment_reference}">${icon("refresh")} Check status</button>`}</div>`;
}

function eventSelect(events, selectedId) {
  return html`<div class="field" data-field="event"><label for="f-event">Event</label>
    <select class="select" id="f-event" name="event">${events.map((e) => html`<option value="${e.id}" ${e.id === selectedId ? "selected" : ""}>${e.name}</option>`)}</select><div class="error" id="err-event" role="alert"></div></div>`;
}

/** Pick the right pay panel: the leader's MoMo number/code if set, else online payments (if enabled), else a notice. */
function panelFor(events, ev, group) {
  if (hasPayDetails(ev)) {
    const start = ev.expected_per_member && ev.expected_per_member >= config.limits.minContribution ? ev.expected_per_member : null;
    return html`<div class="stack">
      <div><h3>Make a contribution</h3><p class="muted" style="font-size:var(--fs-sm);margin-top:4px">Send from your own phone. It counts once the leader confirms it.</p></div>
      ${eventSelect(events, ev.id)}
      ${accountCard(ev)}
      ${field({ name: "amount", label: "Amount", prefix: "RWF", value: start ? String(start) : "", attrs: 'inputmode="numeric"', placeholder: "5000" })}
      <div class="row wrap" style="gap:8px">${QUICK.map((q) => html`<button class="btn sm ghost" type="button" data-quick="${q}">${formatNumber(q)}</button>`)}</div>
      <div data-instructions>${payInstructions(ev, start)}</div>
      ${claimForm()}
    </div>`;
  }
  if (config.onlinePayments) return payForm(events, ev.id);
  return html`<div class="stack">${eventSelect(events, ev.id)}
    ${emptyState({ iconName: "wallet", title: "No MoMo number yet", text: isManagerRole(group?.role) ? "Add your MoMo number or code to this event so members can pay you." : "The group leader hasn't added a MoMo number or code for this event yet.", actions: isManagerRole(group?.role) ? html`<a class="btn primary" href="#/events/${ev.id}">${icon("edit")} Add payment details</a>` : "" })}</div>`;
}

function payForm(events, selectedId) {
  return html`<form class="form" data-pay novalidate>
    <div><h3>Make a contribution</h3><p class="muted" style="font-size:var(--fs-sm);margin-top:4px">Counts only after your payment is confirmed.</p></div>
    <div class="field" data-field="event"><label for="f-event">Event</label>
      <select class="select" id="f-event" name="event">${events.map((e) => html`<option value="${e.id}" ${e.id === selectedId ? "selected" : ""}>${e.name}</option>`)}</select><div class="error" id="err-event" role="alert"></div></div>
    ${field({ name: "amount", label: "Amount", prefix: "RWF", attrs: 'inputmode="numeric"', placeholder: "5000" })}
    <div class="row wrap" style="gap:8px">${QUICK.map((q) => html`<button class="btn sm ghost" type="button" data-quick="${q}">${formatNumber(q)}</button>`)}</div>
    <fieldset style="border:0;padding:0;margin:0"><legend class="label" style="font-size:var(--fs-sm);color:var(--muted);margin-bottom:8px">Pay with</legend>
      <div class="radio-cards">
        <label class="radio-card"><input type="radio" name="method" value="mtn_momo"><span class="face"><strong>MTN Mobile Money</strong><span>078 / 079</span></span></label>
        <label class="radio-card"><input type="radio" name="method" value="airtel_money"><span class="face"><strong>Airtel Money</strong><span>072 / 073</span></span></label>
      </div></fieldset>
    ${field({ name: "phone", label: "Mobile money number", type: "tel", autocomplete: "tel", placeholder: "07X XXX XXXX", help: "The number that will approve the payment. We don't store it." })}
    ${formMsgSlot()}
    <button class="btn primary block" type="submit">${icon("wallet")} Contribute</button>
  </form>`;
}

function showPending(panel, res, amount, eventName) {
  const sim = res.mode === "simulated";
  mount(panel, html`<div class="stack" data-pending>
    <div class="row between"><h3>Payment pending</h3>${sim ? simBadge() : badge("pending")}</div>
    <p class="mono" style="font-family:var(--font-display);font-size:var(--fs-xl);font-weight:700">${formatRWF(amount)} <span class="muted" style="font-size:var(--fs-sm);font-weight:400">to ${eventName}</span></p>
    ${sim
      ? html`<div class="form-msg info"><strong>SIMULATED.</strong> No real money moves. This is a development payment. Choose an outcome to test the flow.</div>
        <div class="actions"><button class="btn primary" type="button" data-sim="success" data-ref="${res.reference}">Simulate success</button>
        <button class="btn" type="button" data-sim="fail" data-ref="${res.reference}">Simulate failure</button></div>`
      : html`<div class="form-msg info">${res.message ?? "Approve the prompt on your phone."}</div>
        ${res.checkout_url ? html`<a class="btn primary" href="${res.checkout_url}" target="_blank" rel="noopener noreferrer">Open secure payment page ${icon("arrow")}</a>` : ""}
        <div class="row" role="status"><span class="spinner" aria-hidden="true"></span><span class="muted">Waiting for the provider to confirm…</span></div>`}
    <div data-pending-note></div>
    <p class="faint" style="font-size:var(--fs-xs)">Reference ${res.reference}</p>
    <button class="btn ghost sm" type="button" data-again>Start another contribution</button>
  </div>`);
}
