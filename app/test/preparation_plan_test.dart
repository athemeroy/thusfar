import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/preparation_plan.dart';
import 'package:thusfar_app/data/preparation_scope.dart';
import 'package:thusfar_app/sheets/preparation_plan_editor.dart';
import 'package:thusfar_app/sheets/preparation_progress.dart';
import 'package:thusfar_app/ui/theme.dart';

void main() {
  NativePreparationPlan plan({int cutoff = 150}) =>
      NativePreparationPlan.fromBook(<String, Object?>{
        'len': 300,
        'chapters': <Map<String, Object?>>[
          for (int i = 0; i < 3; i++)
            <String, Object?>{
              'o0': i * 100,
              'o1': (i + 1) * 100,
              'kind': 'body',
            },
        ],
      }, readingCutoff: cutoff);

  test(
    'native defaults to first chapter and discloses prefix prerequisites',
    () {
      final NativePreparationPlan first = plan();
      expect(first.scope, 'first');
      expect(first.endOffset, 100);
      final NativePreparationPlan range = first.copyWith(
        scope: 'range',
        startChapter: 2,
        endChapter: 2,
      );
      expect(range.endOffset, 300);
      expect(range.prerequisiteCharacters(100), 100);
      expect(range.pendingCharacters(100), 200);
      expect(range.toJson()['goal_start_chapter'], 2);
      expect(first.copyWith(scope: 'read').endOffset, 150);
      expect(plan(cutoff: 0).copyWith(scope: 'read').valid, isFalse);
    },
  );

  test('browser scope round trips the exact authorization boundary', () {
    expect(PreparationScope.parse('range:2:4').encoded, 'range:2:4');
    expect(PreparationScope.parse('read:1234').cutoff, 1234);
    expect(validPreparationScope('range:4:2'), isFalse);
    expect(validPreparationScope('range:-1:2'), isFalse);
    expect(validPreparationScope('read:99999999999'), isFalse);
  });

  testWidgets('planner keeps range controls reachable on a short phone', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(360, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    NativePreparationPlan selected = plan();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (BuildContext context, StateSetter redraw) =>
                SingleChildScrollView(
                  child: PreparationPlanEditor(
                    plan: selected,
                    frontier: 0,
                    onChanged: (NativePreparationPlan next) =>
                        redraw(() => selected = next),
                  ),
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择章节'));
    await tester.pumpAndSettle();
    expect(find.text('从哪章开始'), findsOneWidget);
    expect(find.text('整理到'), findsOneWidget);
    expect(find.text('片段大小与缓存复用'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'progress separates selected goal from book coverage and classification',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: SingleChildScrollView(
              child: PreparationProgress(
                status: ProcessStatus(<String, Object?>{
                  'state': 'paused',
                  'done': 1,
                  'total': 3,
                  'frontier': 100,
                  'plan': <String, Object?>{
                    'state': 'complete',
                    'target_segments': 1,
                    'completed_segments': 1,
                    'classification_source': 'local',
                  },
                }),
                plan: plan(),
                latest: null,
                biographies: 2,
              ),
            ),
          ),
        ),
      );
      expect(find.text('本次目标 · 范围已完成'), findsOneWidget);
      expect(find.textContaining('全书已整理 1 / 3 段'), findsOneWidget);
      expect(find.textContaining('本次采用本地章节分类'), findsNothing);
      expect(find.textContaining('2 篇人物小传'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
