import { canReachLibrary } from './runtime.js';
// Personal notes use exact source anchors. Pending edits survive reload and never silently win conflicts.
import { api, ConflictError } from './api.js';
import { h, store, toast } from './util.js';
import { t as tr } from './i18n.js';
const flights = new Map();
export const noteId = () => crypto.randomUUID();
const keyOf = (id) => `notebook:${id}`;
const read = (id) => store.get(keyOf(id), []);
const localLocks = new Map();
async function mutate(id, fn) {
  const action = () => { const rows = fn(read(id)); write(id, rows); return rows; };
  if (navigator.locks) return navigator.locks.request(`yedu-notebook:${id}`, action);
  const next = (localLocks.get(id) || Promise.resolve()).catch(() => {}).then(action);
  localLocks.set(id, next); return next;
}
const changed = (id) => dispatchEvent(new CustomEvent('yedu-notebook', { detail: id }));
function write(id, rows) {
  if (!store.set(keyOf(id), rows)) throw new Error(tr('本机空间不足，摘记尚未保存，请先复制内容'));
  changed(id);
}
export function mergeNotes(local, remote) {
  const map = new Map(local.map((x) => [x.id, x]));
  for (const item of remote) {
    const own = map.get(item.id);
    if (!own?.dirty && (!own || item.revision >= own.revision)) map.set(item.id, item);
  }
  return [...map.values()];
}
export async function syncNotes(id) {
  if (flights.has(id)) {
    await flights.get(id).catch(() => {});
    if (canReachLibrary() && read(id).some((n) => n.dirty && !n.conflict)) return syncNotes(id);
    return;
  }
  const job = (async () => {
    // Bound work per visit; a pathological imported notebook cannot monopolize requests.
    for (let i = 0; canReachLibrary() && i < 100; i++) {
      const sent = read(id).find((n) => n.dirty && !n.conflict);
      if (!sent) break;
      try {
        const result = await api.saveNote(id, sent, { timeout: 12000 });
        await mutate(id, (rows) => rows.map((latest) => {
          if (latest.id !== sent.id) return latest;
          if (result.item.revision < (latest.revision || 0)) return latest;
          if (latest.operation === sent.operation) return result.item;
          if (!latest.dirty) return latest;
          // An edit made while its previous version was in flight inherits the successful base.
          return { ...latest, expected_revision: result.item.revision, revision: result.item.revision };
        }));
      } catch (e) {
        if (e instanceof ConflictError) await mutate(id, (rows) => rows.map((n) => n.id === sent.id && n.dirty && (e.data.item?.revision || 0) > (n.expected_revision || 0) ? { ...n, conflict: { item: e.data.item || null } } : n));
        else throw e;
      }
    }
    const remote = await api.notebook(id, { timeout: 12000 });
    if (!Array.isArray(remote.items)) throw new Error(tr('摘记同步数据无效'));
    await mutate(id, (rows) => mergeNotes(rows, remote.items));
  })();
  flights.set(id, job);
  try { await job; } finally { flights.delete(id); }
}
export async function retryNotebooks() {
  if (!canReachLibrary()) return;
  for (const key of Object.keys(localStorage).filter((k) => k.startsWith('notebook:'))) {
    const id = key.slice(9);
    if (read(id).some((n) => n.dirty && !n.conflict)) await syncNotes(id).catch(() => {});
  }
}
export class Notebook {
  constructor(book) { this.book = book; this.error = ''; }
  get items() { return read(this.book.id); }
  async sync() {
    try { await syncNotes(this.book.id); this.error = ''; }
    catch (e) { this.error = canReachLibrary() ? e.message : ''; }
    changed(this.book.id);
  }
  async save(input) {
    let saved;
    await mutate(this.book.id, (rows) => {
      const old = rows.find((n) => n.id === input.id);
      if (!old && rows.length >= 5000) throw new Error(tr('本书摘记已达上限，请先导出留存'));
      if (old?.conflict) throw new Error(tr('请先处理这条摘记的同步冲突'));
      if (input.operation && old && input.operation !== old.operation) throw new Error(tr('这条摘记刚在另一个窗口修改，请先复制草稿，再返回查看最新版本'));
      saved = { ...old, ...input, id: input.id || noteId(), sourceVersion: this.book.version,
        operation: noteId(), expected_revision: old?.revision || 0, revision: old?.revision || 0,
        created: old?.created || Date.now() / 1000, updated: Date.now() / 1000, dirty: true };
      return rows.filter((n) => n.id !== saved.id).concat(saved);
    });
    this.sync(); return saved;
  }
  async resolve(id, keepBoth) {
    await mutate(this.book.id, (rows) => {
      const own = rows.find((n) => n.id === id);
      if (!own?.conflict) return rows;
      const remote = own.conflict.item, result = rows.filter((n) => n.id !== id).concat(remote ? [remote] : []);
      if (keepBoth && !own.deleted) {
        const { conflict, ...copy } = own;
        result.push({ ...copy, id: noteId(), operation: noteId(), revision: 0, expected_revision: 0, dirty: true });
      }
      return result;
    });
    this.sync();
  }

}
export function notebookMarkdown(book, items) {
  const lines = [`# ${book.title}`, '', tr('我的摘记'), ''];
  for (const n of items.filter((n) => !n.deleted).sort((a, b) => a.start - b.start)) {
    lines.push(tr("## {0} · 原文位置 {1}", [n.kind === 'bookmark' ? tr('书签') : tr('摘记'), n.start]), '', ...n.quote.split('\n').map((s) => `> ${s}`), '', n.text, '', tr("[回到书中]({0}/#/read/{1}?at={2})", [location.origin, book.id, n.start]), '');
  }
  return lines.join('\n');
}
export function notebookView(ctx, arg, pane, title) {
  title.append(tr('我的摘记'), h('small', {}, tr('你留下的书签、原文与想法')));
  const notebook = ctx.notebook;
  if (arg?.draft || arg?.edit) return editView(ctx, arg, pane);
  const status = h('p', { class: 'muted notebook-status', role: 'status' });
  const query = h('input', { type: 'search', class: 'notebook-filter', placeholder: tr('查找摘录或想法'), 'aria-label': tr('查找摘记') });
  const list = h('div', { class: 'notebook-list' });
  const showAll = h('input', { type: 'checkbox', 'aria-label': tr('包含后面读过的摘记') });
  const actions = h('div', { class: 'notebook-actions' },
    h('button', { class: 'btn primary', onclick: () => ctx.panes.open('notebook', { draft: { start: ctx.info.start, end: ctx.info.start, quote: '', kind: 'note' } }) }, tr('写下此刻的想法')),
    h('button', { class: 'btn', onclick: () => ctx.addBookmark() }, tr('书签记在这里')));
  pane.append(actions, h('p', { class: 'muted' }, tr('保存到本机后会联网同步。摘录原文：关闭面板，点「摘录」，选中一段文字。')), status, query,
    h('label', { class: 'notebook-scope' }, showAll, tr('包含后面读过的摘记（可能涉及后文）')), list);
  const exportButton = h('button', { class: 'btn', onclick: async () => {
    const text = notebookMarkdown(ctx.book, notebook.items);
    try { await navigator.clipboard.writeText(text); toast(tr('全书个人摘记已复制，可粘贴留存')); }
    catch { const box = h('textarea', { class: 'notebook-export', readonly: true, 'aria-label': tr('摘记导出文本') }, text); pane.append(box); box.focus(); box.select(); toast(tr('请复制下方选中的摘记')); }
  } }, tr('复制全书摘记（Markdown）'));
  pane.append(h('div', { class: 'notebook-export-actions' }, exportButton,
    h('a', { class: 'linkish', href: /YeduApp\/1\.[012]\./.test(navigator.userAgent) ? 'https://github.com/athemeroy/thusfar/releases/latest' : `/api/books/${ctx.book.id}/notebook.md` }, /YeduApp\/1\.[012]\./.test(navigator.userAgent) ? tr('更新安卓 App 后可下载摘记') : tr('下载已同步的摘记'))));
  const render = () => {
    const all = notebook.items, pending = all.filter((n) => n.dirty).length, conflicts = all.filter((n) => n.conflict).length;
    status.textContent = conflicts ? tr("{0} 条在另一设备也有修改，请选择如何保留。", [conflicts]) : pending ? tr("{0} 条已保存在本机，{1}。", [pending, canReachLibrary() ? tr('等待同步') : tr('联网后同步')]) : canReachLibrary() ? tr('个人摘记会随这本书的备份一同导出。') : tr('离线查看 · 修改先保存在本机。');
    if (notebook.error) status.append(tr(" 同步暂未完成：{0}", [notebook.error]));
    status.append(h('button', { class: 'linkish', onclick: () => notebook.sync() }, tr('立即同步')));
    const term = query.value.trim().toLocaleLowerCase();
    const selected = all.filter((n) => (!n.deleted || n.conflict) && (showAll.checked || Math.max(n.knowledge_cutoff ?? n.end, n.conflict?.item?.knowledge_cutoff ?? n.conflict?.item?.end ?? 0) <= ctx.current().info.cutoff) && `${n.quote}\n${n.text}`.toLocaleLowerCase().includes(term)).sort((a, b) => a.start - b.start);
    list.replaceChildren();
    for (const n of selected) {
      const card = h('article', { class: 'notebook-card' },
        h('button', { class: 'note-source', onclick: () => ctx.goSource(n.start, n.end || n.start) }, n.kind === 'bookmark' ? tr('书签') : tr('摘记'), tr(" · 第 {0} 页", [ctx.pageNo(n.start)]), ' ↗'),
        n.quote ? h('blockquote', {}, n.quote) : null,
        n.text ? h('p', { class: 'note-thought' }, n.text) : null);
      if (n.conflict) {
        card.append(h('p', { class: 'note' }, tr('另一设备的版本：'), n.conflict.item?.deleted ? tr('已删除') : n.conflict.item?.text || n.conflict.item?.quote || tr('内容已变化')),
          h('button', { class: 'btn', onclick: () => notebook.resolve(n.id, true).catch((e) => toast(e.message)) }, n.deleted ? tr('恢复另一设备版本') : tr('两份都保留')),
          h('button', { class: 'linkish', onclick: () => notebook.resolve(n.id, false).catch((e) => toast(e.message)) }, tr('使用另一设备版本')));
      } else card.append(h('div', { class: 'note-tools' },
        h('button', { class: 'linkish', onclick: () => ctx.panes.open('notebook', { edit: n.id }) }, tr('编辑')),
        h('button', { class: 'linkish', onclick: async () => { if (confirm(tr('删除这条摘记？原文会保留。'))) { try { await notebook.save({ ...n, deleted: true }); } catch (e) { toast(e.message); } } } }, tr('删除')),
        n.dirty ? h('small', { class: 'muted' }, tr('待同步')) : null));
      list.append(card);
    }
    if (!selected.length) list.append(h('div', { class: 'empty notebook-empty' }, h('b', {}, tr('留一点自己的痕迹')), term ? tr('没有找到匹配的摘记。') : tr('把值得重读的原文、疑问和此刻的想法，留在它发生的位置。')));
  };
  query.addEventListener('input', render); showAll.addEventListener('change', render);
  const update = (e) => { if (e.detail === ctx.book.id) render(); };
  const stored = (e) => { if (e.key === keyOf(ctx.book.id)) render(); };
  addEventListener('storage', stored); addEventListener('yedu-notebook', update);
  ctx.onLeave(() => { removeEventListener('yedu-notebook', update); removeEventListener('storage', stored); });
  render(); notebook.sync();
}
function editView(ctx, arg, pane) {
  const existing = arg.edit && ctx.notebook.items.find((n) => n.id === arg.edit);
  const note = existing || arg.draft;
  if (!note) return pane.append(h('p', {}, tr('这条摘记已不在本机，请返回并同步。')));
  const draftKey = `note-draft:${ctx.book.id}:${note.id || note.start}`;
  const savedDraft = store.get(draftKey, null);
  const draftCutoff = typeof savedDraft === 'object' && savedDraft ? savedDraft.cutoff : 0;
  if (draftCutoff > ctx.info.cutoff && !arg.revealDraft) {
    pane.append(h('p', { class: 'note' }, tr('这里有一份读到后面时写下的草稿，可能涉及后文。草稿仍保存在本机。')),
      h('button', { class: 'btn', onclick: () => ctx.panes.open('notebook', { ...arg, revealDraft: true }, { replace: true }) }, tr('查看后来的草稿（可能剧透）')),
      h('button', { class: 'btn', onclick: () => ctx.panes.back() }, tr('返回')));
    return;
  }
  const text = h('textarea', { class: 'note-editor', rows: 7, maxlength: 10000, placeholder: tr('写下你的理解、疑问，或留给下次阅读的提醒…'), 'aria-label': tr('我的想法') });
  text.value = (savedDraft && typeof savedDraft === 'object' ? savedDraft.text : savedDraft) ?? note.text ?? '';
  const hint = h('p', { class: 'muted', role: 'status' }, tr('写作草稿保留在本机，点击保存后同步。'));
  text.addEventListener('input', () => { hint.textContent = store.set(draftKey, { text: text.value, cutoff: Math.max(ctx.info.cutoff, draftCutoff, note.knowledge_cutoff || note.end) }) ? tr('草稿已留在本机') : tr('本机存储不足，请复制文字后再离开'); });
  pane.append(note.quote ? h('blockquote', { class: 'note-quote' }, note.quote) : h('p', { class: 'muted' }, tr("记在第 {0} 页", [ctx.pageNo(note.start)])), text, hint,
    h('button', { class: 'btn primary', onclick: async () => {
      if (!note.quote && !text.value.trim() && note.kind !== 'bookmark') return toast(tr('先写下一点想法吧'));
      try { await ctx.notebook.save({ ...note, text: text.value, deleted: false, knowledge_cutoff: Math.max(note.knowledge_cutoff || note.end, draftCutoff, ctx.info.cutoff, ctx.current().info.cutoff) }); localStorage.removeItem(draftKey); toast(tr('摘记已保存在本机')); ctx.panes.open('notebook', undefined, { root: true }); }
      catch (e) { toast(e.message, 5000); }
    } }, tr('保存摘记')), h('button', { class: 'btn', onclick: () => ctx.panes.back() }, tr('返回')));
  requestAnimationFrame(() => text.focus({ preventScroll: true }));
}
