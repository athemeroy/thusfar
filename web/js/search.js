// Reader-owned literal search. Source positions are UTF-16 units, as in pipeline.parse.
import { api } from './api.js';
import { h, icon, maskTitle } from './util.js';
import { t as tr } from './i18n.js';

export const SEARCH_LIMITS = Object.freeze({ results: 30, chapters: 12, chars: 262144, chunk: 32768, query: 160, milliseconds: 8000 });
const searchDrafts = new WeakMap();
const abortError = () => new DOMException(tr('搜索已取消'), 'AbortError');
function checkAbort(signal) { if (signal?.aborted) throw abortError(); }
function literal(query) { return query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
function safeEnd(text, end) {
  end = Math.max(0, Math.min(text.length, end));
  return end > 0 && end < text.length && /[\uD800-\uDBFF]/.test(text[end - 1]) && /[\uDC00-\uDFFF]/.test(text[end]) ? end - 1 : end;
}
function safeStart(text, start) {
  start = Math.max(0, Math.min(text.length, start));
  return start > 0 && start < text.length && /[\uDC00-\uDFFF]/.test(text[start]) && /[\uD800-\uDBFF]/.test(text[start - 1]) ? start - 1 : start;
}
function nextCharacter(text, at) {
  return at + (at + 1 < text.length && /[\uD800-\uDBFF]/.test(text[at]) && /[\uDC00-\uDFFF]/.test(text[at + 1]) ? 2 : 1);
}
export function visibleChapterTitle(chapter, cutoff, reveal = false, index = 0) {
  if (!chapter) return tr("第 {0} 节", [index + 1]);
  const hidden = !reveal && chapter.o0 >= cutoff && chapter.spoil !== false;
  return hidden ? tr("{0} · 未读", [maskTitle(chapter.title)]) : chapter.title || tr("第 {0} 节", [index + 1]);
}
export function sourceExcerpt(text, start, end, visibleLength, radius = 36) {
  const cap = safeEnd(text, visibleLength), left = safeStart(text, Math.max(0, start - radius)), right = safeEnd(text, Math.min(cap, end + radius));
  return { before: text.slice(left, start), match: text.slice(start, end), after: text.slice(end, right), leading: left > 0, trailing: right < cap };
}
// A cancellation race must not abort a chapter fetch shared with the reading engine.
export async function abortable(promise, signal, timeout = 10000) {
  checkAbort(signal);
  let abort, timer;
  const cancelled = new Promise((_, reject) => {
    abort = () => reject(abortError());
    signal?.addEventListener('abort', abort, { once: true });
    timer = setTimeout(() => reject(new Error(tr('这一章获取超时，可继续搜索'))), timeout);
  });
  try { return await Promise.race([promise, cancelled]); }
  finally { clearTimeout(timer); signal?.removeEventListener('abort', abort); }
}

/** Scan one bounded window, retaining only its results and one chapter at a time.
 * A cursor resumes within a block, so frequent matches and very long chapters do
 * not truncate the book or require an in-memory whole-book search index.
 */
export async function scanBook({ chapters, query, cutoff, loadChapter, cursor, signal, onProgress, limits = {} }) {
  query = String(query || '').trim();
  if (!query || query.length > SEARCH_LIMITS.query) throw new Error(tr("请输入 1–{0} 个字的关键词", [SEARCH_LIMITS.query]));
  if (!Number.isFinite(cutoff) || cutoff < 0) throw new Error(tr('搜索范围无效，请重新打开搜索'));
  const lim = { ...SEARCH_LIMITS, ...limits };
  for (const key of ['results', 'chapters', 'chars', 'chunk', 'milliseconds']) if (!Number.isInteger(lim[key]) || lim[key] < 1 || lim[key] > SEARCH_LIMITS[key]) throw new Error(tr('搜索限制无效'));
  if (!Array.isArray(chapters) || chapters.some((c) => !Number.isSafeInteger(c.o0) || c.o0 < 0)) throw new Error(tr('章节位置无效，请重新打开这本书'));
  const began = performance.now();
  const start = cursor || { chapter: 0, block: 0, offset: 0 };
  for (const key of ['chapter', 'block', 'offset']) if (!Number.isInteger(start[key]) || start[key] < 0) throw new Error(tr('搜索位置无效，请重新搜索'));
  const total = chapters.reduce((n, c) => n + (c.o0 < cutoff ? 1 : 0), 0);
  let chapter = start.chapter, block = start.block, offset = start.offset, checked = 0, chars = 0;
  const results = [];
  const progress = (done = false) => ({ results: [...results], next: done ? null : { chapter, block, offset }, done, checked, total, chapter: Math.min(chapter, chapters.length), chars });
  const publish = () => { checkAbort(signal); onProgress?.(progress()); };
  const yieldNow = () => new Promise((resolve) => setTimeout(resolve, 0));
  while (chapter < chapters.length) {
    checkAbort(signal);
    const meta = chapters[chapter];
    if (meta.o0 >= cutoff) { chapter++; block = offset = 0; continue; }
    if (checked >= lim.chapters || chars >= lim.chars || performance.now() - began >= lim.milliseconds) return progress();
    let data;
    try { data = await abortable(loadChapter(chapter, signal), signal); }
    catch (error) {
      checkAbort(signal);
      const stopped = progress();
      error.search = stopped;
      throw error;
    }
    checkAbort(signal);
    if (!Array.isArray(data?.blocks)) throw new Error(tr('章节内容格式不正确，请重试'));
    if (data.blocks.some((b) => typeof b.t === 'string' && (!Number.isSafeInteger(b.o) || b.o < meta.o0 || (Number.isSafeInteger(meta.o1) && b.o + b.t.length > meta.o1)))) throw new Error(tr('章节原文位置不一致，请刷新这本书后重试'));
    while (block < data.blocks.length) {
      checkAbort(signal);
      const b = data.blocks[block];
      if (typeof b.t !== 'string' || !Number.isFinite(b.o) || b.k === 'img' || b.o >= cutoff) { block++; offset = 0; continue; }
      const end = safeEnd(b.t, Math.min(b.t.length, cutoff - b.o));
      while (offset < end) {
        checkAbort(signal);
        if (chars >= lim.chars || performance.now() - began >= lim.milliseconds) return progress();
        let windowEnd = safeEnd(b.t, Math.min(end, offset + Math.min(lim.chunk, lim.chars - chars)));
        if (windowEnd <= offset) windowEnd = Math.min(end, offset + 2);
        const sliceEnd = safeEnd(b.t, Math.min(end, windowEnd + query.length - 1));
        const text = b.t.slice(offset, sliceEnd), base = offset;
        const re = new RegExp(literal(query), 'giu');
        let match;
        while ((match = re.exec(text))) {
          const local = base + match.index, matchEnd = local + match[0].length;
          if (local >= windowEnd) break;
          results.push({ chapter, start: b.o + local, end: b.o + matchEnd, excerpt: sourceExcerpt(b.t, local, matchEnd, end) });
          if (results.length >= lim.results) {
            const next = nextCharacter(b.t, local);
            chars += next - offset;
            offset = next;
            publish();
            return progress();
          }
          // Resume at the next character: a repeated phrase can start inside this match.
          re.lastIndex = nextCharacter(text, match.index);
        }
        chars += windowEnd - offset;
        offset = windowEnd;
        publish();
        await yieldNow();
      }
      block++; offset = 0;
    }
    chapter++; block = offset = 0; checked++;
    publish();
    await yieldNow();
  }
  checkAbort(signal);
  return progress(true);
}

export function navigationTabs(ctx, active) {
  return h('nav', { class: 'reader-nav-tabs', 'aria-label': tr('书内导航') },
    h('button', { type: 'button', class: active === 'toc' ? 'on' : '', 'aria-current': active === 'toc' ? 'page' : null, onclick: () => ctx.panes.open('toc', undefined, { replace: true }) }, icon('toc'), tr('目录')),
    h('button', { type: 'button', class: active === 'search' ? 'on' : '', 'aria-current': active === 'search' ? 'page' : null, onclick: () => ctx.panes.open('search', undefined, { replace: true, full: true }) }, icon('search'), tr('搜索原文')));
}

export function searchView(ctx, _arg, pane, title) {
  title.append(tr('导航'), h('small', {}, tr('搜索原文')));
  let whole = false, disposed = false, controller = null, sequence = 0, next = null, history = [], currentCursor = null, page = 1;
  const cutoff = ctx.info.cutoff, generation = ctx.generation;
  const input = h('input', { type: 'search', maxlength: SEARCH_LIMITS.query, placeholder: tr('人名、词语，或记得的一句话'), 'aria-label': tr('搜索原文'), enterkeyhint: 'search', autocomplete: 'off' });
  input.value = searchDrafts.get(ctx.book)?.query || '';
  const submit = h('button', { type: 'submit', class: 'btn zhu' }, tr('搜索'));
  const form = h('form', { class: 'reader-search-form' }, input, submit);
  const cancel = h('button', { type: 'button', class: 'reader-search-stop', hidden: true }, tr('暂停搜索'));
  const wholeToggle = h('button', { type: 'button', class: 'switch', role: 'switch', 'aria-label': tr('搜索整本书（包含未读内容）'), 'aria-checked': false });
  const scope = h('p', { class: 'reader-search-scope' }, tr("只搜索截至当前第 {0} 页的原文；回看前文时，范围也会跟着回退。", [ctx.info.global]));
  const state = h('p', { class: 'reader-search-status muted', role: 'status', 'aria-live': 'polite' }, tr('输入关键词，点结果先预览原文，阅读位置会留在这里。'));
  const results = h('ol', { class: 'reader-search-results', 'aria-label': tr('原文搜索结果') });
  const previous = h('button', { type: 'button', hidden: true }, tr('上一组'));
  const more = h('button', { type: 'button', hidden: true }, tr('继续搜索'));
  const paging = h('div', { class: 'reader-search-paging' }, previous, more);
  pane.append(navigationTabs(ctx, 'search'), form,
    h('div', { class: 'set-row reader-search-whole' }, h('label', {}, tr('搜索整本书'), h('small', {}, tr('包含未读内容，可能剧透'))), wholeToggle), scope, state, cancel, results, paging);
  const valid = (token) => !disposed && token === sequence && ctx.current().generation === generation && ctx.current().info.cutoff === cutoff;
  const stop = () => { sequence++; controller?.abort(); controller = null; cancel.hidden = true; submit.disabled = false; };
  ctx.onLeave(() => { disposed = true; stop(); });
  const leave = () => { disposed = true; stop(); };
  ctx.signal?.addEventListener('abort', leave, { once: true });
  ctx.onLeave(() => ctx.signal?.removeEventListener('abort', leave));
  function renderRows(rows) {
    results.replaceChildren(...rows.map((row) => {
      const ex = row.excerpt;
      return h('li', {}, h('button', { type: 'button', onclick: () => ctx.goSource(row.start, row.end) },
        h('span', { class: 'reader-search-location' }, visibleChapterTitle(ctx.book.chapters[row.chapter], cutoff, whole, row.chapter), h('small', {}, tr("第 {0} 页", [ctx.pageNo(row.start)]))),
        h('span', { class: 'reader-search-excerpt' }, ex.leading ? '…' : '', ex.before, h('mark', {}, ex.match), ex.after, ex.trailing ? '…' : '')));
    }));
  }
  function reset() { stop(); next = null; currentCursor = null; history = []; page = 1; previous.hidden = more.hidden = true; results.replaceChildren(); }
  wholeToggle.addEventListener('click', () => {
    reset(); whole = !whole;
    wholeToggle.classList.toggle('on', whole); wholeToggle.setAttribute('aria-checked', String(whole));
    scope.textContent = whole ? tr('已开启全书搜索：结果、章节名和附近原文会包含后文。关闭后恢复当前页范围。') : tr("只搜索截至当前第 {0} 页的原文；回看前文时，范围也会跟着回退。", [ctx.info.global]);
    scope.classList.toggle('spoiler-warning', whole);
    state.textContent = tr('范围已切换，请重新搜索。');
  });
  input.addEventListener('input', () => { reset(); state.textContent = tr('按回车或点“搜索”开始。'); });
  cancel.addEventListener('click', () => { stop(); state.textContent = tr('搜索已暂停。已找到的结果保留，可以继续搜索。'); more.hidden = !next; previous.hidden = history.length === 0; });
  async function run(cursor = null) {
    stop(); const token = sequence, q = input.value.trim();
    if (!q) { input.focus(); state.textContent = tr('请输入想找的词语或句子。'); return; }
    searchDrafts.set(ctx.book, { query: q });
    currentCursor = cursor; next = cursor || { chapter: 0, block: 0, offset: 0 };
    controller = new AbortController(); const pending = controller;
    submit.disabled = true; cancel.hidden = false; previous.hidden = more.hidden = true; results.replaceChildren();
    state.textContent = tr('正在搜索原文…');
    const update = (batch) => {
      if (!valid(token) || pending.signal.aborted) return;
      next = batch.next; renderRows(batch.results);
      state.textContent = tr("已检查到第 {0} 节 · 本组找到 {1} 处", [Math.min(batch.chapter + 1, ctx.book.chapters.length), batch.results.length]);
    };
    try {
      const batch = await scanBook({ chapters: ctx.book.chapters, query: q, cutoff: whole ? ctx.book.len : cutoff, cursor, signal: pending.signal,
        loadChapter: (n, signal) => ctx.reader?.cache?.has(n) ? ctx.reader.cache.get(n) : api.chapter(ctx.book.id, n, { signal, timeout: 10000 }), onProgress: update });
      if (!valid(token) || pending.signal.aborted) return;
      next = batch.next; renderRows(batch.results);
      state.textContent = batch.done ? tr("搜索完成 · 第 {0} 组，{1} 处{2}", [page, batch.results.length, batch.results.length === 0 && page === 1 ? tr('；可以换个关键词试试') : '']) : tr("第 {0} 组 · {1} 处 · 后面还有原文可继续搜索", [page, batch.results.length]);
      more.hidden = !next; previous.hidden = history.length === 0;
    } catch (error) {
      if (!valid(token) || pending.signal.aborted) return;
      if (error.search) { next = error.search.next; renderRows(error.search.results); }
      state.textContent = tr("搜索暂时中断：{0}。已显示的结果仍可打开。", [error.message]);
      more.hidden = !next; more.textContent = tr('重试这一段'); previous.hidden = history.length === 0;
    } finally {
      if (valid(token)) { controller = null; submit.disabled = false; cancel.hidden = true; }
    }
  }
  form.addEventListener('submit', (e) => { e.preventDefault(); reset(); more.textContent = tr('继续搜索'); run(); });
  more.addEventListener('click', () => { if (!next) return; history.push(currentCursor); if (history.length > 100) history.shift(); page++; more.textContent = tr('继续搜索'); run(next); });
  previous.addEventListener('click', () => { if (!history.length) return; const cursor = history.pop(); page--; run(cursor); });
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Escape' && controller) { e.preventDefault(); e.stopPropagation(); cancel.click(); }
  });
}
