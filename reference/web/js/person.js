// 人物卡 and the lists that lead to it. Everything is computed from world(cutoff), so the
// same card shows a different person at page 100 and at page 300.

import { h, svg, icon, avatar, personColor, initial, words } from './util.js';
import { t as tr } from './i18n.js';

const ATTR_SOURCE = ['身份', '职业', '年龄', '住处', '处境', '生死', '外貌', '性格'];
const ATTR_ORDER = [tr('身份'), tr('职业'), tr('年龄'), tr('住处'), tr('处境'), tr('生死'), tr('外貌'), tr('性格')];
const ATTR_LABELS = { identity: tr('身份'), occupation: tr('职业'), age: tr('年龄'), residence: tr('住处'),
  situation: tr('处境'), alive: tr('生死'), appearance: tr('外貌'), personality: tr('性格') };
export function attributeLabel(key) {
  const source = String(key);
  const index = ATTR_SOURCE.indexOf(source);
  return ATTR_LABELS[source.toLowerCase()] || (index < 0 ? source : ATTR_ORDER[index]);
}

function seal(ctx) {
  return h('div', { class: 'seal', title: tr('人物信息只截至这一页') }, tr('截至'), h('b', {}, ctx.info.global), tr('页'));
}

function pageLink(ctx, s, e, label) {
  return h('button', { type: 'button', class: 'at', onclick: (ev) => { ev.stopPropagation(); ctx.goSource(s, e); } }, label || tr("第 {0} 页", [ctx.pageNo(s)]));
}

function empty(big, text) {
  return h('div', { class: 'empty' }, h('b', {}, big), text);
}

