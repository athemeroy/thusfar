// Shell releases and downloaded book snapshots have independent lifetimes.
const SHELL = 'yedu-shell-6a161c1f55d57b16a6de';
const VISITED = 'yedu-books-v1'; // Preserve books cached by older releases.
const META = 'yedu-offline-index-v1';
const INDEX = '/__yedu_offline_index__';
const SHELL_URLS = ['/', '/index.html', '/css/app.css', '/css/library.css', '/css/search.css', '/css/source-preview.css', '/css/reading-workspace.css', '/css/marginalia.css', '/manifest.webmanifest', '/icon-192.png', '/icon-512.png',
  '/css/workspace-nav.css', '/css/reading-list.css', '/css/notebook-hub.css', '/css/offline-library.css', '/css/model-settings.css',
  '/fonts/serif.css', '/fonts/kai.css', '/fonts/latin.css',
  ...['main','api','util','reader','readerview','marginalia','kg','shelf','panes','person','graph','views','text','progress','offline','library','search','notebook','manual','companion','source-preview','workspace-nav','reading-list','notebook-hub','offline-library','model-settings','runtime','i18n','i18n-catalogs'].map((n) => `/js/${n}.js`),
  ...['en','es','fr','de','pt-BR','ja','ko'].map((n) => `/js/locales/${n}.js`)];
const downloads = new Map();
const removing = new Set();
const bookEpoch = new Map();
const visitedWrites = new Map();
const validId = (id) => /^[A-Za-z0-9_-]+$/.test(id || '');
let indexQueue = Promise.resolve();
let shelfWrite = Promise.resolve();
let shelfEpoch = 0;
const json = (data, status = 200) => new Response(JSON.stringify(data), { status, headers: { 'Content-Type': 'application/json', 'X-Yedu-Offline': '1' } });
async function index() { return (await (await caches.open(META)).match(INDEX))?.json() || {}; }
function updateIndex(fn) {
  indexQueue = indexQueue.catch(() => {}).then(async () => { const data = await index(); await fn(data); await (await caches.open(META)).put(INDEX, json(data)); });
  return indexQueue;
}
async function boundedFetch(request, signal, ms = 15000) {
  const controller = new AbortController(); const abort = () => controller.abort();
  if (signal?.aborted) abort(); else signal?.addEventListener('abort', abort, { once: true });
  const timer = setTimeout(abort, ms);
  try { const response = await fetch(request, { signal: controller.signal, credentials: 'same-origin', cache: 'no-cache' }); const body = await response.arrayBuffer(); return new Response(body, { status: response.status, statusText: response.statusText, headers: response.headers }); }
  finally { clearTimeout(timer); signal?.removeEventListener('abort', abort); }
}
self.addEventListener('install', (e) => e.waitUntil((async () => {
  const c = await caches.open(SHELL); await c.addAll(SHELL_URLS); await self.skipWaiting();
})()));
self.addEventListener('activate', (e) => e.waitUntil((async () => {
  // Never delete book snapshots, legacy visited books, or another application's caches.
  for (const key of await caches.keys()) if (key.startsWith('yedu-shell-') && key !== SHELL) await caches.delete(key);
  await self.clients.claim();
})()));

async function offlineApi(request) {
  const url = new URL(request.url); const data = await index();
  const visited = await caches.open(VISITED);
  if (url.pathname === '/api/books') {
    const old = await visited.match('/api/books');
    const books = old ? await old.json() : [];
    const map = new Map(books.map((b) => [b.id, b]));
    // A direct link to a hidden comparison book must not put it on the visible shelf.
    for (const [id, entry] of Object.entries(data)) if (map.has(id)) map.set(id, { ...entry.book, offline: true });
    return json([...map.values()]);
  }
  const m = /^\/api\/books\/([A-Za-z0-9_-]+)(.*)$/.exec(url.pathname);
  if (!m) return json({ error: '这个功能需要网络连接' }, 503);
  const entry = data[m[1]], rest = m[2];
  if (entry) {
    const c = await caches.open(entry.cache);
    if (rest === '/kg') {
      const graphResponse = await c.match(entry.graph.url);
      if (!graphResponse) return json({ error: '离线人物资料不完整，请重新下载' }, 503);
      const graph = await graphResponse.json();
      const from = Number(url.searchParams.get('from') ?? -1), requested = Number(url.searchParams.get('to') ?? 0);
      if (!Number.isFinite(from) || !Number.isFinite(requested)) return json({ error: '无效资料范围' }, 400);
      const coverage = graph.state === 'done' ? graph.to : Math.min(graph.to, graph.frontier || 0);
      const to = Math.max(from, Math.min(requested, coverage));
      return json({ ...graph, from, to, before: graph.records.filter((r) => r.p <= from).length,
        records: graph.records.filter((r) => r.p > from && r.p <= to), incomplete: requested > coverage, offline: true, version: entry.version });
    }
    const hit = await c.match(url.pathname);
    if (hit && rest === '/notebook') {
      // Notebook data can change after the book was downloaded. A later online GET
      // lives in VISITED; combine per-item revisions so going offline cannot roll it back.
      const recent = await visited.match(request);
      if (recent) {
        try {
          const saved = await hit.clone().json(), fetched = await recent.json();
          if (Array.isArray(saved.items) && Array.isArray(fetched.items)) {
            const items = new Map(saved.items.map((item) => [item.id, item]));
            for (const item of fetched.items) {
              const old = items.get(item.id);
              if (!old || item.revision >= old.revision) items.set(item.id, item);
            }
            return json({ items: [...items.values()], offline: true });
          }
        } catch { /* retain the complete downloaded snapshot if a visited response is unreadable */ }
      }
    }
    if (hit) return hit;
  }
  // An exact visited response is safe. Different KG delta queries are not interchangeable.
  const exact = await visited.match(request); if (exact) return exact;
  return json({ error: '本机尚未下载这部分内容，请连接网络后下载本书' }, 503);
}

