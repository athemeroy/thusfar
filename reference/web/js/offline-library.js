// Device-local packages are independent of the library, personal notes and reading progress.
import { api, AuthError } from './api.js';
import { downloadBook } from './offline.js';
import { h, icon } from './util.js';
import { currentLanguage, localizeServerMessage, t as tr } from './i18n.js';

export async function offlineWorkerRequest(type, data = {}, signal) {
  if (!navigator.serviceWorker) throw new Error(tr('请使用 HTTPS 或安卓 App 管理本机下载'));
  let timer;
  const reg = await Promise.race([navigator.serviceWorker.ready, new Promise((_, reject) => {
    timer = setTimeout(() => reject(new Error(tr('离线服务尚未就绪，请刷新页面后重试'))), 10000);
  })]).finally(() => clearTimeout(timer));
  if (signal?.aborted) throw new DOMException(tr('已取消'), 'AbortError');
  if (!reg.active) throw new Error(tr('离线服务尚未就绪'));
  return new Promise((resolve, reject) => {
    const channel = new MessageChannel();
    let settled = false;
    const finish = (error, value) => {
      if (settled) return; settled = true;
      clearTimeout(timer); signal?.removeEventListener('abort', abort); channel.port1.close();
      error ? reject(error) : resolve(value);
    };
    const abort = () => finish(new DOMException(tr('已取消'), 'AbortError'));
    signal?.addEventListener('abort', abort, { once: true });
    timer = setTimeout(() => finish(new Error(tr('本机下载状态暂未返回，请稍后刷新核对'))), 20000);
    channel.port1.onmessage = ({ data: result }) => result.error ? finish(new Error(localizeServerMessage(result.error))) : finish(null, result);
    reg.active.postMessage({ type, ...data }, [channel.port2]);
  });
}

