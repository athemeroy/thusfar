// Jev chooses promising sentences for each page. A deliberate tap asks the
// writing model and opens a reading-comment drawer attached to that sentence.
import { api } from './api.js';
import { h, toast } from './util.js';
import { t as tr } from './i18n.js';

export const MARGINALIA_PERSONAS = [
  ['auto', tr('随故事'), tr('由这一页的情绪、线索与写法决定')],
  ['empathy', tr('共情'), tr('贴近人物没说出口的情绪')],
  ['detective', tr('侦探'), tr('只看已经出现的细节与照应')],
  ['cold', tr('冷眼'), tr('看人情、体面与自欺')],
  ['scholar', tr('学者'), tr('看措辞、视角与结构')],
  ['wit', tr('吐槽'), tr('轻巧说出反差，不抢戏')],
];
const LABELS = Object.fromEntries(MARGINALIA_PERSONAS.map(([id, label]) => [id, label]));

export class Marginalia {
  constructor({ stage, reader, book, settings, notebook, signal, getInfo }) {
    Object.assign(this, { stage, reader, book, settings, notebook, signal, getInfo });
    this.token = 0;
    this.results = new Map();
    this.inflight = new Map();
    this.cueResults = new Map();
    this.cueInflight = new Map();
    this.items = [];
    this.drawerToken = 0;
    this.hint = h('span', { class: 'marginalia-hint', role: 'status', hidden: true });
    this.scrim = h('button', { type: 'button', class: 'marginalia-scrim', hidden: true,
      'aria-label': tr('关闭这句的评论'), onclick: () => this.closeDrawer() });
    this.drawer = h('section', { class: 'marginalia-drawer', role: 'dialog',
      'aria-label': tr('这句的评论'), 'aria-modal': 'true', hidden: true });
    for (const event of ['pointerdown', 'pointerup', 'click'])
      this.drawer.addEventListener(event, (e) => e.stopPropagation());
    this.composer = h('section', { class: 'marginalia-composer', hidden: true, 'aria-label': tr('选择 AI 批注口吻') });
    stage.append(this.hint, this.scrim, this.drawer, this.composer);
    this.onCueKey = (event) => {
      if (event.key === 'Escape' && !this.drawer.hidden) { event.stopPropagation(); this.closeDrawer(); return; }
      if ((event.key === 'Enter' || event.key === ' ') && event.target.closest('.marginalia-cue')) {
        event.preventDefault(); this.openCue(event.target.closest('.marginalia-cue'));
      }
    };
    stage.addEventListener('keydown', this.onCueKey);
  }

  async page(info) {
    const token = ++this.token;
    this.hide();
    if (!this.settings.aiComments || !info || this.signal?.aborted) return;
    const key = `${info.start}:${info.cutoff}`;
    let request = this.cueResults.get(key);
    if (!request) {
      request = this.cueInflight.get(key);
      if (!request) {
        request = api.marginalia(this.book.id, {
          mode: 'cues', purpose: 'visible', pos: info.cutoff,
          page_start: info.start, page_end: info.cutoff, persona: 'auto',
        }, { signal: this.signal });
        this.cueInflight.set(key, request);
      }
    }
    let result;
    try { result = await request; } catch (error) {
      if (token === this.token && !this.signal?.aborted) {
        this.hint.textContent = error.message || tr('暂时找不到可评论的句子'); this.hint.hidden = false;
      }
      return;
    } finally { this.cueInflight.delete(key); }
    this.cueResults.set(key, result);
    if (this.cueResults.size > 40) this.cueResults.delete(this.cueResults.keys().next().value);
    if (token !== this.token || this.signal?.aborted || this.getInfo()?.start !== info.start ||
        this.getInfo()?.cutoff !== info.cutoff) return;
    for (const row of result.items || []) {
      this.reader.mark(row.start, row.end, 'marginalia-cue', {
        role: 'button', tabindex: '0', 'aria-label': tr('查看这句的评论'),
        'data-start': row.start, 'data-end': row.end, 'data-persona': row.persona,
        'data-quote': row.quote,
      }, true);
    }
  }

  openCue(cue) {
    if (!cue || cue.classList.contains('loading') || !this.settings.aiComments) return;
    const info = this.getInfo();
    const start = Number(cue.dataset.start), end = Number(cue.dataset.end);
    if (!info || start < info.start || end > info.cutoff || end <= start) return;
    const viewToken = this.openDrawer();
    this.loadCue(cue, info, start, end, viewToken);
  }

  async loadCue(cue, info, start, end, viewToken) {
    const token = this.token;
    const persona = this.settings.aiPersona && this.settings.aiPersona !== 'auto'
      ? this.settings.aiPersona : cue.dataset.persona || 'auto';
    const key = `${start}:${end}:${persona}`;
    cue.classList.add('loading');
    try {
      let request = this.inflight.get(key);
      if (!request) {
        request = this.results.has(key) ? Promise.resolve(this.results.get(key)) : api.marginalia(this.book.id, {
          mode: 'auto', purpose: 'visible', pos: info.cutoff,
          page_start: start, page_end: end, persona,
        }, { signal: this.signal });
        this.inflight.set(key, request);
      }
      const result = await request;
      this.results.set(key, result);
      if (this.results.size > 40) this.results.delete(this.results.keys().next().value);
      if (token !== this.token || viewToken !== this.drawerToken || !this.settings.aiComments || this.signal?.aborted ||
          this.getInfo()?.start !== info.start || this.getInfo()?.cutoff !== info.cutoff) return;
      if (result.items?.length) this.display(result.items);
      else if (result.comment) this.show(result);
      else this.status(tr('这句暂时没有合适的评论'));
    } catch (error) {
      if (token !== this.token || viewToken !== this.drawerToken || !this.settings.aiComments || this.signal?.aborted) return;
      this.status(error.message || tr('评论暂时没有生成，点虚线可重试'));
    } finally {
      cue.classList.remove('loading');
      this.inflight.delete(key);
    }
  }

