import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/reader/paginator.dart';
import 'package:thusfar_app/reader/reader_controller.dart';

const _chapters = 4000;
const _pagesPerChapter = 12;
const _spec = PageSpec(
  width: 320,
  height: 500,
  fontSize: 18,
  lineHeight: 1.6,
  fontFamily: null,
  color: Colors.black,
  textScaler: TextScaler.noScaling,
);

// Isolate navigation from disk writes and shaping: all chapter pages are ready.
class _Library extends Library {
  _Library(super.root);
  int? savedStart;
  int? savedCutoff;
  @override
  void saveProgress(
    String id,
    int pos,
    int cutoff,
    int length, {
    double? timestamp,
    int? returnTo,
  }) {
    savedStart = pos;
    savedCutoff = cutoff;
  }
}

class _Pager extends Paginator {
  _Pager(BookData book) : super(book, _spec);
  int lookups = 0;
  final Map<int, List<PageData>> _pages = {};
  @override
  List<PageData> pages(int chapter) {
    lookups++;
    return _pages.putIfAbsent(
      chapter,
      () => [
        for (int i = 0; i < _pagesPerChapter; i++)
          PageData(
            chapter: chapter,
            index: i,
            frags: const [],
            start: chapter * _pagesPerChapter + i,
            end: chapter * _pagesPerChapter + i + 1,
          ),
      ],
    );
  }
}

void main() {
  late Directory root;
  late BookData book;
  late _Library library;
  late _Pager pager;
  late ReaderController reader;
  setUp(() {
    root = Directory.systemTemp.createTempSync('reader-navigation-');
    final dir = Directory('${root.path}/books/long')
      ..createSync(recursive: true);
    final Json source = {
      'title': 'Long book',
      'lang': 'en',
      'len': _chapters * _pagesPerChapter,
      'blocks': [
        for (int c = 0; c < _chapters; c++)
          {'k': 'p', 't': 'abcdefghijkl', 'o': c * _pagesPerChapter},
      ],
      'chapters': [
        for (int c = 0; c < _chapters; c++)
          {
            'title': 'Chapter $c',
            'b0': c,
            'b1': c + 1,
            'kind': 'body',
            'o0': c * _pagesPerChapter,
            'o1': (c + 1) * _pagesPerChapter,
          },
      ],
      'notes': <String, Object?>{},
    };
    writeJson(File('${dir.path}/book.json'), source);
    final entry = BookEntry(
      id: 'long',
      dir: dir,
      meta: source,
      status: const ProcessStatus({'state': 'idle'}),
      added: 0,
    );
    book = BookData.open(entry);
    library = _Library(root);
    pager = _Pager(book);
    // Warm pages before timing so both versions use the same cached geometry.
    for (int c = 0; c < _chapters; c++) {
      pager.pages(c);
    }
    reader = ReaderController(library: library, book: book)..layout(pager, 0);
    pager.lookups = 0;
  });
  tearDown(() {
    reader.dispose();
    book.notes.dispose();
    book.dispose();
    library.dispose();
    root.deleteSync(recursive: true);
  });

  test(
    'long-book sequential turns preserve virtual indexes and source offsets',
    () {
      final generationBeforeTurns = reader.generation;
      final watch = Stopwatch()..start();
      for (int i = 0; i < _chapters * _pagesPerChapter; i++) {
        reader.onPage(ReaderController.base + i);
        expect(reader.start, i);
        expect(reader.cutoff, i + 1);
      }
      watch.stop();
      // ignore: avoid_print
      print(
        'NAVIGATION_BENCH forward_us=${watch.elapsedMicroseconds} '
        'page_lookups=${pager.lookups} turns=${_chapters * _pagesPerChapter}',
      );
      expect(pager.lookups, lessThan(_chapters * _pagesPerChapter * 4));
      expect(reader.generation, generationBeforeTurns);
      expect(library.savedStart, _chapters * _pagesPerChapter - 1);
      expect(reader.pageAt(ReaderController.base - 1), isNull);
      expect(
        reader.pageAt(ReaderController.base + _chapters * _pagesPerChapter),
        isNull,
      );
      for (int i = _chapters * _pagesPerChapter - 1; i >= 0; i -= 7) {
        reader.onPage(ReaderController.base + i);
        expect(reader.start, i);
      }
      final generation = reader.generation;
      reader.jump(20001, highlight: (20001, 20002));
      expect(reader.generation, generation + 1);
      expect(reader.start, 20001);
      expect(reader.pageAt(ReaderController.base - 1)?.start, 20000);
      expect(reader.pageAt(ReaderController.base + 1)?.start, 20002);
      reader.layout(_Pager(book), 17);
      expect(reader.pageAt(ReaderController.base)?.start, 17);
      expect(reader.pageAt(ReaderController.base + 1)?.start, 18);
    },
  );

  test('chapter lookup retains exact boundaries and duplicate starts', () {
    for (int c = 0; c < _chapters; c += 17) {
      expect(book.chapterAt(c * _pagesPerChapter), c);
      expect(book.chapterAt((c + 1) * _pagesPerChapter - 1), c);
    }
    expect(book.chapterAt(-1), 0);
    expect(book.chapterAt(book.length), _chapters - 1);
    book.chapters[3].raw['o0'] = book.chapters[2].o0;
    expect(book.chapterAt(book.chapters[2].o0), 3);
  });
}
