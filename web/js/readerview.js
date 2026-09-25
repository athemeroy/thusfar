// The reading screen: wires the pagination engine, the temporal KG and the panes together.

import { api } from './api.js';
import { KG } from './kg.js';
import { Reader } from './reader.js';
import { Progress } from './progress.js';
import { pronounSpan, textOffset } from './text.js';
import { Panes } from './panes.js';
import { Notebook, notebookView } from './notebook.js';
import { searchView } from './search.js';
import { companionView } from './companion.js';
import { manualView } from './manual.js';
import { sourcePreviewView } from './source-preview.js';
import { Marginalia } from './marginalia.js';
import { personView, hereView, castView } from './person.js';
import { graphView } from './graph.js';
import { recapView, askView, tocView, settingsView, bookSettingsView } from './views.js';
import { h, icon, avatar, store, debounce, toast, maskTitle, qualityPending } from './util.js';
import { t as tr } from './i18n.js';

const STATIC = new Set(['ask', 'settings', 'toc', 'search', 'notebook', 'companion', 'manual', 'bookSettings', 'sourcepreview']);   // don't redraw these on every page turn

function defaults() {
  const wide = innerWidth >= 760;
  return { fs: wide ? 20 : 19, lh: 1.9, font: 'serif', theme: 'paper', names: true, anim: true, volKeys: true, immersive: false,
    aiComments: false, aiPersona: 'auto' };
}

