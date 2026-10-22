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
  receipt_used: "That MoMo message has already been used for another payment.",
  amount_mismatch: "The amount in that MoMo message is different from the claim, so it can't be used to confirm it.",
  invalid_token: "That secret isn't valid.",
  slow_down: "Too many messages at once. Try again in a minute.",
  invalid_code: "That invitation code isn't valid. It may be wrong, expired, revoked or used up.",
  plan_limit_members: "This group has reached the member limit of its plan. An admin can upgrade the group plan on the group page.",
  plan_limit_events: "This group already has the most active events its plan allows. Finish an event, or upgrade the plan on the group page.",
  plan_limit_photos: "The photo wall of this group is full on its current plan. An admin can upgrade the plan on the group page.",
  plan_feature_autocheck: "Automatic payment checking is part of the Plus and Pro plans. An admin can upgrade on the group page.",
  invalid_plan: "Choose Plus or Pro, monthly or yearly.",
  request_pending: "An upgrade request is already waiting for approval.",
  too_many_games: "You already have 3 open tables. Close one or finish a game first.",
  game_started: "That game has already started.",
  game_full: "That table is full.",
  not_enough_players: "You need at least 2 players to start.",
  not_your_turn: "It's not your turn yet.",
  cell_taken: "That square is taken. Pick another.",
  column_full: "That column is full. Pick another.",
  already_moved: "You've already played this round.",
  too_late: "Time's up for this question.",
  not_in_game: "Join the game first to play.",
  game_over: "This game is over.",
  invalid_move: "That move isn't allowed.",
  email_unverified: "Confirm your email first to chat or share photos. Tap “Send confirmation email” on the Squad page.",
  email_not_proven: "We couldn't confirm your email from that link. Tap “Send confirmation email” again and open the newest link.",
  invalid_photo: "That picture couldn't be used. Try another JPG, PNG or WebP image.",
  invalid_message: "Messages need 1 to 1000 characters.",
  invalid_game: "That game isn't set up correctly. Check the title and options.",
  game_closed: "This game is already closed.",
  too_many_games: "You already have several open games. Close one first.",
  // Sign-up / sign-in service limits (these come from the email service, not from the person)
  over_email_send_rate_limit: "Our email service is busy right now, so the confirmation email could not be sent. Your details were not wrong. Please wait a few minutes and try again. If you already tried once, try signing in first.",
  over_request_rate_limit: "Lots of people are using SquadVault at the moment. Please wait a minute and try again.",
  user_already_exists: "An account with this email already exists. Try signing in.",
  email_not_confirmed: "Please confirm your email first. Check your inbox (and spam), or tap Resend.",
  weak_password: "That password is too weak. Use 8+ characters with letters and numbers.",
  email_address_invalid: "That email address doesn't look valid.",
};

export function friendlyError(err) {
  if (!err) return "Something went wrong. Please try again.";
  if (err instanceof AppError) return err.message;
  const msg = String(err.message ?? err ?? "");
  const token = msg.trim().split(/[\s:]/)[0];
  if (MESSAGES[token]) return MESSAGES[token];
  if (MESSAGES[err.code]) return MESSAGES[err.code];
  if (err.status === 429 && /email/i.test(msg)) return MESSAGES.over_email_send_rate_limit;
  if (err.status === 429) return MESSAGES.over_request_rate_limit;
  if (/jwt expired|invalid jwt|refresh token/i.test(msg)) return MESSAGES.not_authenticated;
  if (/failed to fetch|networkerror|load failed|network request failed/i.test(msg)) {
    return "Can't reach the server. Check your connection and try again.";
  }
  if (/invalid login credentials/i.test(msg)) return "Email or password is incorrect.";
  if (/email not confirmed/i.test(msg)) return "Please confirm your email first. Check your inbox.";
  if (/already registered|already been registered/i.test(msg)) return "An account with this email already exists. Try signing in.";
  if (/email rate limit|over_email_send_rate_limit/i.test(msg)) return MESSAGES.over_email_send_rate_limit;
  if (/rate limit|too many requests/i.test(msg)) return MESSAGES.rate_limited;
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
