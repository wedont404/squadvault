// UI kit: icons, toasts, dialogs, skeletons, empty/error states, badges, avatars, progress bars,
// form helpers. All markup is built with html`` so user-supplied text is always escaped.
import { html, raw, str, esc, formatRWF, percent, initials } from "./utils.js";
import { avatarUrl, friendlyError } from "./supabase.js";

// ---------------------------------------------------------------------------
// Icons: inline SVG (no CDN, so nothing can fail to load)
// ---------------------------------------------------------------------------
const ICONS = {
  home: '<path d="M3 10.5 12 3l9 7.5V21a1 1 0 0 1-1 1h-5v-7H9v7H4a1 1 0 0 1-1-1z"/>',
  users: '<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c0-3.6 2.9-6 6.5-6s6.5 2.4 6.5 6"/><path d="M16 4.6a3.5 3.5 0 0 1 0 6.8M18 14.3c2.2.7 3.5 2.6 3.5 5.7"/>',
  calendar: '<rect x="3" y="5" width="18" height="16" rx="2.5"/><path d="M3 10h18M8 3v4M16 3v4"/>',
  wallet: '<path d="M3 7a2 2 0 0 1 2-2h13v4"/><path d="M3 7v11a2 2 0 0 0 2 2h14a1 1 0 0 0 1-1v-9a1 1 0 0 0-1-1H5a2 2 0 0 1-2-2z"/><circle cx="16.5" cy="14.5" r="1.2"/>',
  receipt: '<path d="M5 3h14v18l-3-2-2 2-2-2-2 2-2-2-3 2z"/><path d="M9 8h6M9 12h6"/>',
  ticket: '<path d="M3 9a2 2 0 0 0 0 6v3a1 1 0 0 0 1 1h16a1 1 0 0 0 1-1v-3a2 2 0 0 1 0-6V6a1 1 0 0 0-1-1H4a1 1 0 0 0-1 1z"/><path d="M13 5v14" stroke-dasharray="2 3"/>',
  user: '<circle cx="12" cy="8" r="4"/><path d="M4 21c0-4 3.6-7 8-7s8 3 8 7"/>',
  settings: '<path d="M4 7h10M18 7h2M4 17h2M10 17h10"/><circle cx="16" cy="7" r="2"/><circle cx="8" cy="17" r="2"/>',
  plus: '<path d="M12 5v14M5 12h14"/>',
  check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
  x: '<path d="M6 6l12 12M18 6 6 18"/>',
  copy: '<rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V6a2 2 0 0 1 2-2h9"/>',
  alert: '<path d="M12 3 2 20h20z"/><path d="M12 10v4M12 17.5v.01"/>',
  logout: '<path d="M9 4H5a1 1 0 0 0-1 1v14a1 1 0 0 0 1 1h4"/><path d="m16 8 4 4-4 4M20 12H9"/>',
  refresh: '<path d="M20 11a8 8 0 0 0-14.5-4M4 4v4h4"/><path d="M4 13a8 8 0 0 0 14.5 4M20 20v-4h-4"/>',
  trend: '<path d="m3 17 6-6 4 4 8-8"/><path d="M15 7h6v6"/>',
  shield: '<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/><path d="m9 12 2 2 4-4"/>',
  lock: '<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
  upload: '<path d="M12 16V4M7 9l5-5 5 5"/><path d="M4 16v3a1 1 0 0 0 1 1h14a1 1 0 0 0 1-1v-3"/>',
  trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  arrow: '<path d="M5 12h14M13 6l6 6-6 6"/>',
  more: '<circle cx="5" cy="12" r="1.4"/><circle cx="12" cy="12" r="1.4"/><circle cx="19" cy="12" r="1.4"/>',
  party: '<path d="m4 20 5-14 9 9z"/><path d="M14 4v2M19 9h2M17 3l1 1"/>',
  eye: '<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
  edit: '<path d="M4 20h4L19 9l-4-4L4 16z"/><path d="m13.5 6.5 4 4"/>',
  phone: '<rect x="7" y="2.5" width="10" height="19" rx="2.5"/><path d="M11 18.5h2"/>',
  link: '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 7.5v.01"/>',
};
export function icon(name) {
  return raw(
    `<svg class="ico" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" focusable="false">${ICONS[name] ?? ICONS.info}</svg>`,
  );
}