export async function openReader(root, bookId, options = {}) {
  const { signal } = options;
  let selecting = false;
  root.textContent = '';
  root.append(h('div', { class: 'loading' }, tr('正在打开…')));
  const book = await api.book(bookId, { signal });
  if (signal?.aborted) return;
  const settings = { ...defaults(), ...store.get('settings', {}) };
  root.textContent = '';

  const readerEl = h('div', { class: 'reader has-margin paper-grain' });
  const stage = h('div', { class: 'stage paper-grain' });
  const head = h('div', { class: 'run-head' }, h('span', {}, book.title), h('span', {}));
  const foot = h('div', { class: 'run-foot' }, h('div', { class: 'page-cast' }), h('span', { class: 'folio' }));
  const banner = h('div', { class: 'ai-banner', hidden: true });
  const backChip = h('button', { class: 'back-chip', hidden: true });
  const fnPop = h('div', { class: 'fn-pop', hidden: true });
  stage.append(head, foot, banner, backChip, fnPop);
  readerEl.append(stage);
  root.append(readerEl);

  const notebook = new Notebook(book);
  notebook.sync();
  const kg = new KG(bookId, { signal });
  const reader = new Reader(stage, book, settings, { signal });
  const sync = h('div', { class: 'sync-state', hidden: true, role: 'status' });
  stage.append(sync);
  const progress = new Progress(bookId, book.progress, () => renderSync());
  const marginalia = new Marginalia({ stage, reader, book, settings, notebook, signal, getInfo: () => info });
  let graphError = '';
  let pendingPaneRefresh = null;
  let info = null;
  let world = null;
  let returnTo = null, turnsSinceJump = 0;
  const leaveHooks = [];
  let firstPage;
  const ready = new Promise((r) => (firstPage = r));
  const askHistory = [];
  let maxPos = store.get(`max:${bookId}`, 0);   // furthest point ever read: chapter titles after it stay hidden

  // ---------------------------------------------------------------- chrome
  const title = h('div', { class: 'title' }, book.title, h('small', {}));
  const top = h('div', { class: 'chrome top' },
    h('button', { class: 'icon-btn', 'aria-label': tr('回书架'), onclick: () => (location.hash = '#/') }, icon('back')),
    title,
    h('button', { class: 'icon-btn bookmark-toggle', 'aria-label': tr('收藏当前页为书签'), onclick: () => addBookmark() }, icon('bookmark')),
    h('button', { class: 'icon-btn', 'aria-label': tr('排版'), onclick: () => panes.open('settings') }, icon('font')));
  const scrubN = h('span', { class: 'n' });
  const scrubT = h('span', { class: 'n' });
  const range = h('input', { type: 'range', min: 1, max: 1, value: 1, 'aria-label': tr('页码') });
  const tip = h('div', { class: 'scrub-tip', hidden: true });
  const scrub = h('div', { class: 'scrub', style: { position: 'relative' } }, scrubN, range, scrubT, tip);
  const dockBtn = (ic, label, view) => h('button', { onclick: () => panes.open(view, undefined, { root: true }) }, icon(ic), label);
  const dock = h('div', { class: 'dock' },
    dockBtn('toc', tr('目录'), 'toc'), h('button', { onclick: () => setSelecting(true) }, icon('pen'), tr('摘录')),
    dockBtn('bookmark', tr('摘记'), 'notebook'), dockBtn('people', tr('资料'), 'companion'),
    dockBtn('ask', tr('问书'), 'ask'), dockBtn('font', tr('排版'), 'settings'));
  const bottom = h('div', { class: 'chrome bottom' }, scrub, dock);
  stage.append(top, bottom);
  const menuHandle = h('button', { class: 'reader-menu-handle', 'aria-label': tr('打开阅读菜单'), onclick: () => readerEl.classList.add('ui') }, icon('toc'), tr('菜单'));
  const selectionTools = h('div', { class: 'selection-tools', hidden: true },
    h('span', {}, tr('长按或拖选一段文字')),
    h('button', { class: 'btn primary', onclick: () => captureSelection() }, tr('记一笔')),
    h('button', { class: 'btn ai-comment-action', onclick: () => commentSelection() }, tr('AI 批一句')),
    h('button', { class: 'btn', onclick: () => setSelecting(false) }, tr('完成摘录')));
  stage.append(menuHandle, selectionTools);
  stage.addEventListener('focusin', (e) => { if (e.target.closest('.chrome')) readerEl.classList.add('ui'); });

  // ---------------------------------------------------------------- context for views
  const chapterOf = (pos) => reader.chapterAt(pos);
  const chapterTitle = (n) => { const c = book.chapters[n]; return (c.parent ? c.parent + ' · ' : '') + c.title; };
  const bodyStart = () => (book.chapters.find((c) => c.kind === 'body') || book.chapters[0]).o0;
  const ctx = () => ({
    book, reader, kg, panes, settings, world, info, askHistory, signal, current: ctx, notebook, addBookmark,
    startExcerpt: () => setSelecting(true),
    generation: book.version || book.revision || `${book.id}:${book.len}`,
    pageNo: (pos) => reader.pageNumberOf(pos),
    chapterName: (pos) => chapterTitle(chapterOf(pos)),
    chapterTitle,
    chapterStart: () => book.chapters[info.ch].o0,
    bodyStart,
    openPerson: (id) => panes.open('person', world.canon(id)),
    goSource, jumpSource,
    gotoChapter: async (n) => { jumpFrom(); if (!panes.desktop) panes.close(); await reader.showChapter(n, 0); },
    gotoPage: async (g) => { jumpFrom(); if (!panes.desktop) panes.close(); await reader.gotoPage(g); },
    pagePeople,
    chapterPeople,
    maxPos: () => maxPos,
    lastSeen: (id) => store.get(`seen:${bookId}`, {})[id] ?? null,
    markSeen: (id) => { const m = store.get(`seen:${bookId}`, {}); m[id] = Math.max(m[id] || 0, info.cutoff); store.set(`seen:${bookId}`, m); },
    statusLine,
    refreshManual: async () => {
      kg.invalidate();
      await kg.ensure(info.cutoff);
      world = kg.world(info.cutoff);
      reader.refreshChapters();
      await reader.showChapter(info.ch, info.start);
      await kg.ensure(info.cutoff);
      world = kg.world(info.cutoff);
      applyNames(); renderFooter();
      panes.refresh();
    },
    onLeave: (fn) => leaveHooks.push(fn),
    saveSettings: () => store.set('settings', settings),
    applySettings,
  });
  const views = {
    person: personView, here: hereView, cast: castView, graph: graphView,
    recap: recapView, ask: askView, toc: tocView, settings: settingsView,
    search: searchView, notebook: notebookView, companion: companionView, manual: manualView, bookSettings: bookSettingsView, sourcepreview: sourcePreviewView,
  };
  const wrapped = {};
  for (const [k, fn] of Object.entries(views)) {
    wrapped[k] = (...a) => { while (leaveHooks.length) leaveHooks.pop()(); return fn(...a); };
  }
  const panes = new Panes(readerEl, wrapped, ctx);
  panes.onClose = () => { while (leaveHooks.length) leaveHooks.pop()(); };

  async function addBookmark() {
    if (!info) return;
    const old = notebook.items.find((n) => !n.deleted && n.kind === 'bookmark' && n.start === info.start);
    if (old) { panes.open('notebook', undefined, { root: true }); toast(tr('这一页已经有书签')); return; }
    try { await notebook.save({ kind: 'bookmark', start: info.start, end: info.start, knowledge_cutoff: info.cutoff, quote: '', text: '' }); toast(tr('书签已留下，可在「摘记」找回')); }
    catch (e) { toast(e.message, 5000); }
  }
  function setSelecting(on) {
    selecting = on; down = null; reader.settle();
    readerEl.classList.toggle('selecting', on); selectionTools.hidden = !on;
    if (on) { panes.close(); readerEl.classList.remove('ui'); }
    else getSelection()?.removeAllRanges();
  }
  function selectedDraft() {
    const selection = getSelection();
    if (!selection?.rangeCount || selection.isCollapsed) throw new Error(tr('请先长按或拖选一段原文'));
    const r = selection.getRangeAt(0);
    const block = (node) => (node.nodeType === 1 ? node : node.parentElement)?.closest('.flow p[data-o], .flow h3[data-o]');
    const a = block(r.startContainer), b = block(r.endContainer);
    if (!a || a !== b || !reader.flow.contains(a)) throw new Error(tr('请在同一段原文内选取，较长内容可以分次摘录'));
    const start = +a.dataset.o + textOffset(a, r.startContainer, r.startOffset);
    const end = +a.dataset.o + textOffset(a, r.endContainer, r.endOffset);
    if (start < info.start || end > info.cutoff || end <= start) throw new Error(tr('请只选择当前页可见的文字'));
    // Quote uses source text nodes, excluding footnote buttons and cosmetic markers.
    const walker = document.createTreeWalker(a, NodeFilter.SHOW_TEXT); let original = '';
    while (walker.nextNode()) if (!walker.currentNode.parentElement.closest('.fn,.fn-ref,.note-mark')) original += walker.currentNode.textContent;
    const quote = original.slice(start - +a.dataset.o, end - +a.dataset.o);
    if (quote.length > 4000) throw new Error(tr('一次摘录最多 4000 字'));
    return { kind: 'note', start, end, quote };
  }
  function captureSelection() {
    try { const draft = selectedDraft(); setSelecting(false); panes.open('notebook', { draft }, { root: true, full: true }); }
    catch (e) { toast(e.message, 5000); }
  }
  function commentSelection() {
    try {
      const draft = selectedDraft();
      if (draft.quote.length > 600) throw new Error(tr('AI 批注一次最多选择 600 字'));
      setSelecting(false); marginalia.compose(draft);
    } catch (e) { toast(e.message, 5000); }
  }

  function renderSync() {
    if (signal?.aborted) return;
    sync.replaceChildren();
    if (progress.conflict) {
      sync.append(tr('其他设备也更新了进度。'),
        h('button', { onclick: () => progress.useLocal() }, tr('保留本机位置')),
        h('button', { onclick: async () => { const pos = progress.useServer(); if (pos != null) await reader.goto(pos); } }, tr('使用云端位置')));
    } else if (progress.storageError) sync.append(tr('本机存储空间不足，无法保存离线位置。请联网同步。'));
    // Ordinary page turns are saved locally and synchronized in the background.
    // Keep this banner for states that need the reader's attention only.
    sync.hidden = !sync.childNodes.length;
  }

  function statusLine(pane) {
    const st = book.status || {};
    let text = '';
    if (st.state === 'done' && qualityPending(st)) text = tr('正文已整理，但部分资料仍待核对或补全。这里显示当前可用的内容。');
    else if (st.state === 'done') text = tr("AI 已读完全书，整理出 {0} 位人物。所有信息都按你读到的页码截止。", [st.people || tr('若干')]);
    else if (st.state === 'finalizing') text = tr('正文已处理完，正在核对并整理最后的资料。');
    else if (st.state === 'running' || st.state === 'queued') text = tr("AI 正在读这本书：已整理到第 {0} 页（{1}%）。", [reader.pageNumberOf(st.frontier || 0), Math.round(100 * (st.done || 0) / Math.max(1, st.total || 1))]);
    else if (st.state === 'error') text = tr("AI 整理停下了：{0}", [st.error || tr('原因未知')]);
    else if (st.state === 'paused') text = tr('AI 整理已暂停，已完成的资料仍可查看。');
    else text = tr('这本书还没有让 AI 整理。');
    pane.append(h('p', { class: 'muted', style: { marginTop: '26px' } }, text));
    if (st.notice && ['queued', 'running'].includes(st.state)) pane.append(h('p', { class: 'note', role: 'status' }, st.notice));
    if (graphError || kg.incomplete) pane.append(h('p', { class: 'note', role: 'status' }, graphError || tr("离线资料只整理到第 {0} 页。连接后可更新。", [reader.pageNumberOf(kg.loadedTo)])));
    if (st.state === 'done' && qualityPending(st)) pane.append(h('button', { class: 'btn zhu', onclick: async (e) => {
      if (!confirm(tr('重试待核对资料会调用模型，可能产生费用。确定继续？'))) return;
      const button = e.currentTarget; button.disabled = true;
      try { await api.process(bookId, { signal }); book.status = { ...st, state: 'queued' }; toast(tr('已排队重试待核对资料')); panes.refresh(); }
      catch (err) { if (!signal?.aborted) { toast(err.message); button.disabled = false; } }
    } }, tr('重试待核对资料')));
    if (!st.state || st.state === 'idle') {
      pane.append(h('button', { class: 'btn zhu', onclick: async (e) => { if (!confirm(tr('开始整理这本书的阅读资料？将调用当前配置的模型，可能产生费用；你可以继续阅读正文。'))) return; e.currentTarget.disabled = true; try { await api.process(bookId, { signal }); book.status = { state: 'queued' }; toast(tr('已开始整理，读着读着人物就会出现')); panes.refresh(); } catch (err) { toast(err.message); e.target.disabled = false; } } }, tr('让 AI 开始整理')));
    }
  }

  function pagePeople() {
    const ids = [];
    for (const el of reader.layout.mentionEls) {
      const s = +el.dataset.s;
      if (s < info.start || s >= info.cutoff || !el.classList.contains('on')) continue;
      const id = el.dataset.c;
      if (!ids.includes(id)) ids.push(id);
    }
    return ids;
  }

  function chapterPeople() {
    const ids = new Set();
    for (const el of reader.layout.mentionEls) if (el.classList.contains('on')) ids.add(el.dataset.c);
    const c0 = book.chapters[info.ch].o0;
    for (const e of world.events) if (e.p >= c0) e.whoC.forEach((x) => ids.add(x));
    return [...ids];
  }

  // ---------------------------------------------------------------- page updates
  reader.onPage = async (inf) => {
    const previous = info;
    info = inf;
    progress.save(inf.start, Math.round(1000 * inf.cutoff / Math.max(1, book.len)) / 10, inf.cutoff);
    renderSync();
    const keepEditor = inf.reason === 'layout' && panes.top?.view === 'notebook' && panes.top.arg;
    const askChanged = !keepEditor && ['ask', 'search', 'toc', 'companion', 'notebook', 'manual', 'sourcepreview'].includes(panes.top?.view) && previous && previous.cutoff !== inf.cutoff;
    if (askChanged && panes.top?.view === 'notebook' && panes.top.arg) panes.top.arg = undefined;
    if (askChanged) { pendingPaneRefresh = panes.top; while (leaveHooks.length) leaveHooks.pop()(); panes.pane.replaceChildren(h('p', { role: 'status' }, tr('正在更新已读范围…'))); }
    if (returnTo && ++turnsSinceJump > 6) hideBack();
    try { await kg.ensure(inf.cutoff); graphError = ''; } catch (e) { graphError = tr('人物资料暂时不可用，正在显示已保存的内容。'); }
    if (signal?.aborted || info !== inf) return;
    world = kg.world(inf.cutoff);
    if (pendingPaneRefresh) { const refresh = pendingPaneRefresh === panes.top; pendingPaneRefresh = null; if (refresh) panes.refresh(); }
    if (inf.cutoff > maxPos && !returnTo) { maxPos = inf.cutoff; store.set(`max:${bookId}`, maxPos); }
    applyNames();
    renderFooter();
    renderChrome();
    marginalia.page(inf);
    const t = panes.top;
    if (panes.desktop ? !(t && STATIC.has(t.view)) : (panes.isOpen && t && !STATIC.has(t.view))) panes.refresh();
    firstPage();
  };

  function applyNames() {
    const seen = new Set();
    for (const el of reader.layout.mentionEls) {
      const s = +el.dataset.s;
      const cid = world.canon(el.dataset.id);
      const p = world.people.get(cid);
      const on = !!p && s < info.cutoff;
      el.dataset.c = cid;
      el.classList.toggle('on', on);
      el.tabIndex = on && s >= info.start && s < info.cutoff ? 0 : -1;
      el.setAttribute('aria-label', on ? tr("查看{0}的批注", [p.name]) : el.textContent);
      const isNew = on && p.first >= info.start && p.first < info.cutoff && s >= info.start && !seen.has(cid);
      el.classList.toggle('new', isNew);
      if (on && s >= info.start) seen.add(cid);
    }
  }

  function renderFooter() {
    const cast = foot.querySelector('.page-cast');
    cast.textContent = '';
    const ids = pagePeople();
    for (const id of ids.slice(0, 4)) {
      const p = world.people.get(id);
      if (!p) continue;
      const b = h('button', { style: { background: p.color }, 'aria-label': p.name, onclick: (e) => { e.stopPropagation(); panes.open('person', id, { root: true }); } }, p.name[0]);
      cast.append(b);
    }
    if (ids.length > 4) cast.append(h('button', { class: 'more', onclick: (e) => { e.stopPropagation(); panes.open('cast', { mode: 'page' }, { root: true }); } }, `+${ids.length - 4}`));
    foot.querySelector('.folio').replaceChildren(String(info.global), h('em', {}, ` / ${info.exact ? '' : tr('约 ')}${info.total}`));
    head.lastChild.textContent = chapterTitle(info.ch);
    const st = book.status || {};
    const behind = ['queued', 'running', 'finalizing', 'error', 'paused'].includes(st.state) && info.cutoff > (st.frontier || 0) && book.chapters[info.ch].kind === 'body';
    banner.hidden = !behind;
    if (behind) banner.textContent = st.state === 'error' ? tr("AI 整理停下了：{0}", [st.error || tr('原因未知')])
      : st.state === 'paused' ? tr("整理已暂停 · 人物信息整理到第 {0} 页", [reader.pageNumberOf(st.frontier || 0)])
      : st.notice ? st.notice
      : tr("AI 正在读这本书 · 人物信息整理到第 {0} 页", [reader.pageNumberOf(st.frontier || 0)]);
  }

  function renderChrome() {
    title.lastChild.textContent = chapterTitle(info.ch);
    range.max = info.total;
    range.value = info.global;
    scrubN.textContent = info.global;
    scrubT.textContent = (info.exact ? '' : tr('约')) + info.total;
  }

  range.addEventListener('input', () => {
    const t = reader.posOfPage(+range.value);
    tip.hidden = false;
    const c = book.chapters[t.ch];
    tip.replaceChildren(h('b', {}, range.value), c.o0 > maxPos && c.kind === 'body' && !store.get(`toc-reveal:${bookId}`, false) ? maskTitle(c.title) : chapterTitle(t.ch));
  });
  range.addEventListener('change', async () => {
    tip.hidden = true;
    jumpFrom();
    await reader.gotoPage(+range.value);
  });

  // ---------------------------------------------------------------- jumps with a way back
  function jumpFrom() {
    if (!info) return;
    returnTo = { pos: info.start, page: info.global };
    turnsSinceJump = 0;
    backChip.hidden = false;
    backChip.replaceChildren(icon('undo'), tr("回到第 {0} 页", [info.global]));
  }
  function hideBack() { returnTo = null; backChip.hidden = true; }
  backChip.addEventListener('click', async (e) => {
    e.stopPropagation();
    const r = returnTo;
    hideBack();
    if (r) await reader.goto(r.pos);
  });
  function goSource(s, e) {
    panes.open('sourcepreview', { start: s, end: Math.min(book.len, Math.max(s + 1, e ?? s + 2)) }, { full: true });
  }
  async function jumpSource(s, e) {
    jumpFrom();
    if (!panes.desktop) panes.close();
    await reader.goto(s, { mark: [s, e ?? s + 2] });
  }

  // ---------------------------------------------------------------- settings
  function applySettings() {
    const d = document.documentElement;
    d.dataset.theme = settings.theme;
    d.dataset.font = settings.font;
    d.dataset.bookLang = book.lang || 'zh';
    d.style.setProperty('--fs', settings.fs + 'px');
    d.style.setProperty('--lh', settings.lh);
    readerEl.classList.toggle('names-on', settings.names);
    if (!settings.aiComments) marginalia.hide();
    else if (info) marginalia.page(info, true);
    const paper = getComputedStyle(d).getPropertyValue('--paper').trim();
    document.querySelector('meta[name=theme-color]')?.setAttribute('content', paper);
    try { window.YeduApp?.setBars(paper, settings.theme === 'night'); } catch { /* not in the Android shell */ }
    if (reader.ch >= 0) reader.relayout();
    try { window.YeduApp?.reading(true, !!settings.immersive && !readerEl.classList.contains('ui') && !panes.isOpen); } catch { /* browser */ }
    try { window.YeduApp?.setVolumePaging?.(!!settings.volKeys); } catch { /* older shell */ }
  }

  // ---------------------------------------------------------------- input
  let down = null;
  let suppressCueClickUntil = 0;
  stage.addEventListener('pointerdown', (e) => {
    if (selecting || e.target.closest('button, input, textarea, .chrome, .back-chip, .page-cast, .fn-pop, .selection-tools, .reader-menu-handle') && !e.target.closest('.nm,.fn') || e.button > 0) return;
    down = { x: e.clientX, y: e.clientY, t: Date.now(), drag: false };
  });
  stage.addEventListener('pointermove', (e) => {
    if (!down) return;
    const dx = e.clientX - down.x, dy = e.clientY - down.y;
    if (!down.drag && Math.abs(dx) > 10 && Math.abs(dx) > Math.abs(dy) * 1.2) down.drag = true;
    if (down.drag && settings.anim) reader.drag(dx);
  });
  const up = async (e) => {
    if (selecting || !down) return;
    const d = down;
    down = null;
    const dx = e.clientX - d.x;
    if (d.drag) {
      suppressCueClickUntil = performance.now() + 350;
      const fast = Math.abs(dx) / Math.max(1, Date.now() - d.t) > 0.35;
      if (dx < -60 || (fast && dx < -20)) return turn(1);
      if (dx > 60 || (fast && dx > 20)) return turn(-1);
      return reader.settle();
    }
    if (Math.abs(e.clientY - d.y) > 12) return;
    // Open a cue on click, after touch's synthetic click has chosen its target.
    // Opening the scrim during pointerup lets that same click close the drawer.
    if (e.target.closest('.marginalia-cue')) return;
    await onTap(e);
  };
  stage.addEventListener('pointerup', up);
  stage.addEventListener('pointercancel', () => { if (down?.drag) reader.settle(); down = null; });

  stage.addEventListener('click', (e) => {
    const cue = !selecting && e.target.closest('.marginalia-cue');
    if (cue) {
      if (performance.now() >= suppressCueClickUntil) marginalia.openCue(cue);
      return;
    }
    if (e.detail === 0 && e.target.closest('.nm.on,.fn')) onTap(e).catch((err) => toast(err.message));
  });
  async function onTap(e) {
    const fn = e.target.closest('.fn');
    if (fn) {
      const note = reader.cache.get(reader.ch);
      Promise.resolve(note).then((ch) => {
        fnPop.replaceChildren(h('b', {}, tr('注释')), ch?.notes?.[fn.dataset.n] || '');
        fnPop.hidden = false;
      });
      return;
    }
    if (!fnPop.hidden) { fnPop.hidden = true; return; }
    const nm = e.target.closest('.nm.on');
    if (nm) {
      panes.open('person', nm.dataset.c, { root: true });
      return;
    }
    if (readerEl.classList.contains('ui')) { readerEl.classList.remove('ui'); return; }
    if (panes.isOpen && !panes.desktop) { panes.close(); return; }
    const x = e.clientX - stage.getBoundingClientRect().left;
    const W = stage.clientWidth;
    // Edge taps are page-turn controls, even when the text under the finger is
    // a pronoun. An implicit "who is this" lookup must never trap the reader.
    if (x < W * 0.3) { turn(-1); return; }
    if (x > W * 0.7) { turn(1); return; }
    if (await tappedPronoun(e)) return;
    readerEl.classList.add('ui');
  }

  // Tapping a pronoun asks who it is, as of this page. Names are highlighted from the graph;
  // pronouns are not, so the reader taps the word itself and the judge answers.
  async function tappedPronoun(e) {
    const p = e.target.closest('.flow p, .flow h3');
    if (!p || !p.dataset.o) return false;
    const r = document.caretRangeFromPoint?.(e.clientX, e.clientY);
    if (!r || !r.startContainer || r.startContainer.nodeType !== 3) return false;
    const span = pronounSpan(r.startContainer.textContent, r.startOffset);
    if (!span) return false;
    const word = span.text;
    const before = textOffset(p, r.startContainer, span.start);
    const start = +p.dataset.o + before;
    const cutoff = info.cutoff;
    toast(tr('正在看这是谁…'), 4000);
    try {
      const res = await api.who(bookId, cutoff, start, start + word.length, { signal });
      if (signal?.aborted || info.cutoff !== cutoff) return true;
      if (res.ok) {
        toast(tr("「{0}」指的是 {1}", [res.word || word, res.name]), 2500);
        panes.open('person', res.id, { root: true });
      } else toast(tr('这一处看不出来指谁'), 2000);
    } catch { toast(tr('问不到，稍后再试'), 2000); }
    return true;
  }

  async function turn(dir) {
    fnPop.hidden = true;
    readerEl.classList.remove('ui');
    if (!settings.anim) reader.flow.classList.remove('anim');
    try { if (dir > 0) await reader.next(); else await reader.prev(); } catch (e) { if (!signal?.aborted) toast(e.message); }
    if (!settings.anim) reader.flow.classList.remove('anim');
  }

  const onKey = (e) => {
    if (e.target.closest('input, textarea, [contenteditable=true]')) return;
    if (selecting) { if (e.key === 'Escape') setSelecting(false); return; }
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'f') { e.preventDefault(); panes.open('search', undefined, { root: true }); return; }
    if (e.target.closest('button, a, select, [role=button], .sheet, .margin, .chrome') && e.key !== 'Escape') return;
    if (['ArrowRight', 'PageDown', ' '].includes(e.key)) { e.preventDefault(); turn(1); }
    else if (['ArrowLeft', 'PageUp'].includes(e.key)) { e.preventDefault(); turn(-1); }
    else if (e.key === 'Escape') { panes.isOpen && !panes.desktop ? panes.close() : readerEl.classList.remove('ui'); }
  };
  let wheelT = 0;
  const onWheel = (e) => {
    if (selecting || e.target.closest('.pane, .chrome')) return;
    if (Date.now() - wheelT < 350 || Math.abs(e.deltaY) < 25) return;
    wheelT = Date.now();
    turn(e.deltaY > 0 ? 1 : -1);
  };
  addEventListener('keydown', onKey);
  stage.addEventListener('wheel', onWheel, { passive: true });
  // the Android shell drives these: volume keys turn pages, the screen stays on, bars hide while reading
  window.YeduReader = { page: (d) => { if (!selecting && settings.volKeys && !panes.sheet.classList.contains('open')) turn(d); }, onNativeBack: () => {
    if (selecting) { setSelecting(false); return true; }
    if (panes.stack.length) { panes.stack.length > 1 ? panes.back() : panes.close(); return true; }
    if (readerEl.classList.contains('ui')) { readerEl.classList.remove('ui'); return true; }
    return false;
  } };
  const nativeReading = () => {
    try { window.YeduApp?.reading(true, !!settings.immersive && !readerEl.classList.contains('ui') && !panes.isOpen); } catch { /* browser */ }
  };
  nativeReading();
  panes.onChange = nativeReading;
  const observer = new MutationObserver(nativeReading);
  observer.observe(readerEl, { attributes: true, attributeFilter: ['class'] });
  const onResize = debounce(() => reader.relayout(), 200);
  addEventListener('resize', onResize);

  // keep up with the AI while it is still reading this book
  const poll = setInterval(async () => {
    if (document.hidden || (book.status?.state === 'done')) return;
    try {
      const b = await api.book(bookId, { signal });
      if (signal?.aborted) return;
      const moved = (b.status?.frontier || 0) !== (book.status?.frontier || 0);
      book.status = b.status;
      if (moved && info) {
        await kg.ensure(info.cutoff);
        const c = book.chapters[info.ch];
        if (b.status.frontier > c.o0 && reader.layout.mentionEls.length === 0 || (b.status.frontier > c.o0 && (book._lastFront || 0) < c.o1)) {
          reader.refreshChapter(info.ch);
          await reader.showChapter(info.ch, info.start);
        } else reader.emit();
        book._lastFront = b.status.frontier;
      }
    } catch { /* offline: keep reading */ }
  }, 20000);

  const cleanup = () => {
    try { window.YeduApp?.reading(false, false); } catch { /* browser */ }
    delete window.YeduReader;
    removeEventListener('keydown', onKey);
    removeEventListener('resize', onResize);
    clearInterval(poll);
    onResize.cancel(); observer.disconnect(); marginalia.destroy(); panes.destroy(); reader.destroy(); progress.destroy();
    firstPage();
  };
  signal?.addEventListener('abort', cleanup, { once: true });

  applySettings();
  const start = progress.pos ?? bodyStart();
  await reader.open(start);
  await ready;
  if (signal?.aborted) return;
  if (panes.desktop) panes.render(true);
  if (Number.isInteger(options.at) && options.at >= 0 && options.at < book.len) await jumpSource(options.at);
  if (options.panel === 'notebook') panes.open('notebook', undefined, { root: true });
  if (!store.get('tip-shown')) {
    store.set('tip-shown', 1);
    toast(tr('点朱线标出的人名，看他截至此页的一切；点屏幕中间呼出菜单'), 4200);
    // the tip sits over the progress bar and dock: get out of the way on the first tap
    readerEl.addEventListener('pointerdown', () => { const t = document.getElementById('toast'); if (t) t.hidden = true; }, { once: true, capture: true });
  }
}
