// UI language is a reader preference. It never changes book text, saved notes, or KG records.
import { translations } from './i18n-catalogs.js';

const KEY = 'yedu-ui-language-v1';
export const languages = Object.freeze([
  { code: 'zh-CN', name: '简体中文' },
  { code: 'en', name: 'English' },
  { code: 'es', name: 'Español' },
  { code: 'fr', name: 'Français' },
  { code: 'de', name: 'Deutsch' },
  { code: 'pt-BR', name: 'Português (Brasil)' },
  { code: 'ja', name: '日本語' },
  { code: 'ko', name: '한국어' },
]);
const supported = new Set(languages.map(({ code }) => code));

function storedPreference() {
  try { return localStorage.getItem(KEY) || 'auto'; } catch { return 'auto'; }
}

function match(code) {
  if (!code) return null;
  if (supported.has(code)) return code;
  const base = code.toLowerCase().split('-')[0];
  return languages.find((row) => row.code.toLowerCase().split('-')[0] === base)?.code || null;
}

function deviceLanguage() {
  if (typeof document === 'undefined') return 'zh-CN';
  const requested = globalThis.navigator?.languages?.length ? navigator.languages : [globalThis.navigator?.language];
  if (!requested.some(Boolean)) return 'zh-CN';
  for (const code of requested) {
    const resolved = match(code);
    if (resolved) return resolved;
  }
  return 'en';
}

export function languagePreference() {
  const value = storedPreference();
  return value === 'auto' || supported.has(value) ? value : 'auto';
}

export function currentLanguage() {
  return languagePreference() === 'auto' ? deviceLanguage() : languagePreference();
}

export function setLanguagePreference(code) {
  if (code !== 'auto' && !supported.has(code)) throw new RangeError('Unsupported interface language');
  try {
    if (code === 'auto') localStorage.removeItem(KEY);
    else localStorage.setItem(KEY, code);
  } catch { throw new Error(t('无法保存语言设置，请检查本机存储空间。')); }
  globalThis.window?.YeduApp?.setAppLanguage?.(code);
  if (typeof document !== 'undefined') document.documentElement.lang = currentLanguage();
}

export function t(source, values = {}) {
  const language = currentLanguage();
  const template = language === 'zh-CN' ? source : translations[language]?.[source] ?? translations.en?.[source] ?? source;
  return template.replace(/\{([\w]+)\}/g, (whole, key) => Object.hasOwn(values, key) ? String(values[key]) : whole);
}

export function localizeServerMessage(message) {
  const raw = String(message || '');
  if (!raw || currentLanguage() === 'zh-CN' || !/[\u3400-\u9fff]/.test(raw)) return raw;
  return translations[currentLanguage()]?.[raw] || t('操作未完成，请检查输入或稍后重试。');
}

export function setDocumentLanguage() {
  if (typeof document === 'undefined') return;
  globalThis.window?.YeduApp?.setAppLanguage?.(languagePreference());
  document.documentElement.lang = currentLanguage();
  document.title = t('页读');
}
