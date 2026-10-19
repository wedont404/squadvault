// Authentication: sign up, sign in, sign out, password reset/recovery, session restore.
// Identity always comes from the verified Supabase session; no user id is ever sent by the browser.
import { supabase, friendlyError } from "./supabase.js";
import { html, isEmail, passwordProblem } from "./utils.js";
import { icon, field, mount, on, setBusy, setFieldError, clearFieldErrors, formMessage, formMsgSlot, formData, $ } from "./ui.js";

const redirectUrl = () => `${location.origin}${location.pathname}`;

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
    // Never call supabase APIs synchronously in here (documented deadlock); defer a tick.
    setTimeout(() => {
      if (event === "PASSWORD_RECOVERY") return handlers.onRecovery?.(session);
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
    <main class="auth-panel" id="main">${card}</main>
  </div>`;
}

export function renderAuth(root, { mode = "signin", notice = null } = {}) {
  const modes = {
    signin: renderSignIn,
    signup: renderSignUp,
    forgot: renderForgot,
    recovery: renderRecovery,
  };
  (modes[mode] ?? renderSignIn)(root, notice);
}

function noticeBox(notice) {
  return notice ? html`<div class="form-msg ${notice.type ?? "info"}" role="status">${notice.text}</div>` : "";
}

function renderSignIn(root, notice) {
  mount(root, shell(html`<div class="auth-card">
    <div><p class="eyebrow">Welcome back</p><h1>Sign in</h1></div>
    ${noticeBox(notice)}
    <form class="form" novalidate data-form="signin">
      ${field({ name: "email", label: "Email", type: "email", autocomplete: "email", placeholder: "you@example.com" })}
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
      ${formMsgSlot()}
      <button class="btn primary block" type="submit">Create account</button>
    </form>
    <div class="auth-links"><span class="muted">Already have an account?</span><button class="link-btn" type="button" data-go="signin">Sign in</button></div></div>`));
  wire(root);
  $("#f-display_name", root)?.focus();
}

function renderForgot(root) {
  mount(root, shell(html`<div class="auth-card">
    <div><p class="eyebrow">Account recovery</p><h1>Reset your password</h1>
      <p class="muted" style="margin-top:8px">We'll email you a secure link to choose a new password.</p></div>
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
function wire(root) {
  on(root, "click", "[data-go]", (_, b) => renderAuth(root, { mode: b.dataset.go }));
  const form = $("form[data-form]", root);
  if (!form) return;
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    clearFieldErrors(form);
    const kind = form.dataset.form;
    const v = formData(form);
    const btn = $('button[type="submit"]', form);
    const bad = (name, msg) => { setFieldError(form, name, msg); $(`#f-${name}`, form)?.focus(); return true; };

    try {
      if (kind === "signin") {
        if (!isEmail(v.email)) return bad("email", "Enter a valid email address.");
        if (!v.password) return bad("password", "Enter your password.");
        setBusy(btn, true, "Signing in…");
        const { error } = await supabase.auth.signInWithPassword({ email: v.email.trim(), password: v.password });
        if (error) throw error; // success is picked up by onAuthStateChange
      } else if (kind === "signup") {
        const name = v.display_name.trim();
        if (name.length < 1 || name.length > 60) return bad("display_name", "Use 1 to 60 characters.");
        if (!isEmail(v.email)) return bad("email", "Enter a valid email address.");
        const pw = passwordProblem(v.password);
        if (pw) return bad("password", pw);
        setBusy(btn, true, "Creating account…");
        const { data, error } = await supabase.auth.signUp({
          email: v.email.trim(),
          password: v.password,
          options: { data: { display_name: name }, emailRedirectTo: redirectUrl() },
        });
        if (error) throw error;
        if (!data.session) {
          renderAuth(root, { mode: "signin", notice: { type: "ok", text: "Account created. Check your inbox and confirm your email, then sign in." } });
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
      formMessage(form, "error", friendlyError(err));
    } finally {
      setBusy(btn, false);
    }
  });
}
