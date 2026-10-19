// Terms & Conditions (shown in a dialog from the sign-up form, the footer and Settings).
// Plain-language template. Have it reviewed against your own situation before relying on it.
import { html } from "./utils.js";
import { openModal } from "./ui.js";
import { config } from "./config.js";

export const TERMS_VERSION = "2026-10-19";

const S = (title, ...body) => html`<h3 style="margin:18px 0 6px;font-size:var(--fs-md)">${title}</h3>${body}`;
const P = (t) => html`<p class="muted" style="margin:0 0 8px;line-height:1.6">${t}</p>`;

export function termsContent() {
  return html`<div class="terms" style="max-height:60vh;overflow:auto;padding-right:6px">
    <p class="faint" style="font-size:var(--fs-xs)">Version ${TERMS_VERSION}</p>
    ${S("1. What SquadVault is", P("SquadVault is a record-keeping tool for private savings groups in Rwanda. It helps a group agree on goals, see who has paid, and keep a trail of expenses. SquadVault is not a bank, a mobile money provider or a licensed financial institution. It never holds, receives, sends or lends your money."))}
    ${S("2. Your account", P("Give accurate details and keep your password private. You are responsible for what happens under your account. You must be old enough to make an agreement under Rwandan law, or have a parent or guardian's permission."))}
    ${S("3. Groups and leaders", P("A group leader (admin or treasurer) creates events, chooses the MoMo number or code members pay to, confirms payments and records expenses. Members pay the leader directly, and the leader is responsible for how the money is collected, kept and spent. SquadVault is not a party to any arrangement between members and leaders. Disagreements about money are for the people involved to settle between themselves."))}
    ${S("4. Payments are made outside SquadVault", P("Contributions are sent from your own phone through MTN MoMo or Airtel Money. Network fees may apply. Always check the number and the account name before you pay, because a payment sent to the wrong number may not be recoverable. Never share your PIN. SquadVault will never ask for it, and the network asks for it only on its own screen."), P("When you tap “I've paid”, SquadVault only records your claim. It counts toward the target after the leader confirms it, or after automatic checking matches it. Pending, failed and refunded amounts are never counted as collected."))}
    ${S("5. Automatic payment checking (optional)", P("A leader may let their phone forward MoMo “money received” messages to SquadVault. From each message we keep only the amount, the transaction ID and the sender's name as shown in the message, and we do not keep the message itself. A claim is confirmed automatically only when its transaction ID and amount both match. Checking is best-effort and can be wrong or delayed, so leaders remain responsible for the final confirmation. A leader who turns this on is responsible for doing so with the knowledge of the group."))}
    ${S("6. Records", P("SquadVault shows what members and leaders enter and what is confirmed. We do not guarantee that those entries are correct, complete or agreed by everyone. Leaders can correct or refund records, and those changes stay visible in the history."))}
    ${S("7. Your information", P("We collect your email, display name, optional profile picture, the groups you join, your contributions and, for leaders, expenses and receipts. We use it only to run SquadVault. Other members of your group can see your name and your contributions to that group's events. We do not sell your information. Data is stored with our infrastructure provider (Supabase). You can ask to correct or delete your account, and we handle personal data in line with Rwanda's personal data protection law."))}
    ${S("8. Acceptable use", P("Do not make false payment claims, impersonate others, harass members, attempt to break into accounts or the service, or use SquadVault for anything unlawful. We may suspend or remove accounts or groups that do."))}
    ${S("9. No guarantees", P("SquadVault is provided “as is”. We work to keep it available and accurate but cannot promise it will always work without errors. To the extent the law allows, we are not responsible for lost or misdirected money, disputes between members and leaders, network or provider failures, or losses caused by wrong information entered by users."))}
    ${S("10. Changes and law", P("We may update these terms and will change the version date above when we do. Continuing to use SquadVault after a change means you accept it. These terms are governed by the laws of Rwanda."))}
    ${config.contactEmail ? S("11. Contact", P(`Questions about these terms: ${config.contactEmail}`)) : ""}
  </div>`;
}

export function openTerms() {
  const m = openModal({
    title: "Terms & Conditions",
    content: termsContent(),
    footer: html`<button class="btn primary" type="button" data-close>Close</button>`,
  });
  m.el.style.width = "min(720px, 100%)";
  m.el.querySelector("[data-close]")?.addEventListener("click", () => m.close());
  return m;
}
