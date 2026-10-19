// Leader-managed Mobile Money collection: payment details, pay instructions with a copyable USSD
// shortcut, the "I've paid" claim, leader confirmation, and the who-has-paid progress list.
// The browser never marks anything paid: claims are PENDING until a leader confirms them (RPC).
import { html, formatRWF, parseRWF, normalizeRwPhone, networkOfPhone, ussdFor, telHref, prettyPhone, copyText, percent, timeAgo } from "./utils.js";
import { rpc } from "./supabase.js";
import { config } from "./config.js";
import {
  $, on, icon, badge, avatar, toast, toastError, openModal, confirmDialog, setBusy,
  field, formData, formMessage, formMsgSlot, setFieldError, clearFieldErrors, progressBar, emptyState,
} from "./ui.js";
import { methodLabel } from "./components.js";

const NET = { mtn_momo: "MTN", airtel_money: "Airtel" };

export const hasPayDetails = (ev) => Boolean(ev?.pay_account && ev?.pay_provider);
export const accountText = (ev) => (ev.pay_kind === "number" ? prettyPhone(ev.pay_account) : ev.pay_account);
export const accountKindLabel = (ev) => `${NET[ev.pay_provider] ?? ""} MoMo ${ev.pay_kind === "code" ? "code" : "number"}`.trim();

// ---------------------------------------------------------------------------
// Leader: payment-details fields inside the create / edit event dialog
// ---------------------------------------------------------------------------
export function payFields(ev) {
  const prov = ev?.pay_provider ?? "mtn_momo";
  return html`<fieldset style="border:0;padding:0;margin:0;display:grid;gap:var(--s4)">
    <legend class="label" style="font-size:var(--fs-sm);color:var(--muted);margin-bottom:8px">How should members pay you? <span class="faint">(you can add this later)</span></legend>
    <div class="radio-cards">
      <label class="radio-card"><input type="radio" name="pay_provider" value="mtn_momo" ${prov === "mtn_momo" ? "checked" : ""}><span class="face"><strong>MTN MoMo</strong><span>078 / 079</span></span></label>
      <label class="radio-card"><input type="radio" name="pay_provider" value="airtel_money" ${prov === "airtel_money" ? "checked" : ""}><span class="face"><strong>Airtel Money</strong><span>072 / 073</span></span></label>
    </div>
    <div class="field" data-field="pay_kind"><label for="f-pay_kind">Members send to</label>
      <select class="select" id="f-pay_kind" name="pay_kind">
        <option value="number" ${ev?.pay_kind !== "code" ? "selected" : ""}>A phone number</option>
        <option value="code" ${ev?.pay_kind === "code" ? "selected" : ""}>A MoMo code (merchant code)</option></select>
      <div class="error" id="err-pay_kind" role="alert"></div></div>
    ${field({ name: "pay_account", label: "MoMo number or code", value: ev?.pay_account ?? "", placeholder: "0788 123 456 or 123456", required: false, attrs: 'inputmode="numeric" maxlength="20"', help: "Leave empty to remove the payment details." })}
    ${field({ name: "pay_account_name", label: "Name on the account (optional)", value: ev?.pay_account_name ?? "", placeholder: "Shown to members so they can check it", required: false, attrs: 'maxlength="60"' })}
    ${field({ name: "expected", label: "Amount expected from each member (optional)", value: ev?.expected_per_member ? String(ev.expected_per_member) : "", prefix: "RWF", required: false, attrs: 'inputmode="numeric"', help: "Used to show who is fully paid and who has only part paid." })}
  </fieldset>`;
}

