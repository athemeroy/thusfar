'use strict';

// prepare_offline.py replaces this marker in the built copy after Flutter
// emits main.dart.js and its assets. Cache names include the deployment path
// so another app on the same origin is never touched.
const BUILD_ID = 'unprepared';
const SCOPE = new URL(self.registration.scope);
const CACHE_PREFIX = `thusfar-app-shell:${encodeURIComponent(SCOPE.pathname)}:`;
const CACHE_NAME = `${CACHE_PREFIX}${BUILD_ID}`;

// The reader can start with these files when the server is unreachable.
// Other bundled fonts and assets are cached as they are used while online.
const CORE_PATHS = [
  'index.html',
  'flutter_bootstrap.js',
  'flutter.js',
  'main.dart.js',
  'manifest.json',
  'favicon.png',
  'icons/Icon-128.png',
  'icons/Icon-512.png',
  'assets/AssetManifest.bin',
  'assets/AssetManifest.bin.json',
  'assets/FontManifest.json',
  'assets/fonts/MaterialIcons-Regular.otf',
  'assets/assets/fonts/NotoSerifSC-Regular.otf',
  'assets/assets/fonts/ZCOOLXiaoWei-Regular.ttf',
  'assets/shaders/stretch_effect.frag',
  'assets/shaders/ink_sparkle.frag',
  'canvaskit/canvaskit.js',
  'canvaskit/canvaskit.wasm',
  'canvaskit/chromium/canvaskit.js',
  'canvaskit/chromium/canvaskit.wasm',
];

function scopeUrl(path) {
  return new URL(path, SCOPE).href;
}

function publicPath(request) {
  if (request.method !== 'GET' || request.headers.has('authorization')) {
    return null;
  }
  const url = new URL(request.url);
  if (url.origin !== SCOPE.origin || !url.pathname.startsWith(SCOPE.pathname)) {
    return null;
  }
  // Never put a credential-bearing or other dynamic query in Cache Storage.
  for (const key of url.searchParams.keys()) {
    if (key !== 'v' && key !== 'version') return null;
  }
  const path = url.pathname.slice(SCOPE.pathname.length);
  if (request.mode === 'navigate') {
    return path === '' || path === 'index.html' ? 'index.html' : null;
  }
  if (CORE_PATHS.includes(path) ||
      path.startsWith('assets/') ||
      path.startsWith('canvaskit/') ||
      path.startsWith('icons/')) {
    return path;
  }
  return null;
}

function mayCache(response) {
  if (!response.ok || response.type !== 'basic') return false;
  if (new URL(response.url).origin !== SCOPE.origin) return false;
  return !/(?:^|,)\s*(?:private|no-store)\b/i.test(
    response.headers.get('cache-control') || '',
  );
}

self.addEventListener('install', (event) => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE_NAME);
    try {
      await cache.addAll(CORE_PATHS.map((path) => new Request(scopeUrl(path), {
        cache: 'reload',
      })));
    } catch (error) {
      await caches.delete(CACHE_NAME);
      throw error;
    }
    await self.skipWaiting();
  })());
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names.filter((name) =>
      name.startsWith(CACHE_PREFIX) && name !== CACHE_NAME,
    ).map((name) => caches.delete(name)));
    await self.clients.claim();
  })());
});

self.addEventListener('fetch', (event) => {
  const path = publicPath(event.request);
  if (path === null) return;

  event.respondWith((async () => {
    const cache = await caches.open(CACHE_NAME);
    const key = scopeUrl(path);
    try {
      const response = await fetch(event.request, {
        cache: path === 'index.html' || path === 'flutter_bootstrap.js' ||
            path === 'flutter.js'
          ? 'reload'
          : 'no-cache',
      });
      if (mayCache(response)) {
        event.waitUntil(cache.put(key, response.clone()).catch(() => {}));
        return response;
      }
      return await cache.match(key) || response;
    } catch (_) {
      return await cache.match(key) || Response.error();
    }
  })());
});
