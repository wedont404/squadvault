// Owner page: approve or reject plan upgrade requests after checking the MoMo payment on your own phone.
// Only users listed in platform_admins can load anything here (enforced in the database).
import { rpc } from "./supabase.js";
import { html, formatRWF, timeAgo } from "./utils.js";
import { mount, on, icon, badge, toast, toastError, openModal, confirmDialog, loadInto, emptyState, skeletonList, field, formData, setBusy } from "./ui.js";

export async function renderOwner({ outlet, isCurrent }) {
  await loadInto(outlet, {
    isCurrent,
    skeleton: skeletonList(3),
    load: () => rpc("owner_list_plan_requests"),
    render: (rows) => {
      const pending = rows.filter((r) => r.status === "pending");
      const done = rows.filter((r) => r.status !== "pending");
      const row = (r, actions) => html`<div class="list-item" style="flex-wrap:wrap">
        <div class="grow"><div class="title">${r.group_name} · ${r.plan === "pro" ? "Pro" : "Plus"} ${r.period === "year" ? "yearly" : "monthly"} · ${formatRWF(r.amount)}</div>
          <div class="sub">By ${r.requester_name ?? "?"} (${r.requester_email ?? "no email"}) · ID <strong>${r.txn_ref}</strong> · ${timeAgo(r.created_at)}${r.note ? ` · ${r.note}` : ""}</div></div>
        ${actions ?? badge(r.status === "approved" ? "paid" : "failed", r.status === "approved" ? "Approved" : "Rejected")}</div>`;
      mount(outlet, html`<div class="page-head"><div><h1>Owner</h1><p class="sub">Plan upgrade requests</p></div></div>
        <div class="section"><div class="section-head"><h2>Waiting (${pending.length})</h2></div>
          <p class="muted" style="font-size:var(--fs-sm);margin-bottom:8px">Open your MoMo messages. Approve only if you received the exact amount with that transaction ID.</p>
          ${pending.length ? html`<div class="card flush"><div class="list">${pending.map((r) => row(r, html`<div class="acts"><button class="btn sm primary" type="button" data-ok="${r.id}">${icon("check")} Approve</button><button class="btn sm danger" type="button" data-no="${r.id}">${icon("x")} Reject</button></div>`))}</div></div>`
            : emptyState({ iconName: "check", title: "Nothing waiting", text: "New upgrade requests appear here." })}</div>
        ${done.length ? html`<div class="section"><div class="section-head"><h2>History</h2></div><div class="card flush"><div class="list">${done.map((r) => row(r))}</div></div></div>` : ""}`);
      on(outlet, "click", "[data-ok]", async (_, b) => {
        if (!(await confirmDialog({ title: "Approve and switch the plan on?", message: "Only do this once the money is in your MoMo.", confirmLabel: "Approve" }))) return;
        try { await rpc("owner_decide_plan_request", { p_request_id: b.dataset.ok, p_approve: true }); toast("Plan switched on.", "success"); renderOwner({ outlet, isCurrent }); } catch (err) { toastError(err); }
      });
      on(outlet, "click", "[data-no]", (_, b) => {
        const m = openModal({ title: "Reject this request", content: html`<form class="form">${field({ name: "note", label: "Reason (shown to the group admin)", required: false, value: "Payment not found", attrs: 'maxlength="200"' })}
          <div class="foot"><button class="btn ghost" type="button" data-c>Cancel</button><button class="btn danger" type="submit">Reject</button></div></form>` });
        m.el.querySelector("[data-c]").addEventListener("click", () => m.close());
        m.el.querySelector("form").addEventListener("submit", async (e) => {
          e.preventDefault();
          const btn = e.target.querySelector('button[type="submit"]');
          setBusy(btn, true, "Saving…");
          try { await rpc("owner_decide_plan_request", { p_request_id: b.dataset.no, p_approve: false, p_note: formData(e.target).note }); m.close(); renderOwner({ outlet, isCurrent }); }
          catch (err) { toastError(err); setBusy(btn, false); }
        });
      });
    },
  });
}
