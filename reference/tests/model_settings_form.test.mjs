import assert from 'node:assert/strict';

// A minimal DOM seam keeps this test offline and focused on controller behavior.
// Full layout and pointer interaction remain browser-executor acceptance.
class Node {
  constructor(tag = '#text', text = '') { this.tag = tag; this.children = []; this.attributes = {}; this.events = {}; this.textContent = text; this.value = ''; this.checked = false; this.disabled = false; this.style = {}; }
  setAttribute(key, value) { this.attributes[key] = String(value); }
  append(...kids) { for (const kid of kids) { kid.parent = this; this.children.push(kid); } }
  replaceChildren(...kids) { this.children = []; this.append(...kids); }
  remove() { this.parent.children = this.parent.children.filter((kid) => kid !== this); }
  addEventListener(name, handler) { (this.events[name] ||= []).push(handler); }
  reportValidity() { return true; }
  async trigger(name) { for (const handler of this.events[name] || []) await handler({ preventDefault() {} }); }
}
const toast = new Node('div');
let capability = true;
globalThis.Node = Node;
globalThis.document = {
  createElement: (tag) => new Node(tag), createElementNS: (_, tag) => new Node(tag),
  createTextNode: (text) => new Node('#text', text), getElementById: () => toast,
  querySelector: () => capability ? { content: 'true' } : null, documentElement: {},
};
Object.defineProperty(globalThis, 'navigator', { value: { userAgent: 'Ordinary desktop browser', language: 'zh-CN', onLine: false }, configurable: true });
globalThis.localStorage = { getItem: () => null, setItem() {}, removeItem() {} };
globalThis.window = {};
const { standalone, localSettings, canReachLibrary } = await import('../web/js/runtime.js');
assert.equal(standalone, false);
assert.equal(localSettings, true, 'local capability does not require a mobile user agent');
assert.equal(canReachLibrary(), false, 'local settings do not change standalone/offline semantics');
capability = false;
assert.equal((await import('../web/js/runtime.js?without-meta')).localSettings, false);
navigator.userAgent = 'YeduStandalone/1';
assert.equal((await import('../web/js/runtime.js?android')).localSettings, true);
navigator.userAgent = 'Ordinary desktop browser';
capability = true;

const { openModelSettings } = await import('../web/js/model-settings.js');
const saved = { protocol: 'openai', base_url: 'https://saved.invalid/v1', model: 'saved-model', api_key_set: true, api_key_last4: '1234' };
const calls = [];
let pending;
globalThis.fetch = async (url, options) => {
  calls.push([url, options]);
  if (options.method === 'GET') return Response.json(saved);
  return new Promise((resolve) => { pending = resolve; });
};
const root = new Node('main');
const controller = new AbortController();
await openModelSettings(root, { signal: controller.signal });
const all = (node) => [node, ...node.children.flatMap(all)];
const field = (label) => all(root).find((node) => node.attributes['aria-label'] === label);
const button = (text) => all(root).find((node) => node.tag === 'button' && node.children.some((kid) => kid.textContent === text));
const form = all(root).find((node) => node.tag === 'form');
assert.ok(form, 'a normal browser receives the native local-settings form');
field('接口协议').value = 'gemini';
await field('接口协议').trigger('change');
assert.equal(field('模型接口地址').value, 'https://generativelanguage.googleapis.com/v1beta');
field('模型接口地址').value = 'https://preview.invalid/v1beta';
field('抽取模型').value = 'preview-model';
field('API 密钥').value = 'unsaved-test-only';
const controls = all(form).filter((node) => ['input', 'select', 'button'].includes(node.tag));
const testing = button('测试连接').trigger('click');
assert.ok(controls.every((node) => node.disabled), 'test owns all form controls');
await form.trigger('submit');
assert.equal(calls.length, 2, 'save cannot race an in-flight preview');
assert.equal(calls[1][0], '/api/settings/test');
assert.deepEqual(JSON.parse(calls[1][1].body), { protocol: 'gemini', base_url: 'https://preview.invalid/v1beta', model: 'preview-model', api_key: 'unsaved-test-only', clear_key: false, jev_route: 'free-only' });
pending(Response.json({ ok: true, message: 'preview succeeded' }));
await testing;
assert.ok(controls.every((node) => !node.disabled));
assert.equal(field('API 密钥').value, 'unsaved-test-only', 'a probe does not clear or save unsaved credentials');

const saving = form.trigger('submit');
assert.ok(controls.every((node) => node.disabled), 'save owns all form controls');
await button('测试连接').trigger('click');
assert.equal(calls.length, 3, 'preview cannot race an in-flight save');
assert.equal(calls[2][1].method, 'PUT');
pending(Response.json({ ...saved, protocol: 'gemini', base_url: 'https://preview.invalid/v1beta', model: 'preview-model' }));
await saving;
assert.equal(field('API 密钥').value, '');
assert.ok(controls.every((node) => !node.disabled));

field('API 密钥').value = 'do-not-mutate-after-abort';
const abandoned = form.trigger('submit');
controller.abort();
pending(Response.json(saved));
await abandoned;
assert.equal(field('API 密钥').value, 'do-not-mutate-after-abort', 'late saved reply cannot mutate an abandoned page');
assert.equal(field('接口协议').value, 'gemini');
console.log('model settings form passed: native capability, unsaved probe payload, shared busy ownership, abort publication');
