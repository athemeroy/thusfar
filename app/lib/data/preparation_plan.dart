/// Pure range planning shared by the installed preparation UI and tests.
/// It never reads a title or changes the immutable extraction geometry.
library;

typedef PlanJson = Map<String, Object?>;

class PreparationChapter {
  const PreparationChapter(this.index, this.start, this.end);
  final int index;
  final int start;
  final int end;
}

class NativePreparationPlan {
  NativePreparationPlan({
    required this.chapters,
    required this.length,
    required this.readingCutoff,
    this.scope = 'first',
    int? startChapter,
    int? endChapter,
  }) : startChapter =
           startChapter ?? (chapters.isEmpty ? 0 : chapters.first.index),
       endChapter = endChapter ?? (chapters.isEmpty ? 0 : chapters.first.index);

  factory NativePreparationPlan.fromBook(
    PlanJson book, {
    required int readingCutoff,
    PlanJson? saved,
  }) {
    final List<PreparationChapter> chapters = <PreparationChapter>[];
    final Object? rows = book['chapters'];
    if (rows is List) {
      for (int i = 0; i < rows.length; i++) {
        final Object? raw = rows[i];
        if (raw is! PlanJson || (raw['kind'] ?? 'body') != 'body') continue;
        final int start = (raw['o0'] as num?)?.toInt() ?? 0;
        final int end = (raw['o1'] as num?)?.toInt() ?? start;
        if (end > start) chapters.add(PreparationChapter(i, start, end));
      }
    }
    final int length =
        (book['len'] as num?)?.toInt() ??
        (chapters.isEmpty ? 0 : chapters.last.end);
    return NativePreparationPlan(
      chapters: chapters,
      length: length,
      readingCutoff: readingCutoff.clamp(0, length),
      scope:
          const <String>{
            'first',
            'read',
            'range',
            'all',
          }.contains(saved?['scope'])
          ? saved!['scope']! as String
          : 'first',
      startChapter: (saved?['goal_start_chapter'] as num?)?.toInt(),
      endChapter: (saved?['goal_end_chapter'] as num?)?.toInt(),
    );
  }

  final List<PreparationChapter> chapters;
  final int length;
  final int readingCutoff;
  final String scope;
  final int startChapter;
  final int endChapter;

  NativePreparationPlan copyWith({
    String? scope,
    int? startChapter,
    int? endChapter,
  }) => NativePreparationPlan(
    chapters: chapters,
    length: length,
    readingCutoff: readingCutoff,
    scope: scope ?? this.scope,
    startChapter: startChapter ?? this.startChapter,
    endChapter: endChapter ?? this.endChapter,
  );

  PreparationChapter? get first => chapters.isEmpty ? null : chapters.first;
  PreparationChapter? chapter(int index) {
    for (final PreparationChapter chapter in chapters) {
      if (chapter.index == index) return chapter;
    }
    return null;
  }

  int get endOffset => switch (scope) {
    'all' => length,
    'read' => readingCutoff,
    'range' => chapter(endChapter)?.end ?? 0,
    _ => first?.end ?? 0,
  };
  bool get valid =>
      endOffset > 0 &&
      (scope != 'range' ||
          (chapter(startChapter) != null &&
              chapter(endChapter) != null &&
              startChapter <= endChapter));
  int pendingCharacters(int frontier) =>
      (endOffset - frontier).clamp(0, length);
  int prerequisiteCharacters(int frontier) => scope == 'range'
      ? ((chapter(startChapter)?.start ?? 0) - frontier).clamp(0, length)
      : 0;
  String get label => switch (scope) {
    'all' => '整本书',
    'read' => '到当前阅读位置',
    'range' => '第 ${startChapter + 1}–${endChapter + 1} 章',
    _ => '首章试整理',
  };
  PlanJson toJson() => <String, Object?>{
    'version': 1,
    'scope': scope,
    'end_offset': endOffset,
    'goal_start_chapter': scope == 'range' ? startChapter : (first?.index ?? 0),
    'goal_end_chapter': scope == 'range'
        ? endChapter
        : chapters
              .where((PreparationChapter c) => c.end <= endOffset)
              .fold<int>(
                first?.index ?? 0,
                (int _, PreparationChapter c) => c.index,
              ),
  };
}
