// Offline support: the whole game is cached on first visit, served from the cache afterwards,
// and refreshed in the background whenever the network is there.
// Bump VERSION when a file is added or removed.
const VERSION = 'warcamp-v3';
const ASSETS = [
  './', 'index.html', 'manifest.webmanifest', 'css/style.css',
  'js/main.js', 'js/data.js', 'js/sim.js', 'js/ai.js', 'js/render.js', 'js/net.js',
  'vendor/peerjs.min.js', 'icons/icon.svg', 'icons/icon-192.png', 'icons/apple-touch-icon.png', 'icons/icon-512.png', 'icons/icon-maskable-512.png',
];
self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(ASSETS)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== VERSION).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;
  e.respondWith(caches.open(VERSION).then(async cache => {
    const hit = await cache.match(e.request, { ignoreSearch: true });
    const fresh = fetch(e.request).then(r => { if (r.ok) cache.put(e.request, r.clone()); return r; }).catch(() => hit);
    return hit || fresh;
  }));
});
