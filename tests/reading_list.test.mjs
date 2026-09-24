import assert from 'node:assert/strict';
import { webcrypto } from 'node:crypto';
import { api, ConflictError } from '../web/js/api.js';
import { READING_LIST_KEY, emptyReadingList, validateReadingList, receiveReadingList, acknowledgeReadingList,
  moveReadingListItem, readReadingList, addToReadingList, retryReadingList, resolveReadingList } from '../web/js/reading-list.js';

const snap = (revision, items, operation = `remote-operation-${revision}`) => ({ revision, items, operation, updated: revision });
const local = (revision, items, operation = 'local-operation-1') => ({ ...snap(revision, items, operation), known: true, dirty: true });
assert.deepEqual(receiveReadingList(emptyReadingList(), snap(2, ['one'])).items, ['one']);
const pending = local(2, ['one', 'two']);
assert.deepEqual(receiveReadingList(pending, snap(2, ['one'])), pending, 'same-base refresh preserves pending order');
const conflict = receiveReadingList(pending, snap(3, ['three']));
assert.deepEqual(conflict.items, ['one', 'two']); assert.deepEqual(conflict.conflict.items, ['three']);
assert.equal(receiveReadingList(conflict, snap(2, ['one'])), conflict, 'stale response cannot downgrade the conflict preview');
assert.equal(receiveReadingList(pending, snap(3, pending.items, pending.operation)).dirty, false, 'GET reconciles an uncertain successful operation');
const sent = { expected_revision: 2, items: ['one'], operation: 'sent-operation-1' };
const editing = { ...local(2, ['one', 'two'], 'later-operation-2'), inflight: sent };
const acknowledged = acknowledgeReadingList(editing, sent, snap(3, ['one'], sent.operation));
assert.deepEqual(acknowledged.items, ['one', 'two']); assert.equal(acknowledged.revision, 3);
assert.equal(acknowledged.dirty, true); assert.equal(acknowledged.operation, editing.operation); assert.equal(acknowledged.inflight, undefined);
assert.deepEqual(receiveReadingList(editing, snap(3, ['one'], sent.operation)), acknowledged, 'refresh also recognizes the original pending receipt');
const newer = { ...local(8, ['newer'], 'newer-operation-8'), inflight: sent };
assert.equal(acknowledgeReadingList(newer, sent, snap(3, ['one'], sent.operation)).revision, 8, 'late acknowledgement never regresses revision');
assert.throws(() => acknowledgeReadingList(editing, sent, snap(3, ['wrong'], sent.operation)), /不一致/);
assert.deepEqual(moveReadingListItem(['one', 'two', 'three'], 'two', -1), ['two', 'one', 'three']);
assert.deepEqual(moveReadingListItem(['one', 'two'], 'one', -1), ['one', 'two']);
assert.throws(() => validateReadingList(snap(0, ['one', 'one'])), /无效/);
assert.throws(() => validateReadingList(snap(0, Array.from({ length: 201 }, (_, i) => `id${i}`))), /无效/);
assert.equal(validateReadingList(snap(0, ['x'.repeat(160)])).items[0].length, 160);

const original = { get: api.readingList, put: api.saveReadingList, navigator: Object.getOwnPropertyDescriptor(globalThis, 'navigator'),
  storage: globalThis.localStorage, dispatch: globalThis.dispatchEvent, customEvent: globalThis.CustomEvent };
