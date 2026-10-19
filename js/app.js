// SquadVault entry point: boot, session handling, app shell (sidebar / mobile nav), routes.
import { isConfigured } from "./config.js";
import { initSupabase, friendlyError, supabase } from "./supabase.js";
import { initAuth, renderAuth, signOut } from "./auth.js";
import { defineRoute, startRouter, stopRouter, refresh } from "./router.js";
import { state, setState, subscribe, chooseActiveGroup, setActiveGroup, resetState } from "./state.js";
import { fetchProfile, fetchGroups } from "./data.js";
import { $, $$, mount, on, icon, avatar, toast } from "./ui.js";
import { html, str } from "./utils.js";

const app = document.getElementById("app");
let sessionUid = null;   // guards against handling the same session twice (INITIAL_SESSION + getSession)
let inRecovery = false;  // password-recovery link flow
let pendingSession = null; // session to retry after a failed account load

/** Delegated listeners are bound once on #app, so re-rendering the shell never stacks handlers. */
function bindAppEvents() {
  on(app, "change", "[data-group-switch]", (_, sel) => {
    setActiveGroup(sel.value);
    refresh();
  });
  on(app, "click", "[data-signout]", () => signOut());
  on(app, "click", "[data-more]", openMoreSheet);
  on(app, "click", "[data-reload]", () => location.reload());
  on(app, "click", "[data-retry-boot]", () => { if (pendingSession) handleSession(pendingSession); });
}

const NAV = [
  ["dashboard", "Dashboard", "home"],
  ["groups", "My Groups", "users"],
  ["events", "Events", "calendar"],
  ["contributions", "Contributions", "wallet"],
  ["expenses", "Expenses", "receipt"],
  ["invitations", "Invitations", "ticket"],
  ["profile", "Profile", "user"],
  ["settings", "Settings", "settings"],
];
const BOTTOM = ["dashboard", "groups", "contributions", "events"];

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------
async function boot() {
  bindAppEvents();
  if (!isConfigured()) return renderSetup();
  try {
    await initSupabase();
  } catch (err) {
    return renderBootError(err);
  }

  defineRoutes();

  const session = await initAuth({
    onSession: handleSession,
    onRecovery: () => { inRecovery = true; teardownShell(); renderAuth(app, { mode: "recovery" }); },
    onSignedOut: ({ expired }) => {
      teardownShell();
      renderAuth(app, {
        mode: "signin",
        notice: expired ? { type: "warn", text: "Your session expired. Please sign in again." } : null,
      });
    },
  });
  window.addEventListener("sv:recovery-done", async () => {
    inRecovery = false;
    toast("Password updated. You're signed in.", "success");
    const { data } = await supabase.auth.getSession();
    if (data.session) handleSession(data.session); else renderAuth(app, { mode: "signin" });
  });

  if (session) handleSession(session);
  else if (!inRecovery) renderAuth(app, { mode: "signin" });
}

function renderSetup() {
  mount(app, html`<main class="card setup-card" id="main">
    <p class="eyebrow">One quick step</p>
    <h1 style="margin:8px 0 12px">Connect SquadVault to Supabase</h1>
    <p class="muted">Open <code>js/config.js</code> and paste your project's <strong>publishable key</strong>
    into <code>supabasePublishableKey</code>, then reload. You can find it in the Supabase dashboard under
    <em>Project Settings → API Keys</em>.</p>
    <p class="muted" style="margin-top:12px">Never paste a service-role key or secret key here. Only the publishable key belongs in the browser.</p>
    <p class="muted" style="margin-top:12px">Also run the SQL files in <code>supabase/migrations</code>, in order. The README walks through every step.</p>
  </main>`);
}

function renderBootError(err) {
  mount(app, html`<main class="card setup-card" id="main"><h1>Couldn't start SquadVault</h1>
    <p class="muted" style="margin:10px 0 16px">${friendlyError(err)}</p>
    <button class="btn primary" type="button" data-reload>${icon("refresh")} Reload</button></main>`);
}

async function handleSession(session) {
  if (inRecovery || !session?.user) return;
  const uid = session.user.id;
  if (sessionUid === uid) return;
  sessionUid = uid;

  setState({ user: { id: uid, email: session.user.email ?? "" } });
  mount(app, html`<div class="boot" role="status"><span class="spinner" aria-hidden="true"></span><span>Loading your squads…</span></div>`);
  try {
    const [profile, groups] = await Promise.all([fetchProfile(uid), fetchGroups(uid)]);
    setState({ profile, groups });
    chooseActiveGroup();
    renderShell();
  } catch (err) {
    console.error(err);
    sessionUid = null;
    mount(app, html`<main class="card setup-card" id="main"><h1>We couldn't load your account</h1>
      <p class="muted" style="margin:10px 0 16px">${friendlyError(err)}</p>
      <div class="actions"><button class="btn primary" type="button" data-retry-boot>${icon("refresh")} Try again</button>
      <button class="btn ghost" type="button" data-signout>Sign out</button></div></main>`);
    pendingSession = session;
  }
}

// ---------------------------------------------------------------------------
// Shell
// ---------------------------------------------------------------------------
let unsubscribe = null;

function teardownShell() {
  stopRouter();
  unsubscribe?.();
  unsubscribe = null;
  sessionUid = null;
  resetState();
}

const navLink = ([key, label, ic]) =>
  html`<a class="nav-link" href="#/${key}" data-nav="${key}">${icon(ic)}<span>${label}</span></a>`;

