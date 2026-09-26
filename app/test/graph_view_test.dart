import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/sheets/graph_view.dart';
import 'package:thusfar_app/sheets/people_sheet.dart';
import 'package:thusfar_app/sheets/sheet_host.dart';
import 'package:thusfar_app/ui/theme.dart';
import 'package:thusfar_core/thusfar_core.dart';

import 'support/graph_fixture.dart';

void main() {
  late GraphFixture fixture;
  late ScrollController scroll;
  setUp(() {
    fixture = GraphFixture();
    scroll = ScrollController();
  });
  tearDown(() {
    scroll.dispose();
    fixture.dispose();
  });

  Future<void> open(
    WidgetTester tester, {
    Size size = const Size(430, 1000),
    double scale = 1,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: SheetFrame(
            scroll: scroll,
            root: GraphPage(link: fixture.link),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void expectVisibleRole(WidgetTester tester, String id, String role) {
    final Finder finder = find.byKey(ValueKey<String>('relation-role-0-$id'));
    expect(finder, findsOneWidget);
    final Text text = tester.widget<Text>(finder);
    expect(text.data, role);
    expect(text.maxLines, isNull);
    expect(text.overflow, isNot(TextOverflow.ellipsis));
    final RenderParagraph paragraph = tester.renderObject<RenderParagraph>(
      finder,
    );
    expect(paragraph.didExceedMaxLines, isFalse);
    final Rect label = tester.getRect(
      find.byKey(const ValueKey<String>('relation-label-0')),
    );
    final Rect roleBox = tester.getRect(finder);
    expect(label.contains(roleBox.topLeft), isTrue);
    expect(label.contains(roleBox.bottomRight - const Offset(.1, .1)), isTrue);
  }

  void expectEndedVisible(WidgetTester tester) {
    final Finder finder = find.byKey(
      const ValueKey<String>('relation-ended-0'),
    );
    expect(tester.widget<Text>(finder).data, '已结束');
    final Rect label = tester.getRect(
      find.byKey(const ValueKey<String>('relation-label-0')),
    );
    final Rect status = tester.getRect(finder);
    expect(label.contains(status.topLeft), isTrue);
    expect(label.contains(status.bottomRight - const Offset(.1, .1)), isTrue);
  }

  Slider slider(WidgetTester tester) =>
      tester.widget<Slider>(find.byKey(const ValueKey<String>('graph-replay')));

  for (final bool largeText in <bool>[false, true]) {
    testWidgets(
      'real people drawer expands graph into the physical viewport${largeText ? ' with large text' : ''}',
      (WidgetTester tester) async {
        final Size size = largeText
            ? const Size(320, 740)
            : const Size(393, 851);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        if (largeText) {
          fixture.dispose();
          fixture = GraphFixture(longNames: true);
        }
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(largeText ? 1.8 : 1)),
              child: child!,
            ),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () => openSheet<void>(
                      context,
                      PeoplePage(link: fixture.link),
                    ),
                    child: const Text('人物'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('人物'));
        await tester.pumpAndSettle();
        final Rect collapsed = tester.getRect(find.byType(SheetFrame));
        expect(collapsed.height, lessThan(size.height * .5));
        final Rect tabs = tester.getRect(find.byType(Segmented));
        for (final String label in <String>['本页', '本章', '全部', '关系图']) {
          final Rect text = tester.getRect(find.text(label));
          expect(tabs.contains(text.topLeft), isTrue);
          expect(
            tabs.contains(text.bottomRight - const Offset(.1, .1)),
            isTrue,
            reason:
                'Wrapped large-text tabs must stay within their measured header',
          );
          expect(collapsed.contains(text.bottomRight), isTrue);
        }
        await tester.tap(find.text('关系图'));
        await tester.pumpAndSettle();
        final Rect drawer = tester.getRect(find.byType(SheetFrame));
        final Rect screen = Rect.fromLTRB(0, 24, size.width, size.height - 24);
        final Rect graph = tester.getRect(
          find.byKey(const ValueKey<String>('graph-viewport')),
        );
        final Rect label = tester.getRect(
          find.byKey(const ValueKey<String>('relation-label-0')),
        );
        expect(drawer.height, greaterThan(size.height * .85));
        expect(screen.contains(graph.topLeft), isTrue);
        expect(
          screen.contains(graph.bottomRight - const Offset(.1, .1)),
          isTrue,
          reason:
              'The graph viewport must fit on the phone, not below the collapsed drawer',
        );
        expect(graph.intersect(screen).contains(label.topLeft), isTrue);
        expect(
          graph.intersect(screen).contains(label.bottomRight),
          isTrue,
          reason:
              'A complete relationship card must physically be visible after the actual people-to-graph route',
        );
        for (final String control in <String>['缩小关系图', '放大关系图', '重置视图']) {
          final Rect button = tester.getRect(find.byTooltip(control));
          expect(screen.contains(button.topLeft), isTrue);
          expect(screen.contains(button.bottomRight), isTrue);
        }
        if (!largeText) {
          final Rect replay = tester.getRect(
            find.byKey(const ValueKey<String>('graph-replay')),
          );
          expect(screen.contains(replay.bottomRight), isTrue);
        }
        await tester.tap(
          find.byKey(const ValueKey<String>('relation-label-0')),
        );
        await tester.pumpAndSettle();
        expect(find.byType(RelationDetailPage), findsOneWidget);
        await tester.tap(find.byTooltip('返回上一层'));
        await tester.pumpAndSettle();
        expect(find.byType(GraphPage), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  test(
    'relationship wording preserves both roles and selected-person direction',
    () {
      final World world = fixture.data.world(1000);
      expect(
        relationLabel(world, world.rels.single),
        '林先生是小明的前导师\n小明是林先生的前学生\n已结束',
      );
      expect(
        relationLabel(world, world.rels.single, selected: 'P1'),
        '小明是林先生的前学生\n林先生是小明的前导师\n已结束',
      );
      expect(
        relationLabel(world, world.rels.single, selected: 'P2'),
        '林先生是小明的前导师\n小明是林先生的前学生\n已结束',
      );
    },
  );

  testWidgets(
    'two people show an accessible relation label immediately and open complete detail',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await open(tester);
      expect(find.byType(RelationGraph), findsOneWidget);
      expectVisibleRole(tester, 'P1', '前导师');
      expectVisibleRole(tester, 'P2', '前学生');
      expectEndedVisible(tester);
      expect(
        find.bySemanticsLabel(RegExp('林先生是小明的前导师.*', dotAll: true)),
        findsWidgets,
      );
      await tester.tap(find.byKey(const ValueKey<String>('relation-label-0')));
      await tester.pumpAndSettle();
      expect(find.byType(RelationDetailPage), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is SelectableText &&
              widget.data == GraphFixture.description,
        ),
        findsOneWidget,
      );
      expect(find.text('这段关系截至此页已结束。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'selection reverses the sentence perspective without changing its meaning or node center',
    (WidgetTester tester) async {
      await open(tester);
      final Rect before = tester.getRect(
        find.byKey(const ValueKey<String>('graph-circle-P1')),
      );
      await tester.tap(find.byKey(const ValueKey<String>('graph-person-P1')));
      await tester.pumpAndSettle();
      expectVisibleRole(tester, 'P1', '前导师');
      expectVisibleRole(tester, 'P2', '前学生');
      expectEndedVisible(tester);
      final Rect relation = tester.getRect(
        find.byKey(const ValueKey<String>('relation-label-0')),
      );
      for (final String id in <String>['P1', 'P2']) {
        final Rect node = tester.getRect(
          find.byKey(ValueKey<String>('graph-person-$id')),
        );
        expect(
          relation.overlaps(node),
          isFalse,
          reason:
              'A readable role card must not cover the $id node or name: label=$relation, node=$node, graph=${tester.getSize(find.byType(RelationGraph))}',
        );
      }
      expect(
        tester
            .getTopLeft(
              find.byKey(const ValueKey<String>('relation-role-0-P2')),
            )
            .dy,
        lessThan(
          tester
              .getTopLeft(
                find.byKey(const ValueKey<String>('relation-role-0-P1')),
              )
              .dy,
        ),
      );
      final Rect circle = tester.getRect(
        find.byKey(const ValueKey<String>('graph-circle-P1')),
      );
      final Rect node = tester.getRect(
        find.byKey(const ValueKey<String>('graph-person-P1')),
      );
      expect(circle.center.dx, closeTo(node.center.dx, .001));
      expect(circle.center, before.center);
      expect(find.text('打开人物卡'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('zoom controls enlarge meaningful text and reset the view', (
    WidgetTester tester,
  ) async {
    await open(tester);
    InteractiveViewer viewport() => tester.widget<InteractiveViewer>(
      find.byKey(const ValueKey<String>('graph-viewport')),
    );
    expect(viewport().transformationController!.value.getMaxScaleOnAxis(), 1);
    await tester.tap(find.byTooltip('放大关系图'));
    await tester.pump();
    expect(
      viewport().transformationController!.value.getMaxScaleOnAxis(),
      closeTo(1.3, .0001),
    );
    expect(
      find.byKey(const ValueKey<String>('relation-label-0')),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('重置视图'));
    await tester.pump();
    expect(viewport().transformationController!.value.getMaxScaleOnAxis(), 1);
    await tester.tap(find.byTooltip('缩小关系图'));
    await tester.pump();
    expect(
      viewport().transformationController!.value.getMaxScaleOnAxis(),
      closeTo(1 / 1.3, .0001),
    );
    for (int i = 0; i < 8; i++) {
      await tester.tap(find.byTooltip('缩小关系图'));
      await tester.pump();
    }
    expect(viewport().transformationController!.value.getMaxScaleOnAxis(), .3);
    await tester.tap(find.byTooltip('重置视图'));
    await tester.pump();
    expect(viewport().transformationController!.value.getMaxScaleOnAxis(), 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'replay updates both header and roles and clearly returns to present before a person card',
    (WidgetTester tester) async {
      await open(tester);
      slider(tester).onChanged!(.4);
      await tester.pumpAndSettle();
      expect(find.text('截至第 ${fixture.link.pageNo(399)} 页'), findsOneWidget);
      for (final double value in <double>[0, .4, 1]) {
        final int position = (value * fixture.controller.cutoff).round();
        expect(
          slider(tester).semanticFormatterCallback!(value),
          '第 ${fixture.link.pageNo(position > 0 ? position - 1 : 0)} 页',
        );
      }
      expectVisibleRole(tester, 'P1', '导师');
      expectVisibleRole(tester, 'P2', '学生');
      expect(
        find.byKey(const ValueKey<String>('relation-ended-0')),
        findsNothing,
      );
      expect(find.textContaining('前导师'), findsNothing);
      await tester.tap(find.byKey(const ValueKey<String>('graph-person-P1')));
      await tester.pumpAndSettle();
      expect(find.text('回到当前页看人物卡'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<String>('relation-label-0')));
      await tester.pumpAndSettle();
      expect(find.text('截至第 ${fixture.link.pageNo(399)} 页'), findsOneWidget);
      expect(find.text('林先生是小明的导师'), findsOneWidget);
      expect(find.textContaining('前导师'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('play pause resume and slider cancel one replay timer', (
    WidgetTester tester,
  ) async {
    await open(tester);
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('graph-play')),
    );
    await tester.tap(find.byKey(const ValueKey<String>('graph-play')));
    await tester.pump(const Duration(milliseconds: 200));
    final double progressed = slider(tester).value;
    expect(progressed, greaterThan(0));
    await tester.tap(find.byKey(const ValueKey<String>('graph-play')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(slider(tester).value, progressed);
    await tester.tap(find.byKey(const ValueKey<String>('graph-play')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(slider(tester).value, greaterThan(progressed));
    slider(tester).onChanged!(.4);
    await tester.pump(const Duration(milliseconds: 500));
    expect(slider(tester).value, .4);
    await tester.tap(find.byKey(const ValueKey<String>('graph-play')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reader rewind and durable graph changes refresh visible relationships',
    (WidgetTester tester) async {
      await open(tester);
      fixture.setCutoff(400);
      await tester.pumpAndSettle();
      expectVisibleRole(tester, 'P1', '导师');
      expectVisibleRole(tester, 'P2', '学生');
      expect(
        find.byKey(const ValueKey<String>('relation-ended-0')),
        findsNothing,
      );
      fixture.records.insert(3, <String, Object?>{
        't': 'rel',
        'a': 'P1',
        'b': 'P2',
        'a_is': '朋友',
        'b_is': '朋友',
        'p': 300,
      });
      fixture.refresh();
      await tester.pumpAndSettle();
      expectVisibleRole(tester, 'P1', '朋友');
      expectVisibleRole(tester, 'P2', '朋友');
      expect(find.text('截至第 ${fixture.link.pageNo(399)} 页'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'long names and roles remain readable at narrow width and large text scale',
    (WidgetTester tester) async {
      fixture.dispose();
      fixture = GraphFixture(longNames: true);
      await open(tester, size: const Size(320, 900), scale: 1.8);
      expectVisibleRole(tester, 'P1', '曾经共同研究草药医理的导师');
      expectVisibleRole(tester, 'P2', '后来离开故乡继续独立求学的学生');
      expectEndedVisible(tester);
      final Rect relation = tester.getRect(
        find.byKey(const ValueKey<String>('relation-label-0')),
      );
      for (final String id in <String>['P1', 'P2']) {
        final Rect node = tester.getRect(
          find.byKey(ValueKey<String>('graph-person-$id')),
        );
        expect(
          relation.overlaps(node),
          isFalse,
          reason:
              'A readable role card must not cover the $id node or name: label=$relation, node=$node, graph=${tester.getSize(find.byType(RelationGraph))}',
        );
      }
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey<String>('relation-name-0-P1')),
            )
            .data,
        '来自远方的林先生',
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey<String>('relation-label-0')));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (Widget widget) =>
              widget is SelectableText &&
              (widget.data?.contains('曾经共同研究草药医理的导师') ?? false),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
