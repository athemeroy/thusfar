// 前情提要 · 问问这本书 · 目录 · 排版

import { api } from './api.js';
import { h, icon, avatar, paragraphs, toast, maskTitle, store } from './util.js';
import { downloadBook } from './offline.js';
import { standalone } from './runtime.js';
import { t as tr, currentLanguage } from './i18n.js';

export function recapView(ctx, _arg, pane, title) {
  const w = ctx.world;
  title.append(tr('前情提要'), h('small', {}, tr("截至第 {0} 页", [ctx.info.global])));
  if (w.saga) {
    pane.append(h('div', { class: 'saga' }, paragraphs(w.saga.text)));
    pane.append(h('p', { class: 'muted' }, tr("以上概括到「{0}」结束。", [ctx.chapterName(w.saga.p)])));
  } else {
    pane.append(h('div', { class: 'empty' }, h('b', {}, '〇'), tr('还没读完第一章，暂时没有前情提要。')));
  }
  const chStart = ctx.chapterStart();
  const sinceCh = w.events.filter((e) => e.p >= chStart);
  if (sinceCh.length) {
    const list = h('ul', { class: 'tl' });
    for (const e of sinceCh) list.append(h('li', { class: `imp${e.imp}` }, h('div', { class: 'tx' }, e.text),
      h('button', { type: 'button', class: 'at', onclick: () => ctx.goSource(e.s, e.p) }, tr("第 {0} 页", [ctx.pageNo(e.s)]))));
    pane.append(h('div', { class: 'sec' }, h('h4', {}, tr('本章到这里')), list));
  }
  if (w.recaps.length) {
    const ul = h('ul', { class: 'recaps' });
    for (const r of [...w.recaps].reverse()) {
      ul.append(h('li', {}, h('button', { type: 'button', class: 'recap-link', onclick: () => ctx.gotoChapter(r.chapter) }, h('b', {}, ctx.chapterTitle(r.chapter)), h('p', {}, r.text))));
    }
    pane.append(h('div', { class: 'sec' }, h('h4', {}, tr('各章梗概')), ul));
  }
  ctx.statusLine(pane);
}

