// Pane stack: a draggable bottom sheet on phones, a permanent margin column on wide screens.

import { h, icon } from './util.js';
import { t as tr } from './i18n.js';

export class Panes {
  constructor(root, views, ctx) {
    this.root = root;
    this.views = views;
    this.ctx = ctx;           // () => context object for views
    this.stack = [];
    this.scrim = h('div', { class: 'scrim', onclick: () => this.close() });
    this.sheet = h('div', { class: 'sheet', role: 'dialog', 'aria-modal': 'true', 'aria-label': tr('阅读批注'), tabindex: -1, inert: true });
    this.grip = h('div', { class: 'grip', 'aria-hidden': 'true' });
    this.sheetPane = h('div', { class: 'pane' });
    this.sheet.append(this.grip, this.sheetPane);
    this.margin = h('aside', { class: 'margin' });
    this.marginPane = h('div', { class: 'pane' });
    this.margin.append(this.marginPane);
    root.append(this.scrim, this.sheet, this.margin);
    this.mq = matchMedia('(min-width: 1080px)');
    this.mediaChange = () => this.render();
    this.mq.addEventListener('change', this.mediaChange);
    this.keyHandler = (e) => {
      if (this.desktop || !this.isOpen) return;
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); this.stack.length > 1 ? this.back() : this.close(); }
      if (e.key !== 'Tab') return;
      const nodes = [...this.sheet.querySelectorAll('button:not(:disabled),input,textarea,a[href],[tabindex="0"]')].filter((n) => n.getClientRects().length);
      const first = nodes[0], last = nodes.at(-1);
      if (!first) { e.preventDefault(); this.sheet.focus(); }
      else if (e.shiftKey && (document.activeElement === first || !this.sheet.contains(document.activeElement))) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && (document.activeElement === last || !this.sheet.contains(document.activeElement))) { e.preventDefault(); first.focus(); }
    };
    this.sheet.addEventListener('keydown', this.keyHandler);
    this.bindDrag();
  }

  get desktop() { return this.mq.matches && this.root.classList.contains('has-margin'); }
  get pane() { return this.desktop ? this.marginPane : this.sheetPane; }
  get top() { return this.stack[this.stack.length - 1]; }
  get isOpen() { return this.desktop || this.sheet.classList.contains('open'); }

  open(view, arg, opts = {}) {
    if (opts.replace || opts.root) this.stack = opts.root ? [] : this.stack.slice(0, -1);
    const t = this.top;
    if (!(t && t.view === view && JSON.stringify(t.arg) === JSON.stringify(arg))) this.stack.push({ view, arg });
    if (!this.desktop) {
      if (!this.sheet.classList.contains('open')) this.previousFocus = document.activeElement;
      this.sheet.inert = false;
      this.sheet.classList.add('open');
      this.sheet.classList.toggle('full', !!opts.full || ['graph', 'ask', 'toc', 'search', 'notebook', 'sourcepreview'].includes(view));
      this.scrim.classList.add('on');
    }
    this.render(true);
    this.onChange?.();
    if (!this.desktop) this.sheet.focus({ preventScroll: true });
  }

  back() {
    this.stack.pop();
    if (!this.stack.length && !this.desktop) return this.close();
    this.render(true);
  }

  close() {
    this.stack = [];
    this.sheet.classList.remove('open', 'full');
    this.sheet.inert = true;
    this.sheet.style.transform = '';
    this.scrim.classList.remove('on');
    if (this.desktop) this.render(true);
    this.onClose?.();
    this.onChange?.();
    if (this.previousFocus?.isConnected) this.previousFocus.focus({ preventScroll: true });
  }

  render(resetScroll = false) {
    if (!this.ctx().world) return;     // first page not laid out yet
    const pane = this.pane;
    const other = this.desktop ? this.sheetPane : this.marginPane;
    other.textContent = '';
    const t = this.top || (this.desktop ? { view: 'here' } : null);
    if (!t) return;
    const scroll = pane.scrollTop;
    const view = this.views[t.view];
    pane.textContent = '';
    const canBack = this.stack.length > 1 || (!this.desktop && this.stack.length === 1) || (this.desktop && this.stack.length >= 1);
    const nav = h('div', { class: 'pane-nav' },
      canBack ? h('button', { class: 'icon-btn', 'aria-label': this.stack.length > 1 ? tr('返回') : tr('关闭'), onclick: () => (this.stack.length > 1 ? this.back() : this.close()) }, icon(this.stack.length > 1 ? 'back' : 'close')) : null,
      h('div', { class: 't' }));
    pane.append(nav);
    this.sheet.setAttribute('aria-label', t.view === 'ask' ? tr('问问这本书') : tr('阅读批注'));
    view(this.ctx(), t.arg, pane, nav.querySelector('.t'), this);
    if (!resetScroll) pane.scrollTop = scroll;
  }

  refresh() {
    if (this.isOpen) this.render(false);
  }

  destroy() { this.onClose?.(); this.mq.removeEventListener('change', this.mediaChange); this.sheet.removeEventListener('keydown', this.keyHandler); this.stack = []; }

  bindDrag() {
    let y0 = null, base = 0, h0 = 0;
    const start = (e) => {
      y0 = e.clientY;
      h0 = this.sheet.getBoundingClientRect().height;
      base = this.sheet.getBoundingClientRect().top - (this.root.getBoundingClientRect().bottom - h0);
      this.sheet.style.transition = 'none';
      this.grip.setPointerCapture?.(e.pointerId);
    };
    const move = (e) => {
      if (y0 == null) return;
      const y = Math.max(0, base + e.clientY - y0);
      this.sheet.style.transform = `translateY(${y}px)`;
    };
    const end = (e) => {
      if (y0 == null) return;
      const dy = e.clientY - y0;
      y0 = null;
      this.sheet.style.transition = '';
      this.sheet.style.transform = '';
      const frac = (base + dy) / h0;
      if (frac > 0.62) this.close();
      else if (frac < 0.18) this.sheet.classList.add('full');
      else this.sheet.classList.remove('full');
    };
    this.grip.addEventListener('pointerdown', start);
    this.grip.addEventListener('pointermove', move);
    this.grip.addEventListener('pointerup', end);
    this.grip.addEventListener('pointercancel', end);
    this.grip.addEventListener('click', () => this.sheet.classList.toggle('full'));
  }
}
