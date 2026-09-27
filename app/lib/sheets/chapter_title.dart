import '../data/library.dart';

final RegExp _chapterNumber = RegExp(
  r'^(第\s*[0-9零一二三四五六七八九十百千]+\s*[部章回卷节篇集]|(?:chapter|part|book)\s+[0-9ivxlcdm]+)',
  caseSensitive: false,
);

/// Show an unread title only after it has been classified as safe.
/// An absent or malformed verdict stays hidden until the title is checked.
String safeTitle(Chapter chapter, bool read) {
  if (read || chapter.raw['spoil'] == false) return chapter.title;
  final RegExpMatch? number = _chapterNumber.firstMatch(chapter.title.trim());
  return number?.group(0) ?? '第 ${chapter.index + 1} 节';
}
