import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/main.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/page_body.dart';
import 'package:thusfar_app/reader/reader_controller.dart';
import 'package:thusfar_app/reader/reader_screen.dart';
import 'package:thusfar_app/sheets/common.dart';
import 'package:thusfar_app/sheets/footnotes_sheet.dart';
import 'package:thusfar_app/sheets/note_editor.dart';
import 'package:thusfar_app/sheets/preview_sheet.dart';
import 'package:thusfar_app/sheets/recap_sheet.dart';
import 'package:thusfar_app/sheets/sheet_host.dart';
import 'package:thusfar_app/sheets/search_sheet.dart';
import 'package:thusfar_app/sheets/toc_sheet.dart';
import 'package:thusfar_app/ui/theme.dart';

import 'support/viewport.dart';

void main() {
  late Directory root;
  late AppModel model;
  const String first = 'Known passage 😀 ends here.';
  const String future = 'UNREAD_SECRET: the hidden ending.';

  setUp(() async {
    root = Directory.systemTemp.createTempSync('thusfar-reader-regression-');
    final Directory book = Directory('${root.path}/books/fixture0001')
      ..createSync(recursive: true);
    writeJson(File('${book.path}/book.json'), <String, Object?>{
      'title': 'Regression book',
      'author': '',
      'lang': 'en',
      'len': first.length + future.length,
      'notes': <String, Object?>{
        'read-note': 'A visible source note.',
        'future-note': 'FUTURE_NOTE_SECRET',
      },
      'blocks': <Json>[
        <String, Object?>{
          'k': 'p',
          't': first,
          'o': 0,
          'fn': <Object?>[
            <Object?>[first.length, 'read-note'],
          ],
        },
        <String, Object?>{
          'k': 'p',
          't': future,
          'o': first.length,
          'fn': <Object?>[
            <Object?>[3, 'future-note'],
          ],
        },
      ],
      'chapters': <Json>[
        <String, Object?>{
          'title': 'First',
          'b0': 0,
          'b1': 1,
          'o0': 0,
          'o1': first.length,
          'kind': 'body',
        },
        <String, Object?>{
          'title': 'SECRET_CHAPTER',
          'b0': 1,
          'b1': 2,
          'o0': first.length,
          'o1': first.length + future.length,
          'kind': 'body',
        },
      ],
    });
    writeJson(File('${book.path}/status.json'), <String, Object?>{
      'state': 'idle',
    });
    model = AppModel(root);
    await model.library.scan();
  });
  tearDown(() {
    model.dispose();
    root.deleteSync(recursive: true);
  });

  testWidgets(
    'vertical fold keeps text and tools on opposite sides of the hinge',
    (tester) async {
      tester.view
        ..physicalSize = const Size(900, 1000)
        ..devicePixelRatio = 1
        ..displayFeatures = <ui.DisplayFeature>[
          const ui.DisplayFeature(
            bounds: Rect.fromLTWH(440, 0, 20, 1000),
            type: ui.DisplayFeatureType.hinge,
            state: ui.DisplayFeatureState.postureHalfOpened,
          ),
        ];
      addTearDown(() {
        tester.view
          ..resetDisplayFeatures()
          ..resetPhysicalSize()
          ..resetDevicePixelRatio();
      });

      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('foldable-nav-0')),
        findsOneWidget,
      );
      expect(find.text('书架'), findsOneWidget);
      expect(find.byType(NavigationRail), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      await tester.tap(find.text('Regression book').first);
      await tester.pumpAndSettle();

      final Rect page = tester.getRect(find.byType(PageBody).first);
      final Rect viewport = tester.getRect(
        find.byKey(const ValueKey<String>('reader-page-viewport')),
      );
      expect(viewport.left, 0);
      expect(viewport.right, 440);
      expect(page.left, 20);
      expect(page.right, 420);
      expect(find.text('目录与书签'), findsNothing);
      final PageController controller = tester
          .widget<PageView>(find.byType(PageView))
          .controller!;
      await tester.tapAt(const Offset(420, 700));
      await tester.pumpAndSettle();
      expect(controller.page, closeTo(ReaderController.base + 1, 0.001));
      await tester.tapAt(const Offset(12, 700));
      await tester.pumpAndSettle();
      expect(controller.page, closeTo(ReaderController.base, 0.001));
      model.prefs.update((prefs) => prefs.pageHorizontalMargin = 96);
      await tester.pumpAndSettle();
      final Rect insetPage = tester.getRect(find.byType(PageBody).first);
      expect(insetPage.left, 96);
      expect(insetPage.right, 344);
      final PageController insetController = tester
          .widget<PageView>(find.byType(PageView))
          .controller!;
      await tester.tapAt(const Offset(420, 700));
      await tester.pumpAndSettle();
      expect(insetController.page, closeTo(ReaderController.base + 1, 0.001));
      await tester.tapAt(const Offset(12, 700));
      await tester.pumpAndSettle();
      expect(insetController.page, closeTo(ReaderController.base, 0.001));
      await tester.tapAt(const Offset(220, 700));
      await tester.pumpAndSettle();
      expect(find.text('人物').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('horizontal fold keeps text above the hinge and tools below it', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(430, 900)
      ..devicePixelRatio = 1
      ..displayFeatures = <ui.DisplayFeature>[
        const ui.DisplayFeature(
          bounds: Rect.fromLTWH(0, 430, 430, 20),
          type: ui.DisplayFeatureType.hinge,
          state: ui.DisplayFeatureState.postureHalfOpened,
        ),
      ];
    addTearDown(() {
      tester.view
        ..resetDisplayFeatures()
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });

    await tester.pumpWidget(ThusfarApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Regression book').first);
    await tester.pumpAndSettle();

    final Rect page = tester.getRect(find.byType(PageBody).first);
    expect(page.bottom, lessThanOrEqualTo(430));
    expect(find.text('工具栏'), findsNothing);
    await tester.tap(find.text('阅读工具'));
    await tester.pumpAndSettle();
    expect(find.text('目录').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'flat folds stay continuous and selection follows a right reading pane',
    (WidgetTester tester) async {
      tester.view
        ..physicalSize = const Size(840, 900)
        ..devicePixelRatio = 1;
      addTearDown(() {
        tester.view
          ..resetDisplayFeatures()
          ..resetPhysicalSize()
          ..resetDevicePixelRatio();
      });
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Regression book').first);
      await tester.pumpAndSettle();
      tester.view.displayFeatures = const <ui.DisplayFeature>[
        ui.DisplayFeature(
          bounds: Rect.fromLTWH(410, 0, 0, 900),
          type: ui.DisplayFeatureType.fold,
          state: ui.DisplayFeatureState.postureFlat,
        ),
      ];
      await tester.pumpAndSettle();
      final Finder viewport = find.byKey(
        const ValueKey<String>('reader-page-viewport'),
      );
      expect(tester.getRect(viewport).width, 840);
      expect(tester.getRect(find.byType(PageBody).first).center.dx, 420);
      expect(find.text('阅读工具'), findsNothing);

      tester.view.displayFeatures = const <ui.DisplayFeature>[
        ui.DisplayFeature(
          bounds: Rect.fromLTWH(80, 0, 20, 900),
          type: ui.DisplayFeatureType.hinge,
          state: ui.DisplayFeatureState.postureHalfOpened,
        ),
      ];
      await tester.pumpAndSettle();
      expect(tester.getRect(viewport).left, 100);
      final Finder visible = find.byType(PageBody).first;
      final PageBody body = tester.widget<PageBody>(visible);
      final Frag fragment = body.page.frags.first;
      final Block block = body.pager.book.blocks[fragment.block];
      final TextPainter painter = body.pager.painterFor(block);
      final Offset caret = painter.getOffsetForCaret(
        TextPosition(offset: fragment.start + 3 + indentShift),
        Rect.zero,
      );
      painter.dispose();
      await tester.longPressAt(
        tester.getTopLeft(visible) +
            Offset(
              caret.dx + body.pager.spec.fontSize / 4,
              caret.dy - fragment.top + body.pager.spec.line / 2,
            ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('摘录'));
      await tester.pumpAndSettle();
      expect(body.pager.book.notes.notes, hasLength(1));
      final Json note = body.pager.book.notes.notes.single;
      expect(
        note['quote'],
        body.pager.book.textBetween(note['start']! as int, note['end']! as int),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('footnote at next block start does not leak across page boundary', () {
    final BookData book = BookData.open(model.library.books.single);
    book.blocks[1].raw['fn'] = <Object?>[
      <Object?>[0, 'future-note'],
    ];
    expect(pageFootnotes(book, 0, first.length), <(int, String)>[
      (first.length, 'read-note'),
    ]);
    expect(pageFootnotes(book, first.length, book.length), <(int, String)>[
      (first.length, 'future-note'),
    ]);
    book.notes.dispose();
    book.dispose();
  });

  testWidgets('arrow keys and the mouse wheel turn pages on a computer', (
    tester,
  ) async {
    await setTestViewport(tester, const Size(430, 1000));
    addTearDown(() => setTestViewport(tester, null));
    await tester.pumpWidget(ThusfarApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Regression book').first);
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsOneWidget);
    Finder page(int n) => find.textContaining(RegExp('^$n / '));
    expect(page(1), findsOneWidget);
    // Standard application shortcuts must not trigger single-letter reading
    // actions or accidentally change the current page.
    for (final LogicalKeyboardKey modifier in <LogicalKeyboardKey>[
      LogicalKeyboardKey.control,
      LogicalKeyboardKey.meta,
      LogicalKeyboardKey.alt,
    ]) {
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
      expect(page(1), findsOneWidget);
      expect(find.byType(TocPage), findsNothing);
      final PageBody body = tester.widget<PageBody>(
        find.byType(PageBody).first,
      );
      expect(body.pager.book.notes.bookmarks, isEmpty);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(page(2), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(page(1), findsOneWidget);
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    mouse.hover(const Offset(215, 500));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 60)));
    await tester.pumpAndSettle();
    expect(page(2), findsOneWidget);

    // Mouse wheel scroll backward to page 1
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -60)));
    await tester.pumpAndSettle();
    expect(page(1), findsOneWidget);

    // Test N key opens TocPage notes tab
    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await tester.pumpAndSettle();
    expect(find.byType(TocPage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // Test R key opens RecapPage
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pumpAndSettle();
    expect(find.byType(RecapPage), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'book illustrations retain original alt and explain missing files',
    (WidgetTester tester) async {
      const String originalAlt = '本地插图的原始说明';
      final BookEntry entry = model.library.books.single;
      final File metaFile = File('${entry.dir.path}/book.json');
      final Json meta = readJson(metaFile)! as Json;
      meta
        ..['len'] = 3
        ..['blocks'] = <Json>[
          <String, Object?>{
            'k': 'img',
            't': '\uFFFC',
            'o': 0,
            'src': 'illustration.png',
            'alt': originalAlt,
          },
          <String, Object?>{
            'k': 'img',
            't': '\uFFFC',
            'o': 1,
            'src': 'illustration.png',
            'alt': '',
          },
          <String, Object?>{
            'k': 'img',
            't': '\uFFFC',
            'o': 2,
            'src': 'missing.png',
            'alt': originalAlt,
          },
        ]
        ..['chapters'] = <Json>[
          for (int index = 0; index < 3; index++)
            <String, Object?>{
              'title': 'Illustration $index',
              'b0': index,
              'b1': index + 1,
              'o0': index,
              'o1': index + 1,
              'kind': 'body',
            },
        ];
      writeJson(metaFile, meta);
      final Directory images = Directory('${entry.dir.path}/img')..createSync();
      final File illustration = File('${images.path}/illustration.png')
        ..writeAsBytesSync(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAgAAAAICAIAAABLbSncAAAAEUlEQVR4nGPQjSrHihiGlgQAvbA/gQjEHksAAAAASUVORK5CYII=',
          ),
        );
      final BookData book = BookData.open(entry);
      addTearDown(() {
        book.notes.dispose();
        book.dispose();
      });
      final Paginator pager = Paginator(
        book,
        const PageSpec(
          width: 300,
          height: 400,
          fontSize: 16,
          lineHeight: 1.6,
          fontFamily: null,
          color: Colors.black,
          textScaler: TextScaler.noScaling,
        ),
      );
      final SemanticsHandle semantics = tester.ensureSemantics();
      try {
        // Start file IO and decoding outside FakeAsync before Image.file uses
        // the cache entry; awaiting an already pending fake-zone stream stalls.
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.light),
            home: const Scaffold(body: SizedBox()),
          ),
        );
        await tester.runAsync(
          () => precacheImage(
            FileImage(illustration),
            tester.element(find.byType(Scaffold)),
          ),
        );
        Future<void> showChapter(int chapter) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: buildTheme(Brightness.light),
              home: Scaffold(
                body: PageBody(
                  page: pager.pages(chapter).single,
                  pager: pager,
                  layers: const PageLayers(
                    world: null,
                    cutoff: 3,
                    notes: <Json>[],
                  ),
                  onName: (_) {},
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        await showChapter(0);
        expect(find.byType(Image), findsOneWidget);
        expect(find.bySemanticsLabel(originalAlt), findsOneWidget);
        await showChapter(1);
        expect(find.byType(Image), findsOneWidget);
        expect(
          tester.getSemantics(find.byType(Image)).getSemanticsData().label,
          isEmpty,
        );
        await showChapter(2);
        expect(find.byType(Image), findsNothing);
        expect(find.bySemanticsLabel('图片未保存。$originalAlt'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('screen reader receives only the visible paragraph slice', (
    WidgetTester tester,
  ) async {
    final BookEntry entry = model.library.books.single;
    final String text =
        '${List<String>.filled(80, 'Visible words. ').join()}'
        'UNREAD_SECRET_ENDING';
    writeJson(File('${entry.dir.path}/book.json'), <String, Object?>{
      'title': 'Accessible reading',
      'author': '',
      'lang': 'en',
      'len': text.length,
      'blocks': <Json>[
        <String, Object?>{'k': 'p', 't': text, 'o': 0},
      ],
      'chapters': <Json>[
        <String, Object?>{
          'title': 'First',
          'b0': 0,
          'b1': 1,
          'o0': 0,
          'o1': text.length,
          'kind': 'body',
        },
      ],
    });
    final BookData book = BookData.open(entry);
    addTearDown(() {
      book.notes.dispose();
      book.dispose();
    });
    final Paginator pager = Paginator(
      book,
      const PageSpec(
        width: 180,
        height: 100,
        fontSize: 18,
        lineHeight: 1.6,
        fontFamily: null,
        color: Colors.black,
        textScaler: TextScaler.noScaling,
      ),
    );
    final PageData page = pager.pages(0).first;
    expect(page.end, lessThan(text.indexOf('UNREAD_SECRET')));
    final SemanticsHandle semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: PageBody(
              page: page,
              pager: pager,
              layers: PageLayers(
                world: null,
                cutoff: page.end,
                notes: const <Json>[],
              ),
              onName: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final RichText paragraph = tester.widget<RichText>(
        find.byType(RichText).first,
      );
      expect(
        paragraph.text.toPlainText(includeSemanticsLabels: false),
        contains('UNREAD_SECRET_ENDING'),
      );
      expect(
        paragraph.text.toPlainText(includeSemanticsLabels: true),
        isNot(contains('UNREAD_SECRET_ENDING')),
      );
      expect(find.bySemanticsLabel(RegExp('UNREAD_SECRET')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    } finally {
      semantics.dispose();
    }
  });

  testWidgets(
    'screen reader page actions turn available pages and expose reading tools',
    (WidgetTester tester) async {
      await setTestViewport(tester, const Size(430, 1000));
      addTearDown(() => setTestViewport(tester, null));
      final SemanticsHandle semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(ThusfarApp(model: model));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Regression book').first);
        await tester.pumpAndSettle();
        final Finder actions = find.byKey(
          const ValueKey<String>('reader-page-actions'),
        );
        Map<CustomSemanticsAction, VoidCallback> available() => tester
            .widget<Semantics>(actions)
            .properties
            .customSemanticsActions!;
        Future<void> activate(String label) async {
          final CustomSemanticsAction action = available().keys.singleWhere(
            (CustomSemanticsAction action) => action.label == label,
          );
          final node = tester.getSemantics(actions);
          node.owner!.performAction(
            node.id,
            ui.SemanticsAction.customAction,
            CustomSemanticsAction.getIdentifier(action),
          );
          await tester.pumpAndSettle();
        }

        expect(
          available().keys.map((CustomSemanticsAction action) => action.label),
          unorderedEquals(<String>['下一页', '阅读工具']),
        );
        await activate('下一页');
        expect(
          model.library.progressOf(model.library.books.single.id)!.pos,
          first.length,
        );
        expect(
          available().keys.map((CustomSemanticsAction action) => action.label),
          unorderedEquals(<String>['上一页', '阅读工具']),
        );
        await activate('上一页');
        expect(model.library.progressOf(model.library.books.single.id)!.pos, 0);
        await activate('阅读工具');
        expect(find.byTooltip('回书架').hitTestable(), findsOneWidget);
        expect(model.library.progressOf(model.library.books.single.id)!.pos, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('folding and desktop resizing preserve the source anchor', (
    WidgetTester tester,
  ) async {
    final BookEntry entry = model.library.books.single;
    File(
      '../oracle/goldens/books/aq_deepseek/book.json',
    ).copySync('${entry.dir.path}/book.json');
    await model.library.scan();
    model.library.saveProgress(entry.id, 5799, 6086, 21734);
    tester.view
      ..physicalSize = const Size(390, 844)
      ..devicePixelRatio = 1;
    addTearDown(() {
      tester.view
        ..resetDisplayFeatures()
        ..resetPhysicalSize()
        ..resetDevicePixelRatio();
    });
    await tester.pumpWidget(ThusfarApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.text(model.library.books.single.title).first);
    await tester.pumpAndSettle();
    final Progress saved = model.library.progressOf(entry.id)!;
    final int anchor = saved.pos;
    final List<(Size, List<ui.DisplayFeature>)> profiles =
        <(Size, List<ui.DisplayFeature>)>[
          (
            const Size(840, 900),
            const <ui.DisplayFeature>[
              ui.DisplayFeature(
                bounds: Rect.fromLTWH(410, 0, 20, 900),
                type: ui.DisplayFeatureType.hinge,
                state: ui.DisplayFeatureState.postureHalfOpened,
              ),
            ],
          ),
          (
            const Size(430, 900),
            const <ui.DisplayFeature>[
              ui.DisplayFeature(
                bounds: Rect.fromLTWH(0, 430, 430, 20),
                type: ui.DisplayFeatureType.hinge,
                state: ui.DisplayFeatureState.postureHalfOpened,
              ),
            ],
          ),
          (const Size(1440, 960), const <ui.DisplayFeature>[]),
          (const Size(390, 844), const <ui.DisplayFeature>[]),
        ];
    for (final (Size size, List<ui.DisplayFeature> features) in profiles) {
      tester.view
        ..physicalSize = size
        ..displayFeatures = features;
      await tester.pumpAndSettle();
      final Finder visible = find.byType(PageBody).first;
      final PageBody body = tester.widget<PageBody>(visible);
      final Rect rect = tester.getRect(visible);
      expect(body.page.start, lessThanOrEqualTo(anchor));
      expect(body.page.end, greaterThan(anchor));
      expect(rect.width, lessThanOrEqualTo(560));
      for (final ui.DisplayFeature feature in features) {
        expect(rect.overlaps(feature.bounds), isFalse);
      }
      expect(model.library.progressOf(entry.id)!.pos, saved.pos);
      expect(model.library.progressOf(entry.id)!.cutoff, saved.cutoff);
      if (size.width == 1440) {
        expect(rect.center.dx, 720);
        // Selection hit testing must use the same centered content origin.
        final Frag fragment = body.page.frags.firstWhere(
          (Frag frag) => !frag.image,
        );
        final Block block = body.pager.book.blocks[fragment.block];
        final TextPainter painter = body.pager.painterFor(block);
        final Offset caret = painter.getOffsetForCaret(
          TextPosition(offset: fragment.start + 3 + indentShift),
          Rect.zero,
        );
        painter.dispose();
        await tester.longPressAt(
          tester.getTopLeft(visible) +
              Offset(
                caret.dx + body.pager.spec.fontSize / 4,
                caret.dy - fragment.top + body.pager.spec.line / 2,
              ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('摘录'));
        await tester.pumpAndSettle();
        expect(body.pager.book.notes.notes, hasLength(1));
        final Json note = body.pager.book.notes.notes.single;
        expect(note['start']! as int, greaterThanOrEqualTo(body.page.start));
        expect(note['end']! as int, lessThanOrEqualTo(body.page.end));
        expect(
          note['quote'],
          body.pager.book.textBetween(
            note['start']! as int,
            note['end']! as int,
          ),
        );
      }
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'book drawer notes opens notes and reader back returns in one tap',
    (tester) async {
      await setTestViewport(tester, const Size(430, 1000));
      addTearDown(() => setTestViewport(tester, null));
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pumpAndSettle();
      await tester.longPress(find.text('Regression book').first);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('我的摘记'));
      await tester.tap(find.text('我的摘记'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(find.byType(TocPage), findsOneWidget);
      expect(find.text('读书时长按一句话，就能摘录或写笔记'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(215, 500));
      await tester.pumpAndSettle();
      expect(find.byTooltip('更多操作'), findsOneWidget);
      await tester.tap(find.byTooltip('回书架'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsNothing);
      expect(find.text('Regression book'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'closing a sheet restores the reader toolbar before the next Back leaves reading',
    (tester) async {
      await setTestViewport(tester, const Size(430, 1000));
      addTearDown(() => setTestViewport(tester, null));
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Regression book').first);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(215, 500));
      await tester.pumpAndSettle();
      expect(find.byTooltip('更多操作'), findsOneWidget);

      await tester.tap(find.text('目录'));
      await tester.pumpAndSettle();
      expect(find.byType(TocPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(TocPage), findsNothing);
      expect(find.byTooltip('更多操作'), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsOneWidget);
      final Finder hiddenToolbar = find
          .ancestor(
            of: find.byTooltip('更多操作'),
            matching: find.byType(IgnorePointer),
          )
          .first;
      expect(tester.widget<IgnorePointer>(hiddenToolbar).ignoring, isTrue);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsNothing);
      expect(find.text('Regression book'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'page footnotes open through reader without exposing later notes',
    (tester) async {
      await setTestViewport(tester, const Size(430, 1000));
      addTearDown(() => setTestViewport(tester, null));
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Regression book').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('注释 1'));
      await tester.pumpAndSettle();
      expect(find.byType(FootnotesPage), findsOneWidget);
      expect(find.text('A visible source note.'), findsOneWidget);
      expect(find.text('FUTURE_NOTE_SECRET'), findsNothing);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(ReaderScreen), findsOneWidget);
      expect(find.byType(FootnotesPage), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('read-only search clips snippets within a partially read block', (
    tester,
  ) async {
    final BookData book = BookData.open(model.library.books.single);
    final ReaderController controller = ReaderController(
      library: model.library,
      book: book,
    );
    final ScrollController scroll = ScrollController();
    controller.layout(
      Paginator(
        book,
        const PageSpec(
          width: 390,
          height: 700,
          fontSize: 18,
          lineHeight: 1.8,
          fontFamily: 'Roboto',
          color: Colors.black,
          textScaler: TextScaler.noScaling,
        ),
      ),
      0,
    );
    // Stop inside the first paragraph, before the word 'ends'.
    controller.page = PageData(
      chapter: 0,
      index: 0,
      frags: [],
      start: 0,
      end: first.indexOf('ends'),
    );
    final ReaderLink link = ReaderLink(
      c: controller,
      jump: (int _, {(int, int)? highlight}) {},
      openAsk: ({String? prefill, String? quote}) {},
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: SheetFrame(
            scroll: scroll,
            root: SearchPage(link: link),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'Known');
    await tester.pumpAndSettle();
    String visible() => tester
        .widgetList<RichText>(find.byType(RichText))
        .map((RichText text) => text.text.toPlainText())
        .join('\n');
    expect(visible(), contains('Known passage'));
    expect(visible(), isNot(contains('ends here')));
    await tester.tap(find.text('全书'));
    await tester.pumpAndSettle();
    expect(visible(), contains('ends here'));
    await tester.pumpWidget(const SizedBox());
    scroll.dispose();
    controller.dispose();
    book.notes.dispose();
    book.dispose();
  });

  testWidgets(
    'note modal IME animation preserves reading position and saves original range once',
    (WidgetTester tester) async {
      final BookEntry entry = model.library.books.single;
      File(
        '../oracle/goldens/books/aq_deepseek/book.json',
      ).copySync('${entry.dir.path}/book.json');
      await model.library.scan();
      model.library.saveProgress(entry.id, 5799, 6086, 21734);
      await setTestViewport(tester, const Size(430, 1000));
      tester.view.viewPadding = const FakeViewPadding(bottom: 24);
      tester.view.padding = const FakeViewPadding(bottom: 24);
      addTearDown(() async {
        tester.view.resetViewInsets();
        tester.view.resetViewPadding();
        tester.view.resetPadding();
        await setTestViewport(tester, null);
      });
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pumpAndSettle();
      await tester.tap(find.text(model.library.books.single.title).first);
      await tester.pumpAndSettle();

      Finder visibleBody() {
        final Finder bodies = find.byType(PageBody, skipOffstage: false);
        for (int i = 0; i < bodies.evaluate().length; i++) {
          if (tester.getRect(bodies.at(i)).contains(const Offset(215, 300))) {
            return bodies.at(i);
          }
        }
        throw StateError('No visible reader page');
      }

      final PageBody original = tester.widget<PageBody>(visibleBody());
      final int originalStart = original.page.start;
      final int originalEnd = original.page.end;
      final Progress savedProgress = model.library.progressOf(entry.id)!;
      expect(originalStart, greaterThan(4000));
      final Frag fragment = original.page.frags.first;
      final Block block = original.pager.book.blocks[fragment.block];
      final TextPainter painter = original.pager.painterFor(block);
      final Offset caret = painter.getOffsetForCaret(
        TextPosition(offset: fragment.start + 3 + indentShift),
        Rect.zero,
      );
      painter.dispose();
      final Offset point =
          tester.getTopLeft(visibleBody()) +
          Offset(
            caret.dx + original.pager.spec.fontSize / 4,
            caret.dy - fragment.top + original.pager.spec.line / 2,
          );
      await tester.longPressAt(point);
      await tester.pumpAndSettle();
      await tester.tap(find.text('笔记'));
      await tester.pumpAndSettle();
      final NoteEditor editor = tester.widget<NoteEditor>(
        find.byType(NoteEditor),
      );
      final String quote = original.pager.book.textBetween(
        editor.start,
        editor.end,
      );
      expect(quote, isNotEmpty);

      // Android reports a sequence of changing insets while the IME animates.
      // Its ordinary padding also drops to zero despite a persistent nav inset.
      for (final double height in <double>[60, 120, 180, 240, 300, 360]) {
        tester.view.viewInsets = FakeViewPadding(bottom: height);
        tester.view.padding = FakeViewPadding.zero;
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.enterText(find.byType(TextField), '回归测试：保存笔记\n第二行 ✅');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      for (final double height in <double>[300, 240, 180, 120, 60, 0]) {
        tester.view.viewInsets = FakeViewPadding(bottom: height);
        tester.view.padding = FakeViewPadding(bottom: height == 0 ? 24 : 0);
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      expect(find.byType(NoteEditor), findsNothing);
      final PageBody after = tester.widget<PageBody>(visibleBody());
      expect(
        after.page.start,
        originalStart,
        reason: 'IME must not move the source anchor',
      );
      expect(
        after.page.end,
        originalEnd,
        reason: 'IME must not change the reading cutoff',
      );
      expect(
        after.pager,
        same(original.pager),
        reason: 'A modal keyboard must not repaginate the underlying book',
      );
      expect(model.library.progressOf(entry.id)!.pos, savedProgress.pos);
      expect(model.library.progressOf(entry.id)!.cutoff, savedProgress.cutoff);
      final List<Object?> saved =
          jsonDecode(File('${entry.dir.path}/notebook.json').readAsStringSync())
              as List<Object?>;
      expect(saved, hasLength(1));
      final Json note = saved.single! as Json;
      expect(note['start'], editor.start);
      expect(note['end'], editor.end);
      expect(note['quote'], quote);
      expect(note['text'], '回归测试：保存笔记\n第二行 ✅');
      expect(note['revision'], 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final bool crossesCutoff in <bool>[false, true]) {
    testWidgets(
      'preview ${crossesCutoff ? 'gates crossing range' : 'clips trailing context'} at cutoff',
      (tester) async {
        final BookData book = BookData.open(model.library.books.single);
        final ReaderController controller = ReaderController(
          library: model.library,
          book: book,
        );
        final ScrollController scroll = ScrollController();
        controller.layout(
          Paginator(
            book,
            const PageSpec(
              width: 390,
              height: 700,
              fontSize: 18,
              lineHeight: 1.8,
              fontFamily: 'Roboto',
              textScaler: TextScaler.noScaling,
              color: Colors.black,
            ),
          ),
          0,
        );
        expect(controller.cutoff, first.length);
        final ReaderLink link = ReaderLink(
          c: controller,
          jump: (int _, {(int, int)? highlight}) {},
          openAsk: ({String? prefill, String? quote}) {},
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Scaffold(
              body: SheetFrame(
                scroll: scroll,
                root: PreviewPage(
                  link: link,
                  start: 0,
                  end: crossesCutoff ? first.length + 4 : 5,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        String visible() => tester
            .widgetList<RichText>(find.byType(RichText))
            .map((RichText text) => text.text.toPlainText())
            .join('\n');
        expect(visible(), isNot(contains('UNREAD_SECRET')));
        expect(visible(), isNot(contains('SECRET_CHAPTER')));
        if (crossesCutoff) {
          expect(find.text('预览未读原文'), findsOneWidget);
          await tester.tap(find.text('预览未读原文'));
          await tester.pumpAndSettle();
          expect(visible(), contains('UNREAD_SECRET'));
        } else {
          expect(visible(), contains(first));
        }
        final int emoji = first.indexOf('😀');
        expect(book.textBetween(emoji + 1, emoji + 2), '');
        expect(book.textBetween(emoji, emoji + 1), '');
        expect(book.textBetween(emoji, emoji + 2), '😀');
        await tester.pumpWidget(const SizedBox());
        scroll.dispose();
        controller.dispose();
        book.notes.dispose();
        book.dispose();
      },
    );
  }

  testWidgets('typography sheet switches font and propagates to reader spec', (
    tester,
  ) async {
    await setTestViewport(tester, const Size(430, 1000));
    addTearDown(() => setTestViewport(tester, null));
    await tester.pumpWidget(ThusfarApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Regression book').first);
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsOneWidget);

    // Initial font is 0 (Songti)
    expect(model.prefs.font, 0);
    expect(model.prefs.fontFamily, 'NotoSerifSC');
    expect(model.prefs.fontFallback.contains('NotoSerifSC'), isTrue);

    // Tap center to open reader toolbar
    await tester.tapAt(const Offset(215, 500));
    await tester.pumpAndSettle();
    expect(find.text('排版'), findsOneWidget);

    // Open typography sheet
    await tester.tap(find.text('排版'));
    await tester.pumpAndSettle();

    // Select 楷
    await tester.tap(find.text('楷'));
    await tester.pumpAndSettle();
    expect(model.prefs.font, 1);
    expect(model.prefs.fontFamily, 'LXGWWenKaiScreen');
    expect(model.prefs.fontFallback, <String>['NotoSerifSC', 'serif']);

    // Select 黑
    await tester.tap(find.text('黑'));
    await tester.pumpAndSettle();
    expect(model.prefs.font, 2);
    expect(model.prefs.fontFamily, 'NotoSansSC');
    expect(model.prefs.fontFallback.contains('MiSans'), isTrue);
    expect(model.prefs.fontFallback.last, 'NotoSerifSC');

    // Reset back to 0 (宋)
    await tester.tap(find.text('宋'));
    await tester.pumpAndSettle();
    expect(model.prefs.font, 0);
    expect(model.prefs.fontFamily, 'NotoSerifSC');

    // Dismiss sheet
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
}
