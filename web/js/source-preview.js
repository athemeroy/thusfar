// Reading a citation is an inspection. Only the explicit jump commits a new position.
import { api } from './api.js';
import { h } from './util.js';
import { t as tr } from './i18n.js';

const CONTEXT = 240;
const QUOTE_LIMIT = 1200;
const BLOCK_LIMIT = 16;
const integer = (n) => Number.isSafeInteger(n) && n >= 0;
const generation = (ctx) => ctx.generation ?? ctx.book.version ?? `${ctx.book.id}:${ctx.book.len}`;

function boundary(text, at, end = false) {
  at = Math.max(0, Math.min(text.length, at));
  const c = text.charCodeAt(at), before = text.charCodeAt(at - 1);
  // A cutoff through a surrogate pair must not expose a character beyond its boundary.
  if (c >= 0xdc00 && c <= 0xdfff && before >= 0xd800 && before <= 0xdbff) at += end ? -1 : 1;
  return at;
}

// All positions are the existing UTF-16 source offsets, never presentation page numbers.
export function sourcePreviewParts(chapter, { start, end, cutoff }) {
  if (![start, end, cutoff, chapter?.o0, chapter?.o1].every(integer) || end <= start || start >= cutoff || chapter.o1 < chapter.o0) {
    return { parts: [], truncated: false, selected: false };
  }
  const from = Math.max(chapter.o0, start - CONTEXT);
  const to = Math.min(chapter.o1, cutoff, Math.min(end, start + QUOTE_LIMIT) + CONTEXT);
  const candidates = (Array.isArray(chapter.blocks) ? chapter.blocks : []).filter((b) =>
    integer(b.o) && typeof b.t === 'string' && b.k !== 'img' && b.o < to && b.o + b.t.length > from && b.o >= chapter.o0);
  // Keep the selected passage when a chapter has many short blocks before it.
  const firstSelected = candidates.findIndex((b) => b.o + b.t.length > start);
  const first = Math.max(0, firstSelected - 4);
  const parts = candidates.slice(first, first + BLOCK_LIMIT).map((b) => {
    const left = boundary(b.t, Math.max(from, b.o) - b.o);
    const right = boundary(b.t, Math.min(to, b.o + b.t.length) - b.o, true);
    const markStart = Math.min(right, Math.max(left, boundary(b.t, start - b.o)));
    const markEnd = Math.max(markStart, Math.min(right, boundary(b.t, Math.min(end, cutoff, start + QUOTE_LIMIT) - b.o, true)));
    return {
      start: b.o + left, end: b.o + right,
      before: b.t.slice(left, markStart), quote: b.t.slice(markStart, markEnd), after: b.t.slice(markEnd, right),
    };
  }).filter((part) => part.end > part.start);
  return {
    parts, selected: parts.some((part) => part.quote),
    truncated: end > Math.min(chapter.o1, cutoff, start + QUOTE_LIMIT) || first > 0 || candidates.length > first + BLOCK_LIMIT,
  };
}

