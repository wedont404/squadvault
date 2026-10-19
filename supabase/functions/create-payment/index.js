// create-payment: authenticated user asks to contribute to an event.
//
// 1. Verify the caller's JWT (identity comes from Supabase Auth, never from the body).
// 2. Validate amount / phone / method. The database re-validates membership, event status, limits.
// 3. Insert a PENDING contribution with a unique internal reference (service-role RPC).
// 4. simulated mode -> no provider call. live mode -> start the provider payment server-side.
// The browser never sets a paid status; only payment_settle (called by webhook / verify) can.
import { adminClient, corsHeaders, json, userFromRequest } from "../_shared/clients.js";
import {
  MAX_AMOUNT, MIN_AMOUNT, intasendInitiate, networkOf, newReference, normalizeRwPhone, paymentMode,
                     
} from "../_shared/payments.js";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, { error: "method_not_allowed" }, 405);

  const user = await userFromRequest(req);
  if (!user) return json(req, { error: "not_authenticated" }, 401);

  const mode = paymentMode();
  if (mode === "disabled") return json(req, { error: "payments_not_configured" }, 503);

  let body                         ;
  try { body = await req.json(); } catch { return json(req, { error: "invalid_json" }, 400); }

  const eventId = String(body.event_id ?? "");
  const method = String(body.method ?? "")                 ;
  const amount = body.amount;
  const phone = normalizeRwPhone(String(body.phone ?? ""));

  if (!/^[0-9a-f-]{36}$/i.test(eventId)) return json(req, { error: "invalid_event" }, 400);
  if (method !== "mtn_momo" && method !== "airtel_money") return json(req, { error: "invalid_method" }, 400);
  if (typeof amount !== "number" || !Number.isSafeInteger(amount) || amount < MIN_AMOUNT || amount > MAX_AMOUNT) {
    return json(req, { error: "invalid_amount", min: MIN_AMOUNT, max: MAX_AMOUNT }, 400);
  }
  if (!phone) return json(req, { error: "invalid_phone" }, 400);
  if (networkOf(phone) !== method) return json(req, { error: "phone_network_mismatch" }, 400);

  const admin = adminClient();
  const reference = newReference();

  const { data: contributionId, error } = await admin.rpc("payment_create_pending", {
    p_user_id: user.id,
    p_event_id: eventId,
    p_amount: amount,
    p_method: method,
    p_reference: reference,
    p_simulated: mode === "simulated",
  });
  if (error) {
    const code = error.message.split(/\s/)[0];
    const known = ["not_allowed", "event_not_active", "event_not_found", "too_many_pending", "invalid_amount", "invalid_method"];
    return json(req, { error: known.includes(code) ? code : "could_not_start_payment" }, known.includes(code) ? 400 : 500);
  }

  if (mode === "simulated") {
    return json(req, {
      mode: "simulated",
      simulated: true,
      contribution_id: contributionId,
      reference,
      status: "pending",
      message: "SIMULATED payment. No real money moves. Use the simulate buttons to complete it.",
    });
  }

  // ---- live mode ----
  try {
    const name = String(user.user_metadata?.display_name ?? user.email?.split("@")[0] ?? "Member");
    const result = await intasendInitiate({ reference, amount, method, phone, email: user.email ?? "", name });
    if (result.providerRef) {
      await admin.rpc("payment_attach_provider", { p_reference: reference, p_provider_ref: result.providerRef });
    }
    return json(req, {
      mode: "live",
      simulated: false,
      contribution_id: contributionId,
      reference,
      status: "pending",
      checkout_url: result.checkoutUrl,
      message: result.checkoutUrl
        ? "Continue on the secure payment page, or approve the prompt on your phone."
        : "Approve the payment prompt on your phone. We will confirm it as soon as the provider does.",
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : "provider_error";
    await admin.rpc("payment_mark_failed", { p_reference: reference, p_reason: msg.slice(0, 100) });
    console.error("create-payment provider error:", msg); // never log secrets or phone numbers
    const timeout = e instanceof DOMException && e.name === "TimeoutError";
    return json(req, { error: timeout ? "provider_timeout" : "provider_unavailable" }, 502);
  }
});