/** Validate the payFields() of a form. Returns {pay} or null after showing field errors. */
export function readPayFields(form) {
  const v = formData(form);
  const account = String(v.pay_account ?? "").trim();
  const expectedRaw = String(v.expected ?? "").trim();
  const expected = expectedRaw ? parseRWF(expectedRaw) : null;
  if (expectedRaw && !expected) { setFieldError(form, "expected", "Enter a whole amount in RWF."); return null; }
  if (!account) return { pay: { provider: null, kind: null, account: "", accountName: null, expected } };
  const provider = v.pay_provider;
  const kind = v.pay_kind;
  let clean = account.replace(/[\s-]/g, "");
  if (kind === "number") {
    const n = normalizeRwPhone(clean);
    if (!n) { setFieldError(form, "pay_account", "Enter a valid MTN (078/079) or Airtel (072/073) number."); return null; }
    if (networkOfPhone(n) !== provider) { setFieldError(form, "pay_account", `That number isn't on ${methodLabel(provider)}.`); return null; }
    clean = `0${n.slice(3)}`;
  } else if (!/^\d{4,10}$/.test(clean)) {
    setFieldError(form, "pay_account", "A MoMo code is 4 to 10 digits.");
    return null;
  }
  return { pay: { provider, kind, account: clean, accountName: String(v.pay_account_name ?? "").trim() || null, expected } };
}

export const savePayDetails = (eventId, p) =>
  rpc("set_event_payment_details", {
    p_event_id: eventId, p_provider: p.provider, p_kind: p.kind, p_account: p.account,
    p_account_name: p.accountName, p_expected_per_member: p.expected,
  });

// ---------------------------------------------------------------------------
// Member: how to pay (instructions + USSD shortcut + "I've paid")
// ---------------------------------------------------------------------------
export function accountCard(ev) {
  return html`<div class="acct">
    <span class="muted" style="font-size:var(--fs-sm)">Send to this ${accountKindLabel(ev)}</span>
    <div class="row between wrap"><span class="big">${accountText(ev)}</span>
      <button class="btn sm" type="button" data-copy="${ev.pay_account}">${icon("copy")} Copy</button></div>
    ${ev.pay_account_name ? html`<span class="muted" style="font-size:var(--fs-sm)">Name on account: <strong style="color:var(--text)">${ev.pay_account_name}</strong></span>` : ""}
  </div>`;
}

