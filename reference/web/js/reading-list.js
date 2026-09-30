import { canReachLibrary } from './runtime.js';
// Explicit reading intentions, independent of percentage read or generated material.
// Durable desired order survives uncertain requests; cross-device conflicts require a choice.
import { api, AuthError, ConflictError } from './api.js';
import { h, icon, toast, store } from './util.js';
import { t as tr } from './i18n.js';

export const READING_LIST_KEY = 'reading-list-v1';
const BOOKS_KEY = 'reading-list-books-v1';
const EVENT = 'yedu-reading-list';
const LIMIT = 200;
const validId = (id) => typeof id === 'string' && /^[A-Za-z0-9_-]{1,160}$/.test(id);
const sameItems = (a, b) => a.length === b.length && a.every((id, i) => id === b[i]);
let localQueue = Promise.resolve(), flight = null, lastError = '';

export function emptyReadingList() { return { revision: 0, items: [], operation: '', updated: 0, known: false, dirty: false }; }
export function validateReadingList(value) {
  if (!value || !Number.isSafeInteger(value.revision) || value.revision < 0 || !Array.isArray(value.items) || value.items.length > LIMIT ||
      value.items.some((id) => !validId(id)) || new Set(value.items).size !== value.items.length ||
      (value.operation && (typeof value.operation !== 'string' || !/^[A-Za-z0-9_-]{8,80}$/.test(value.operation)))) throw new Error(tr('阅读清单数据无效，现有顺序未被覆盖'));
  return { revision: value.revision, items: [...value.items], operation: value.operation || '', updated: Number(value.updated) || 0 };
}
function validateReceipt(value) {
  const clean = validateReadingList({ ...value, revision: value?.expected_revision });
  if (!clean.operation) throw new Error(tr('本机同步回执无效，现有清单未被覆盖'));
  return { expected_revision: clean.revision, operation: clean.operation, items: clean.items };
}
function snapshotState(value) { return { ...validateReadingList(value), known: true, dirty: false }; }
export function readReadingList() {
  let value;
  try { const raw = localStorage.getItem(READING_LIST_KEY); if (raw == null) return emptyReadingList(); value = JSON.parse(raw); }
  catch { throw new Error(tr('本机阅读清单无法读取，未覆盖已有记录')); }
  const clean = validateReadingList(value);
  return { ...clean, known: value.known === true, dirty: value.dirty === true, ...(value.inflight ? { inflight: validateReceipt(value.inflight) } : {}), ...(value.conflict ? { conflict: validateReadingList(value.conflict) } : {}) };
}
// A refresh can acknowledge an uncertain successful write, but never silently merge orders.
export function receiveReadingList(current, remote) {
  remote = validateReadingList(remote);
  if (remote.revision < current.revision || (current.conflict && remote.revision < current.conflict.revision)) return current;
  if (!current.dirty) return snapshotState(remote);
  if (remote.operation === current.operation && sameItems(remote.items, current.items)) return snapshotState(remote);
  if (current.inflight && remote.operation === current.inflight.operation && sameItems(remote.items, current.inflight.items)) return acknowledgeReadingList(current, current.inflight, remote);
  if (remote.revision === current.revision) return { ...current, known: true };
  return { ...current, known: true, conflict: remote };
}
// The user may have changed the desired order while the previous operation was in flight.
export function acknowledgeReadingList(current, sent, remote) {
  remote = validateReadingList(remote);
  if (remote.operation !== sent.operation || !sameItems(remote.items, sent.items)) throw new Error(tr('同步回执与提交的顺序不一致，已保留本机清单'));
  const remaining = { ...current };
  if (remaining.inflight?.operation === sent.operation) delete remaining.inflight;
  if (remote.revision < current.revision || (current.conflict && current.conflict.revision > remote.revision)) return remaining;
  if (current.operation === sent.operation) return snapshotState(remote);
  if (current.dirty && current.revision === sent.expected_revision && !current.conflict) return { ...remaining, revision: remote.revision, known: true };
  return remaining;
}
export function moveReadingListItem(items, id, direction) {
  const result = [...items], at = result.indexOf(id), next = at + direction;
  if (![-1, 1].includes(direction) || at < 0 || next < 0 || next >= result.length) return result;
  [result[at], result[next]] = [result[next], result[at]];
  return result;
}
function broadcast() { dispatchEvent(new CustomEvent(EVENT)); }
function persist(value) {
  if (!store.set(READING_LIST_KEY, value)) throw new Error(tr('本机空间不足，这次清单修改尚未保存，请腾出空间后重试'));
  broadcast();
  return value;
}
function withLocalLock(fn) {
  if (navigator.locks?.request) return navigator.locks.request('yedu-reading-list:storage', fn);
  const next = localQueue.catch(() => {}).then(fn); localQueue = next; return next;
}
async function mutate(fn) {
  return withLocalLock(() => { const old = readReadingList(), next = fn(old); return next === old ? old : persist(next); });
}
function freshOperation() { return crypto.randomUUID(); }
async function editReadingList(change) {
  const state = await mutate((old) => {
    if (old.conflict) throw new Error(tr('另一设备也修改了顺序，请先在「接下来读」选择保留哪一份'));
    const items = change([...old.items]);
    validateReadingList({ ...old, items });
    if (sameItems(items, old.items)) return old;
    return { ...old, items, operation: freshOperation(), updated: Date.now() / 1000, dirty: true };
  });
  if (state.dirty) retryReadingList().catch(() => {});
  return state;
}
export async function addToReadingList(bookId) {
  if (!validId(bookId)) throw new Error(tr('这本书的编号无效'));
  // An initial online visit should append to the existing list, not replace it with one book.
  if (!readReadingList().known && canReachLibrary()) await retryReadingList({ force: true }).catch(() => {});
  return editReadingList((items) => {
    if (items.includes(bookId)) return items;
    if (items.length >= LIMIT) throw new Error(tr('接下来读最多放 200 本，请先移除几本'));
    return [...items, bookId];
  });
}
export async function resolveReadingList(useLocal) {
  const state = await mutate((old) => {
    if (!old.conflict) return old;
    const remote = old.conflict;
    return useLocal ? { ...snapshotState(remote), items: [...old.items], operation: freshOperation(), updated: Date.now() / 1000, dirty: true }
      : snapshotState(remote);
  });
  if (state.dirty) retryReadingList().catch(() => {});
  return state;
}
async function synchronize() {
  const run = async () => {
    if (!canReachLibrary()) return;
    let state = readReadingList();
    if (!state.known) {
      const remote = await api.readingList({ timeout: 12000 });
      state = await mutate((current) => receiveReadingList(current, remote));
    }
    for (let i = 0; canReachLibrary() && i < 20; i++) {
      state = readReadingList();
      if (!state.dirty || state.conflict) break;
      let sent;
      await mutate((current) => {
        if (!current.dirty || current.conflict) return current;
        // Retain the original operation durably until its uncertain result is reconciled.
        sent = current.inflight || { expected_revision: current.revision, operation: current.operation, items: [...current.items] };
        return current.inflight ? current : { ...current, inflight: sent };
      });
      if (!sent) break;
      try {
        const remote = await api.saveReadingList(sent, { timeout: 12000 });
        await mutate((current) => acknowledgeReadingList(current, sent, remote));
      } catch (error) {
        if (!(error instanceof ConflictError) || !error.data?.list) {
          // A validated rejection is conclusive. Keeping its receipt would prevent
          // the user from removing an unavailable book and saving the corrected order.
          if (error instanceof AuthError || (error.status >= 400 && error.status < 500 && ![408, 409, 429].includes(error.status))) {
            await mutate((current) => { if (current.inflight?.operation !== sent.operation) return current; const next = { ...current }; delete next.inflight; return next; });
          }
          throw error;
        }
        const remote = validateReadingList(error.data.list);
        await mutate((current) => receiveReadingList(current, remote));
        break;
      }
    }
    state = readReadingList();
    if (state.conflict) return;
    if (state.dirty) return; // A continuous stream of edits gets another bounded pass below.
    const remote = await api.readingList({ timeout: 12000 });
    await mutate((current) => receiveReadingList(current, remote));
  };
  if (navigator.locks?.request) return navigator.locks.request('yedu-reading-list:sync', run);
  return run();
}
export async function retryReadingList({ force = false } = {}) {
  if (!canReachLibrary() || (!force && localStorage.getItem(READING_LIST_KEY) == null)) return;
  if (flight) return flight;
  let succeeded = false;
  const job = (async () => {
    try { await synchronize(); lastError = ''; succeeded = true; }
    catch (error) { lastError = error.message || tr('同步暂未完成'); throw error; }
    finally { broadcast(); }
  })();
  flight = job;
  try { return await job; }
  finally {
    flight = null;
    if (succeeded) {
      const state = readReadingList();
      if (canReachLibrary() && state.dirty && !state.conflict) setTimeout(() => retryReadingList().catch(() => {}), 0);
    }
  }
}

