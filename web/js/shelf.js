// Reader home: resume, find a book, and manage imports without starting model jobs.
import { api, AuthError } from './api.js';
import { h, icon, toast, qualityPending, store } from './util.js';
import { downloadBook } from './offline.js';
import { LIBRARY_FILTERS, normalizeLibrary, continueBook, libraryBooks, libraryCounts, resumeReceipts } from './library.js';
import { addToReadingList } from './reading-list.js';
import { standalone, localSettings, canReachLibrary } from './runtime.js';
import { currentLanguage, t as tr } from './i18n.js';

const COVERS = ['#2f4858', '#2d4a3e', '#7a3e25', '#8e3a1f', '#3b3f5c', '#5a3e2b', '#44506b', '#3e5a4a', '#6b3b4a'];
const FILTER_LABELS = { all: tr('全部'), reading: tr('在读'), unread: tr('未读'), finished: tr('读完'), downloaded: tr('已下载') };
const RECEIPTS_KEY = 'library-imports-v1';
function coverColor(title) { let x = 0; for (const c of title || '') x = (x * 31 + c.charCodeAt(0)) >>> 0; return COVERS[x % COVERS.length]; }
function estimate(b) {
  const e = b?.est; if (!e) return tr('暂无可靠的耗时和费用估算');
  if (e.low == null || e.high == null) return tr('模型价格未收录，请先向接口提供方确认费用');
  const mins = Math.max(1, Number(e.minutes) || 1);
  const time = mins < 60 ? tr("{0} 分钟", [Math.ceil(mins)]) : tr("{0} 小时", [(mins / 60).toFixed(1)]);
  if (!Number.isFinite(e.low) || !Number.isFinite(e.high)) return tr("约 {0}，费用以实际调用为准", [time]);
  const money = e.high < 1 ? `¥${e.low.toFixed(1)}～${e.high.toFixed(1)}` : `¥${Math.round(e.low)}～${Math.round(e.high)}`;
  return tr("约 {0} · {1}", [time, money]);
}
function size(b) {
  if (currentLanguage() === 'zh-CN') return b.lang === 'zh'
    ? tr('{0} 万字', [((b.len || 0) / 10000).toFixed(1)])
    : tr('{0}k 字符', [Math.round((b.len || 0) / 1000)]);
  return tr('{0} 字符', [new Intl.NumberFormat(currentLanguage()).format(b.len || 0)]);
}
function pctLabel(value) { return value > 0 && value < 1 ? '<1%' : `${Math.floor(value)}%`; }
function readingLabel(b) { return b.reading.state === 'finished' ? tr('已读完') : b.reading.state === 'reading' ? tr("读到 {0}", [pctLabel(b.reading.pct)]) : tr('尚未开始'); }
function cover(b) {
  const el = h('div', { class: `cover${b.cover ? ' has-img' : ''}`, style: { background: coverColor(b.title) }, 'aria-hidden': 'true' });
  if (b.cover) el.append(h('img', { src: `/api/books/${b.id}/img/${b.cover}`, alt: '', loading: 'lazy', onerror: (e) => { e.currentTarget.remove(); el.classList.remove('has-img'); el.append(h('span', { class: 'ct' }, b.title || tr('未命名'))); } }));
  else el.append(h('span', { class: 'ct' }, b.title || tr('未命名')), h('span', { class: 'seal' }, tr('页读')), h('span', { class: 'ca' }, b.author || ''));
  return el;
}
export function aiState(st) {
  if (!st || !st.state || st.state === 'idle') return ['', tr('未整理人物')];
  if (st.state === 'done' && qualityPending(st)) return ['', tr('正文已整理 · 部分资料待核对')];
  if (st.state === 'done') return ['done', st.people > 0 ? tr("AI 已读完 · {0} 位人物", [st.people]) : tr('AI 已读完')];
  if (st.state === 'error') return ['', tr('AI 整理停下了，点开查看原因')];
  if (st.state === 'queued') return ['run', tr('AI 排队中')];
  if (st.state === 'finalizing') return ['run', tr('正在核对并整理最后的资料')];
  if (st.state === 'paused') return ['', tr('整理已暂停')];
  return ['run', tr("AI 正在读 · {0}%", [Math.round(100 * (st.done || 0) / Math.max(1, st.total || 1))])];
}

