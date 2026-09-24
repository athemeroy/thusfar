import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const origin = 'https://fixture.test';
const urlOf = (value) => new URL(typeof value === 'string' ? value : value.url, origin).href;
const cachesByName = new Map(), control = { version: 'v1', failGraph: false, hook: null, fetchHook: null };
const json = (value, status = 200) => new Response(JSON.stringify(value), { status, headers: { 'Content-Type': 'application/json' } });
class Cache {
  constructor(name) { this.name = name; this.entries = new Map(); }
  async match(request) { return this.entries.get(urlOf(request))?.clone(); }
  async put(request, response) {
    const url = urlOf(request);
    await control.hook?.(this.name, url);
    this.entries.set(url, response.clone());
  }
  async keys() { return [...this.entries.keys()].map((url) => new Request(url)); }
  async delete(request) { return this.entries.delete(urlOf(request)); }
  async addAll() {}
}
const caches = {
  async open(name) { if (!cachesByName.has(name)) cachesByName.set(name, new Cache(name)); return cachesByName.get(name); },
  async keys() { return [...cachesByName.keys()]; },
  async delete(name) { return cachesByName.delete(name); },
};
const books = [{ id: 'a', title: '保留的书', author: '作者甲' }, { id: 'b', title: '另一本书' }];
const listeners = new Map();
const context = vm.createContext({ URL, Request, Response, AbortController, setTimeout, clearTimeout, setInterval, clearInterval,
  caches, console, self: { location: { origin }, addEventListener: (name, fn) => listeners.set(name, fn), skipWaiting: async () => {}, clients: { claim: async () => {} } },
  fetch: async (request, options) => {
    const url = new URL(urlOf(request));
    const held = control.fetchHook?.(url.pathname, options?.signal); if (held) return held;
    if (url.pathname === '/api/books') return json(books);
    const id = /^\/api\/books\/([^/]+)/.exec(url.pathname)?.[1];
    if (url.pathname.endsWith('/offline-manifest')) return json({ version: control.version,
      book: { id, title: id === 'hidden' ? 'HIDDEN_COMPARISON' : '保留的书', len: 100, version: 'source-v1', chapters: [{ o0: 0, o1: 100 }] },
      chapters: [{ url: `/api/books/${id}/chapters/0` }], assets: [], notebook: { url: `/api/books/${id}/notebook` }, graph: { url: `/api/books/${id}/kg?from=-1&to=100`, to: 100 } });
    if (url.pathname.endsWith('/kg')) return control.failGraph ? json({ error: 'fixture' }, 503) : json({ from: -1, to: 100, records: [], state: 'done' });
    if (url.pathname.endsWith('/notebook')) return json({ items: [{ id: 'note', revision: 9, text: '新版个人摘记' }] });
    return json({ n: 0, blocks: [{ o: 0, t: '原文' }] });
  },
});
vm.runInContext(fs.readFileSync(new URL('../web/sw.js', import.meta.url), 'utf8'), context);
const call = (code) => vm.runInContext(code, context);
const visited = await caches.open('yedu-books-v1');
// First installation: initial API request ran before worker control, so no visited shelf exists yet.

function message(data) {
  const values = []; let task = Promise.resolve();
  listeners.get('message')({ data, ports: [{ postMessage: (value) => values.push(value) }], waitUntil: (promise) => { task = promise; } });
  return { values, task };
}
async function fetchEvent(path) {
  let response; const writes = [];
  listeners.get('fetch')({ request: new Request(origin + path), respondWith: (promise) => { response = promise; }, waitUntil: (promise) => writes.push(promise) });
  return { response: await response, writes };
}
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
async function until(fn) { for (let n = 0; n < 100; n++) { if (fn()) return; await tick(); } throw new Error('fixture checkpoint not reached'); }

let task = message({ type: 'download-book', id: 'a', requestId: 'one' }); await task.task;
assert(task.values.some((value) => value.done));
let inventory = await call('offlineInventory()');
assert.equal(inventory.packages[0].available, true);
assert.equal(inventory.packages[0].verification, 'full');
assert.equal(inventory.packages[0].version, 'v1');
context.notebookRequest = new Request(origin + '/api/books/a/notebook');
await visited.put('/api/books/a/notebook', json({ items: [{ id: 'note', revision: 11, text: '联网后更新的摘记' },
  { id: 'later', revision: 1, text: '后来新增的摘记' }] }));
let offlineNotes = await (await call('offlineApi(notebookRequest)')).json();
assert.deepEqual(offlineNotes.items.map((item) => [item.id, item.revision]), [['note', 11], ['later', 1]],
  'offline reading retains notes fetched after the original book download');
await visited.put('/api/books/a/notebook', json({ items: [{ id: 'note', revision: 8, text: '较旧的已访问副本' }] }));
offlineNotes = await (await call('offlineApi(notebookRequest)')).json();
assert.equal(offlineNotes.items[0].revision, 9, 'an older visited response cannot replace the downloaded note');
task = message({ type: 'download-book', id: 'hidden', requestId: 'hidden-one' }); await task.task;
assert(!(await call('offlineInventory()')).packages.some((entry) => entry.id === 'hidden'));
context.shelfRequest = new Request(origin + '/api/books');
assert(!(await (await call('offlineApi(shelfRequest)')).json()).some((entry) => entry.id === 'hidden'));

