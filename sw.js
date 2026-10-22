// Service worker: fast repeat loads and offline fallback. App files are network-first; the pinned CDN library is cache-first. Supabase API/auth/storage calls are NEVER
// cached or intercepted, so money data is always live.
const CACHE = "squadvault-v11";
const CDN = "https://cdn.jsdelivr.net/";

self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  const sameOrigin = url.origin === self.location.origin;
  if (!sameOrigin && !req.url.startsWith(CDN)) return; // Supabase & everything else: network only
  if (sameOrigin && /\/(sw\.js)$/.test(url.pathname)) return;

  // Our own files: network first (so an update can never mix old and new modules), cache only as the
  // offline fallback. The pinned CDN library never changes, so it is served from cache instantly.
  if (sameOrigin) {
    e.respondWith(
      fetch(req)
        .then((res) => { if (res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); } return res; })
        .catch(() => caches.match(req)),
    );
    return;
  }
  e.respondWith(
    caches.open(CACHE).then(async (cache) => {
      const cached = await cache.match(req);
      const network = fetch(req)
        .then((res) => { if (res.ok) { const copy = res.clone(); cache.put(req, copy); } return res; })
        .catch(() => cached);
      return cached || network;
    }),
  );
});
