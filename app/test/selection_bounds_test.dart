import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/reader_controller.dart';
import 'package:thusfar_app/sheets/note_editor.dart';
import 'package:thusfar_app/ui/theme.dart';
import 'package:thusfar_core/notebook.dart' as notebook;

void main() {
  const String first = '可见文字😀随后还有未读内容';
  const String second = '另一段落的文字😀结尾';
  late Directory root;
  late Library library;
  late BookData book;
  late ReaderController controller;
  setUp(() {
    root = Directory.systemTemp.createTempSync('thusfar-selection-bounds-');
    final Directory directory = Directory('${root.path}/books/fixture')
      ..createSync(recursive: true);
    final Json raw = <String, Object?>{
      'title': 'Selection fixture',
      'lang': 'zh',
      'len': first.length + second.length,
      'notes': <String, Object?>{},
      'blocks': <Json>[
        <String, Object?>{'k': 'p', 't': first, 'o': 0},
        <String, Object?>{'k': 'p', 't': second, 'o': first.length},
      ],
      'chapters': <Json>[
        <String, Object?>{
          'title': '一',
          'kind': 'body',
          'b0': 0,
          'b1': 2,
          'o0': 0,
          'o1': first.length + second.length,
        },
      ],
    };
    writeJson(File('${directory.path}/book.json'), raw);
    library = Library(root);
    book = BookData.open(
      BookEntry(
        id: 'fixture',
        dir: directory,
        meta: raw,
        status: const ProcessStatus(<String, Object?>{'state': 'idle'}),
        added: 0,
      ),
    );
    controller = ReaderController(library: library, book: book);
  });
  tearDown(() {
    controller.dispose();
    book.notes.dispose();
    book.dispose();
    library.dispose();
    root.deleteSync(recursive: true);
  });

  void page(int start, int end) => controller.page = PageData(
    chapter: 0,
    index: 0,
    frags: <Frag>[],
    start: start,
    end: end,
  );

  test(
    'word expansion cannot select text before or after the visible page',
    () {
      page(1, 4);
      controller.select((0, first.length));
      expect(controller.selection, (1, 4));
      expect(
        notebook.sourceQuote(
          book.book,
          controller.selection!.$1,
          controller.selection!.$2,
        ),
        '见文字',
      );
    },
  );

  test('selection includes a complete visible emoji from either half', () {
    page(0, first.length);
    controller.select((4, 5));
    expect(controller.selection, (4, 6));
    expect(notebook.sourceQuote(book.book, 4, 6), '😀');
    controller.select((5, 6));
    expect(controller.selection, (4, 6));
  });

  test(
    'page boundaries inside a surrogate pair clip inward without leaking',
    () {
      page(0, 5);
      controller.select((0, 10));
      expect(controller.selection, (0, 4));
      expect(notebook.sourceQuote(book.book, 0, 4), '可见文字');
      page(5, 10);
      controller.select((4, 7));
      expect(controller.selection, (6, 7));
      expect(notebook.sourceQuote(book.book, 6, 7), '随');
      page(4, 5);
      controller.select((4, 5));
      expect(controller.selection, isNull);
    },
  );

  test(
    'forward drag across blocks stops at original block and saves a valid quote',
    () {
      page(0, book.length);
      controller.select((2, 4));
      controller.select((2, book.length), anchor: 2);
      expect(controller.selection, (2, first.length));
      final Json saved = book.notes.save(
        kind: 'note',
        start: controller.selection!.$1,
        end: controller.selection!.$2,
        cutoff: controller.cutoff,
      );
      expect(saved['quote'], first.substring(2));
      expect(saved['quote'], isNot(contains('另一段落')));
    },
  );

  test(
    'backward drag preserves its second-block anchor rather than selecting the previous paragraph',
    () {
      page(0, book.length);
      final int anchor = first.length + 3;
      controller.select((anchor, anchor + 2));
      controller.select((0, anchor + 2), anchor: anchor);
      expect(controller.selection, (first.length, anchor + 2));
      final Json saved = book.notes.save(
        kind: 'note',
        start: controller.selection!.$1,
        end: controller.selection!.$2,
        cutoff: controller.cutoff,
      );
      expect(saved['quote'], second.substring(0, 5));
    },
  );

  testWidgets(
    'note editor only displays the clipped selected word before cutoff',
    (WidgetTester tester) async {
      page(0, 4);
      // A word without punctuation extends beyond the final visible line.
      controller.select((0, first.length));
      final (int start, int end) = controller.selection!;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: NoteEditor(
              book: book,
              start: start,
              end: end,
              cutoff: controller.cutoff,
              draftDir: book.entry.dir,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('可见文字'), findsOneWidget);
      expect(find.textContaining('随后'), findsNothing);
      expect(find.textContaining('未读内容'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
