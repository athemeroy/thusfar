// A single reading-support hub keeps generated material secondary to the text and personal work.
import { h, icon, words } from './util.js';
import { t as tr } from './i18n.js';
export function companionView(ctx, _arg, pane, title) {
  const labels = words(ctx.book), people = [...ctx.world.people.values()];
  title.append(tr('阅读资料'), h('small', {}, tr("只到你眼前的第 {0} 页", [ctx.info.global])));
  pane.append(h('p', { class: 'companion-intro' }, tr('忘了这个人是谁，或想接上前情，可以从这里找回线索。每条资料都能回到原文核对。')));
  const choices = [
    ['people', labels.list, tr("{0} 位已出现的{1}，查看身份、出处与经历", [people.length, labels.one]), 'cast'],
    ['graph', labels.rel, tr('把目前已知的联系放在一起看'), 'graph'],
    ['recap', tr('接上前情'), ctx.world.saga ? tr('回顾已整理的故事，接着往下读') : tr('查看已整理章节与本章线索'), 'recap'],
    ['ask', tr('带着问题读'), tr('依据当前页之前的内容回答，附原文出处'), 'ask'],
  ];
  const cards = h('div', { class: 'companion-cards' });
  for (const [ic, label, detail, view] of choices) cards.append(h('button', { class: 'companion-card', onclick: () => ctx.panes.open(view) }, icon(ic), h('span', {}, h('b', {}, label), h('small', {}, detail)), icon('chev')));
  pane.append(cards, h('div', { class: 'companion-own' }, h('h4', {}, tr('你留下的线索')),
    h('button', { class: 'btn', onclick: () => ctx.panes.open('manual') }, tr('补充遗漏的人物或概念')),
    h('button', { class: 'btn', onclick: () => ctx.panes.open('notebook') }, tr('打开我的摘记')),
    h('button', { class: 'btn', onclick: () => ctx.panes.open('search', undefined, { full: true }) }, tr('搜索原文'))),
    h('button', { class: 'linkish book-management', onclick: () => ctx.panes.open('bookSettings') }, tr('管理本书 · 离线与整理')));
  ctx.statusLine(pane);
}
