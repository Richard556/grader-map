// Sverdrup Township Road Tracker — offline support
// Bump APP_VERSION whenever index.html or the road file changes in a way
// phones should pick up even if they're mostly offline.
const APP_VERSION = '2026-10-11.2';
const SHELL_CACHE = 'shell-' + APP_VERSION;
const TILE_CACHE = 'tiles-v1';           // kept across versions
const MAX_TILES = 2500;                  // ~ a few dozen MB of satellite imagery

const SHELL = [
  './',
  './index.html',
  './sverdrup_roads.geojson',
  './manifest.webmanifest',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/apple-touch-icon.png',
  './icons/favicon-32.png'
];
const LIBS = [
  'https://unpkg.com/leaflet@1.9.4/dist/leaflet.css',
  'https://unpkg.com/leaflet@1.9.4/dist/leaflet.js',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2'
];

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(SHELL_CACHE);
    await cache.addAll(SHELL);
    // Libraries come from other sites; don't fail the install if one is slow
    await Promise.all(LIBS.map(url =>
      fetch(url, { mode: 'cors' }).then(res => res.ok && cache.put(url, res)).catch(() => {})));
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k.startsWith('shell-') && k !== SHELL_CACHE).map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});

self.addEventListener('message', event => {
  if (event.data === 'SKIP_WAITING') self.skipWaiting();
});

function isTile(url) {
  return url.hostname === 'server.arcgisonline.com' && url.pathname.includes('/tile/');
}
function isLib(url) {
  return LIBS.some(l => url.href.startsWith(l.split('?')[0])) ||
    url.hostname === 'unpkg.com' || url.hostname === 'cdn.jsdelivr.net';
}
function isAppFile(url) {
  return url.origin === self.location.origin;
}

// Page + road file: try the network first (so updates show up), fall back
// to the saved copy when there's no signal.
async function networkFirst(request) {
  const cache = await caches.open(SHELL_CACHE);
  try {
    const res = await Promise.race([
      fetch(request),
      new Promise((_, reject) => setTimeout(() => reject(new Error('timeout')), 6000))
    ]);
    if (res && res.ok) cache.put(request, res.clone());
    return res;
  } catch (e) {
    const cached = await cache.match(request, { ignoreSearch: true }) ||
      (request.mode === 'navigate' ? await cache.match('./index.html') : null);
    if (cached) return cached;
    throw e;
  }
}

// Libraries: use the saved copy right away, refresh it in the background
async function staleWhileRevalidate(request) {
  const cache = await caches.open(SHELL_CACHE);
  const cached = await cache.match(request);
  const refresh = fetch(request).then(res => {
    if (res && res.ok) cache.put(request, res.clone());
    return res;
  }).catch(() => cached);
  return cached || refresh;
}

// Satellite tiles: saved copy first; keep the cache from growing forever
let tileWrites = 0;
async function tileCacheFirst(request) {
  const cache = await caches.open(TILE_CACHE);
  const cached = await cache.match(request);
  if (cached) return cached;
  try {
    const res = await fetch(request);
    // Only CORS (non-opaque) tiles: opaque ones are counted as ~7 MB each by browsers
    if (res && res.ok) {
      await cache.put(request, res.clone());
      if (++tileWrites % 50 === 0) trimTiles(cache);
    }
    return res;
  } catch (e) {
    return new Response('', { status: 504 });
  }
}
async function trimTiles(cache) {
  const keys = await cache.keys();
  const extra = keys.length - MAX_TILES;
  for (let i = 0; i < extra; i++) await cache.delete(keys[i]);  // oldest first
}

self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  // Never cache live data (Supabase database, realtime, photo uploads)
  if (url.hostname.endsWith('.supabase.co')) return;

  if (isTile(url)) { event.respondWith(tileCacheFirst(req)); return; }
  if (isLib(url)) { event.respondWith(staleWhileRevalidate(req)); return; }
  if (isAppFile(url)) {
    if (req.mode === 'navigate' || url.pathname.endsWith('.html') || url.pathname.endsWith('.geojson') || url.pathname.endsWith('/')) {
      event.respondWith(networkFirst(req));
    } else {
      event.respondWith(staleWhileRevalidate(req));
    }
  }
});
