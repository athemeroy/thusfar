import { canReachLibrary } from './runtime.js';
// Cross-book personal workspace. Loading and source inspection never write reading progress.
import { api, AuthError } from './api.js';
import { Notebook, mergeNotes } from './notebook.js';
import { sourcePreviewParts } from './source-preview.js';
import { h, icon } from './util.js';
import { currentLanguage, localizeServerMessage, t as tr } from './i18n.js';

const ID = /^[A-Za-z0-9_-]+$/;
export const HUB_LIMITS = Object.freeze({ concurrency: 3, page: 40, perBook: 1000, notes: 20000, textUnits: 8_000_000 });
const normalize = (value) => String(value || '').normalize('NFKC').toLocaleLowerCase();
const timestamp = (note) => Number.isFinite(note.updated) ? note.updated : 0;
const noteUnits = (n) => n.quote.length + n.text.length + (n.conflict?.item?.quote?.length || 0) + (n.conflict?.item?.text?.length || 0);
export function validHubNote(n) {
  return !!n && typeof n.id === 'string' && ID.test(n.id) && ['note', 'bookmark'].includes(n.kind)
    && Number.isSafeInteger(n.start) && n.start >= 0 && Number.isSafeInteger(n.end) && n.end >= n.start
    && typeof n.quote === 'string' && n.quote.length <= 8000 && typeof n.text === 'string' && n.text.length <= 20000
    && Number.isSafeInteger(n.revision ?? 0) && (n.revision ?? 0) >= 0;
}
export function mergeHubNotes(local, remote) {
  if (!Array.isArray(local) || !Array.isArray(remote) || local.some((n) => !validHubNote(n)) || remote.some((n) => !validHubNote(n))) throw new Error(tr('摘记数据格式不完整，请在书内检查后重试'));
  return mergeNotes(local, remote).filter((n) => !n.deleted || n.conflict)
    .sort((a, b) => Number(!!b.dirty) - Number(!!a.dirty) || timestamp(b) - timestamp(a) || a.start - b.start);
}
export function filterHubNotes(states, { query = '', book = '', kind = '', sync = '' } = {}) {
  const terms = normalize(query).trim().split(/\s+/).filter(Boolean);
  const rows = [];
  for (const state of states) {
    if (book && state.book.id !== book) continue;
    for (const note of state.notes) {
      if (kind && note.kind !== kind || sync === 'pending' && !note.dirty || sync === 'conflict' && !note.conflict) continue;
      const searchable = normalize(`${state.book.title} ${state.book.author || ''} ${note.quote} ${note.text} ${note.conflict?.item?.quote || ''} ${note.conflict?.item?.text || ''}`);
      if (terms.every((term) => searchable.includes(term))) rows.push({ book: state.book, note, phase: state.phase });
    }
  }
  return rows.sort((a, b) => timestamp(b.note) - timestamp(a.note) || a.book.id.localeCompare(b.book.id) || a.note.start - b.note.start);
}

