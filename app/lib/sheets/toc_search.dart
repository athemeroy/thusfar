import '../data/library.dart';
import 'chapter_title.dart';

/// Search exactly the title the reader is allowed to see. Matching the raw
/// title first would reveal a hidden event even if its result label were safe.
List<Chapter> findTocChapters(
  List<Chapter> chapters,
  String query, {
  required int readTo,
  required bool checkPending,
}) {
  final String needle = query.trim().toLowerCase();
  if (needle.isEmpty) return const <Chapter>[];
  return <Chapter>[
    for (final Chapter chapter in chapters)
      if (safeTitle(
        chapter,
        chapter.o0 < readTo,
        checkPending: checkPending,
      ).toLowerCase().contains(needle))
        chapter,
  ];
}

/// A one-based TOC ordinal, including front matter and volume headings. Never
/// clamp a typo to another chapter or mistake a number in a title for its index.
Chapter? tocChapterAtOrdinal(List<Chapter> chapters, String input) {
  final String value = input.trim();
  if (!RegExp(r'^[0-9]+$').hasMatch(value)) return null;
  final int? ordinal = int.tryParse(value);
  if (ordinal == null || ordinal < 1 || ordinal > chapters.length) return null;
  return chapters[ordinal - 1];
}
