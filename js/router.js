// Minimal hash router: "#/events/123?tab=x". Hash routing works on any static host with no rewrite
// rules. Each handler receives a context with a stale-render guard so slow requests from a page the
// person already left can never paint over the current one.
const routes = [];
let outletEl = null;
let token = 0;
let onChange = () => {};

export function defineRoute(pattern, handler, meta = {}) {
  const keys = [];
  const re = new RegExp(
    "^" + pattern.replace(/\/:([A-Za-z]+)/g, (_, k) => { keys.push(k); return "/([^/]+)"; }) + "/?$",
  );
  routes.push({ pattern, re, keys, handler, meta });
}

export function parseHash(hash = location.hash) {
  const raw = hash.replace(/^#/, "") || "/";
  const [path, qs = ""] = raw.split("?");
  const query = Object.fromEntries(new URLSearchParams(qs));
  return { path: path.startsWith("/") ? path : `/${path}`, query };
}

export function navigate(path, { replace = false } = {}) {
  const target = `#${path}`;
  if (location.hash === target) return resolve();
  if (replace) location.replace(target);
  else location.hash = target;
}

export function startRouter(outlet, { onRoute } = {}) {
  outletEl = outlet;
  onChange = onRoute ?? (() => {});
  window.removeEventListener("hashchange", resolve);
  window.addEventListener("hashchange", resolve);
  resolve();
}

export function stopRouter() {
  window.removeEventListener("hashchange", resolve);
  token++;
}

export function refresh() {
  resolve();
}

async function resolve() {
  if (!outletEl) return;
  const { path, query } = parseHash();
  const my = ++token;
  for (const r of routes) {
    const m = path.match(r.re);
    if (!m) continue;
    const params = Object.fromEntries(r.keys.map((k, i) => [k, decodeURIComponent(m[i + 1])]));
    onChange({ path, pattern: r.pattern, meta: r.meta, params, query });
    outletEl.scrollTo?.(0, 0);
    window.scrollTo(0, 0);
    // Every navigation gets a brand-new container, so event listeners bound by a view are
    // discarded with it and can never stack up or leak into the next page.
    const host = document.createElement("div");
    outletEl.replaceChildren(host);
    try {
      await r.handler({ outlet: host, params, query, path, isCurrent: () => my === token });
    } catch (err) {
      if (my !== token) return;
      console.error(err);
      outletEl.innerHTML = '<div class="error-state"><div>This page hit a problem.</div><a class="btn" href="#/dashboard">Back to dashboard</a></div>';
    }
    return;
  }
  navigate("/dashboard", { replace: true });
}