export function personView(ctx, id, pane, title) {
  const w = ctx.world;
  const cid = w.canon(id);
  const p = w.people.get(cid);
  title.append(p?.entityKind === 'concept' ? tr('概念') : tr('人物'), h('small', {}, tr("读到第 {0} 页时", [ctx.info.global])));
  if (!p) {
    pane.append(empty('?', tr('这位人物在这一页还没有登场。往后读一读，就会遇见。')));
    return;
  }
  const prevSeen = ctx.lastSeen(cid);
  ctx.markSeen(cid);

  pane.append(h('div', { class: 'pc-top' },
    h('div', { class: 'pc-head' }, avatar(p),
      h('div', {},
        h('div', { class: 'pc-name' }, p.name),
        p.aliases.length ? h('div', { class: 'pc-alias' }, tr('又称 '), p.aliases.slice(0, 8).join(' · ')) : null,
        p.tagline ? h('div', { class: 'pc-tag' }, p.tagline) : null)),
    seal(ctx)));

  if (p.bio) pane.append(h('p', { class: 'bio' }, p.bio));
  else pane.append(h('p', { class: 'muted', style: { fontFamily: 'var(--kai)', fontSize: '15px' } },
    p.manual ? tr('你还没有为这条补充写说明。') : tr('人物小传暂未整理；下方仍可查看截至这一页已记录的线索。')));
  if (p.manual) pane.append(h('div', { class: 'note' }, tr('你手动补充的资料 '),
    h('button', { class: 'linkish', onclick: () => ctx.panes.open('manual', { edit: p.id.slice(1) }) }, tr('编辑或删除'))));
  const meta = h('div', { class: 'muted', style: { display: 'flex', gap: '12px', flexWrap: 'wrap', alignItems: 'center' } });
  if (p.chk && (p.chk.verdict === 'ok' || p.chk.verdict === 'rewritten')) {
    meta.append(h('span', { class: 'check', title: tr('经过模型核对，仍可点出处复核原文') }, icon('check'), tr('已通过模型核对')));
  }
  meta.append(h('span', {}, p.entityKind === 'concept' ? tr('原文出现 ') : tr('首次登场 '), pageLink(ctx, p.first, p.first + 2)));
  if (p.n) meta.append(h('span', {}, tr("被提到 {0} 次", [p.n])));
  pane.append(meta);

  if (w.frontier && ctx.info.cutoff > w.frontier && w.state !== 'done') {
    pane.append(h('div', { class: 'note' }, tr("AI 还在读这本书，目前整理到第 {0} 页。这张卡片里的信息只到那里，不会超过你读到的位置。", [ctx.pageNo(w.frontier)])));
  }

  for (const m of p.merged) {
    pane.append(h('div', { class: 'note' }, tr("原文在第 {0} 页揭示：「{1}」就是{2}。", [ctx.pageNo(m.p), m.name, p.name]), m.reason ? ` ${m.reason}` : ''));
  }

  const rels = w.relsOf(cid);
  const W = words(ctx.book);
  if (rels.length) pane.append(egoGraph(ctx, p, rels));

  // what changed since the reader last opened this card
  if (prevSeen != null && prevSeen < ctx.info.cutoff) {
    const fresh = p.events.filter((e) => e.p > prevSeen);
    if (fresh.length) pane.append(h('div', { class: 'note' }, tr("自你上次在第 {0} 页查看以来，{1}又有 {2} 件新事，已在时间线标出。", [ctx.pageNo(prevSeen), p.name, fresh.length])));
  }

  // 身份变迁: who this person was at earlier pages
  if (p.trail.length >= 2) {
    const ol = h('ol', { class: 'trail' });
    // only the pages where the description actually changed — not every chapter that repeated it
    const seenTrail = new Set();
    const trail = p.trail.filter((t) => { const k = (t.t || '').trim(); if (!k || seenTrail.has(k)) return false; seenTrail.add(k); return true; });
    for (const t of trail.slice(-8)) ol.append(h('li', {}, h('span', { class: 'at', onclick: () => ctx.goSource(t.p, t.p + 1) }, tr("第 {0} 页", [ctx.pageNo(t.p)])), h('span', { class: 'tt' }, t.t)));
    pane.append(h('div', { class: 'sec' }, h('h4', {}, tr('身份变迁')), ol));
  }

  // 档案
  const order = (key) => { const index = ATTR_ORDER.indexOf(attributeLabel(key)); return index < 0 ? ATTR_ORDER.length : index; };
  const keys = Object.keys(p.attrs).sort((a, b) => order(a) - order(b));
  if (keys.length) {
    const dl = h('dl', { class: 'facts' });
    for (const k of keys) {
      const vals = p.attrs[k];
      const last = vals[vals.length - 1];
      const prev = vals.length > 1 ? vals[vals.length - 2] : null;
      dl.append(h('dt', {}, attributeLabel(k)), h('dd', {}, prev && prev.v !== last.v ? h('span', { class: 'was' }, prev.v) : null, last.v));
    }
    pane.append(h('div', { class: 'sec' }, h('h4', {}, tr('档案')), dl));
  }

  // 关系
  if (rels.length) {
    const box = h('div', { class: 'rels' });
    for (const r of rels) {
      const o = w.people.get(r.other);
      if (!o) continue;
      box.append(h('button', { class: 'rel' + (r.status === 'ended' ? ' ended' : ''), onclick: () => ctx.openPerson(o.id) },
        avatar(o, 'sm'),
        h('div', {}, h('div', { class: 'rn' }, o.name, h('i', {}, r.role || tr('相关')), r.status === 'ended' ? h('i', {}, tr('（已结束）')) : null),
          h('div', { class: 'rd' }, r.desc),
          (() => {   // the other ways the book has put this relationship
            const also = (r.also || []).filter((x) => x && x !== r.role);
            return also.length ? h('div', { class: 'rd was-rel' }, tr("书中也写作：{0}", [also.join('、')]),
              r.times > 1 ? h('i', {}, tr(" · 共 {0} 处", [r.times])) : null) : null;
          })()),
        h('span', { class: 'chev' }, icon('chev'))));
    }
    pane.append(h('div', { class: 'sec' }, h('h4', {}, `${words(ctx.book).rel} · ${rels.length}`), box));
  }

  // 经历
  if (p.events.length) {
    const evs = [...p.events].reverse();
    const list = h('ul', { class: 'tl' });
    const limit = 12;
    let lastCh = null;
    const draw = (items) => {
      for (const e of items) {
        const ch = ctx.chapterName(e.p);
        if (ch !== lastCh) { list.append(h('div', { class: 'chap' }, ch)); lastCh = ch; }
        list.append(h('li', { class: `imp${e.imp}` + (prevSeen != null && e.p > prevSeen ? ' fresh' : '') },
          h('div', { class: 'tx' }, e.text), pageLink(ctx, e.s, e.p)));
      }
    };
    draw(evs.slice(0, limit));
    const sec = h('div', { class: 'sec' }, h('h4', {}, tr("经历 · {0}", [evs.length])), list);
    if (evs.length > limit) {
      const more = h('button', { class: 'more-btn', onclick: () => { more.remove(); draw(evs.slice(limit)); } }, tr("展开更早的 {0} 件事", [evs.length - limit]));
      sec.append(more);
    }
    pane.append(sec);
  }
}