export async function openShelf(root, options = {}) {
  const controller = new AbortController(), signal = controller.signal;
  if (options.signal?.aborted) return;
  options.signal?.addEventListener('abort', () => controller.abort(), { once: true });
  delete document.documentElement.dataset.bookLang;
  root.textContent = '';
  const standaloneSaved = standalone ? store.get('library-view-v2', null) : null;
  const saved = standaloneSaved || store.get('library-view-v1', {}) || {};
  const initialView = standalone && !standaloneSaved ? 'list' : saved.view;
  const filtersAvailable = standalone ? LIBRARY_FILTERS.filter((key) => key !== 'downloaded') : LIBRARY_FILTERS;
  const preferences = { filter: filtersAvailable.includes(saved.filter) ? saved.filter : 'all', query: typeof saved.query === 'string' ? saved.query : '',
    sort: ['recent', 'title', 'progress'].includes(saved.sort) ? saved.sort : 'recent', view: ['grid', 'list'].includes(initialView) ? initialView : standalone ? 'list' : 'grid' };
  let books = [], loaded = false, loading = null, timer = null, dialog = null, importsRunning = false, pendingRender = false;
  let receipts = resumeReceipts(store.get(RECEIPTS_KEY, []));
  const importFiles = new Map(), downloading = new Set();
  const hero = h('section', { class: 'library-resume', 'aria-label': tr('继续阅读'), hidden: true });
  const grid = h('div', { class: 'books library-books', id: 'library-books', 'aria-label': tr('书籍列表') });
  const count = h('p', { class: 'library-result', role: 'status', 'aria-live': 'polite' }, tr('正在打开书房…'));
  const notice = h('div', { class: 'library-notice', role: 'status', hidden: true });
  const importPanel = h('section', { class: 'library-imports', hidden: true, 'aria-label': tr('导入记录') });
  const file = h('input', { type: 'file', accept: standalone ? '.txt,.epub,.json' : '.txt,.epub,.mobi,.azw3,.azw,.json', multiple: true, hidden: true, 'aria-label': tr('选择书籍文件') });
  const pickFiles = () => file.click();
  const search = h('input', { type: 'search', placeholder: tr('找一本书，或一位作者'), value: preferences.query, 'aria-label': tr('搜索书名或作者'), autocomplete: 'off', oninput: () => { preferences.query = search.value; saveView(); render(); } });
  const clearSearch = h('button', { class: 'library-clear', type: 'button', 'aria-label': tr('清空搜索'), hidden: !preferences.query, onclick: () => { preferences.query = ''; search.value = ''; saveView(); render(); search.focus(); } }, icon('close'));
  const filterButtons = new Map();
  const filters = h('div', { class: 'library-filters', role: 'group', 'aria-label': tr('按阅读状态筛选') }, filtersAvailable.map((key) => {
    const button = h('button', { type: 'button', 'aria-pressed': preferences.filter === key, onclick: () => { preferences.filter = key; saveView(); render(); } }, FILTER_LABELS[key], h('span', {}, '0'));
    filterButtons.set(key, button); return button;
  }));
  const sort = h('select', { 'aria-label': tr('书籍排序'), onchange: () => { preferences.sort = sort.value; saveView(); render(); } },
    h('option', { value: 'recent' }, tr('最近阅读')), h('option', { value: 'title' }, tr('按书名')), h('option', { value: 'progress' }, tr('按阅读进度')));
  sort.value = preferences.sort;
  const views = new Map();
  const viewButtons = h('div', { class: 'library-layout', role: 'group', 'aria-label': tr('书架布局') }, ['grid', 'list'].map((key) => {
    const button = h('button', { type: 'button', 'aria-pressed': preferences.view === key, onclick: () => { preferences.view = key; saveView(); render(); } }, key === 'grid' ? tr('封面') : tr('列表')); views.set(key, button); return button;
  }));
  const header = h('header', { class: 'shelf-head library-header' },
    h('div', { class: 'library-brand-lockup' }, h('span', { class: 'brand-mark', 'aria-hidden': 'true' }, '页'),
      h('div', {}, h('h1', { class: 'brand' }, tr('页读')), h('p', { class: 'library-tagline' }, tr('只读到你这一页')))),
    h('div', { class: 'library-header-actions' }, h('a', { class: 'library-settings-button', href: '#/settings', 'aria-label': localSettings ? tr('模型设置') : tr('设置'), title: localSettings ? tr('模型设置') : tr('设置') }, icon('settings')),
      h('button', { class: 'btn zhu library-import-button', type: 'button', onclick: pickFiles }, icon('plus'), tr('导入书籍'))));
  const shelf = h('main', { class: 'shelf paper-grain reading-home' }, header, notice, hero,
    h('section', { class: 'library-collection', 'aria-labelledby': 'library-title' },
      h('div', { class: 'library-section-head' }, h('h2', { id: 'library-title' }, tr('我的书')), h('span', { class: 'library-section-note' }, tr('正文与资料都在这里'))),
      h('div', { class: 'library-search-row' }, h('label', { class: 'library-search' }, icon('search'), search, clearSearch), sort),
      h('div', { class: 'library-filter-row' }, filters, viewButtons), count, grid), importPanel,
    h('footer', { class: 'library-footer' },
      h('p', {}, standalone ? tr('书籍和笔记都保存在这台手机，随时可以离线阅读。整理人物资料需要联网。') : tr('正文随时可读。点开书籍菜单，可以下载到本机，或按需整理人物资料。')),
      h('details', {}, h('summary', {}, tr('关于人物批注')), h('p', {}, tr('正文里朱线标出的人名，可以查看按当前页截止的身份、关系和经历。返回前页，批注也随之回退。AI 可能理解有误，点出处回到原文核对。'))),
      navigator.userAgent.includes('YeduApp') ? null : h('p', {}, h('a', { class: 'linkish', href: 'https://github.com/athemeroy/thusfar/releases/latest' }, tr('下载安卓 App')), tr(' · 也可以把页读添加到主屏幕'))), file);
  root.append(shelf);
  function saveView() { store.set(standalone ? 'library-view-v2' : 'library-view-v1', preferences); }
  function normalized() { return normalizeLibrary(books, (id) => store.get(`resume:${id}`, null)); }
  function showNotice(text) { notice.textContent = text; notice.hidden = !text; }
  function networkState() { if (!canReachLibrary()) showNotice(tr('当前离线 · 已下载的书可以继续阅读，阅读位置会先保存在本机。')); else if (!loading) showNotice(''); }
  function render() {
    if (signal.aborted) return;
    const all = normalized(), counts = libraryCounts(all), visible = libraryBooks(all, preferences);
    clearSearch.hidden = !preferences.query;
    for (const [key, button] of filterButtons) { button.setAttribute('aria-pressed', String(preferences.filter === key)); button.querySelector('span').textContent = counts[key]; }
    for (const [key, button] of views) button.setAttribute('aria-pressed', String(preferences.view === key));
    count.textContent = loaded ? tr("{0} 本{1}{2}", [visible.length, preferences.query.trim() ? tr('符合搜索') : '', preferences.filter !== 'all' ? ` · ${FILTER_LABELS[preferences.filter]}` : '']) : tr('正在打开书房…');
    // Background status polling must not remove the link/button a keyboard user is on.
    const focusedCard = document.activeElement?.closest('.library-card');
    if ((focusedCard && grid.contains(focusedCard) && all.some((b) => b.id === focusedCard.dataset.bookId)) || hero.contains(document.activeElement)) { pendingRender = true; return; }
    pendingRender = false;
    const current = continueBook(all);
    hero.hidden = !current;
    if (current) hero.replaceChildren(h('a', { class: 'library-resume-cover', href: `#/read/${current.id}`, 'aria-label': tr("继续阅读《{0}》", [current.title]) }, cover(current)),
      h('div', { class: 'library-resume-copy' }, h('span', { class: 'library-eyebrow' }, tr('继续阅读 · ') + readingLabel(current)), h('h2', {}, current.title || tr('未命名')),
        h('p', { class: 'library-resume-progress' }, aiState(current.status)[1], current.reading.conflict ? tr(' · 阅读进度待选择') : current.reading.pending ? tr(' · 本机进度待保存') : ''),
        h('a', { class: 'library-resume-action', href: `#/read/${current.id}` }, tr('接着读'), icon('chev'))));
    grid.dataset.layout = preferences.view;
    grid.replaceChildren(...visible.map(bookCard));
    if (!visible.length && loaded) grid.append(h('div', { class: 'library-empty' }, h('span', { class: 'library-empty-mark', 'aria-hidden': 'true' }, '页'),
      h('h3', {}, books.length ? preferences.filter === 'downloaded' && !preferences.query ? tr('把想读的书，带在身边') : tr('这里还没有找到书') : tr('你的第一本书，从这里开始')),
      h('p', {}, books.length ? preferences.filter === 'downloaded' && !preferences.query ? tr('打开书籍菜单，选择“下载到本机”。出门没有网络，也能接着读。') : tr('试试别的书名、作者，或切回全部书籍。') : standalone ? tr('导入 TXT 或 EPUB，即可离线阅读；已有的书籍备份也可以恢复。MOBI 请先转成 EPUB。') : tr('导入 TXT、EPUB、MOBI 或 AZW3，即可开始阅读；已有的书籍备份也可以恢复。')),
      h('button', { class: 'btn primary', type: 'button', onclick: books.length ? () => { preferences.query = ''; preferences.filter = 'all'; search.value = ''; saveView(); render(); } : pickFiles }, books.length ? tr('查看全部书籍') : tr('导入第一本书'))));
  }
  function bookCard(b) {
    const [cls, label] = aiState(b.status);
    return h('article', { class: 'book-card library-card', 'data-book-id': b.id },
      h('a', { class: 'book-open', href: `#/read/${b.id}`, 'aria-label': `${b.reading.state === 'reading' ? tr('继续阅读') : tr('打开')}《${b.title || tr('未命名')}》` }, cover(b)),
      h('div', { class: 'book-meta' }, h('a', { class: 't', href: `#/read/${b.id}` }, b.title || tr('未命名')),
        h('p', { class: 'library-author' }, b.author || tr('作者未标注')),
        h('div', { class: 'library-card-progress' }, h('span', {}, readingLabel(b)), !standalone && b.offline ? h('span', { class: 'library-offline', title: tr('完整离线下载保存在本机') }, tr('已下载')) : null),
        h('div', { class: 'meter', 'aria-hidden': 'true' }, h('i', { style: { width: `${b.reading.pct}%` } })),
        standalone && !['done', 'queued', 'running', 'finalizing'].includes(b.status?.state)
          ? h('button', { class: 'library-ai-status library-ai-link', type: 'button', onclick: (e) => showBook(b.id, e.currentTarget) }, h('span', { class: `ai-dot ${cls}` }), label, icon('chev'))
          : h('p', { class: 'library-ai-status' }, h('span', { class: `ai-dot ${cls}` }), label),
        b.status?.notice && ['queued', 'running'].includes(b.status.state) ? h('p', { class: 'library-ai-note' }, b.status.notice) : null,
        b.thin ? h('p', { class: 'library-thin' }, tr('可能是试读片段')) : null),
      h('button', { class: 'library-book-menu', type: 'button', 'aria-label': tr("《{0}》书籍菜单", [b.title || tr('未命名')]), 'aria-haspopup': 'dialog', onclick: (e) => showBook(b.id, e.currentTarget) }, icon('more')));
  }
  grid.addEventListener('focusout', () => setTimeout(() => { if (pendingRender && !signal.aborted) render(); }, 0));
  hero.addEventListener('focusout', () => setTimeout(() => { if (pendingRender && !signal.aborted) render(); }, 0));
  async function load() {
    if (signal.aborted) return;
    if (loading) return loading;
    clearTimeout(timer);
    loading = (async () => {
      books = await api.books({ signal });
      if (signal.aborted) return;
      loaded = true; render();
      if (canReachLibrary()) showNotice(''); else networkState();
    })();
    try { await loading; }
    finally { loading = null; if (!signal.aborted && books.some((b) => ['running', 'queued', 'finalizing'].includes(b.status?.state))) timer = setTimeout(refresh, 15000); }
  }
  async function refresh() {
    try { await load(); } catch (e) { if (!signal.aborted) { showNotice(tr("书架暂时未能更新：{0}。现有书籍仍可打开。", [e.message])); clearTimeout(timer); timer = setTimeout(refresh, 30000); } }
  }
  function closeDialog() { if (dialog) { const old = dialog; dialog = null; old.close(); old.remove(); } }
  function showBook(id, trigger) {
    closeDialog();
    const b = normalized().find((row) => row.id === id); if (!b) return;
    const [cls, label] = aiState(b.status),
      idle = (standalone || !b.auto) && ['idle', 'error', 'paused', undefined].includes(b.status?.state),
      activeJob = ['queued', 'running', 'finalizing', 'cancelling'].includes(b.status?.state),
      retry = b.status?.state === 'done' && qualityPending(b.status);
    const message = h('p', { class: 'library-action-message', role: 'status', 'aria-live': 'polite' });
    const modal = h('dialog', { class: 'library-dialog', 'aria-labelledby': 'library-dialog-title' });
    const download = h('button', { class: 'library-action', 'data-download': id, type: 'button', disabled: downloading.has(id), onclick: async () => {
      if (downloading.has(id)) return;
      downloading.add(id); download.disabled = true; message.textContent = tr('正在准备下载…');
      try {
        await downloadBook(id, (n, total) => { if (modal.isConnected) message.textContent = tr("正在下载 {0}/{1} 项；离开书架会暂停，可稍后继续。", [n, total]); }, signal);
        const raw = books.find((row) => row.id === id); if (raw) raw.offline = true;
        download.textContent = tr('重新下载最新资料'); message.textContent = tr('已下载到本机。正文、插图和现有资料均可离线使用。'); render();
      } catch (e) { if (!signal.aborted && modal.isConnected) message.textContent = e.message; }
      finally { downloading.delete(id); download.disabled = false; const current = root.querySelector(`[data-download="${id}"]`); if (current) current.disabled = false; }
    } }, h('span', {}, b.offline ? tr('更新本机下载') : tr('下载到本机')), h('small', {}, b.offline ? tr('保留当前下载，完整更新后再替换') : tr('保存正文、插图和现有人物资料')));
    const modalChildren = [h('div', { class: 'library-dialog-head' }, h('h2', { id: 'library-dialog-title' }, b.title || tr('未命名')), h('button', { class: 'library-dialog-close', type: 'button', 'aria-label': tr('关闭书籍菜单'), onclick: closeDialog }, icon('close'))),
      h('p', { class: 'library-dialog-meta' }, [b.author, size(b), readingLabel(b)].filter(Boolean).join(' · ')),
      b.thin ? h('p', { class: 'library-thin' }, tr("这本书只有 {0}，可能是试读片段。", [size(b)])) : null,
      h('a', { class: 'btn zhu library-dialog-read', href: `#/read/${id}` }, b.reading.state === 'unread' ? tr('开始阅读') : tr('打开阅读'), icon('chev')),
      h('a', { class: 'library-action', href: `#/read/${id}?panel=notebook` }, h('span', {}, tr('我的摘记')), h('small', {}, tr('回到书签、原文摘录和自己的笔记'))),
      h('button', { class: 'library-action', type: 'button', onclick: async (event) => {
        const button = event.currentTarget; button.disabled = true;
        try { await addToReadingList(id); if (!signal.aborted && modal.isConnected) { message.replaceChildren(tr('已放入“接下来读”。'), h('a', { class: 'linkish', href: '#/next' }, tr('查看书单顺序'))); } }
        catch (error) { if (!signal.aborted && modal.isConnected) message.textContent = error.message; }
        finally { button.disabled = false; }
      } }, h('span', {}, tr('加入接下来读')), h('small', {}, tr('给想读的书排个顺序'))),
      h('h3', {}, tr('随身带走')), standalone ? null : download,
      h('a', { class: 'library-action', href: `/api/books/${id}/export` }, h('span', {}, tr('导出完整备份')), h('small', {}, tr('正文、插图、进度及现有整理资料，一起存成文件'))),
      h('h3', { class: 'library-ai-heading' }, tr('人物与关系')), h('p', { class: 'library-ai-description' }, h('span', { class: `ai-dot ${cls}` }), label),
      b.status?.state === 'error' && b.status.error ? h('p', { class: 'library-ai-error', role: 'status' }, tr("AI 整理停下了：{0}", [b.status.error])) : null,
      b.status?.refused?.length ? h('p', { class: 'library-ai-error', role: 'status' }, tr("模型拒绝处理其中 {0} 段（通常是内容审核），已跳过；这些段落里的人物信息可能缺失。换一个模型可以避免。", [b.status.refused.length])) : null,
      activeJob && b.status?.notice ? h('p', { class: 'library-ai-error', role: 'status' }, b.status.notice) : null,
      localSettings && /模型设置|API 密钥|HTTP 40[0-4]/.test(b.status?.error || '') ? h('a', { class: 'library-action', href: '#/settings' }, h('span', {}, tr('模型设置')), h('small', {}, tr('填写或检查 API 密钥、接口地址和模型名'))) : null,
      h('p', { class: 'library-ai-explanation' }, retry ? tr('部分资料仍待核对；正文可以照常阅读。重试可能产生费用。') : tr('资料只显示到当前页。往回翻，它也会回退；每条线索都能回到原文核对。')),
      idle || retry ? h('button', { class: 'library-action', type: 'button', 'aria-label': retry ? tr('重试待核对资料') : tr('开始整理人物'), onclick: async (e) => {
        const button = e.currentTarget;
        const detail = retry ? tr('将重新处理待核对资料，可能产生费用。已有资料仍可阅读。') : `${size(b)}，${estimate(b)}。`;
        if (!confirm(tr("{0}：《{1}》？\n{2}\n按当前模型 {3} 估算，实际耗时和费用可能不同。AI 结果可能有误。", [retry ? tr('重试待核对资料') : tr('开始整理人物'), b.title, detail, b.est?.model || tr('配置')]))) return;
        button.disabled = true; message.textContent = tr('正在提交整理任务…');
        try {
          await api.process(id, { signal });
          if (!signal.aborted) {
            message.textContent = tr('已提交。可以先开始阅读，整理进度会在书架更新。');
            try { await load(); }
            catch {
              // The worker may be running even when the follow-up shelf refresh is busy.
              message.textContent = tr('任务已提交；书架暂时未能刷新，稍后会自动更新。');
              clearTimeout(timer); timer = setTimeout(refresh, 10000);
            }
          }
        }
        catch (e) {
          if (signal.aborted) return;
          message.replaceChildren(e.message, localSettings && /模型设置/.test(e.message) ? h('a', { class: 'linkish', href: '#/settings' }, ` ${tr('去填写')}`) : '');
          button.disabled = false;
        }
      } }, h('span', {}, retry ? tr('重试待核对资料') : tr('开始整理人物')), h('small', {}, retry ? tr('会重新调用模型；需确认后开始') : estimate(b))) : null,
      activeJob ? h('button', { class: 'library-action', type: 'button', disabled: b.status?.state === 'cancelling', onclick: async (event) => {
        if (!confirm(tr("暂停整理《{0}》？已保存的段落可以在下次继续。", [b.title]))) return;
        const button = event.currentTarget; button.disabled = true; message.textContent = tr('正在暂停，当前模型请求结束后会停下…');
        try { await api.cancelProcess(id, { signal, timeout: 20000 }); await load();
          if (!signal.aborted) message.textContent = books.find((row) => row.id === id)?.status?.state === 'cancelling'
            ? tr('正在等待当前模型请求结束，然后会暂停。') : tr('已暂停，下次可以从保存的位置继续。');
        } catch (error) { if (!signal.aborted) { message.textContent = error.message; button.disabled = false; } }
      } }, h('span', {}, b.status?.state === 'cancelling' ? tr('正在暂停') : tr('暂停整理')),
      h('small', {}, tr('当前段落处理完后停止；已保存的进度会保留'))) : null,
      message,
      h('details', { class: 'library-delete' }, h('summary', {}, tr('移除书籍')), h('p', {}, standalone ? tr('会从这台手机移除正文和人物资料。需要留存时，请先导出完整备份。') : tr('会从所有设备的书架移除正文和人物资料。需要留存时，请先导出完整备份。')),
        h('button', { type: 'button', onclick: async (e) => {
          if (!confirm(tr("从书架移除《{0}》？\n正文和已经整理的资料会一起移除。请确认已经保存需要的备份。", [b.title]))) return;
          const button = e.currentTarget; button.disabled = true;
          try { await api.remove(id, { signal }); if (signal.aborted) return; navigator.serviceWorker?.controller?.postMessage({ type: 'remove-book', id }); closeDialog(); books = books.filter((row) => row.id !== id); render(); toast(tr('已从书架移除')); }
          catch (e) { if (!signal.aborted) { message.textContent = e.message; button.disabled = false; } }
        } }, tr('确认移除这本书')))];
    const aiStart = modalChildren.findIndex((child) => child?.classList?.contains('library-ai-heading'));
    const aiEnd = modalChildren.indexOf(message) + 1;
    modalChildren.splice(4, 0, ...modalChildren.splice(aiStart, aiEnd - aiStart));
    modal.append(...modalChildren.filter((child) => child != null));
    modal.addEventListener('click', (event) => { if (event.target === modal) { const bounds = modal.getBoundingClientRect(); if (event.clientX < bounds.left || event.clientX > bounds.right || event.clientY < bounds.top || event.clientY > bounds.bottom) closeDialog(); } });
    modal.addEventListener('close', () => { if (dialog === modal) dialog = null; modal.remove(); if (!signal.aborted && trigger.isConnected) trigger.focus(); });
    root.append(modal); dialog = modal; modal.showModal();
  }
  function persistReceipts(force = false) {
    if (signal.aborted && !force) return;
    const active = receipts.filter((row) => ['queued', 'uploading'].includes(row.state));
    const settled = receipts.filter((row) => !['queued', 'uploading'].includes(row.state)).slice(-(100 - active.length) || receipts.length);
    const keep = new Set([...active, ...settled]); receipts = receipts.filter((row) => keep.has(row));
    const keys = new Set(receipts.map((row) => row.key)); for (const key of importFiles.keys()) if (!keys.has(key)) importFiles.delete(key);
    if (!store.set(RECEIPTS_KEY, receipts)) showNotice(tr('本机存储空间不足，导入记录暂时无法保存；已经导入的书不受影响。'));
  }
  function renderImports() {
    if (signal.aborted) return;
    importPanel.hidden = !receipts.length;
    const activeCount = receipts.filter((row) => ['uploading', 'queued'].includes(row.state)).length;
    const needsAttention = receipts.some((row) => ['failed', 'interrupted'].includes(row.state));
    importPanel.replaceChildren(h('details', { class: 'library-import-history', open: activeCount || needsAttention ? true : null },
      h('summary', {}, activeCount ? tr("正在导入 · 剩余 {0} 本", [activeCount]) : tr("导入记录 · {0} 本", [receipts.length])),
      h('div', { class: 'library-import-history-body' },
      h('button', { class: 'linkish', type: 'button', disabled: importsRunning, onclick: () => { receipts = []; importFiles.clear(); persistReceipts(); renderImports(); } }, tr('清空记录')),
      h('p', { class: 'library-import-help' }, tr('导入后即可阅读；整理人物需要另行确认。')),
      h('ul', {}, receipts.slice().reverse().map((row) => h('li', { class: `library-import-row is-${row.state}` },
        h('div', {}, h('strong', {}, row.title || row.name), h('p', { role: row.state === 'uploading' ? 'status' : undefined }, row.message || ({ queued: tr('等待导入'), uploading: tr('正在上传…'), done: tr('已导入'), failed: tr('导入未完成'), interrupted: tr('需要重新选择文件') }[row.state] || tr('导入记录')))),
        row.state === 'done' && row.bookId ? h('a', { class: 'btn', href: `#/read/${row.bookId}` }, tr('打开阅读'))
          : ['failed', 'interrupted'].includes(row.state) ? h('button', { class: 'btn', type: 'button', disabled: importsRunning, onclick: () => {
            if (importFiles.has(row.key)) {
              if (!confirm(tr('请先确认书架中没有刚刚导入的这本书。重新提交相同文件会复用同一本书，不会覆盖不同资料。继续重试？'))) return;
              row.state = 'queued'; row.message = tr('等待重试'); persistReceipts(); renderImports(); runImports();
            } else pickFiles();
          } }, importFiles.has(row.key) ? tr('重试') : tr('重新选文件')) : h('span', { class: 'library-import-stage' }, row.state === 'queued' ? tr('排队中') : tr('进行中'))))))));
  }
  async function runImports() {
    if (importsRunning) return;
    importsRunning = true; renderImports();
    try {
      for (const row of receipts.filter((item) => item.state === 'queued')) {
        if (signal.aborted) break;
        const selected = importFiles.get(row.key); if (!selected) continue;
        row.state = 'uploading'; row.message = tr('正在上传…'); persistReceipts(); renderImports();
        try {
          const result = selected.name.toLowerCase().endsWith('.json') ? await api.restore(selected, { signal }) : await api.upload(selected, (p) => {
            row.message = p >= 1 ? tr('文件已送达，正在解析…') : tr("正在上传 {0}%", [Math.round(p * 100)]);
            renderImports();
          }, { signal });
          row.state = 'done'; row.bookId = result.id; row.title = result.title || selected.name;
          row.message = selected.name.toLowerCase().endsWith('.json') ? tr('书籍及备份中的资料已恢复') : tr('已导入，现在就能开始阅读');
          importFiles.delete(row.key);
          if (!signal.aborted) { const at = books.findIndex((b) => b.id === result.id); if (at >= 0) books[at] = result; else books.unshift(result); loaded = true; render(); }
        } catch (e) { row.state = signal.aborted ? 'interrupted' : 'failed'; row.message = signal.aborted ? tr('导入未收到完成确认，请先检查书架，再重新选择文件。') : tr("{0}；如连接中断，请先检查书架再重试。", [e.message]); }
        persistReceipts(); renderImports();
      }
    } finally { importsRunning = false; persistReceipts(); renderImports(); if (!signal.aborted) { refresh(); if (receipts.some((row) => row.state === 'queued')) runImports(); } }
  }
  file.addEventListener('change', () => {
    const selected = [...file.files]; file.value = ''; if (!selected.length) return;
    // Keep in-flight entries when trimming the bounded receipt log.
    const capacity = Math.max(0, 100 - receipts.filter((row) => ['queued', 'uploading'].includes(row.state)).length);
    const accepted = selected.slice(0, capacity);
    if (accepted.length < selected.length) toast(tr('一次最多保留 100 个导入任务，请等当前队列完成后继续。'), 6000);
    for (const item of accepted) { const key = `${Date.now()}-${Math.random()}`; importFiles.set(key, item); receipts.push({ key, name: item.name, time: Date.now(), state: 'queued', message: tr('等待导入') }); }
    persistReceipts(); renderImports(); importPanel.scrollIntoView({ behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth', block: 'start' }); runImports();
  });
  const onStorage = (event) => { if (event.key?.startsWith('resume:')) render(); };
  const onOnline = () => { networkState(); refresh(); };
  const onOffline = () => networkState();
  addEventListener('storage', onStorage); addEventListener('online', onOnline); addEventListener('offline', onOffline);
  navigator.serviceWorker?.addEventListener('controllerchange', onOnline);
  signal.addEventListener('abort', () => {
    clearTimeout(timer); closeDialog(); navigator.serviceWorker?.removeEventListener('controllerchange', onOnline); removeEventListener('storage', onStorage); removeEventListener('online', onOnline); removeEventListener('offline', onOffline);
    for (const row of receipts) if (['uploading', 'queued'].includes(row.state)) { row.state = 'interrupted'; row.message = tr('离开书架时导入尚未确认，请先检查书架，再重新选择文件。'); }
    persistReceipts(true); importFiles.clear();
  }, { once: true });
  render(); renderImports(); networkState();
  try { await load(); }
  catch (e) {
    if (signal.aborted || e instanceof AuthError) throw e;
    count.textContent = tr('暂时无法连接书房');
    grid.replaceChildren(h('div', { class: 'library-empty' }, h('h3', {}, tr('书架暂时没能打开')), h('p', {}, e.message),
      h('button', { class: 'btn primary', type: 'button', onclick: () => refresh() }, tr('重新连接'))));
  }
}
