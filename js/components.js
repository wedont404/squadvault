// Reusable row/list components shared by several views.
import { html, formatRWF, timeAgo } from "./utils.js";
import { avatar, badge, simBadge, icon, toastError, toast } from "./ui.js";
import { supabase } from "./supabase.js";

export const methodLabel = (m) => ({ mtn_momo: "MTN MoMo", airtel_money: "Airtel Money" }[m] ?? "Mobile money");
const viaLabel = (c) => (c.provider === "manual" && c.note ? `${methodLabel(c.payment_method)} · ${c.note}` : methodLabel(c.payment_method));

/** One contribution. Only status "paid" is styled as money in; pending/failed are visibly not counted. */
export function contributionRow(c, { showEvent = true } = {}) {
  const paid = c.status === "paid";
  return html`<div class="list-item">
    ${avatar(c.name, c.avatar_path)}
    <div class="grow"><div class="title">${c.name}</div>
      <div class="sub">${showEvent ? `${c.event_name} · ` : ""}${viaLabel(c)} · ${timeAgo(c.created_at)}${c.status === "failed" && c.failure_reason ? ` · ${c.failure_reason}` : ""}</div></div>
    ${c.is_simulated ? simBadge() : ""}${badge(c.status)}
    <div class="amount ${paid ? "pos" : ""}" ${paid ? "" : html`style="opacity:.7"`}>${formatRWF(c.amount)}</div>
  </div>`;
}

export function expenseRow(x, { canEdit = false, showEvent = true } = {}) {
  return html`<div class="list-item">
    <span class="avatar" aria-hidden="true" style="background:var(--surface-3);color:var(--violet)">${icon("receipt")}</span>
    <div class="grow"><div class="title">${x.description}</div>
      <div class="sub">${showEvent ? `${x.event_name} · ` : ""}by ${x.recorder} · ${timeAgo(x.created_at)}</div></div>
    ${x.receipt_path ? html`<button class="btn sm ghost" type="button" data-receipt="${x.receipt_path}">${icon("eye")} Receipt</button>` : html`<span class="faint" style="font-size:var(--fs-xs)">No receipt</span>`}
    ${canEdit ? html`<button class="btn sm ghost" type="button" data-edit-expense="${x.id}" aria-label="Edit expense ${x.description}">${icon("edit")}</button>` : ""}
    <div class="amount neg">−${formatRWF(x.amount)}</div>
  </div>`;
}

export function activityRows(items) {
  return items.map((a) =>
    a.kind === "contribution"
      ? html`<div class="list-item">${avatar(a.name, a.avatar_path)}
          <div class="grow"><div class="title">${a.name} ${a.status === "paid" ? "contributed" : a.status === "pending" ? "started a contribution" : `contribution ${a.status}`}</div>
          <div class="sub">${a.event_name} · ${timeAgo(a.at)}</div></div>
          ${a.is_simulated ? simBadge() : ""}
          <div class="amount ${a.status === "paid" ? "pos" : ""}" ${a.status === "paid" ? "" : html`style="opacity:.7"`}>${formatRWF(a.amount)}</div></div>`
      : html`<div class="list-item"><span class="avatar" aria-hidden="true" style="background:var(--surface-3);color:var(--violet)">${icon("receipt")}</span>
          <div class="grow"><div class="title">${a.recorder} recorded an expense</div>
          <div class="sub">${a.description} · ${a.event_name} · ${timeAgo(a.at)}</div></div>
          <div class="amount neg">−${formatRWF(a.amount)}</div></div>`,
  );
}

/** Open a receipt via a short-lived (60 s) signed URL. The bucket is private. */
export async function openReceipt(path) {
  const { data, error } = await supabase.storage.from("receipts").createSignedUrl(path, 60);
  if (error || !data?.signedUrl) {
    console.error(error);
    return toastError(error ?? new Error("receipt"));
  }
  const w = window.open(data.signedUrl, "_blank", "noopener");
  if (!w) toast("Your browser blocked the receipt tab. Allow pop-ups and try again.", "info");
}
