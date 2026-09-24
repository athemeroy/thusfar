import assert from 'node:assert/strict';
import { scanBook, sourceExcerpt, visibleChapterTitle, SEARCH_LIMITS, abortable } from '../web/js/search.js';

const chapters = [
  { title: '第一章 已读开头', kind: 'body', o0: 0, o1: 100 },
  { title: '第二章 秘密身份', kind: 'body', o0: 100, o1: 300 },
];
const firstText = '😀甲说 Find me，甲又来了。到此为止。SPOILER_SECRET';
const data = [
  { blocks: [{ k: 'h', t: 'Find heading', o: 0 }, { k: 'p', t: firstText, o: 15 }] },
  { blocks: [{ k: 'p', t: '甲的秘密：Find later', o: 100 }] },
];
let loads = [];
const loadChapter = async (n) => { loads.push(n); return data[n]; };
const cutoff = 15 + firstText.indexOf('SPOILER_SECRET');
const bounded = await scanBook({ chapters, query: '甲', cutoff, loadChapter });
assert.equal(bounded.done, true);
assert.deepEqual(loads, [0], 'unread chapters are not fetched in current-page scope');
assert.equal(bounded.results.length, 2);
assert.equal(bounded.results[0].start, 17, 'astral prefix occupies two source UTF-16 units');
assert.equal(bounded.results[0].end, 18);
for (const row of bounded.results) assert.doesNotMatch(JSON.stringify(row), /SPOILER_SECRET|秘密/);
assert.deepEqual((await scanBook({ chapters, query: 'SPOILER_SECRET', cutoff, loadChapter })).results, []);
assert.equal((await scanBook({ chapters, query: 'Find', cutoff, loadChapter })).results.length, 2, 'headings and paragraphs are searched');
assert.equal((await scanBook({ chapters, query: '甲', cutoff: 300, loadChapter })).results.length, 3, 'explicit full-book scope includes later chapters');
assert.doesNotMatch(visibleChapterTitle(chapters[1], 100), /秘密身份/);
assert.doesNotMatch(visibleChapterTitle(chapters[1], 50), /秘密身份/, 'rewinding restores the title boundary');
assert.match(visibleChapterTitle(chapters[1], 50, true), /秘密身份/);
assert.doesNotMatch(visibleChapterTitle({...chapters[1],kind:'back'},50), /秘密身份/, 'unread appendix titles can also spoil');

// Matches crossing chunk boundaries must keep their original positions.
const crossing = { blocks: [{ k: 'caption', t: 'aaaaXYZzz😀XYZ', o: 20 }] };
const chunked = await scanBook({ chapters: [{ o0: 0 }], query: 'XYZ', cutoff: 100, loadChapter: async () => crossing, limits: { chunk: 5 } });
assert.deepEqual(chunked.results.map((r) => [r.start, r.end]), [[24, 27], [31, 34]]);
const overlappingText = 'abababa😀😀😀';
let overlapCursor = null, overlapStarts = [];
do {
  const batch = await scanBook({ chapters: [{ o0: 0 }], query: 'aba', cutoff: overlappingText.length, cursor: overlapCursor,
    loadChapter: async () => ({ blocks: [{ t: overlappingText, o: 0 }] }), limits: { chunk: 2, results: 1 } });
  overlapStarts.push(...batch.results.map((r) => r.start)); overlapCursor = batch.next;
} while (overlapCursor);
assert.deepEqual(overlapStarts, [0, 2, 4], 'overlapping matches survive chunk and result-page boundaries');
const emojiOverlap = await scanBook({ chapters: [{ o0: 0 }], query: '😀😀', cutoff: overlappingText.length,
  loadChapter: async () => ({ blocks: [{ t: overlappingText, o: 0 }] }), limits: { chunk: 2 } });
assert.deepEqual(emojiOverlap.results.map((r) => r.start), [7, 9], 'overlapping astral matches keep UTF-16 anchors');
const literal = await scanBook({ chapters: [{ o0: 0 }], query: '[x].*', cutoff: 100, loadChapter: async () => ({ blocks: [{ t: 'a[x].*b', o: 0 }] }) });
assert.equal(literal.results[0].start, 1, 'queries are literal, not regular expressions');
const folded = await scanBook({ chapters: [{ o0: 0 }], query: 'abc', cutoff: 100, loadChapter: async () => ({ blocks: [{ t: '😀ABC abc', o: 0 }] }) });
assert.deepEqual(folded.results.map((r) => r.start), [2, 6], 'case folding preserves original source offsets');
const partialEmoji = sourceExcerpt('甲😀秘密', 0, 1, 2);
assert.equal(partialEmoji.after, '', 'clipping does not display half a surrogate pair');

