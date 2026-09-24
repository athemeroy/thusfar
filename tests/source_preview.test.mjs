import assert from 'node:assert/strict';
import { sourcePreviewParts } from '../web/js/source-preview.js';

const text = '之前。😀这是原文。FUTURE_SENTINEL';
const chapter = { o0: 100, o1: 100 + text.length, blocks: [{ o: 100, k: 'p', t: text }] };
const result = sourcePreviewParts(chapter, { start: 103, end: 109, cutoff: 110 });
assert.equal(result.parts[0].quote, '😀这是原文');
assert.equal(result.parts.map((p) => p.before + p.quote + p.after).join(''), '之前。😀这是原文。');
assert(!JSON.stringify(result).includes('FUTURE'));

const throughEmoji = sourcePreviewParts(chapter, { start: 100, end: 110, cutoff: 104 });
assert.equal(throughEmoji.parts.map((p) => p.before + p.quote + p.after).join(''), '之前。');
assert.equal(throughEmoji.truncated, true);
assert.equal(sourcePreviewParts(chapter, { start: 111, end: 114, cutoff: 110 }).parts.length, 0);
assert.equal(sourcePreviewParts(chapter, { start: -1, end: 114, cutoff: 110 }).parts.length, 0);

const many = { o0: 0, o1: 2000, blocks: Array.from({ length: 1000 }, (_, n) => ({ o: 2 * n, t: n === 500 ? '选' : '文' })) };
const selected = sourcePreviewParts(many, { start: 1000, end: 1001, cutoff: 1500 });
assert.equal(selected.parts.length, 16);
assert(selected.parts.some((p) => p.quote === '选'), 'short context blocks must not push the selected passage out of the limit');
assert.equal(selected.truncated, true);

const long = { o0: 0, o1: 10000, blocks: [{ o: 0, t: '长'.repeat(10000) }] };
const bounded = sourcePreviewParts(long, { start: 500, end: 9000, cutoff: 9500 });
assert.equal(bounded.parts[0].quote.length, 1200);
assert(bounded.parts.map((p) => p.before + p.quote + p.after).join('').length <= 1680);
assert.equal(bounded.truncated, true);
console.log('source preview source-span, cutoff, Unicode and bounded-context checks passed');
