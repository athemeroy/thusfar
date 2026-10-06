import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/backup.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/reader_directory.dart';
import 'package:thusfar_app/sheets/chapter_title.dart';

Json _bookFor(List<String> lines, {List<Json>? chapters}) {
  int offset = 0;
  final List<Json> blocks = <Json>[];
  for (final String line in lines) {
    blocks.add(<String, Object?>{'k': 'p', 't': line, 'o': offset});
    offset += line.length + 1;
  }
  final int length = offset == 0 ? 0 : offset - 1;
  return <String, Object?>{
    'title': '目录修正测试',
    'lang': 'zh',
    'len': length,
    'notes': <String, Object?>{'original': '原书脚注'},
    'blocks': blocks,
    'chapters':
        chapters ??
        <Json>[
          <String, Object?>{
            'title': '原目录',
            'b0': 0,
            'b1': blocks.length,
            'o0': 0,
            'o1': length,
            'kind': 'body',
          },
        ],
  };
}

List<String> _titles(DirectoryPreview preview) =>
    preview.rows.map((Json row) => row['title']! as String).toList();

class _DirectoryFixture {
  _DirectoryFixture({List<String>? lines, List<Json>? chapters}) {
    final List<String> source =
        lines ??
        <String>[
          '序言😀',
          '第一章 故事开始',
          '正文第一段。',
          'Chapter II A meeting',
          '正文第二段。',
          '002 数字章节',
          '正文第三段。',
        ];
    dir.createSync(recursive: true);
    final Json raw = _bookFor(source, chapters: chapters);
    writeJson(file('book.json'), raw);
    file('source.txt').writeAsStringSync(source.join('\n'));
    writeJson(file('meta.json'), <String, Object?>{'filename': 'original.TXT'});
    writeJson(file('status.json'), <String, Object?>{
      'state': 'done',
      'frontier': raw['len'],
      'done': 1,
      'total': 1,
    });
    writeJson(file('kg.json'), <String, Object?>{
      'log': <Json>[
        <String, Object?>{'t': 'person', 'id': 'P1', 'name': '人物甲', 'p': 0},
      ],
    });
    writeJson(file('plan.json'), <String, Object?>{
      'chapters': <int>[0],
      'budget': 42,
    });
    writeJson(file('mentions/0000.json'), <Object?>[
      <Object?>[0, 2, 'P1', 0],
    ]);
    writeJson(File('${root.path}/progress.json'), <String, Object?>{
      'fixture': <String, Object?>{'pos': 2, 'cutoff': 4, 'pct': 0.1, 't': 10},
    });
    entry = BookEntry(
      id: 'fixture',
      dir: dir,
      meta: raw,
      status: ProcessStatus(readJson(file('status.json'))! as Json),
      added: 0,
    );
    book = open();
  }

  final Directory root = Directory.systemTemp.createTempSync(
    'thusfar-directory-',
  );
  late final Directory dir = Directory('${root.path}/books/fixture');
  late final BookEntry entry;
  late final BookData book;
  final List<BookData> _opened = <BookData>[];

  File file(String name) => File('${dir.path}/$name');

  BookData open() {
    final BookData data = BookData.open(entry);
    _opened.add(data);
    return data;
  }

  DirectoryPreview scan(DirectoryRule rule, [String prefix = '']) =>
      detectDirectory(book.book, rule, prefix);

  Map<String, List<int>> durableBytes() => <String, List<int>>{
    for (final File file in root.listSync(recursive: true).whereType<File>())
      if (!file.path.endsWith('/reader-directory.json'))
        file.path.substring(root.path.length): file.readAsBytesSync(),
  };

  void dispose() {
    for (final BookData data in _opened) {
      data.directory.dispose();
      data.notes.dispose();
      data.dispose();
    }
    root.deleteSync(recursive: true);
  }
}

