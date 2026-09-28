/// Browser reading boundaries that need no DOM, so they run in VM tests.
library;

import 'package:thusfar_core/title_spoilers.dart';

final RegExp _chapterNumber = RegExp(
  r'^(第\s*[0-9零一二三四五六七八九十百千]+\s*[部章回卷节篇集]|(?:chapter|part|book)\s+[0-9ivxlcdm]+)',
  caseSensitive: false,
);

int _offset(Object? value, [int fallback = 0]) =>
    (value as num?)?.toInt() ?? fallback;

/// Native graph positions are segment ends, so a record at the reader's
/// exclusive text end is already known. Without a page boundary (the shelf)
/// every record in the current chapter stays hidden unless revealed.
int nativeCutoff(
  Map<String, Object?> chapter, {
  int? pageEnd,
  bool revealCurrentChapter = false,
}) {
  final int start = _offset(chapter['o0']);
  final int end = _offset(chapter['o1'], start);
  if (pageEnd != null) return pageEnd.clamp(start, end);
  return revealCurrentChapter ? end : start - 1;
}

/// At a shared chapter boundary a record belongs to the chapter that just
/// ended, not to the next title.
int nativeChapterAt(List<Map<String, Object?>> chapters, int position) {
  int chapter = 0;
  for (int i = 1; i < chapters.length; i++) {
    if (_offset(chapters[i]['o0']) < position) {
      chapter = i;
    } else {
      break;
    }
  }
  return chapter;
}

/// Records known at [cutoff], in log order.
Iterable<Map<String, Object?>> visibleNativeRecords(
  List<Map<String, Object?>> log,
  int cutoff,
) => log.where((Map<String, Object?> row) {
  final int? position = (row['p'] as num?)?.toInt();
  return position != null && position >= 0 && position <= cutoff;
});

/// A chapter title as the reader may see it: chapters up to [readChapter]
/// are shown in full; a later one is reduced to its number only when the
/// title itself gives something away.
String webChapterTitle(
  List<Map<String, Object?>> chapters,
  int index,
  int readChapter, {
  bool checkPending = false,
}) {
  if (index < 0 || index >= chapters.length) return '第 ${index + 1} 章';
  final Map<String, Object?> chapter = chapters[index];
  final String title = '${chapter['title'] ?? '第 ${index + 1} 章'}';
  if (index <= readChapter ||
      !titleSpoils(
        chapter['spoil'],
        title,
        checkPending: checkPending,
        checkedByModel: chapter['spoilSource'] == 'model',
      )) {
    return title;
  }
  return _chapterNumber.firstMatch(title.trim())?.group(0) ??
      '第 ${index + 1} 节';
}
