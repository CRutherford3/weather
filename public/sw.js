// Minimal service worker: caches the app shell so it opens instantly and works as an installed app.
// Weather data is never cached here, so forecasts are always live.
const CACHE = 'updraft-shell-v14';
const SHELL = ['/', '/index.html', '/css/app.css', '/js/app.js', '/js/config.js', '/js/util.js', '/js/api.js', '/js/map.js', '/js/forecast.js', '/js/dashboard.js', '/icons/icon.svg', '/manifest.webmanifest'];

self.addEventListener('install', (e) => { e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener('activate', (e) => { e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (e.request.method !== 'GET' || url.origin !== location.origin || url.pathname.startsWith('/api/')) return;
  // Network first so updates show right away; fall back to cache when offline
  e.respondWith(fetch(e.request, { cache: 'no-cache' }).then((r) => { const copy = r.clone(); caches.open(CACHE).then((c) => c.put(e.request, copy)); return r; }).catch(() => caches.match(e.request).then((r) => r || caches.match('/index.html'))));
});
