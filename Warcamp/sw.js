// Offline support. Each release is downloaded whole into its own cache, and its scripts and styles have
// addresses that carry the release's version (file.js?v=VERSION), so the page never runs a mix of old and new.
// tools/stamp.sh sets VERSION and the addresses when the site is published.
const VERSION = 'dev';
const CACHE = 'warcamp-' + VERSION;
const V = VERSION === 'dev' ? '' : '?v=' + VERSION;
const ASSETS = [
  './', 'index.html', 'manifest.webmanifest',
  'icons/icon.svg', 'icons/icon-192.png', 'icons/apple-touch-icon.png', 'icons/icon-512.png', 'icons/icon-maskable-512.png',
  ...['css/style.css', 'js/main.js', 'js/data.js', 'js/sim.js', 'js/ai.js', 'js/render.js', 'js/net.js', 'lib/peerjs.min.js'].map(u => u + V),
];
self.addEventListener('install', e => {
  // cache: 'reload' goes to the server, never to a copy the browser kept from an earlier release.
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS.map(u => new Request(u, { cache: 'reload' })))).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin) return;
  e.respondWith(caches.open(CACHE).then(async c => {
    if (e.request.mode === 'navigate') return (await c.match('./')) || fetch(e.request);
    // A request that names a version gets exactly that version: from this cache if it is ours, else from the server.
    return (await c.match(e.request, { ignoreSearch: !url.search })) || fetch(e.request);
  }));
});
