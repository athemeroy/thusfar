import { canReachLibrary } from './runtime.js';
// Paginated reading engine.
//
// One chapter at a time is laid out with CSS columns (one column = one page) and moved
// with translateX. Every paragraph carries its global UTF-16 offset, so any page can be
// mapped to an exact [start, end) text range; `end` is the spoiler cutoff for that page.

import { api } from './api.js';
import { h, clamp, store } from './util.js';
import { t as tr } from './i18n.js';

const FN_SKIP = (node) => node.parentElement?.closest('.fn');

// ------------------------------------------------------------------ chapter layout
export class ChapterLayout {
  constructor(flow) {
    this.flow = flow;
    this.blockEls = [];
    this.mentionEls = [];
    this.textIndex = new WeakMap();
  }

  render(ch, bookId, chapterMeta) {
    const flow = this.flow;
    flow.textContent = '';
    this.blockEls = [];
    this.mentionEls = [];
    this.o0 = ch.o0;
    this.o1 = ch.o1;
    const byBlock = groupMentions(ch.blocks, ch.mentions || []);
    const open = h('div', { class: 'ch-open', 'data-o': ch.o0 },
      chapterMeta.parent ? h('div', { class: 'part' }, chapterMeta.parent) : null,
      h('h2', {}, ch.title), h('span', { class: 'orn' }));
    flow.append(open);
    let skippedTitle = false;
    for (const b of ch.blocks) {
      if (b.k === 'img') {
        const fig = h('figure', { 'data-o': b.o }, h('img', { src: `/api/books/${bookId}/img/${b.src}`, alt: b.alt || '', loading: 'eager', decoding: 'async' }));
        flow.append(fig);
        this.blockEls.push(fig);
        continue;
      }
      if (b.k === 'h' && !skippedTitle && (b.t === ch.title || b.t === chapterMeta.parent)) {
        if (b.t === ch.title) skippedTitle = true;
        continue;   // already shown in the chapter opener
      }
      const el = b.k === 'h' ? h('h3', { class: 'inner', 'data-o': b.o }) : h('p', { 'data-o': b.o });
      fillBlock(el, b, byBlock.get(b.o) || [], ch.notes || {}, this.mentionEls);
      flow.append(el);
      this.blockEls.push(el);
    }
    this.blockEls.sort((a, b) => +a.dataset.o - +b.dataset.o);
    this.offsets = this.blockEls.map((e) => +e.dataset.o);
  }

  // text nodes of a block with their local starting offsets (footnote markers excluded)
  nodes(el) {
    let idx = this.textIndex.get(el);
    if (idx) return idx;
    idx = [];
    const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
    let at = 0;
    for (let n = w.nextNode(); n; n = w.nextNode()) {
      if (FN_SKIP(n)) continue;
      idx.push([n, at]);
      at += n.length;
    }
    idx.len = at;
    this.textIndex.set(el, idx);
    return idx;
  }

  // x offset (in unscrolled flow coordinates) of the character at global position pos
  xOf(pos) {
    const offs = this.offsets;
    if (!offs.length) return 0;
    let i = upperBound(offs, pos) - 1;
    if (i < 0) i = 0;
    let el = this.blockEls[i];
    let local = pos - offs[i];
    const base = this.flow.getBoundingClientRect().left;
    if (el.tagName === 'FIGURE') return el.getBoundingClientRect().left - base;
    const idx = this.nodes(el);
    if (local >= idx.len) {           // in the gap after this block → start of the next one
      if (i + 1 < this.blockEls.length) { el = this.blockEls[i + 1]; local = 0; if (el.tagName === 'FIGURE') return el.getBoundingClientRect().left - base; }
      else local = Math.max(0, idx.len - 1);
    }
    const nodes = this.nodes(el);
    if (!nodes.length) return el.getBoundingClientRect().left - base;
    let k = nodes.length - 1;
    while (k > 0 && nodes[k][1] > local) k--;
    const [node, start] = nodes[k];
    const off = clamp(local - start, 0, Math.max(0, node.length - 1));
    const r = document.createRange();
    r.setStart(node, off);
    r.setEnd(node, Math.min(node.length, off + 1));
    const rects = r.getClientRects();
    const rect = rects.length ? rects[rects.length - 1] : r.getBoundingClientRect();
    return rect.left - base;
  }

  pageOf(pos, stride) {
    return Math.max(0, Math.floor((this.xOf(pos) + 2) / stride));
  }

  count(stride) {
    return this.pageOf(Math.max(this.o0, this.o1 - 1), stride) + 1;
  }