export function askView(ctx, _arg, pane, title) {
  title.append(tr('问问这本书'), h('small', {}, tr("只根据前 {0} 页回答", [ctx.info.global])));
  const chat = h('div', { class: 'chat' });
  const hist = ctx.askHistory;
  const ta = h('textarea', { rows: 1, placeholder: tr('比如：他为什么要这样做？'), enterkeyhint: 'send' });
  const send = h('button', { 'aria-label': tr('发送') }, icon('send'));
  const cancel = h('button', { type: 'button', hidden: true }, tr('取消回答'));
  ta.setAttribute('aria-label', tr('向已读内容提问'));
  let pending = null, disposed = false;
  ctx.onLeave(() => { disposed = true; pending?.abort(); });
  cancel.addEventListener('click', () => pending?.abort());
  const people = ctx.pagePeople().map((id) => ctx.world.people.get(id)).filter(Boolean);
  const sugg = [];
  if (people[0]) sugg.push(tr("{0}是个什么样的人？", [people[0].name]));
  if (people[1]) sugg.push(tr("{0}和{1}是什么关系？", [people[0].name, people[1].name]));
  sugg.push(tr('刚才这一段发生了什么？'), tr('到目前为止，故事讲了什么？'));
  const suggest = h('div', { class: 'suggest' }, sugg.map((q) => h('button', { onclick: () => ask(q) }, q)));
  pane.append(h('p', { class: 'muted', style: { marginTop: '0' } }, tr('问题按当前页截止。回答经过模型核对，仍可能有误；可点出处查看原文。')), suggest, chat,
    h('div', { class: 'ask-bar' }, ta, send), cancel);

  const renderMsg = (m) => {
    if (m.me) return h('div', { class: 'msg me' }, m.text);
    const body = h('div', { class: 'msg ai' });
    const parts = m.text.split(/(\[\d+\])/);
    for (const part of parts) {
      const mm = /^\[(\d+)\]$/.exec(part);
      if (mm) {
        const c = m.cites.find((c) => c.n === +mm[1]);
        body.append(c ? h('button', { type: 'button', class: 'cite', title: c.text, onclick: () => ctx.goSource(c.o, c.o + c.text.length) }, tr("[{0}页]", [ctx.pageNo(c.o)])) : '');
      } else body.append(part);
    }
    const meta = h('div', { class: 'meta' });
    if (m.guard?.verdict === 'ok') meta.append(h('span', { class: 'check' }, icon('check'), tr('已通过模型核对，可复核原文')));
    else if (m.guard?.verdict === 'rewritten') meta.append(h('span', { class: 'check' }, icon('check'), tr('校验后已重写')));
    else if (m.guard?.verdict === 'uncertain') meta.append(h('span', {}, tr('⚠ 校验不确定，请谨慎参考')));
    else if (m.guard?.verdict === 'withheld') meta.append(h('span', {}, tr('校验未通过或暂不可用，未提供推断性回答')));
    else if (m.guard?.verdict === 'safe') meta.append(h('span', {}, tr('已保留后文信息')));
    if (m.route === 'future') meta.append(h('span', {}, tr('这个问题涉及后文')));
    meta.append(h('span', {}, tr("截至第 {0} 页", [m.page])));
    body.append(meta);
    return body;
  };
  for (const m of hist) if (m.cutoff <= ctx.info.cutoff && m.generation === ctx.generation) chat.append(renderMsg(m));

  async function ask(q) {
    q = q.trim();
    if (!q || disposed || pending) return;
    const current = ctx.current();
    const cutoff = current.info.cutoff, page = current.info.global, generation = current.generation;
    const controller = new AbortController(); pending = controller;
    const leave = () => controller.abort(); ctx.signal?.addEventListener('abort', leave, { once: true });
    send.disabled = true; cancel.hidden = false;
    ta.value = '';
    suggest.remove();
    const mine = { me: true, text: q, cutoff, generation, page };
    hist.push(mine);
    chat.append(renderMsg(mine));
    const line = h('div', { class: 'stage-line' }, tr('正在思考'));
    chat.append(line);
    line.scrollIntoView({ block: 'end', behavior: 'smooth' });
    try {
      let done = false;
      await api.ask(ctx.book.id, q, cutoff, (kind, d) => {
        if (disposed || controller.signal.aborted || ctx.current().info.cutoff < cutoff || ctx.current().generation !== generation) return;
        if (kind === 'stage') line.textContent = d.text;
        if (kind === 'answer') {
          done = true;
          line.remove();
          if (typeof d.text !== 'string' || !Array.isArray(d.cites)) throw new Error(tr('回答格式不正确，请重试'));
          const m = { ...d, page, cutoff, generation };
          hist.push(m);
          const el = renderMsg(m);
          chat.append(el);
          el.scrollIntoView({ block: 'start', behavior: 'smooth' });
        }
        if (kind === 'error') { line.textContent = d.message; done = true; }
      }, { signal: controller.signal });
      if (!done) line.textContent = tr('连接断开了，请再试一次。');
    } catch (e) {
      if (!disposed) line.textContent = controller.signal.aborted ? tr('已取消回答') : e.message;
    } finally { ctx.signal?.removeEventListener('abort', leave); pending = null; send.disabled = false; cancel.hidden = true; }
  }
  send.addEventListener('click', () => ask(ta.value));
  ta.addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey && !e.isComposing) { e.preventDefault(); ask(ta.value); } });
  ta.addEventListener('input', () => { ta.style.height = 'auto'; ta.style.height = Math.min(120, ta.scrollHeight) + 'px'; });
}