function groupSwitcher(id) {
  const groups = state.groups;
  return html`<div class="group-switch"><label for="${id}">Current group</label>
    <select class="select" id="${id}" data-group-switch ${groups.length ? "" : "disabled"} aria-label="Current group">
      ${groups.length
        ? groups.map((g) => html`<option value="${g.id}" ${g.id === state.activeGroupId ? "selected" : ""}>${g.name}</option>`)
        : html`<option>No groups yet</option>`}
    </select></div>`;
}

function renderShell() {
  mount(app, html`
  <div class="app-shell">
    <aside class="sidebar" aria-label="Primary">
      <div class="brand"><img src="assets/logo.svg" alt="SquadVault"></div>
      <div data-slot="switch-desktop">${groupSwitcher("gs-d")}</div>
      <nav class="nav" aria-label="Main navigation">${NAV.map(navLink)}</nav>
      <div class="side-foot">
        <div class="user-chip" data-slot="user">${userChip()}</div>
        <button class="btn ghost block" type="button" data-signout>${icon("logout")} Sign out</button>
      </div>
    </aside>
    <div class="content">
      <header class="topbar">
        <div class="brand"><img src="assets/logo.svg" alt="SquadVault"></div>
        <div data-slot="switch-mobile">${groupSwitcher("gs-m")}</div>
      </header>
      <main class="main" id="main" tabindex="-1"><div id="outlet" class="view"></div></main>
    </div>
    <nav class="bottom-nav" aria-label="Mobile navigation">
      ${NAV.filter(([k]) => BOTTOM.includes(k)).map(([k, label, ic]) => html`<a href="#/${k}" data-nav="${k}">${icon(ic)}<span>${label.replace("My ", "")}</span></a>`)}
      <button type="button" data-more aria-haspopup="dialog">${icon("more")}<span>More</span></button>
    </nav>
  </div>`);

  unsubscribe?.();
  unsubscribe = subscribe(() => {
    const d = $('[data-slot="switch-desktop"]'), m = $('[data-slot="switch-mobile"]'), u = $('[data-slot="user"]');
    if (d) mount(d, groupSwitcher("gs-d"));
    if (m) mount(m, groupSwitcher("gs-m"));
    if (u) mount(u, userChip());
  });

  startRouter($("#outlet"), { onRoute: markNav });
}

const userChip = () => html`${avatar(state.profile?.display_name, state.profile?.avatar_path)}
  <div class="meta"><div class="name">${state.profile?.display_name ?? "Member"}</div><div class="mail">${state.user?.email ?? ""}</div></div>`;

function markNav({ meta }) {
  $$("[data-nav]").forEach((a) => {
    if (a.dataset.nav === meta.nav) a.setAttribute("aria-current", "page");
    else a.removeAttribute("aria-current");
  });
  const more = $("[data-more]");
  if (more) {
    if (meta.nav && !BOTTOM.includes(meta.nav)) more.setAttribute("aria-current", "page");
    else more.removeAttribute("aria-current");
  }
  document.title = `${meta.title ?? "SquadVault"} · SquadVault`;
}

function openMoreSheet() {
  const backdrop = document.createElement("div");
  backdrop.className = "sheet-backdrop";
  backdrop.innerHTML = str(html`<div class="sheet" role="dialog" aria-modal="true" aria-label="More">
    <nav class="nav">${NAV.filter(([k]) => !BOTTOM.includes(k)).map(navLink)}
    <button class="nav-link" type="button" data-signout style="background:none;border:0;cursor:pointer;font:inherit">${icon("logout")}<span>Sign out</span></button></nav></div>`);
  document.body.appendChild(backdrop);
  const close = () => { backdrop.remove(); document.removeEventListener("keydown", onKey); };
  const onKey = (e) => { if (e.key === "Escape") close(); };
  document.addEventListener("keydown", onKey);
  backdrop.addEventListener("click", (e) => { if (e.target === backdrop || e.target.closest("a,[data-signout]")) close(); });
  on(backdrop, "click", "[data-signout]", () => signOut());
  backdrop.querySelector("a,button")?.focus();
}

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------
let routesDefined = false;
// Views are loaded on demand (dynamic import), so first paint only downloads the core modules.
const lazy = (file, fn) => async (ctx) => (await import(file))[fn](ctx);

function defineRoutes() {
  if (routesDefined) return;
  routesDefined = true;
  defineRoute("/dashboard", lazy("./dashboard.js", "renderDashboard"), { nav: "dashboard", title: "Dashboard" });
  defineRoute("/groups", lazy("./groups.js", "renderGroups"), { nav: "groups", title: "My Groups" });
  defineRoute("/groups/:id", lazy("./groups.js", "renderGroupDetail"), { nav: "groups", title: "Group" });
  defineRoute("/events", lazy("./events.js", "renderEvents"), { nav: "events", title: "Events" });
  defineRoute("/events/:id", lazy("./events.js", "renderEventDetail"), { nav: "events", title: "Event" });
  defineRoute("/contributions", lazy("./contributions.js", "renderContributions"), { nav: "contributions", title: "Contributions" });
  defineRoute("/expenses", lazy("./expenses.js", "renderExpenses"), { nav: "expenses", title: "Expenses" });
  defineRoute("/invitations", lazy("./invitations.js", "renderInvitations"), { nav: "invitations", title: "Invitations" });
  defineRoute("/profile", lazy("./profile.js", "renderProfile"), { nav: "profile", title: "Profile" });
  defineRoute("/settings", lazy("./profile.js", "renderSettings"), { nav: "settings", title: "Settings" });
}

boot();

// Repeat visits load from the local cache first (see sw.js). Skipped on file:// and unsupported browsers.
if ("serviceWorker" in navigator && (location.protocol === "https:" || location.hostname === "localhost")) {
  window.addEventListener("load", () => navigator.serviceWorker.register("sw.js").catch(() => {}));
}