/** Owns at most three GETs and a bounded, read-only projection of notebook data. */
export class NotebookHubLoader {
  constructor({ books, readLocal, loadRemote, onChange = () => {}, signal }) {
    this.readLocal = readLocal; this.loadRemote = loadRemote; this.onChange = onChange;
    this.states = new Map(); this.active = new Map(); this.paused = false; this.stopped = false; this.waiters = [];
    for (const book of books) if (book && ID.test(book.id || '') && !book.hidden && !this.states.has(book.id)) {
      this.states.set(book.id, { book, phase: 'pending', notes: [], remote: [], error: '', partial: false, omitted: 0 });
    }
    for (const state of this.states.values()) this.reconcile(state);
    this.signal = signal;
    this.abort = () => this.destroy();
    signal?.addEventListener('abort', this.abort, { once: true });
    if (signal?.aborted) this.destroy();
  }
  reconcile(state) {
    try {
      const rows = mergeHubNotes(this.readLocal(state.book), state.remote);
      let usedNotes = 0, usedUnits = 0;
      for (const other of this.states.values()) if (other !== state) for (const n of other.notes) { usedNotes++; usedUnits += noteUnits(n); }
      const selected = [];
      for (const note of rows) {
        const units = noteUnits(note);
        if (selected.length >= HUB_LIMITS.perBook || usedNotes >= HUB_LIMITS.notes || usedUnits + units > HUB_LIMITS.textUnits) break;
        selected.push(note); usedNotes++; usedUnits += units;
      }
      state.notes = selected; state.omitted = Math.max(state.remoteOmitted || 0, rows.length - selected.length); state.partial = state.omitted > 0; state.remoteOmitted = state.omitted;
      // Keep only the bounded projection. The original durable local notebook is never changed.
      state.remote = selected.filter((n) => !n.dirty);
    } catch (error) { state.error = error.message; state.phase = 'unavailable'; }
  }
  emit() { if (!this.stopped) this.onChange([...this.states.values()]); }
  start() { this.paused = false; this.pump(); return this.idle(); }
  pump() {
    if (this.stopped || this.paused) return this.finishIdle();
    for (const state of this.states.values()) {
      if (this.active.size >= HUB_LIMITS.concurrency) break;
      if (state.phase !== 'pending') continue;
      const controller = new AbortController(); this.active.set(state.book.id, controller);
      state.phase = 'loading'; state.error = ''; this.emit();
      Promise.resolve().then(() => { if (controller.signal.aborted) throw new DOMException(tr('已取消'), 'AbortError'); return this.loadRemote(state.book.id, controller.signal); }).then((response) => {
        if (this.stopped || controller.signal.aborted) return;
        if (!Array.isArray(response?.items) || response.items.some((n) => !validHubNote(n))) throw new Error(tr('摘记响应不完整，请重试'));
        state.remote = response.items; state.remoteOmitted = 0; state.phase = 'loaded'; state.offline = !!response.offline || (typeof navigator !== 'undefined' && !canReachLibrary());
        this.reconcile(state);
      }).catch((error) => {
        if (this.stopped) return;
        if (controller.signal.aborted) { state.phase = 'pending'; return; }
        state.phase = 'unavailable'; state.error = error.message || tr('暂时无法取得摘记'); this.reconcile(state);
      }).finally(() => {
        this.active.delete(state.book.id);
        if (!this.stopped) { this.emit(); this.pump(); }
        this.finishIdle();
      });
    }
    this.finishIdle();
  }
  retry(id) {
    const state = this.states.get(id);
    if (!state || this.active.has(id) || this.stopped) return;
    state.phase = 'pending'; state.error = ''; this.paused = false; this.pump();
  }
  refreshLocal(id) { const state = this.states.get(id); if (state && !this.stopped) { this.reconcile(state); this.emit(); } }
  pause() { this.paused = true; for (const controller of this.active.values()) controller.abort(); this.emit(); this.finishIdle(); }
  idle() { if (!this.active.size && (this.paused || this.stopped || ![...this.states.values()].some((s) => s.phase === 'pending'))) return Promise.resolve(); return new Promise((resolve) => this.waiters.push(resolve)); }
  finishIdle() { if (!this.active.size && (this.paused || this.stopped || ![...this.states.values()].some((s) => s.phase === 'pending'))) while (this.waiters.length) this.waiters.pop()(); }
  destroy() { this.stopped = true; this.signal?.removeEventListener('abort', this.abort); for (const c of this.active.values()) c.abort(); this.finishIdle(); }
}

