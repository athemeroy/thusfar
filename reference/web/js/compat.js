// Older Android System WebViews (Chrome 87 on Android 11 phones that never update it) lack a
// few newer built-ins the reader uses. Imported first by main.js, before any other module runs.
const define = (target, name, value) => {
  if (!(name in target)) Object.defineProperty(target, name, { value, writable: true, configurable: true });
};
define(Object, 'hasOwn', (object, key) => Object.prototype.hasOwnProperty.call(object, key));
function at(index) {
  const n = Math.trunc(index) || 0, i = n < 0 ? this.length + n : n;
  return i >= 0 && i < this.length ? this[i] : undefined;
}
define(Array.prototype, 'at', at);
define(String.prototype, 'at', at);
if (globalThis.crypto && !crypto.randomUUID) {
  define(crypto, 'randomUUID', () => {
    const b = crypto.getRandomValues(new Uint8Array(16));
    b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
    const x = [...b].map((v) => v.toString(16).padStart(2, '0')).join('');
    return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`;
  });
}
define(globalThis, 'structuredClone', (value) => (value === undefined ? undefined : JSON.parse(JSON.stringify(value))));