self.addEventListener('fetch', (e) => {
  const request = e.request, url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== self.location.origin) return;
  const bookResource = /^\/api\/books(?:$|\/[A-Za-z0-9_-]+(?:$|\/(?:chapters\/\d+|kg|notebook|img\/.+)$))/.test(url.pathname);
  if (url.pathname.startsWith('/api/')) {
    if (!bookResource) return;
    const bookId = /^\/api\/books\/([A-Za-z0-9_-]+)/.exec(url.pathname)?.[1];
    const epoch = bookEpoch.get(bookId) || 0;
    const cacheEligibleAtStart = !removing.has(bookId);
    const visibleEpoch = shelfEpoch;
    e.respondWith((async () => {
      try {
        const response = await boundedFetch(request, null, 7000);
        if (response.status >= 500) return offlineApi(request);
        if (response.ok) {
          const copy = response.clone(); let write;
          if (url.pathname === '/api/books') {
            write = shelfWrite.catch(() => {}).then(async () => {
              if (visibleEpoch === shelfEpoch) await (await caches.open(VISITED)).put(request, copy);
            });
            shelfWrite = write;
          } else {
            write = (visitedWrites.get(bookId) || Promise.resolve()).catch(() => {}).then(async () => {
              if (cacheEligibleAtStart && !removing.has(bookId) && epoch === (bookEpoch.get(bookId) || 0)) await (await caches.open(VISITED)).put(request, copy);
            });
            visitedWrites.set(bookId, write);
            const cleanup = () => { if (visitedWrites.get(bookId) === write) visitedWrites.delete(bookId); };
            write.then(cleanup, cleanup);
          }
          e.waitUntil(write);
          if (url.pathname === '/api/books') {
            const snapshot = await index(); const books = await response.json();
            return json(books.map((b) => ({ ...b, offline: !!snapshot[b.id] })));
          }
        }
        return response;
      } catch { return offlineApi(request); }
    })());
    return;
  }
  e.respondWith((async () => {
    const c = await caches.open(SHELL);
    // A release serves one coherent shell; a new worker installs a complete replacement.
    const hit = await c.match(request); if (hit) return hit;
    try {
      const response = await boundedFetch(request);
      if (response.ok) e.waitUntil(c.put(request, response.clone()));
      return response;
    } catch {
      if (request.mode === 'navigate') return (await c.match('/')) || (await c.match('/index.html')) || Response.error();
      // Preserve font assets populated by the previous worker.
      return (await caches.match(request)) || Response.error();
    }
  })());
});