export function validateHubQuote(note, book, chapter) {
  if (!validHubNote(note) || !Number.isSafeInteger(book?.len) || note.start >= book.len || note.end > book.len) throw new Error(tr('摘记位置与当前正文不一致，请先打开本书摘记核对'));
  if (!Array.isArray(chapter?.blocks)) throw new Error(tr('原文暂时不完整'));
  if (note.quote) {
    const block = chapter.blocks.find((b) => typeof b.t === 'string' && Number.isSafeInteger(b.o) && b.o <= note.start && note.end <= b.o + b.t.length);
    if (!block || block.t.slice(note.start - block.o, note.end - block.o) !== note.quote) throw new Error(tr('保存的摘录与当前原文不一致，未跳到可能错误的位置'));
  }
  return sourcePreviewParts(chapter, { start: note.start, end: Math.max(note.start + 1, note.end), cutoff: book.len });
}
function dateLabel(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0 || seconds > 8_640_000_000_000) return tr('保存时间未记录');
  return new Intl.DateTimeFormat(currentLanguage(), { month: 'short', day: 'numeric', year: 'numeric' }).format(new Date(seconds * 1000));
}

export async function openNotebookHub(root, { signal } = {}) {
  root.replaceChildren();
  let loader, disposed = false, dialog = null, dialogRequest = null, page = 1, currentRows = [];
  const filters = { query: '', book: '', kind: '', sync: '' };
  const title = h('header', { class: 'nh-header' }, h('div', {}, h('p', { class: 'nh-eyebrow' }, tr('把读过的，留给自己')), h('h1', {}, tr('全部个人摘记')), h('p', { class: 'nh-intro' }, tr('从不同的书里，找回同一个念头。'))), h('a', { href: '#/', class: 'nh-back' }, icon('back'), tr('回书房')));
  const notice = h('p', { class: 'nh-scope' }, h('strong', {}, tr('全部个人摘记 · 包含后文想法')), h('span', {}, tr('这里汇集书架中各本书的书签、摘录和想法，不按当前阅读页截断。浏览和预览不会改变阅读进度。')));
  const search = h('input', { type: 'search', maxlength: 200, placeholder: tr('搜一句原文、一个想法，或一本书'), 'aria-label': tr('搜索全部个人摘记') });
  const bookSelect = h('select', { 'aria-label': tr('按书籍筛选') }, h('option', { value: '' }, tr('所有书籍')));
  const kindSelect = h('select', { 'aria-label': tr('按摘记类型筛选') }, h('option', { value: '' }, tr('所有类型')), h('option', { value: 'note' }, tr('摘录与想法')), h('option', { value: 'bookmark' }, tr('书签')));
  const syncSelect = h('select', { 'aria-label': tr('按同步状态筛选') }, h('option', { value: '' }, tr('所有同步状态')), h('option', { value: 'pending' }, tr('待同步')), h('option', { value: 'conflict' }, tr('待处理冲突')));
  const count = h('p', { class: 'nh-count', role: 'status', 'aria-live': 'polite' }, tr('正在打开你的书房…'));
  const loadStatus = h('span', {}, tr('准备读取书架'));
  const pause = h('button', { type: 'button', class: 'nh-link', hidden: true }, tr('暂停加载'));
  const loadRows = h('div', { class: 'nh-load-rows' });
  const loadDetails = h('details', { class: 'nh-loading' }, h('summary', {}, loadStatus), h('p', {}, tr('先显示本机已保存的内容，再逐本读取。未能取得的书籍会单独标出，不计作“没有摘记”。')), pause, loadRows);
  const list = h('div', { class: 'nh-cards', 'aria-label': tr('全部个人摘记列表') });
  const previous = h('button', { type: 'button', class: 'btn', hidden: true }, tr('上一页'));
  const next = h('button', { type: 'button', class: 'btn', hidden: true }, tr('下一页'));
  const pageLabel = h('span', {});
  const paging = h('nav', { class: 'nh-paging', 'aria-label': tr('摘记分页') }, previous, pageLabel, next);
  const shell = h('main', { class: 'notebook-hub paper-grain' }, title, notice,
    h('div', { class: 'nh-tools' }, h('label', { class: 'nh-search' }, icon('search'), search), h('div', { class: 'nh-filters' }, bookSelect, kindSelect, syncSelect)),
    h('div', { class: 'nh-results-head' }, count), loadDetails, list, paging);
  root.append(shell);
  function closeDialog() { dialogRequest?.abort(); dialogRequest = null; if (dialog) { dialog.close(); dialog.remove(); dialog = null; } }
  const storageChanged = (e) => { if (e.key?.startsWith('notebook:')) loader?.refreshLocal(e.key.slice(9)); };
  const notebookChanged = (e) => loader?.refreshLocal(e.detail);
  const cleanup = () => { disposed = true; loader?.destroy(); closeDialog(); removeEventListener('storage', storageChanged); removeEventListener('yedu-notebook', notebookChanged); signal?.removeEventListener('abort', cleanup); };
  signal?.addEventListener('abort', cleanup, { once: true });
  if (signal?.aborted) { cleanup(); return; }
  addEventListener('storage', storageChanged); addEventListener('yedu-notebook', notebookChanged);
  function filterChanged() { filters.query = search.value; filters.book = bookSelect.value; filters.kind = kindSelect.value; filters.sync = syncSelect.value; page = 1; render(); }
  search.addEventListener('input', filterChanged);
  for (const select of [bookSelect, kindSelect, syncSelect]) select.addEventListener('change', filterChanged);
  previous.addEventListener('click', () => { page--; render(); count.scrollIntoView({ block: 'start' }); });
  next.addEventListener('click', () => { page++; render(); count.scrollIntoView({ block: 'start' }); });
  pause.addEventListener('click', () => { if (loader.paused) loader.start(); else loader.pause(); render(); });
  function render() {
    if (disposed || !loader) return;
    const states = [...loader.states.values()];
    const loaded = states.filter((s) => s.phase === 'loaded').length, unavailable = states.filter((s) => s.phase === 'unavailable').length;
    const pending = states.filter((s) => ['pending', 'loading'].includes(s.phase)).length;
    const partial = states.filter((s) => s.partial).length;
    currentRows = filterHubNotes(states, filters);
    const pages = Math.max(1, Math.ceil(currentRows.length / HUB_LIMITS.page)); page = Math.max(1, Math.min(page, pages));
    count.textContent = tr("{0} 条{1}个人摘记{2}", [currentRows.length, filters.query || filters.book || filters.kind || filters.sync ? tr('匹配的') : tr('已载入的'), pending || unavailable || partial ? tr(' · 仍有未载入的内容') : '']);
    loadStatus.textContent = tr("{0} / {1} 本已读取{2}{3}{4}", [loaded, states.length, pending ? tr(" · {0} {1} 本", [loader.paused ? tr('已暂停，剩余') : tr('正在载入'), pending]) : '', unavailable ? tr(" · {0} 本暂不可用", [unavailable]) : '', partial ? tr(" · {0} 本显示部分摘记", [partial]) : '']);
    pause.hidden = pending === 0; pause.textContent = loader.paused ? tr('继续加载') : tr('暂停加载');
    loadRows.replaceChildren(...states.map((state) => {
      const text = state.phase === 'loaded' ? tr("{0} 条{1}", [state.notes.length, state.offline ? tr(' · 来自离线保存') : '']) : state.phase === 'unavailable' ? tr("暂不可用{0}", [state.notes.length ? tr(" · 先显示本机 {0} 条", [state.notes.length]) : tr(' · 未确认是否有摘记')]) : state.phase === 'loading' ? tr('读取中…') : loader.paused ? tr('已暂停') : tr('等待读取');
      return h('div', { class: 'nh-load-row' }, h('div', {}, h('strong', {}, state.book.title || tr('未命名')), h('span', {}, text), state.error ? h('small', {}, localizeServerMessage(state.error)) : null,
        state.partial ? h('small', {}, tr("摘记较多，跨书查看先保留近期 {0} 条；可在本书摘记查看其余内容。", [state.notes.length])) : null),
        state.phase === 'unavailable' ? h('button', { type: 'button', class: 'nh-link', onclick: () => loader.retry(state.book.id) }, tr('重试')) : null,
        state.partial ? h('a', { href: `#/read/${state.book.id}?panel=notebook`, class: 'nh-link' }, tr('打开本书摘记')) : null);
    }));
    const focusedCard = list.contains(document.activeElement) ? document.activeElement.closest('[data-note]') : null;
    const restoreFocus = focusedCard ? [focusedCard.dataset.book, focusedCard.dataset.note] : null;
    list.replaceChildren(...currentRows.slice((page - 1) * HUB_LIMITS.page, page * HUB_LIMITS.page).map(card));
    if (restoreFocus) list.querySelector(`[data-book="${restoreFocus[0]}"][data-note="${restoreFocus[1]}"] .nh-preview-button`)?.focus({ preventScroll: true });
    if (!currentRows.length) list.append(h('section', { class: 'nh-empty' }, h('h2', {}, pending ? tr('先让书页上的痕迹聚到一起') : unavailable ? tr('这次还没能取得摘记') : filters.query || filters.book || filters.kind || filters.sync ? tr('没有找到匹配的摘记') : tr('留下一句原文，也留住一个念头')),
      h('p', {}, pending ? tr('正在逐本读取，已保存的内容会陆续出现。') : unavailable ? tr('上方列出了暂时不可用的书籍，联网后可以重试。') : filters.query || filters.book || filters.kind || filters.sync ? tr('试试其他词语，或放宽筛选范围。搜索只覆盖已载入的内容。') : tr('阅读时点「摘录」或「摘记」，这里会收集你在每本书里留下的内容。')), h('a', { href: '#/', class: 'btn' }, tr('回书房选一本书'))));
    previous.hidden = page <= 1; next.hidden = page >= pages; pageLabel.textContent = currentRows.length ? tr("第 {0} / {1} 页", [page, pages]) : '';
  }
  function card({ book, note }) {
    return h('article', { class: 'nh-card', 'data-book': book.id, 'data-note': note.id },
      h('div', { class: 'nh-card-meta' }, h('span', { class: 'nh-book' }, book.title || tr('未命名')), h('span', {}, note.kind === 'bookmark' ? tr('书签') : note.quote ? tr('摘录与想法') : tr('想法'))),
      note.quote ? h('blockquote', {}, note.quote) : null,
      note.text ? h('p', { class: 'nh-thought' }, note.text) : note.kind === 'bookmark' ? h('p', { class: 'nh-bookmark' }, tr('给这一页，留一个再见的记号。')) : null,
      note.conflict ? h('div', { class: 'nh-conflict' }, h('strong', {}, tr('另一设备也有修改')), h('p', {}, tr('本机内容仍保留。打开本书摘记，可选择两份都保留或使用另一版本。'))) : null,
      h('footer', {}, h('div', { class: 'nh-badges' }, h('time', {}, dateLabel(note.updated)), note.dirty ? h('span', {}, tr('待同步')) : null, note.conflict ? h('span', {}, tr('待处理冲突')) : null),
        h('button', { type: 'button', class: 'nh-preview-button', onclick: (e) => preview(book, note, e.currentTarget) }, tr('查看原文'), icon('chev'))));
  }
  async function preview(summary, note, opener) {
    closeDialog();
    const request = new AbortController(); dialogRequest = request;
    const body = h('div', { class: 'nh-preview-body' }, h('p', {}, tr('正在取出原文…')));
    const status = h('p', { class: 'nh-preview-status', role: 'status' });
    const actions = h('div', { class: 'nh-preview-actions' }, h('a', { class: 'btn', href: `#/read/${summary.id}?panel=notebook` }, tr('打开摘记')));
    const modal = h('dialog', { class: 'nh-dialog', 'aria-labelledby': 'nh-dialog-title' },
      h('div', { class: 'nh-dialog-head' }, h('h2', { id: 'nh-dialog-title' }, summary.title || tr('原文预览')), h('button', { type: 'button', 'aria-label': tr('关闭原文预览'), onclick: closeDialog }, icon('close'))),
      h('p', { class: 'nh-preview-scope' }, tr('全书个人摘记的原文 · 可能包含后文。关闭预览会留在这里；转到书中阅读才会更新进度。')), body, status, actions);
    dialog = modal; root.append(modal);
    modal.addEventListener('close', () => { request.abort(); modal.remove(); if (dialog === modal) dialog = null; if (dialogRequest === request) dialogRequest = null; if (!disposed && opener.isConnected) opener.focus({ preventScroll: true }); });
    modal.addEventListener('cancel', (e) => { e.preventDefault(); closeDialog(); });
    modal.addEventListener('click', (e) => { if (e.target === modal) { const r = modal.getBoundingClientRect(); if (e.clientX < r.left || e.clientX > r.right || e.clientY < r.top || e.clientY > r.bottom) closeDialog(); } });
    modal.showModal();
    try {
      const book = await api.book(summary.id, { signal: request.signal, timeout: 12000 });
      if (request.signal.aborted || disposed) return;
      if (book.id !== summary.id || !Array.isArray(book.chapters)) throw new Error(tr('这本书的目录暂时不完整'));
      const n = book.chapters.findIndex((c) => c.o0 <= note.start && note.start < c.o1);
      if (n < 0) throw new Error(tr('找不到摘记对应的原文位置'));
      const chapter = await api.chapter(summary.id, n, { signal: request.signal, timeout: 12000 });
      if (request.signal.aborted || disposed) return;
      if (chapter.o0 !== book.chapters[n].o0 || chapter.o1 !== book.chapters[n].o1) throw new Error(tr('章节版本不一致，请重新打开这本书核对'));
      const result = validateHubQuote(note, book, chapter);
      body.replaceChildren(h('p', { class: 'nh-preview-chapter' }, book.chapters[n].title || tr("第 {0} 节", [n + 1])), ...result.parts.map((part) => h('p', {}, part.before, part.quote ? h('mark', {}, part.quote) : null, part.after)));
      status.textContent = result.selected ? tr('已对照当前正文的位置。预览仅显示附近原文。') : tr('这个位置没有可预览的文字，可能是一幅插图或段落间隔。');
      actions.prepend(h('a', { class: 'btn zhu', href: `#/read/${summary.id}?at=${note.start}` }, tr('转到这里阅读')));
    } catch (error) {
      if (request.signal.aborted || disposed) return;
      body.replaceChildren(note.quote ? h('blockquote', {}, note.quote) : h('p', {}, tr('本机没有这部分原文。')));
      status.textContent = tr("原文暂不可用：{0}。{1}", [error.message, note.quote ? tr('上方保留的是你当时保存的摘录，尚未核对当前正文。') : tr('可以稍后联网重试。')]);
      actions.append(h('button', { type: 'button', class: 'btn', onclick: () => preview(summary, note, opener) }, tr('重试预览')));
    }
  }
  async function loadBooks() {
    try {
      const books = await api.books({ signal, timeout: 15000 });
      if (disposed) return;
      const visible = books.filter((book) => book && ID.test(book.id || '') && !book.hidden);
      bookSelect.replaceChildren(h('option', { value: '' }, tr('所有书籍')), ...visible.map((book) => h('option', { value: book.id }, book.title || tr('未命名'))));
      loader?.destroy();
      loader = new NotebookHubLoader({ books: visible, readLocal: (book) => new Notebook(book).items,
        loadRemote: (id, ownedSignal) => api.notebook(id, { signal: ownedSignal, timeout: 12000 }), onChange: render, signal });
      render(); loader.start();
    } catch (error) {
      if (disposed || signal?.aborted) return;
      if (error instanceof AuthError) { cleanup(); throw error; }
      count.textContent = tr('书架暂时不可用，无法确认本次可查看的书籍。');
      list.replaceChildren(h('section', { class: 'nh-empty' }, h('h2', {}, tr('暂时没有打开书房')), h('p', {}, tr("{0}。本机保存的摘记没有改动。", [error.message])), h('button', { type: 'button', class: 'btn', onclick: () => loadBooks().catch((error) => { if (error instanceof AuthError) location.hash = '#/'; }) }, tr('重新读取书架'))));
    }
  }
  await loadBooks();
  return cleanup;
}