// small radial diagram of the person's current relations
function egoGraph(ctx, p, rels) {
  const W = 360, H = 200, cx = W / 2, cy = H / 2;
  // people the book actually keeps around, not one-off passers-by ("带头男人")
  const weight = (r) => {
    const o = ctx.world.people.get(r.other);
    if (!o) return -1;
    return (o.n || 0) + o.events.length * 2 + (r.times || 1) * 3 + (o.imp >= 3 ? 20 : 0);
  };
  const top = rels.filter((r) => r.status !== 'ended' && weight(r) >= 4)
    .sort((a, b) => weight(b) - weight(a)).slice(0, 8);
  const s = svg('svg', { class: 'ego', viewBox: `0 0 ${W} ${H}`, role: 'img', 'aria-label': tr("{0}的关系", [p.name]) });
  const n = top.length;
  top.forEach((r, i) => {
    const o = ctx.world.people.get(r.other);
    if (!o) return;
    const a = -Math.PI / 2 + (i / Math.max(1, n)) * Math.PI * 2 + (n === 2 ? Math.PI / 2 : 0);
    const x = cx + Math.cos(a) * 138, y = cy + Math.sin(a) * 62;
    s.append(svg('line', { x1: cx, y1: cy, x2: x, y2: y, stroke: personColor(o.id), 'stroke-opacity': '.45', 'stroke-width': 1.2 }));
    // role label on the spoke, name on the far side of the node (never between node and centre)
    const mx = cx + (x - cx) * 0.5, my = cy + (y - cy) * 0.5;
    s.append(svg('text', { x: mx, y: my + (Math.abs(y - cy) < 20 ? -5 : 4), 'text-anchor': 'middle', 'font-size': 10.5, fill: 'var(--zhu)', style: 'font-family:var(--kai);paint-order:stroke', stroke: 'var(--sheet)', 'stroke-width': 3 }, r.role || ''));
    const g = svg('g', { style: 'cursor:pointer', role: 'button', tabindex: 0, 'aria-label': tr("查看{0}的批注", [o.name]), onclick: () => ctx.openPerson(o.id), onkeydown: (e) => { if (['Enter', ' '].includes(e.key)) { e.preventDefault(); ctx.openPerson(o.id); } } });
    g.append(svg('circle', { cx: x, cy: y, r: 13, fill: personColor(o.id) }));
    g.append(svg('text', { x, y: y + 4.5, 'text-anchor': 'middle', 'font-size': 12, fill: '#fff', 'font-weight': 600 }, initial(o.name)));
    const below = y >= cy - 2;
    g.append(svg('text', { x, y: below ? y + 27 : y - 19, 'text-anchor': 'middle', 'font-size': 11.5, fill: 'var(--ink-2)' }, o.name.length > 7 ? o.name.slice(0, 7) + '…' : o.name));
    s.append(g);
  });
  s.append(svg('circle', { cx, cy, r: 19, fill: personColor(p.id) }));
  s.append(svg('text', { x: cx, y: cy + 6, 'text-anchor': 'middle', 'font-size': 16, fill: '#fff', 'font-weight': 600 }, initial(p.name)));
  return s;
}

function row(ctx, p, extra) {
  return h('button', { class: 'cast-row', onclick: () => ctx.openPerson(p.id) },
    avatar(p, 'sm'),
    h('div', {}, h('div', { class: 'n' }, p.name, extra ? h('span', { class: 'tag-new' }, extra) : null),
      h('div', { class: 'd' }, p.tagline || p.intro || '')),
    h('div', { class: 'c' }, p.n || '', h('small', {}, p.n ? tr('次') : '')));
}

// 本页 · what the margin shows by default on wide screens
export function hereView(ctx, _arg, pane, title, panes) {
  const w = ctx.world;
  const W = words(ctx.book);
  title.append(tr('此页批注'), h('small', {}, tr("第 {0} 页", [ctx.info.global])));
  const ids = ctx.pagePeople();
  if (ids.length) {
    const box = h('div', { class: 'cast' });
    for (const id of ids) {
      const p = w.people.get(id);
      if (p) box.append(row(ctx, p, p.first >= ctx.info.start && p.first < ctx.info.cutoff ? tr('新登场') : null));
    }
    pane.append(h('div', { class: 'sec', style: { marginTop: '4px' } }, h('h4', {}, W.here), box));
  } else {
    pane.append(h('p', { class: 'muted' }, W.none));
  }
  const recent = w.events.slice(-4).reverse();
  if (recent.length) {
    const list = h('ul', { class: 'tl' });
    for (const e of recent) list.append(h('li', { class: `imp${e.imp}` }, h('div', { class: 'tx' }, e.text), pageLink(ctx, e.s, e.p)));
    pane.append(h('div', { class: 'sec' }, h('h4', {}, tr('刚刚发生')), list));
  }
  if (w.saga) {
    const txt = w.saga.text;
    pane.append(h('div', { class: 'sec' }, h('h4', {}, tr('前情提要')),
      h('p', { class: 'bio', style: { fontSize: '15px' } }, txt.length > 160 ? txt.slice(0, 160) + '……' : txt),
      h('button', { class: 'more-btn', onclick: () => panes.open('recap') }, tr('读完整的前情提要'))));
  }
  pane.append(h('div', { class: 'sec' }, h('h4', {}, tr('工具')),
    h('div', { class: 'chips' },
      h('button', { onclick: () => panes.open('cast') }, W.all),
      h('button', { onclick: () => panes.open('graph') }, W.rel + tr('图')),
      h('button', { onclick: () => panes.open('ask') }, tr('问问这本书')))));
  ctx.statusLine(pane);
}

