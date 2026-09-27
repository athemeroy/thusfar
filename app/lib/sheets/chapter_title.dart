import '../data/library.dart';
import 'package:thusfar_core/title_spoilers.dart';

final RegExp _chapterNumber = RegExp(
  r'^(第\s*[0-9零一二三四五六七八九十百千]+\s*[部章回卷节篇集]|(?:chapter|part|book)\s+[0-9ivxlcdm]+)',
  caseSensitive: false,
);

/// Conceal model-confirmed spoilers and obvious local fallback spoilers.
String safeTitle(Chapter chapter, bool read, {bool checkPending = false}) {
  if (read ||
      !titleSpoils(
        chapter.raw['spoil'],
        chapter.title,
        checkPending: checkPending,
        checkedByModel: chapter.raw['spoilSource'] == 'model',
      )) {
    return chapter.title;
  }
  final RegExpMatch? number = _chapterNumber.firstMatch(chapter.title.trim());
  return number?.group(0) ?? '第 ${chapter.index + 1} 节';
}
