import { h, icon } from './util.js';
import { standalone } from './runtime.js';
import { t } from './i18n.js';

export function workspaceNavigation(path) {
  const entries = [['#/', t('书架'), 'toc'], ['#/next', t('接下来读'), 'bookmark'],
    ['#/notes', t('全部摘记'), 'pen'], ...(standalone ? [] : [['#/offline', t('离线书籍'), 'recap']])];
  const active = entries.some(([href]) => href === path) ? path : '#/';
  return h('nav', { class: 'workspace-nav', 'aria-label': t('书房导航') },
    h('a', { class: 'workspace-wordmark', href: '#/', 'aria-label': t('页读书房') }, h('span', { class: 'brand-mark', 'aria-hidden': 'true' }, '页'), t('页读')),
    h('div', { class: 'workspace-tabs' }, entries.map(([href, label, symbol]) =>
      h('a', { href, 'aria-current': active === href && path !== '#/settings' ? 'page' : null }, icon(symbol), h('span', {}, label)))),
    h('a', { class: 'workspace-settings-link', href: '#/settings', 'aria-label': standalone ? t('模型设置') : t('设置'), 'aria-current': path === '#/settings' ? 'page' : null }, icon('settings')));
}
