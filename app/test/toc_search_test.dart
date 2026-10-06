import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/seen.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/reader_controller.dart';
import 'package:thusfar_app/sheets/common.dart';
import 'package:thusfar_app/sheets/sheet_host.dart';
import 'package:thusfar_app/sheets/toc_search.dart';
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

  test('title search only matches the rendered safe label', () {
    final List<Chapter> chapters = <Chapter>[
      Chapter(0, <String, Object?>{'title': '前言', 'o0': 0}),
      Chapter(1, <String, Object?>{
        'title': '第2章 The Old Village',
        'spoil': false,
        'o0': 100,
      }),
      Chapter(2, <String, Object?>{
        'title': '第3章 秘密凶手',
        'spoil': true,
        'o0': 200,
      }),
      Chapter(3, <String, Object?>{'title': '第4章 主角身亡', 'o0': 300}),
      Chapter(4, <String, Object?>{
        'title': '没有章号的结局',
        'spoil': true,
        'o0': 400,
      }),
    ];
    List<Chapter> search(
      String query, {
      int readTo = 50,
      bool pending = false,
    }) =>
        findTocChapters(chapters, query, readTo: readTo, checkPending: pending);
    expect(search(' village '), <Chapter>[chapters[1]]);
    expect(search('秘密凶手'), isEmpty);
    expect(search('主角身亡'), isEmpty);
    expect(search('结局'), isEmpty);
    expect(search('第3章'), <Chapter>[chapters[2]]);
    expect(search('第 5 节'), <Chapter>[chapters[4]]);
    expect(search('秘密凶手', readTo: 201), <Chapter>[chapters[2]]);
    expect(search('秘密凶手', readTo: 200), isEmpty);
    expect(search('主角身亡', pending: true), isEmpty);
    expect(search(''), isEmpty);
    expect(search('   '), isEmpty);
  });

  test('ordinal lookup is one based, includes front matter, never clamps', () {
    final List<Chapter> chapters = List<Chapter>.generate(
      10000,
      (int i) => Chapter(i, <String, Object?>{
        'title': i == 0 ? '前言' : '第${i + 80}章 不同的标题章号',
        'o0': i * 100,
      }),
    );
    expect(tocChapterAtOrdinal(chapters, '1'), same(chapters.first));
    expect(tocChapterAtOrdinal(chapters, ' 09999 '), same(chapters[9998]));
    expect(tocChapterAtOrdinal(chapters, '10000'), same(chapters.last));
    for (final String input in <String>[
      '',
      '0',
      '-1',
      '10001',
      '1.5',
      '1e2',
      '第2章',
      '9' * 200,
    ]) {
      expect(tocChapterAtOrdinal(chapters, input), isNull, reason: input);
    }
    expect(tocChapterAtOrdinal(const <Chapter>[], '1'), isNull);
    expect(
      findTocChapters(chapters, '第10079章', readTo: 1, checkPending: false),
      <Chapter>[chapters.last],
    );
  });

  late Directory root;
  late BookData book;
  late Library library;
  late ReaderController controller;
  late ReaderLink link;
  late List<int> jumps;

  setUp(() {
    root = Directory.systemTemp.createTempSync('thusfar-toc-search-');
    final Directory dir = Directory('${root.path}/books/fixture')
      ..createSync(recursive: true);
    final List<Json> blocks = <Json>[];
    final List<Json> chapters = <Json>[];
    int offset = 0;
    for (int i = 0; i < 500; i++) {
      final String body = 'Chapter ${i + 1}. A short passage for navigation.';
      blocks.add(<String, Object?>{'k': 'p', 't': body, 'o': offset});
      chapters.add(<String, Object?>{
        'title': '第${i + 1}章 山间旅程',
        'spoil': false,
        'b0': i,
        'b1': i + 1,
        'o0': offset,
        'o1': offset + body.length,
        'kind': i == 0 ? 'front' : 'body',
      });
      offset += body.length;
    }
    chapters[0]['title'] = '前言';
    chapters[450]['title'] = '第451章 秘密凶手';
    chapters[450]['spoil'] = true;
    chapters[451]['title'] = '第452章 主角身亡';
    chapters[451].remove('spoil');
    final Json source = <String, Object?>{
      'title': '长目录',
      'lang': 'en',
      'len': offset,
      'notes': <String, Object?>{},
      'blocks': blocks,
      'chapters': chapters,
    };
    writeJson(File('${dir.path}/book.json'), source);
    writeJson(File('${dir.path}/status.json'), <String, Object?>{
      'state': 'idle',
    });
    library = Library(root);
    final BookEntry entry = BookEntry(
      id: 'fixture',
      dir: dir,
      meta: source,
      status: const ProcessStatus(<String, Object?>{'state': 'idle'}),
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
          height: 220,
          fontSize: 16,
          lineHeight: 1.6,
          fontFamily: null,
          color: Colors.black,
          textScaler: TextScaler.noScaling,
        ),
      ),
      book.chapters[229].o0,
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

  Future<ScrollController> showPage(
    WidgetTester tester, {
    bool directory = false,
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
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: SheetFrame(
            scroll: scroll,
            root: directory ? TocPage(link: link) : TocSearchPage(link: link),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return scroll;
  }

  Finder getInput() => find.byKey(const ValueKey<String>('toc-search-input'));

  Future<void> search(WidgetTester tester, String text) async {
    await tester.enterText(getInput(), text);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'search cannot expose hidden future titles through results or counts',
    (tester) async {
      final int start = controller.start;
      final int cutoff = controller.cutoff;
      await showPage(tester);
      final SemanticsHandle semantics = tester.ensureSemantics();
      for (final String hidden in <String>['秘密凶手', '主角身亡']) {
        await search(tester, hidden);
        expect(find.text('找到 0 项'), findsOneWidget);
        expect(find.byType(ListTile), findsNothing);
      }
      await search(tester, '第451章');
      final Finder safeLabel = find.descendant(
        of: find.byType(ListTile),
        matching: find.text('第451章'),
      );
      expect(safeLabel, findsOneWidget);
      expect(find.text('第451章 秘密凶手'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('.*秘密凶手.*')), findsNothing);
      await tester.tap(safeLabel);
      await tester.pumpAndSettle();
      expect(find.text('会看到后面的内容'), findsOneWidget);
      expect(jumps, isEmpty);
      expect(controller.start, start);
      expect(controller.cutoff, cutoff);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('会看到后面的内容'), findsNothing);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets(
    'ordinal jump previews exact chapter and requires existing unread warning',
    (tester) async {
      await showPage(tester);
      await tester.tap(find.text('章节序号'));
      await search(tester, '451');
      expect(find.text('目录第 451 项'), findsOneWidget);
      expect(find.text('第451章'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(jumps, isEmpty);
      expect(find.text('会看到后面的内容'), findsOneWidget);
      await tester.tap(find.text('跳过去'));
      expect(jumps, <int>[book.chapters[450].o0]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('invalid ordinals never jump or silently clamp', (tester) async {
    await showPage(tester);
    await tester.tap(find.text('章节序号'));
    for (final String value in <String>[
      '0',
      '501',
      '1.5',
      '-1',
      '第2章',
      '9' * 40,
    ]) {
      await search(tester, value);
      expect(find.text('请输入 1–500 之间的序号'), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.go);
      await tester.pumpAndSettle();
      expect(jumps, isEmpty);
      expect(find.text('跳过去'), findsNothing);
    }
  });

  testWidgets(
    'current chapter locator and known chapter jumps preserve source offsets',
    (tester) async {
      await showPage(tester);
      await tester.tap(find.text('定位当前章节'));
      await tester.pumpAndSettle();
      expect(find.text('目录第 230 项 · 当前章节'), findsOneWidget);
      expect(jumps, isEmpty);
      await tester.tap(find.text('第230章 山间旅程'));
      expect(jumps, <int>[book.chapters[229].o0]);
      expect(find.text('会看到后面的内容'), findsNothing);
      await search(tester, '1');
      await tester.testTextInput.receiveAction(TextInputAction.go);
      expect(jumps.last, 0);
    },
  );

  testWidgets(
    'repeated searches reset long-list scroll and cancel pending jumps',
    (tester) async {
      final ScrollController scroll = await showPage(tester);
      await search(tester, '山间');
      expect(find.text('找到 497 项'), findsOneWidget);
      scroll.jumpTo(10000);
      await tester.pumpAndSettle();
      await search(tester, '第499章');
      expect(scroll.offset, 0);
      expect(find.text('第499章 山间旅程'), findsOneWidget);
      await tester.tap(find.text('第499章 山间旅程'));
      await tester.pumpAndSettle();
      expect(find.text('会看到后面的内容'), findsOneWidget);
      await search(tester, '第498章');
      expect(find.text('跳过去'), findsNothing);
      await tester.tap(find.text('章节序号'));
      await tester.pumpAndSettle();
      expect(find.text('跳过去'), findsNothing);
      expect(tester.widget<TextField>(getInput()).controller!.text, isEmpty);
      await search(tester, '452');
      expect(find.text('第452章'), findsOneWidget);
      await tester.tap(find.byTooltip('清空章节查找'));
      await tester.pumpAndSettle();
      expect(find.text('输入序号定位章节'), findsOneWidget);
      expect(jumps, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Chinese composition waits for committed text', (tester) async {
    await showPage(tester);
    await search(tester, '第450章');
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '主角身亡',
        composing: TextRange(start: 0, end: 4),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('第450章 山间旅程'), findsOneWidget);
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: '主角身亡'),
    );
    await tester.pumpAndSettle();
    expect(find.text('找到 0 项'), findsOneWidget);
  });

  testWidgets(
    'read boundary and title verdict changes refresh existing search',
    (tester) async {
      await showPage(tester);
      await search(tester, '秘密凶手');
      expect(find.text('找到 0 项'), findsOneWidget);
      controller.jump(book.chapters[450].o0);
      await tester.pumpAndSettle();
      expect(find.text('第451章 秘密凶手'), findsOneWidget);
      await search(tester, '主角身亡');
      expect(find.text('找到 0 项'), findsOneWidget);
      book.chapters[451].raw['spoil'] = false;
      controller.touch();
      await tester.pumpAndSettle();
      expect(find.text('第452章 主角身亡'), findsOneWidget);
    },
  );

  testWidgets(
    'opening and cancelling search keeps directory position and reading location',
    (tester) async {
      final ScrollController scroll = await showPage(tester, directory: true);
      final int start = controller.start;
      scroll.jumpTo(5000);
      await tester.pumpAndSettle();
      final double before = scroll.offset;
      for (int attempt = 0; attempt < 2; attempt++) {
        await tester.tap(find.byTooltip('搜索目录或按章节序号跳转'));
        await tester.pumpAndSettle();
        await search(tester, '第400章');
        await tester.tap(find.byTooltip('返回上一层'));
        await tester.pumpAndSettle();
        expect(scroll.offset, before);
        expect(controller.start, start);
        expect(jumps, isEmpty);
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('narrow large-text controls and future warning do not overflow', (
    tester,
  ) async {
    book.chapters[450].raw['title'] = '第451章 很长很长的章名' * 8;
    book.chapters[450].raw['spoil'] = false;
    await showPage(tester, size: const Size(320, 720), scale: 2);
    await tester.tap(find.text('章节序号'));
    await search(tester, '451');
    await tester.tap(find.byType(ListTile));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('跳过去'));
    await tester.pumpAndSettle();
    expect(find.text('会看到后面的内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(jumps, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow drawer survives keyboard, back, close and reopen', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    await setTestViewport(tester, const Size(320, 720));
    addTearDown(() async {
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
      await setTestViewport(tester, null);
    });
    final int start = controller.start;
    final int cutoff = controller.cutoff;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        builder: (BuildContext context, Widget? child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => openSheet<void>(context, TocPage(link: link)),
              child: const Text('打开目录'),
            ),
          ),
        ),
      ),
    );
    for (int attempt = 0; attempt < 2; attempt++) {
      await tester.tap(find.text('打开目录'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('搜索目录或按章节序号跳转'));
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      await search(tester, '第400章');
      expect(
        tester.getRect(find.byType(SheetFrame)).bottom,
        lessThanOrEqualTo(440.01),
      );
      expect(tester.takeException(), isNull);
      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('返回上一层'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭阅读工具'));
      await tester.pumpAndSettle();
      expect(find.byType(SheetFrame), findsNothing);
      expect(controller.start, start);
      expect(controller.cutoff, cutoff);
      expect(jumps, isEmpty);
      expect(tester.takeException(), isNull);
    }
  });
}