export function castView(ctx, arg, pane, title) {
  const w = ctx.world;
  const W = words(ctx.book);
  title.append(W.list, h('small', {}, tr("截至第 {0} 页 · {1} 条资料", [ctx.info.global, w.people.size])));
  const mode = { v: arg?.mode || (ctx.pagePeople().length ? 'page' : 'all'), q: '' };
  const search = h('input', { type: 'search', placeholder: tr('搜索已读人物或概念'), 'aria-label': tr('搜索已读人物或概念'), enterkeyhint: 'search' });
  const listBox = h('div', { class: 'cast' });
  const seg = h('div', { class: 'seg-ctl' });
  const modes = [['page', tr('本页')], ['chapter', tr('本章')], ['all', tr('全部')]];
  for (const [k, label] of modes) {
    seg.append(h('button', { class: mode.v === k ? 'on' : '', onclick: (e) => { mode.v = k; [...seg.children].forEach((b) => b.classList.toggle('on', b === e.currentTarget)); draw(); } }, label));
  }
  const draw = () => {
    listBox.textContent = '';
    let people = w.ranked();
    const chStart = ctx.chapterStart();
    const q = mode.q.trim();
    // A search covers all knowledge through this page, regardless of the selected tab.
    if (q) people = people.filter((p) => [p.name, ...p.aliases, p.tagline, p.bio].join(' ').toLocaleLowerCase().includes(q.toLocaleLowerCase()));
    else if (mode.v === 'page') { const ids = ctx.pagePeople(); people = ids.map((id) => w.people.get(id)).filter(Boolean); }
    else if (mode.v === 'chapter') { const ids = new Set(ctx.chapterPeople()); people = people.filter((p) => ids.has(p.id)); }
    if (!people.length) listBox.append(empty('·', q ? tr('没有找到这个人。可能还没登场，或者换个称呼试试。') : tr('这里还没有人物。')));
    if (mode.v === 'all' && !q && people.length > 12) {
      // importance grows with the story: the model's first rating plus how much the text has used them so far
      // (two-phase books give every newcomer importance 2, so only the text's own use of a person counts below 3)
      const tier = (p) => (p.imp >= 3 || p.n >= 40 || p.events.length >= 15 ? 3 : p.n >= 8 || p.events.length >= 4 ? 2 : 1);
      // walk-ons (named once, nothing else known so far) stay folded; search still finds them
      const walkOn = (p) => !p.manual && tier(p) === 1 && (p.n || 0) <= 1 && p.events.length <= 1 && !w.relsOf(p.id).length;
      const names = W.one === tr('概念') ? [tr('核心概念'), tr('重要概念'), tr('其他条目')] : [tr('主要人物'), tr('重要配角'), tr('其他人物')];
      const tiers = [[names[0], (p) => tier(p) === 3], [names[1], (p) => tier(p) === 2], [names[2], (p) => tier(p) === 1 && !walkOn(p)]];
      for (const [label, test] of tiers) {
        const group = people.filter(test);
        if (!group.length) continue;
        listBox.append(h('h4', { class: 'tier' }, label, h('small', {}, ` ${group.length}`)));
        for (const p of group.slice(0, 200)) listBox.append(row(ctx, p, p.first >= chStart ? tr('本章新') : null));
      }
      const minor = people.filter(walkOn);
      if (minor.length) {
        const box = h('div', { hidden: !mode.minor });
        for (const p of minor.slice(0, 300)) box.append(row(ctx, p, p.first >= chStart ? tr('本章新') : null));
        const btn = h('button', { class: 'more-btn', onclick: () => { mode.minor = !mode.minor; box.hidden = !mode.minor; btn.textContent = label(); } });
        const label = () => (mode.minor ? tr("收起{0}", [W.one === tr('概念') ? tr('零散条目') : tr('过场人物')])
          : tr("还有 {0} {1}", [minor.length, W.one === tr('概念') ? tr('条只出现过一次的条目') : tr('位过场人物（只出现过一次）')]));
        btn.textContent = label();
        listBox.append(btn, box);
      }
      return;
    }
    for (const p of people.slice(0, 300)) listBox.append(row(ctx, p, p.first >= chStart ? tr('本章新') : null));
  };
  search.addEventListener('input', () => { mode.q = search.value; draw(); });
  pane.append(h('div', { class: 'search' }, icon('search'), search), seg,
    h('button', { class: 'btn', onclick: () => ctx.panes.open('manual') }, tr('找不到？手动补充人物或概念')), listBox);
  draw();
  ctx.statusLine(pane);
}
