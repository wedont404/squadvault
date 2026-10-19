// Profile (display name, avatar) and Settings (security, payments info, sign out).
import { state, setState } from "./state.js";
import { supabase, rpc, AppError, friendlyError } from "./supabase.js";
import { signOut } from "./auth.js";
import { config } from "./config.js";
import { html, passwordProblem } from "./utils.js";
import {
  $, mount, on, icon, avatar, badge, toast, toastError, confirmDialog, setBusy, field, formData, formMessage, formMsgSlot,
  setFieldError, clearFieldErrors,
} from "./ui.js";

const AV_EXT = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" };

export async function renderProfile({ outlet }) {
  const p = state.profile;
  mount(outlet, html`<div class="page-head"><div><h1>Profile</h1><p class="sub">How your squad sees you.</p></div></div>
    <div class="grid cols-2" style="align-items:start">
      <form class="card form" novalidate data-profile>
        <div class="row">${avatar(p?.display_name, p?.avatar_path, true)}
          <div><div class="mail muted">${state.user.email}</div>
          <div class="row wrap" style="margin-top:6px;gap:6px">${state.groups.slice(0, 4).map((g) => badge(g.role, `${g.name} · ${g.role}`))}</div></div></div>
        ${field({ name: "display_name", label: "Display name", value: p?.display_name ?? "", attrs: 'maxlength="60"', autocomplete: "nickname" })}
        <div class="field" data-field="avatar"><label for="f-avatar">Avatar (optional)</label>
          <input class="input" id="f-avatar" name="avatar" type="file" accept="image/jpeg,image/png,image/webp">
          <div class="help">JPG, PNG or WebP, up to 1 MB. Visible to people in your groups.</div><div class="error" id="err-avatar" role="alert"></div></div>
        ${p?.avatar_path ? html`<label class="row" style="gap:8px"><input type="checkbox" name="clear"> <span class="muted">Remove current avatar</span></label>` : ""}
        ${formMsgSlot()}
        <button class="btn primary" type="submit">Save profile</button>
      </form>
    </div>`);

  const form = $("form[data-profile]", outlet);
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    clearFieldErrors(form);
    const v = formData(form);
    const name = v.display_name.trim();
    const file = $("#f-avatar", form).files[0];
    if (name.length < 1 || name.length > 60) return setFieldError(form, "display_name", "Use 1 to 60 characters.");
    if (file?.size && (!AV_EXT[file.type] || file.size > config.limits.avatarMaxBytes)) return setFieldError(form, "avatar", "Use a JPG, PNG or WebP image under 1 MB.");
    const btn = $('button[type="submit"]', form);
    setBusy(btn, true, "Saving…");
    try {
      let path = null;
      if (file?.size) {
        path = `${state.user.id}/${crypto.randomUUID()}.${AV_EXT[file.type]}`;
        const { error } = await supabase.storage.from("avatars").upload(path, file, { contentType: file.type, upsert: false });
        if (error) throw new AppError("The avatar couldn't be uploaded.", "upload_failed", error);
      }
      await rpc("update_profile", { p_display_name: name, p_avatar_path: path, p_clear_avatar: !!v.clear && !path });
      const avatar_path = path ?? (v.clear ? null : state.profile?.avatar_path ?? null);
      setState({ profile: { ...state.profile, display_name: name, avatar_path } });
      toast("Profile saved.", "success");
      renderProfile({ outlet });
    } catch (err) {
      formMessage(form, "error", friendlyError(err));
      setBusy(btn, false);
    }
  });
}

export async function renderSettings({ outlet }) {
  mount(outlet, html`<div class="page-head"><div><h1>Settings</h1><p class="sub">Security and app info.</p></div></div>
    <div class="grid cols-2" style="align-items:start">
      <form class="card form" novalidate data-password>
        <div><h3>Change password</h3><p class="muted" style="font-size:var(--fs-sm);margin-top:4px">Use at least 8 characters with a letter and a number.</p></div>
        ${field({ name: "password", label: "New password", type: "password", autocomplete: "new-password" })}
        ${field({ name: "confirm", label: "Confirm new password", type: "password", autocomplete: "new-password" })}
        ${formMsgSlot()}
        <button class="btn primary" type="submit">Update password</button>
      </form>
      <div class="stack">
        <div class="card stack"><h3>Sessions</h3>
          <p class="muted" style="font-size:var(--fs-sm)">Signed in as ${state.user.email}.</p>
          <div class="actions"><button class="btn" type="button" data-signout>${icon("logout")} Sign out</button>
          <button class="btn danger" type="button" data-signout-all>Sign out everywhere</button></div></div>
        <div class="card stack"><h3>About your money</h3>
          <p class="muted" style="font-size:var(--fs-sm)">${icon("shield")} Only payments confirmed by the payment provider count toward savings. Pending, failed and refunded amounts are never included. Everything is in whole ${config.currency}.</p>
          <p class="muted" style="font-size:var(--fs-sm)">If your project owner runs payments in <strong>simulated</strong> mode for testing, those payments are always labelled “Simulated” and no real money moves.</p></div>
      </div>
    </div>`);

  on(outlet, "click", "[data-signout]", () => signOut());
  on(outlet, "click", "[data-signout-all]", async () => {
    if (await confirmDialog({ title: "Sign out everywhere?", message: "This ends your session on every device, including this one.", confirmLabel: "Sign out everywhere", danger: true })) signOut({ everywhere: true });
  });
  const form = $("form[data-password]", outlet);
  form.addEventListener("submit", async (e) => {
    e.preventDefault();
    clearFieldErrors(form);
    const v = formData(form);
    const problem = passwordProblem(v.password);
    if (problem) return setFieldError(form, "password", problem);
    if (v.password !== v.confirm) return setFieldError(form, "confirm", "The passwords don't match.");
    const btn = $('button[type="submit"]', form);
    setBusy(btn, true, "Updating…");
    try {
      const { error } = await supabase.auth.updateUser({ password: v.password });
      if (error) throw error;
      form.reset();
      toast("Password updated.", "success");
    } catch (err) { toastError(err); }
    setBusy(btn, false);
  });
}
