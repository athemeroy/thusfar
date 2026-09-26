import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/seen.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/reader_controller.dart';
import 'package:thusfar_app/sheets/common.dart';
import 'package:thusfar_app/sheets/people_sheet.dart';
import 'package:thusfar_app/sheets/sheet_host.dart';
import 'package:thusfar_app/ui/theme.dart';

void main() {
  testWidgets('people search stays visible when returning to the all tab', (
    WidgetTester tester,
  ) async {
    const String text = 'Alice saw a fox. Bob follows.';
    final Directory root = Directory.systemTemp.createTempSync(
      'people-search-',
    );
    final Directory directory = Directory('${root.path}/books/fixture')
      ..createSync(recursive: true);
    writeJson(File('${directory.path}/book.json'), <String, Object?>{
      'title': 'Search fixture',
      'len': text.length,
      'lang': 'en',
      'notes': <String, Object?>{},
      'blocks': <Json>[
        <String, Object?>{'k': 'p', 't': text, 'o': 0},
      ],
      'chapters': <Json>[
        <String, Object?>{
          'title': 'One',
          'b0': 0,
          'b1': 1,
          'o0': 0,
          'o1': text.length,
          'kind': 'body',
        },
      ],
    });
    writeJson(File('${directory.path}/status.json'), <String, Object?>{
      'state': 'idle',
      'frontier': 0,
    });
    final Library library = Library(root);
    await library.scan();
    SeenStore.instance.attach(File('${root.path}/seen.json'));
    final BookData book = BookData.open(library.books.single);
    for (final String name in <String>['Alice', 'Bob']) {
      book.saveManual(<String, Object?>{
        'id': 'person$name',
        'kind': 'person',
        'name': name,
        'note': 'A visible fixture person',
        'knowledge_cutoff': text.length,
        'expected_revision': 0,
        'operation': 'operation$name',
        'deleted': false,
      });
    }
    final ReaderController reader = ReaderController(
      library: library,
      book: book,
    );
    reader.layout(
      Paginator(
        book,
        const PageSpec(
          width: 350,
          height: 500,
          fontSize: 16,
          lineHeight: 1.7,
          fontFamily: null,
          color: Colors.black,
          textScaler: TextScaler.noScaling,
        ),
      ),
      0,
    );
    reader.page = PageData(
      chapter: 0,
      index: 0,
      frags: <Frag>[],
      start: 0,
      end: text.length,
    );
    final ReaderLink link = ReaderLink(
      c: reader,
      jump: (int _, {(int, int)? highlight}) {},
      openAsk: ({String? prefill, String? quote}) {},
    );
    final ScrollController scroll = ScrollController();
    await tester.binding.setSurfaceSize(const Size(430, 1000));
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: SheetFrame(
              scroll: scroll,
              root: PeoplePage(link: link, tab: 2),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final Finder field = find.byKey(const ValueKey<String>('people-search'));
      expect(find.text('Bob'), findsOneWidget);
      await tester.enterText(field, 'Alice');
      await tester.pumpAndSettle();
      expect(find.text('Bob'), findsNothing);

      await tester.tap(find.text('本章'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, 'Alice');
      expect(find.text('Bob'), findsNothing);

      await tester.enterText(field, '');
      await tester.pumpAndSettle();
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('Alice'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.binding.setSurfaceSize(null);
      scroll.dispose();
      reader.dispose();
      book.notes.dispose();
      book.dispose();
      library.dispose();
      root.deleteSync(recursive: true);
    }
  });
}
