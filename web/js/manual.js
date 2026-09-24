// Reader-authored source-anchored entries. Writes require a connection and server receipt.
import { api, ConflictError } from './api.js';
import { h, toast } from './util.js';
import { t as tr } from './i18n.js';

export function manualView(ctx, arg, pane, title) {
  title.append(tr('手动补充'), h('small', {}, tr("截至第 {0} 页", [ctx.info.global])));
  const status = h('p', { class: 'muted', role: 'status' }, tr('正在读取你补充的资料…'));
  const list = h('div', { class: 'cast' });
  const kind = h('select', { 'aria-label': tr('条目类型') },
    h('option', { value: 'person' }, tr('人物')), h('option', { value: 'concept' }, tr('概念')));
  const name = h('input', { type: 'text', maxlength: 80, required: true, placeholder: tr('原文中的完整名称'), 'aria-label': tr('原文中的完整名称') });
  const note = h('textarea', { maxlength: 3000, rows: 5, placeholder: tr('写下你目前知道的身份、含义或线索（可留空）'), 'aria-label': tr('补充说明') });
  const submit = h('button', { type: 'submit', class: 'btn primary' }, tr('保存补充'));
  const cancel = h('button', { type: 'button', class: 'btn', onclick: () => ctx.panes.open('manual', undefined, { replace: true }) }, tr('取消编辑'));
  cancel.hidden = true;
  const remove = h('button', { type: 'button', class: 'linkish' }, tr('删除这条补充'));
  remove.hidden = true;
  const form = h('form', { class: 'manual-form' },
    h('label', {}, tr('类型'), kind), h('label', {}, tr('名称'), name),
    h('label', {}, tr('你知道的内容'), note),
    h('div', { class: 'manual-actions' }, submit, cancel, remove));
  form.hidden = true;
  pane.append(h('p', { class: 'muted' }, tr('联网后可保存。只补充已读原文里出现过的名称；说明从保存这一页起可见，不会自动改写原文或 AI 资料。')),
    status, list, h('h4', {}, arg?.edit ? tr('编辑补充') : tr('新增人物或概念')), form);

  let items = [], edit = null, operation = crypto.randomUUID(), deleteOperation = crypto.randomUUID(), busy = false;
  const currentCutoff = () => ctx.current().info.cutoff;
  const render = () => {
    list.replaceChildren();
    for (const item of items) {
      const entry = h('div', { class: 'cast-row manual-entry' },
        h('div', {}, h('b', {}, item.name), h('small', {}, item.kind === 'concept' ? tr(' · 概念') : tr(' · 人物')),
          h('p', { class: 'muted' }, item.versions.at(-1)?.note || tr('尚未写说明'))),
        h('button', { type: 'button', class: 'linkish', onclick: () => ctx.panes.open('manual', { edit: item.id }, { replace: true }) }, tr('编辑')));
      list.append(entry);
    }
    if (!items.length) list.append(h('p', { class: 'muted' }, tr('还没有手动补充的条目。')));
  };
  const choose = (item) => {
    edit = item;
    kind.value = item?.kind || 'person'; kind.disabled = !!item;
    name.value = item?.name || ''; name.disabled = !!item;
    note.value = item?.versions.at(-1)?.note || '';
    submit.textContent = item ? tr('保存修改') : tr('保存补充');
    cancel.hidden = !item; remove.hidden = !item;
    if (item?.locked) {
      submit.disabled = true; remove.disabled = true;
      status.textContent = tr('这条资料在更后面的阅读位置修改过；回到那里才能继续编辑。');
    }
  };
  const load = async () => {
    const response = await api.manualEntities(ctx.book.id, currentCutoff(), { signal: ctx.signal });
    items = response.items;
    render();
    choose(arg?.edit ? items.find((x) => x.id === arg.edit) : null);
    if (arg?.edit && !edit) status.textContent = tr('这一页还看不到该条目，或它已被删除。');
    else if (!edit?.locked) status.textContent = tr('补充资料会随本书备份一起保存。');
    form.hidden = !!(arg?.edit && !edit);
  };
  form.addEventListener('submit', async (ev) => {
    ev.preventDefault();
    if (busy || edit?.locked) return;
    const cutoff = currentCutoff();
    const payload = { id: edit?.id || crypto.randomUUID(), kind: kind.value, name: name.value.trim(),
      note: note.value, knowledge_cutoff: cutoff, expected_revision: edit?.revision || 0, operation };
    busy = true; submit.disabled = true; status.textContent = tr('正在保存…');
    let saved = false;
    try {
      const result = await api.saveManualEntity(ctx.book.id, payload, { signal: ctx.signal });
      saved = true;
      operation = crypto.randomUUID();
      await ctx.refreshManual();
      toast(tr('已补充到阅读资料'));
      ctx.panes.open('person', `U${result.item.id}`, { replace: true });
    } catch (error) {
      status.textContent = saved ? tr('资料已经保存，但页面暂时没有刷新；重新打开这本书即可看到。')
        : error instanceof ConflictError ? tr('其他设备已改过这条资料。请先复制你的文字，返回后重新打开。') : error.message;
      if (!saved) submit.disabled = false;
    } finally { busy = false; }
  });
  remove.addEventListener('click', async () => {
    if (!edit || busy || !confirm(tr("删除手动补充的「{0}」？", [edit.name]))) return;
    busy = true; remove.disabled = true; status.textContent = tr('正在删除…');
    try {
      const result = await api.saveManualEntity(ctx.book.id, { id: edit.id, kind: edit.kind, name: edit.name,
        note: edit.versions.at(-1)?.note || '', knowledge_cutoff: currentCutoff(),
        expected_revision: edit.revision, operation: deleteOperation, deleted: true }, { signal: ctx.signal });
      if (!result.item?.deleted) throw new Error(tr('删除尚未确认，请重新打开后检查'));
      await ctx.refreshManual();
      toast(tr('已删除手动补充'));
      ctx.panes.open('cast', { mode: 'all' }, { replace: true });
    } catch (error) {
      status.textContent = error instanceof ConflictError ? tr('其他设备已改过这条资料，请重新打开后再删。') : error.message;
      remove.disabled = false;
    } finally { busy = false; }
  });
  load().catch((error) => { status.textContent = tr("暂时读不到手动资料：{0}", [error.message]); form.hidden = true; });
}
