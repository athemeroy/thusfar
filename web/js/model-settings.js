import { api } from './api.js';
import { h, icon, toast } from './util.js';
import { standalone } from './runtime.js';
import { currentLanguage, languagePreference, languages, setLanguagePreference, t } from './i18n.js';

export function languageControl() {
  const select = h('select', { 'aria-label': t('界面语言'), onchange: () => {
    try { setLanguagePreference(select.value); location.reload(); }
    catch (error) { toast(error.message); select.value = languagePreference(); }
  } },
  h('option', { value: 'auto' }, `${t('跟随设备')} (${languages.find((row) => row.code === currentLanguage())?.name || 'English'})`),
  languages.map(({ code, name }) => h('option', { value: code }, name)));
  select.value = languagePreference();
  return select;
}

export async function openModelSettings(root, options = {}) {
  const signal = options.signal;
  const section = h('section', { class: 'language-settings', 'aria-labelledby': 'language-settings-title' },
    h('div', {}, h('h2', { id: 'language-settings-title' }, t('界面语言')),
      h('p', {}, t('切换后立即生效。书籍原文和你的笔记不会翻译。'))),
    languageControl());
  const page = h('main', { class: 'model-settings paper-grain' },
    h('header', {}, h('a', { class: 'model-back', href: '#/' }, icon('back'), t('回书架')),
      h('p', { class: 'library-eyebrow' }, standalone ? t('页读 · 仅在这台手机上使用') : t('页读 · 你的私人书房')),
      h('h1', {}, standalone ? t('模型设置') : t('设置')),
      h('p', {}, standalone ? t('读书不需要网络。你确认整理或提问后，页读才会连接这里填写的接口。') : t('选择适合你的界面语言。阅读位置、书籍和笔记会照常保留。'))),
    section);
  root.replaceChildren(page);
  if (!standalone) return;

  const loading = h('p', { class: 'model-settings-status', role: 'status' }, t('正在读取这台手机上的设置…'));
  page.append(loading);
  const saved = await api.settings({ signal });
  if (signal?.aborted) return;
  loading.remove();
  const endpoint = h('input', { type: 'url', required: true, maxlength: 500, autocomplete: 'url', 'aria-label': t('模型接口地址') });
  endpoint.value = saved.base_url;
  const model = h('input', { type: 'text', required: true, maxlength: 100, autocomplete: 'off', 'aria-label': t('抽取模型') });
  model.value = saved.model;
  const key = h('input', { type: 'password', maxlength: 1024, autocomplete: 'new-password', 'aria-label': t('API 密钥') });
  const keyStatus = h('p', { class: 'model-key-status' }, saved.api_key_set ? t('已保存密钥，末尾 {last4}', { last4: saved.api_key_last4 }) : t('还没有保存密钥'));
  const clearKey = h('input', { type: 'checkbox', 'aria-label': t('清除已保存的密钥') });
  const status = h('p', { class: 'model-settings-status', role: 'status' });
  const submit = h('button', { type: 'submit', class: 'btn zhu' }, t('保存设置'));
  const form = h('form', { class: 'model-settings-form' },
    h('h2', {}, t('模型设置')),
    h('label', {}, t('模型接口地址'), endpoint, h('small', {}, t('填写兼容 OpenAI 接口的 HTTPS 地址，例如 https://api.deepseek.com/v1'))),
    h('label', {}, t('抽取模型'), model, h('small', {}, t('例如 deepseek-flash+nothink。整理前会显示费用估算。'))),
    h('label', {}, t('API 密钥'), key, keyStatus, h('small', {}, t('留空会保留已保存的密钥。'))),
    h('label', { class: 'model-clear-key' }, clearKey, t('清除已保存的密钥')),
    h('p', { class: 'model-route-note' }, t('人物资料使用所填模型接口。JEV 判断走免费的 classifier.dev；额度用完会暂停，不会自动切到付费通道。')),
    status, submit);
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    if (signal?.aborted) return;
    if (clearKey.checked && key.value) { status.textContent = t('请先清空新密钥，再勾选清除。'); return; }
    submit.disabled = true; status.textContent = t('正在保存…');
    try {
      const result = await api.saveSettings({ base_url: endpoint.value.trim(), model: model.value.trim(),
        api_key: key.value, clear_key: clearKey.checked, jev_route: 'free-only' }, { signal });
      key.value = ''; clearKey.checked = false;
      keyStatus.textContent = result.api_key_set ? t('已保存密钥，末尾 {last4}', { last4: result.api_key_last4 }) : t('还没有保存密钥');
      status.textContent = t('已保存在这台手机。开始整理前，请确认预计费用。');
      toast(t('模型设置已保存'));
    } catch (error) { if (!signal?.aborted) status.textContent = error.message; }
    finally { submit.disabled = false; }
  });
  page.append(form);
}