const values = new Map(), locks = new Map();
let quota = false, requests = [], remote = snap(0, []);
const lockNames = [];
Object.defineProperty(globalThis, 'navigator', { configurable: true, value: { onLine: false, locks: { request(name, action) {
  lockNames.push(name); const next = (locks.get(name) || Promise.resolve()).catch(() => {}).then(action); locks.set(name, next); return next;
} } } });
globalThis.localStorage = { getItem: (key) => values.get(key) ?? null, setItem(key, value) { if (quota) throw new Error('quota'); values.set(key, value); } };
globalThis.dispatchEvent = () => true;
if (!globalThis.CustomEvent) globalThis.CustomEvent = class { constructor(type) { this.type = type; } };
if (!globalThis.crypto) globalThis.crypto = webcrypto;
const putState = (state) => values.set(READING_LIST_KEY, JSON.stringify(state));
const delay = (ms = 0) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(predicate, message) { for (let i = 0; i < 100; i++) { if (predicate()) return; await delay(5); } throw new Error(message || 'condition timed out'); }
function accept(payload) {
  requests.push(structuredClone(payload));
  if (remote.operation === payload.operation && JSON.stringify(remote.items) === JSON.stringify(payload.items)) return structuredClone(remote);
  if (payload.expected_revision !== remote.revision) throw new ConflictError('其他设备也修改了清单', { list: structuredClone(remote) });
  remote = snap(remote.revision + 1, [...payload.items], payload.operation); return structuredClone(remote);
}
api.readingList = async () => structuredClone(remote);
api.saveReadingList = async (payload) => accept(payload);
try {
  await addToReadingList('one');
  assert.equal(readReadingList().dirty, true); assert.deepEqual(readReadingList().items, ['one']);
  const durable = values.get(READING_LIST_KEY);
  quota = true; await assert.rejects(addToReadingList('two'), /尚未保存/); quota = false;
  assert.equal(values.get(READING_LIST_KEY), durable, 'quota failure must not claim success or replace durable order');
  navigator.onLine = true; await retryReadingList();
  assert.equal(readReadingList().dirty, false); assert.deepEqual(remote.items, ['one']);

  // A second local edit is made after the server request starts, before its acknowledgement.
  let release, entered = false;
  api.saveReadingList = async (payload) => { const result = accept(payload); if (!entered) { entered = true; await new Promise((resolve) => { release = resolve; }); } return result; };
  await addToReadingList('two'); await until(() => entered, 'first operation never started');
  const originalReceipt = readReadingList().inflight;
  await addToReadingList('three');
  assert.deepEqual(readReadingList().items, ['one', 'two', 'three']);
  assert.equal(readReadingList().inflight.operation, originalReceipt.operation, 'new edit retains the original request receipt');
  release(); await retryReadingList();
  assert.deepEqual(remote.items, ['one', 'two', 'three']); assert.equal(readReadingList().dirty, false);

  // The server committed, but the response was lost. A later edit and reload must
  // replay the original operation before submitting that later desired order.
  requests = []; remote = snap(0, []); putState({ ...remote, known: true, dirty: false });
  let loseFirst = true;
  api.saveReadingList = async (payload) => { const result = accept(payload); if (loseFirst) { loseFirst = false; throw new Error('connection lost after commit'); } return result; };
  await addToReadingList('one'); await retryReadingList().catch(() => {});
  const uncertain = readReadingList(); assert.equal(uncertain.dirty, true); assert.equal(uncertain.inflight.operation, requests[0].operation);
  navigator.onLine = false; await addToReadingList('two');
  const afterReload = JSON.parse(JSON.stringify(readReadingList())); putState(afterReload);
  navigator.onLine = true; await retryReadingList();
  assert.equal(requests[0].operation, requests[1].operation, 'uncertain request reuses its original operation ID');
  assert.deepEqual(requests[1].items, ['one']); assert.deepEqual(requests[2].items, ['one', 'two']);
  assert.notEqual(requests[2].operation, requests[1].operation); assert.equal(requests[2].expected_revision, 1);
  assert.equal(remote.revision, 2); assert.equal(readReadingList().dirty, false);

  // Definitively invalid content can be removed; an old rejected receipt must not block recovery.
  requests = []; remote = snap(0, []); putState({ ...remote, known: true, dirty: false });
  api.saveReadingList = async (payload) => {
    if (payload.items.includes('removed-book')) { requests.push(structuredClone(payload)); const e = new Error('书籍已经不在书架'); e.status = 400; throw e; }
    return accept(payload);
  };
  await addToReadingList('removed-book'); await retryReadingList().catch(() => {});
  assert.equal(readReadingList().inflight, undefined, 'definite validation rejection clears only its receipt');
  assert.equal(readReadingList().dirty, true, 'desired order is retained for user correction');
  const corrected = { ...readReadingList(), items: ['one'], operation: 'corrected-operation-1' }; putState(corrected);
  await retryReadingList(); assert.deepEqual(remote.items, ['one']); assert.equal(readReadingList().dirty, false);

  // A server-side edit must remain a visible, durable choice across reload.
  remote = snap(5, ['remote-book']); putState(local(4, ['local-book'])); api.saveReadingList = async (payload) => accept(payload);
  await retryReadingList(); assert.equal(readReadingList().conflict.revision, 5);
  const calls = requests.length; await retryReadingList(); assert.equal(requests.length, calls, 'no write is attempted while conflict awaits a decision');
  putState(JSON.parse(JSON.stringify(readReadingList()))); await resolveReadingList(false);
  assert.deepEqual(readReadingList().items, ['remote-book']); assert.equal(readReadingList().dirty, false);
  putState({ ...local(4, ['local-book']), conflict: remote }); await resolveReadingList(true); await retryReadingList();
  assert.deepEqual(remote.items, ['local-book']); assert.equal(remote.revision, 6);
  assert.ok(lockNames.includes('yedu-reading-list:storage')); assert.ok(lockNames.includes('yedu-reading-list:sync'));
  console.log('reading-list tests passed: durable offline edits, storage quota, local edits during request, original-operation retry after lost response/reload, rejected-receipt correction, CAS conflict choices, late-ack protection and Web Locks');
} finally {
  navigator.onLine = false;
  api.readingList = original.get; api.saveReadingList = original.put;
  if (original.navigator) Object.defineProperty(globalThis, 'navigator', original.navigator); else delete globalThis.navigator;
  globalThis.localStorage = original.storage; globalThis.dispatchEvent = original.dispatch;
  if (original.customEvent) globalThis.CustomEvent = original.customEvent;
}