export function tocView(ctx, _arg, pane, title) {
  title.append(tr('导航'), h('small', {}, tr("第 {0} / {1}{2} 页", [ctx.info.global, ctx.info.exact ? '' : tr('约 '), ctx.info.total])));
  const nav = h('nav', { class: 'reader-nav-tabs', 'aria-label': tr('书内导航') },
    h('button', { type: 'button', class: 'on', 'aria-current': 'page' }, icon('toc'), tr('目录')),
    h('button', { type: 'button', onclick: () => ctx.panes.open('search', undefined, { replace: true, full: true }) }, icon('search'), tr('搜索原文')));
  let reveal = store.get(`toc-reveal:${ctx.book.id}`, false);
  const unread = (c) => c.o0 >= ctx.info.cutoff && c.spoil !== false;
  const visibleTitle = (c, n) => !reveal && unread(c) ? tr("{0} · 未读", [maskTitle(c.title)]) : c.title || tr("第 {0} 节", [n + 1]);
  const filter = h('input', { type: 'search', class: 'reader-toc-filter', 'aria-label': tr('筛选目录'), placeholder: tr('按可见章节名查找'), autocomplete: 'off', maxlength: 160 });
  const sections = h('div', { class: 'reader-toc-sections' });
  const info = h('p', { class: 'muted', role: 'status' });
  let current = null;
  function render() {
    sections.replaceChildren(); current = null;
    const query = filter.value.trim().toLocaleLowerCase();
    let count = 0, group = null, kind = null;
    const labels = { front: tr('开篇与前言'), body: tr('正文'), back: tr('附录与后记') };
    ctx.book.chapters.forEach((c, n) => {
      const label = visibleTitle(c, n);
      // Filtering uses only the displayed label; hidden titles never enter search text or attributes.
      if (query && !label.toLocaleLowerCase().includes(query)) return;
      count++;
      const k = c.kind || 'body';
      if (kind !== k) {
        kind = k; group = h('ul', { class: 'toc' });
        sections.append(h('section', { class: 'reader-toc-group' }, h('h4', {}, labels[k] || tr('章节')), group));
      }
      const li = h('li', { class: `d${Math.min(1, c.depth || 0)} ${k} ${n === ctx.info.ch ? 'cur' : ''} ${!reveal && unread(c) ? 'masked' : ''}` },
        h('button', { type: 'button', 'aria-current': n === ctx.info.ch ? 'location' : null, onclick: () => ctx.gotoChapter(n) },
          h('span', {}, label), h('span', { class: 'pg' }, ctx.pageNo(c.o0))));
      if (n === ctx.info.ch) current = li;
      group.append(li);
    });
    info.textContent = query ? tr("找到 {0} 节；隐藏的未读标题不参与筛选。", [count]) : tr("{0} 节 · 点章节可跳转，随后可返回刚才的阅读位置。", [ctx.book.chapters.length]);
    if (!count) sections.append(h('p', { class: 'reader-toc-empty' }, tr('没有找到可见的章节名。可以换个关键词，或切到“搜索原文”。')));
  }
  const chapter = ctx.book.chapters[ctx.info.ch];
  pane.append(nav, h('div', { class: 'reader-toc-current' },
    h('div', {}, tr('正在读'), h('strong', {}, visibleTitle(chapter, ctx.info.ch))),
    h('button', { type: 'button', onclick: () => { filter.value = ''; render(); current?.scrollIntoView({ block: 'center', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' }); } }, tr('定位本章'))));
  const input = h('input', { type: 'number', inputmode: 'numeric', min: 1, max: ctx.info.total, placeholder: `1 – ${ctx.info.total}`, 'aria-label': tr('页码') });
  const jumpStatus = h('p', { class: 'muted', role: 'status', hidden: true });
  const go = () => {
    const n = Number(input.value);
    if (!Number.isInteger(n) || n < 1 || n > ctx.info.total) { jumpStatus.textContent = tr("请输入 1 至 {0} 之间的整数页码。", [ctx.info.total]); jumpStatus.hidden = false; input.focus(); return; }
    ctx.gotoPage(n);
  };
  input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); go(); } });
  pane.append(h('div', { class: 'jump' }, h('label', {}, tr('跳到第')), input, h('label', {}, /^(zh|ja|ko)/.test(currentLanguage()) ? tr('页') : ''), h('button', { type: 'button', class: 'btn zhu', onclick: go }, tr('跳转'))), jumpStatus);
  if (!ctx.info.exact) pane.append(h('p', { class: 'muted' }, tr('总页数仍在估算；目录按原文位置定位，不受字号和屏幕大小影响。')));
  if (ctx.book.chapters.some(unread)) {
    const toggle = h('button', { type: 'button', class: 'switch' + (reveal ? ' on' : ''), role: 'switch', 'aria-label': tr('显示未读章节标题（可能剧透）'), 'aria-checked': reveal });
    toggle.addEventListener('click', () => { reveal = !reveal; store.set(`toc-reveal:${ctx.book.id}`, reveal); toggle.classList.toggle('on', reveal); toggle.setAttribute('aria-checked', String(reveal)); render(); });
    pane.append(h('div', { class: 'set-row reader-toc-reveal' }, h('label', {}, tr('显示未读章节标题'), h('small', { class: 'muted' }, tr('未读且可能剧透的标题默认隐藏。开启后会看到后文信息。'))), toggle));
  }
  pane.append(filter, info, sections);
  filter.addEventListener('input', render);
  render();
}

async function cacheBook(ctx, btn) {
  if (btn._download) { btn._download.abort(); return; }
  const controller = new AbortController(); btn._download = controller;
  const leave = () => controller.abort(); ctx.signal?.addEventListener('abort', leave, { once: true });
  btn.textContent = tr('准备离线下载（点此取消）');
  try {
    await downloadBook(ctx.book.id, (n, total) => { btn.textContent = tr("下载 {0}/{1} · 点此取消", [n, total]); }, controller.signal);
    btn.textContent = tr('已离线下载 · 正文、插图和现有资料');
  } catch (e) { btn.textContent = controller.signal.aborted ? tr('已暂停 · 点击继续离线下载') : tr('下载未完成 · 点击重试'); toast(e.message, 5000); }
  finally { btn._download = null; ctx.signal?.removeEventListener('abort', leave); }
}

export function settingsView(ctx, _arg, pane, title) {
  title.append(tr('排版与显示'));
  const s = ctx.settings;
  const set = (k, v) => { s[k] = v; ctx.saveSettings(); ctx.applySettings(); pane.textContent = ''; ctx.panes.render(false); };
  const stepper = (k, step, min, max, fmt) => h('div', { class: 'stepper' },
    h('button', { 'aria-label': tr('减小字号'), onclick: () => set(k, Math.max(min, +(s[k] - step).toFixed(2))) }, '−'), h('span', {}, fmt(s[k])),
    h('button', { 'aria-label': tr('增大字号'), onclick: () => set(k, Math.min(max, +(s[k] + step).toFixed(2))) }, '+'));
  const chips = (k, opts) => h('div', { class: 'chips' }, opts.map(([v, label]) => h('button', { class: s[k] === v ? 'on' : '', onclick: () => set(k, v) }, label)));
  const themes = [['paper', '#f4efe4', tr('纸')], ['amber', '#efe3c8', tr('米')], ['celadon', '#e6ece3', tr('青')], ['night', '#171512', tr('夜')]];
  const voices = [['auto', tr('随故事')], ['empathy', tr('共情')], ['detective', tr('侦探')], ['cold', tr('冷眼')], ['scholar', tr('学者')], ['wit', tr('吐槽')]];
  const rows = [
    h('div', { class: 'set-row' }, h('label', {}, tr('字号')), stepper('fs', 1, 14, 28, (v) => v)),
    h('div', { class: 'set-row' }, h('label', {}, tr('行距')), chips('lh', [[1.6, tr('紧')], [1.9, tr('适中')], [2.2, tr('松')]])),
    h('div', { class: 'set-row' }, h('label', {}, tr('字体')), chips('font', [['serif', tr('宋体')], ['kai', tr('楷体')], ['sans', tr('黑体')]])),
    h('div', { class: 'set-row' }, h('label', {}, tr('背景')), h('div', { class: 'chips' }, themes.map(([v, c, t]) =>
      h('button', { class: 'swatch' + (s.theme === v ? ' on' : ''), style: { background: c, color: v === 'night' ? '#ccc' : '#555' }, 'aria-label': t, onclick: () => set('theme', v) }, t)))),
    h('div', { class: 'set-row' }, h('label', {}, tr('人名批注（朱线）')), h('button', { class: 'switch' + (s.names ? ' on' : ''), role: 'switch', 'aria-label': tr('人名批注'), 'aria-checked': s.names, onclick: () => set('names', !s.names) })),
    h('div', { class: 'set-row ai-comments-setting' }, h('label', {}, tr('读者评论'), h('small', { class: 'muted' }, tr('先标出值得评论的句子；点虚线后才生成评论'))), h('button', { class: 'switch' + (s.aiComments ? ' on' : ''), role: 'switch', 'aria-label': tr('读者评论'), 'aria-checked': s.aiComments, onclick: () => set('aiComments', !s.aiComments) })),
    s.aiComments ? h('div', { class: 'set-row ai-voice-setting' }, h('label', {}, tr('评论口吻')), chips('aiPersona', voices)) : null,
    h('div', { class: 'set-row' }, h('label', {}, tr('翻页动画')), h('button', { class: 'switch' + (s.anim ? ' on' : ''), role: 'switch', 'aria-label': tr('翻页动画'), 'aria-checked': s.anim, onclick: () => set('anim', !s.anim) })),
    window.YeduApp ? h('div', { class: 'set-row' }, h('label', {}, tr('音量键翻页')), h('button', { class: 'switch' + (s.volKeys ? ' on' : ''), role: 'switch', 'aria-label': tr('音量键翻页'), 'aria-checked': s.volKeys, onclick: () => set('volKeys', !s.volKeys) })) : null,
    window.YeduApp ? h('div', { class: 'set-row' }, h('label', {}, tr('阅读时全屏')), h('button', { class: 'switch' + (s.immersive ? ' on' : ''), role: 'switch', 'aria-label': tr('阅读时全屏'), 'aria-checked': s.immersive, onclick: () => set('immersive', !s.immersive) })) : null,
  ];
  pane.append(...rows.filter(Boolean));
  pane.append(h('p', { class: 'muted' }, standalone ? tr('书籍类型与整理进度已放在「资料 → 管理本书」。') : tr('离线下载、书籍类型与整理进度已放在「资料 → 管理本书」。')));
}

export function bookSettingsView(ctx, _arg, pane, title) {
  title.append(tr('管理本书'));
  const KINDS = [['novel', tr('小说')], ['biography', tr('传记 / 纪实')], ['collection', tr('合集')], ['nonfiction', tr('非虚构 / 知识类')], ['reference', tr('工具书')]];
  const kind = ctx.book.genre || 'novel';
  pane.append(h('div', { class: 'sec' }, h('h4', {}, tr('这本书是')),
    h('div', { class: 'chips' }, KINDS.map(([v, label]) => h('button', {
      class: kind === v ? 'on' : '',
      onclick: async (e) => { e.currentTarget.disabled = true; try { await api.setKind(ctx.book.id, v, { signal: ctx.signal }); ctx.book.genre = v; ctx.panes.render(false); } catch (err) { toast(err.message); e.target.disabled = false; } },
    }, label))),
    h('p', { class: 'muted', style: { margin: '6px 0 0', fontSize: '13px' } },
      kind === 'nonfiction' ? tr('知识类的书整理的是术语与概念：点一个词，看到的是读到这一页为止它被怎么定义的。')
        : kind === 'collection' ? tr('合集里每部作品的人物互不相通，不会把上一篇的人认成这一篇的。')
          : kind === 'reference' ? tr('工具书没有阅读顺序，人物/术语卡片意义不大。')
            : tr('叙事类的书整理人物、关系和经历，只写到你读到的那一页。'))));
  const offline = h('button', { title: tr('下载全文、插图和当前已整理的资料；显示仍按当前页截止'), onclick: () => cacheBook(ctx, offline) }, tr('离线下载本书'));
  pane.append(h('div', { class: 'sec' }, h('h4', {}, tr('这本书')),
    h('div', { class: 'chips' }, standalone ? null : offline,
      h('button', { onclick: async (e) => { if (confirm(tr('从书架移除这本书？AI 整理的结果也会一起删除。'))) { e.currentTarget.disabled = true; try { await api.remove(ctx.book.id, { signal: ctx.signal }); navigator.serviceWorker?.controller?.postMessage({ type: 'remove-book', id: ctx.book.id }); location.hash = '#/'; } catch (err) { toast(err.message); e.target.disabled = false; } } } }, tr('从书架移除')))));
  ctx.statusLine(pane);
}
