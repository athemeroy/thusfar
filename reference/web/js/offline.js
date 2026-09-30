import { localizeServerMessage, t as tr } from './i18n.js';
// A download belongs to one caller. Worker stages are resumable and publish atomically.
export async function downloadBook(id, onProgress, signal) {
  if (!('serviceWorker' in navigator)) throw new Error(tr('请使用 HTTPS 或安卓 App 下载离线书籍'));
  let timer;
  const reg = await Promise.race([navigator.serviceWorker.ready, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(tr('离线服务还未就绪，请刷新后重试'))), 10000); })]).finally(() => clearTimeout(timer));
  if (!reg.active || signal?.aborted) throw new Error(tr('离线下载已取消'));
  return new Promise((resolve, reject) => {
    const channel = new MessageChannel(); const requestId = `${Date.now()}-${Math.random()}`;
    let timeout;
    const finish = (error) => { clearTimeout(timeout); signal?.removeEventListener('abort', abort); channel.port1.close(); error ? reject(error) : resolve(); };
    const abort = () => { reg.active.postMessage({ type: 'cancel-download', requestId }); finish(new Error(tr('离线下载已暂停'))); };
    const touch = () => { clearTimeout(timeout); timeout = setTimeout(() => { reg.active.postMessage({ type: 'cancel-download', requestId }); finish(new Error(tr('离线下载连接超时，可点击继续'))); }, 45000); };
    channel.port1.onmessage = (event) => { const d = event.data; touch(); if (d.error) finish(new Error(localizeServerMessage(d.error))); else if (d.done) finish(); else onProgress(d.n || 0, d.total || 0); };
    signal?.addEventListener('abort', abort, { once: true }); touch();
    reg.active.postMessage({ type: 'download-book', id, requestId }, [channel.port2]);
  });
}