// Resume hundreds of frequent matches without dropping or duplicating an anchor.
const dense = '甲'.repeat(211);
let cursor = null, anchors = [], batches = 0;
do {
  const part = await scanBook({ chapters: [{ o0: 0 }], query: '甲', cutoff: dense.length, cursor,
    loadChapter: async () => ({ blocks: [{ t: dense, o: 0 }] }) });
  assert.ok(part.results.length <= SEARCH_LIMITS.results);
  anchors.push(...part.results.map((r) => r.start)); cursor = part.next; batches++;
} while (cursor);
assert.equal(batches, 8);
assert.deepEqual(anchors, Array.from({ length: 211 }, (_, n) => n));
const longBook = Array.from({ length: 100 }, (_, n) => ({ o0: n * 100 }));
let chapterLoads = 0;
const chapterBounded = await scanBook({ chapters: longBook, query: '不存在', cutoff: 10000,
  loadChapter: async (n) => { chapterLoads++; return { blocks: [{ t: '原文', o: n * 100 }] }; } });
assert.equal(chapterLoads, SEARCH_LIMITS.chapters);
assert.equal(chapterBounded.done, false);
assert.equal(chapterBounded.next.chapter, SEARCH_LIMITS.chapters);
const textBounded = await scanBook({ chapters: [{ o0: 0 }], query: 'missing', cutoff: 600000,
  loadChapter: async () => ({ blocks: [{ t: 'x'.repeat(600000), o: 0 }] }) });
assert.equal(textBounded.chars, SEARCH_LIMITS.chars);
assert.equal(textBounded.next.offset, SEARCH_LIMITS.chars);

// Cancellation must finish promptly, suppress late updates, and leave shared reader work alive.
let finish, updates = 0, sharedFinished = false;
const shared = new Promise((resolve) => { finish = () => { sharedFinished = true; resolve(data[0]); }; });
const stop = new AbortController();
const pending = scanBook({ chapters, query: '甲', cutoff, signal: stop.signal, loadChapter: () => shared, onProgress: () => updates++ });
stop.abort();
await assert.rejects(pending, { name: 'AbortError' });
finish(); await shared;
assert.equal(sharedFinished, true);
assert.equal(updates, 0, 'late shared response cannot emit stale results');
const already = new AbortController(); already.abort();
await assert.rejects(abortable(Promise.resolve(1), already.signal), { name: 'AbortError' });
let published = 0;
const mid = new AbortController();
await assert.rejects(scanBook({ chapters: [{ o0: 0 }], query: 'none', cutoff: 100000, signal: mid.signal,
  loadChapter: async () => ({ blocks: [{ t: 'x'.repeat(100000), o: 0 }] }),
  onProgress: () => { published++; mid.abort(); } }), { name: 'AbortError' });
assert.equal(published, 1);

// A missing offline chapter stops with a reusable cursor instead of claiming completion.
const unavailable = new Error('本机没有下载这一章');
await assert.rejects(scanBook({ chapters, query: '甲', cutoff: 300, loadChapter: async (n) => { if (n === 1) throw unavailable; return data[n]; } }), (error) => {
  assert.equal(error.search.next.chapter, 1);
  assert.equal(error.search.done, false);
  assert.equal(error.search.results.length, 2);
  return true;
});
await assert.rejects(scanBook({ chapters, query: 'x'.repeat(161), cutoff: 100, loadChapter }), /关键词/);
await assert.rejects(abortable(new Promise(() => {}), null, 5), /获取超时/);
await assert.rejects(scanBook({ chapters, query: 'x', cutoff: 100, loadChapter: async () => ({blocks: [{t: 'wrong', o: -1}]}) }), /位置不一致/);
console.log('search tests passed: current-page clipping, UTF-16 anchors, literal matches, chunk overlap, bounded resumable scanning, and cancellation');
