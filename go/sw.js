// PunchCard Go: keeps the app shell available on a weak shop Wi-Fi. Pages are network-first
// (always fresh when online); the API and wallets are never cached.
const CACHE = 'punchcard-go-v13';
const SHELL = ['/go/', '/site.css', '/launchpad/lp.js', '/brand/punchcard.svg', '/go/icon-192.png'];
self.addEventListener('install', (e) => { e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).catch(() => {})); self.skipWaiting(); });
self.addEventListener('activate', (e) => { e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k))))); self.clients.claim(); });
self.addEventListener('fetch', (e) => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== location.origin) return;
  // Always ask the server first (skipping the 10-minute browser cache), so an update shows on the next open.
  e.respondWith(fetch(e.request, { cache: 'no-cache' }).then((r) => { if (r.ok) { const copy = r.clone(); caches.open(CACHE).then((c) => c.put(e.request, copy)); } return r; })
    .catch(() => caches.match(e.request).then((m) => m || caches.match('/go/'))));
});