  // first text position on page k
  pageStart(k, stride) {
    if (k <= 0) return this.o0;
    let lo = this.o0, hi = this.o1;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (this.pageOf(mid, stride) >= k) hi = mid; else lo = mid + 1;
    }
    return lo;
  }
}

function upperBound(arr, x) {
  let lo = 0, hi = arr.length;
  while (lo < hi) { const m = (lo + hi) >> 1; if (arr[m] <= x) lo = m + 1; else hi = m; }
  return lo;
}

function groupMentions(blocks, mentions) {
  const map = new Map();
  if (!mentions.length) return map;
  const starts = blocks.map((b) => b.o);
  for (const m of mentions) {
    const i = upperBound(starts, m[0]) - 1;
    if (i < 0) continue;
    const b = blocks[i];
    if (m[1] > b.o + b.t.length) continue;
    if (!map.has(b.o)) map.set(b.o, []);
    map.get(b.o).push(m);
  }
  return map;
}

function fillBlock(el, b, mentions, notes, mentionEls) {
  const marks = [];
  for (const m of mentions) marks.push({ at: m[0] - b.o, end: m[1] - b.o, id: m[2], g: m[3], s: m[0] });
  for (const [off, n] of b.fn || []) marks.push({ at: off, end: off, fn: n });
  marks.sort((x, y) => x.at - y.at || (x.fn ? 1 : -1));
  let at = 0;
  const t = b.t;
  for (const m of marks) {
    if (m.at < at) continue;           // overlapping mention: keep the first
    if (m.at > at) el.append(t.slice(at, m.at));
    if (m.fn) {
      el.append(h('button', { type: 'button', class: 'fn', 'data-n': m.fn, 'aria-label': tr('查看注释') }, tr('注')));
      at = m.at;
      continue;
    }
    const span = h('button', { type: 'button', class: 'nm' + (m.g ? ' g' : ''), 'data-id': m.id, 'data-s': m.s, tabindex: -1 }, t.slice(m.at, m.end));
    mentionEls.push(span);
    el.append(span);
    at = m.end;
  }
  if (at < t.length) el.append(t.slice(at));
  if (b.k === 'p' && t.length < 40 && /^[（(【\[].*[）)】\]]$|^[*＊·—\s]+$/.test(t)) el.classList.add('c');
}

// ------------------------------------------------------------------ reader
export class Reader {
  constructor(stage, book, settings, options = {}) {
    this.stage = stage;
    this.book = book;
    this.settings = settings;
    this.chapters = book.chapters;
    this.cache = new Map();
    this.aheadCache = new Map();
    this.counts = new Map();      // measured page counts for the current layout signature
    this.viewport = h('div', { class: 'viewport' });
    this.flow = h('div', { class: 'flow', lang: book.lang || 'zh-CN' });
    this.viewport.append(this.flow);
    stage.append(this.viewport);
    this.layout = new ChapterLayout(this.flow);
    this.ch = -1;
    this.page = 0;
    this.pages = 1;
    this.onPage = () => {};
    this.busy = false;
    this.measureToken = 0;
    this.options = options;
    this.destroyed = false;
    this.showToken = 0;
  }

  // ---------------------------------------------------------------- geometry
  metrics() {
    const W = this.stage.clientWidth, H = this.stage.clientHeight;
    const fs = this.settings.fs;
    const wide = W >= 760;
    const pw = wide ? Math.min(W - 120, Math.round(fs * 34)) : W - 2 * clamp(Math.round(W * 0.066), 20, 34);
    const mx = Math.round((W - pw) / 2);
    const safeT = parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--safe-t')) || 0;
    const mt = (wide ? 64 : 46) + safeT;
    const mb = wide ? 64 : 50;
    const lineH = fs * this.settings.lh;
    let ph = H - mt - mb - 8;
    ph = Math.floor(ph / lineH) * lineH + Math.round(fs * 0.3);  // whole lines only
    const gap = mx * 2;
    return { W, H, pw, ph, mx, mt, mb, gap, stride: pw + gap, fs };
  }

  applyMetrics() {
    const m = this.metrics();
    this.m = m;
    const s = this.stage.style;
    s.setProperty('--mx', m.mx + 'px');
    s.setProperty('--mt', m.mt + 'px');
    s.setProperty('--mb', (this.stage.clientHeight - m.mt - m.ph) + 'px');
    s.setProperty('--pw', m.pw + 'px');
    s.setProperty('--ph', m.ph + 'px');
    s.setProperty('--gap', m.gap + 'px');
    this.viewport.style.height = m.ph + 'px';
    this.viewport.style.bottom = 'auto';
    const sig = [this.book.version || this.book.len, m.pw, m.ph, this.settings.fs, this.settings.lh, this.settings.font].join('x');
    if (sig !== this.sig) {
      this.sig = sig;
      this.counts = new Map(Object.entries(store.get(`pages:${this.book.id}:${sig}`, {})).map(([k, v]) => [+k, v]));
      this.aheadCache.clear();
    }
  }

