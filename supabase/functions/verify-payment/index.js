// verify-payment: the signed-in contributor asks "what is the status of my payment?".
//
//  live mode:      server-to-server provider check (covers a missed/late webhook), then payment_settle.
//                  The caller cannot influence the result; they only trigger a re-check.
//  simulated mode: the caller may complete THEIR OWN simulated payment with
//                  { simulate: "success" | "fail" }. Rows are flagged is_simulated and the UI
//                  labels them. This path is refused entirely unless PAYMENT_MODE=simulated.
import { adminClient, corsHeaders, json, userFromRequest } from "../_shared/clients.js";
import { intasendStatus, paymentMode } from "../_shared/payments.js";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(req) });
  if (req.method !== "POST") return json(req, { error: "method_not_allowed" }, 405);

  const user = await userFromRequest(req);
  if (!user) return json(req, { error: "not_authenticated" }, 401);

  const mode = paymentMode();
  if (mode === "disabled") return json(req, { error: "payments_not_configured" }, 503);

  let body                         ;
  try { body = await req.json(); } catch { return json(req, { error: "invalid_json" }, 400); }
  const reference = String(body.reference ?? "");
  if (!/^SV-PAY-[0-9A-F]{24}$/.test(reference)) return json(req, { error: "invalid_reference" }, 400);

  const admin = adminClient();
  const { data: c } = await admin
    .from("contributions")
    .select("id,user_id,amount,status,provider,provider_ref,is_simulated,failure_reason")
    .eq("payment_reference", reference)
    .maybeSingle();

  // Same answer for "missing" and "someone else's": no information leak.
  if (!c || c.user_id !== user.id) return json(req, { error: "not_found" }, 404);

  const reply = (status        , extra                          = {}) =>
    json(req, { reference, status, simulated: c.is_simulated, ...extra });

  if (c.status !== "pending") return reply(c.status, { reason: c.failure_reason ?? null });

  // ---------------- simulated ----------------
  if (c.is_simulated) {
    if (mode !== "simulated") return json(req, { error: "simulation_disabled" }, 403);
    const sim = String(body.simulate ?? "");
    if (sim !== "success" && sim !== "fail") return reply("pending");
    const state = sim === "success" ? "COMPLETE" : "FAILED";
    const { data, error } = await admin.rpc("payment_settle", {
      p_reference: reference,
      p_provider: "simulated",
      p_provider_event_id: `sim:${reference}:${state}`,
      p_state: state,
      p_amount: c.amount,
      p_currency: "RWF",
      p_provider_ref: null,
      p_payload: { failed_reason: "simulated failure" },
    });
    if (error) return json(req, { error: "settle_failed" }, 500);
    return reply(state === "COMPLETE" ? "paid" : "failed", { outcome: data?.outcome });
  }

  // ---------------- live ----------------
  if (mode !== "live") return json(req, { error: "not_live" }, 403);
  if (!c.provider_ref) return reply("pending", { note: "waiting_for_provider" });

  try {
    const s = await intasendStatus(c.provider_ref);
    if (s.apiRef !== reference) return reply("pending", { note: "reference_mismatch" });
    const { data, error } = await admin.rpc("payment_settle", {
      p_reference: reference,
      p_provider: "intasend",
      p_provider_event_id: `${c.provider_ref}:${s.state}`,
      p_state: s.state,
      p_amount: s.amount !== null && Number.isInteger(s.amount) ? s.amount : null,
      p_currency: s.currency,
      p_provider_ref: c.provider_ref,
      p_payload: { failed_reason: s.raw?.failed_reason ?? null },
    });
    if (error) return json(req, { error: "settle_failed" }, 500);
    const { data: after } = await admin.from("contributions").select("status").eq("payment_reference", reference).maybeSingle();
    return reply(after?.status ?? "pending", { outcome: data?.outcome });
  } catch (e) {
    console.error("verify-payment provider error:", e instanceof Error ? e.message : "unknown");
    return json(req, { error: "provider_unavailable", status: "pending" }, 502);
  }
});