export function payInstructions(ev, amount) {
  const ussd = ussdFor({ provider: ev.pay_provider, kind: ev.pay_kind, account: ev.pay_account, amount });
  const net = NET[ev.pay_provider] ?? "MoMo";
  return html`<div class="stack">
    ${ussd
      ? html`<div><p class="label" style="font-size:var(--fs-sm);color:var(--muted);margin-bottom:6px">Dial this on your ${net} phone</p>
          <div class="code-box sm"><span data-ussd>${ussd}</span><button class="btn sm" type="button" data-copy="${ussd}" data-copy-ussd>${icon("copy")} Copy</button></div></div>
        <button class="btn primary block" type="button" data-dial="${ussd}">${icon("phone")} Pay with ${net} MoMo</button>`
      : html`<div class="form-msg info">Open Airtel Money on your phone (dial <strong>*500#</strong>), choose <strong>Send money</strong>, enter <strong>${accountText(ev)}</strong>${amount ? html` and the amount <strong>${formatRWF(amount)}</strong>` : ""}, then confirm with your PIN.</div>
        <button class="btn primary block" type="button" data-dial="*500#">${icon("phone")} Open Airtel Money</button>`}
    <ol class="steps">
      <li>Tap the button (or dial the code yourself). ${net} opens its own menu.</li>
      <li><strong style="color:var(--text)">${net} asks for your PIN on its own screen.</strong> Enter it there only. SquadVault never asks for your PIN.</li>
      <li>When you get the confirmation SMS, come back and tap <strong style="color:var(--text)">I've paid</strong> below.</li>
    </ol>
    ${ussd ? html`<p class="faint" style="font-size:var(--fs-xs)">If the shortcut doesn't work on your phone, dial *182# and pick Send money${ev.pay_kind === "code" ? " / Pay merchant" : ""}, then enter ${ev.pay_account} yourself.</p>` : ""}
  </div>`;
}

/** Opens the dialer after telling the member that MTN/Airtel will ask for their PIN. */
export async function dialWithNotice(ussd) {
  const ok = await confirmDialog({
    title: "Enter your PIN on the MoMo screen",
    message: "Your phone will open the mobile money menu with the details filled in. The network will ask for your PIN on its own screen. Type it only there. SquadVault never sees it.",
    confirmLabel: "Open MoMo",
  });
  if (ok) window.location.href = telHref(ussd);
}

export function claimForm() {
  return html`<form class="form" data-claim novalidate>
    <div><h4 style="margin:0">After you have paid</h4><p class="muted" style="font-size:var(--fs-sm);margin-top:4px">Tell the group leader. It counts once they confirm it.</p></div>
    ${field({ name: "txn", label: "MoMo transaction ID (optional)", placeholder: "From the confirmation SMS", required: false, attrs: 'maxlength="20" autocapitalize="characters"', help: "Helps the leader find your payment quickly." })}
    ${formMsgSlot()}
    <button class="btn primary block" type="submit">${icon("check")} I've paid</button>
  </form>`;
}

export async function submitClaim(form, ev, amount) {
  clearFieldErrors(form);
  const txn = String(formData(form).txn ?? "").trim();
  if (txn && !/^[A-Za-z0-9]{6,20}$/.test(txn)) { setFieldError(form, "txn", "6 to 20 letters or numbers, or leave empty."); return false; }
  const btn = $('button[type="submit"]', form);
  setBusy(btn, true, "Sending…");
  try {
    await rpc("submit_payment_claim", { p_event_id: ev.id, p_amount: amount, p_txn_ref: txn || null });
    return true;
  } catch (err) {
    formMessage(form, "error", err.message);
    setBusy(btn, false);
    return false;
  }
}

/** Delegated copy / dial handlers. Bind once per view. */
export function bindCopyAndDial(view) {
  on(view, "click", "[data-copy]", async (_, b) => { if (await copyText(b.dataset.copy)) toast("Copied.", "success"); });
  on(view, "click", "[data-dial]", (_, b) => dialWithNotice(b.dataset.dial));
}

// ---------------------------------------------------------------------------
// Everyone: who has paid, who has not
// ---------------------------------------------------------------------------
export function paidState(r, expected) {
  if (r.paid_total > 0 && (!expected || r.paid_total >= expected)) return "paid";
  if (r.paid_total > 0) return "partial";
  if (r.pending_total > 0) return "pending";
  return "unpaid";
}

export function progressSummary(rows, expected) {
  const members = rows.filter((r) => r.role);
  const paid = members.filter((r) => paidState(r, expected) === "paid").length;
  return { members, paid, total: members.length, pct: percent(paid, members.length) };
}

export function progressSection(rows, ev, { manager }) {
  const expected = ev.expected_per_member;
  const { members, paid, total, pct } = progressSummary(rows, expected);
  const todo = members.filter((r) => paidState(r, expected) !== "paid").sort((a, b) => a.name.localeCompare(b.name));
  const done = members.filter((r) => paidState(r, expected) === "paid").sort((a, b) => b.paid_total - a.paid_total);
  const left = rows.filter((r) => !r.role && r.paid_total > 0);

  const row = (r) => {
    const st = paidState(r, expected);
    const owed = expected ? Math.max(expected - r.paid_total, 0) : 0;
    return html`<div class="list-item">${avatar(r.name, r.avatar_path)}
      <div class="grow"><div class="title">${r.name}</div>
        <div class="sub">${r.paid_total > 0 ? `${formatRWF(r.paid_total)} paid${r.last_paid_at ? ` · ${timeAgo(r.last_paid_at)}` : ""}` : "Nothing paid yet"}${r.pending_total > 0 ? ` · ${formatRWF(r.pending_total)} waiting for confirmation` : ""}${st === "partial" && owed ? ` · ${formatRWF(owed)} to go` : ""}</div></div>
      ${badge(st)}
      ${manager && ev.status === "active" && st !== "paid" ? html`<button class="btn sm" type="button" data-record="${r.user_id}" data-name="${r.name}" data-owed="${owed}">${icon("plus")} Record</button>` : ""}
    </div>`;
  };

  return html`<div class="section-head"><h2>Who has paid</h2>
      ${manager && todo.length ? html`<button class="btn sm" type="button" data-remind>${icon("copy")} Copy reminder</button>` : ""}</div>
    <div class="card">
      <div class="row between wrap"><strong style="font-family:var(--font-display);font-size:var(--fs-lg)">${paid} of ${total} paid</strong><span class="muted">${total - paid} still to go</span></div>
      <div style="margin-top:12px">${progressBar(pct, { label: "Members who have paid" })}</div>
    </div>
    ${total === 0 ? emptyState({ iconName: "users", title: "No members yet", text: "Invite your squad to see their progress here." }) : html`
      ${todo.length ? html`<h3 style="margin:18px 0 8px;font-size:var(--fs-md)">Still to pay (${todo.length})</h3><div class="card flush"><div class="list">${todo.map(row)}</div></div>` : html`<p class="muted" style="margin-top:14px">${icon("check")} Everyone has paid. 🎉</p>`}
      ${done.length ? html`<h3 style="margin:18px 0 8px;font-size:var(--fs-md)">Paid (${done.length})</h3><div class="card flush"><div class="list">${done.map(row)}</div></div>` : ""}
      ${left.length ? html`<h3 style="margin:18px 0 8px;font-size:var(--fs-md)">Paid, then left the group</h3><div class="card flush"><div class="list">${left.map((r) => html`<div class="list-item">${avatar(r.name, r.avatar_path)}<div class="grow"><div class="title">${r.name}</div><div class="sub">${formatRWF(r.paid_total)} paid</div></div>${badge("left")}</div>`)}</div></div>` : ""}`}`;
}

export function reminderText(rows, ev, groupName) {
  const todo = rows.filter((r) => r.role && paidState(r, ev.expected_per_member) !== "paid").map((r) => r.name);
  const how = hasPayDetails(ev) ? ` Please send ${ev.expected_per_member ? formatRWF(ev.expected_per_member) : "your contribution"} to ${accountKindLabel(ev)} ${accountText(ev)}${ev.pay_account_name ? ` (${ev.pay_account_name})` : ""}, then tap "I've paid" in SquadVault.` : "";
  return `${groupName}: reminder for "${ev.name}".${how}\nStill to pay: ${todo.join(", ")}.`;
}

// ---------------------------------------------------------------------------
// Leader: confirm / reject claims, record a payment, add a member
// ---------------------------------------------------------------------------
export function claimsQueue(claims) {
  if (!claims.length) return "";
  return html`<div class="section"><div class="section-head"><h2>Waiting for your confirmation</h2></div>
    <div class="card flush"><div class="list">${claims.map((c) => html`<div class="list-item">${avatar(c.name, c.avatar_path)}
      <div class="grow"><div class="title">${c.name} · ${formatRWF(c.amount)}</div>
        <div class="sub">${methodLabel(c.payment_method)} · ${timeAgo(c.created_at)}${c.provider_ref ? ` · ID ${c.provider_ref}` : " · no transaction ID"}</div></div>
      <div class="acts"><button class="btn sm primary" type="button" data-review="paid" data-id="${c.id}">${icon("check")} Received</button>
        <button class="btn sm danger" type="button" data-review="failed" data-id="${c.id}">${icon("x")} Not received</button></div>
    </div>`)}</div></div>
    <p class="faint" style="font-size:var(--fs-xs);margin-top:8px">Check your MoMo messages before confirming. Only confirmed payments count toward the target.</p></div>`;
}

export async function reviewClaim(id, decision) {
  const ok = await confirmDialog({
    title: decision === "paid" ? "Confirm you received this?" : "Mark as not received?",
    message: decision === "paid" ? "It will count toward the event total." : "It will not be counted. The member can submit again.",
    confirmLabel: decision === "paid" ? "Yes, received" : "Not received",
    danger: decision !== "paid",
  });
  if (!ok) return false;
  try { await rpc("review_contribution", { p_contribution_id: id, p_decision: decision, p_reason: null }); toast(decision === "paid" ? "Payment confirmed." : "Marked as not received.", "success"); return true; }
  catch (err) { toastError(err); return false; }
}

export function openRecordDialog({ event, rows, userId = null, owed = 0, onDone }) {
  const members = rows.filter((r) => r.role);
  const m = openModal({
    title: "Record a payment",
    content: html`<form class="form" novalidate>
      <p class="muted">For money you received yourself (cash, or MoMo you saw on your phone). It is counted straight away.</p>
      <div class="field" data-field="user"><label for="f-user">Member</label>
        <select class="select" id="f-user" name="user">${members.map((r) => html`<option value="${r.user_id}" ${r.user_id === userId ? "selected" : ""}>${r.name}</option>`)}</select><div class="error" id="err-user" role="alert"></div></div>
      ${field({ name: "amount", label: "Amount", prefix: "RWF", value: owed ? String(owed) : event.expected_per_member ? String(event.expected_per_member) : "", attrs: 'inputmode="numeric"' })}
      ${field({ name: "note", label: "Note (optional)", placeholder: "e.g. cash at the meeting", required: false, attrs: 'maxlength="120"' })}
      ${formMsgSlot()}
      <div class="foot"><button class="btn ghost" type="button" data-cancel>Cancel</button><button class="btn primary" type="submit">Record payment</button></div>
    </form>`,
  });
  const form = $("form", m.el);
  $("[data-cancel]", m.el).addEventListener("click", () => m.close());
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    clearFieldErrors(form);
    const v = formData(form);
    const amount = parseRWF(v.amount);
    if (!amount || amount < config.limits.minContribution || amount > config.limits.maxContribution) return setFieldError(form, "amount", "Enter between 100 and 5,000,000 RWF.");
    const btn = $('button[type="submit"]', form);
    setBusy(btn, true, "Saving…");
    try {
      await rpc("record_manual_contribution", { p_event_id: event.id, p_user_id: v.user, p_amount: amount, p_note: String(v.note ?? "").trim() || null });
      toast("Payment recorded.", "success");
      m.close();
      onDone();
    } catch (err) { formMessage(form, "error", err.message); setBusy(btn, false); }
  });
}

export function openAddMemberDialog(group, onDone) {
  const m = openModal({
    title: `Add a member to ${group.name}`,
    content: html`<form class="form" novalidate>
      <p class="muted">Type the email they used to sign up for SquadVault. If they don't have an account yet, send them an invitation code instead (see Invitations below).</p>
      ${field({ name: "email", label: "Their email", type: "email", autocomplete: "off", placeholder: "name@example.com", attrs: 'maxlength="254" autofocus' })}
      ${formMsgSlot()}
      <div class="foot"><button class="btn ghost" type="button" data-cancel>Cancel</button><button class="btn primary" type="submit">Add member</button></div>
    </form>`,
  });
  const form = $("form", m.el);
  $("[data-cancel]", m.el).addEventListener("click", () => m.close());
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    clearFieldErrors(form);
    const email = String(formData(form).email ?? "").trim();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return setFieldError(form, "email", "Enter a valid email address.");
    const btn = $('button[type="submit"]', form);
    setBusy(btn, true, "Adding…");
    try {
      await rpc("add_member_by_email", { p_group_id: group.id, p_email: email });
      toast("Member added.", "success");
      m.close();
      onDone();
    } catch (err) { formMessage(form, "error", err.message); setBusy(btn, false); }
  });
}
