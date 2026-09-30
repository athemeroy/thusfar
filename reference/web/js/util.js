import { t as tr } from './i18n.js';
// Small DOM + formatting helpers shared by every view.

export const $ = (sel, root = document) => root.querySelector(sel);
export const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

// what to call the entities in this book: characters in a story, terms in a book of ideas
export const WORDS = {
  novel: { one: tr('人物'), list: tr('人物表'), here: tr('本页人物'), rel: tr('关系'), none: tr('这一页没有点到名字的人物。'), all: tr('全部人物') },
  concept: { one: tr('概念'), list: tr('术语表'), here: tr('本页概念'), rel: tr('关联'), none: tr('这一页没有点到已整理的概念。'), all: tr('全部概念') },
};

export function words(book) {
  return ['nonfiction', 'reference'].includes(book?.genre) ? WORDS.concept : WORDS.novel;
}

export function qualityPending(status) { return status?.quality?.state === 'pending' || (Array.isArray(status?.quality?.pending) && status.quality.pending.length > 0); }

export function h(tag, attrs = {}, ...kids) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null || (v === false && !k.startsWith('aria-'))) continue;
    if (k === 'class') el.className = v;
    else if (k === 'style' && typeof v === 'object') Object.assign(el.style, v);
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'html') el.innerHTML = v;
    else el.setAttribute(k, k.startsWith('aria-') ? String(v) : v === true ? '' : v);
  }
  for (const kid of kids.flat(Infinity)) {
    if (kid == null || kid === false) continue;
    el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return el;
}

export function svg(tag, attrs = {}, ...kids) {
  const el = document.createElementNS('http://www.w3.org/2000/svg', tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v == null) continue;
    if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v);
  }
  for (const kid of kids.flat(Infinity)) if (kid != null) el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  return el;
}

// line icons (24x24, stroke)
const ICONS = {
  bookmark: 'M6 3h12v18l-6-4-6 4z',
  pen: 'M4 20l1-5L16 4l4 4L9 19zM14 6l4 4',
  back: 'M15 5l-7 7 7 7',
  close: 'M6 6l12 12M18 6L6 18',
  toc: 'M4 6h16M4 12h10M4 18h13',
  people: 'M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM2.5 20c.6-3.6 3.3-5.5 6.5-5.5s5.9 1.9 6.5 5.5M16 4.5a3.2 3.2 0 0 1 0 6.3M18 14.8c2 .6 3.2 2.3 3.5 5.2',
  graph: 'M6 7a2.5 2.5 0 1 0 0-.1zM18 5a2.5 2.5 0 1 0 0-.1zM17 18a2.5 2.5 0 1 0 0-.1zM8.3 6.4l7.4-1.2M7.8 8.8l7.6 7.8M18 7.5l-.6 8',
  recap: 'M5 4h11l3 3v13H5zM8 10h8M8 14h8M8 18h5',
  ask: 'M4 5h16v11H9l-5 4zM9 10h6',
  font: 'M4 19l6-15 6 15M6.5 13h7M16 19l3-8 3 8M17 16.5h4',
  search: 'M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14zM20 20l-4-4',
  send: 'M5 12l14-7-5 14-2.5-5.5z',
  chev: 'M9 6l6 6-6 6',
  check: 'M5 12.5l4.2 4L19 7',
  play: 'M8 5v14l11-7z',
  pause: 'M7 5h4v14H7zM13 5h4v14h-4z',
  plus: 'M12 5v14M5 12h14',
  undo: 'M9 14L4 9l5-5M4 9h10a6 6 0 0 1 0 12h-3',
  more: 'M5 12h.01M12 12h.01M19 12h.01',
  settings: 'M12 15.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7zM19.4 15.1l1.1 1.9-2 2-1.9-1.1a8 8 0 0 1-1.5.6L14.6 21h-2.9l-.5-2.5a8 8 0 0 1-1.5-.6L7.8 19l-2-2 1.1-1.9a8 8 0 0 1-.6-1.5L3.8 13v-2l2.5-.6a8 8 0 0 1 .6-1.5L5.8 7l2-2 1.9 1.1a8 8 0 0 1 1.5-.6L11.7 3h2.9l.5 2.5a8 8 0 0 1 1.5.6L18.5 5l2 2-1.1 1.9a8 8 0 0 1 .6 1.5l2.5.6v2l-2.5.6a8 8 0 0 1-.6 1.5z',
};

export function icon(name, cls = '') {
  const s = svg('svg', { viewBox: '0 0 24 24', class: cls, 'aria-hidden': 'true' });
  if (name === 'play' || name === 'pause') s.append(svg('path', { d: ICONS[name], fill: 'currentColor', stroke: 'none' }));
  else s.append(svg('path', { d: ICONS[name] }));
  return s;
}

// 朱砂、靛青、石绿、赭石、藤黄、胭脂、黛蓝、松绿、檀褐、紫棠、苍青、柿红
const INKS = ['#b8401c', '#35507a', '#4f7a5a', '#8a5a2b', '#b08a2e', '#9c3450', '#3d5d6b', '#2f6f63', '#6d4a3a', '#6a4a7a', '#557080', '#c0602a'];
export function personColor(id) {
  const n = parseInt(String(id).replace(/\D/g, ''), 10) || 0;
  return INKS[(n * 7) % INKS.length];
}

export function initial(name) {
  let s = String(name || '?').replace(/^[“"「（(]/, '').trim();
  if (/^[A-Za-z]/.test(s)) {
    // Western names: the surname's initial (Mr. Richard Enfield → E, Dr. Jekyll → J)
    const words = s.replace(/^(?:(?:mr|mrs|miss|ms|dr|sir|lady|lord|the|a|an|old|young|little|uncle|aunt|captain|master)\.?\s+)+/i, '').split(/\s+/);
    s = words[words.length - 1] || s;
    return (s.match(/[A-Za-z]/) || ['?'])[0].toUpperCase();
  }
  return s[0] || '?';
}

export function avatar(p, cls = '') {
  return h('span', { class: 'avatar ' + cls, style: { background: personColor(p.id) } }, initial(p.name));
}

export function toast(msg, ms = 2200) {
  const t = document.getElementById('toast');
  t.textContent = msg;
  t.hidden = false;
  clearTimeout(toast._t);
  toast._t = setTimeout(() => (t.hidden = true), ms);
}

export const store = {
  get(k, d) { try { const v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch { return d; } },
  set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); return true; } catch { return false; } },
};

export function debounce(fn, ms) {
  let t;
  const run = (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); };
  run.cancel = () => clearTimeout(t);
  return run;
}

export function clamp(x, a, b) { return Math.max(a, Math.min(b, x)); }

export function paragraphs(text) {
  return String(text || '').split(/\n+/).filter(Boolean).map((t) => h('p', {}, t));
}

// Chapter titles often give the plot away (红楼梦: “苦绛珠魂归离恨天”). Unread ones show only their number.
export function maskTitle(title) {
  const m = /^(第[零〇一二三四五六七八九十百千万两0-9０-９]+[章回节卷集部篇幕])/.exec(title || '');
  return m ? `${m[1]}　······` : '······';
}
