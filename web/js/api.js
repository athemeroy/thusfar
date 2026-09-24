import { localizeServerMessage, t as tr } from './i18n.js';
// Same-origin transport with explicit deadlines and owned cancellation.
export class AuthError extends Error {}
export class ConflictError extends Error { constructor(message, data) { super(message); this.data = data; } }
function deadline(signal, ms = 30000) {
  const controller = new AbortController();
  const abort = () => controller.abort(signal?.reason);
  if (signal?.aborted) abort(); else signal?.addEventListener('abort', abort, { once: true });
  const timer = setTimeout(() => controller.abort(new Error(tr('连接超时，请重试'))), ms);
  return { signal: controller.signal, close() { clearTimeout(timer); signal?.removeEventListener('abort', abort); } };
}
async function req(method, url, body, options = {}) {
  const d = deadline(options.signal, options.timeout);
  try {
    const r = await fetch(url, { method, credentials: 'same-origin', signal: d.signal,
      headers: body == null ? {} : { 'Content-Type': 'application/json' },
      body: body == null ? undefined : JSON.stringify(body), keepalive: !!options.keepalive });
    if (r.status === 401) throw new AuthError(tr('需要口令'));
    let data;
    try { data = await r.json(); } catch { throw new Error(tr('服务器返回了无法识别的数据，请重试')); }
    if (r.status === 409) throw new ConflictError(data.error ? localizeServerMessage(data.error) : tr('其他设备更新了阅读进度'), data);
    if (!r.ok) {
      const error = new Error(data.error ? localizeServerMessage(data.error) : tr("请求失败（{0}）", [r.status]));
      error.status = r.status;
      throw error;
    }
    if (options.array ? !Array.isArray(data) : data == null || typeof data !== 'object') throw new Error(tr('服务器数据格式不正确'));
    return data;
  } catch (error) { if (d.signal.aborted && !options.signal?.aborted) throw new Error(tr('连接超时，请重试')); throw error; }
  finally { d.close(); }
}
export const api = {
  me: (o) => req('GET', '/api/me', null, o),
  settings: (o) => req('GET', '/api/settings', null, o),
  saveSettings: (settings, o) => req('PUT', '/api/settings', settings, o),
  login: (code, o) => req('POST', '/api/login', { code }, o),
  books: (o) => req('GET', '/api/books', null, { ...o, array: true }),
  readingList: (o) => req('GET', '/api/reading-list', null, o),
  saveReadingList: (payload, o) => req('PUT', '/api/reading-list', payload, o),
  notebook: (id, o) => req('GET', `/api/books/${id}/notebook`, null, o),
  saveNote: (id, item, o) => req('PUT', `/api/books/${id}/notebook`, item, o),
  manualEntities: (id, to, o) => req('GET', `/api/books/${id}/manual-entities?to=${to}`, null, o),
  saveManualEntity: (id, item, o) => req('PUT', `/api/books/${id}/manual-entities`, item, o),
  book: (id, o) => req('GET', `/api/books/${id}`, null, o),
  chapter: (id, n, o) => req('GET', `/api/books/${id}/chapters/${n}`, null, o),
  kg: (id, from, to, o) => req('GET', `/api/books/${id}/kg?from=${from}&to=${to}`, null, o),
  progress: (id, pos, pct, o = {}) => req('PUT', `/api/books/${id}/progress`, { pos, pct, ...(o.cutoff !== undefined ? { cutoff: o.cutoff } : {}), ...(o.expected_t !== undefined ? { expected_t: o.expected_t } : {}), client_updated_at: o.updatedAt }, o),
  async process(id, o) {
    let result;
    try { result = await req('POST', `/api/books/${id}/process`, {}, o); }
    catch (error) {
      // An empty overload response can arrive after the worker accepted the job.
      // Reconcile the same book before reporting failure; never submit it twice.
      const book = o?.signal?.aborted ? null : await req('GET', `/api/books/${id}`, null, { ...o, timeout: 10000 }).catch(() => null);
      if (!['queued', 'running', 'finalizing'].includes(book?.status?.state)) throw error;
      result = { ok: true, status: book.status, reconciled: true };
    }
    if (/YeduStandalone\/1\b/.test(navigator.userAgent)) window.YeduApp?.processingStarted?.();
    return result;
  },
  cancelProcess: (id, o) => req('DELETE', `/api/books/${id}/process`, null, o),
  setKind: (id, kind, o) => req('PUT', `/api/books/${id}/kind`, { kind }, o),
  who: (id, pos, start, end, o) => req('POST', `/api/books/${id}/who`, { pos, start, end }, o),
  marginalia: (id, payload, o = {}) => req('POST', `/api/books/${id}/marginalia`, payload, { timeout: 180000, ...o }),
  remove: (id, o) => req('DELETE', `/api/books/${id}`, null, o),
  upload(file, onProgress, options = {}) {
    return new Promise((resolve, reject) => {
      const x = new XMLHttpRequest(); const abort = () => x.abort();
      if (options.signal?.aborted) { reject(new DOMException(tr('已取消'), 'AbortError')); return; }
      options.signal?.addEventListener('abort', abort, { once: true });
      x.open('POST', '/api/books'); x.timeout = 180000;
      x.setRequestHeader('X-Filename', encodeURIComponent(file.name));
      x.upload.onprogress = (e) => e.lengthComputable && onProgress?.(e.loaded / e.total);
      x.onloadend = () => options.signal?.removeEventListener('abort', abort);
      x.onload = () => {
        let data; try { data = JSON.parse(x.responseText); } catch { reject(new Error(tr('上传响应无法识别，请检查书架后重试'))); return; }
        x.status >= 200 && x.status < 300 ? resolve(data) : reject(new Error(data.error ? localizeServerMessage(data.error) : tr('上传失败')));
      };
      x.onerror = () => reject(new Error(tr('网络出错了，请检查书架后重试')));
      x.ontimeout = () => reject(new Error(tr('上传超时，请先检查书架，避免重复导入')));
      x.onabort = () => reject(new DOMException(tr('已取消'), 'AbortError')); x.send(file);
    });
  },
  async restore(file, options = {}) {
    let data; try { data = JSON.parse(await file.text()); } catch { throw new Error(tr('这个文件不是有效的书籍备份')); }
    return req('POST', '/api/books/import', data, { ...options, timeout: 180000 });
  },
  async ask(id, q, pos, onEvent, options = {}) {
    const d = deadline(options.signal, 180000); let reader;
    try {
      const r = await fetch(`/api/books/${id}/ask`, { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ q, pos }), credentials: 'same-origin', signal: d.signal });
      if (!r.ok) throw new Error(localizeServerMessage((await r.json().catch(() => ({}))).error) || tr('提问失败'));
      reader = r.body.getReader(); const dec = new TextDecoder(); let buf = '';
      for (;;) {
        const { value, done } = await reader.read(); if (done) break;
        buf += dec.decode(value, { stream: true }); let i;
        while ((i = buf.search(/\r?\n\r?\n/)) >= 0) {
          const chunk = buf.slice(0, i); const separator = /^\r?\n\r?\n/.exec(buf.slice(i))[0]; buf = buf.slice(i + separator.length);
          const ev = /^event: ?(.*)$/m.exec(chunk)?.[1]?.trim();
          const data = [...chunk.matchAll(/^data: ?(.*)$/gm)].map((m) => m[1]).join('\n');
          if (ev && data) onEvent(ev, JSON.parse(data));
        }
      }
    } catch (error) { if (d.signal.aborted && !options.signal?.aborted) throw new Error(tr('回答超时，请重试')); throw error; }
    finally { if (d.signal.aborted) await reader?.cancel().catch(() => {}); reader?.releaseLock(); d.close(); }
  },
};
