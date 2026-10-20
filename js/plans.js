// Plans (Free / Plus / Pro) per group. Limits are enforced by the database; this file only shows them and
// lets a group admin ask for an upgrade. The owner approves after receiving the MoMo payment (owner.js).
import { rpc, friendlyError } from "./supabase.js";
import { config } from "./config.js";
import { fetchPlanOverview } from "./data.js";
import { html, formatRWF, formatDate, copyText, timeAgo } from "./utils.js";
import {
  $, mount, on, icon, toast, toastError, openModal, confirmDialog, setBusy, field, formData, formMessage, formMsgSlot,
  setFieldError, clearFieldErrors, progressBar,
} from "./ui.js";

const usageRow = (label, used, max) => html`<div style="display:grid;gap:4px">
  <div class="row between" style="font-size:var(--fs-sm)"><span>${label}</span><span class="muted">${used} of ${max ?? "unlimited"}</span></div>
  ${max ? progressBar(Math.min(100, Math.round((used / max) * 100)), { thin: true, label: label }) : ""}</div>`;

/** Renders the plan card into `el`. Returns the overview so callers can react to it (e.g. lock features). */
export async function mountPlanPanel(el, group, { onChange } = {}) {
  let ov;
  try { ov = await fetchPlanOverview(group.id); }
  catch (err) { mount(el, html`<p class="muted">Couldn't load the plan. ${friendlyError(err)}</p>`); return null; }
  const free = ov.plan === "free";
  const pend = ov.pending;
  mount(el, html`<div class="card stack" style="gap:14px">
    <div class="row between wrap" style="gap:10px"><div><h3 style="margin:0">${ov.plan_name} plan</h3>
      <p class="muted" style="font-size:var(--fs-sm);margin-top:4px">${free
        ? (ov.expired ? `Your ${ov.booked_plan === "pro" ? "Pro" : "Plus"} plan ended. Existing members, events and photos are kept. Renew to add more.` : "Free forever for small groups. Upgrade for more members, unlimited events and automatic payment checking.")
        : `Active until ${formatDate(ov.until)}.`}</p></div>
      <span class="badge ${free ? "" : "active"}">${ov.plan_name}</span></div>
    <div class="grid cols-2" style="gap:12px">
      ${usageRow("Members", ov.usage.members, ov.limits.members)}
      ${usageRow("Active events", ov.usage.events, ov.limits.events)}
      ${usageRow("Photos", ov.usage.photos, ov.limits.photos)}
      <div style="display:grid;gap:4px"><div class="row between" style="font-size:var(--fs-sm)"><span>Automatic payment checking</span><span class="${ov.limits.auto_check ? "" : "muted"}">${ov.limits.auto_check ? "Included" : "Plus or Pro"}</span></div></div></div>
    ${pend ? html`<div class="form-msg info" role="status">${icon("clock")} Upgrade request for <strong>${pend.plan === "pro" ? "Pro" : "Plus"}</strong> (${pend.period === "year" ? "yearly" : "monthly"}, ${formatRWF(pend.amount)}) is waiting for approval. Payment ID ${pend.txn_ref}, sent ${timeAgo(pend.created_at)}. This is usually done within a day.
      ${ov.is_admin ? html`<div style="margin-top:8px"><button class="btn sm" type="button" data-cancel-req>Cancel request</button></div>` : ""}</div>`
      : ov.last_rejected ? html`<div class="form-msg warn" role="status">Your last upgrade request wasn't approved: ${ov.last_rejected.note ?? "payment not found"}. You can send a new one.</div>` : ""}
    ${!pend ? (ov.is_admin
      ? html`<div class="actions"><button class="btn primary" type="button" data-upgrade>${icon("trend")} ${free ? "Upgrade this group" : "Renew or change plan"}</button></div>`
      : html`<p class="faint" style="font-size:var(--fs-xs)">Only the group admin can change the plan.</p>`) : ""}
  </div>`);
  on(el, "click", "[data-upgrade]", () => openUpgradeDialog(group, ov, () => { onChange?.(); mountPlanPanel(el, group, { onChange }); }));
  on(el, "click", "[data-cancel-req]", async () => {
    if (!(await confirmDialog({ title: "Cancel the upgrade request?", message: "If you already paid, don't cancel. Wait for approval or contact the owner with your payment ID.", confirmLabel: "Cancel request", danger: true }))) return;
    try { await rpc("cancel_plan_request", { p_group_id: group.id }); toast("Request cancelled.", "success"); mountPlanPanel(el, group, { onChange }); } catch (err) { toastError(err); }
  });
  return ov;
}

const FEATURES = (p) => [
  `Up to ${p.members.toLocaleString("en")} members`,
  p.events ? `${p.events} active events` : "Unlimited active events",
  `${p.photos.toLocaleString("en")} photos on the wall`,
  p.auto_check ? "Automatic MoMo payment checking" : "Manual payment confirmation",
];

export function openUpgradeDialog(group, ov, onDone) {
  const paid = ov.plans.filter((p) => p.code !== "free");
  const b = config.billing ?? {};
  const ready = Boolean(b.momoNumber);
  const m = openModal({
    title: `Upgrade ${group.name}`,
    content: html`<form class="form" novalidate>
      <div class="radio-cards">${paid.map((p, i) => html`<label class="radio-card"><input type="radio" name="plan" value="${p.code}" ${i === 0 ? "checked" : ""}><span class="face"><strong>${p.name}</strong><span>${formatRWF(p.price_month)}/month</span></span></label>`)}</div>
      <div data-features class="muted" style="font-size:var(--fs-sm)"></div>
      <div class="radio-cards"><label class="radio-card"><input type="radio" name="period" value="month" checked><span class="face"><strong>Monthly</strong><span data-pm></span></span></label>
        <label class="radio-card"><input type="radio" name="period" value="year"><span class="face"><strong>Yearly</strong><span data-py></span></span></label></div>
      ${ready ? html`<div class="card" style="box-shadow:none"><ol class="steps" style="margin:0">
          <li>Send <strong style="color:var(--text)" data-amount></strong> by MoMo to <strong style="color:var(--text)">${b.momoName || "SquadVault"}</strong> on <span class="mono" style="color:var(--green)">${b.momoNumber}</span> <button class="btn sm" type="button" data-copy="${b.momoNumber}">${icon("copy")} Copy number</button></li>
          <li>Type the <strong style="color:var(--text)">transaction ID</strong> from your MoMo confirmation message below.</li>
          <li>We check the payment and switch your plan on, usually within a day.</li></ol></div>
        ${field({ name: "txn", label: "MoMo transaction ID", placeholder: "From the confirmation SMS", attrs: 'maxlength="20" autocapitalize="characters"' })}`
        : html`<div class="form-msg warn">Upgrades aren't switched on yet. ${b.contact ? `Contact ${b.contact}.` : "Please try again soon."}</div>`}
      ${formMsgSlot()}
      <div class="foot"><button class="btn ghost" type="button" data-cancel>Cancel</button>${ready ? html`<button class="btn primary" type="submit">Send upgrade request</button>` : ""}</div></form>`,
  });
  const form = $("form", m.el);
  const cur = () => paid.find((p) => p.code === formData(form).plan) ?? paid[0];
  const sync = () => {
    const p = cur();
    $("[data-features]", form).innerHTML = `<ul style="margin:0;padding-left:18px">${FEATURES(p).map((f) => `<li>${f}</li>`).join("")}</ul>`;
    $("[data-pm]", form).textContent = `${formatRWF(p.price_month)}`;
    $("[data-py]", form).textContent = `${formatRWF(p.price_year)} · 2 months free`;
    const a = $("[data-amount]", form);
    if (a) a.textContent = formatRWF(formData(form).period === "year" ? p.price_year : p.price_month);
  };
  form.addEventListener("change", sync);
  sync();
  $("[data-cancel]", m.el).addEventListener("click", () => m.close());
  on(form, "click", "[data-copy]", async (_, btn) => { if (await copyText(btn.dataset.copy)) toast("Number copied.", "success"); });
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    clearFieldErrors(form);
    const v = formData(form);
    const txn = String(v.txn ?? "").trim();
    if (!/^[A-Za-z0-9]{6,20}$/.test(txn)) return setFieldError(form, "txn", "6 to 20 letters or numbers, from your MoMo message.");
    const btn = $('button[type="submit"]', form);
    setBusy(btn, true, "Sending…");
    try {
      await rpc("request_plan_upgrade", { p_group_id: group.id, p_plan: v.plan, p_period: v.period, p_txn_ref: txn });
      toast("Request sent. We'll switch your plan on once we see the payment.", "success");
      m.close();
      onDone?.();
    } catch (err) { formMessage(form, "error", friendlyError(err)); setBusy(btn, false); }
  });
}
