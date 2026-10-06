import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/reader_directory.dart';
import 'package:thusfar_app/data/seen.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/reader_controller.dart';
import 'package:thusfar_app/reader/text_purification.dart';
import 'package:thusfar_app/sheets/common.dart';
import 'package:thusfar_app/sheets/directory_correction_page.dart';
import 'package:thusfar_app/sheets/sheet_host.dart';
import 'package:thusfar_app/sheets/toc_search_page.dart';
import 'package:thusfar_app/sheets/toc_sheet.dart';
import 'package:thusfar_app/ui/theme.dart';

import 'support/viewport.dart';

void main() {
  setUpAll(() async {
    for (final String family in <String>['Roboto', 'NotoSansSC']) {
      await (FontLoader(family)..addFont(
            Future<ByteData>.value(
              ByteData.sublistView(
                File('assets/fonts/NotoSansSC.ttf').readAsBytesSync(),
              ),
            ),
          ))
          .load();
    }
  });
  late Directory root;
  late BookData book;
  late Library library;
  late ReaderController controller;
  late ReaderLink link;
  late List<int> jumps;
  late Json source;
  setUp(() {
    root = Directory.systemTemp.createTempSync('thusfar-directory-ui-');
    final Directory dir = Directory('${root.path}/books/fixture')
      ..createSync(recursive: true);
    final List<Json> blocks = <Json>[];
    final List<Json> chapters = <Json>[];
    int offset = 0;
    for (int i = 0; i < 600; i++) {
      final int start = offset;
      final String heading = '第${i + 1}章 ${i == 450 ? '秘密线索已揭晓' : '山间旅程'}';
      blocks.add(<String, Object?>{'k': 'p', 't': heading, 'o': offset});
      offset += heading.length + 1;
      blocks.add(<String, Object?>{'k': 'p', 't': '这里是正文📕。' * 3, 'o': offset});
      offset += ('这里是正文📕。' * 3).length + 1;
      if (i % 100 == 0) {
        chapters.add(<String, Object?>{
          'title': '原始分段 ${i ~/ 100 + 1}',
          'b0': i * 2,
          'b1': (i + 100) * 2,
          'o0': start,
          'o1': 0,
          'kind': 'body',
        });
      }
      chapters.last['o1'] = offset;
    }
    source = <String, Object?>{
      'title': '长篇 TXT',
      'lang': 'zh',
      'len': offset,
      'blocks': blocks,
      'chapters': chapters,
      'notes': <String, Object?>{},
    };
    writeJson(File('${dir.path}/book.json'), source);
    writeJson(File('${dir.path}/meta.json'), <String, Object?>{
      'filename': 'long.TXT',
    });
    library = Library(root);
    final BookEntry entry = BookEntry(
      id: 'fixture',
      dir: dir,
      meta: source,
      status: const ProcessStatus(<String, Object?>{
        'state': 'paused',
        'frontier': 20,
      }),
      added: 0,
    );
    library.books.add(entry);
    book = BookData.open(entry);
    controller = ReaderController(library: library, book: book);
    controller.layout(
      Paginator(
        book,
        const PageSpec(
          width: 280,
          height: 200,
          fontSize: 16,
          lineHeight: 1.6,
          fontFamily: null,
          color: Colors.black,
          textScaler: TextScaler.noScaling,
        ),
      ),
      book.blocks[460].o,
    );
    jumps = <int>[];
    link = ReaderLink(
      c: controller,
      jump: (int offset, {(int, int)? highlight}) => jumps.add(offset),
      openAsk: ({String? prefill, String? quote}) {},
    );
    SeenStore.instance.attach(File('${root.path}/seen.json'));
  });
  tearDown(() {
    controller.dispose();
    book.notes.dispose();
    book.dispose();
    library.dispose();
    root.deleteSync(recursive: true);
  });

  Future<void> show(
    WidgetTester tester, {
    Widget? page,
    Size size = const Size(430, 900),
    double scale = 1,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: SheetFrame(
            key: UniqueKey(),
            scroll: scroll,
            root: page ?? TocPage(link: link),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapText(WidgetTester tester, String text) async {
    final Finder target = find.text(text);
    await Scrollable.ensureVisible(tester.element(target), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }

  Future<void> preview(WidgetTester tester) async {
    await tapText(tester, '预览目录');
    for (int i = 0; i < 100 && find.text('正在识别…').evaluate().isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('预览共 600 项 · 常见中英文章节'), findsOneWidget);
  }

  testWidgets(
    '600-heading preview cancel apply repeat reset preserve reader and AI state',
    (tester) async {
      final String before = File(
        '${book.entry.dir.path}/book.json',
      ).readAsStringSync();
      final int start = controller.start,
          cutoff = controller.cutoff,
          chapter = controller.chapter;
      await show(tester);
      await tapText(tester, '修正 TXT 目录');
      expect(find.text('修正目录不包含在书籍导出、书库 ZIP 备份或 WebDAV 同步中'), findsOneWidget);
      await preview(tester);
      expect(book.directory.enabled, isFalse);
      await tapText(tester, '取消预览');
      expect(find.text('应用目录'), findsNothing);
      await preview(tester);
      await tapText(tester, '应用目录');
      expect(book.directory.chapters.length, 600);
      expect(book.chapters.length, 6);
      expect(controller.start, start);
      expect(controller.cutoff, cutoff);
      expect(controller.chapter, chapter);
      expect(book.status.state, 'paused');
      expect(book.status.frontier, 20);
      expect(jumps, isEmpty);
      await preview(tester);
      await tapText(tester, '应用目录');
      await tapText(tester, '恢复原目录');
      await tapText(tester, '取消恢复');
      expect(book.directory.enabled, isTrue);
      await tapText(tester, '恢复原目录');
      await tapText(tester, '确认恢复');
      expect(book.directory.chapters, same(book.chapters));
      expect(
        File('${book.entry.dir.path}/book.json').readAsStringSync(),
        before,
      );
      expect(controller.start, start);
      expect(controller.cutoff, cutoff);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'preview, search and ordinal jumps use safe offset-based corrected entries',
    (tester) async {
      // Before reading anything only neutral labels may enter the preview tree.
      controller.layout(controller.pager!, 0);
      await show(tester, page: DirectoryCorrectionPage(link: link));
      final SemanticsHandle semantics = tester.ensureSemantics();
      await preview(tester);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('directory-preview-450')),
        400,
        maxScrolls: 130,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('目录第 451 项'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('.*秘密线索.*')), findsNothing);
      tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!
          .jumpTo(0);
      await tester.pumpAndSettle();
      await tapText(tester, '应用目录');
      await show(tester, page: TocSearchPage(link: link));
      final Finder input = find.byKey(
        const ValueKey<String>('toc-search-input'),
      );
      await tester.enterText(input, '秘密线索');
      await tester.pumpAndSettle();
      expect(find.text('找到 0 项'), findsOneWidget);
      await tapText(tester, '章节序号');
      await tester.enterText(input, '451');
      await tester.pumpAndSettle();
      expect(find.text('目录第 451 项'), findsNWidgets(2));
      expect(find.text('第451章 秘密线索已揭晓'), findsNothing);
      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();
      expect(jumps, isEmpty);
      await tapText(tester, '取消');
      await tester.tap(find.byType(ListTile));
      await tester.pumpAndSettle();
      await tapText(tester, '跳过去');
      expect(jumps, <int>[book.blocks[900].o]);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'corrected current locator uses source position not canonical index',
    (tester) async {
      book.directory.apply(
        detectDirectory(source, DirectoryRule.automatic, ''),
      );
      final int expected = book.directory.chapterAt(controller.start) + 1;
      expect(expected, greaterThan(200));
      expect(controller.chapter, 2);
      await show(tester, page: TocSearchPage(link: link));
      await tapText(tester, '定位当前章节');
      expect(find.text('目录第 $expected 项 · 当前章节'), findsOneWidget);
      expect(jumps, isEmpty);
    },
  );

  testWidgets(
    'back discards preview and repeated openings never mutate directory',
    (tester) async {
      await show(tester);
      final int start = controller.start;
      for (int i = 0; i < 2; i++) {
        await tapText(tester, '修正 TXT 目录');
        await preview(tester);
        await tester.tap(find.byTooltip('返回上一层'));
        await tester.pumpAndSettle();
        expect(book.directory.enabled, isFalse);
        expect(find.byType(DirectoryCorrectionPage), findsNothing);
        expect(controller.start, start);
      }
    },
  );

  testWidgets(
    'changing rule cancels preview and literal-prefix input is never regex',
    (tester) async {
      await show(tester, page: DirectoryCorrectionPage(link: link));
      await preview(tester);
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('directory-rule')),
      );
      await tester.tap(find.byKey(const ValueKey<String>('directory-rule')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义固定前缀').last);
      await tester.pumpAndSettle();
      expect(find.text('应用目录'), findsNothing);
      final Finder input = find.byKey(
        const ValueKey<String>('directory-prefix'),
      );
      await tester.enterText(input, r'^(a+)+$');
      await tapText(tester, '预览目录');
      for (
        int i = 0;
        i < 100 && find.text('正在识别…').evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.textContaining('没有找到标题。'), findsOneWidget);
      expect(find.text('应用目录'), findsNothing);
      expect(book.directory.enabled, isFalse);
      await tester.enterText(input, '第');
      await tapText(tester, '预览目录');
      for (
        int i = 0;
        i < 100 && find.text('正在识别…').evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.text('预览共 600 项 · 自定义固定前缀'), findsOneWidget);
      await tester.enterText(input, '不存在');
      await tester.pumpAndSettle();
      expect(find.text('应用目录'), findsNothing);
      expect(book.directory.enabled, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'closing during a scan cancels worker and reopening starts fresh',
    (tester) async {
      await show(tester);
      await tapText(tester, '修正 TXT 目录');
      await tester.tap(find.text('预览目录'));
      await tester.pump();
      await tester.tap(find.byTooltip('返回上一层'));
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      expect(book.directory.enabled, isFalse);
      expect(tester.takeException(), isNull);
      await tapText(tester, '修正 TXT 目录');
      await preview(tester);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'short hidden titles retain full-width rules without unused flex space',
    (tester) async {
      book.chapters[4].raw['title'] = '第5章 凶手现身';
      book.chapters[4].raw['spoil'] = true;
      await show(tester);
      final Finder title = find.text('第5章');
      expect(title, findsOneWidget);
      final Finder rule = find.byWidgetPredicate(
        (Widget widget) =>
            widget is Container &&
            widget.constraints?.maxHeight == 1 &&
            widget.color != null,
      );
      expect(rule, findsOneWidget);
      final Rect labelBounds = tester.getRect(title);
      final Rect ruleBounds = tester.getRect(rule);
      expect(ruleBounds.left, closeTo(labelBounds.right + 10, .01));
      expect(ruleBounds.width, greaterThan(200));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('corrected directory unread warning wraps at narrow large text', (
    tester,
  ) async {
    controller.layout(controller.pager!, 0);
    book.directory.apply(detectDirectory(source, DirectoryRule.automatic, ''));
    await show(tester, size: const Size(320, 720), scale: 2);
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
    await tester.pumpAndSettle();
    final Finder label = find.text('目录第 8 项');
    await Scrollable.ensureVisible(tester.element(label), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(label);
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(find.text('会看到后面的内容')),
      alignment: .5,
    );
    await tester.pumpAndSettle();
    expect(jumps, isEmpty);
    expect(tester.takeException(), isNull);
    await tapText(tester, '取消');
    expect(find.text('跳过去'), findsNothing);
  });

  testWidgets('narrow correction drawer survives keyboard, close and reopen', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    await setTestViewport(tester, const Size(320, 720));
    addTearDown(() async {
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
      await setTestViewport(tester, null);
    });
    final int start = controller.start, cutoff = controller.cutoff;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  openSheet<void>(context, DirectoryCorrectionPage(link: link)),
              child: const Text('打开修正'),
            ),
          ),
        ),
      ),
    );
    for (int attempt = 0; attempt < 2; attempt++) {
      await tapText(tester, '打开修正');
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('directory-rule')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('directory-rule')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('自定义固定前缀').last);
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      final Finder input = find.byKey(
        const ValueKey<String>('directory-prefix'),
      );
      await tester.ensureVisible(input);
      await tester.enterText(input, '第');
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(SheetFrame)).bottom,
        lessThanOrEqualTo(440.01),
      );
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      // Header can scroll at very large text in a shallow drawer.
      tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!
          .jumpTo(0);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭阅读工具'));
      await tester.pumpAndSettle();
      expect(find.byType(SheetFrame), findsNothing);
      expect(book.directory.enabled, isFalse);
      expect(controller.start, start);
      expect(controller.cutoff, cutoff);
      expect(tester.takeException(), isNull);
    }
  });

  for (final double font in <double>[16, 32]) {
    testWidgets(
      'purified-away corrected heading and citations navigate forward at $font',
      (tester) async {
        final File canonical = File('${book.entry.dir.path}/book.json');
        final List<int> originalBytes = canonical.readAsBytesSync();
        final int start = controller.start, cutoff = controller.cutoff;
        final List<Chapter> originalChapters = book.chapters;
        controller.onPage(ReaderController.base);
        final File progressFile = File('${root.path}/progress.json');
        final List<int> savedProgress = progressFile.readAsBytesSync();
        book.notes.save(
          kind: 'note',
          start: 0,
          end: 3,
          cutoff: cutoff,
          text: '原文摘记',
        );
        final File notebook = File('${book.entry.dir.path}/notebook.json');
        final List<int> savedNotes = notebook.readAsBytesSync();
        book.directory.apply(
          detectDirectory(source, DirectoryRule.automatic, ''),
        );
        expect(controller.start, start);
        expect(controller.cutoff, cutoff);
        expect(progressFile.readAsBytesSync(), savedProgress);
        final Chapter target = book.directory.chapters[450];
        final Paginator pager = Paginator(
          book,
          PageSpec(
            width: 280,
            height: 220,
            fontSize: font,
            lineHeight: 1.6,
            fontFamily: null,
            color: Colors.black,
            textScaler: TextScaler.noScaling,
          ),
          rules: <PurificationRule>[
            PurificationRule(id: 'hide-target-heading', find: target.title),
            const PurificationRule(
              id: 'expand-body',
              find: '这里是正文📕。',
              replacement: '替换展示文字📚📚📚📚📚。',
            ),
          ],
        );
        controller.layout(pager, start);
        expect(pager.textFor(book.blocks[900]).text, isEmpty);
        expect(progressFile.readAsBytesSync(), savedProgress);
        // Directory jumps and direct source citations inside the removed heading
        // must land on text at/after that source, never on the previous page.
        for (final int offset in <int>[
          target.o0,
          target.o0 + 2,
          target.o0 + target.title.length - 1,
        ]) {
          final (int, int) sourceRange = (offset, offset + 1);
          controller.jump(offset, highlight: sourceRange);
          expect(controller.chapter, book.chapterAt(target.o0));
          expect(controller.chapter, 4);
          expect(controller.page!.end, greaterThan(offset));
          expect(controller.page!.start, lessThanOrEqualTo(book.blocks[901].o));
          expect(controller.flash, sourceRange);
          expect(controller.returnTo, start);
          expect(library.progressOf(book.id)!.pos, controller.start);
          expect(library.progressOf(book.id)!.cutoff, controller.cutoff);
          expect(controller.cutoff, lessThanOrEqualTo(book.length));
        }
        expect(book.directory.chapterAt(target.o0), 450);
        expect(book.chapters, same(originalChapters));
        final int jumpedStart = controller.start,
            jumpedCutoff = controller.cutoff;
        final List<int> jumpedProgress = progressFile.readAsBytesSync();
        book.directory.reset();
        expect(controller.start, jumpedStart);
        expect(controller.cutoff, jumpedCutoff);
        expect(progressFile.readAsBytesSync(), jumpedProgress);
        expect(book.directory.chapters, same(originalChapters));
        expect(pager.textFor(book.blocks[900]).text, isEmpty);
        expect(canonical.readAsBytesSync(), originalBytes);
        expect(notebook.readAsBytesSync(), savedNotes);
        expect(book.status.state, 'paused');
        expect(book.status.frontier, 20);
        final List<PageData> pages = pager.pages(controller.chapter);
        expect(
          pager.pageOf(
            controller.chapter,
            book.chapters[controller.chapter].o1,
          ),
          pages.length - 1,
        );
      },
    );
  }
  for (final Size size in <Size>[
    const Size(320, 720),
    const Size(540, 720),
    const Size(720, 540),
  ]) {
    testWidgets(
      'correction flows fit ${size.width} by ${size.height} at 2x text',
      (tester) async {
        await show(
          tester,
          page: DirectoryCorrectionPage(link: link),
          size: size,
          scale: 2,
        );
        await preview(tester);
        await tapText(tester, '应用目录');
        await tapText(tester, '恢复原目录');
        await tapText(tester, '确认恢复');
        expect(book.directory.enabled, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
