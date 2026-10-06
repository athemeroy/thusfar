import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:thusfar_app/data/backup.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/library_zip.dart';
import 'package:thusfar_app/data/purification_store.dart';
import 'package:thusfar_app/data/reader_customizations.dart';
import 'package:thusfar_app/data/reader_directory.dart';
import 'package:thusfar_app/reader/tap_layout.dart';
import 'package:thusfar_app/reader/text_purification.dart';

Uint8List _bytes(Json value) => utf8.encode(jsonEncode(value));

class Fixture {
  Fixture() : root = Directory.systemTemp.createTempSync('portable-reader-') {
    library = Library(root);
    library.booksDir.createSync(recursive: true);
  }
  final Directory root;
  late Library library;
  File get rulesFile => File('${root.path}/text-purification.json');
  List<PurificationRule> get rules => PurificationStore.readSnapshot(rulesFile);
  Future<BookEntry> add({String name = 'example.txt'}) async {
    final ImportResult result = await importBookFile(
      library,
      name,
      utf8.encode('前言😀\n\n第一章 开始\n\n正文含广告。\n\n第二章 相遇\n\n正文继续。'),
    );
    expect(result.error, isNull);
    await library.scan();
    return library.byId(result.id!)!;
  }

  void customize(BookEntry entry, {bool global = true}) {
    final BookData book = BookData.open(entry);
    book.directory.apply(detectDirectory(book.book, DirectoryRule.chinese, ''));
    book.directory.dispose();
    book.notes.dispose();
    book.dispose();
    writeJson(
      rulesFile,
      PurificationStore.encodeStore(<PurificationRule>[
        if (global) const PurificationRule(id: 'global-first', find: '广告'),
        PurificationRule(
          id: 'book-only',
          find: '正文',
          replacement: '文字',
          bookId: entry.id,
          enabled: false,
        ),
        if (global)
          const PurificationRule(
            id: 'global-last',
            find: '继续',
            replacement: '往前',
          ),
      ]),
    );
    library.saveProgress(entry.id, 2, 3, entry.length, timestamp: 40);
  }

  Map<String, List<int>> snapshot() => <String, List<int>>{
    for (final File f in root.listSync(recursive: true).whereType<File>())
      f.path.substring(root.path.length): f.readAsBytesSync(),
  };
  void dispose() {
    library.dispose();
    root.deleteSync(recursive: true);
  }
}

class RuleWriteBlockedLibrary extends Library {
  RuleWriteBlockedLibrary(super.root);
  @override
  void saveProgress(
    String id,
    int pos,
    int cutoff,
    int length, {
    double? timestamp,
    int? returnTo,
  }) {
    super.saveProgress(
      id,
      pos,
      cutoff,
      length,
      timestamp: timestamp,
      returnTo: returnTo,
    );
    Directory('${root.path}/text-purification.json').createSync();
  }
}