export function sourcePreviewView(ctx, arg, pane, title) {
  title.append(tr('原文预览'), h('small', {}, tr('查看出处不会改变阅读位置')));
  const box = h('section', { class: 'source-preview', 'aria-label': tr('原文预览') });
  const location = h('p', { class: 'source-preview-location' });
  const content = h('div', { class: 'source-preview-content', 'aria-live': 'polite' });
  const status = h('p', { class: 'source-preview-status', role: 'status' });
  const actions = h('div', { class: 'source-preview-actions' });
  box.append(location, content, status, actions); pane.append(box);

  const initial = { id: ctx.book.id, generation: generation(ctx), cutoff: ctx.info.cutoff };
  let disposed = false, request = null, attempt = 0;
  const leave = () => { disposed = true; attempt++; request?.abort(); ctx.signal?.removeEventListener('abort', leave); };
  ctx.onLeave(leave);
  ctx.signal?.addEventListener('abort', leave, { once: true });
  if (ctx.signal?.aborted) { leave(); return; }
  const current = () => ctx.current?.() || ctx;
  const sameEdition = () => { const now = current(); return now.book.id === initial.id && generation(now) === initial.generation; };
  const valid = () => !disposed && !ctx.signal?.aborted && sameEdition() && current().info.cutoff === initial.cutoff;

  const back = h('button', { type: 'button', class: 'btn source-preview-back', onclick: () => {
    if (disposed) return;
    ctx.panes.stack.length > 1 ? ctx.panes.back() : ctx.panes.close();
  } }, ctx.panes.stack.length > 1 ? tr('返回上一项') : tr('返回阅读'));

  function stale() {
    if (disposed) return;
    request?.abort();
    location.textContent = ''; content.replaceChildren();
    status.textContent = sameEdition() ? tr('阅读位置已改变，请按当前页重新查看。') : tr('文本版本已改变，请关闭预览后重新选择出处。');
    actions.replaceChildren(back);
    if (sameEdition()) actions.prepend(h('button', { type: 'button', class: 'btn', onclick: () => ctx.panes.render(false) }, tr('按当前页重新查看')));
  }

  const start = arg?.start;
  const end = arg?.end ?? Math.min(ctx.book.len, start + 2);
  if (![start, end, ctx.book.len, initial.cutoff].every(integer) || start >= ctx.book.len || end <= start || end > ctx.book.len) {
    status.textContent = tr('这个出处的位置不完整，暂时无法预览。'); actions.append(back); return;
  }
  const chapters = ctx.book.chapters || [];
  const chapterNumber = chapters.findIndex((c) => c.o0 <= start && start < c.o1);
  if (chapterNumber < 0) { status.textContent = tr('找不到这个出处对应的章节。'); actions.append(back); return; }
  const meta = chapters[chapterNumber];
  const future = end > initial.cutoff;
  // The fetched chapter may include a future title, so do not use it in this state.
  location.textContent = future ? tr('这段出处包含当前页之后的内容') : (ctx.chapterTitle?.(chapterNumber) || tr("第 {0} 节", [chapterNumber + 1]));
  const jump = h('button', { type: 'button', class: 'btn zhu source-preview-jump', onclick: async () => {
    if (!valid()) { stale(); return; }
    jump.disabled = true;
    try { await ctx.jumpSource(start, end); }
    catch (error) { if (valid()) { status.textContent = tr("未能跳转：{0}", [error.message || tr('请重试')]); jump.disabled = false; } }
  } }, future ? tr('转到这里阅读（后文）') : tr('转到这里阅读'));
  actions.append(jump, back);

  if (start >= initial.cutoff) {
    status.textContent = tr('后文原文暂不显示。选择“转到这里阅读”会跳到这个位置，并更新阅读进度。');
    return; // A future-only request makes no network call and reveals no chapter title.
  }

  async function load() {
    if (!valid()) { stale(); return; }
    request?.abort(); request = new AbortController();
    const ticket = ++attempt;
    content.replaceChildren(h('p', { class: 'source-preview-loading' }, tr('正在取出原文…')));
    status.textContent = ''; content.setAttribute('aria-busy', 'true');
    try {
      const chapter = await api.chapter(initial.id, chapterNumber, { signal: request.signal });
      if (ticket !== attempt || disposed) return;
      if (!valid()) { stale(); return; }
      if (chapter.o0 !== meta.o0 || chapter.o1 !== meta.o1 || !Array.isArray(chapter.blocks)) throw new Error(tr('原文位置与书籍版本不一致'));
      const result = sourcePreviewParts(chapter, { start, end, cutoff: initial.cutoff });
      content.replaceChildren(...result.parts.map((part) => h('p', { class: 'source-preview-paragraph' },
        part.before, part.quote ? h('mark', {}, part.quote) : null, part.after)));
      status.textContent = !result.selected ? tr('这一位置没有可显示的文字，可能是插图或段落间隔。')
        : future ? tr('已截取到当前页为止，后文保持隐藏。转到这里阅读会更新阅读进度。')
          : result.truncated ? tr('出处较长，预览只显示本章中的部分原文；可以转到这里继续阅读。') : tr('标亮的是引用原文，上下文仅显示到当前页。');
    } catch (error) {
      if (disposed || ticket !== attempt || request.signal.aborted) return;
      if (!valid()) { stale(); return; }
      content.replaceChildren(h('p', { class: 'source-preview-error' }, tr("原文暂不可用：{0}", [error.message || tr('请检查连接')])),
        h('button', { type: 'button', class: 'btn', onclick: load }, tr('重新获取原文')));
      status.textContent = tr('当前阅读位置没有改变。');
    } finally { if (!disposed && ticket === attempt) content.removeAttribute('aria-busy'); }
  }
  load();
}
