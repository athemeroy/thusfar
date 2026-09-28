import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/web/reading_boundary.dart';
import 'package:thusfar_core/thusfar_core.dart' as knowledge;

typedef Json = Map<String, Object?>;

void main() {
  // Adjacent chapters share their boundary: chapter 1 ends where 2 begins.
  final List<Json> chapters = <Json>[
    <String, Object?>{'title': '第1章 林间', 'o0': 0, 'o1': 100},
    <String, Object?>{'title': '第2章 旧城', 'o0': 100, 'o1': 200},
    <String, Object?>{
      'title': '第3章 师父身亡',
      'o0': 200,
      'o1': 300,
      'spoil': true,
      'spoilSource': 'model',
    },
    <String, Object?>{'title': '第4章 夜雨', 'o0': 300, 'o1': 400},
  ];
  final List<Json> log = <Json>[
    <String, Object?>{'t': 'person', 'id': 'P1', 'name': '林远', 'p': 60},
    <String, Object?>{'t': 'profile', 'id': 'P1', 'p': 200, 'tagline': '剑客'},
    <String, Object?>{'t': 'profile', 'id': 'P1', 'p': 201, 'tagline': '孤儿'},
  ];

  test('a record exactly at the next chapter start is known on the page '
      'that ends there, and belongs to the chapter that just ended', () {
    final int cutoff = nativeCutoff(chapters[1], pageEnd: 200);
    expect(cutoff, 200);
    expect(visibleNativeRecords(log, cutoff).map((Json r) => r['p']), <int>[
      60,
      200,
    ]);
    expect(nativeChapterAt(chapters, 200), 1);
    expect(nativeChapterAt(chapters, 201), 2);
    // The fold used for the person card applies the same inclusive cutoff.
    expect(knowledge.fold(log, cutoff).people['P1']?['tagline'], '剑客');
    // Knowing the record does not unlock the next chapter's spoiler title.
    expect(webChapterTitle(chapters, 2, 1), '第3章');
  });

  test('one page earlier, the boundary record is still hidden', () {
    final int cutoff = nativeCutoff(chapters[1], pageEnd: 199);
    expect(visibleNativeRecords(log, cutoff).map((Json r) => r['p']), <int>[
      60,
    ]);
    final Json? person = knowledge.fold(log, cutoff).people['P1'];
    expect(person?['name'], '林远');
    expect(person?['tagline'], isNot('剑客'));
  });

  test('page ends outside the current chapter are clamped to it', () {
    expect(nativeCutoff(chapters[1], pageEnd: 250), 200);
    expect(nativeCutoff(chapters[1], pageEnd: 20), 100);
  });

  test('without a page boundary the current chapter stays hidden until '
      'revealed', () {
    expect(nativeCutoff(chapters[1]), 99);
    expect(nativeCutoff(chapters[1], revealCurrentChapter: true), 200);
  });

  test('records without a valid position are never shown', () {
    final List<Json> rows = <Json>[
      <String, Object?>{'t': 'profile', 'p': -1},
      <String, Object?>{'t': 'profile'},
      <String, Object?>{'t': 'profile', 'p': 0},
    ];
    expect(visibleNativeRecords(rows, 10).length, 1);
  });

  test('unread titles are masked one by one', () {
    expect(webChapterTitle(chapters, 1, 0), '第2章 旧城');
    expect(webChapterTitle(chapters, 2, 0), '第3章');
    expect(webChapterTitle(chapters, 2, 2), '第3章 师父身亡');
    expect(webChapterTitle(chapters, 3, 0), '第4章 夜雨');
    expect(webChapterTitle(chapters, 9, 0), '第 10 章');
    // A legacy blanket verdict from an unfinished check falls back to the
    // title's own words.
    final List<Json> legacy = <Json>[
      chapters[0],
      <String, Object?>{'title': '第2章 旧城', 'spoil': true},
      <String, Object?>{'title': '第3章 大结局', 'spoil': true},
    ];
    expect(webChapterTitle(legacy, 1, 0, checkPending: true), '第2章 旧城');
    expect(webChapterTitle(legacy, 2, 0, checkPending: true), '第3章');
    expect(webChapterTitle(legacy, 1, 0), '第2章');
  });
}