control.version = 'v2'; control.failGraph = true;
task = message({ type: 'download-book', id: 'a', requestId: 'failed-update' }); await task.task;
assert(task.values.some((value) => value.error));
inventory = await call('offlineInventory()');
assert.equal(inventory.packages[0].version, 'v1');
assert.equal(inventory.packages[0].available, true);
assert.equal(inventory.packages[0].partial, true);
control.failGraph = false;

control.version = 'v3'; let fetchStarted = false;
control.fetchHook = (path, signal) => path.endsWith('/chapters/0') ? new Promise((resolve, reject) => {
  fetchStarted = true; signal.addEventListener('abort', () => reject(new Error('aborted')), { once: true });
}) : null;
task = message({ type: 'download-book', id: 'a', requestId: 'active-update' });
await until(() => fetchStarted);
let blocked = message({ type: 'remove-offline-copy', id: 'a' }); await blocked.task;
assert(blocked.values[0].error.includes('下载任务'));
message({ type: 'cancel-download', requestId: 'active-update' }); await task.task;
control.fetchHook = null;
assert.equal((await call('offlineInventory()')).packages[0].version, 'v1');

// A VISITED put already passed its epoch guard. Removal must await it, then preserve its newer notebook.
let releasePut, putStarted = false;
control.hook = (name, url) => name === 'yedu-books-v1' && url.endsWith('/notebook') ? new Promise((resolve) => { putStarted = true; releasePut = resolve; }) : undefined;
const pendingNotes = await fetchEvent('/api/books/a/notebook');
await until(() => putStarted);
let removed = false;
task = message({ type: 'remove-offline-copy', id: 'a' }); task.task.then(() => { removed = true; });
await tick(); assert.equal(removed, false, 'removal must drain an in-flight notebook cache put');
blocked = message({ type: 'download-book', id: 'a', requestId: 'during-removal' }); await blocked.task;
assert(blocked.values[0].error.includes('移除'));
control.hook = null; releasePut(); await Promise.all(pendingNotes.writes); await task.task;
assert.equal(task.values[0].personalDataPreserved, true);
assert.equal((await (await visited.match('/api/books/a/notebook')).json()).items[0].revision, 9);
assert(!(await caches.keys()).some((key) => key.startsWith('yedu-book-a@')));
assert((await (await visited.match('/api/books')).json()).some((book) => book.id === 'a'));
assert((await caches.keys()).some((key) => key.startsWith('yedu-book-hidden@')), 'exact book boundary preserves another book');

// Already-started content writes also cannot reappear after removal finishes.
putStarted = false;
control.hook = (name, url) => name === 'yedu-books-v1' && url.endsWith('/chapters/0') ? new Promise((resolve) => { putStarted = true; releasePut = resolve; }) : undefined;
const pendingChapter = await fetchEvent('/api/books/a/chapters/0');
await until(() => putStarted);
task = message({ type: 'remove-offline-copy', id: 'a' });
control.hook = null; releasePut(); await Promise.all(pendingChapter.writes); await task.task;
assert.equal(await visited.match('/api/books/a/chapters/0'), undefined);

// A read starts while removal is locked, but its network result arrives after removal.
// It shares the new epoch; eligibility must also be captured at request start.
putStarted = false;
control.hook = (name, url) => name === 'yedu-books-v1' && url.endsWith('/chapters/0') ? new Promise((resolve) => { putStarted = true; releasePut = resolve; }) : undefined;
const beforeRemoval = await fetchEvent('/api/books/a/chapters/0'); await until(() => putStarted);
task = message({ type: 'remove-offline-copy', id: 'a' });
let releaseDuring, duringStarted = false;
control.fetchHook = (path) => path.endsWith('/chapters/0') ? new Promise((resolve) => { duringStarted = true; releaseDuring = () => resolve(json({ blocks: [{ t: 'late content' }] })); }) : null;
const duringRemoval = fetchEvent('/api/books/a/chapters/0?during=1'); await until(() => duringStarted);
control.hook = null; releasePut(); await Promise.all(beforeRemoval.writes); await task.task;
releaseDuring(); const during = await duringRemoval; await Promise.all(during.writes); control.fetchHook = null;
assert.equal(await visited.match('/api/books/a/chapters/0?during=1'), undefined);

// An older network shelf response arrives after book deletion; it cannot resurrect cached metadata.
let releaseShelf, shelfStarted = false;
control.fetchHook = (path) => path === '/api/books' ? new Promise((resolve) => { shelfStarted = true; releaseShelf = () => resolve(json(books)); }) : null;
const oldShelf = fetchEvent('/api/books'); await until(() => shelfStarted);
task = message({ type: 'remove-book', id: 'a' }); await task.task;
releaseShelf(); const delivered = await oldShelf; await Promise.all(delivered.writes); control.fetchHook = null;
assert(!(await (await visited.match('/api/books')).json()).some((book) => book.id === 'a'));
assert.equal(await visited.match('/api/books/a/notebook'), undefined, 'actual book deletion keeps its distinct cache cleanup behavior');

console.log('offline worker checks passed: actual inventory, hidden membership, atomic failed update, cancellation, exclusion, personal data preservation and late-write races');
