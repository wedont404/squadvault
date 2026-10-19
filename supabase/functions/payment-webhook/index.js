// payment-webhook: called by the payment provider (no Supabase JWT, verify_jwt = false).
//
// Defence in depth. A request only changes money state if ALL of these hold:
//   1. The shared `challenge` secret matches (constant-time compare). Weak on its own, so:
//   2. We IGNORE the amount/state in the body and re-fetch the invoice from the provider API.
//   3. The provider says api_ref == our reference, state, amount and currency (RWF).
//   4. payment_settle() re-checks amount/currency vs the stored contribution, is idempotent
//      (unique provider_event_id), and never reverts a paid row.
// Replays and duplicate callbacks return 200 {outcome:"duplicate"} and change nothing.
import { adminClient, json, safeEqual } from "../_shared/clients.js";
import { intasendStatus, paymentMode } from "../_shared/payments.js";

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(req, { error: "method_not_allowed" }, 405);
  if (paymentMode() !== "live") return json(req, { error: "not_live" }, 404);

  const expected = Deno.env.get("INTASEND_WEBHOOK_CHALLENGE") ?? "";
  if (!expected) return json(req, { error: "webhook_not_configured" }, 503);

  let payload                     ;
  try { payload = await req.json(); } catch { return json(req, { error: "invalid_json" }, 400); }

  if (!safeEqual(String(payload?.challenge ?? ""), expected)) {
    return json(req, { error: "unauthorized" }, 401);
  }
  const invoiceId = String(payload?.invoice_id ?? "");
  if (!/^[A-Za-z0-9_-]{3,64}$/.test(invoiceId)) return json(req, { error: "invalid_invoice" }, 400);

  // Independent verification with the provider. A timeout/5xx => we answer 5xx so the provider retries.
  let status;
  try {
    status = await intasendStatus(invoiceId);
  } catch (e) {
    console.error("webhook verification failed:", e instanceof Error ? e.message : "unknown");
    return json(req, { error: "verification_unavailable" }, 503);
  }

  const reference = status.apiRef ?? "";
  if (!reference.startsWith("SV-PAY-")) return json(req, { outcome: "ignored_foreign_reference" }, 200);
  if (String(payload?.api_ref ?? reference) !== reference) {
    return json(req, { outcome: "reference_mismatch" }, 200); // body disagrees with provider: do nothing
  }

  const { data, error } = await adminClient().rpc("payment_settle", {
    p_reference: reference,
    p_provider: "intasend",
    p_provider_event_id: `${invoiceId}:${status.state}`,
    p_state: status.state,
    p_amount: status.amount !== null && Number.isInteger(status.amount) ? status.amount : null,
    p_currency: status.currency,
    p_provider_ref: invoiceId,
    p_payload: { failed_reason: status.raw?.failed_reason ?? null, provider: status.raw?.provider ?? null },
  });
  if (error) {
    console.error("payment_settle error:", error.message);
    return json(req, { error: "settle_failed" }, 500);
  }
  return json(req, data ?? { outcome: "unknown" }, 200);
});
