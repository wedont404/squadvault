// Service worker: instant repeat loads. Static app files are served from cache immediately and
// refreshed in the background (stale-while-revalidate). Supabase API/auth/storage calls are NEVER
// cached or intercepted, so money data is always live.
const CACHE = "squadvault-v2";
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

  e.respondWith(
    caches.open(CACHE).then(async (cache) => {
      const cached = await cache.match(req);
      const network = fetch(req)
        .then((res) => { if (res.ok) cache.put(req, res.clone()); return res; })
        .catch(() => cached);
      return cached || network;
    }),
  );
});
