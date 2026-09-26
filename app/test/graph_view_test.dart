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
    String? focus,
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
            root: GraphPage(link: fixture.link, focus: focus),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The edge label shows one role: who the other person is to the selected
  /// one. It must be complete (no ellipsis) and sit inside its pill.
  void expectVisibleRole(WidgetTester tester, String role) {
    final Finder finder = find.byKey(const ValueKey<String>('relation-role-0'));
    expect(finder, findsOneWidget);
    expect(tester.widget<Text>(finder).data, role);
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

  bool endedAnnounced() => find
      .bySemanticsLabel(RegExp('已结束，查看关系详情'))
      .evaluate()
      .isNotEmpty;

  Slider slider(WidgetTester tester) =>
      tester.widget<Slider>(find.byKey(const ValueKey<String>('graph-replay')));

  void addThirdPerson() {
    fixture.records.add(<String, Object?>{
      't': 'person',
      'id': 'P3',
      'name': '旁观者',
      'p': 0,
    });
    fixture.records.sort(
      (Json left, Json right) =>
          (left['p']! as int).compareTo(right['p']! as int),
    );
    fixture.refresh();
  }

  for (final bool largeText in <bool>[false, true]) {
    testWidgets(
      'few people show a full relationship card${largeText ? ' with large text' : ''}',
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
        final Finder cardFinder = find.byKey(
          const ValueKey<String>('relation-card-0'),
        );
        await tester.ensureVisible(cardFinder);
        await tester.pumpAndSettle();
        final Rect card = tester.getRect(cardFinder);
        final Rect screenTolerance = screen.inflate(1);
        expect(drawer.height, greaterThan(size.height * .85));
        expect(
          screenTolerance.contains(card.topLeft) &&
              screenTolerance.contains(card.bottomRight - const Offset(.1, .1)),
          isTrue,
          reason:
              'The complete sparse relationship card must fit the foldable cover viewport: screen=$screen card=$card drawer=$drawer',
        );
        expect(find.byType(RelationGraph), findsNothing);
        expect(find.text('已结束'), findsOneWidget);
        await tester.tap(cardFinder);
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
    'two people show a readable relationship list and open complete detail',
    (WidgetTester tester) async {
      final SemanticsHandle semantics = tester.ensureSemantics();
      await open(tester);
      expect(find.byType(RelationGraph), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('relation-card-0')),
        findsOneWidget,
      );
      expect(find.text('前导师'), findsOneWidget);
      expect(find.text('前学生'), findsOneWidget);
      expect(find.text('已结束'), findsOneWidget);
      expect(
        find.bySemanticsLabel(RegExp('林先生是小明的前导师.*', dotAll: true)),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey<String>('relation-card-0')));
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

  testWidgets('two people without recorded edges get a clear empty state', (
    WidgetTester tester,
  ) async {
    fixture.records.removeWhere((Json row) => row['t'] == 'rel');
    fixture.refresh();
    await open(tester);
    expect(find.byType(RelationGraph), findsNothing);
    expect(find.text('截至此页尚未记录人物关系'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('relation-card-0')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'selection reverses the sentence perspective without changing its meaning or node center',
    (WidgetTester tester) async {
      addThirdPerson();
      await open(tester);
      final Rect before = tester.getRect(
        find.byKey(const ValueKey<String>('graph-circle-P1')),
      );
      await tester.tap(find.byKey(const ValueKey<String>('graph-person-P1')));
      await tester.pumpAndSettle();
      // P1 is selected: the label says who P2 is to P1.
      expectVisibleRole(tester, '前学生');
      expect(endedAnnounced(), isTrue);
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
    addThirdPerson();
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

  testWidgets('bounded graph canvas keeps relationships reachable while panning', (
    WidgetTester tester,
  ) async {
    for (int i = 3; i <= 8; i++) {
      fixture.records.add(<String, Object?>{
        't': 'person',
        'id': 'P$i',
        'name': '人物$i',
        'p': 0,
      });
      fixture.records.add(<String, Object?>{
        't': 'rel',
        'a': 'P1',
        'b': 'P$i',
        'a_is': '同行者$i',
        'b_is': '熟人$i',
        'desc': '图谱边界测试关系$i',
        'p': 20,
      });
    }
    fixture.records.sort(
      (Json left, Json right) =>
          (left['p']! as int).compareTo(right['p']! as int),
    );
    fixture.refresh();
    expect(
      fixture.data
          .world(1000)
          .rels
          .where((Json row) => row['a'] == 'P1' || row['b'] == 'P1')
          .length,
      greaterThan(5),
      reason:
          'The focused test graph must contain enough edges to pan in both axes.',
    );
    await open(tester, focus: 'P1');

    final Finder viewportFinder = find.byKey(
      const ValueKey<String>('graph-viewport'),
    );
    InteractiveViewer viewport() =>
        tester.widget<InteractiveViewer>(viewportFinder);
    Finder cards() => find.byWidgetPredicate(
      (Widget widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('relation-label-'),
    );
    bool hasCompleteCard() {
      final Rect bounds = tester.getRect(viewportFinder);
      return cards().evaluate().any((Element element) {
        final Rect card = tester.getRect(find.byWidget(element.widget));
        return bounds.contains(card.topLeft) &&
            bounds.contains(card.bottomRight - const Offset(.1, .1));
      });
    }

    expect(cards().evaluate().length, greaterThan(5));
    expect(hasCompleteCard(), isTrue);
    final Rect bounds = tester.getRect(viewportFinder);
    final Offset start = Offset(bounds.left + 8, bounds.center.dy);
    await tester.dragFrom(start, const Offset(1200, 0));
    await tester.pumpAndSettle();
    expect(
      hasCompleteCard(),
      isTrue,
      reason: 'A bounded horizontal pan must not lose every relationship card.',
    );

    final double beforeVerticalPan =
        viewport().transformationController!.value.storage[13];
    await tester.dragFrom(
      Offset(bounds.left + 8, bounds.bottom - 8),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(
      viewport().transformationController!.value.storage[13],
      isNot(beforeVerticalPan),
      reason:
          'A tall focused graph must be vertically pannable inside its sheet.',
    );
    final List<Rect> cardsAfterVerticalPan = cards()
        .evaluate()
        .map((Element element) => tester.getRect(find.byWidget(element.widget)))
        .toList();
    final Rect viewportAfterVerticalPan = tester.getRect(viewportFinder);
    expect(
      hasCompleteCard(),
      isTrue,
      reason:
          'At least one relation card must stay visible after a bounded vertical pan: viewport=$viewportAfterVerticalPan, cards=$cardsAfterVerticalPan, transform=${viewport().transformationController!.value.storage}',
    );

    await tester.tap(find.byTooltip('重置视图'));
    await tester.pumpAndSettle();
    expect(viewport().transformationController!.value.getMaxScaleOnAxis(), 1);
    expect(hasCompleteCard(), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'replay updates both header and roles and clearly returns to present before a person card',
    (WidgetTester tester) async {
      addThirdPerson();
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
      expectVisibleRole(tester, '学生');
      expect(endedAnnounced(), isFalse);
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
      addThirdPerson();
      await open(tester);
      fixture.setCutoff(400);
      await tester.pumpAndSettle();
      expectVisibleRole(tester, '学生');
      expect(endedAnnounced(), isFalse);
      fixture.records.insert(3, <String, Object?>{
        't': 'rel',
        'a': 'P1',
        'b': 'P2',
        'a_is': '朋友',
        'b_is': '朋友',
        'p': 300,
      });
      fixture.records.sort(
        (Json left, Json right) =>
            (left['p']! as int).compareTo(right['p']! as int),
      );
      fixture.refresh();
      await tester.pumpAndSettle();
      expectVisibleRole(tester, '朋友');
      expect(find.text('截至第 ${fixture.link.pageNo(399)} 页'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'long names and roles remain readable in the sparse list at large text scale',
    (WidgetTester tester) async {
      fixture.dispose();
      fixture = GraphFixture(longNames: true);
      await open(tester, size: const Size(320, 900), scale: 1.8);
      expect(find.byType(RelationGraph), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('relation-card-0')),
        findsOneWidget,
      );
      expect(find.text('来自远方的林先生'), findsOneWidget);
      expect(find.text('正在学习医术的小明'), findsOneWidget);
      expect(find.text('曾经共同研究草药医理的导师'), findsOneWidget);
      expect(find.text('后来离开故乡继续独立求学的学生'), findsOneWidget);
      expect(find.text('已结束'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey<String>('relation-card-0')));
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
