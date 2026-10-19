// Invitations: generate / copy / revoke codes (admins & treasurers) and join with a code (anyone).
// The plaintext code is shown exactly once, when created. Only a SHA-256 hash is stored server-side.
import { activeGroup, isManagerRole } from "./state.js";
import { rpc, friendlyError } from "./supabase.js";
import { reloadGroups } from "./session.js";
import { navigate } from "./router.js";
import { html, formatDate, relativeExpiry, normalizeInviteCode, isInviteCode, copyText } from "./utils.js";
import {
  $, mount, on, icon, badge, toast, toastError, openModal, confirmDialog, loadInto, setBusy, field, formData, formMessage, formMsgSlot,
  setFieldError, clearFieldErrors, emptyState, skeletonList,
} from "./ui.js";

// ---------------------------------------------------------------------------
// Join with a code
// ---------------------------------------------------------------------------
async function redeem(code) {
  const res = await rpc("join_group_with_code", { p_code: code });
  if (!res?.ok) {
    const msg = res?.error === "rate_limited" ? "Too many attempts. Please wait a few minutes and try again." : "That invitation code isn't valid. It may be wrong, expired, revoked or used up.";
    throw new Error(msg);
  }
  await reloadGroups(res.group_id);
  toast(res.already_member ? "You're already in that group." : "You're in! Welcome to the squad.", "success");
  navigate(`/groups/${res.group_id}`);
}

function bindJoinForm(form, onDone) {
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    clearFieldErrors(form);
    const code = normalizeInviteCode(formData(form).code);
    if (!isInviteCode(code)) return setFieldError(form, "code", "Codes look like SV-1A2B3C4D5E6F.");
    const btn = $('button[type="submit"]', form);
    setBusy(btn, true, "Joining…");
    try { await redeem(code); onDone?.(); }
    catch (err) { formMessage(form, "error", err.message || friendlyError(err)); setBusy(btn, false); }
  });
}

const joinFormHtml = (extra = "") => html`<form class="form" novalidate>
  ${field({ name: "code", label: "Invitation code", placeholder: "SV-XXXXXXXXXXXX", autocomplete: "off", attrs: 'autocapitalize="characters" spellcheck="false" maxlength="20" autofocus' })}
  ${formMsgSlot()}${extra}<button class="btn primary" type="submit">${icon("link")} Join group</button></form>`;

export function openJoinDialog() {
  const m = openModal({ title: "Join a group", content: joinFormHtml(html`<p class="muted" style="font-size:var(--fs-sm)">Ask a group admin or treasurer for a code.</p>`) });
  bindJoinForm($("form", m.el), () => m.close());
}

