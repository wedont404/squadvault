// Automatic payment checking (leader only): the leader's phone forwards "money received" MoMo SMS to
// SquadVault, which matches transaction ID + amount against members' "I've paid" claims.
// The secret token is shown ONCE when created; only its hash is stored.
import { rpc } from "./supabase.js";
import { config } from "./config.js";
import { html, timeAgo, formatRWF, copyText } from "./utils.js";
import { $, mount, on, icon, toast, toastError, confirmDialog, setBusy } from "./ui.js";

const ingestUrl = () => `${config.supabaseUrl}/rest/v1/rpc/ingest_momo_sms`;
const bodyTemplate = (token) => `{"p_token":"${token}","p_message":"{{SMS_TEXT}}"}`;

function copyRow(label, value, { secret = false } = {}) {
  return html`<div style="display:grid;gap:4px"><span class="muted" style="font-size:var(--fs-xs)">${label}</span>
    <div class="code-box sm" style="font-size:var(--fs-sm);letter-spacing:0"><span style="min-width:0">${value}</span>
      <button class="btn sm" type="button" data-copy-value="${value}" ${secret ? 'data-secret="1"' : ""}>${icon("copy")} Copy</button></div></div>`;
}

export async function mountAutoCheckPanel(el, group, { allowed = true, onUpgrade } = {}) {
  mount(el, html`<div class="skeleton sk-card" style="height:90px"></div>`);
  let status;
  try { status = await rpc("collector_status", { p_group_id: group.id }); }
  catch (err) { mount(el, html`<p class="muted">Couldn't load automatic checking.</p>`); toastError(err); return; }

  const draw = (token = null) => {
    if (!allowed && !status.active) {
      mount(el, html`<div class="card"><div class="row between wrap" style="gap:12px"><div><h3 style="margin:0">Automatic payment checking</h3>
        <p class="muted" style="font-size:var(--fs-sm);margin-top:4px">Members' payments are confirmed straight from your MoMo messages, with no hand-checking. Included in the Plus and Pro plans.</p></div>
        <span class="badge">Plus</span></div>
        ${onUpgrade ? html`<div class="actions" style="margin-top:12px"><button class="btn primary" type="button" data-go-upgrade>${icon("trend")} See plans</button></div>` : ""}</div>`);
      return;
    }
    mount(el, html`<div class="card">
      <div class="row between wrap" style="gap:12px"><div><h3 style="margin:0">Automatic payment checking</h3>
        <p class="muted" style="font-size:var(--fs-sm);margin-top:4px">Optional. Members' “I've paid” claims are confirmed by your own MoMo messages, so nobody can claim money you never received.</p></div>
        ${status.active ? html`<span class="badge active">On</span>` : html`<span class="badge">Off</span>`}</div>

      ${status.active ? html`<p class="muted" style="margin-top:12px">${status.last_seen_at ? html`Last MoMo message received ${timeAgo(status.last_seen_at)}. ${status.receipts_30d} payment message${status.receipts_30d === 1 ? "" : "s"} in the last 30 days.` : "No message received yet. Finish the phone setup below, then send yourself a small test payment."}</p>` : ""}

      ${token ? html`<div class="stack" style="margin-top:14px">
        <div class="form-msg warn"><strong>Copy these now.</strong> The secret is shown only once. If you lose it, turn checking off and on again.</div>
        ${copyRow("1. Address to send to (POST)", ingestUrl())}
        ${copyRow("2. Header  apikey", config.supabasePublishableKey)}
        ${copyRow("3. Header  Content-Type", "application/json")}
        ${copyRow("4. Body (JSON)", bodyTemplate(token), { secret: true })}
        <p class="muted" style="font-size:var(--fs-sm)">In the body, replace <code class="code-inline">{{SMS_TEXT}}</code> with whatever your forwarder app calls “message text”.</p></div>` : ""}

      ${status.active ? html`<div class="row between wrap" style="margin-top:14px;gap:10px;padding:12px 14px;border:1px solid var(--border-soft);border-radius:var(--r-sm)">
        <div style="min-width:220px;flex:1"><strong>Also check the sender's name</strong>
          <div class="muted" style="font-size:var(--fs-sm);margin-top:2px">When a member gives no transaction ID, their claim is confirmed if the MoMo message has the <em>same amount</em>, a <em>matching sender name</em>, arrived around the same time, and only one claim fits it. Every new message re-checks waiting claims. Unclear cases stay with you.</div></div>
        <button class="btn sm ${status.auto_by_name ? "" : "primary"}" type="button" data-toggle-name>${status.auto_by_name ? "Turn off" : "Turn on"}</button></div>` : ""}

      ${status.active || token ? html`<ol class="steps" style="margin-top:14px">
        <li>Use the phone that receives your MoMo “you have received” messages. This needs <strong style="color:var(--text)">Android</strong>. iPhones can't forward SMS automatically.</li>
        <li>Install an SMS-forwarder app that can send an HTTP request with custom headers and a JSON body, then create a rule that forwards <strong style="color:var(--text)">only messages from your mobile money provider</strong> using the four values above.</li>
        <li>Keep the app allowed to run in the background, then send yourself a small payment. “Last message received” above should update.</li>
        <li>Paste a real message below to check we read it correctly. Only the amount, the transaction ID and the sender's name are kept. The message itself is never saved. The sender's name is what lets payments without an ID be matched.</li></ol>

        <div class="stack" style="margin-top:12px"><label class="label" for="sms-test" style="font-size:var(--fs-sm);color:var(--muted)">Test a sample MoMo message (nothing is saved)</label>
          <textarea class="input" id="sms-test" rows="3" maxlength="1000" placeholder="Paste a “You have received …” message here"></textarea>
          <div class="row" style="gap:8px"><button class="btn sm" type="button" data-test>${icon("check")} Check this message</button></div>
          <div data-test-result></div></div>` : ""}

      <div class="actions" style="margin-top:14px">
        ${status.active
          ? html`<button class="btn sm" type="button" data-new-token>${icon("refresh")} New secret</button><button class="btn sm danger" type="button" data-off>${icon("x")} Turn off</button>`
          : html`<button class="btn primary" type="button" data-on>${icon("shield")} Turn on automatic checking</button>`}
      </div>
    </div>`);
  };
  draw();
  on(el, "click", "[data-go-upgrade]", () => onUpgrade?.());

  on(el, "click", "[data-toggle-name]", async (_, b) => {
    setBusy(b, true, "Saving…");
    try {
      await rpc("set_auto_by_name", { p_group_id: group.id, p_on: !status.auto_by_name });
      status = await rpc("collector_status", { p_group_id: group.id });
      draw();
      toast(status.auto_by_name ? "Name matching is on." : "Name matching is off. Only transaction IDs confirm automatically.", "success");
    } catch (err) { toastError(err); setBusy(b, false); }
  });
  on(el, "click", "[data-copy-value]", async (_, b) => { if (await copyText(b.dataset.copyValue)) toast("Copied.", "success"); });
  const make = async (b) => {
    setBusy(b, true, "Creating…");
    try {
      const token = await rpc("create_collector_token", { p_group_id: group.id });
      status = await rpc("collector_status", { p_group_id: group.id });
      draw(token);
    } catch (err) { toastError(err); setBusy(b, false); }
  };
  on(el, "click", "[data-on]", (_, b) => make(b));
  on(el, "click", "[data-new-token]", async (_, b) => {
    if (await confirmDialog({ title: "Create a new secret?", message: "The old secret stops working straight away. You'll need to update the forwarder app.", confirmLabel: "Create new secret" })) make(b);
  });
  on(el, "click", "[data-off]", async () => {
    if (!(await confirmDialog({ title: "Turn off automatic checking?", message: "Your phone's messages will no longer be accepted. Existing records are kept.", confirmLabel: "Turn off", danger: true }))) return;
    try { await rpc("revoke_collector_token", { p_group_id: group.id }); status = await rpc("collector_status", { p_group_id: group.id }); draw(); toast("Automatic checking is off.", "success"); }
    catch (err) { toastError(err); }
  });
  on(el, "click", "[data-test]", async (_, b) => {
    const text = $("#sms-test", el)?.value ?? "";
    const out = $("[data-test-result]", el);
    if (text.trim().length < 10) { mount(out, html`<p class="muted">Paste the whole message first.</p>`); return; }
    setBusy(b, true, "Checking…");
    try {
      const r = await rpc("preview_momo_sms", { p_message: text });
      mount(out, r.is_receipt
        ? html`<div class="form-msg ok">${icon("check")} Recognised as received money: <strong>${formatRWF(r.amount)}</strong>${r.txn_id ? html`, transaction ID <strong>${r.txn_id}</strong>` : html`, <strong>no transaction ID found</strong> (claims can then only be matched by you, not automatically)`}${r.payer_hint ? html`, from <strong>${r.payer_hint}</strong>` : ""}.</div>`
        : html`<div class="form-msg warn">We couldn't read this as a “money received” message. If it is one, send the exact wording (hide your phone number) so the reader can be adjusted.</div>`);
    } catch (err) { toastError(err); }
    setBusy(b, false);
  });
}