const bytes = (value) => value >= 1024 ** 3 ? `${(value / 1024 ** 3).toFixed(1)} GB` : `${Math.max(.1, value / 1024 ** 2).toFixed(1)} MB`;
const date = (value) => new Date(value).toLocaleString(currentLanguage(), { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' });

export async function openOfflineLibrary(root, options = {}) {
  const controller = new AbortController(), signal = controller.signal;
  if (options.signal?.aborted) return;
  const stop = () => controller.abort();
  options.signal?.addEventListener('abort', stop, { once: true });
  delete document.documentElement.dataset.bookLang;
  let books = [], packages = [], foreignJobs = [], filter = 'downloaded', query = '', timer, pendingInventory, inventoryKnown = false, inventoryError = '';
  const jobs = new Map(), checks = new Map(), messages = new Map(), cards = new Map();
  const list = h('div', { class: 'offline-library-list' });
  const notice = h('p', { class: 'offline-library-notice', role: 'status' }, tr('正在核对本机下载…'));
  const summary = h('p', { class: 'offline-library-summary', role: 'status' });
  const storage = h('p', { class: 'offline-library-storage' });
  const search = h('input', { type: 'search', placeholder: tr('查找书名或作者'), 'aria-label': tr('搜索下载书籍'), oninput: () => { query = search.value; render(); } });
  const tabs = ['downloaded', 'all'].map((value) => h('button', { type: 'button', 'aria-pressed': filter === value, onclick: () => {
    filter = value; tabs.forEach((tab, i) => tab.setAttribute('aria-pressed', String(i === (value === 'downloaded' ? 0 : 1)))); render();
  } }, value === 'downloaded' ? tr('本机下载') : tr('选择书籍下载')));
  const refreshButton = h('button', { type: 'button', class: 'btn', onclick: () => refreshInventory().catch(showError) }, tr('刷新本机状态'));
  const page = h('main', { class: 'shelf offline-library paper-grain' },
    h('a', { class: 'offline-library-back', href: '#/' }, icon('back'), tr('返回书房')),
    h('header', { class: 'offline-library-header' }, h('div', {}, h('p', { class: 'offline-library-eyebrow' }, tr('把书带在身边')), h('h1', {}, tr('本机书包')),
      h('p', {}, tr('提前装好想读的书，没有网络也能接着读。'))), refreshButton),
    notice, h('section', { class: 'offline-library-capacity', 'aria-label': tr('本机空间与下载') }, summary, storage),
    h('div', { class: 'offline-library-controls' }, h('div', { class: 'offline-library-tabs', role: 'group', 'aria-label': tr('下载范围') }, tabs), search), list,
    h('footer', { class: 'offline-library-footer' }, tr('移除本机副本会清理正文、插图和人物资料，书房中的书籍、个人摘记、草稿和阅读进度仍保留。'),
      h('p', {}, tr('更新时保留原先下载的内容，完成后再替换。有没有新内容，可以逐本联网检查。'))));
  root.replaceChildren(page);

  function showError(error) { if (!signal.aborted) notice.textContent = error.message || tr('本机下载状态暂不可用'); }
  function connection() { if (inventoryKnown) notice.textContent = navigator.onLine ? tr('在这里查看已下载的书，继续未完成的下载。') : tr('当前离线 · 已完整下载的书可以继续阅读，下载和更新需要联网。'); }
  function packageFor(id) { return packages.find((entry) => entry.id === id); }
  function externalJob(id) { return foreignJobs.find((job) => job.id === id) && !jobs.has(id); }

  function updateCard(book) {
    const card = cards.get(book.id), entry = packageFor(book.id), job = jobs.get(book.id), external = externalJob(book.id);
    card.title.textContent = book.title || tr('未命名'); card.author.textContent = book.author || tr('作者未标注');
    card.state.textContent = entry?.available ? entry.verification === 'legacy' ? tr('正文可离线 · 旧副本的插图待核对') : tr('可离线阅读')
      : entry ? entry.partial ? tr('下载未完成，可继续') : tr('本机副本不完整，需要重新下载') : tr('尚未完整下载');
    if (entry?.available && entry.partial) card.state.textContent += tr(' · 更新未完成，原副本仍可用');
    card.stamp.textContent = entry?.verifiedAt ? tr("最近下载完成：{0}", [date(entry.verifiedAt)]) : '';
    const checked = checks.get(book.id);
    card.check.textContent = checked ? checked.error ? localizeServerMessage(checked.error) : checked.same ? tr("与 {0} 核对的书房内容一致", [date(checked.time)]) : tr('已核对：书房有新内容，可以更新') : '';
    card.progress.hidden = !job || !job.total;
    if (job?.total) { card.progress.max = job.total; card.progress.value = job.n; }
    card.message.textContent = job ? job.cancelled ? tr('正在暂停，请稍候…') : tr("正在下载 {0}/{1} 项", [job.n || 0, job.total || '…']) : external ? tr('另一个页面正在下载这本书，完成后可刷新查看。') : messages.get(book.id) || '';
    card.read.hidden = !entry?.available;
    card.download.textContent = entry?.available ? entry.partial ? tr('继续更新') : tr('更新本机副本') : entry?.partial ? tr('继续下载') : tr('下载到本机');
    card.download.disabled = !!job || !!external || !!card.busy || !navigator.onLine;
    card.verify.hidden = !entry?.available;
    card.verify.disabled = !!job || !!external || !!card.busy || !navigator.onLine;
    card.remove.hidden = !entry;
    card.remove.disabled = !!job || !!external || !!card.busy;
    card.cancel.hidden = !job;
    card.cancel.disabled = !!job?.cancelled;
  }

  function makeCard(book) {
    const title = h('h2'), author = h('p', { class: 'offline-book-author' });
    const state = h('p', { class: 'offline-book-state' }), stamp = h('p', { class: 'offline-book-stamp' });
    const check = h('p', { class: 'offline-book-check' }), message = h('p', { class: 'offline-book-message', role: 'status' });
    const progress = h('progress', { 'aria-label': tr("《{0}》下载进度", [book.title || tr('未命名')]), hidden: true });
    const read = h('a', { class: 'btn zhu', href: `#/read/${book.id}` }, tr('打开阅读'));
    const download = h('button', { type: 'button', class: 'btn', onclick: () => startDownload(book.id) });
    const verify = h('button', { type: 'button', class: 'btn', onclick: () => checkUpdate(book.id) }, tr('检查更新'));
    const cancel = h('button', { type: 'button', class: 'btn', hidden: true, onclick: () => {
      const job = jobs.get(book.id); if (job) { job.cancelled = true; job.controller.abort(); updateCard(book); }
    } }, tr('暂停下载'));
    const remove = h('button', { type: 'button', class: 'offline-book-remove', onclick: () => removeCopy(book.id) }, tr('移除本机副本'));
    const node = h('article', { class: 'offline-book', 'data-book-id': book.id },
      h('div', { class: 'offline-book-heading' }, h('span', { class: 'offline-book-seal', 'aria-hidden': 'true' }, tr('书')), h('div', {}, title, author)),
      state, stamp, check, progress, message, h('div', { class: 'offline-book-actions' }, read, download, verify, cancel, remove));
    const card = { node, title, author, state, stamp, check, message, progress, read, download, verify, cancel, remove };
    cards.set(book.id, card); return card;
  }

  function render() {
    if (signal.aborted) return;
    const ids = new Set(books.map((book) => book.id));
    const available = packages.filter((entry) => ids.has(entry.id) && entry.available).length;
    summary.textContent = inventoryKnown ? tr("{0} 本可以离线阅读 · {1} 本待继续或修复", [available, packages.filter((entry) => ids.has(entry.id) && (!entry.available || entry.partial)).length]) : tr('本机下载状态尚未核对');
    const term = query.normalize('NFKC').trim().toLocaleLowerCase();
    const rows = books.filter((book) => (filter === 'all' || packageFor(book.id) || jobs.has(book.id) || externalJob(book.id)) && `${book.title || ''} ${book.author || ''}`.normalize('NFKC').toLocaleLowerCase().includes(term));
    const focus = document.activeElement;
    list.replaceChildren(...rows.map((book) => { const card = cards.get(book.id) || makeCard(book); updateCard(book); return card.node; }));
    if (focus?.isConnected && !focus.hidden && !focus.disabled) focus.focus({ preventScroll: true });
    if (!rows.length) list.append(h('div', { class: 'offline-library-empty' }, h('h2', {}, !inventoryKnown ? inventoryError ? tr('暂时无法核对本机下载') : tr('正在读取本机下载') : term ? tr('没有找到这本书') : tr('书包里还没有书')),
      h('p', {}, !inventoryKnown ? inventoryError || tr('先查看本机保存的信息，联网时再更新书库。') : term ? tr('试试别的书名或作者。') : tr('选几本接下来想读的书，下载完成后再出发。')),
      inventoryKnown && !term && filter === 'downloaded' ? h('button', { type: 'button', class: 'btn zhu', onclick: () => tabs[1].click() }, tr('选择书籍下载')) : null));
  }

  async function estimateStorage() {
    try {
      const value = await navigator.storage?.estimate?.(); if (signal.aborted) return;
      storage.textContent = value && Number.isFinite(value.usage) && Number.isFinite(value.quota)
        ? tr("本站在此浏览器约使用 {0}，浏览器允许的总额度约 {1}。包含字体、摘记和其他缓存。", [bytes(value.usage), bytes(value.quota)])
        : tr('浏览器没有提供可用的空间估算。');
    } catch { if (!signal.aborted) storage.textContent = tr('暂时无法估算本机空间。'); }
  }

  async function refreshInventory() {
    if (pendingInventory) return pendingInventory;
    refreshButton.disabled = true; clearTimeout(timer);
    pendingInventory = (async () => {
      const data = await offlineWorkerRequest('offline-inventory', {}, signal);
      if (signal.aborted) return;
      if (!Array.isArray(data.books) || !Array.isArray(data.packages) || !Array.isArray(data.downloads)) throw new Error(tr('本机下载清单格式不正确'));
      if (!books.length) books = data.books;
      inventoryKnown = true; inventoryError = ''; packages = data.packages; foreignJobs = data.downloads; render(); estimateStorage();
      if (foreignJobs.length) timer = setTimeout(() => refreshInventory().catch(showError), 1500);
    })();
    try { await pendingInventory; }
    catch (error) { inventoryError = error.message || tr('本机下载状态暂不可用'); render(); throw error; }
    finally { pendingInventory = null; if (!signal.aborted) refreshButton.disabled = false; }
  }

  async function refreshBooks(refreshLocal = true) {
    if (!navigator.onLine) return;
    try {
      const rows = await api.books({ signal, timeout: 12000 });
      if (signal.aborted) return;
      books = rows.filter((book) => !book.hidden && !book.meta?.hidden); connection();
      if (refreshLocal) await refreshInventory(); render();
    } catch (error) {
      if (error instanceof AuthError) throw error;
      if (!signal.aborted) { notice.textContent = tr("未能更新书库，以下仍显示本机保留的信息。{0}", [error.message || '']); render(); }
    }
  }

  async function startDownload(id) {
    const book = books.find((book) => book.id === id); if (!book || jobs.has(id) || signal.aborted) return;
    const own = new AbortController(), job = { controller: own, n: 0, total: 0 };
    const abort = () => own.abort(); signal.addEventListener('abort', abort, { once: true }); jobs.set(id, job); messages.delete(id); updateCard(book);
    try {
      await downloadBook(id, (n, total) => { job.n = n; job.total = total; if (!signal.aborted) updateCard(book); }, own.signal);
      checks.delete(id); messages.set(id, tr('已装入书包，现在可以离线阅读。'));
    } catch (error) { messages.set(id, own.signal.aborted ? tr('已暂停。已下载的部分保留，联网后可继续。') : error.message); }
    finally {
      signal.removeEventListener('abort', abort); jobs.delete(id);
      if (!signal.aborted) { await refreshInventory().catch(showError); render(); }
    }
  }

  async function checkUpdate(id) {
    const book = books.find((book) => book.id === id), card = cards.get(id), entry = packageFor(id);
    if (!book || !entry || card.busy || signal.aborted) return;
    card.busy = true; messages.set(id, tr('正在检查这本书是否有更新…')); updateCard(book);
    const own = new AbortController(), abort = () => own.abort(); signal.addEventListener('abort', abort, { once: true });
    const timeout = setTimeout(abort, 12000);
    try {
      const response = await fetch(`/api/books/${id}/offline-manifest`, { credentials: 'same-origin', cache: 'no-cache', signal: own.signal });
      if (response.status === 401) throw new AuthError(tr('需要重新输入书房口令'));
      if (!response.ok) throw new Error(tr('暂时无法检查更新'));
      const manifest = await response.json(); if (!manifest.version || manifest.book?.id !== id) throw new Error(tr('这本书的更新信息暂时无法识别，请稍后重试'));
      checks.set(id, { same: String(manifest.version) === String(entry.version), time: Date.now() }); messages.delete(id);
    } catch (error) {
      if (error instanceof AuthError && !signal.aborted) { location.hash = '#/'; return; }
      checks.set(id, { error: tr('本次未能核对更新；本机原副本仍保留。') }); messages.set(id, error.message || tr('请联网后重试'));
    } finally { clearTimeout(timeout); signal.removeEventListener('abort', abort); card.busy = false; if (!signal.aborted) updateCard(book); }
  }

  async function removeCopy(id) {
    const book = books.find((book) => book.id === id), card = cards.get(id);
    if (!book || card.busy || signal.aborted) return;
    if (!confirm(tr("移除《{0}》的本机离线副本？\n书房里的书、个人摘记、草稿和阅读进度都保留。之后需要联网才能重新下载正文。", [book.title || tr('未命名')]))) return;
    card.busy = true; updateCard(book);
    try { await offlineWorkerRequest('remove-offline-copy', { id }, signal); checks.delete(id); messages.set(id, tr('本机副本已移除，书籍和个人记录仍保留。')); if (!signal.aborted) notice.textContent = tr("《{0}》的本机副本已移除，书籍和个人记录仍保留。", [book.title || tr('未命名')]); }
    catch (error) { messages.set(id, error.message); }
    finally { card.busy = false; if (!signal.aborted) { await refreshInventory().catch(showError); render(); } }
  }

  const online = () => { connection(); render(); refreshBooks().catch((error) => { if (error instanceof AuthError) location.hash = '#/'; else showError(error); }); };
  const offline = () => { connection(); render(); };
  addEventListener('online', online); addEventListener('offline', offline);
  signal.addEventListener('abort', () => { clearTimeout(timer); options.signal?.removeEventListener('abort', stop); removeEventListener('online', online); removeEventListener('offline', offline); for (const job of jobs.values()) job.controller.abort(); }, { once: true });
  render();
  // Authentication does not wait for worker readiness; the root router handles a direct 401.
  try { await Promise.all([refreshInventory().catch(showError), refreshBooks(false)]); }
  catch (error) { controller.abort(); throw error; }
  if (!signal.aborted) { connection(); render(); }
}
