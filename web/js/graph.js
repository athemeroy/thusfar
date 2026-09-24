// 关系图: the relationship network as known at the current page, with a replay of how it grew.

import { h, svg, icon, personColor } from './util.js';
import { t as tr } from './i18n.js';

const KIN = /[父母子女夫妻兄弟姐妹叔伯舅姑姨祖孙婆公岳婿媳侄甥]/;
const positions = new Map();   // keeps nodes steady between redraws

function hash(s) { let x = 0; for (const c of s) x = (x * 31 + c.charCodeAt(0)) | 0; return x; }

function layout(nodes, edges, warm, aspect = 1) {
  const gx = 0.02 * Math.max(1, 1 / aspect) * 0.7, gy = 0.02 * Math.min(1, aspect) * 0.9;
  const idx = new Map(nodes.map((n, i) => [n.id, i]));
  const P = nodes.map((n) => {
    const old = positions.get(n.id);
    if (old) return { x: old.x, y: old.y, vx: 0, vy: 0 };
    // new nodes appear next to a neighbour if they have one
    const e = edges.find((e) => (e.a === n.id && positions.has(e.b)) || (e.b === n.id && positions.has(e.a)));
    const anchor = e ? positions.get(e.a === n.id ? e.b : e.a) : { x: 0, y: 0 };
    const a = (hash(n.id) % 360) * Math.PI / 180;
    return { x: anchor.x + Math.cos(a) * 60, y: anchor.y + Math.sin(a) * 60, vx: 0, vy: 0 };
  });
  const E = edges.map((e) => [idx.get(e.a), idx.get(e.b)]).filter(([a, b]) => a != null && b != null);
  const iters = warm ? 90 : 320;
  for (let it = 0; it < iters; it++) {
    const t = 1 - it / iters;
    for (let i = 0; i < P.length; i++) {
      for (let j = i + 1; j < P.length; j++) {
        let dx = P[i].x - P[j].x, dy = P[i].y - P[j].y;
        let d2 = dx * dx + dy * dy + 0.01;
        if (d2 > 250000) continue;
        const f = 3400 / d2;
        const d = Math.sqrt(d2);
        dx /= d; dy /= d;
        P[i].vx += dx * f; P[i].vy += dy * f; P[j].vx -= dx * f; P[j].vy -= dy * f;
      }
    }
    for (const [a, b] of E) {
      const dx = P[b].x - P[a].x, dy = P[b].y - P[a].y;
      const d = Math.sqrt(dx * dx + dy * dy) || 1;
      const f = (d - 105) * 0.035;
      P[a].vx += dx / d * f; P[a].vy += dy / d * f; P[b].vx -= dx / d * f; P[b].vy -= dy / d * f;
    }
    for (const p of P) {
      p.vx -= p.x * gx; p.vy -= p.y * gy;
      const cap = 18 * t + 2;
      p.x += Math.max(-cap, Math.min(cap, p.vx * 0.5));
      p.y += Math.max(-cap, Math.min(cap, p.vy * 0.5));
      p.vx *= 0.5; p.vy *= 0.5;
    }
  }
  nodes.forEach((n, i) => positions.set(n.id, { x: P[i].x, y: P[i].y }));
}

