// Payment adapter: simulated mode + IntaSend.
//
// !!! READ THIS BEFORE GOING LIVE !!!
// IntaSend's public docs I could reach describe SDK calls (create a checkout, check status by
// invoice_id) and the webhook payload (fields: invoice_id, state, provider, charges, net_amount,
// currency, value, account, api_ref, failed_reason, challenge; states PENDING / PROCESSING /
// COMPLETE / FAILED). They do NOT document the raw REST paths, and I could not confirm that
// IntaSend supports MTN Mobile Money / Airtel Money collections in Rwanda. So:
//   * REST paths are configurable via env (defaults below are UNVERIFIED guesses based on the SDKs).
//   * Nothing here is marked "paid" from the webhook body alone: the webhook handler re-fetches the
//     transaction from the provider and checks api_ref, state, amount and currency first.
//   * Confirm coverage and endpoints with IntaSend support before enabling PAYMENT_MODE=live.
// If IntaSend does not cover Rwanda for you, only this file needs to change (swap the adapter).

                                                        
                                                     

export const MIN_AMOUNT = 100;
export const MAX_AMOUNT = 5_000_000;

export function paymentMode()       {
  const m = (Deno.env.get("PAYMENT_MODE") ?? "").toLowerCase();
  return m === "simulated" || m === "live" ? m : "disabled";
}

/** 07XXXXXXXX / +2507XXXXXXXX / 2507XXXXXXXX -> 2507XXXXXXXX, or null. */
export function normalizeRwPhone(input        )                {
  const digits = String(input ?? "").replace(/[\s\-().]/g, "");
  const m = digits.match(/^(?:\+?250|0)(7[2389]\d{7})$/);
  return m ? `250${m[1]}` : null;
}

/** MTN Rwanda = 078/079, Airtel Rwanda = 072/073. */
export function networkOf(phone        )                       {
  const p = phone.slice(3, 5);
  if (p === "78" || p === "79") return "mtn_momo";
  if (p === "72" || p === "73") return "airtel_money";
  return null;
}

export function newReference()         {
  const bytes = crypto.getRandomValues(new Uint8Array(12));
  return "SV-PAY-" + Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("").toUpperCase();
}

// ---------------------------------------------------------------------------
// IntaSend adapter
// ---------------------------------------------------------------------------
function cfg() {
  const test = (Deno.env.get("INTASEND_TEST_MODE") ?? "true") !== "false";
  const base = test
    ? Deno.env.get("INTASEND_SANDBOX_API_BASE") ?? "https://sandbox.intasend.com"
    : Deno.env.get("INTASEND_API_BASE") ?? "https://payment.intasend.com";
  const secret = Deno.env.get("INTASEND_SECRET_KEY") ?? "";
  const publishable = Deno.env.get("INTASEND_PUBLISHABLE_KEY") ?? "";
  if (!secret || !publishable) throw new Error("provider_not_configured");
  return {
    base: base.replace(/\/$/, ""),
    secret,
    publishable,
    checkoutPath: Deno.env.get("INTASEND_CHECKOUT_PATH") ?? "/api/v1/checkout/",
    statusPath: Deno.env.get("INTASEND_STATUS_PATH") ?? "/api/v1/payment/status/",
    appUrl: Deno.env.get("APP_URL") ?? "",
    methodMtn: Deno.env.get("INTASEND_METHOD_MTN_MOMO") ?? "",
    methodAirtel: Deno.env.get("INTASEND_METHOD_AIRTEL_MONEY") ?? "",
  };
}

async function providerFetch(url        , body         , secret        )                    {
  return await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", Accept: "application/json", Authorization: `Bearer ${secret}` },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(12_000), // provider timeouts must not hang the function
  });
}

                                
                    
                 
                        
                                           
                
               
 
                                 
                                                                                    
                                                                                    
 

export async function intasendInitiate(i               )                          {
  const c = cfg();
  const [first, ...rest] = i.name.trim().split(/\s+/);
  const body                          = {
    public_key: c.publishable,
    amount: i.amount,
    currency: "RWF",
    email: i.email,
    first_name: first || "Member",
    last_name: rest.join(" ") || "-",
    phone_number: i.phone,
    api_ref: i.reference, // our unique reference; echoed back in webhooks and status calls
    comment: "SquadVault contribution",
  };
  if (c.appUrl) body.redirect_url = c.appUrl;
  const method = i.method === "mtn_momo" ? c.methodMtn : c.methodAirtel;
  if (method) body.method = method; // exact provider method code: set via env once confirmed

  const res = await providerFetch(c.base + c.checkoutPath, body, c.secret);
  const text = await res.text();
  let data                      = {};
  try { data = JSON.parse(text); } catch { /* non-JSON error body */ }
  if (!res.ok) throw new Error(`provider_rejected:${res.status}`);

  const providerRef = String(data?.invoice?.invoice_id ?? data?.invoice_id ?? data?.id ?? "") || null;
  const url = typeof data?.url === "string" && data.url.startsWith("https://") ? data.url : null;
  return { providerRef, checkoutUrl: url };
}

                                 
                    
                                                                   
                        
                                     
                          
                               
 

/** Independent server-to-server verification. This, not the webhook body, is the source of truth. */
export async function intasendStatus(invoiceId        )                          {
  const c = cfg();
  const res = await providerFetch(c.base + c.statusPath, { invoice_id: invoiceId }, c.secret);
  if (!res.ok) throw new Error(`provider_status_failed:${res.status}`);
  const data = await res.json();
  const inv = data?.invoice ?? data;
  const value = Number(inv?.value);
  return {
    invoiceId: String(inv?.invoice_id ?? invoiceId),
    state: String(inv?.state ?? "").toUpperCase(),
    apiRef: inv?.api_ref ? String(inv.api_ref) : null,
    // Only whole-RWF amounts are acceptable ("1000.00" parses to 1000). Anything else -> null,
    // which payment_settle treats as an amount mismatch (never paid).
    amount: Number.isInteger(value) ? value : null,
    currency: inv?.currency ? String(inv.currency).toUpperCase() : null,
    raw: inv ?? {},
  };
}