  // ---------------------------------------------------------------- chapters
  async fetchChapter(n) {
    if (this.destroyed) throw new DOMException(tr('已离开阅读器'), 'AbortError');
    if (!this.cache.has(n)) this.cache.set(n, api.chapter(this.book.id, n, this.options));
    if (this.cache.size > 8) for (const k of this.cache.keys()) { if (k !== n && k !== this.ch) { this.cache.delete(k); break; } }
    try { return await this.cache.get(n); } catch (e) { this.cache.delete(n); throw e; }
  }

  refreshChapter(n) { this.cache.delete(n); this.aheadCache.delete(n); }

  refreshChapters() { this.cache.clear(); this.aheadCache.clear(); }

  chapterAt(pos) {
    const cs = this.chapters;
    for (let i = cs.length - 1; i >= 0; i--) if (cs[i].o0 <= pos) return i;
    return 0;
  }

  async showChapter(n, target) {
    const token = ++this.showToken;
    const data = await this.fetchChapter(n);
    if (this.destroyed || token !== this.showToken) return;
    this.ch = n;
    this.layout.render(data, this.book.id, this.chapters[n]);
    await settle(this.flow);
    if (this.destroyed || token !== this.showToken) return;
    this.pages = this.layout.count(this.m.stride);
    this.saveCount(n, this.pages);
    let page = 0;
    if (target === 'end') page = this.pages - 1;
    else if (typeof target === 'number') page = this.layout.pageOf(target, this.m.stride);
    this.go(clamp(page, 0, this.pages - 1), false);
    // images or late font chunks can still move text: re-measure once they settle
    this.flow.querySelectorAll('img').forEach((img) => img.complete || img.addEventListener('load', () => this.relayout(), { once: true }));
  }

  saveCount(n, c) {
    if (this.counts.get(n) === c) return;
    this.counts.set(n, c);
    store.set(`pages:${this.book.id}:${this.sig}`, Object.fromEntries(this.counts));
  }

  async open(pos) {
    this.applyMetrics();
    await document.fonts?.ready;
    await this.showChapter(this.chapterAt(pos), pos);
    this.measureAll();
  }

  async goto(pos, opts = {}) {
    const n = this.chapterAt(pos);
    if (n !== this.ch) await this.showChapter(n, pos);
    else this.go(this.layout.pageOf(pos, this.m.stride), opts.animate);
    if (opts.mark) this.mark(opts.mark[0], opts.mark[1]);
  }

  // ---------------------------------------------------------------- paging
  go(page, animate = true, reason = 'navigation') {
    this.page = page;
    this.flow.classList.toggle('anim', !!animate && !!this.settings.anim);
    this.flow.style.transform = `translateX(${-page * this.m.stride}px)`;
    this.emit(reason);
  }

  range(page = this.page) {
    const st = this.m.stride;
    const start = this.layout.pageStart(page, st);
    const end = page + 1 >= this.pages ? this.layout.o1 : this.layout.pageStart(page + 1, st);
    return [start, Math.max(start, end)];
  }

