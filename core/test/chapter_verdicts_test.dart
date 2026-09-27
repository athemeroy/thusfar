import 'package:test/test.dart';
import 'package:thusfar_core/chapter_verdicts.dart';

void main() {
  Json book([Object? verdict, String? source]) => <String, Object?>{
    'chapters': <Json>[
      <String, Object?>{
        'title': '第2章 旧城',
        'o0': 0,
        'o1': 8,
        if (verdict != null) 'spoil': verdict,
        if (source != null) 'spoilSource': source,
      },
    ],
  };

  test('model verdict travels to an older copy without changing text', () {
    expect(
      sameChapterContent(book()['chapters'], book(true, 'model')['chapters']),
      isTrue,
    );
    final Json merged = mergeChapterVerdicts(book(), book(true, 'model'));
    expect(
      (merged['chapters'] as List<Object?>).single,
      containsPair('spoil', true),
    );
    expect(
      (merged['chapters'] as List<Object?>).single,
      containsPair('spoilSource', 'model'),
    );
  });

  test('legacy blanket-hidden pending verdict is discarded', () {
    final Json merged = mergeChapterVerdicts(
      book(true),
      book(),
      localCheckPending: true,
    );
    expect(
      (merged['chapters'] as List<Object?>).single,
      isNot(contains('spoil')),
    );
  });

  test('different verified judgments are a conflict', () {
    expect(
      () => mergeChapterVerdicts(book(false, 'model'), book(true, 'model')),
      throwsA(isA<ChapterVerdictConflict>()),
    );
  });
}