async function download(id, requestId, port) {
  if (!validId(id)) throw new Error('无效书籍');
  if (removing.has(id)) throw new Error('正在移除本机副本，请稍后重试');
  if (typeof requestId !== 'string' || downloads.has(requestId)) throw new Error('下载任务标识重复，请重试');
  if ([...downloads.values()].some((x) => x.id === id)) throw new Error('这本书已有下载任务');
  const controller = new AbortController(); downloads.set(requestId, { controller, id });
  let pulse;
  try {
    const manifestUrl = `/api/books/${id}/offline-manifest`;
    const readManifest = async () => {
      const r = await boundedFetch(manifestUrl, controller.signal); if (!r.ok) throw new Error('无法取得离线清单，请联网后重试');
      const m = await r.json();
      if (!m.version || !m.book || !Array.isArray(m.chapters) || !m.graph?.url) throw new Error('离线清单格式不正确');
      return m;
    };
    const manifest = await readManifest();
    // On a first install the page's initial shelf request may predate worker control.
    // Verify visible membership from the server instead of advertising every deep-linked snapshot.
    if (!(await visibleShelf()).some((book) => book.id === id)) {
      const visibleEpoch = shelfEpoch;
      const response = await boundedFetch('/api/books', controller.signal);
      if (!response.ok) throw new Error('暂时无法核对书库，请联网后继续下载');
      const books = await response.json();
      if (!Array.isArray(books)) throw new Error('书库清单格式不正确');
      shelfWrite = shelfWrite.catch(() => {}).then(async () => {
        if (controller.signal.aborted) throw new Error('离线下载已暂停');
        if (visibleEpoch !== shelfEpoch) throw new Error('书库刚刚变化，请继续下载以重新核对');
        await (await caches.open(VISITED)).put('/api/books', json(books));
      });
      await shelfWrite;
    }
    const safeVersion = String(manifest.version).replace(/[^A-Za-z0-9_-]/g, '_');
    const cacheName = `yedu-book-${id}@${safeVersion}`; const cache = await caches.open(cacheName);
    const urls = [...new Set([...manifest.chapters.flatMap((c) => [c.url, ...(c.images || [])]), ...(manifest.assets || []), manifest.graph.url, ...(manifest.notebook?.url ? [manifest.notebook.url] : [])])];
    for (const path of urls) { const u = new URL(path, self.location.origin); if (u.origin !== self.location.origin || !u.pathname.startsWith(`/api/books/${id}/`)) throw new Error('离线清单包含无效地址'); }
    let n = 0; const total = urls.length + 1;
    pulse = setInterval(() => port?.postMessage({ n, total }), 5000);
    for (const url of urls) {
      if (controller.signal.aborted) throw new Error('离线下载已暂停');
      if (!(await cache.match(url))) {
        const response = await boundedFetch(url, controller.signal, 30000);
        if (!response.ok) throw new Error(`有内容未能下载（${response.status}），请点击重试`);
        await cache.put(url, response);
      }
      n++; Object.assign(downloads.get(requestId), { n, total });
      port?.postMessage({ n, total });
    }
    const graph = await (await cache.match(manifest.graph.url)).json();
    if (graph.from !== -1 || graph.to !== manifest.graph.to || !Array.isArray(graph.records)) throw new Error('人物资料范围不完整，请重试');
    const after = await readManifest();
    if (String(after.version) !== String(manifest.version)) throw new Error('资料正在更新，本次下载尚未完成，请稍后继续');
    if (controller.signal.aborted) throw new Error('离线下载已暂停');
    await cache.put(`/api/books/${id}`, json({ ...manifest.book, offline: true, version: manifest.book.version || manifest.version }));
    await updateIndex((data) => {
      if (controller.signal.aborted) throw new Error('离线下载已暂停');
      data[id] = { version: manifest.version, cache: cacheName, graph: manifest.graph, book: manifest.book,
        resources: [...urls, `/api/books/${id}`], verifiedAt: Date.now() };
    });
    port?.postMessage({ n: total, total, done: true });
    for (const key of await caches.keys()) if (key.startsWith(`yedu-book-${id}@`) && key !== cacheName) await caches.delete(key);
  } finally { clearInterval(pulse); downloads.delete(requestId); }
}

async function visibleShelf() {
  const response = await (await caches.open(VISITED)).match('/api/books');
  const books = response ? await response.json() : [];
  return Array.isArray(books) ? books.filter((book) => validId(book.id) && !book.hidden && !book.meta?.hidden) : [];
}

async function offlineInventory() {
  await Promise.all([indexQueue.catch(() => {}), shelfWrite.catch(() => {})]);
  const data = await index(), books = await visibleShelf(), keys = new Set(await caches.keys());
  const packages = [];
  for (const book of books) {
    const entry = data[book.id];
    const staged = [...keys].filter((key) => key.startsWith(`yedu-book-${book.id}@`) && key !== entry?.cache);
    if (!entry && !staged.length) continue;
    let available = false, missing = 0, resourceCount = 0;
    if (typeof entry?.cache === 'string' && entry.cache.startsWith(`yedu-book-${book.id}@`) && keys.has(entry.cache)) {
      const cache = await caches.open(entry.cache);
      const actual = new Set((await cache.keys()).map((request) => request.url));
      const expected = entry.resources || [`/api/books/${book.id}`, entry.graph?.url,
        ...(entry.book?.chapters || []).map((_c, n) => `/api/books/${book.id}/chapters/${n}`),
        ...(entry.book?.cover ? [`/api/books/${book.id}/img/${entry.book.cover}`] : [])];
      resourceCount = expected.length;
      missing = expected.filter((url) => !url || !actual.has(new URL(url, self.location.origin).href)).length;
      available = resourceCount > 0 && missing === 0;
    }
    packages.push({ id: book.id, title: book.title || entry?.book?.title || '未命名', author: book.author || entry?.book?.author || '',
      version: entry?.version || null, available, missing, resourceCount, partial: staged.length > 0,
      verification: entry?.resources ? 'full' : 'legacy', verifiedAt: entry?.verifiedAt || null });
  }
  const visible = new Set(books.map((book) => book.id));
  return { books: books.map(({ id, title, author }) => ({ id, title, author })), packages,
    downloads: [...downloads.values()].filter((job) => visible.has(job.id)).map(({ id, n, total }) => ({ id, n: n || 0, total: total || 0 })) };
}