  // Measure a bounded lookahead without changing the visible chapter or read position.
  async aheadRanges(ch = this.ch, page = this.page, limit = 20) {
    if (this.destroyed || ch !== this.ch || page !== this.page || limit < 1) return [];
    const ranges = [];
    for (let k = page + 1; k < this.pages && ranges.length < limit; k++) {
      const [start, cutoff] = this.range(k);
      if (cutoff > start) ranges.push({ ch, page: k, start, cutoff });
    }
    if (ranges.length >= limit || ch + 1 >= this.chapters.length) return ranges;
    const probe = h('div', { class: 'viewport', style: { position: 'fixed', left: '-10000px', top: '0',
      visibility: 'hidden', width: this.m.pw + 'px', height: this.m.ph + 'px' } });
    const flow = h('div', { class: 'flow', lang: this.book.lang || 'zh-CN' });
    probe.append(flow);
    this.stage.append(probe);
    const lay = new ChapterLayout(flow);
    try {
      for (let n = ch + 1; n < this.chapters.length && n <= ch + 10 && ranges.length < limit; n++) {
        if (this.destroyed || this.ch !== ch || this.page !== page) break;
        let pageRanges = this.aheadCache.get(n);
        if (!pageRanges) {
          const data = await this.fetchChapter(n);
          if (this.destroyed || this.ch !== ch || this.page !== page) break;
          lay.render(data, this.book.id, this.chapters[n]);
          await settle(flow);
          if (this.destroyed || this.ch !== ch || this.page !== page) break;
          const pages = lay.count(this.m.stride);
          const bounds = [lay.o0];
          for (let k = 1; k < pages; k++) bounds.push(lay.pageStart(k, this.m.stride));
          bounds.push(lay.o1);
          pageRanges = [];
          for (let k = 0; k < pages; k++) if (bounds[k + 1] > bounds[k]) {
            pageRanges.push({ ch: n, page: k, start: bounds[k], cutoff: bounds[k + 1] });
          }
          this.saveCount(n, pages);
          this.aheadCache.set(n, pageRanges);
          if (this.aheadCache.size > 10) this.aheadCache.delete(this.aheadCache.keys().next().value);
        }
        ranges.push(...pageRanges.slice(0, limit - ranges.length));
      }
    } finally {
      probe.remove();
    }
    return ranges;
  }

  emit(reason = 'measurement') {
    if (this.destroyed) return;
    const [start, end] = this.range();
    this.start = start;
    this.cutoff = end;
    const g = this.globalPage(this.ch, this.page);
    this.onPage({ reason, ch: this.ch, page: this.page, pages: this.pages, start, cutoff: end, global: g, total: this.totalPages(), exact: this.exact() });
  }

  async next() {
    if (this.busy) return;
    if (this.page + 1 < this.pages) return this.go(this.page + 1);
    if (this.ch + 1 < this.chapters.length) {
      this.busy = true;
      try { await this.showChapter(this.ch + 1, 0); } finally { this.busy = false; }
    }
  }

  async prev() {
    if (this.busy) return;
    if (this.page > 0) return this.go(this.page - 1);
    if (this.ch > 0) {
      this.busy = true;
      try { await this.showChapter(this.ch - 1, 'end'); } finally { this.busy = false; }
    }
  }

  drag(dx) {
    this.flow.classList.remove('anim');
    let d = dx;
    if ((dx > 0 && this.page === 0 && this.ch === 0) || (dx < 0 && this.page === this.pages - 1 && this.ch === this.chapters.length - 1)) d = dx * 0.25;
    this.flow.style.transform = `translateX(${-this.page * this.m.stride + d}px)`;
  }

  settle() { this.go(this.page, true); }

  async relayout() {
    if (this.destroyed) return;
    const anchor = this.start ?? this.chapters[Math.max(0, this.ch)].o0;
    this.applyMetrics();
    if (this.ch < 0) return;
    await settle(this.flow);
    if (this.destroyed) return;
    this.layout.textIndex = new WeakMap();
    this.pages = this.layout.count(this.m.stride);
    this.saveCount(this.ch, this.pages);
    this.go(clamp(this.layout.pageOf(anchor, this.m.stride), 0, this.pages - 1), false, 'layout');
    this.measureAll();
  }

  clearMarks(className) {
    for (const mark of this.flow.querySelectorAll(`.${className}`)) {
      const parent = mark.parentNode;
      mark.replaceWith(...mark.childNodes);
      parent?.normalize();
    }
    this.layout.textIndex = new WeakMap();
  }

  mark(s, e, className = 'srcmark', attrs = {}, preserveExisting = false) {
    if (className !== 'srcmark' && !preserveExisting) this.clearMarks(className);
    const made = [];
    const els = this.layout.blockEls;
    for (const el of els) {
      const o = +el.dataset.o;
      if (o > e) break;
      const nodes = this.layout.nodes(el);
      if (o + (nodes.len || 0) < s) continue;
      if (!nodes.length) continue;
      const lo = clamp(s - o, 0, nodes.len), hi = clamp(e - o, 0, nodes.len);
      // Wrap each text-node fragment separately. This preserves nested person buttons
      // when an underline crosses a highlighted name.
      for (const [node, at] of [...nodes].reverse()) {
        const a = Math.max(0, lo - at), z = Math.min(node.length, hi - at);
        if (z <= a) continue;
        try {
          const r = document.createRange(); r.setStart(node, a); r.setEnd(node, z);
          const mk = h('span', { class: className, ...attrs, 'data-start': s, 'data-end': e });
          r.surroundContents(mk); made.push(mk);
        } catch { /* marking is cosmetic */ }
      }
      this.layout.textIndex.delete(el);
    }
    return made.reverse();
  }