// ---------------------------------------------------------------------------
// DOM helpers
// ---------------------------------------------------------------------------
export const $ = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

/** Render trusted html`` output into an element and kick off progress-bar animation. */
export function mount(el, content) {
  el.innerHTML = str(content);
  animateBars(el);
  return el;
}

export function animateBars(root = document) {
  const bars = $$("[data-w]", root);
  if (!bars.length) return;
  requestAnimationFrame(() => requestAnimationFrame(() => bars.forEach((b) => { b.style.width = `${b.dataset.w}%`; })));
}

/** Replace a parent's children with one fresh container (drops old listeners with it). */
export function freshView(parent) {
  const d = document.createElement("div");
  parent.replaceChildren(d);
  return d;
}

/** Event delegation: on(root, "click", "[data-x]", (e, target) => ...) */
export function on(root, type, selector, handler) {
  root.addEventListener(type, (e) => {
    const t = e.target.closest?.(selector);
    if (t && root.contains(t)) handler(e, t);
  });
}

export function setBusy(btn, busy, label) {
  if (!btn) return;
  if (busy) {
    btn.dataset.label = btn.innerHTML;
    btn.setAttribute("aria-busy", "true");
    btn.disabled = true;
    btn.innerHTML = `<span class="spinner" aria-hidden="true"></span><span>${esc(label ?? "Working…")}</span>`;
  } else {
    btn.removeAttribute("aria-busy");
    btn.disabled = false;
    if (btn.dataset.label) btn.innerHTML = btn.dataset.label;
  }
}

// ---------------------------------------------------------------------------
// Toasts
// ---------------------------------------------------------------------------
export function toast(message, type = "info", ms = 5200) {
  const host = $("#toasts");
  if (!host) return;
  const el = document.createElement("div");
  el.className = `toast ${type}`;
  el.setAttribute("role", type === "error" ? "alert" : "status");
  el.innerHTML = `<span class="msg">${esc(message)}</span><button type="button" aria-label="Dismiss notification">×</button>`;
  const close = () => el.remove();
  el.querySelector("button").addEventListener("click", close);
  host.appendChild(el);
  while (host.children.length > 4) host.firstChild.remove();
  if (ms) setTimeout(close, ms);
}
export const toastError = (err) => toast(friendlyError(err), "error", 7000);

// ---------------------------------------------------------------------------
// Dialogs (modal, focus-trapped, Esc to close, restores focus)
// ---------------------------------------------------------------------------
const FOCUSABLE = 'a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),textarea:not([disabled]),[tabindex]:not([tabindex="-1"])';

