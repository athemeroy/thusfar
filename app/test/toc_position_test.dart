import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/seen.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/reader_controller.dart';
import 'package:thusfar_app/sheets/common.dart';
import 'package:thusfar_app/sheets/sheet_host.dart';
import 'package:thusfar_app/sheets/toc_sheet.dart';
import 'package:thusfar_app/ui/theme.dart';

void main() {
  late Directory root;
  late BookData book;
  late ReaderController controller;
  late ReaderLink link;
  late Library library;

  setUp(() {
    root = Directory.systemTemp.createTempSync('thusfar-chapter-titles-');
    final Directory dir = Directory('${root.path}/books/fixture')
      ..createSync(recursive: true);
    const String text = 'A short chapter.';
    final Json source = <String, Object?>{
      'title': 'Long book',
      'lang': 'en',
      'len': text.length * 300,
      'notes': <String, Object?>{},
      'blocks': <Json>[
        for (int i = 0; i < 300; i++)
          <String, Object?>{'k': 'p', 't': text, 'o': i * text.length},
      ],
      'chapters': <Json>[
        for (int i = 0; i < 300; i++)
          <String, Object?>{
            'title': '第${i + 1}章',
            'spoil': false,
            'b0': i,
            'b1': i + 1,
            'o0': i * text.length,
            'o1': (i + 1) * text.length,
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
      229 * text.length,
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

  testWidgets('opens at chapter 230 and returns there from bookmarks', (
    tester,
  ) async {
    await showSheet(tester, TocPage(link: link));
    expect(find.text('第230章').hitTestable(), findsOneWidget);
    expect(find.text('第1章').hitTestable(), findsNothing);
    await tester.tap(find.text('书签'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    expect(find.text('第230章').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large text keeps the current chapter visible', (tester) async {
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(430, 1000),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: SheetFrame(
              scroll: scroll,
              root: TocPage(link: link),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('第230章').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
