import assert from 'node:assert/strict';
import { api } from '../web/js/api.js';

let started = 0;
const calls = [];
Object.defineProperty(globalThis, 'navigator', { value: { userAgent: 'YeduStandalone/1' }, configurable: true });
globalThis.window = { YeduApp: { processingStarted() { started++; } } };
globalThis.fetch = async (url, options) => {
  calls.push([options.method, url]);
  if (options.method === 'POST') return new Response('', { status: 503 });
  return Response.json({ status: { state: 'running', done: 1, total: 20 } });
};
const accepted = await api.process('same-book');
assert.equal(accepted.reconciled, true);
assert.equal(started, 1, 'an accepted job starts the Android foreground service');
assert.deepEqual(calls, [['POST', '/api/books/same-book/process'], ['GET', '/api/books/same-book']]);

globalThis.fetch = async (url, options) => options.method === 'POST'
  ? new Response('', { status: 503 }) : Response.json({ status: { state: 'idle' } });
await assert.rejects(api.process('other-book'), /服务器返回了无法识别的数据/);
assert.equal(started, 1, 'an idle job must not start the service');
console.log('process response reconciliation passed');