async function removeLocalCopy(id, deleted = false) {
  if (!validId(id)) throw new Error('无效书籍');
  if (removing.has(id)) throw new Error('正在移除本机副本，请稍候');
  const active = [...downloads.values()].filter((job) => job.id === id);
  if (active.length && !deleted) throw new Error('这本书还有下载任务。请先暂停下载，等待结束后再移除本机副本。');
  removing.add(id); bookEpoch.set(id, (bookEpoch.get(id) || 0) + 1); shelfEpoch++;
  try {
    // Server deletion is different: cancel its obsolete jobs before removing all cached state.
    if (deleted) { for (const job of active) job.controller.abort(); await Promise.all(active.map((job) => job.done)); }
    // Drain puts that already passed their guard before enumerating/deleting visited resources.
    await visitedWrites.get(id)?.catch(() => {});
    const visited = await caches.open(VISITED), base = `/api/books/${id}`;
    const keys = (await caches.keys()).filter((key) => key.startsWith(`yedu-book-${id}@`));
    if (!deleted) {
      // A never-opened downloaded notebook is still personal data. Retain its latest revisions.
      const notebookUrl = base + '/notebook', saved = await visited.match(notebookUrl);
      const rows = saved ? (await saved.json()).items : [];
      if (!Array.isArray(rows)) throw new Error('摘记缓存无法核对，本机副本尚未移除');
      const notes = new Map(rows.map((row) => [row.id, row]));
      for (const key of keys) {
        const response = await (await caches.open(key)).match(notebookUrl);
        if (!response) continue;
        const items = (await response.json()).items;
        if (!Array.isArray(items)) throw new Error('摘记缓存无法核对，本机副本尚未移除');
        for (const item of items) if (!notes.has(item.id) || (item.revision || 0) > (notes.get(item.id).revision || 0)) notes.set(item.id, item);
      }
      if (notes.size || saved) await visited.put(notebookUrl, json({ items: [...notes.values()] }));
    }
    await updateIndex((data) => { delete data[id]; });
    for (const key of keys) await caches.delete(key);
    for (const request of await visited.keys()) {
      const path = new URL(request.url).pathname;
      if (path === base || path.startsWith(base + '/')) {
        if (!deleted && path === base + '/notebook') continue;
        await visited.delete(request);
      }
    }
    shelfWrite = shelfWrite.catch(() => {}).then(async () => {
      const shelf = await visited.match('/api/books');
      if (shelf) await visited.put('/api/books', json((await shelf.json()).filter((book) => !deleted || book.id !== id)
        .map((book) => book.id === id ? { ...book, offline: false } : book)));
    });
    await shelfWrite;
    return { removed: true, id, personalDataPreserved: !deleted };
  } finally { removing.delete(id); }
}

self.addEventListener('message', (e) => {
  const d = e.data || {}, port = e.ports[0];
  if (d.type === 'cancel-download') { downloads.get(d.requestId)?.controller.abort(); return; }
  if (d.type === 'download-book') {
    const existing = downloads.get(d.requestId);
    const task = download(d.id, d.requestId, port).catch((error) => port?.postMessage({ error: error.message || '下载失败，请重试' }));
    const job = downloads.get(d.requestId); if (job && !existing) job.done = task;
    e.waitUntil(task);
  }
  if (d.type === 'offline-inventory') e.waitUntil(offlineInventory().then((data) => port?.postMessage(data)).catch((error) => port?.postMessage({ error: error.message || '无法读取本机下载' })));
  if (d.type === 'remove-offline-copy' || d.type === 'remove-book') e.waitUntil(removeLocalCopy(d.id, d.type === 'remove-book')
    .then((data) => port?.postMessage(data)).catch((error) => port?.postMessage({ error: error.message || '本机副本未能移除' })));
});