export async function openReadingList(root, { signal } = {}) {
  if (signal?.aborted) return;
  delete document.documentElement.dataset.bookLang;
  const savedBooks = store.get(BOOKS_KEY, []);
  let books = Array.isArray(savedBooks) ? savedBooks.filter((b) => b && validId(b.id)) : [], booksError = '', catalogLoaded = false, disposed = false;
  let shown = 12, signature = '', pickerSignature = '', removed = null, announce = '';
  const stateLine = h('p', { class: 'reading-list-sync', role: 'status', 'aria-live': 'polite' });
  const count = h('p', { class: 'reading-list-count' });
  const syncButton = h('button', { class: 'btn', type: 'button', onclick: async () => {
    syncButton.disabled = true; stateLine.textContent = tr('正在同步顺序…');
    try { await retryReadingList({ force: true }); }
    catch (error) { if (!disposed) toast(error.message, 5000); }
    finally { if (!disposed) { syncButton.disabled = false; render(); } }
  } }, tr('立即同步'));
  const conflict = h('section', { class: 'reading-list-conflict', hidden: true, 'aria-label': tr('处理清单同步冲突') });
  const list = h('ol', { class: 'reading-list-order', 'aria-label': tr('接下来的阅读顺序') });
  const live = h('p', { class: 'reading-list-announcement', role: 'status', 'aria-live': 'polite' });
  const undo = h('button', { class: 'linkish reading-list-undo', type: 'button', hidden: true, onclick: async () => {
    const previous = removed; if (!previous) return;
    try {
      await editReadingList((items) => { if (items.includes(previous.id)) return items; if (items.length >= LIMIT) throw new Error(tr('清单已满，请先移除一本')); items.splice(Math.min(previous.at, items.length), 0, previous.id); return items; });
      removed = null; announce = tr('已恢复到清单'); render();
    } catch (error) { toast(error.message, 5000); }
  } }, tr('撤销刚才的移除'));
  const search = h('input', { type: 'search', placeholder: tr('书名或作者'), 'aria-label': tr('搜索可以加入清单的书'), autocomplete: 'off', oninput: () => { shown = 12; renderPicker(); } });
  const pickerList = h('ul', { class: 'reading-list-picker', 'aria-label': tr('从书架加入书籍') });
  const pickerState = h('p', { class: 'reading-list-picker-state', role: 'status' });
  const more = h('button', { class: 'btn reading-list-more', type: 'button', hidden: true, onclick: () => { shown += 24; renderPicker(); } }, tr('显示更多书籍'));
  const picker = h('details', { class: 'reading-list-add' }, h('summary', {}, icon('plus'), tr('从书架加入')),
    h('div', { class: 'reading-list-picker-body' }, h('label', { class: 'reading-list-search' }, icon('search'), search), pickerState, pickerList, more));
  const page = h('main', { class: 'reading-list-page paper-grain' },
    h('a', { class: 'reading-list-back', href: '#/' }, icon('back'), tr('回到书架')),
    h('header', { class: 'reading-list-header' }, h('div', {}, h('p', { class: 'reading-list-eyebrow' }, tr('给下一本书留个位置')), h('h1', {}, tr('接下来读')),
      h('p', {}, tr('把想读的书排在这里。顺序由你决定，开始阅读后也会保留，读完可以自己移出。'))), syncButton),
    stateLine, conflict, count, list, h('div', { class: 'reading-list-feedback' }, live, undo), picker);
  root.replaceChildren(page);
  const bookMap = () => new Map(books.map((book) => [book.id, book]));
  const name = (id) => bookMap().get(id)?.title || tr("暂不可用的书（{0}）", [id]);
  const operationError = (error) => { announce = error.message; render(); toast(error.message, 5000); };
  async function move(id, direction) {
    try { const result = await editReadingList((items) => moveReadingListItem(items, id, direction)); announce = tr("《{0}》已移到第 {1} 位", [name(id), result.items.indexOf(id) + 1]); render(); }
    catch (error) { operationError(error); }
  }
  async function remove(id) {
    try {
      const at = readReadingList().items.indexOf(id); if (at < 0) return;
      await editReadingList((items) => items.filter((item) => item !== id));
      removed = { id, at }; announce = tr("《{0}》已移出，书籍仍在书架", [name(id)]); render();
    } catch (error) { operationError(error); }
  }
  function restoreFocus(focus) {
    if (!focus || disposed) return;
    const target = page.querySelector(`[data-list-book="${focus.id}"][data-list-action="${focus.action}"]:not(:disabled)`)
      || page.querySelector(`[data-list-book="${focus.id}"] a`) || list.querySelector('a,button:not(:disabled)');
    target?.focus({ preventScroll: true });
  }
  function render() {
    if (disposed || signal?.aborted) return;
    let state;
    try { state = readReadingList(); }
    catch (error) { stateLine.textContent = error.message; syncButton.disabled = true; return; }
    count.textContent = state.items.length ? tr("{0} 本待你翻开 · 排在前面的先读", [state.items.length]) : tr('还没有安排下一本');
    stateLine.textContent = state.conflict ? tr('另一设备也调整了清单。两份顺序都已保留，请选择如何继续。')
      : state.dirty ? tr("顺序已保存在本机，{0}。", [canReachLibrary() ? tr('等待同步到其他设备') : tr('联网后会继续同步')])
        : !canReachLibrary() ? tr('离线查看本机清单；已下载的书仍可阅读。')
          : !state.known ? tr('正在读取其他设备上的清单…') : tr('书单已保存到书房，可在其他设备读取。');
    if (lastError && canReachLibrary()) stateLine.append(tr(" 同步暂未完成：{0}", [lastError]));
    if (booksError) stateLine.append(` ${booksError}`);
    conflict.hidden = !state.conflict;
    const conflictKey = state.conflict ? `${state.conflict.revision}:${state.operation}:${state.items.join(',')}:${JSON.stringify(books.map((b) => [b.id, b.title]))}` : '';
    if (conflict.dataset.version !== conflictKey) {
      conflict.dataset.version = conflictKey;
      conflict.replaceChildren();
      if (state.conflict) {
        const preview = (label, items) => h('div', {}, h('h3', {}, tr("{0} · {1} 本", [label, items.length])), h('ol', {}, items.map((id) => h('li', {}, name(id)))));
        conflict.append(h('h2', {}, tr('这次保留哪份顺序？')), h('p', {}, tr('选择本机顺序，会在确认当前服务器版本后替换另一份；选择另一设备顺序，会放弃本机尚未同步的排序。书籍正文不会改变。')),
          h('div', { class: 'reading-list-conflict-columns' }, preview(tr('这台设备'), state.items), preview(tr('另一设备'), state.conflict.items)),
          h('div', { class: 'reading-list-conflict-actions' },
            h('button', { class: 'btn zhu', type: 'button', onclick: () => resolveReadingList(true).then(() => { announce = tr('已选择本机顺序'); render(); }).catch(operationError) }, tr('保留本机顺序并同步')),
            h('button', { class: 'btn', type: 'button', onclick: () => resolveReadingList(false).then(() => { announce = tr('已采用另一设备的顺序'); render(); }).catch(operationError) }, tr('使用另一设备顺序'))));
      }
    }
    const nextSignature = JSON.stringify([state.items, !!state.conflict, books.map((b) => [b.id, b.title, b.author, b.offline])]);
    if (nextSignature !== signature) {
      signature = nextSignature;
      const active = document.activeElement;
      const focus = list.contains(active) && active.dataset.listBook ? { id: active.dataset.listBook, action: active.dataset.listAction } : null;
      const catalog = bookMap();
      list.replaceChildren(...state.items.map((id, i) => {
        const book = catalog.get(id), title = book?.title || tr('这本书暂时不可用');
        const link = book ? h('a', { href: `#/read/${id}`, 'data-list-book': id, 'data-list-action': 'read' }, title) : h('strong', {}, title);
        return h('li', { class: `reading-list-book${i === 0 ? ' is-next' : ''}`, 'data-list-book': id },
          h('span', { class: 'reading-list-position', 'aria-label': tr("第 {0} 位", [i + 1]) }, String(i + 1).padStart(2, '0')),
          h('div', { class: 'reading-list-book-copy' }, i === 0 ? h('span', { class: 'reading-list-next-label' }, tr('下一本，从这里开始')) : null,
            h('h2', {}, link), h('p', {}, book ? [book.author || tr('作者未标注'), book.offline ? tr('已下载到这台设备') : tr('阅读正文需要网络或已有缓存')].join(' · ') : tr("编号 {0} · 可移出清单，其他书的顺序不受影响", [id]))),
          h('div', { class: 'reading-list-book-actions', role: 'group', 'aria-label': tr("调整《{0}》", [title]) },
            h('button', { type: 'button', 'data-list-book': id, 'data-list-action': 'up', 'aria-label': tr("将《{0}》上移", [title]), disabled: i === 0 || !!state.conflict, onclick: () => move(id, -1) }, '↑'),
            h('button', { type: 'button', 'data-list-book': id, 'data-list-action': 'down', 'aria-label': tr("将《{0}》下移", [title]), disabled: i === state.items.length - 1 || !!state.conflict, onclick: () => move(id, 1) }, '↓'),
            h('button', { class: 'reading-list-remove', type: 'button', 'data-list-book': id, 'data-list-action': 'remove', 'aria-label': tr("将《{0}》移出清单", [title]), disabled: !!state.conflict, onclick: () => remove(id) }, tr('移出'))));
      }));
      if (!state.items.length) list.append(h('li', { class: 'reading-list-empty' }, h('span', { 'aria-hidden': 'true' }, tr('序')), h('h2', {}, tr('想读的书，不必靠记忆排队')), h('p', {}, tr('从下面的书架挑几本，先后顺序可以随时调整。也可以在书架的书籍菜单里加入。')),
        h('button', { class: 'btn primary', type: 'button', onclick: () => { picker.open = true; search.focus(); } }, tr('挑选下一本'))));
      restoreFocus(focus);
    }
    live.textContent = announce; undo.hidden = !removed; undo.disabled = !!state.conflict;
    renderPicker();
  }
  function renderPicker() {
    if (disposed || signal?.aborted) return;
    let state; try { state = readReadingList(); } catch { return; }
    const terms = search.value.normalize('NFKC').toLocaleLowerCase().trim().split(/\s+/).filter(Boolean);
    const matches = books.filter((book) => { const text = `${book.title || ''} ${book.author || ''}`.normalize('NFKC').toLocaleLowerCase(); return terms.every((term) => text.includes(term)); });
    const available = matches.filter((book) => !state.items.includes(book.id));
    pickerState.textContent = !catalogLoaded && !books.length ? booksError || tr('正在打开书架…') : tr("{0} 本可以加入{1}", [available.length, terms.length ? tr(' · 搜索结果') : '']);
    more.hidden = matches.length <= shown;
    const key = JSON.stringify([matches.slice(0, shown).map((b) => [b.id, b.title, b.author]), state.items, !!state.conflict, shown]);
    if (pickerSignature === key) return;
    pickerSignature = key;
    const active = document.activeElement;
    const focus = pickerList.contains(active) && active.dataset.listBook ? { id: active.dataset.listBook, action: 'add' } : null;
    pickerList.replaceChildren(...matches.slice(0, shown).map((book) => {
      const added = state.items.includes(book.id);
      return h('li', {}, h('div', {}, h('strong', {}, book.title || tr('未命名')), h('small', {}, book.author || tr('作者未标注'))),
        h('button', { type: 'button', class: 'btn', 'data-list-book': book.id, 'data-list-action': 'add', 'aria-label': `${added ? tr('已加入') : tr('加入')}《${book.title || tr('未命名')}》`, disabled: added || !!state.conflict || state.items.length >= LIMIT,
          onclick: async () => { try { await addToReadingList(book.id); announce = tr("《{0}》已排在清单末尾", [book.title]); render(); } catch (error) { operationError(error); } } }, added ? tr('已加入') : tr('加入')));
    }));
    if (focus) { const target = pickerList.querySelector(`[data-list-book="${focus.id}"]`); if (target && !target.disabled) target.focus({ preventScroll: true }); else search.focus({ preventScroll: true }); }
    if (!matches.length && catalogLoaded) pickerList.append(h('li', { class: 'reading-list-picker-empty' }, terms.length ? tr('没有找到匹配的书，试试书名或作者的一部分。') : h('a', { class: 'linkish', href: '#/' }, tr('先回书架导入一本书'))));
  }
  async function loadBooks() {
    try {
      const result = await api.books({ signal, timeout: 12000 });
      if (disposed || signal?.aborted) return;
      books = result; catalogLoaded = true; booksError = '';
      store.set(BOOKS_KEY, books.slice(0, 2000).map(({ id, title, author }) => ({ id, title, author })));
      signature = pickerSignature = ''; render();
    } catch (error) {
      if (disposed || signal?.aborted) return;
      booksError = tr('书架暂未更新，清单顺序仍保存在本机。'); render();
      if (error instanceof AuthError) throw error;
    }
  }
  const changed = () => render();
  const stored = (event) => { if (event.key === READING_LIST_KEY) render(); };
  const online = () => { render(); retryReadingList({ force: true }).catch(() => {}); loadBooks().catch(() => {}); };
  const offline = () => render();
  addEventListener(EVENT, changed); addEventListener('storage', stored); addEventListener('online', online); addEventListener('offline', offline);
  signal?.addEventListener('abort', () => { disposed = true; removeEventListener(EVENT, changed); removeEventListener('storage', stored); removeEventListener('online', online); removeEventListener('offline', offline); }, { once: true });
  render();
  if (!readReadingList().items.length) picker.open = true;
  const initialSync = retryReadingList({ force: true }).catch((error) => { if (error instanceof AuthError) throw error; });
  await Promise.all([loadBooks(), initialSync]);
}