export function openModal({ title, content, footer = null, onClose = null, labelledBy = "dlg-title" }) {
  const root = $("#dialog-root");
  const opener = document.activeElement;
  const backdrop = document.createElement("div");
  backdrop.className = "dialog-backdrop";
  backdrop.innerHTML = str(html`
    <div class="dialog" role="dialog" aria-modal="true" aria-labelledby="${labelledBy}">
      <h2 id="${labelledBy}">${title}</h2>
      <div class="dialog-body">${content}</div>
      ${footer ? html`<div class="foot">${footer}</div>` : ""}
    </div>`);
  root.appendChild(backdrop);
  const dialog = $(".dialog", backdrop);

  const close = (result) => {
    document.removeEventListener("keydown", onKey, true);
    backdrop.remove();
    opener?.focus?.();
    onClose?.(result);
  };
  const onKey = (e) => {
    if (e.key === "Escape") { e.stopPropagation(); close(null); return; }
    if (e.key !== "Tab") return;
    const items = $$(FOCUSABLE, dialog).filter((n) => n.offsetParent !== null);
    if (!items.length) return;
    const first = items[0], last = items[items.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  };
  document.addEventListener("keydown", onKey, true);
  backdrop.addEventListener("mousedown", (e) => { if (e.target === backdrop) close(null); });
  (dialog.querySelector("[autofocus]") ?? $$(FOCUSABLE, dialog)[0])?.focus();
  return { el: dialog, close };
}

export function confirmDialog({ title, message, confirmLabel = "Confirm", danger = false }) {
  return new Promise((resolve) => {
    const m = openModal({
      title,
      content: html`<p class="muted">${message}</p>`,
      footer: html`<button class="btn ghost" data-cancel type="button">Cancel</button>
        <button class="btn ${danger ? "danger" : "primary"}" data-ok type="button" autofocus>${confirmLabel}</button>`,
      onClose: () => resolve(false),
    });
    $("[data-cancel]", m.el).addEventListener("click", () => m.close(false));
    $("[data-ok]", m.el).addEventListener("click", () => { resolve(true); m.close(true); });
  });
}

// ---------------------------------------------------------------------------
// Skeletons, empty and error states
// ---------------------------------------------------------------------------
export const skeletonCards = (n = 3) =>
  html`<div class="grid auto" aria-busy="true" aria-label="Loading">${Array.from({ length: n }, () => html`<div class="skeleton sk-card"></div>`)}</div>`;
export const skeletonList = (n = 4) =>
  html`<div class="card" aria-busy="true" aria-label="Loading">${Array.from({ length: n }, () => html`<div class="skeleton sk-line"></div>`)}</div>`;
export const skeletonPage = () => html`
  <div class="stack" aria-busy="true" aria-label="Loading">
    <div class="skeleton" style="height:48px;width:55%"></div>
    <div class="grid cols-4">${Array.from({ length: 4 }, () => html`<div class="skeleton sk-card" style="height:104px"></div>`)}</div>
    ${skeletonCards(3)}
  </div>`;

export function emptyState({ iconName = "party", title, text, actions = "" }) {
  return html`<div class="empty">
    <div class="ico">${icon(iconName)}</div>
    <h3>${title}</h3>
    <p>${text}</p>
    ${actions ? html`<div class="actions" style="justify-content:center">${actions}</div>` : ""}
  </div>`;
}

export const errorState = (message) => html`<div class="error-state" role="alert">
  <div>${icon("alert")}</div><div>${message}</div>
  <button class="btn" type="button" data-retry>${icon("refresh")} Try again</button></div>`;

/** Skeleton -> load -> render, with an error state and retry button. */
export async function loadInto(el, { load, render, skeleton = skeletonCards(3), isCurrent = () => true }) {
  mount(el, skeleton);
  try {
    const data = await load();
    if (!isCurrent()) return;
    await render(data);
  } catch (err) {
    if (!isCurrent()) return;
    console.error(err);
    mount(el, errorState(friendlyError(err)));
    $("[data-retry]", el)?.addEventListener("click", () => loadInto(el, { load, render, skeleton, isCurrent }));
  }
}

// ---------------------------------------------------------------------------
// Small components
// ---------------------------------------------------------------------------
const STATUS_LABEL = { paid: "Verified", pending: "Pending", failed: "Failed", refunded: "Refunded", active: "Active", completed: "Completed", cancelled: "Cancelled", admin: "Admin", treasurer: "Treasurer", member: "Member", revoked: "Revoked", expired: "Expired", exhausted: "Used up", partial: "Part paid", unpaid: "Not paid", left: "Left group" };
export const badge = (status, label) => html`<span class="badge ${status}">${label ?? STATUS_LABEL[status] ?? status}</span>`;
export const simBadge = () => html`<span class="badge simulated" title="Simulated payment. No real money moved.">Simulated</span>`;

export function avatar(name, path = null, large = false) {
  const url = avatarUrl(path);
  return html`<span class="avatar ${large ? "lg" : ""}" aria-hidden="true">${url ? html`<img src="${url}" alt="" loading="lazy" referrerpolicy="no-referrer">` : initials(name)}</span>`;
}

export function progressBar(pct, { thin = false, label = "Savings progress" } = {}) {
  const p = Math.max(0, Math.min(100, Number(pct) || 0));
  return html`<div class="progress ${thin ? "thin" : ""}" role="progressbar" aria-label="${label}" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${p}"><span data-w="${p}"></span></div>`;
}

export function statCard({ label, value, hint = "", tone = "", iconName = null }) {
  return html`<div class="card stat ${tone}">
    <div class="label">${iconName ? icon(iconName) : ""}${label}</div>
    <div class="value">${value}</div>
    ${hint ? html`<div class="hint">${hint}</div>` : ""}</div>`;
}

export function eventProgressCard(ev, fin, href) {
  const p = percent(fin.paid_total, ev.target_amount);
  return html`<a class="card link" href="${href}">
    <div class="row between"><h3>${ev.name}</h3>${badge(ev.status)}</div>
    <div style="margin:14px 0 6px" class="mono"><strong style="font-size:1.35rem;font-family:var(--font-display)">${formatRWF(fin.paid_total)}</strong>
      <span class="muted"> of ${formatRWF(ev.target_amount)}</span></div>
    ${progressBar(p, { label: `${ev.name} progress` })}
    <div class="progress-meta"><span>${p}% verified</span><span>${formatRWF(fin.remaining_amount ?? Math.max(ev.target_amount - fin.paid_total, 0))} to go</span></div>
    ${fin.pending_total > 0 ? html`<div class="faint" style="font-size:var(--fs-xs);margin-top:6px">${formatRWF(fin.pending_total)} pending, not counted yet</div>` : ""}
  </a>`;
}

// ---------------------------------------------------------------------------
// Forms
// ---------------------------------------------------------------------------
export function field({ name, label, type = "text", value = "", placeholder = "", help = "", autocomplete = "off", required = true, attrs = "", prefix = "" }) {
  const input = html`<input class="input" id="f-${name}" name="${name}" type="${type}" value="${value}" placeholder="${placeholder}" autocomplete="${autocomplete}" ${required ? raw("required") : ""} aria-describedby="err-${name}" ${raw(attrs)}>`;
  return html`<div class="field" data-field="${name}">
    <label for="f-${name}">${label}</label>
    ${prefix ? html`<div class="input-affix"><span class="affix">${prefix}</span>${input}</div>` : input}
    ${help ? html`<div class="help">${help}</div>` : ""}
    <div class="error" id="err-${name}" role="alert"></div></div>`;
}

export function setFieldError(form, name, message) {
  const wrap = form.querySelector(`[data-field="${name}"]`);
  if (!wrap) return;
  const input = wrap.querySelector("input,select,textarea");
  wrap.querySelector(".error").textContent = message ?? "";
  if (input) { if (message) input.setAttribute("aria-invalid", "true"); else input.removeAttribute("aria-invalid"); }
}
export function clearFieldErrors(form) {
  $$("[data-field]", form).forEach((w) => setFieldError(form, w.dataset.field, ""));
  formMessage(form, null);
}
export function formMessage(form, type, text) {
  let box = form.querySelector("[data-msg]");
  if (!box) return;
  if (!type) { box.innerHTML = ""; return; }
  box.innerHTML = `<div class="form-msg ${type}" role="${type === "error" ? "alert" : "status"}">${esc(text)}</div>`;
}
export const formMsgSlot = () => html`<div data-msg></div>`;
export const formData = (form) => Object.fromEntries(new FormData(form).entries());

/** Footer shown on every screen: Terms link and the credit line. */
export const siteFooter = () => html`<footer class="site-foot">
  <button class="link-btn" type="button" data-terms>Terms &amp; Conditions</button>
  <p>This website was happily made by Tresor</p>
</footer>`;
