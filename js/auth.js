// Authentication: sign up, sign in, sign out, password reset/recovery, session restore.
// Identity always comes from the verified Supabase session; no user id is ever sent by the browser.
import { supabase, friendlyError } from "./supabase.js";
import { html, isEmail, passwordProblem } from "./utils.js";
import { icon, field, mount, on, setBusy, setFieldError, clearFieldErrors, formMessage, formMsgSlot, formData, siteFooter, $ } from "./ui.js";
import { TERMS_VERSION } from "./terms.js";

export const redirectUrl = () => `${location.origin}${location.pathname}`;

// ---------------------------------------------------------------------------
// Session lifecycle
// ---------------------------------------------------------------------------
/**
 * Subscribes to auth changes. handlers: { onSession(session), onSignedOut({expired}), onRecovery() }.
 * Returns the initial session (restored from storage after a refresh, or null).
 */
export async function initAuth(handlers) {
  let hadSession = false;
  let manualSignOut = false;
  window.addEventListener("sv:manual-signout", () => { manualSignOut = true; });

  supabase.auth.onAuthStateChange((event, session) => {
    // The recovery flag is set synchronously, so the SIGNED_IN that arrives with it can never open the app.
    if (event === "PASSWORD_RECOVERY") { handlers.onRecovery?.(session); return; }
    // Never call supabase APIs synchronously in here (documented deadlock); defer a tick.
    setTimeout(() => {
      if (event === "SIGNED_OUT") {
        const expired = hadSession && !manualSignOut;
        hadSession = false;
        manualSignOut = false;
        return handlers.onSignedOut?.({ expired });
      }
      if (session && (event === "SIGNED_IN" || event === "INITIAL_SESSION" || event === "USER_UPDATED")) {
        const first = !hadSession;
        hadSession = true;
        if (first) handlers.onSession?.(session);
      }
      if (event === "TOKEN_REFRESHED" && session) hadSession = true;
    }, 0);
  });

  const { data, error } = await supabase.auth.getSession();
  if (error) console.error("getSession failed", error);
  return data?.session ?? null;
}

// ---------------------------------------------------------------------------
// Email links (confirm email, reset password)
//   New style  : <site>/?token_hash=...&type=recovery|signup   -> verifyOtp, works in ANY browser or phone app
//   Older style: <site>/?code=...                              -> only works in the browser that asked for it
// ---------------------------------------------------------------------------
const LINK_TYPES = new Set(["signup", "recovery", "invite", "magiclink", "email", "email_change"]);

