import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/purification_store.dart';
import 'package:thusfar_app/main.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/reader_controller.dart';
import 'package:thusfar_app/reader/text_purification.dart';

void main() {
  test(
    'picker import bounds advertised and streamed data before buffering',
    () async {
      var listened = false;
      final advertised = Stream<List<int>>.multi((controller) {
        listened = true;
        controller.close();
      });
      await expectLater(
        readPurificationImport(
          advertised,
          reportedSize: PurificationStore.maxImportBytes + 1,
        ),
        throwsFormatException,
      );
      expect(listened, isFalse);
      var cancelled = false;
      final controller = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
        },
      );
      final pending = readPurificationImport(controller.stream);
      final check = expectLater(pending, throwsFormatException);
      controller.add(List<int>.filled(PurificationStore.maxImportBytes, 32));
      controller.add(<int>[32]);
      await check;
      expect(cancelled, isTrue);
      await controller.close();
      expect(
        await readPurificationImport(
          Stream<List<int>>.fromIterable(<List<int>>[
            <int>[123],
            <int>[125],
          ]),
        ),
        '{}',
      );
      await expectLater(
        readPurificationImport(Stream<List<int>>.value(<int>[255])),
        throwsFormatException,
      );
    },
  );

  test('all valid maximum-size exported rule sets round-trip', () {
    final root = Directory.systemTemp.createTempSync(
      'purification-review-roundtrip',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    final store = PurificationStore(File('${root.path}/rules.json'));
    final target = PurificationStore(File('${root.path}/target.json'));
    addTearDown(store.dispose);
    addTearDown(target.dispose);
    for (var i = 0; i < 64; i++) {
      store.put(
        PurificationRule(
          id: '$i',
          find: '"' * 510 + '$i'.padLeft(2, '0'),
          replacement: '\\' * 512,
        ),
      );
    }
    final data = store.exportForBook('book');
    expect(data.length, greaterThan(128 * 1024));
    expect(target.importForBook(data, 'book'), 64);
  });

  testWidgets('layout at source start begins on the first expanded page', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync(
      'purification-review-pages',
    );
    final dir = Directory('${root.path}/books/review')
      ..createSync(recursive: true);
    final source = 'a' * 64;
    writeJson(File('${dir.path}/book.json'), <String, Object?>{
      'title': 'Review',
      'lang': 'en',
      'len': source.length,
      'notes': <String, Object?>{},
      'blocks': [
        <String, Object?>{'k': 'p', 't': source, 'o': 0},
      ],
      'chapters': [
        <String, Object?>{
          'title': 'One',
          'kind': 'body',
          'b0': 0,
          'b1': 1,
          'o0': 0,
          'o1': source.length,
        },
      ],
    });
    writeJson(File('${dir.path}/status.json'), <String, Object?>{
      'state': 'idle',
    });
    final model = AppModel(root);
    await model.library.scan();
    final book = BookData.open(model.library.books.single);
    addTearDown(() {
      book.notes.dispose();
      book.dispose();
      model.dispose();
      root.deleteSync(recursive: true);
    });
    final pager = Paginator(
      book,
      const PageSpec(
        width: 180,
        height: 100,
        fontSize: 16,
        lineHeight: 1.5,
        fontFamily: null,
        color: Colors.black,
        textScaler: TextScaler.noScaling,
      ),
      rules: [
        PurificationRule(id: 'r', find: source, replacement: 'word ' * 100),
      ],
    );
    final pages = pager.pages(0);

    expect(pages.length, greaterThan(1));
    final controller = ReaderController(library: model.library, book: book)
      ..layout(pager, 0);
    addTearDown(controller.dispose);
    expect(controller.page!.index, 0);
    for (int i = 1; i < pages.length; i++) {
      controller.onPage(ReaderController.base + i);
      expect(controller.page!.index, i);
    }
    // A citation jump goes to the first display occurrence of its source.
    controller.jump(0, remember: false);
    expect(controller.page!.index, 0);
    final plain = Paginator(book, pager.spec);
    final plainPages = plain.pages(0);
    if (plainPages.length > 1) {
      expect(plain.pageOf(0, plainPages[1].start), 1);
    }
  });
}
