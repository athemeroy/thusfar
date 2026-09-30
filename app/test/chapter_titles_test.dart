import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/seen.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/reader_controller.dart';
import 'package:thusfar_app/sheets/common.dart';
import 'package:thusfar_app/sheets/preview_sheet.dart';
import 'package:thusfar_app/sheets/search_sheet.dart';
import 'package:thusfar_app/sheets/sheet_host.dart';
import 'package:thusfar_app/sheets/toc_sheet.dart';
import 'package:thusfar_app/ui/theme.dart';

void main() {
  Future<void> loadFont(String family, String path) async {
    await (FontLoader(family)..addFont(
          Future<ByteData>.value(
            ByteData.sublistView(File(path).readAsBytesSync()),
          ),
        ))
        .load();
  }

  test('unread titles follow their individual spoiler verdict', () {
    Chapter chapter(Object? spoiler) {
      final Json raw = <String, Object?>{'title': '第2章 旧城'};
      if (spoiler != null) raw['spoil'] = spoiler;
      return Chapter(1, raw);
    }

    expect(safeTitle(chapter(false), false), '第2章 旧城');
    expect(safeTitle(chapter(true), false), '第2章');
    expect(safeTitle(chapter(null), false), '第2章 旧城');
    expect(safeTitle(chapter('false'), false), '第2章 旧城');
    expect(safeTitle(chapter(true), false, checkPending: true), '第2章 旧城');
    expect(
      safeTitle(Chapter(2, <String, Object?>{'title': '第3章 主角身亡'}), false),
      '第3章',
    );
    expect(safeTitle(chapter(true), true), '第2章 旧城');
    expect(
      safeTitle(
        Chapter(2, <String, Object?>{'title': '主角身亡', 'spoil': true}),
        false,
      ),
      '第 3 节',
    );
  });

  late Directory root;
  late BookData book;
  late ReaderController controller;
  late ReaderLink link;
  late Library library;
  late int secondStart;
  late int thirdStart;

  setUp(() {
    root = Directory.systemTemp.createTempSync('thusfar-chapter-titles-');
    final Directory dir = Directory('${root.path}/books/fixture')
      ..createSync(recursive: true);
    const String first = 'A known page.';
    const String second = 'The needle is in the village.';
    const String third = 'The needle points at the ending.';
    secondStart = first.length;
    thirdStart = first.length + second.length;
    final Json source = <String, Object?>{
      'title': 'Title policy fixture',
      'lang': 'en',
      'len': first.length + second.length + third.length,
      'notes': <String, Object?>{},
      'blocks': <Json>[
        <String, Object?>{'k': 'p', 't': first, 'o': 0},
        <String, Object?>{'k': 'p', 't': second, 'o': secondStart},
        <String, Object?>{'k': 'p', 't': third, 'o': thirdStart},
      ],
      'chapters': <Json>[
        <String, Object?>{
          'title': '第1章 开始',
          'spoil': false,
          'b0': 0,
          'b1': 1,
          'o0': 0,
          'o1': secondStart,
          'kind': 'body',
        },
        <String, Object?>{
          'title': '第2章 旧城',
          'spoil': false,
          'b0': 1,
          'b1': 2,
          'o0': secondStart,
          'o1': thirdStart,
          'kind': 'body',
        },
        <String, Object?>{
          'title': '第3章 主角身亡',
          'spoil': true,
          'b0': 2,
          'b1': 3,
          'o0': thirdStart,
          'o1': first.length + second.length + third.length,
          'kind': 'body',
        },
      ],
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
      0,
    );
    link = ReaderLink(
      c: controller,
      jump: (int _, {(int, int)? highlight}) {},
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

  Future<void> showSheet(
    WidgetTester tester,
    Widget page, {
    Size size = const Size(430, 1000),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: SheetFrame(scroll: scroll, root: page),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the table of contents shows safe future titles only', (
    tester,
  ) async {
    await showSheet(tester, TocPage(link: link));
    expect(find.textContaining('章节标题尚待核对'), findsNothing);
    expect(find.text('第2章 旧城'), findsOneWidget);
    expect(find.text('第3章 主角身亡'), findsNothing);
    expect(find.text('第3章'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('title retry notice is book-wide and keeps chapter verdicts', (
    tester,
  ) async {
    final String sdkRoot =
        Platform.environment['FLUTTER_ROOT'] ??
        '${Platform.environment['HOME']}/.local/share/flutter';
    await loadFont(
      'MaterialIcons',
      '$sdkRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
    );
    await loadFont(
      'Roboto',
      Platform.environment['THUSFAR_TEST_SANS_FONT'] ??
          '${Platform.environment['HOME']}/.local/share/fonts/NotoSansSC.ttf',
    );
    await loadFont('NotoSansSC', 'assets/fonts/NotoSansSC.ttf');
    book.entry.status = const ProcessStatus(<String, Object?>{
      'state': 'paused',
      'quality': <String, Object?>{
        'state': 'pending',
        'pending': <String>['bio-0', 'chapter-titles'],
      },
    });
    await showSheet(tester, TocPage(link: link));
    expect(find.text('章节标题尚待核对，明显剧透的标题暂时隐藏。可在书籍整理页重试。'), findsOneWidget);
    expect(find.text('第2章 旧城'), findsOneWidget);
    expect(find.text('第3章 主角身亡'), findsNothing);
    expect(find.text('第3章'), findsOneWidget);
    await expectLater(
      find.byType(SheetFrame),
      matchesGoldenFile('shots/title-pending-toc.png'),
    );

    book.entry.status = const ProcessStatus(<String, Object?>{
      'state': 'paused',
      'quality': <String, Object?>{
        'state': 'pending',
        'pending': <String>['bio-0'],
      },
    });
    controller.touch();
    await tester.pumpAndSettle();
    expect(find.textContaining('章节标题尚待核对'), findsNothing);

    book.entry.status = const ProcessStatus(<String, Object?>{
      'state': 'paused',
      'quality': <String, Object?>{'pending': true},
    });
    controller.touch();
    await tester.pumpAndSettle();
    expect(find.textContaining('章节标题尚待核对'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long safe title fits a narrow table of contents', (
    tester,
  ) async {
    const String longTitle = '第2章 一座很远很远的旧城和一段还没有讲完的旅程';
    book.chapters[1].raw['title'] = longTitle;
    await showSheet(tester, TocPage(link: link), size: const Size(320, 800));
    expect(find.text(longTitle), findsOneWidget);
    expect(tester.widget<Text>(find.text(longTitle)).maxLines, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('whole-book search headings use the same title policy', (
    tester,
  ) async {
    await showSheet(tester, SearchPage(link: link));
    await tester.enterText(find.byType(TextField), 'needle');
    await tester.tap(find.text('全书'));
    await tester.pumpAndSettle();
    expect(find.text('第2章 旧城'), findsOneWidget);
    expect(find.text('第3章 主角身亡'), findsNothing);
    expect(find.text('第3章'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a locked preview can show a safe future title', (tester) async {
    await showSheet(
      tester,
      PreviewPage(link: link, start: secondStart, end: secondStart + 1),
    );
    expect(find.textContaining('第2章 旧城'), findsOneWidget);
    expect(find.textContaining('你还没读到'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a locked preview hides a spoiling future title', (tester) async {
    await showSheet(
      tester,
      PreviewPage(link: link, start: thirdStart, end: thirdStart + 1),
    );
    expect(find.textContaining('第3章 主角身亡'), findsNothing);
    expect(find.textContaining('第3章'), findsOneWidget);
    expect(find.textContaining('你还没读到'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