// ---------------------------------------------------------------------------
// Manager panel (also embedded in the group detail page)
// ---------------------------------------------------------------------------
export async function mountInvitationPanel(host, groupId) {
  const draw = () => loadInto(host, {
    skeleton: skeletonList(2),
    load: () => rpc("list_invitations", { p_group_id: groupId }),
    render: (rows) => {
      mount(host, html`<div class="card stack">
        <form class="row wrap" data-gen novalidate style="align-items:flex-end">
          <div class="field" style="width:130px"><label for="inv-uses">Max uses</label><input class="input" id="inv-uses" name="uses" type="number" min="1" max="100" value="10" inputmode="numeric"></div>
          <div class="field" style="width:130px"><label for="inv-days">Valid for (days)</label><input class="input" id="inv-days" name="days" type="number" min="1" max="30" value="7" inputmode="numeric"></div>
          <button class="btn primary" type="submit">${icon("plus")} Generate code</button></form>
        <div data-msg></div>
        ${rows.length
          ? html`<div class="list" style="margin:0 -24px -24px">${rows.map((r) => html`<div class="list-item">
              <span class="avatar" aria-hidden="true" style="background:var(--surface-3);color:var(--green)">${icon("ticket")}</span>
              <div class="grow"><div class="title">${r.use_count} of ${r.max_uses} used</div>
                <div class="sub">${r.status === "active" ? relativeExpiry(r.expires_at) : `Created ${formatDate(r.created_at)}`} · codes are hidden after creation</div></div>
              ${badge(r.status)}
              ${r.status === "active" ? html`<button class="btn sm danger" type="button" data-revoke="${r.id}">Revoke</button>` : ""}</div>`)}</div>`
          : html`<p class="muted">No invitations yet. Generate one and share it privately.</p>`}
      </div>`);

      const form = $("form[data-gen]", host);
      form.addEventListener("submit", async (e) => {
        e.preventDefault();
        const v = formData(form);
        const uses = Number(v.uses), days = Number(v.days);
        if (!Number.isInteger(uses) || uses < 1 || uses > 100) return formMessage(host, "error", "Max uses must be 1 to 100.");
        if (!Number.isInteger(days) || days < 1 || days > 30) return formMessage(host, "error", "Validity must be 1 to 30 days.");
        const btn = $('button[type="submit"]', form);
        setBusy(btn, true, "Generating…");
        try {
          const inv = await rpc("create_invitation_code", { p_group_id: groupId, p_max_uses: uses, p_valid_days: days });
          showCode(inv);
          draw();
        } catch (err) { formMessage(host, "error", friendlyError(err)); setBusy(btn, false); }
      });
      on(host, "click", "[data-revoke]", async (_, b) => {
        if (!(await confirmDialog({ title: "Revoke this invitation?", message: "Nobody will be able to join with it anymore. People who already joined stay in the group.", confirmLabel: "Revoke", danger: true }))) return;
        try { await rpc("revoke_invitation_code", { p_invitation_id: b.dataset.revoke }); toast("Invitation revoked.", "success"); draw(); }
        catch (err) { toastError(err); }
      });
    },
  });
  await draw();
}

function showCode(inv) {
  const m = openModal({
    title: "Invitation ready",
    content: html`<div class="stack">
      <p class="muted">Copy it now. For your security the code is <strong>never shown again</strong>.</p>
      <div class="code-box"><span data-code>${inv.code}</span><button class="btn sm" type="button" data-copy>${icon("copy")} Copy</button></div>
      <p class="muted" style="font-size:var(--fs-sm)">Up to ${inv.max_uses} people can use it · ${relativeExpiry(inv.expires_at)}.</p></div>`,
    footer: html`<button class="btn primary" type="button" data-done>Done</button>`,
  });
  $("[data-copy]", m.el).addEventListener("click", async (e) => {
    const ok = await copyText(inv.code);
    toast(ok ? "Code copied." : "Couldn't copy automatically. Select and copy it.", ok ? "success" : "info");
    if (ok) e.currentTarget.innerHTML = "Copied";
  });
  $("[data-done]", m.el).addEventListener("click", () => m.close());
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------
export async function renderInvitations({ outlet }) {
  const group = activeGroup();
  const manager = isManagerRole(group?.role);
  mount(outlet, html`<div class="page-head"><div><h1>Invitations</h1><p class="sub">Invite people with a private, expiring code.</p></div></div>
    <div class="grid cols-2" style="align-items:start">
      <div><div class="section-head"><h2>Join a group</h2></div><div class="card">${joinFormHtml()}</div></div>
      <div><div class="section-head"><h2>${group ? `Invite to ${group.name}` : "Invite people"}</h2></div>
        ${!group ? emptyState({ iconName: "users", title: "No group selected", text: "Create or join a group to invite people.", actions: html`<a class="btn" href="#/groups">My groups</a>` })
          : manager ? html`<div data-panel></div>`
          : emptyState({ iconName: "lock", title: "Admins and treasurers only", text: "Ask an admin or treasurer of this group to invite new members." })}</div>
    </div>`);
  bindJoinForm($("form", outlet));
  if (group && manager) mountInvitationPanel($("[data-panel]", outlet), group.id);
}
