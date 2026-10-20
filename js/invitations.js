// Invitations: generate / copy / revoke codes (admins & treasurers) and join with a code (anyone).
// Leaders (admins & treasurers) can read their group's active code again. Joining checks a SHA-256 hash.
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
      const active = rows.filter((r) => r.status === "active");
      const current = active.find((r) => r.code) ?? null;      // newest active code we can still read
      const oldActive = active.filter((r) => !r.code);         // made before codes became viewable
      const others = rows.filter((r) => r.status !== "active" || (!r.code && r.status === "active"));
      mount(host, html`<div class="card stack">
        ${current
          ? html`<div class="stack" style="gap:10px"><div><h3 style="margin:0">Your invitation code</h3>
              <p class="muted" style="font-size:var(--fs-sm);margin-top:4px">Share this one. It stays here until it expires or is used up, so there's no need to make a new code each time.</p></div>
              <div class="code-box"><span data-code>${current.code}</span><button class="btn sm" type="button" data-copy-code="${current.code}">${icon("copy")} Copy</button></div>
              <div class="row wrap" style="gap:8px"><a class="btn sm" data-wa href="${waLink(current.code)}" target="_blank" rel="noopener">${icon("link")} Share on WhatsApp</a>
                <span class="muted" style="font-size:var(--fs-sm)">${current.use_count} of ${current.max_uses} used · ${relativeExpiry(current.expires_at)}</span>
                <button class="btn sm danger" type="button" data-revoke="${current.id}" style="margin-left:auto">Revoke</button></div></div>`
          : html`<div><h3 style="margin:0">No active code yet</h3><p class="muted" style="font-size:var(--fs-sm);margin-top:4px">Make one and it will stay visible here so you can copy it any time.</p></div>`}
        <details ${current ? "" : "open"} class="more"><summary class="link-btn" style="cursor:pointer">${current ? "Need a different code? Make another" : "Make a code"}</summary>
          <form class="row wrap" data-gen novalidate style="align-items:flex-end;margin-top:12px">
            <div class="field" style="width:130px"><label for="inv-uses">Max uses</label><input class="input" id="inv-uses" name="uses" type="number" min="1" max="100" value="10" inputmode="numeric"></div>
            <div class="field" style="width:130px"><label for="inv-days">Valid for (days)</label><input class="input" id="inv-days" name="days" type="number" min="1" max="30" value="7" inputmode="numeric"></div>
            <button class="btn primary" type="submit">${icon("plus")} Generate code</button></form></details>
        <div data-msg></div>
        ${oldActive.length ? html`<p class="faint" style="font-size:var(--fs-xs)">${oldActive.length} older active code${oldActive.length === 1 ? " was" : "s were"} made before codes could be viewed. They still work, but can't be shown again. Revoke them below if you don't know who has them.</p>` : ""}
        ${others.length
          ? html`<div class="list" style="margin:0 -24px -24px">${others.map((r) => html`<div class="list-item">
              <span class="avatar" aria-hidden="true" style="background:var(--surface-3);color:var(--green)">${icon("ticket")}</span>
              <div class="grow"><div class="title">${r.use_count} of ${r.max_uses} used</div>
                <div class="sub">${r.status === "active" ? relativeExpiry(r.expires_at) : `Created ${formatDate(r.created_at)}`}${r.status === "active" ? " · can't be shown again" : ""}</div></div>
              ${badge(r.status)}
              ${r.status === "active" ? html`<button class="btn sm danger" type="button" data-revoke="${r.id}">Revoke</button>` : ""}</div>`)}</div>`
          : ""}
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
          await rpc("create_invitation_code", { p_group_id: groupId, p_max_uses: uses, p_valid_days: days });
          toast("New code ready. It's shown above.", "success");
          draw();
        } catch (err) { formMessage(host, "error", friendlyError(err)); setBusy(btn, false); }
      });
      on(host, "click", "[data-copy-code]", async (_, b) => {
        const ok = await copyText(b.dataset.copyCode);
        toast(ok ? "Code copied." : "Couldn't copy automatically. Select and copy it.", ok ? "success" : "info");
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

const waLink = (code) => `https://wa.me/?text=${encodeURIComponent(`Join our savings group on SquadVault. Open ${location.origin}${location.pathname} , sign up, then choose “Join with a code” and enter: ${code}`)}`;

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
