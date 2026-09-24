// Source spans remain UTF-16 offsets, matching DOM Range and the server contract.
import { t } from './i18n.js';
const EN = /^(he|him|his|she|her|they|them)$/i;
const ZH = ['他们', '她们', '它们', '这人', '那人', '此人', '对方', '两人', '二人', '他', '她', '它'];
export function pronounSpan(text, offset) {
  const i = Math.max(0, Math.min(text.length - 1, offset));
  if (/[A-Za-z]/.test(text[i] || '')) {
    let start = i, end = i + 1;
    while (start > 0 && /[A-Za-z]/.test(text[start - 1])) start--;
    while (end < text.length && /[A-Za-z]/.test(text[end])) end++;
    return EN.test(text.slice(start, end)) ? { start, end, text: text.slice(start, end) } : null;
  }
  for (const word of ZH) for (const start of [i, i - 1]) {
    if (start >= 0 && i >= start && i < start + word.length && text.slice(start, start + word.length) === word) return { start, end: start + word.length, text: word };
  }
  return null;
}
export function textOffset(block, node, offset) {
  if (node.nodeType === Node.ELEMENT_NODE && (node === block || block.contains(node))) {
    const range = document.createRange(); range.selectNodeContents(block); range.setEnd(node, offset);
    const fragment = range.cloneContents();
    fragment.querySelectorAll('.fn,.fn-ref,.note-mark').forEach((el) => el.remove());
    return fragment.textContent.length;
  }
  let total = 0;
  const walker = document.createTreeWalker(block, NodeFilter.SHOW_TEXT);
  for (let current = walker.nextNode(); current; current = walker.nextNode()) {
    if (current.parentElement.closest('.fn,.fn-ref,.note-mark')) continue;
    if (current === node) return total + offset;
    total += current.textContent.length;
  }
  throw new Error(t('找不到原文位置，请重新点击'));
}
