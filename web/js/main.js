// Login gate and route-owned views for the personal library workspace and reader.

import { api, AuthError } from './api.js';
import { openShelf } from './shelf.js';
import { openReader } from './readerview.js';
import { h, store, toast } from './util.js';
import { retryOutbox } from './progress.js';
import { retryNotebooks } from './notebook.js';
import { openReadingList, retryReadingList } from './reading-list.js';
import { openNotebookHub } from './notebook-hub.js';
import { openOfflineLibrary } from './offline-library.js';
import { workspaceNavigation } from './workspace-nav.js';
import { standalone } from './runtime.js';
import { openModelSettings, languageControl } from './model-settings.js';
import { setDocumentLanguage, t } from './i18n.js';

const root = document.getElementById('app');
setDocumentLanguage();
const s = store.get('settings', {});
document.documentElement.dataset.theme = s.theme || 'paper';

let active = null;
function login(signal) {
  root.textContent = '';
  const input = h('input', { type: 'password', placeholder: t('口令'), 'aria-label': t('书房口令'), autocomplete: 'current-password', required: true });
  const form = h('form', {},
    h('div', { class: 'brand' }, t('页读'), h('small', {}, t('请输入口令'))),
    input, h('button', { class: 'btn primary', style: { justifyContent: 'center' } }, t('进入书房')),
    h('label', { class: 'login-language' }, t('界面语言'), languageControl()));
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    try { await api.login(input.value, { signal }); if (!signal.aborted) route(); } catch (err) { if (!signal.aborted) toast(err.message); }
  });
  root.append(h('div', { class: 'login paper-grain' }, form));
  input.focus();
}

async function route() {
  active?.abort();
  const controller = new AbortController(); active = controller;
  const signal = controller.signal;
  delete window.YeduReader;
  const mount = h('div', { class: 'route-root' }); root.replaceChildren(mount);
  try {
    const m = /^#\/read\/([A-Za-z0-9_-]+)/.exec(location.hash);
    const query = new URLSearchParams(location.hash.split('?')[1] || '');
    if (m) await openReader(mount, m[1], { signal, at: query.has('at') ? Number(query.get('at')) : undefined, panel: query.get('panel') });
    else {
      const path = location.hash.split('?')[0] || '#/';
      const view = { '#/next': openReadingList, '#/notes': openNotebookHub,
        '#/settings': openModelSettings,
        '#/offline': standalone ? openShelf : openOfflineLibrary }[path] || openShelf;
      delete document.documentElement.dataset.bookLang;
      window.YeduReader = { onNativeBack: () => {
        const dialog = document.querySelector('dialog[open]');
        if (dialog) { dialog.close(); return true; }
        return false;
      } };
      const content = h('div', { class: 'workspace-content' });
      mount.append(workspaceNavigation(path), content);
      await view(content, { signal });
      if (!signal.aborted) { retryOutbox().catch(() => {}); retryNotebooks().catch(() => {}); retryReadingList().catch(() => {}); }
    }
  } catch (e) {
    if (signal.aborted) return;
    if (e instanceof AuthError) {
      controller.abort();
      const gate = new AbortController(); active = gate;
      delete window.YeduReader;
      return login(gate.signal);
    }
    console.error(e);
    root.textContent = '';
    root.append(h('div', { class: 'loading' }, h('div', {}, t('出了点问题：'), e.message, h('br'), h('a', { href: '#/', class: 'linkish' }, t('回书架')))));
  }
}

addEventListener('hashchange', route);
addEventListener('online', () => { retryOutbox().catch(() => {}); retryNotebooks().catch(() => {}); retryReadingList().catch(() => {}); });
route();
if (!standalone && 'serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