void main() {
  late Fixture source;
  late Fixture target;
  late BookEntry entry;
  setUp(() async {
    source = Fixture();
    target = Fixture();
    entry = await source.add();
    source.customize(entry);
  });
  tearDown(() {
    source.dispose();
    target.dispose();
  });

  test(
    'single JSON includes scoped rules and verified directory, explicitly omits globals',
    () {
      final Json data =
          jsonDecode(utf8.decode(exportBookBytes(source.library, entry)))
              as Json;
      final Json custom = data['reader_customizations']! as Json;
      expect(custom['globalRulesOmitted'], 2);
      expect(
        decodeReaderPurificationRules(custom['purification']).map((r) => r.id),
        <String>['book-only'],
      );
      expect((custom['directory']! as Json)['enabled'], isTrue);
      expect(data['book'], readJson(File('${entry.dir.path}/book.json')));
      expect(data.keys, isNot(contains('api_key')));
    },
  );

  test(
    'preview/cancel has no writes; restore/reimport preserves scoped rules and directory',
    () async {
      final Uint8List bytes = exportBookBytes(source.library, entry);
      final Map<String, List<int>> before = target.snapshot();
      expect(
        restoreBackup(
          target.library,
          'book.json',
          bytes,
          previewOnly: true,
        ).error,
        isNull,
      );
      expect(target.snapshot(), before);
      final ImportResult restored = restoreBackup(
        target.library,
        'book.json',
        bytes,
      );
      expect(restored.error, isNull);
      await target.library.scan();
      final BookData book = BookData.open(target.library.books.single);
      expect(book.directory.enabled, isTrue);
      expect(book.directory.chapters.whereType<DirectoryChapter>().length, 3);
      expect(target.rules.map((r) => r.bookId), <String>[restored.id!]);
      expect(target.rules.single.enabled, isFalse);
      expect(target.library.progressOf(restored.id!)!.pos, 2);
      book.directory.dispose();
      book.notes.dispose();
      book.dispose();
      expect(restoreBackup(target.library, 'again.json', bytes).error, isNull);
      expect(target.rules.length, 1);
    },
  );

  test(
    'same immutable book with a different local ID safely remaps both scopes',
    () async {
      final Json data =
          jsonDecode(utf8.decode(exportBookBytes(source.library, entry)))
              as Json;
      final Json old = <String, Object?>{...data}
        ..remove('reader_customizations')
        ..remove('id');
      final ImportResult initial = restoreBackup(
        target.library,
        'legacy.json',
        _bytes(old),
      );
      expect(initial.error, isNull);
      expect(initial.id, isNot(entry.id));
      final ImportResult result = restoreBackup(
        target.library,
        'current.json',
        _bytes(data),
      );
      expect(result.error, isNull);
      expect(result.id, initial.id);
      expect(target.rules.single.bookId, initial.id);
      expect(
        (readJson(
              File(
                '${target.library.booksDir.path}/${initial.id}/reader-directory.json',
              ),
            )!
            as Json)['bookId'],
        initial.id,
      );
    },
  );

  test(
    'foreign source, stale directory and global-in-single payload fail before writes',
    () {
      final Json data =
          jsonDecode(utf8.decode(exportBookBytes(source.library, entry)))
              as Json;
      for (final void Function(Json) damage in <void Function(Json)>[
        (custom) => custom['source'] = '0' * 64,
        (custom) => (custom['directory']! as Json)['bookId'] = 'another-book',
        (custom) =>
            ((custom['directory']! as Json)['rows']! as List<Object?>).first =
                <String, Object?>{'title': 'wrong', 'offset': 0},
        (custom) =>
            ((custom['purification']! as List<Object?>).single!
                    as Json)['bookId'] =
                null,
        (custom) =>
            ((custom['purification']! as List<Object?>).single!
                    as Json)['find'] =
                '',
        (custom) => custom['password'] = 'private',
      ]) {
        final Json bad = jsonDecode(jsonEncode(data)) as Json;
        damage(bad['reader_customizations']! as Json);
        final Map<String, List<int>> before = target.snapshot();
        expect(
          restoreBackup(target.library, 'bad.json', _bytes(bad)).error,
          isNotNull,
        );
        expect(target.snapshot(), before);
      }
    },
  );

  test(
    'different local directory is a conflict and explicit local reset stays reset',
    () async {
      final Uint8List bytes = exportBookBytes(source.library, entry);
      expect(restoreBackup(target.library, 'book.json', bytes).error, isNull);
      await target.library.scan();
      final BookData book = BookData.open(target.library.books.single);
      book.directory.reset();
      book.directory.dispose();
      book.notes.dispose();
      book.dispose();
      final Map<String, List<int>> before = target.snapshot();
      expect(
        restoreBackup(target.library, 'again.json', bytes).error,
        contains('修正目录不同'),
      );
      expect(target.snapshot(), before);
    },
  );

  test(
    'existing enabled preferences and order survive duplicate rule restores',
    () {
      final Uint8List bytes = exportBookBytes(source.library, entry);
      writeJson(
        target.rulesFile,
        PurificationStore.encodeStore(<PurificationRule>[
          const PurificationRule(id: 'local-first', find: '本地'),
          PurificationRule(
            id: 'book-only',
            find: '正文',
            replacement: '文字',
            bookId: entry.id,
            enabled: true,
          ),
        ]),
      );
      expect(restoreBackup(target.library, 'book.json', bytes).error, isNull);
      expect(target.rules.map((r) => r.id), <String>[
        'local-first',
        'book-only',
      ]);
      expect(target.rules.last.enabled, isTrue);
    },
  );

  test('stable rule identity conflicts fail before creating books', () {
    writeJson(
      target.rulesFile,
      PurificationStore.encodeStore(<PurificationRule>[
        PurificationRule(id: 'book-only', find: 'different', bookId: entry.id),
      ]),
    );
    final Map<String, List<int>> before = target.snapshot();
    expect(
      restoreBackup(
        target.library,
        'book.json',
        exportBookBytes(source.library, entry),
      ).error,
      contains('净化规则'),
    );
    expect(target.snapshot(), before);
  });

  test('old v1/v2 backups do not reset current rules or directory', () async {
    final Json data =
        jsonDecode(utf8.decode(exportBookBytes(source.library, entry))) as Json;
    expect(
      restoreBackup(target.library, 'current.json', _bytes(data)).error,
      isNull,
    );
    final Json old = <String, Object?>{...data}
      ..remove('reader_customizations');
    final List<int> ruleBytes = target.rulesFile.readAsBytesSync();
    final File directory = File(
      '${target.library.booksDir.path}/${entry.id}/reader-directory.json',
    );
    final List<int> directoryBytes = directory.readAsBytesSync();
    for (final String format in <String>['yedu-book/1', 'yedu-book/2']) {
      old['format'] = format;
      expect(
        restoreBackup(target.library, 'legacy.json', _bytes(old)).error,
        isNull,
      );
      expect(target.rulesFile.readAsBytesSync(), ruleBytes);
      expect(directory.readAsBytesSync(), directoryBytes);
    }
  });

  test('new-book progress failure rolls root rules and book sidecar back', () {
    const PurificationRule local = PurificationRule(id: 'prior', find: '本地');
    writeJson(
      target.rulesFile,
      PurificationStore.encodeStore(<PurificationRule>[local]),
    );
    Directory('${target.root.path}/progress.json').createSync();
    final List<int> old = target.rulesFile.readAsBytesSync();
    final ImportResult result = restoreBackup(
      target.library,
      'book.json',
      exportBookBytes(source.library, entry),
    );
    expect(result.error, isNotNull);
    expect(target.rulesFile.readAsBytesSync(), old);
    expect(target.library.booksDir.listSync(), isEmpty);
    expect(target.library.progress, isEmpty);
  });

  test(
    'corrupt rule stores and stale sidecars are not silently omitted on export',
    () {
      source.rulesFile.writeAsStringSync('{bad');
      expect(
        () => exportBookBytes(source.library, entry),
        throwsFormatException,
      );
      source.customize(entry);
      final File directory = File('${entry.dir.path}/reader-directory.json');
      final Json bad = readJson(directory)! as Json;
      bad['length'] = -1;
      writeJson(directory, bad);
      expect(
        () => exportBookBytes(source.library, entry),
        throwsFormatException,
      );
    },
  );

  test(
    'full ZIP restores full order only with explicit rule-settings opt-in',
    () {
      final Uint8List zip = exportLibraryZipBytes(
        source.library,
        <String, Object?>{},
      );
      final LibraryZipData decoded = LibraryZipCodec.decode(zip);
      expect(decoded.customizations, isNotNull);
      expect(restoreLibraryZip(target.library, zip).complete, isTrue);
      expect(target.rules.map((r) => r.id), <String>['book-only']);
      // A fresh restore reproduces global/book precedence exactly.
      target.dispose();
      target = Fixture();
      expect(
        restoreLibraryZip(
          target.library,
          zip,
          applyRuleSettings: true,
        ).complete,
        isTrue,
      );
      expect(target.rules.map((r) => r.id), <String>[
        'global-first',
        'book-only',
        'global-last',
      ]);
      expect(target.rules[1].enabled, isFalse);
      expect(
        restoreLibraryZip(
          target.library,
          zip,
          applyRuleSettings: true,
        ).complete,
        isTrue,
      );
      expect(target.rules.length, 3);
    },
  );

  test(
    'full archive malformed rules or source IDs reject the complete preflight',
    () {
      final LibraryZipData valid = LibraryZipCodec.decode(
        exportLibraryZipBytes(source.library, <String, Object?>{}),
      );
      final Json bad = jsonDecode(jsonEncode(valid.customizations)) as Json;
      ((bad['books']! as List<Object?>).single! as Json)['source'] = 'f' * 64;
      final Map<String, List<int>> before = target.snapshot();
      expect(
        () => restoreLibraryZipData(
          target.library,
          LibraryZipData(valid.books, valid.settings, customizations: bad),
          applyRuleSettings: true,
        ),
        throwsFormatException,
      );
      expect(target.snapshot(), before);
    },
  );

  test(
    'legacy ZIP still restores and supported settings reject secrets/invalid tap layouts',
    () {
      final Json old =
          jsonDecode(utf8.decode(exportBookBytes(source.library, entry)))
                as Json
            ..remove('reader_customizations');
      final Uint8List zip = LibraryZipCodec.encode(
        books: <Uint8List>[_bytes(old)],
        settings: <String, Object?>{},
      );
      expect(LibraryZipCodec.decode(zip).customizations, isNull);
      expect(restoreLibraryZip(target.library, zip).complete, isTrue);
      expect(target.rules, isEmpty);
      final Json settings = <String, Object?>{
        'native': <String, Object?>{
          'tapLayout': ReaderTapLayout.preset(
            ReaderTapPreset.leftHanded,
          ).toJson(),
          'paragraphSpacing': 1.25,
          'firstLineIndent': 0,
        },
      };
      expect(LibraryZipCodec.validatedSettings(settings), settings);
      (settings['native']! as Json)['api_key'] = 'secret';
      expect(
        () => LibraryZipCodec.validatedSettings(settings),
        throwsFormatException,
      );
      (settings['native']! as Json)
        ..remove('api_key')
        ..['tapLayout'] = <String>['next'];
      expect(
        () => LibraryZipCodec.validatedSettings(settings),
        throwsFormatException,
      );
    },
  );
  test(
    'full ZIP checks customizations checksum and conflicting embedded rule copies',
    () {
      final Uint8List zip = exportLibraryZipBytes(
        source.library,
        <String, Object?>{},
      );
      final Archive archive = ZipDecoder().decodeBytes(zip);
      final Archive corrupted = Archive();
      for (final ArchiveFile file in archive.files) {
        corrupted.addFile(
          file.name == 'customizations.json'
              ? ArchiveFile.bytes(file.name, utf8.encode('{}'))
              : file,
        );
      }
      expect(
        () => LibraryZipCodec.decode(ZipEncoder().encodeBytes(corrupted)),
        throwsFormatException,
      );
      final LibraryZipData good = LibraryZipCodec.decode(zip);
      final Json bad = jsonDecode(jsonEncode(good.customizations)) as Json;
      final List<Object?> rules = bad['purification']! as List<Object?>;
      (rules[1]! as Json)['replacement'] = 'changed';
      final Map<String, List<int>> before = target.snapshot();
      expect(
        () => restoreLibraryZipData(
          target.library,
          LibraryZipData(good.books, good.settings, customizations: bad),
          applyRuleSettings: true,
        ),
        throwsFormatException,
      );
      expect(target.snapshot(), before);
    },
  );

  test('full ZIP subset metadata retains unrepresented book-scoped rules', () {
    final LibraryZipData good = LibraryZipCodec.decode(
      exportLibraryZipBytes(source.library, <String, Object?>{}),
    );
    final Json subset = <String, Object?>{
      'format': 'thusfar-reader-library',
      'version': 1,
      'books': <Object?>[],
      'purification': encodeReaderPurificationRules(
        source.rules.where((r) => r.bookId == null),
      ),
    };
    final LibraryZipRestoreResult result = restoreLibraryZipData(
      target.library,
      LibraryZipData(good.books, good.settings, customizations: subset),
      applyRuleSettings: true,
    );
    expect(result.complete, isTrue);
    expect(target.rules.map((r) => r.id), <String>[
      'global-first',
      'global-last',
      'book-only',
    ]);
  });

  test(
    'final library rule-write failure reports retained books and retries idempotently',
    () async {
      target.library.dispose();
      target.library = RuleWriteBlockedLibrary(target.root);
      final Uint8List zip = exportLibraryZipBytes(
        source.library,
        <String, Object?>{},
      );
      final LibraryZipRestoreResult failed = restoreLibraryZip(
        target.library,
        zip,
        applyRuleSettings: true,
      );
      expect(failed.complete, isFalse);
      expect(failed.failures, isEmpty);
      expect(failed.customizationError, contains('书籍已恢复'));
      expect(failed.entries.length, 1);
      expect(target.library.booksDir.listSync().length, 1);
      Directory('${target.root.path}/text-purification.json').deleteSync();
      target.library.dispose();
      target.library = Library(target.root);
      await target.library.scan();
      expect(
        restoreLibraryZip(
          target.library,
          zip,
          applyRuleSettings: true,
        ).complete,
        isTrue,
      );
      expect(target.rules.map((r) => r.id), <String>[
        'global-first',
        'book-only',
        'global-last',
      ]);
      expect(
        restoreLibraryZip(
          target.library,
          zip,
          applyRuleSettings: true,
        ).complete,
        isTrue,
      );
      expect(target.rules.length, 3);
    },
  );

  test(
    'interrupted new-book publication restores rules/progress once and ignores staging',
    () {
      final Json previous = PurificationStore.encodeStore(<PurificationRule>[
        const PurificationRule(id: 'local', find: 'local'),
      ]);
      writeJson(target.rulesFile, previous);
      final Uint8List bytes = exportBookBytes(source.library, entry);
      expect(restoreBackup(target.library, 'book.json', bytes).error, isNull);
      final Directory dest = Directory(
        '${target.library.booksDir.path}/${entry.id}',
      );
      writeJson(
        File('${dest.path}/.sync-merge-pending.json'),
        <String, Object?>{
          'id': entry.id,
          'new_book': true,
          'purification_changed': true,
          'purification_previous': previous,
          'progress_previous': <String, Object?>{},
        },
      );
      final Directory staging = Directory(
        '${target.library.booksDir.path}/.unpublished.tmp',
      )..createSync();
      writeJson(
        File('${staging.path}/.sync-merge-pending.json'),
        <String, Object?>{'id': 'unpublished', 'new_book': true},
      );
      expect(recoverPendingBackupMerges(target.root), 1);
      expect(dest.existsSync(), isFalse);
      expect(target.rules.single.id, 'local');
      expect(readJson(File('${target.root.path}/progress.json')), isEmpty);
      expect(staging.existsSync(), isTrue);
      expect(recoverPendingBackupMerges(target.root), 0);
    },
  );

  test(
    'same-book late failure restores customizations and memory before blocked progress recovery',
    () async {
      final Json data =
          jsonDecode(utf8.decode(exportBookBytes(source.library, entry)))
              as Json;
      final Json legacy = <String, Object?>{...data}
        ..remove('reader_customizations');
      expect(
        restoreBackup(target.library, 'old.json', _bytes(legacy)).error,
        isNull,
      );
      final File progress = File('${target.root.path}/progress.json');
      final Object? oldProgress = readJson(progress);
      progress.deleteSync();
      Directory(progress.path).createSync();
      data['progress'] = <String, Object?>{'pos': 3, 'cutoff': 4, 't': 100};
      final ImportResult result = restoreBackup(
        target.library,
        'new.json',
        _bytes(data),
      );
      expect(result.error, isNotNull);
      expect(target.rulesFile.existsSync(), isFalse);
      expect(
        File(
          '${target.library.booksDir.path}/${entry.id}/reader-directory.json',
        ).existsSync(),
        isFalse,
      );
      expect(target.library.progressOf(entry.id)!.pos, 2);
      Directory(progress.path).deleteSync();
      writeJson(progress, oldProgress);
      expect(recoverPendingBackupMerges(target.root), 1);
      expect(
        restoreBackup(target.library, 'retry.json', _bytes(data)).error,
        isNull,
      );
      expect(target.rules.length, 1);
    },
  );
  test(
    'full restore rejects prospective alias collisions before assigning scoped rules',
    () {
      final Json first =
          jsonDecode(utf8.decode(exportBookBytes(source.library, entry)))
              as Json;
      final Json second = jsonDecode(jsonEncode(first)) as Json;
      const String alias = 'abcdef1234567890';
      second['id'] = alias;
      second['reader_customizations'] = exportReaderCustomizations(
        book: second['book']! as Json,
        bookId: alias,
        rules: <PurificationRule>[
          const PurificationRule(id: 'alias-rule', find: '正文', bookId: alias),
        ],
        meta: second['meta']! as Json,
      );
      final Json policy = <String, Object?>{
        'format': 'thusfar-reader-library',
        'version': 1,
        'books': <Json>[
          for (final Json data in <Json>[first, second])
            <String, Object?>{
              'bookId': data['id'],
              'source': readerCustomizationSource(data['book']! as Json),
            },
        ],
        'purification': <Object?>[
          for (final Json data in <Json>[first, second])
            ...((data['reader_customizations']! as Json)['purification']!
                as List<Object?>),
        ],
      };
      final Map<String, List<int>> before = target.snapshot();
      expect(
        () => restoreLibraryZipData(
          target.library,
          LibraryZipData(
            <Uint8List>[_bytes(first), _bytes(second)],
            <String, Object?>{},
            customizations: policy,
          ),
          applyRuleSettings: true,
        ),
        throwsFormatException,
      );
      expect(target.snapshot(), before);
    },
  );
  test(
    'interrupted staging is never matched as an existing restored book on retry',
    () async {
      final Directory staged = Directory(
        '${target.library.booksDir.path}/.${entry.id}.12345.tmp',
      )..createSync();
      for (final String name in <String>['book', 'meta', 'status']) {
        writeJson(
          File('${staged.path}/$name.json'),
          readJson(File('${entry.dir.path}/$name.json')),
        );
      }
      writeJson(
        File('${staged.path}/.sync-merge-pending.json'),
        <String, Object?>{'id': entry.id, 'new_book': true},
      );
      expect(recoverPendingBackupMerges(target.root), 0);
      final Uint8List bytes = exportBookBytes(source.library, entry);
      final ImportResult restored = restoreBackup(
        target.library,
        'retry.json',
        bytes,
      );
      expect(restored.error, isNull);
      expect(restored.id, entry.id);
      expect(restored.existed, isFalse);
      await target.library.scan();
      expect(target.library.books.single.id, entry.id);
      expect(target.rules.single.bookId, entry.id);
      expect(
        restoreBackup(target.library, 'again.json', bytes).existed,
        isTrue,
      );
      expect(target.rules.length, 1);
      expect(staged.existsSync(), isTrue);
    },
  );
  for (final bool wholeLibrary in <bool>[false, true]) {
    test(
      'distinct duplicate rule enabled states preserve appearance; wholeLibrary=$wholeLibrary',
      () async {
        writeJson(
          source.rulesFile,
          PurificationStore.encodeStore(<PurificationRule>[
            PurificationRule(
              id: 'disabled-first',
              find: '正文',
              replacement: '文字',
              bookId: entry.id,
              enabled: false,
            ),
            PurificationRule(
              id: 'enabled-next',
              find: '正文',
              replacement: '文字',
              bookId: entry.id,
            ),
          ]),
        );
        final Uint8List bytes = wholeLibrary
            ? exportLibraryZipBytes(source.library, <String, Object?>{})
            : exportBookBytes(source.library, entry);
        for (int repeat = 0; repeat < 2; repeat++) {
          if (wholeLibrary) {
            expect(
              restoreLibraryZip(
                target.library,
                bytes,
                applyRuleSettings: true,
              ).complete,
              isTrue,
            );
          } else {
            expect(
              restoreBackup(target.library, 'book.json', bytes).error,
              isNull,
            );
          }
          expect(target.rules.map((r) => r.id), <String>[
            'disabled-first',
            'enabled-next',
          ]);
          expect(TextPurifier(target.rules).apply('正文含广告。').text, '文字含广告。');
        }
      },
    );
  }

  test(
    'directory snapshots reject oversized and non-file sidecars before reading them',
    () {
      final File file = File('${entry.dir.path}/reader-directory.json');
      final RandomAccessFile handle = file.openSync(mode: FileMode.write);
      handle.truncateSync(readerDirectoryByteLimit + 1);
      handle.closeSync();
      expect(
        () => exportBookBytes(source.library, entry),
        throwsFormatException,
      );
      file.deleteSync();
      Directory(file.path).createSync();
      expect(
        () => exportBookBytes(source.library, entry),
        throwsFormatException,
      );
    },
  );
  test('stale open rule stores cannot overwrite newly restored rules', () {
    final PurificationStore open = PurificationStore(target.rulesFile);
    int changes = 0;
    open.addListener(() => changes++);
    const PurificationRule localEdit = PurificationRule(
      id: 'new-edit',
      find: 'new',
    );
    expect(
      restoreBackup(
        target.library,
        'book.json',
        exportBookBytes(source.library, entry),
      ).error,
      isNull,
    );
    expect(() => open.put(localEdit), throwsStateError);
    expect(target.rules.map((r) => r.id), <String>['book-only']);
    expect(open.rules.single.id, 'book-only');
    open.put(localEdit);
    expect(target.rules.map((r) => r.id), <String>['book-only', 'new-edit']);
    final int savedChanges = changes;
    open.reload();
    open.refresh();
    expect(
      changes,
      savedChanges,
      reason: 'unchanged progress/scan must not relayout pages',
    );
    open.dispose();
  });
}