  openDrawer() {
    const token = ++this.drawerToken;
    this.renderDrawer(h('p', { class: 'marginalia-drawer-wait', role: 'status' }, tr('正在生成评论…')));
    return token;
  }

  renderDrawer(content, actions = []) {
    const close = h('button', { type: 'button', class: 'marginalia-drawer-close',
      'aria-label': tr('关闭评论'), onclick: () => this.closeDrawer() }, tr('关闭'));
    this.drawer.replaceChildren(
      h('div', { class: 'marginalia-drawer-grip', 'aria-hidden': 'true' }),
      h('header', {}, h('span', { class: 'marginalia-drawer-kicker' }, tr('原文边上')), close),
      h('h2', {}, tr('这句的评论')),
      h('div', { class: 'marginalia-drawer-body' }, content),
      h('footer', {}, ...actions),
    );
    this.scrim.hidden = false;
    this.drawer.hidden = false;
  }

  status(message) {
    this.renderDrawer(h('p', { class: 'marginalia-drawer-error', role: 'status' }, message));
  }

  closeDrawer() {
    this.drawerToken++;
    this.drawer.hidden = true;
    this.scrim.hidden = true;
    this.reader.clearMarks('ai-underline');
  }

  compose(draft, preset) {
    this.token++;
    this.hide();
    const chosen = preset && preset !== 'auto' ? preset
      : this.settings.aiPersona && this.settings.aiPersona !== 'auto' ? this.settings.aiPersona : 'empathy';
    let persona = chosen;
    const quote = h('blockquote', {}, draft.quote);
    const status = h('p', { class: 'marginalia-compose-status muted', role: 'status' }, tr('选一种读法，AI 只会看到这句话之前的内容。'));
    const chips = h('div', { class: 'marginalia-personas' });
    const renderChips = () => {
      chips.replaceChildren(...MARGINALIA_PERSONAS.filter(([id]) => id !== 'auto').map(([id, label]) =>
        h('button', { class: id === persona ? `on persona-${id}` : `persona-${id}`, onclick: () => { persona = id; renderChips(); } }, label)));
    };
    const send = h('button', { class: 'btn primary', onclick: async () => {
      send.disabled = true;
      chips.querySelectorAll('button').forEach((button) => { button.disabled = true; });
      status.classList.remove('muted'); status.textContent = tr("{0}正在读这一句…", [LABELS[persona]]);
      const token = ++this.token;
      try {
        const info = this.getInfo();
        const result = await api.marginalia(this.book.id, {
          mode: 'manual', pos: info.cutoff, start: draft.start, end: draft.end, persona,
        }, { signal: this.signal });
        if (token !== this.token || this.signal?.aborted) return;
        this.composer.hidden = true;
        this.show(result);
      } catch (error) {
        if (!this.signal?.aborted) {
          status.textContent = error.message;
          send.disabled = false;
          chips.querySelectorAll('button').forEach((button) => { button.disabled = false; });
        }
      }
    } }, tr('写一句'));
    const close = h('button', { class: 'linkish', onclick: () => { this.token++; this.composer.hidden = true; } }, tr('取消'));
    renderChips();
    this.composer.replaceChildren(h('header', {}, h('b', {}, tr('让 AI 在这里留一笔')), close), quote, chips,
      h('div', { class: 'marginalia-compose-actions' }, status, send));
    this.composer.hidden = false;
  }

  show(result) { this.display([result], true); }

  display(items, manual = false) {
    this.reader.clearMarks('ai-underline');
    if (!items.length) return;
    this.composer.hidden = true;
    this.items = items;
    if (manual) this.reader.mark(items[0].start, items[0].end, 'ai-underline', {}, true);
    const comments = h('div', { class: 'marginalia-drawer-comments' }, ...items.map((result) =>
      h('article', { class: 'marginalia-drawer-comment' },
        h('div', { class: 'marginalia-drawer-byline' }, h('b', {}, tr('AI 读者短评')),
          h('span', {}, LABELS[result.persona] || tr('随故事'))),
        h('p', {}, result.comment),
        h('button', { type: 'button', class: 'marginalia-drawer-save',
          onclick: () => this.save(result) }, tr('收进摘记')))));
    const actions = manual ? [h('button', { type: 'button', class: 'marginalia-drawer-remix',
      onclick: () => this.compose(items[0], items[0].persona) }, tr('换个口吻'))] : [];
    this.renderDrawer(comments, actions);
  }

  async save(result) {
    try {
      await this.notebook.save({ kind: 'note', start: result.start, end: result.end, quote: result.quote,
        text: `AI · ${LABELS[result.persona] || tr('批注')}：${result.comment}`,
        knowledge_cutoff: result.knowledge_cutoff ?? result.end });
      toast(tr('这条批注已收到摘记'));
    } catch (error) { toast(error.message, 5000); }
  }

  hide() {
    this.closeDrawer();
    this.hint.hidden = true;
    this.reader.clearMarks('marginalia-cue');
    this.items = [];
  }

  destroy() {
    this.token++;
    this.stage.removeEventListener('keydown', this.onCueKey);
    this.reader.clearMarks('ai-underline');
    this.reader.clearMarks('marginalia-cue');
    this.hint.remove(); this.scrim.remove(); this.drawer.remove(); this.composer.remove();
  }
}
