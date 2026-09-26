// Real-font review artifacts: flutter test test/graph_screens_test.dart --update-goldens
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/seen.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/reader_controller.dart';
import 'package:thusfar_app/sheets/common.dart';
import 'package:thusfar_app/sheets/graph_view.dart';
import 'package:thusfar_app/sheets/people_sheet.dart';
import 'package:thusfar_app/sheets/sheet_host.dart';
import 'package:thusfar_app/ui/theme.dart';

import 'support/graph_fixture.dart';

Future<void> _font(String family, String path) async {
  await (FontLoader(family)..addFont(
        Future<ByteData>.value(
          ByteData.sublistView(File(path).readAsBytesSync()),
        ),
      ))
      .load();
}

void main() {
  setUpAll(() async {
    final String sdk =
        Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/.local/share/flutter';
    await _font(
      'MaterialIcons',
      '$sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    await _font(
      'Roboto',
      Platform.environment['THUSFAR_TEST_SANS_FONT'] ??
          '${Platform.environment['HOME']}/.local/share/fonts/NotoSansSC.ttf',
    );
    await _font('NotoSerifSC', 'assets/fonts/NotoSerifSC-Regular.otf');
    await _font('ZCOOLXiaoWei', 'assets/fonts/ZCOOLXiaoWei-Regular.ttf');
  });

  for (final bool narrow in <bool>[false, true]) {
    testWidgets(narrow ? 'graph narrow large text' : 'graph roles and replay', (
      WidgetTester tester,
    ) async {
      final GraphFixture fixture = GraphFixture(longNames: narrow);
      final ScrollController scroll = ScrollController();
      if (!narrow) {
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
      if (narrow) tester.view.devicePixelRatio = 1;
      await tester.binding.setSurfaceSize(
        narrow ? const Size(320, 740) : const Size(430, 1000),
      );
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.binding.setSurfaceSize(null);
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio()
          ..resetPadding()
          ..resetViewPadding();
        scroll.dispose();
        fixture.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(narrow ? 1.8 : 1)),
            child: child!,
          ),
          home: Scaffold(
            body: narrow
                ? Builder(
                    builder: (context) => Center(
                      child: TextButton(
                        onPressed: () => openSheet<void>(
                          context,
                          PeoplePage(link: fixture.link),
                        ),
                        child: const Text('人物'),
                      ),
                    ),
                  )
                : SheetFrame(
                    scroll: scroll,
                    root: GraphPage(link: fixture.link),
                  ),
          ),
        ),
      );
      if (narrow) {
        await tester.tap(find.text('人物'));
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('shots/graph-narrow-people-collapsed.png'),
        );
        await tester.tap(find.text('关系图'));
      }
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('shots/graph-${narrow ? 'narrow' : 'default'}.png'),
      );
      if (!narrow) {
        await tester.tap(find.byKey(const ValueKey<String>('graph-person-P1')));
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('shots/graph-selected.png'),
        );
        tester
            .widget<Slider>(find.byKey(const ValueKey<String>('graph-replay')))
            .onChanged!(.4);
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('shots/graph-replay.png'),
        );
        await tester.tap(
          find.byKey(const ValueKey<String>('relation-label-0')),
        );
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile('shots/graph-detail.png'),
        );
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final bool wholeBook in <bool>[false, true]) {
    testWidgets(wholeBook ? 'Aq full graph crowding' : 'Aq current graph crowding', (
      WidgetTester tester,
    ) async {
      final Directory root = Directory.systemTemp.createTempSync(
        'aq-graph-shots-',
      );
      void copy(Directory source, Directory target) {
        target.createSync(recursive: true);
        for (final FileSystemEntity entity in source.listSync()) {
          final String name = entity.uri.pathSegments
              .where((part) => part.isNotEmpty)
              .last;
          if (entity is Directory) {
            copy(entity, Directory('${target.path}/$name'));
          } else if (entity is File) {
            entity.copySync('${target.path}/$name');
          }
        }
      }

      copy(
        Directory('../oracle/goldens/books/aq_deepseek'),
        Directory('${root.path}/books/aqgraphfixture'),
      );
      final Library library = Library(root);
      await library.scan();
      SeenStore.instance.attach(File('${root.path}/seen.json'));
      final BookData book = BookData.open(library.books.single);
      final ReaderController reader = ReaderController(
        library: library,
        book: book,
      );
      reader.layout(
        Paginator(
          book,
          const PageSpec(
            width: 350,
            height: 780,
            fontSize: 19,
            lineHeight: 1.7,
            fontFamily: 'NotoSerifSC',
            color: Colors.black,
            textScaler: TextScaler.noScaling,
          ),
        ),
        0,
      );
      reader.page = PageData(
        chapter: wholeBook ? book.chapters.length - 1 : book.chapterAt(1740),
        index: 0,
        frags: <Frag>[],
        start: wholeBook ? book.length - 1 : 1740,
        end: wholeBook ? book.length : 2400,
      );
      final ReaderLink link = ReaderLink(
        c: reader,
        jump: (int _, {(int, int)? highlight}) {},
        openAsk: ({String? prefill, String? quote}) {},
      );
      const Size phone = Size(393, 851);
      tester.view.devicePixelRatio = 1;
      await tester.binding.setSurfaceSize(phone);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      try {
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.light),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () =>
                        openSheet<void>(context, PeoplePage(link: link)),
                    child: const Text('人物'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('人物'));
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.byType(SheetFrame)).height,
          lessThan(phone.height * .5),
        );
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            'shots/graph-aq-${wholeBook ? 'whole' : 'current'}-people-collapsed.png',
          ),
        );
        await tester.tap(find.text('关系图'));
        await tester.pumpAndSettle();
        expect(find.byType(RelationGraph), findsOneWidget);
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            'shots/graph-aq-${wholeBook ? 'whole' : 'current'}.png',
          ),
        );
        Finder keyed(String prefix) => find.byWidgetPredicate(
          (Widget widget) =>
              widget.key is ValueKey<String> &&
              (widget.key! as ValueKey<String>).value.startsWith(prefix),
        );
        final List<Rect> labels = keyed('relation-label-')
            .evaluate()
            .map(
              (Element element) =>
                  tester.getRect(find.byWidget(element.widget)),
            )
            .toList();
        final List<Rect> nodes = keyed('graph-person-')
            .evaluate()
            .map(
              (Element element) =>
                  tester.getRect(find.byWidget(element.widget)),
            )
            .toList();
        expect(labels, isNotEmpty);
        void expectVisibleRelationship() {
          final Rect viewport = tester.getRect(
            find.byKey(const ValueKey<String>('graph-viewport')),
          );
          final Rect screen = Rect.fromLTRB(
            0,
            24,
            phone.width,
            phone.height - 24,
          );
          final Rect visible = viewport.intersect(screen);
          expect(screen.contains(viewport.topLeft), isTrue);
          expect(
            screen.contains(viewport.bottomRight - const Offset(.1, .1)),
            isTrue,
            reason:
                'The real modal graph viewport must fit within physical phone bounds',
          );
          final List<Rect> currentLabels = keyed('relation-label-')
              .evaluate()
              .map(
                (Element element) =>
                    tester.getRect(find.byWidget(element.widget)),
              )
              .toList();
          expect(
            currentLabels.any(
              (Rect label) =>
                  visible.contains(label.topLeft) &&
                  visible.contains(label.bottomRight),
            ),
            isTrue,
            reason:
                'Opening/resetting a dense graph through the real drawer must show a complete relationship card inside the phone, not only connecting lines',
          );
        }

        expectVisibleRelationship();
        for (int i = 0; i < labels.length; i++) {
          for (int j = i + 1; j < labels.length; j++) {
            expect(
              labels[i].overlaps(labels[j]),
              isFalse,
              reason: 'Aq relationship cards $i/$j must not obscure each other',
            );
          }
          for (int n = 0; n < nodes.length; n++) {
            expect(
              labels[i].overlaps(nodes[n]),
              isFalse,
              reason: 'Aq relationship card $i must not cover node $n',
            );
          }
        }
        if (wholeBook) {
          for (int i = 0; i < 5; i++) {
            await tester.tap(find.byTooltip('缩小关系图'));
            await tester.pump();
          }
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('shots/graph-aq-overview.png'),
          );
          await tester.tap(find.byTooltip('重置视图'));
          await tester.pumpAndSettle();
          expectVisibleRelationship();
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.binding.setSurfaceSize(null);
        tester.view
          ..resetPhysicalSize()
          ..resetDevicePixelRatio()
          ..resetPadding()
          ..resetViewPadding();
        reader.dispose();
        book.notes.dispose();
        book.dispose();
        library.dispose();
        root.deleteSync(recursive: true);
      }
    });
  }

  testWidgets('vertical graph pan stays inside the expanded reader drawer', (
    WidgetTester tester,
  ) async {
    final GraphFixture fixture = GraphFixture();
    for (int i = 3; i <= 8; i++) {
      fixture.records.addAll(<Json>[
        <String, Object?>{'t': 'person', 'id': 'P$i', 'name': '人物$i', 'p': 0},
        <String, Object?>{
          't': 'rel',
          'a': 'P1',
          'b': 'P$i',
          'a_is': '同行者$i',
          'b_is': '熟人$i',
          'desc': '抽屉内纵向平移回归关系$i',
          'p': 20,
        },
      ]);
    }
    fixture.records.sort(
      (Json left, Json right) =>
          (left['p']! as int).compareTo(right['p']! as int),
    );
    fixture.refresh();

    const Size phone = Size(393, 851);
    tester.view.devicePixelRatio = 1;
    await tester.binding.setSurfaceSize(phone);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    try {
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Center(
                child: TextButton(
                  onPressed: () =>
                      openSheet<void>(context, PeoplePage(link: fixture.link)),
                  child: const Text('人物'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('人物'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('关系图'));
      await tester.pumpAndSettle();

      final Finder viewportFinder = find.byKey(
        const ValueKey<String>('graph-viewport'),
      );
      expect(find.byType(RelationGraph), findsOneWidget);
      expect(
        tester.getRect(find.byType(SheetFrame)).height,
        greaterThan(phone.height * .8),
        reason: 'Opening the relationship graph must expand its real drawer.',
      );
      final InteractiveViewer viewport = tester.widget<InteractiveViewer>(
        viewportFinder,
      );
      final TransformationController transform =
          viewport.transformationController!;
      final double initialY = transform.value.storage[13];
      final Rect graphBounds = tester.getRect(viewportFinder);
      await tester.dragFrom(graphBounds.center, const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(
        transform.value.storage[13],
        isNot(initialY),
        reason: 'Vertical movement on the canvas must pan the graph itself.',
      );
      expect(
        tester.getRect(find.byType(SheetFrame)).height,
        greaterThan(phone.height * .8),
        reason: 'A graph pan must not collapse or scroll its outer drawer.',
      );

      final Rect drawer = tester.getRect(find.byType(SheetFrame));
      await tester.dragFrom(
        Offset(phone.width / 2, drawer.top + 10),
        const Offset(0, 220),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(SheetFrame)).height,
        lessThan(drawer.height - 60),
        reason: 'The pinned drawer handle must still resize the sheet.',
      );
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
      tester.view
        ..resetPhysicalSize()
        ..resetDevicePixelRatio()
        ..resetPadding()
        ..resetViewPadding();
      fixture.dispose();
    }
  });
}
