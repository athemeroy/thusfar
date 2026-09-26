import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'package:thusfar_app/sheets/sheet_host.dart';
import 'package:thusfar_app/sheets/search_sheet.dart';
import 'package:thusfar_app/sheets/toc_sheet.dart';
import 'package:thusfar_app/ui/theme.dart';

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

  testWidgets('vertical fold keeps reader text and tools on separate panes', (
    tester,
  ) async {
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
    final Rect tools = tester.getRect(find.text('目录与书签'));
    expect(page.left, greaterThanOrEqualTo(0));
    expect(page.right, lessThanOrEqualTo(440));
    expect(tools.left, greaterThanOrEqualTo(460));
    expect(find.text('人物与关系'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('horizontal fold places reading above hinge and controls below', (
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
    final Rect controls = tester.getRect(find.text('工具栏'));
    expect(page.bottom, lessThanOrEqualTo(430));
    expect(controls.top, greaterThanOrEqualTo(450));
    expect(find.text('上一页'), findsWidgets);
    expect(find.text('下一页'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

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
    await tester.binding.setSurfaceSize(const Size(430, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ThusfarApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Regression book').first);
    await tester.pumpAndSettle();
    expect(find.byType(ReaderScreen), findsOneWidget);
    Finder page(int n) => find.textContaining(RegExp('^$n / '));
    expect(page(1), findsOneWidget);
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
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'book drawer notes opens notes and reader back returns in one tap',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(430, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
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
      await tester.binding.setSurfaceSize(const Size(430, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
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
      await tester.binding.setSurfaceSize(const Size(430, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
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
      await tester.binding.setSurfaceSize(const Size(430, 1000));
      tester.view.viewPadding = const FakeViewPadding(bottom: 24);
      tester.view.padding = const FakeViewPadding(bottom: 24);
      addTearDown(() async {
        tester.view.resetViewInsets();
        tester.view.resetViewPadding();
        tester.view.resetPadding();
        await tester.binding.setSurfaceSize(null);
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
}
