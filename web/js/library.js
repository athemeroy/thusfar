// Reading-home decisions stay pure so local/remote progress semantics are testable.
import { currentLanguage, t } from './i18n.js';
export const LIBRARY_FILTERS = ['all', 'reading', 'unread', 'finished', 'downloaded'];
export function readingProgress(book, local) {
  const remote = book.progress || {};
  const localTime = Number(local?.updatedAt) || 0, remoteTime = (Number(remote.t) || 0) * 1000;
  const useLocal = local && Number.isFinite(local.pos) && local.pos >= 0 && (local.dirty || localTime >= remoteTime);
  const chosen = useLocal ? local : remote;
  const pct = Math.max(0, Math.min(100, Number(chosen.pct) || 0));
  const pos = Math.max(0, Number(chosen.pos) || 0);
  return { pct, pos, time: useLocal ? localTime : remoteTime, local: !!useLocal,
    pending: !!(useLocal && local.dirty), conflict: !!(useLocal && local.conflict),
    state: pct >= 100 ? 'finished' : pos > 0 || pct > 0 ? 'reading' : 'unread' };
}
export function normalizeLibrary(books, getLocal = () => null) {
  return books.map((book) => ({ ...book, reading: readingProgress(book, getLocal(book.id)) }));
}
export function continueBook(books) {
  return books.filter((book) => book.reading.state === 'reading')
    .sort((a, b) => b.reading.time - a.reading.time || (b.added || 0) - (a.added || 0))[0] || null;
}
export function libraryBooks(books, { filter = 'all', query = '', sort = 'recent' } = {}) {
  const terms = String(query).normalize('NFKC').toLocaleLowerCase().trim().split(/\s+/).filter(Boolean);
  const rows = books.filter((book) => {
    if (filter === 'downloaded' ? !book.offline : filter !== 'all' && book.reading.state !== filter) return false;
    const text = `${book.title || ''} ${book.author || ''}`.normalize('NFKC').toLocaleLowerCase();
    return terms.every((term) => text.includes(term));
  });
  const title = (a, b) => String(a.title || '').localeCompare(String(b.title || ''), currentLanguage(), { numeric: true });
  return rows.sort(sort === 'title' ? title : sort === 'progress'
    ? (a, b) => b.reading.pct - a.reading.pct || title(a, b)
    : (a, b) => b.reading.time - a.reading.time || (b.added || 0) - (a.added || 0) || title(a, b));
}
export function libraryCounts(books) {
  const counts = { all: books.length, reading: 0, unread: 0, finished: 0, downloaded: 0 };
  for (const book of books) { counts[book.reading.state]++; if (book.offline) counts.downloaded++; }
  return counts;
}
export function resumeReceipts(value) {
  if (!Array.isArray(value)) return [];
  return value.filter((row) => row && typeof row.key === 'string' && typeof row.name === 'string').slice(-100).map((row) => {
    const interrupted = ['uploading', 'queued'].includes(row.state);
    return { key: row.key, name: row.name.slice(0, 200), state: interrupted ? 'interrupted' : row.state,
      bookId: /^[A-Za-z0-9_-]+$/.test(row.bookId || '') ? row.bookId : null,
      title: String(row.title || '').slice(0, 200), time: Number(row.time) || 0,
      message: interrupted ? t('上次导入未收到完成确认。请先检查书架，再重新选择文件。') : String(row.message || '').slice(0, 500) };
  });
}