  // ---------------------------------------------------------------- global page numbers
  cpp() {
    let chars = 0, pages = 0;
    for (const [n, c] of this.counts) { chars += this.chapters[n].o1 - this.chapters[n].o0; pages += c; }
    if (pages >= 3) return chars / pages;
    const m = this.m;
    return (m.pw / m.fs) * Math.floor(m.ph / (m.fs * this.settings.lh)) * 0.88;
  }

  countOf(n) {
    return this.counts.get(n) ?? Math.max(1, Math.round((this.chapters[n].o1 - this.chapters[n].o0) / this.cpp()));
  }

  globalPage(n, page) {
    let g = 0;
    for (let i = 0; i < n; i++) g += this.countOf(i);
    return g + page + 1;
  }

  totalPages() {
    let g = 0;
    for (let i = 0; i < this.chapters.length; i++) g += this.countOf(i);
    return g;
  }

  exact() { return this.counts.size >= this.chapters.length; }

  // approximate page number of any text position (exact within the open chapter)
  pageNumberOf(pos) {
    const n = this.chapterAt(pos);
    if (n === this.ch) return this.globalPage(n, this.layout.pageOf(pos, this.m.stride));
    const c = this.chapters[n];
    const frac = (pos - c.o0) / Math.max(1, c.o1 - c.o0);
    return this.globalPage(n, Math.min(this.countOf(n) - 1, Math.floor(frac * this.countOf(n))));
  }

  // position at the start of global page g (exact if that chapter has been measured)
  posOfPage(g) {
    let acc = 0;
    for (let n = 0; n < this.chapters.length; n++) {
      const c = this.countOf(n);
      if (g <= acc + c) {
        const k = g - acc - 1;
        const ch = this.chapters[n];
        return { ch: n, page: k, pos: Math.round(ch.o0 + (ch.o1 - ch.o0) * (k / c)) };
      }
      acc += c;
    }
    const last = this.chapters[this.chapters.length - 1];
    return { ch: this.chapters.length - 1, page: this.countOf(this.chapters.length - 1) - 1, pos: last.o1 - 1 };
  }

  async gotoPage(g) {
    const t = this.posOfPage(g);
    if (t.ch !== this.ch) await this.showChapter(t.ch, 0);
    this.go(clamp(t.page, 0, this.pages - 1), false);
  }

  // Lay out every chapter off-screen once to get exact page numbers (small books only).
  async measureAll() {
    const token = ++this.measureToken;
    const len = this.book.len || 0;
    if (this.destroyed || document.hidden || !canReachLibrary() || navigator.connection?.saveData || len > 3_000_000 || this.chapters.length > 600) return;
    const started = performance.now();
    let measured = 0;
    const probe = h('div', { class: 'viewport', style: { position: 'fixed', left: '-10000px', top: '0', visibility: 'hidden', width: this.m.pw + 'px', height: this.m.ph + 'px' } });
    const flow = h('div', { class: 'flow', lang: this.book.lang || 'zh-CN' });
    probe.append(flow);
    this.stage.append(probe);
    const lay = new ChapterLayout(flow);
    try {
      const candidates = [...new Set([this.ch + 1, this.ch - 1, ...this.chapters.map((_, n) => n)])].filter((n) => n >= 0 && n < this.chapters.length);
      for (const n of candidates) {
        if (this.destroyed || document.hidden || token !== this.measureToken || measured >= 3 || performance.now() - started > 1000) return;
        if (this.counts.has(n)) continue;
        const data = await this.fetchChapter(n).catch(() => null);
        if (!data || token !== this.measureToken) continue;
        lay.render(data, this.book.id, this.chapters[n]);
        await settle(flow);
        this.saveCount(n, lay.count(this.m.stride));
        measured++;
        await idle();
      }
      if (token === this.measureToken) this.emit();
    } finally {
      probe.remove();
    }
  }

  destroy() { this.destroyed = true; this.measureToken++; this.showToken++; this.cache.clear(); this.aheadCache.clear(); this.onPage = () => {}; }
}

async function settle(flow) {
  const imgs = [...flow.querySelectorAll('img')].filter((i) => !i.complete);
  await Promise.race([Promise.all(imgs.map((i) => i.decode().catch(() => {}))), new Promise((r) => setTimeout(r, 1500))]);
  await document.fonts?.ready;
  await new Promise((r) => requestAnimationFrame(() => r()));
}

function idle() {
  return new Promise((r) => (window.requestIdleCallback ? requestIdleCallback(() => r(), { timeout: 200 }) : setTimeout(r, 16)));
}