/** Reads (does not clear) what an email link left in the address bar. */
export function peekAuthLink() {
  const q = new URLSearchParams(location.search);
  const h = new URLSearchParams(/error/.test(location.hash) ? location.hash.replace(/^#\/?/, "") : "");
  const type = q.get("type");
  return {
    tokenHash: q.get("token_hash") && LINK_TYPES.has(type) ? q.get("token_hash") : null,
    type,
    code: q.get("code"),
    error: q.get("error_description") || h.get("error_description") || (q.get("error") ? "error" : null),
  };
}

export function clearAuthLink() {
  if (location.search || /error/.test(location.hash)) history.replaceState(null, "", location.pathname);
}

/** Exchanges the one-time token from an email link for a session. */
export async function verifyEmailLink({ tokenHash, type }) {
  const { error } = await supabase.auth.verifyOtp({ token_hash: tokenHash, type });
  return { ok: !error, error };
}

export const LINK_NOTICES = {
  expired: { type: "warn", text: "That link has expired or was already used. Request a new one below." },
  samebrowser: { type: "warn", text: "That link couldn't be opened here. Open it in the same browser where you asked for it, or request a new link below." },
};

export async function signOut({ everywhere = false } = {}) {
  window.dispatchEvent(new Event("sv:manual-signout"));
  await supabase.auth.signOut({ scope: everywhere ? "global" : "local" });
}

// ---------------------------------------------------------------------------
// Screens
// ---------------------------------------------------------------------------
const heroPoints = [
  ["shield", "Private groups, invite-only. Every record is locked to your squad."],
  ["trend", "Progress counts verified payments only. Pending money is never counted."],
  ["receipt", "Every expense tracked with a private receipt trail."],
];

function shell(card) {
  return html`<div class="auth-wrap">
    <section class="auth-hero" aria-label="About SquadVault">
      <div class="brand"><img src="assets/logo.svg" alt="SquadVault"></div>
      <div>
        <p class="eyebrow">Rwanda · RWF</p>
        <h1 class="hero-title" style="margin-top:10px">Save together.<br><em>Celebrate together.</em></h1>
        <p class="muted" style="margin-top:16px;max-width:46ch">Private savings groups for weddings, birthdays, trips and every goal you chase with your people.</p>
      </div>
      <ul>${heroPoints.map(([i, t]) => html`<li>${icon(i)}<span>${t}</span></li>`)}</ul>
    </section>
    <main class="auth-panel" id="main"><div style="display:grid;justify-items:center;width:100%">${card}${siteFooter()}</div></main>
  </div>`;
}

export function renderAuth(root, { mode = "signin", notice = null, prefill = "", resend = "" } = {}) {
  const modes = {
    signin: renderSignIn,
    signup: renderSignUp,
    forgot: renderForgot,
    recovery: renderRecovery,
  };
  (modes[mode] ?? renderSignIn)(root, notice, { prefill, resend });
}

function noticeBox(notice) {
  return notice ? html`<div class="form-msg ${notice.type ?? "info"}" role="status">${notice.text}</div>` : "";
}

function renderSignIn(root, notice, { prefill = "", resend = "" } = {}) {
  mount(root, shell(html`<div class="auth-card">
    <div><p class="eyebrow">Welcome back</p><h1>Sign in</h1></div>
    ${noticeBox(notice)}
    ${resend ? html`<div class="row" style="gap:10px;align-items:center"><button class="btn sm" type="button" data-resend="${resend}">${icon("refresh")} Resend confirmation email</button><span class="faint" style="font-size:var(--fs-xs)" data-resend-msg></span></div>` : ""}
    <form class="form" novalidate data-form="signin">
      ${field({ name: "email", label: "Email", type: "email", autocomplete: "email", placeholder: "you@example.com", value: prefill })}
      ${field({ name: "password", label: "Password", type: "password", autocomplete: "current-password" })}
      ${formMsgSlot()}
      <button class="btn primary block" type="submit">Sign in</button>
    </form>
    <div class="auth-links">
      <button class="link-btn" type="button" data-go="forgot">Forgot password?</button>
      <button class="link-btn" type="button" data-go="signup">Create an account</button>
    </div></div>`));
  wire(root);
  $("#f-email", root)?.focus();
}

function renderSignUp(root) {
  mount(root, shell(html`<div class="auth-card">
    <div><p class="eyebrow">Start saving</p><h1>Create your account</h1></div>
    <form class="form" novalidate data-form="signup">
      ${field({ name: "display_name", label: "Display name", autocomplete: "nickname", placeholder: "How your squad sees you", attrs: 'maxlength="60"' })}
      ${field({ name: "email", label: "Email", type: "email", autocomplete: "email", placeholder: "you@example.com" })}
      ${field({ name: "password", label: "Password", type: "password", autocomplete: "new-password", help: "At least 8 characters, with a letter and a number." })}
      <div class="field" data-field="agree"><label class="check"><input type="checkbox" id="f-agree" name="agree" value="yes" aria-describedby="err-agree"><span>I have read and agree to the <button class="link-btn" type="button" data-terms>Terms &amp; Conditions</button>.</span></label><div class="error" id="err-agree" role="alert"></div></div>
      ${formMsgSlot()}
      <button class="btn primary block" type="submit">Create account</button>
    </form>
    <div class="auth-links"><span class="muted">Already have an account?</span><button class="link-btn" type="button" data-go="signin">Sign in</button></div></div>`));
  wire(root);
  $("#f-display_name", root)?.focus();
}

function renderForgot(root, notice) {
  mount(root, shell(html`<div class="auth-card">
    <div><p class="eyebrow">Account recovery</p><h1>Reset your password</h1>
      <p class="muted" style="margin-top:8px">We'll email you a secure link to choose a new password.</p></div>
    ${noticeBox(notice)}
    <form class="form" novalidate data-form="forgot">
      ${field({ name: "email", label: "Email", type: "email", autocomplete: "email" })}
      ${formMsgSlot()}
      <button class="btn primary block" type="submit">Send reset link</button>
    </form>
    <div class="auth-links"><button class="link-btn" type="button" data-go="signin">Back to sign in</button></div></div>`));
  wire(root);
  $("#f-email", root)?.focus();
}

function renderRecovery(root) {
  mount(root, shell(html`<div class="auth-card">
    <div><p class="eyebrow">Almost there</p><h1>Choose a new password</h1></div>
    <form class="form" novalidate data-form="recovery">
      ${field({ name: "password", label: "New password", type: "password", autocomplete: "new-password", help: "At least 8 characters, with a letter and a number." })}
      ${field({ name: "confirm", label: "Confirm new password", type: "password", autocomplete: "new-password" })}
      ${formMsgSlot()}
      <button class="btn primary block" type="submit">Update password</button>
    </form></div>`));
  wire(root);
  $("#f-password", root)?.focus();
}

// ---------------------------------------------------------------------------
// Form wiring
// ---------------------------------------------------------------------------
// A short pause after the email service says "busy", so people don't keep pressing and make it worse.
let coolUntil = 0;
const waitLeft = () => Math.max(0, Math.ceil((coolUntil - Date.now()) / 1000));

function wire(root) {
  on(root, "click", "[data-go]", (_, b) => renderAuth(root, { mode: b.dataset.go }));
  on(root, "click", "[data-resend]", async (_, b) => {
    const msg = $("[data-resend-msg]", root);
    if (waitLeft() > 0) { if (msg) msg.textContent = `Please wait ${waitLeft()}s first.`; return; }
    setBusy(b, true, "Sending…");
    try {
      const { error } = await supabase.auth.resend({ type: "signup", email: b.dataset.resend, options: { emailRedirectTo: redirectUrl() } });
      if (error) throw error;
      coolUntil = Date.now() + 60000;
      if (msg) msg.textContent = "Sent. It can take a minute to arrive.";
    } catch (err) {
      if (/rate|busy|429/i.test(`${err.code} ${err.status} ${err.message}`)) coolUntil = Date.now() + 90000;
      if (msg) msg.textContent = friendlyError(err);
    }
    setBusy(b, false);
  });
  const form = $("form[data-form]", root);
  if (!form) return;
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    clearFieldErrors(form);
    const kind = form.dataset.form;
    const v = formData(form);
    const btn = $('button[type="submit"]', form);
    if (btn?.disabled) return; // already sending: a second tap must not send a second email
    if ((kind === "signup" || kind === "forgot") && waitLeft() > 0) {
      formMessage(form, "warn", `The email service is busy. Please wait ${waitLeft()} seconds, then try again.`);
      return;
    }
    const bad = (name, msg) => { setFieldError(form, name, msg); $(`#f-${name}`, form)?.focus(); return true; };

    try {
      if (kind === "signin") {
        if (!isEmail(v.email)) return bad("email", "Enter a valid email address.");
        if (!v.password) return bad("password", "Enter your password.");
        setBusy(btn, true, "Signing in…");
        const { error } = await supabase.auth.signInWithPassword({ email: v.email.trim(), password: v.password });
        if (error) {
          if (error.code === "email_not_confirmed" || /email not confirmed/i.test(error.message ?? "")) {
            renderAuth(root, { mode: "signin", prefill: v.email.trim(), resend: v.email.trim(), notice: { type: "warn", text: "Your email isn't confirmed yet. Open the link we emailed you, or tap Resend to get a new one." } });
            return;
          }
          throw error;
        } // success is picked up by onAuthStateChange
      } else if (kind === "signup") {
        const name = v.display_name.trim();
        if (name.length < 1 || name.length > 60) return bad("display_name", "Use 1 to 60 characters.");
        if (!isEmail(v.email)) return bad("email", "Enter a valid email address.");
        const pw = passwordProblem(v.password);
        if (pw) return bad("password", pw);
        if (v.agree !== "yes") return bad("agree", "Please accept the Terms & Conditions to continue.");
        setBusy(btn, true, "Creating account…");
        const { data, error } = await supabase.auth.signUp({
          email: v.email.trim(),
          password: v.password,
          options: { data: { display_name: name, terms_version: TERMS_VERSION, terms_accepted_at: new Date().toISOString() }, emailRedirectTo: redirectUrl() },
        });
        if (error) throw error;
        if (!data.session) {
          // With email confirmation on, Supabase answers an already-registered email with a "fake" user that
          // has no identities and sends nothing. Tell the person the truth instead of waiting for an email.
          const existing = Array.isArray(data.user?.identities) && data.user.identities.length === 0;
          renderAuth(root, existing
            ? { mode: "signin", prefill: v.email.trim(), notice: { type: "warn", text: "That email already has a SquadVault account, so no new email was sent. Sign in below, or use “Forgot password?” if you don't remember it." } }
            : { mode: "signin", prefill: v.email.trim(), resend: v.email.trim(), notice: { type: "ok", text: "Account created. We sent a confirmation link to your email. Open it (check spam too), then sign in. No email after a few minutes? Tap Resend." } });
        }
      } else if (kind === "forgot") {
        if (!isEmail(v.email)) return bad("email", "Enter a valid email address.");
        setBusy(btn, true, "Sending…");
        const { error } = await supabase.auth.resetPasswordForEmail(v.email.trim(), { redirectTo: redirectUrl() });
        if (error) throw error;
        // Same message whether or not the email exists: no account enumeration.
        formMessage(form, "ok", "If an account exists for that email, a reset link is on its way.");
      } else if (kind === "recovery") {
        const pw = passwordProblem(v.password);
        if (pw) return bad("password", pw);
        if (v.password !== v.confirm) return bad("confirm", "The passwords don't match.");
        setBusy(btn, true, "Updating…");
        const { error } = await supabase.auth.updateUser({ password: v.password });
        if (error) throw error;
        window.dispatchEvent(new CustomEvent("sv:recovery-done"));
      }
    } catch (err) {
      if (/over_email_send_rate_limit|over_request_rate_limit/.test(String(err?.code)) || err?.status === 429) coolUntil = Date.now() + 60000;
      formMessage(form, "error", friendlyError(err));
    } finally {
      setBusy(btn, false);
    }
  });
}

// ---------------------------------------------------------------------------
// Deferred email confirmation (needed for chat and photos only)
// ---------------------------------------------------------------------------
let verifyCoolUntil = 0;
/** Sends a one-time sign-in link to the signed-in person's own email. Resolves { ok, wait?, error? }. */
export async function sendVerifyEmail(email) {
  const left = Math.ceil((verifyCoolUntil - Date.now()) / 1000);
  if (left > 0) return { ok: false, wait: left };
  const { error } = await supabase.auth.signInWithOtp({ email, options: { shouldCreateUser: false, emailRedirectTo: redirectUrl() } });
  if (error) {
    if (error.status === 429 || /rate|limit/i.test(`${error.code} ${error.message}`)) verifyCoolUntil = Date.now() + 90000;
    return { ok: false, error };
  }
  verifyCoolUntil = Date.now() + 60000;
  return { ok: true };
}
