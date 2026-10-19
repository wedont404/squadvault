// Supabase client (official @supabase/supabase-js, pinned, loaded from the jsDelivr CDN as an ES module)
// plus error translation and thin wrappers for RPC calls and Edge Functions.
import { config, isConfigured } from "./config.js";

export let supabase = null; // live binding: set once by initSupabase()

export class AppError extends Error {
  constructor(message, code = "error", original = null) {
    super(message);
    this.name = "AppError";
    this.code = code;
    this.original = original;
  }
}

export async function initSupabase() {
  if (supabase) return supabase;
  if (!isConfigured()) throw new AppError("SquadVault is not configured yet.", "not_configured");
  let mod;
  try {
    mod = await import(config.supabaseJsUrl);
  } catch (e) {
    throw new AppError("Could not load the Supabase client. Check your internet connection and retry.", "cdn_failed", e);
  }
  supabase = mod.createClient(config.supabaseUrl, config.supabasePublishableKey.trim(), {
    auth: {
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
      flowType: "pkce", // keeps auth tokens out of the URL hash, which the router uses
    },
  });
  return supabase;
}

// ---------------------------------------------------------------------------
// Friendly error messages. Server functions raise short machine codes
// (e.g. `not_allowed`); we translate them and never show raw SQL errors.
// ---------------------------------------------------------------------------
const MESSAGES = {
  not_authenticated: "Your session has expired. Please sign in again.",
  not_allowed: "You don't have permission to do that.",
  not_found: "That item could not be found.",
  invalid_group_name: "Group names need 2 to 60 characters.",
  group_limit_reached: "You've reached the limit for groups you can create.",
  invalid_max_uses: "Maximum uses must be between 1 and 100.",
  invalid_valid_days: "Validity must be between 1 and 30 days.",
  too_many_active_invitations: "This group already has 25 active invitations. Revoke one first.",
  invalid_event_name: "Event names need 2 to 80 characters.",
  invalid_amount: "Enter a valid whole-number amount in RWF.",
  invalid_date: "That date isn't valid.",
  event_not_active: "This event is not active.",
  event_not_found: "That event could not be found.",
  invalid_status: "That status isn't valid.",
  invalid_role: "That role isn't valid.",
  last_admin: "A group needs at least one admin. Promote someone else first.",
  use_leave_group: "Use “Leave group” to remove yourself.",
  invalid_description: "Descriptions need 2 to 200 characters.",
  invalid_receipt: "That receipt file isn't valid for this event.",
  insufficient_funds: "That's more than the verified funds currently available for this event.",
  invalid_display_name: "Display names need 1 to 60 characters.",
  invalid_avatar: "That avatar file isn't valid.",
  payments_not_configured: "Payments are not switched on for this project yet.",
  too_many_pending: "You have several payments waiting. Please finish or wait for them first.",
  invalid_phone: "Enter a valid MTN (078/079) or Airtel (072/073) number.",
  phone_network_mismatch: "That phone number doesn't belong to the selected network.",
  invalid_method: "Choose MTN Mobile Money or Airtel Money.",
  provider_unavailable: "The payment provider could not be reached. Nothing was charged. Please try again.",
  provider_timeout: "The payment provider took too long to respond. Nothing was charged. Please try again.",
  simulation_disabled: "Payment simulation is switched off.",
  rate_limited: "Too many attempts. Please wait a few minutes and try again.",
  payment_details_missing: "The leader hasn't added a MoMo number or code for this event yet.",
  invalid_reference: "The transaction ID should be 6 to 20 letters or numbers (or leave it empty).",
  duplicate_reference: "That transaction ID has already been submitted.",
  not_manual: "That payment was handled by the payment provider and can't be changed here.",
  cannot_review_own: "Another leader needs to confirm your own payment.",
  invalid_transition: "That payment has already been handled.",
  invalid_pay_kind: "Choose whether this is a MoMo number or a MoMo code.",
  invalid_pay_code: "A MoMo code is 4 to 10 digits.",
  invalid_account_name: "Account names can be up to 60 characters.",
  invalid_email: "Enter a valid email address.",
  no_such_user: "No SquadVault account uses that email yet. Share an invitation code instead.",
  already_member: "That person is already in this group.",
  group_full: "This group has reached its member limit.",
  invalid_code: "That invitation code isn't valid. It may be wrong, expired, revoked or used up.",
};

export function friendlyError(err) {
  if (!err) return "Something went wrong. Please try again.";
  if (err instanceof AppError) return err.message;
  const msg = String(err.message ?? err ?? "");
  const token = msg.trim().split(/[\s:]/)[0];
  if (MESSAGES[token]) return MESSAGES[token];
  if (MESSAGES[err.code]) return MESSAGES[err.code];
  if (/jwt expired|invalid jwt|refresh token/i.test(msg)) return MESSAGES.not_authenticated;
  if (/failed to fetch|networkerror|load failed|network request failed/i.test(msg)) {
    return "Can't reach the server. Check your connection and try again.";
  }
  if (/invalid login credentials/i.test(msg)) return "Email or password is incorrect.";
  if (/email not confirmed/i.test(msg)) return "Please confirm your email first. Check your inbox.";
  if (/already registered|already been registered/i.test(msg)) return "An account with this email already exists. Try signing in.";
  if (/rate limit|too many requests|over_email_send_rate_limit/i.test(msg)) return MESSAGES.rate_limited;
  if (/password.*(weak|short|least)/i.test(msg)) return "That password is too weak. Use 8+ characters with letters and numbers.";
  if (/permission denied|row-level security|42501/i.test(msg)) return MESSAGES.not_allowed;
  return "Something went wrong. Please try again.";
}

/** Unwrap a supabase-js { data, error } result or throw a friendly AppError. */
export function must(result) {
  if (result?.error) {
    console.error("[supabase]", result.error);
    throw new AppError(friendlyError(result.error), result.error.code ?? "error", result.error);
  }
  return result?.data;
}

export async function rpc(name, args = {}) {
  return must(await supabase.rpc(name, args));
}

/** Invoke an Edge Function and surface its { error: "code" } body as a friendly message. */
export async function invokeFunction(name, body) {
  const { data, error } = await supabase.functions.invoke(name, { body });
  if (error) {
    let code = "";
    try {
      const b = await error.context?.json?.();
      code = b?.error ?? "";
    } catch { /* body wasn't JSON */ }
    throw new AppError(MESSAGES[code] ?? friendlyError(error), code || "function_error", error);
  }
  if (data?.error) throw new AppError(MESSAGES[data.error] ?? friendlyError(data.error), data.error);
  return data;
}

/** Public URL for a file inside the public `avatars` bucket (path is validated first). */
export function avatarUrl(path) {
  if (!path || !/^[0-9a-f-]{36}\/[A-Za-z0-9._-]{1,80}\.(jpg|png|webp)$/.test(path)) return null;
  return `${config.supabaseUrl}/storage/v1/object/public/avatars/${path}`;
}