void main() {
  group('fixed, bounded directory detection', () {
    test(
      'custom prefixes are literal, including regular-expression syntax',
      () {
        final Json book = _bookFor(<String>[
          r'^第.*章 literal heading',
          '第一章 not a literal match',
          '(a+)+\$ literal heading',
          'aaaaaaaaaaaaaaaaaaaaaaaa!',
          '[x] literal heading',
          'x not a literal match',
        ]);
        expect(
          _titles(detectDirectory(book, DirectoryRule.prefix, r'  ^第.*章  ')),
          <String>[r'^第.*章 literal heading'],
        );
        expect(
          _titles(detectDirectory(book, DirectoryRule.prefix, r'(a+)+$')),
          <String>[r'(a+)+$ literal heading'],
        );
        expect(
          _titles(detectDirectory(book, DirectoryRule.prefix, '[x]')),
          <String>['[x] literal heading'],
        );
      },
    );

    test('empty, multiline, and oversized custom prefixes are rejected', () {
      final Json book = _bookFor(<String>['第一章 开始']);
      for (final String prefix in <String>['', '   ', '第\n章', 'x' * 33]) {
        expect(
          () => detectDirectory(book, DirectoryRule.prefix, prefix),
          throwsFormatException,
          reason: 'Invalid literal prefix: ${jsonEncode(prefix)}',
        );
      }
      expect(
        detectDirectory(
          _bookFor(<String>['x' * 32]),
          DirectoryRule.prefix,
          'x' * 32,
        ).rows,
        hasLength(1),
      );
    });

    test(
      'presets match their own formats and automatic combines known formats',
      () {
        final Json book = _bookFor(<String>[
          '第一章 开始',
          '第 2 回 再会',
          '第參節 后续',
          '第三篇 附录',
          '第一卷 风起',
          '第两部 日落',
          '第3集 清晨',
          'Chapter 12: Arrival',
          'PART IV The journey',
          'book ii. Home',
          '001 数字开头',
          '12、标点数字',
          '8: English numbered',
          '9-Another numbered',
          '10. Final numbered',
          '正文章节字样不在开头',
          'chapter twelve not a numeral',
          '123456789 too many digits',
          '001',
        ]);
        final List<String> chinese = <String>[
          '第一章 开始',
          '第 2 回 再会',
          '第參節 后续',
          '第三篇 附录',
        ];
        final List<String> volumes = <String>['第一卷 风起', '第两部 日落', '第3集 清晨'];
        final List<String> english = <String>[
          'Chapter 12: Arrival',
          'PART IV The journey',
          'book ii. Home',
        ];
        expect(
          _titles(detectDirectory(book, DirectoryRule.chinese, '')),
          chinese,
        );
        expect(
          _titles(detectDirectory(book, DirectoryRule.volumes, '')),
          volumes,
        );
        expect(
          _titles(detectDirectory(book, DirectoryRule.english, '')),
          english,
        );
        expect(
          _titles(detectDirectory(book, DirectoryRule.numbered, '')),
          <String>[
            '001 数字开头',
            '12、标点数字',
            '8: English numbered',
            '9-Another numbered',
            '10. Final numbered',
          ],
        );
        expect(
          _titles(detectDirectory(book, DirectoryRule.automatic, '')),
          <String>[...chinese, ...volumes, ...english],
        );
      },
    );

    test('finds all 600 headings without a display-sized truncation', () {
      final List<String> lines = <String>[
        for (int i = 1; i <= 600; i++) ...<String>['第$i章 标题$i', '正文$i'],
      ];
      final DirectoryPreview preview = detectDirectory(
        _bookFor(lines),
        DirectoryRule.chinese,
        '',
      );
      expect(preview.rows, hasLength(600));
      expect(preview.rows.first, <String, Object?>{
        'title': '第1章 标题1',
        'offset': 0,
      });
      expect(preview.rows.last['title'], '第600章 标题600');
      expect(
        preview.rows.last['offset'],
        lines
            .take(1198)
            .fold<int>(
              0,
              (int offset, String line) => offset + line.length + 1,
            ),
      );
    });

    test('preserves UTF-16 offsets and trimmed heading ends after emoji', () {
      final _DirectoryFixture fixture = _DirectoryFixture(
        lines: <String>['😀序言𠮷', '  第1章 😀相遇𠮷  ', '段落😀', '  第2章 归来😀  '],
      );
      addTearDown(fixture.dispose);
      final DirectoryPreview preview = fixture.scan(DirectoryRule.chinese);
      final int firstOffset = '😀序言𠮷'.length + 1 + 2;
      final int secondOffset = '😀序言𠮷\n  第1章 😀相遇𠮷  \n段落😀\n'.length + 2;
      expect(preview.rows, <Json>[
        <String, Object?>{'title': '第1章 😀相遇𠮷', 'offset': firstOffset},
        <String, Object?>{'title': '第2章 归来😀', 'offset': secondOffset},
      ]);
      final List<Chapter> entries = fixture.book.directory.previewEntries(
        preview.rows,
      );
      expect(entries.first.title, '开始');
      expect(entries.first.o0, 0);
      expect(entries.first.o1, firstOffset);
      final DirectoryChapter first = entries[1] as DirectoryChapter;
      expect(first.titleEnd, firstOffset + '第1章 😀相遇𠮷'.length);
      expect(tocTitleRead(first, first.o0 + 1), isFalse);
      expect(tocTitleRead(first, first.titleEnd - 1), isFalse);
      expect(tocTitleRead(first, first.titleEnd), isTrue);
      expect(fixture.book.textBetween(first.o0, first.titleEnd), first.title);
      expect(tocTitleRead(entries.first, 0), isTrue);
    });

    test(
      'skips oversized blocks before matching and ignores non-text blocks',
      () {
        final String boundary = '第1章 ${'字' * (directoryTitleLimit - 4)}';
        expect(boundary.length, directoryTitleLimit);
        final Json book = _bookFor(<String>[
          boundary,
          '第2章 ${'字' * directoryTitleLimit}',
          '  ',
          '正文',
        ]);
        (book['blocks']! as List<Json>).add(<String, Object?>{
          'k': 'img',
          't': '第3章 图片说明',
          'o': book['len'],
        });
        final DirectoryPreview preview = detectDirectory(
          book,
          DirectoryRule.chinese,
          '',
        );
        expect(_titles(preview), <String>[boundary]);
        expect(preview.skippedLong, 1);
      },
    );

    test(
      'accepts 10000 headings but rejects the 10001st rather than truncating',
      () {
        final Json book = _bookFor(<String>[
          for (int i = 1; i <= directoryHeadingLimit; i++) '第$i章 标题',
        ]);
        expect(
          detectDirectory(book, DirectoryRule.chinese, '').rows,
          hasLength(10000),
        );
        (book['blocks']! as List<Json>).add(<String, Object?>{
          'k': 'p',
          't': '第10001章 标题',
          'o': (book['len']! as int) + 1,
        });
        expect(
          () => detectDirectory(book, DirectoryRule.chinese, ''),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('10000'),
            ),
          ),
        );
      },
    );
  });

  group('killable isolate scan', () {
    late _DirectoryFixture fixture;
    setUp(() => fixture = _DirectoryFixture());
    tearDown(() => fixture.dispose());

    test('returns the same source positions as a direct scan', () async {
      final DirectoryScan scan = DirectoryScan(
        fixture.dir.path,
        DirectoryRule.automatic,
        '',
      );
      final DirectoryPreview? result = await scan.result;
      expect(result, isNotNull);
      expect(result!.rows, fixture.scan(DirectoryRule.automatic).rows);
      expect(result.skippedLong, 0);
      scan.cancel();
      expect(await scan.result, same(result));
    });

    test('scans a 10-million-character TXT through its worker isolate', () async {
      const int targetLength = 10000000;
      final String paragraph = ('春天到了，两人沿着河岸向前走。村里的灯火渐渐亮起，远处传来熟悉的歌声。' * 20)
          .substring(0, 400);
      final List<String> lines = <String>[];
      final List<Json> expected = <Json>[];
      int nextOffset = 0;
      int skippedLong = 0;
      void append(String text) {
        lines.add(text);
        nextOffset += text.length + 1;
        if (text.length > directoryTitleLimit) skippedLong++;
      }

      for (int i = 1; i <= 600; i++) {
        final String title = '第$i章 河岸边的故事';
        expected.add(<String, Object?>{'title': title, 'offset': nextOffset});
        append(title);
        for (int p = 0; p < 40; p++) {
          append(paragraph);
        }
      }
      // Fill the remainder with ordinary paragraphs, keeping exact source offsets.
      while (nextOffset + paragraph.length < targetLength) {
        append(paragraph);
      }
      if (nextOffset < targetLength) {
        append(paragraph.substring(0, targetLength - nextOffset));
      }
      final _DirectoryFixture large = _DirectoryFixture(lines: lines);
      addTearDown(large.dispose);
      expect(large.book.length, targetLength);
      expect(large.book.blocks.length, greaterThan(24000));
      // Do not run detectDirectory here: file decoding and matching must use
      // DirectoryScan's real isolate, just as the reader's preview does.
      final DirectoryScan scan = DirectoryScan(
        large.dir.path,
        DirectoryRule.chinese,
        '',
      );
      addTearDown(scan.cancel);
      final DirectoryPreview? result = await scan.result;
      expect(result, isNotNull);
      expect(result!.rows, expected);
      expect(result.rows, hasLength(600));
      expect(result.skippedLong, skippedLong);
      expect(large.file('reader-directory.json').existsSync(), isFalse);
    });

    test(
      'cancel then immediately start a new scan without leaking the old result',
      () async {
        final Map<String, List<int>> before = fixture.durableBytes();
        final DirectoryScan canceled = DirectoryScan(
          fixture.dir.path,
          DirectoryRule.chinese,
          '',
        );
        canceled.cancel();
        final DirectoryScan fresh = DirectoryScan(
          fixture.dir.path,
          DirectoryRule.numbered,
          '',
        );
        addTearDown(fresh.cancel);
        expect(await canceled.result, isNull);
        final DirectoryPreview? result = await fresh.result;
        expect(result, isNotNull);
        expect(result!.rule, DirectoryRule.numbered);
        expect(_titles(result), <String>['002 数字章节']);
        expect(await canceled.result, isNull);
        expect(fixture.file('reader-directory.json').existsSync(), isFalse);
        expect(fixture.durableBytes(), before);
      },
    );

    test(
      'immediate and repeated cancellation resolve to null without writes',
      () async {
        final Map<String, List<int>> before = fixture.durableBytes();
        final DirectoryScan scan = DirectoryScan(
          fixture.dir.path,
          DirectoryRule.automatic,
          '',
        );
        scan.cancel();
        scan.cancel();
        expect(await scan.result, isNull);
        expect(fixture.file('reader-directory.json').existsSync(), isFalse);
        expect(fixture.durableBytes(), before);
      },
    );

    test(
      'timeout reports failure and leaves an applied directory intact',
      () async {
        final ReaderDirectory directory = fixture.book.directory;
        directory.apply(fixture.scan(DirectoryRule.chinese));
        final List<Chapter> previous = directory.chapters;
        final List<int> sidecar = fixture
            .file('reader-directory.json')
            .readAsBytesSync();
        final DirectoryScan scan = DirectoryScan(
          fixture.dir.path,
          DirectoryRule.automatic,
          '',
          timeout: Duration.zero,
        );
        await expectLater(
          scan.result,
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('超时'),
            ),
          ),
        );
        scan.cancel();
        expect(directory.chapters, same(previous));
        expect(
          fixture.file('reader-directory.json').readAsBytesSync(),
          sidecar,
        );
      },
    );

    test(
      'worker decoding and input errors become failures without sidecars',
      () async {
        fixture.file('book.json').writeAsStringSync('{invalid');
        final DirectoryScan invalidJson = DirectoryScan(
          fixture.dir.path,
          DirectoryRule.automatic,
          '',
        );
        await expectLater(invalidJson.result, throwsFormatException);
        fixture
            .file('book.json')
            .writeAsStringSync(jsonEncode(fixture.book.book));
        final DirectoryScan invalidPrefix = DirectoryScan(
          fixture.dir.path,
          DirectoryRule.prefix,
          '',
        );
        await expectLater(invalidPrefix.result, throwsFormatException);
        final DirectoryScan missingFile = DirectoryScan(
          '${fixture.dir.path}/missing',
          DirectoryRule.automatic,
          '',
        );
        await expectLater(missingFile.result, throwsFormatException);
        expect(fixture.file('reader-directory.json').existsSync(), isFalse);
        expect(fixture.book.directory.enabled, isFalse);
      },
    );
  });

  group('navigation-only sidecar', () {
    late _DirectoryFixture fixture;
    setUp(() => fixture = _DirectoryFixture());
    tearDown(() => fixture.dispose());

    test('apply, reapply, reopen, and reset affect only navigation', () {
      fixture.book.notes.save(
        kind: 'note',
        start: 0,
        end: 2,
        cutoff: 4,
        text: '原有摘记',
      );
      final Map<String, List<int>> before = fixture.durableBytes();
      final String rawBefore = jsonEncode(fixture.book.book);
      final String chaptersBefore = jsonEncode(
        fixture.book.chapters.map((c) => c.raw).toList(),
      );
      final String recordsBefore = jsonEncode(fixture.book.records);
      final String notesBefore = jsonEncode(fixture.book.notes.items);
      final List<Chapter> original = fixture.book.chapters;
      final ProcessStatus status = fixture.book.status;
      final List<Mention> mentions = fixture.book.mentions(0);
      final ReaderDirectory directory = fixture.book.directory;
      int notifications = 0;
      directory.addListener(() => notifications++);
      expect(directory, same(fixture.book.directory));
      expect(directory.chapters, same(original));

      directory.apply(fixture.scan(DirectoryRule.automatic));
      expect(directory.enabled, isTrue);
      expect(directory.chapters.map((c) => c.title), <String>[
        '开始',
        '第一章 故事开始',
        'Chapter II A meeting',
      ]);
      expect(directory.chapterAt(0), 0);
      expect(directory.chapterAt(directory.chapters[1].o0 - 1), 0);
      expect(directory.chapterAt(directory.chapters[1].o0), 1);
      expect(directory.chapterAt(fixture.book.length), 2);
      expect(
        () => directory.chapters.add(original.first),
        throwsUnsupportedError,
      );

      final BookData reopened = fixture.open();
      expect(reopened.directory.enabled, isTrue);
      expect(reopened.directory.rule, DirectoryRule.automatic);
      expect(
        reopened.directory.chapters.map((c) => c.title),
        directory.chapters.map((c) => c.title),
      );
      directory.apply(fixture.scan(DirectoryRule.prefix, '  002  '));
      expect(directory.rule, DirectoryRule.prefix);
      expect(directory.prefix, '002');
      expect(directory.chapters.map((c) => c.title), <String>[
        '开始',
        '002 数字章节',
      ]);
      final BookData reapplied = fixture.open();
      expect(reapplied.directory.prefix, '002');
      expect(reapplied.directory.chapters.last.title, '002 数字章节');

      directory.reset();
      expect(directory.enabled, isFalse);
      expect(directory.chapters, same(original));
      expect(directory.rule, DirectoryRule.automatic);
      expect(directory.prefix, isEmpty);
      expect(directory.error, isNull);
      expect(notifications, 3);
      final BookData reset = fixture.open();
      expect(reset.directory.enabled, isFalse);
      expect(reset.directory.chapters, same(reset.chapters));
      expect(reset.directory.error, isNull);
      expect(
        (readJson(fixture.file('reader-directory.json'))! as Json)['enabled'],
        isFalse,
      );
      expect(
        fixture.durableBytes(),
        before,
        reason:
            'Book, raw source, notes, progress, status, graph, plan, and mentions must remain byte-identical',
      );
      expect(jsonEncode(fixture.book.book), rawBefore);
      expect(
        jsonEncode(fixture.book.chapters.map((c) => c.raw).toList()),
        chaptersBefore,
      );
      expect(jsonEncode(fixture.book.records), recordsBefore);
      expect(jsonEncode(fixture.book.notes.items), notesBefore);
      expect(fixture.book.chapters, same(original));
      expect(fixture.book.status, same(status));
      expect(fixture.book.mentions(0), same(mentions));
      expect(fixture.book.chapterAt(fixture.book.length), 0);
    });

    test(
      'preset scans discard stale custom prefixes and persist a reopenable sidecar',
      () async {
        final String stalePrefix = '😀' * 32;
        final DirectoryPreview direct = detectDirectory(
          fixture.book.book,
          DirectoryRule.automatic,
          stalePrefix,
        );
        expect(direct.prefix, isEmpty);
        final DirectoryPreview? scanned = await DirectoryScan(
          fixture.dir.path,
          DirectoryRule.automatic,
          stalePrefix,
        ).result;
        expect(scanned, isNotNull);
        expect(scanned!.prefix, isEmpty);
        final ReaderDirectory directory = fixture.book.directory;
        // Apply also defends its public API if a caller retained unused text.
        directory.apply(
          DirectoryPreview(
            DirectoryRule.automatic,
            stalePrefix,
            scanned.rows,
            0,
          ),
        );
        expect(directory.prefix, isEmpty);
        final ReaderDirectory reopened = fixture.open().directory;
        expect(reopened.enabled, isTrue);
        expect(reopened.error, isNull);
        expect(reopened.prefix, isEmpty);
        final List<int> before = fixture
            .file('reader-directory.json')
            .readAsBytesSync();
        for (final String invalid in <String>['', 'x' * 33, '第\n章']) {
          expect(
            () => directory.apply(
              DirectoryPreview(DirectoryRule.prefix, invalid, scanned.rows, 0),
            ),
            throwsFormatException,
          );
          expect(
            fixture.file('reader-directory.json').readAsBytesSync(),
            before,
          );
        }
      },
    );

    test('failed apply and reset writes preserve the last loaded directory', () {
      final ReaderDirectory directory = fixture.book.directory;
      directory.apply(fixture.scan(DirectoryRule.chinese));
      final List<Chapter> previous = directory.chapters;
      final File sidecar = fixture.file('reader-directory.json');
      final List<int> saved = sidecar.readAsBytesSync();
      final File backup = sidecar.renameSync('${sidecar.path}.saved');
      // A directory at the final file path deterministically makes atomic rename fail.
      final Directory collision = Directory(sidecar.path)..createSync();
      int notifications = 0;
      directory.addListener(() => notifications++);
      expect(
        () => directory.apply(fixture.scan(DirectoryRule.english)),
        throwsA(isA<FileSystemException>()),
      );
      expect(directory.chapters, same(previous));
      expect(directory.rule, DirectoryRule.chinese);
      expect(directory.enabled, isTrue);
      expect(() => directory.reset(), throwsA(isA<FileSystemException>()));
      expect(directory.chapters, same(previous));
      expect(directory.rule, DirectoryRule.chinese);
      expect(directory.enabled, isTrue);
      expect(notifications, 0);
      expect(backup.readAsBytesSync(), saved);
      expect(
        fixture.dir.listSync().where((f) => f.path.endsWith('.tmp')),
        isEmpty,
      );
      collision.deleteSync();
      backup.renameSync(sidecar.path);
      expect(fixture.open().directory.chapters.last.title, previous.last.title);
    });

    test(
      'invalid or empty previews leave applied sidecar and navigation intact',
      () {
        final ReaderDirectory directory = fixture.book.directory;
        directory.apply(fixture.scan(DirectoryRule.chinese));
        final List<Chapter> previous = directory.chapters;
        final List<int> saved = fixture
            .file('reader-directory.json')
            .readAsBytesSync();
        for (final List<Json> rows in <List<Json>>[
          <Json>[],
          <Json>[
            <String, Object?>{'title': 'wrong source text', 'offset': 0},
          ],
          <Json>[
            <String, Object?>{'title': '序言', 'offset': -1},
          ],
          <Json>[
            <String, Object?>{'title': '序言', 'offset': fixture.book.length},
          ],
          <Json>[
            <String, Object?>{'title': '序言😀', 'offset': 0},
            <String, Object?>{'title': '序言😀', 'offset': 0},
          ],
          <Json>[
            <String, Object?>{'title': '序言', 'offset': 0.0},
          ],
          <Json>[
            <String, Object?>{'title': '', 'offset': 0},
          ],
          <Json>[
            <String, Object?>{
              'title': '字' * (directoryTitleLimit + 1),
              'offset': 0,
            },
          ],
          List<Json>.generate(
            directoryHeadingLimit + 1,
            (_) => <String, Object?>{'title': '序言', 'offset': 0},
          ),
        ]) {
          expect(
            () => directory.apply(
              DirectoryPreview(DirectoryRule.prefix, 'x', rows, 0),
            ),
            throwsFormatException,
          );
          expect(directory.chapters, same(previous));
          expect(
            fixture.file('reader-directory.json').readAsBytesSync(),
            saved,
          );
        }
      },
    );

    test(
      'invalid and stale sidecars fall back visibly without rewriting evidence',
      () {
        final ReaderDirectory directory = fixture.book.directory;
        directory.apply(fixture.scan(DirectoryRule.chinese));
        final Json valid =
            readJson(fixture.file('reader-directory.json'))! as Json;
        final List<Object?> invalid = <Object?>[
          null,
          <Object?>[],
          <String, Object?>{...valid, 'version': 2},
          <String, Object?>{...valid, 'bookId': 'another-book'},
          <String, Object?>{...valid, 'length': fixture.book.length + 1},
          <String, Object?>{...valid, 'enabled': null},
          <String, Object?>{...valid, 'enabled': 'true'},
          <String, Object?>{...valid, 'enabled': 0},
          <String, Object?>{...valid}..remove('enabled'),
          <String, Object?>{...valid, 'rule': 'unknown'},
          <String, Object?>{...valid, 'prefix': 12},
          <String, Object?>{...valid, 'prefix': 'x' * 33},
          <String, Object?>{...valid, 'prefix': '第\n章'},
          <String, Object?>{...valid, 'rule': 'prefix', 'prefix': '   '},
          <String, Object?>{
            ...valid,
            'rows': <Json>[
              <String, Object?>{
                'title': '第一章',
                'offset': fixture.book.blocks[1].o,
              },
            ],
          },
          <String, Object?>{...valid, 'rows': <Object?>[]},
          <String, Object?>{
            ...valid,
            'rows': <Object?>[null],
          },
          <String, Object?>{
            ...valid,
            'rows': <Json>[
              <String, Object?>{'title': '篡改标题', 'offset': 0},
            ],
          },
        ];
        for (final Object? value in invalid) {
          fixture
              .file('reader-directory.json')
              .writeAsStringSync(jsonEncode(value));
          final List<int> before = fixture
              .file('reader-directory.json')
              .readAsBytesSync();
          final ReaderDirectory reopened = fixture.open().directory;
          expect(reopened.enabled, isFalse, reason: jsonEncode(value));
          expect(reopened.rule, DirectoryRule.automatic);
          expect(reopened.prefix, isEmpty);
          expect(reopened.chapters, same(reopened.book.chapters));
          expect(reopened.error, isNotNull);
          expect(
            fixture.file('reader-directory.json').readAsBytesSync(),
            before,
          );
        }
        for (final String invalidJson in <String>[
          '{broken',
          ' ' * (4 * 1024 * 1024 + 1),
        ]) {
          fixture.file('reader-directory.json').writeAsStringSync(invalidJson);
          final ReaderDirectory reopened = fixture.open().directory;
          expect(reopened.enabled, isFalse);
          expect(reopened.error, isNotNull);
        }
        final ReaderDirectory damaged = fixture.open().directory;
        damaged.reset();
        expect(damaged.error, isNull);
        expect(fixture.open().directory.error, isNull);
      },
    );

    test(
      'preview rows require whole bounded text blocks at their exact trim offset',
      () {
        final _DirectoryFixture special = _DirectoryFixture(
          lines: <String>[
            '  第一章 故事开始  ',
            '${' ' * 121}第二章 过长原文块',
            '第三章 图片替代文字',
            '第四章 文本标题',
          ],
        );
        addTearDown(special.dispose);
        special.book.blocks[2].raw['k'] = 'img';
        special.book.blocks[3].raw['k'] = 'h';
        final ReaderDirectory directory = special.book.directory;
        for (final Json row in <Json>[
          <String, Object?>{'title': '第一章', 'offset': 2},
          <String, Object?>{'title': '故事开始', 'offset': 6},
          <String, Object?>{'title': '第一章 故事开始', 'offset': 0},
          <String, Object?>{
            'title': '第二章 过长原文块',
            'offset': special.book.blocks[1].o + 121,
          },
          <String, Object?>{
            'title': '第三章 图片替代文字',
            'offset': special.book.blocks[2].o,
          },
        ]) {
          expect(
            () => directory.previewEntries(<Json>[row]),
            throwsFormatException,
            reason: jsonEncode(row),
          );
        }
        final DirectoryPreview valid = special.scan(DirectoryRule.chinese);
        expect(_titles(valid), <String>['第一章 故事开始', '第四章 文本标题']);
        expect(
          directory.previewEntries(valid.rows).map((c) => c.title),
          <String>['开始', '第一章 故事开始', '第四章 文本标题'],
        );
        expect(special.file('reader-directory.json').existsSync(), isFalse);
      },
    );

    test(
      'same-length edits to source reject stale title evidence on reopen',
      () {
        fixture.book.directory.apply(fixture.scan(DirectoryRule.chinese));
        final Json changed = jsonDecode(jsonEncode(fixture.book.book)) as Json;
        ((changed['blocks']! as List<Object?>)[1]! as Json)['t'] = '第一章 故事改写';
        expect('第一章 故事改写'.length, '第一章 故事开始'.length);
        writeJson(fixture.file('book.json'), changed);
        final ReaderDirectory reopened = fixture.open().directory;
        expect(reopened.enabled, isFalse);
        expect(reopened.error, isNotNull);
        expect(reopened.chapters, same(reopened.book.chapters));
      },
    );
  });

  group('encoded sidecar size limit', () {
    test('escaped-control expansion cannot replace a valid saved directory', () {
      final _DirectoryFixture fixture = _DirectoryFixture(
        lines: <String>[
          '基线目录',
          for (int i = 0; i < directoryHeadingLimit; i++)
            '导航${i.toString().padLeft(5, '0')}${'\u0001' * 113}',
        ],
      );
      addTearDown(fixture.dispose);
      final ReaderDirectory directory = fixture.book.directory;
      directory.apply(fixture.scan(DirectoryRule.prefix, '基线'));
      final List<Chapter> previous = directory.chapters;
      final List<int> sidecar = fixture
          .file('reader-directory.json')
          .readAsBytesSync();
      final Map<String, List<int>> durableBefore = fixture.durableBytes();
      final DirectoryPreview oversized = fixture.scan(
        DirectoryRule.prefix,
        '导航',
      );
      expect(oversized.rows, hasLength(directoryHeadingLimit));
      expect(
        oversized.rows.every(
          (row) => (row['title']! as String).length == directoryTitleLimit,
        ),
        isTrue,
      );
      // The UTF-16 title and row-count limits both pass. JSON escaping expands
      // each control character to six bytes, exceeding the loader's 4 MiB cap.
      expect(
        utf8.encode(jsonEncode(oversized.rows)).length,
        greaterThan(4 * 1024 * 1024),
      );
      int notifications = 0;
      directory.addListener(() => notifications++);
      expect(() => directory.apply(oversized), throwsFormatException);
      expect(directory.chapters, same(previous));
      expect(directory.enabled, isTrue);
      expect(directory.rule, DirectoryRule.prefix);
      expect(directory.prefix, '基线');
      expect(directory.error, isNull);
      expect(notifications, 0);
      expect(fixture.file('reader-directory.json').readAsBytesSync(), sidecar);
      expect(fixture.durableBytes(), durableBefore);
      final ReaderDirectory reopened = fixture.open().directory;
      expect(reopened.enabled, isTrue);
      expect(reopened.error, isNull);
      expect(reopened.prefix, '基线');
      expect(reopened.chapters.map((chapter) => chapter.title), <String>[
        '基线目录',
      ]);
    });

    test('10000 ordinary 120-unit Chinese titles still apply and reopen', () {
      final List<String> titles = <String>[
        for (int i = 0; i < directoryHeadingLimit; i++)
          '导航${i.toString().padLeft(5, '0')}${'汉' * 113}',
      ];
      final _DirectoryFixture fixture = _DirectoryFixture(lines: titles);
      addTearDown(fixture.dispose);
      final Map<String, List<int>> durableBefore = fixture.durableBytes();
      final DirectoryPreview maximal = fixture.scan(DirectoryRule.prefix, '导航');
      expect(maximal.rows, hasLength(directoryHeadingLimit));
      expect(
        maximal.rows.every(
          (row) => (row['title']! as String).length == directoryTitleLimit,
        ),
        isTrue,
      );
      fixture.book.directory.apply(maximal);
      expect(fixture.book.directory.chapters, hasLength(directoryHeadingLimit));
      expect(
        fixture.file('reader-directory.json').lengthSync(),
        lessThanOrEqualTo(4 * 1024 * 1024),
      );
      final ReaderDirectory reopened = fixture.open().directory;
      expect(reopened.enabled, isTrue);
      expect(reopened.error, isNull);
      expect(reopened.rule, DirectoryRule.prefix);
      expect(reopened.prefix, '导航');
      expect(reopened.chapters.map((chapter) => chapter.title), titles);
      expect(
        reopened.chapters.last.o0,
        (directoryHeadingLimit - 1) * (directoryTitleLimit + 1),
      );
      expect(fixture.durableBytes(), durableBefore);
    });
  });

  group('positive TXT source identification', () {
    test(
      'metadata filename and saved source.txt are accepted independently',
      () {
        final _DirectoryFixture fixture = _DirectoryFixture();
        addTearDown(fixture.dispose);
        fixture.file('source.txt').deleteSync();
        expect(
          fixture.book.directory.supportsCorrection,
          isTrue,
          reason: 'Uppercase .TXT metadata is positive evidence',
        );
        fixture.file('meta.json').deleteSync();
        expect(fixture.book.directory.supportsCorrection, isFalse);
        fixture.file('source.txt').writeAsStringSync('original source');
        expect(fixture.book.directory.supportsCorrection, isTrue);
        writeJson(fixture.file('meta.json'), <String, Object?>{});
        expect(fixture.book.directory.supportsCorrection, isTrue);
      },
    );

    test(
      'EPUB, conflicting source, unknown format and corrupt metadata are excluded',
      () {
        final _DirectoryFixture fixture = _DirectoryFixture();
        addTearDown(fixture.dispose);
        final ReaderDirectory directory = fixture.book.directory;
        for (final String filename in <String>[
          'book.epub',
          'book.pdf',
          'book',
          'book.txt.epub',
        ]) {
          writeJson(fixture.file('meta.json'), <String, Object?>{
            'filename': filename,
          });
          expect(directory.supportsCorrection, isFalse, reason: filename);
          expect(
            () => directory.apply(fixture.scan(DirectoryRule.chinese)),
            throwsFormatException,
          );
        }
        writeJson(fixture.file('meta.json'), <String, Object?>{
          'filename': 'book.txt',
        });
        fixture.file('source.epub').writeAsBytesSync(<int>[80, 75]);
        expect(directory.supportsCorrection, isFalse);
        fixture.file('source.epub').deleteSync();
        fixture.file('meta.json').writeAsStringSync('[]');
        expect(directory.supportsCorrection, isFalse);
        fixture.file('meta.json').deleteSync();
        fixture.file('source.txt').deleteSync();
        expect(directory.supportsCorrection, isFalse);
        expect(fixture.file('reader-directory.json').existsSync(), isFalse);
      },
    );

    test('an existing sidecar never enables correction for an EPUB source', () {
      final _DirectoryFixture fixture = _DirectoryFixture();
      addTearDown(fixture.dispose);
      fixture.book.directory.apply(fixture.scan(DirectoryRule.chinese));
      writeJson(fixture.file('meta.json'), <String, Object?>{
        'filename': 'book.epub',
      });
      final ReaderDirectory reopened = fixture.open().directory;
      expect(reopened.supportsCorrection, isFalse);
      expect(reopened.enabled, isFalse);
      expect(reopened.error, isNotNull);
    });
  });

  group('imported TXT export and trash integration', () {
    late Directory root;
    late Library library;
    late BookEntry entry;
    late BookData book;
    final List<BookData> opened = <BookData>[];
    final Uint8List source = utf8.encode(
      '目录修正导入测试\n\n'
      '第一章 故事开始\n\n'
      '导航一：河岸相遇\n\n'
      '两人走到河边，停下来交谈，随后继续沿着小路向前走。\n\n'
      '第二章 旅程继续\n\n'
      '导航二：抵达村庄\n\n'
      '天色已经暗了下来，村庄里的灯火依次亮起。\n',
    );

    BookData open(BookEntry entry) {
      final BookData result = BookData.open(entry);
      opened.add(result);
      return result;
    }

    setUp(() async {
      root = Directory.systemTemp.createTempSync('thusfar-directory-import-');
      library = Library(root);
      await library.scan();
      final ImportResult result = await importBookFile(
        library,
        '目录修正导入测试.txt',
        source,
      );
      expect(result.error, isNull);
      expect(result.existed, isFalse);
      await library.scan();
      entry = library.books.single;
      book = open(entry);
    });

    tearDown(() {
      for (final BookData data in opened) {
        data.directory.dispose();
        data.notes.dispose();
        data.dispose();
      }
      opened.clear();
      library.dispose();
      root.deleteSync(recursive: true);
    });

    void applyNavigation() {
      final DirectoryPreview preview = detectDirectory(
        book.book,
        DirectoryRule.prefix,
        '导航',
      );
      expect(_titles(preview), <String>['导航一：河岸相遇', '导航二：抵达村庄']);
      book.directory.apply(preview);
      expect(book.directory.enabled, isTrue);
    }

    test(
      'export before and after correction keeps canonical book and omits the local overlay',
      () {
        final File canonical = File('${entry.dir.path}/book.json');
        final List<int> originalBytes = canonical.readAsBytesSync();
        final Json before =
            jsonDecode(utf8.decode(exportBookBytes(library, entry))) as Json;
        final Object? originalChapters = (before['book']! as Json)['chapters'];
        applyNavigation();
        expect(
          File('${entry.dir.path}/reader-directory.json').existsSync(),
          isTrue,
        );
        final Json after =
            jsonDecode(utf8.decode(exportBookBytes(library, entry))) as Json;
        expect(after['book'], before['book']);
        expect((after['book']! as Json)['chapters'], originalChapters);
        expect(
          (after['work_files']! as Json).keys,
          isNot(contains('reader-directory.json')),
        );
        expect(after.keys, isNot(contains('reader-directory')));
        expect(after.keys, isNot(contains('reader_directory')));
        expect(jsonEncode(after), isNot(contains('reader-directory.json')));
        before.remove('exported');
        after.remove('exported');
        expect(
          after,
          before,
          reason:
              'A local navigation override must not change any backup payload',
        );
        expect(canonical.readAsBytesSync(), originalBytes);
      },
    );

    test(
      'removal moves the sidecar to trash and fresh same-source import starts original',
      () async {
        final Json original = jsonDecode(jsonEncode(book.book)) as Json;
        applyNavigation();
        final List<int> sidecar = File(
          '${entry.dir.path}/reader-directory.json',
        ).readAsBytesSync();
        final String id = entry.id;
        await library.remove(entry);
        expect(library.books, isEmpty);
        expect(entry.dir.existsSync(), isFalse);
        final TrashedBook trashed = library.listTrash().single;
        expect(trashed.id, id);
        expect(
          File('${trashed.dir.path}/reader-directory.json').readAsBytesSync(),
          sidecar,
        );
        final ImportResult imported = await importBookFile(
          library,
          '目录修正导入测试.txt',
          source,
        );
        expect(imported.error, isNull);
        expect(imported.id, id);
        expect(imported.existed, isFalse);
        await library.scan();
        final BookData fresh = open(library.books.single);
        expect(fresh.id, id);
        expect(fresh.directory.enabled, isFalse);
        expect(fresh.directory.error, isNull);
        expect(fresh.directory.chapters, same(fresh.chapters));
        expect(fresh.book['chapters'], original['chapters']);
        expect(
          File('${fresh.entry.dir.path}/reader-directory.json').existsSync(),
          isFalse,
        );
        expect(
          File('${trashed.dir.path}/reader-directory.json').readAsBytesSync(),
          sidecar,
        );
        expect(library.listTrash(), hasLength(1));
      },
    );

    test(
      'restoring the trashed book preserves its exact local sidecar and navigation',
      () async {
        applyNavigation();
        final List<String> titles = book.directory.chapters
            .map((c) => c.title)
            .toList();
        final List<int> sidecar = File(
          '${entry.dir.path}/reader-directory.json',
        ).readAsBytesSync();
        final List<int> canonical = File(
          '${entry.dir.path}/book.json',
        ).readAsBytesSync();
        await library.remove(entry);
        final TrashedBook trashed = library.listTrash().single;
        await library.restoreFromTrash(trashed);
        expect(library.listTrash(), isEmpty);
        final BookData restored = open(library.books.single);
        expect(restored.id, entry.id);
        expect(restored.directory.enabled, isTrue);
        expect(restored.directory.error, isNull);
        expect(restored.directory.rule, DirectoryRule.prefix);
        expect(restored.directory.prefix, '导航');
        expect(restored.directory.chapters.map((c) => c.title), titles);
        expect(
          File(
            '${restored.entry.dir.path}/reader-directory.json',
          ).readAsBytesSync(),
          sidecar,
        );
        expect(
          File('${restored.entry.dir.path}/book.json').readAsBytesSync(),
          canonical,
        );
      },
    );
  });

  group('source-matched title safety', () {
    test(
      'only exact title and offset inherit an explicit safe model verdict',
      () {
        final List<String> lines = <String>[
          '第一章 安全标题',
          '第二章 同位置不同标题',
          '第三章 非模型判定',
          '第四章 模型确认剧透',
          '第一章 安全标题',
        ];
        final Json raw = _bookFor(lines);
        final List<Json> blocks = raw['blocks']! as List<Json>;
        final _DirectoryFixture fixture = _DirectoryFixture(
          lines: lines,
          chapters: <Json>[
            for (int i = 0; i < 4; i++)
              <String, Object?>{
                'title': i == 1 ? '第二章 旧标题' : lines[i],
                'b0': i,
                'b1': i + 1,
                'o0': blocks[i]['o'],
                'o1': blocks[i + 1]['o'],
                'spoil': i == 3,
                if (i != 2) 'spoilSource': 'model',
              },
          ],
        );
        addTearDown(fixture.dispose);
        final List<Chapter> entries = fixture.book.directory.previewEntries(
          fixture.scan(DirectoryRule.chinese).rows,
        );
        expect(
          (entries[0] as DirectoryChapter).source,
          same(fixture.book.chapters[0]),
        );
        expect((entries[0] as DirectoryChapter).verifiedSafe, isTrue);
        for (final Chapter chapter in entries.skip(1)) {
          expect((chapter as DirectoryChapter).verifiedSafe, isFalse);
        }
        expect((entries[1] as DirectoryChapter).source, isNull);
        expect(
          (entries[4] as DirectoryChapter).source,
          isNull,
          reason: 'Equal text at another position cannot reuse a model verdict',
        );
        expect(safeTitle(entries[0], false, checkPending: true), lines[0]);
        for (int i = 1; i < entries.length; i++) {
          expect(safeTitle(entries[i], false), isNot(lines[i]));
          expect(safeTitle(entries[i], true), lines[i]);
        }
        fixture.book.chapters[0].raw['spoil'] = true;
        expect((entries[0] as DirectoryChapter).verifiedSafe, isFalse);
        expect(safeTitle(entries[0], false), isNot(lines[0]));
      },
    );

    test(
      'unread corrected headings remain hidden until their full UTF-16 end',
      () {
        final _DirectoryFixture fixture = _DirectoryFixture(
          lines: <String>['第一章 相遇😀𠮷'],
        );
        addTearDown(fixture.dispose);
        final DirectoryChapter chapter =
            fixture.book.directory
                    .previewEntries(fixture.scan(DirectoryRule.chinese).rows)
                    .single
                as DirectoryChapter;
        for (int cutoff = chapter.o0; cutoff < chapter.titleEnd; cutoff++) {
          expect(tocTitleRead(chapter, cutoff), isFalse);
          expect(
            safeTitle(chapter, tocTitleRead(chapter, cutoff)),
            isNot(chapter.title),
          );
        }
        expect(tocTitleRead(chapter, chapter.titleEnd), isTrue);
        expect(
          safeTitle(chapter, tocTitleRead(chapter, chapter.titleEnd)),
          chapter.title,
        );
        final Chapter canonical = fixture.book.chapters.single;
        expect(tocTitleRead(canonical, canonical.o0), isFalse);
        expect(tocTitleRead(canonical, canonical.o0 + 1), isTrue);
      },
    );
  });
}