export function graphView(ctx, arg, pane, title, panes) {
  title.append(tr('关系图'), h('small', {}, tr("截至第 {0} 页", [ctx.info.global])));
  const wrap = h('div', { class: 'graph-wrap' });
  const s = svg('svg', { role: 'img', 'aria-label': tr('人物关系图') });
  wrap.append(s);
  const start = ctx.bodyStart();
  const end = ctx.info.cutoff;
  const range = h('input', { type: 'range', min: start, max: end, value: end, step: Math.max(1, Math.round((end - start) / 400)), 'aria-label': tr('时间') });
  const label = h('span', { class: 'n' }, tr("第 {0} 页", [ctx.info.global]));
  const play = h('button', { class: 'play', 'aria-label': tr('回放关系的形成') }, icon('play'));
  const hint = h('p', { class: 'muted', style: { margin: '8px 0 0' } }, tr('点一个人物，看他和谁有关、是什么关系；再点一次打开人物卡。朱色线是亲属。按 ▶ 回放关系网是怎样一步步长成这样的（最多到你读到的这一页）。'));
  pane.append(wrap, h('div', { class: 'time-ctl' }, play, range, label), hint);

  let selected = arg?.id ? ctx.world.canon(arg.id) : null;
  let timer = null;
  const limit = ctx.panes.desktop ? 40 : 28;

  const draw = (cut, warm) => {
    const w = ctx.kg.world(cut);
    let people = w.ranked().slice(0, limit);
    if (selected && w.people.has(selected) && !people.some((p) => p.id === selected)) people.push(w.people.get(selected));
    const ids = new Set(people.map((p) => p.id));
    const edges = w.rels.filter((r) => ids.has(r.a) && ids.has(r.b) && r.status !== 'ended');
    // keep isolated minor people out when the graph is busy
    const linked = new Set(edges.flatMap((e) => [e.a, e.b]));
    if (people.length > 12) people = people.filter((p, i) => linked.has(p.id) || i < 8 || p.id === selected);
    const box = wrap.getBoundingClientRect();
    layout(people, edges, warm, box.width && box.height ? box.width / box.height : 1);
    s.textContent = '';
    if (!people.length) {
      s.append(svg('text', { x: '50%', y: '50%', 'text-anchor': 'middle', fill: 'var(--ink-3)', style: 'font-family:var(--kai)' }, tr('人物还没有登场')));
      return;
    }
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const p of people) { const q = positions.get(p.id); minX = Math.min(minX, q.x); maxX = Math.max(maxX, q.x); minY = Math.min(minY, q.y); maxY = Math.max(maxY, q.y); }
    const pad = 50;
    s.setAttribute('viewBox', `${minX - pad} ${minY - pad} ${Math.max(200, maxX - minX + pad * 2)} ${Math.max(200, maxY - minY + pad * 2)}`);
    const neigh = new Set();
    if (selected) for (const e of edges) { if (e.a === selected) neigh.add(e.b); if (e.b === selected) neigh.add(e.a); }
    const gE = svg('g'), gL = svg('g'), gN = svg('g');
    for (const e of edges) {
      const a = positions.get(e.a), b = positions.get(e.b);
      const on = !selected || e.a === selected || e.b === selected;
      const kin = KIN.test((e.a_is || '') + (e.b_is || ''));
      gE.append(svg('line', { class: 'edge' + (kin ? ' kin' : ''), x1: a.x, y1: a.y, x2: b.x, y2: b.y, 'stroke-width': on && selected ? 1.8 : 1, opacity: on ? 1 : 0.15 }));
      if (selected && on) {
        const lab = selected ? (e.a === selected ? e.b_is : e.a_is) : (e.b_is || e.a_is);
        const other = selected ? positions.get(e.a === selected ? e.b : e.a) : null;
        const lx = selected ? (a.x + b.x) / 2 * 0.4 + other.x * 0.6 : (a.x + b.x) / 2;
        const ly = selected ? (a.y + b.y) / 2 * 0.4 + other.y * 0.6 : (a.y + b.y) / 2;
        gL.append(svg('text', { class: 'elabel', x: lx, y: ly - 14, 'text-anchor': 'middle' }, lab || ''));
      }
    }
    for (const p of people) {
      const q = positions.get(p.id);
      const r = Math.min(22, 6 + Math.sqrt(p.n + p.events.length * 2) * 1.2);
      const dim = selected && p.id !== selected && !neigh.has(p.id);
      const g = svg('g', { class: 'node' + (dim ? ' dim' : ''), transform: `translate(${q.x},${q.y})`, style: 'cursor:pointer', role: 'button', tabindex: 0, 'aria-label': tr("查看{0}的批注", [p.name]),
        onkeydown: (ev) => { if (['Enter', ' '].includes(ev.key)) { ev.preventDefault(); ctx.openPerson(p.id); } },
        onclick: (ev) => { ev.stopPropagation(); if (selected === p.id) ctx.openPerson(p.id); else { selected = p.id; draw(+range.value, true); } } });
      g.append(svg('circle', { r, fill: personColor(p.id) }));
      if (p.id === selected) g.append(svg('circle', { r: r + 5, fill: 'none', stroke: 'var(--zhu)', 'stroke-width': 1.5 }));
      g.append(svg('text', { y: r + 15, 'text-anchor': 'middle' }, p.name.length > 6 ? p.name.slice(0, 6) + '…' : p.name));
      gN.append(g);
    }
    s.append(gE, gL, gN);
  };
  s.addEventListener('click', () => { if (selected) { selected = null; draw(+range.value, true); } });
  const setLabel = (cut) => { label.textContent = tr("第 {0} 页", [ctx.pageNo(cut)]); };
  range.addEventListener('input', () => { stop(); draw(+range.value, true); setLabel(+range.value); });
  const stop = () => { clearInterval(timer); timer = null; play.replaceChildren(icon('play')); };
  play.addEventListener('click', () => {
    if (timer) return stop();
    let cut = +range.value >= end ? start : +range.value;
    play.replaceChildren(icon('pause'));
    const step = Math.max(1, (end - start) / 90);
    timer = setInterval(() => {
      cut = Math.min(end, cut + step);
      range.value = cut;
      setLabel(cut);
      draw(cut, true);
      if (cut >= end) stop();
    }, 120);
  });
  ctx.onLeave(() => stop());
  draw(end, positions.size > 0);
  const description = h('details', { class: 'graph-list' }, h('summary', {}, tr('查看关系列表')));
  for (const r of ctx.world.rels) {
    const a = ctx.world.people.get(r.a), b = ctx.world.people.get(r.b);
    if (a && b) description.append(h('p', {}, h('button', { onclick: () => ctx.openPerson(a.id) }, a.name), ' → ', h('button', { onclick: () => ctx.openPerson(b.id) }, b.name), `：${r.b_is || tr('相关')}${r.status === 'ended' ? tr('（已结束）') : ''}`));
  }
  pane.append(description);
}
