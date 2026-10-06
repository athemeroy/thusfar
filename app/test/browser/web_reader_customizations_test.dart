@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library_zip.dart';
import 'package:thusfar_app/data/reader_customizations.dart';
import 'package:thusfar_app/ui/theme.dart';
import 'package:thusfar_app/web/web_storage.dart';
import 'package:thusfar_app/web/webdav_sync.dart';

const _transferKey = 'thusfar-web-reader-customizations-transfer-v1';
const _settingsKeys = <String>[
  _transferKey,
  'thusfar-web-library-settings-transfer-v1',
  'thusfar-web-model-profile-v1',
  'thusfar-web-reading-queue-v1',
  'thusfar-web-prefs',
  'thusfar-web-restore-report-v1',
];

Json _rule(String id, String? bookId, {bool enabled = true}) => {
  'id': id,
  'find': 'Alice',
  'replacement': 'Reader',
  'enabled': enabled,
  'bookId': bookId,
};

Json _native(String id, {String paragraph = 'Alice reads beside the river.'}) {
  const String heading = 'Chapter 1';
  final int length = heading.length + paragraph.length;
  final Json book = {
    'title': 'Portable $id',
    'len': length,
    'lang': 'en',
    'blocks': <Json>[
      {'k': 'h', 't': heading, 'o': 0},
      {'k': 'p', 't': paragraph, 'o': heading.length},
    ],
    'chapters': <Json>[
      {'title': heading, 'b0': 0, 'b1': 2, 'o0': 0, 'o1': length},
    ],
    'notes': <String, Object?>{},
  };
  return {
    'format': 'yedu-book/2',
    'id': id,
    'book': book,
    'assets': <String, Object?>{},
    'kg': <String, Object?>{'log': <Object?>[]},
    'meta': <String, Object?>{'filename': 'original.TXT'},
    'reader_customizations': <String, Object?>{
      'version': 1,
      'bookId': id,
      'source': readerCustomizationSource(book),
      'purification': <Json>[_rule('$id-rule', id, enabled: false)],
      'directory': <String, Object?>{
        'version': 1,
        'bookId': id,
        'length': length,
        'enabled': true,
        'rule': 'english',
        'prefix': '',
        'rows': <Json>[
          {'title': heading, 'offset': 0},
        ],
      },
      'globalRulesOmitted': 2,
    },
  };
}

Uint8List _bytes(Json value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
Json _decode(Uint8List bytes) => jsonDecode(utf8.decode(bytes)) as Json;
Json _customizations(Json backup) =>
    (backup['native_backup'] as Json)['reader_customizations'] as Json;

LibraryZipData _archive(List<Json> books) {
  final Json customizations = {
    'format': 'thusfar-reader-library',
    'version': 1,
    'books': <Json>[
      for (final Json book in books)
        {
          'bookId': book['id'],
          'source': readerCustomizationSource(book['book'] as Json),
        },
    ],
    'purification': <Json>[
      _rule('global-before', null),
      for (final Json book in books) ...<Json>[
        ...((book['reader_customizations'] as Json)['purification']
            as List<Json>),
        if (identical(book, books.first))
          _rule('global-after-first', null, enabled: false),
      ],
    ],
  };
  return LibraryZipCodec.decode(
    LibraryZipCodec.encode(
      books: books.map(_bytes).toList(),
      settings: <String, Object?>{},
      customizations: customizations,
    ),
  );
}

class _SnapshotClient extends Fake implements WebDavClient {
  Uint8List? uploaded;
  final Completer<void> uploadedReady = Completer<void>();
  final WebDavSnapshot snapshot = WebDavSnapshot(
    '20261006T010203004Z-abcdef123456.thusfar.json',
    Uri.parse(
      'https://fixture.invalid/20261006T010203004Z-abcdef123456.thusfar.json',
    ),
  );
  @override
  Future<WebDavSnapshot> upload(
    Uint8List bytes, {
    void Function(int sent, int total)? onProgress,
  }) async {
    uploaded = bytes;
    uploadedReady.complete();
    return snapshot;
  }

  @override
  Future<Uint8List> download(WebDavSnapshot snapshot) async => uploaded!;
  @override
  void dispose() {}
}

class _SnapshotLibrary extends Fake implements WebLibrary {
  _SnapshotLibrary(this.library);
  final WebLibrary library;
  Object? lastError;
  final Completer<void> previewed = Completer<void>();
  final Completer<void> imported = Completer<void>();

  @override
  Future<Uint8List> exportBackupBytes(String id) async {
    try {
      return await library.exportBackupBytes(id);
    } on Object catch (error) {
      lastError = error;
      rethrow;
    }
  }

  @override
  Future<String> importBackup(
    Uint8List bytes, {
    bool previewOnly = false,
  }) async {
    final String id = await library.importBackup(
      bytes,
      previewOnly: previewOnly,
    );
    (previewOnly ? previewed : imported).complete();
    return id;
  }
}

Future<void> _tapForTransfer(
  WidgetTester tester,
  Finder action,
  Completer<void> completed,
  String stage,
  _SnapshotLibrary library,
) async {
  // Start the tap and every resulting IndexedDB await in the real zone. A
  // fake-zone continuation can outlive IndexedDB's native transaction window,
  // even when periodically pumped. Keep the real operation bounded and make
  // any delegate failure visible rather than waiting forever on a completer.
  await tester.runAsync(() async {
    await tester.tap(action);
    await completed.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        throw StateError('WebDAV $stage did not finish: ${library.lastError}');
      },
    );
  });
  expect(tester.takeException(), isNull);
}

void main() {
  late WebLibrary library;
  late String databaseName;
  late Map<String, String?> priorSettings;

  setUp(() async {
    priorSettings = {
      for (final String key in _settingsKeys)
        key: html.window.localStorage[key],
    };
    for (final String key in _settingsKeys) {
      html.window.localStorage.remove(key);
    }
    databaseName =
        'thusfar_customizations_${DateTime.now().microsecondsSinceEpoch}';
    library = await WebLibrary.open(databaseName: databaseName);
  });
  tearDown(() async {
    library.close();
    await html.window.indexedDB!.deleteDatabase(databaseName);
    for (final MapEntry<String, String?> entry in priorSettings.entries) {
      if (entry.value == null) {
        html.window.localStorage.remove(entry.key);
      } else {
        html.window.localStorage[entry.key] = entry.value!;
      }
    }
  });

  test(
    'native metadata roundtrips without enabling Web reader transforms',
    () async {
      final Json native = _native('native-book-a');
      final String id = await library.importBackup(_bytes(native));
      final WebBook book = (await library.load(id))!;
      expect(book.data, native['book']);
      expect(book.blocks.last['t'], 'Alice reads beside the river.');
      expect(book.chapters.single['title'], 'Chapter 1');
      final Json output = _decode(await library.exportBackupBytes(id));
      expect(_customizations(output), native['reader_customizations']);
      expect((output['native_backup'] as Json)['id'], 'native-book-a');
      expect(id, isNot('native-book-a'));
      expect(output.containsKey('reader_customizations'), isFalse);
    },
  );

  test(
    'same-book browser merge keeps original native source identity and legacy omission',
    () async {
      final Json native = _native('native-book-a');
      const String browserId = '0123456789abcdef01234567';
      await library.importBackup(
        _bytes({
          'format': 'thusfar-web-backup-v1',
          'meta': {'id': browserId, 'title': 'Portable native-book-a'},
          'book': native['book'],
          'images': <String, Object?>{},
          'state': <String, Object?>{},
        }),
      );
      expect(await library.importBackup(_bytes(native)), browserId);
      final Json expected = native['reader_customizations'] as Json;
      native.remove('reader_customizations');
      await library.importBackup(_bytes(native));
      final Json output = _decode(await library.exportBackupBytes(browserId));
      expect(_customizations(output), expected);
      expect(_customizations(output)['bookId'], 'native-book-a');
      expect(await library.list(), hasLength(1));
    },
  );

  test(
    'customization conflict previews and imports leave local metadata untouched',
    () async {
      final Json native = _native('native-book-a');
      final String id = await library.importBackup(_bytes(native));
      final Json before = _customizations(
        _decode(await library.exportBackupBytes(id)),
      );
      final Json changed = _native('native-book-a');
      (((changed['reader_customizations'] as Json)['purification']
                  as List<Json>)
              .single)['replacement'] =
          'Another';
      for (final bool preview in [true, false]) {
        await expectLater(
          library.importBackup(_bytes(changed), previewOnly: preview),
          throwsA(isA<WebBackupConflict>()),
        );
        expect(
          _customizations(_decode(await library.exportBackupBytes(id))),
          before,
        );
      }
    },
  );

  test(
    'source mismatch, malformed directory, unknown fields and global rule injection are rejected',
    () async {
      for (final void Function(Json) damage in <void Function(Json)>[
        (Json custom) => custom['source'] = '0' * 64,
        (Json custom) => (custom['directory'] as Json)['rows'] = <Json>[
          {'title': 'Future invented heading', 'offset': 0},
        ],
        (Json custom) => custom['api_key'] = 'not-exportable',
        (Json custom) =>
            (custom['purification'] as List<Json>).single['bookId'] = null,
      ]) {
        final Json native = _native('native-book-a');
        damage(native['reader_customizations'] as Json);
        await expectLater(
          library.importBackup(_bytes(native)),
          throwsFormatException,
        );
        expect(await library.list(), isEmpty);
      }
    },
  );

  test(
    'legacy backups remain readable and do not invent customization metadata',
    () async {
      final Json legacy = _native('native-book-a')
        ..remove('reader_customizations');
      final String id = await library.importBackup(_bytes(legacy));
      final Json output = _decode(await library.exportBackupBytes(id));
      expect(
        (output['native_backup'] as Json).containsKey('reader_customizations'),
        isFalse,
      );
    },
  );

  test(
    'chapter verdict enrichment does not invalidate immutable source metadata',
    () async {
      final Json native = _native('native-book-a');
      final String id = await library.importBackup(_bytes(native));
      final Json chapter =
          ((native['book'] as Json)['chapters'] as List<Json>).single;
      chapter['spoil'] = false;
      chapter['spoilSource'] = 'model';
      await library.importBackup(_bytes(native));
      expect(
        _customizations(_decode(await library.exportBackupBytes(id))),
        native['reader_customizations'],
      );
      expect((await library.load(id))!.chapters.single['spoilSource'], 'model');
    },
  );

  test(
    'disabled directory sidecar is preserved without becoming enabled',
    () async {
      final Json native = _native('native-book-a');
      (native['reader_customizations']
          as Json)['directory'] = <String, Object?>{
        'version': 1,
        'bookId': 'native-book-a',
        'length': (native['book'] as Json)['len'],
        'enabled': false,
      };
      final String id = await library.importBackup(_bytes(native));
      expect(
        _customizations(_decode(await library.exportBackupBytes(id))),
        native['reader_customizations'],
      );
    },
  );

  test(
    'full ZIP preserves global order only after explicit settings consent',
    () async {
      final LibraryZipData archive = _archive([_native('native-book-a')]);
      final WebLibraryZipRestoreResult skipped = await library
          .importLibraryZipData(archive, applySettings: false);
      expect(skipped.complete, isTrue);
      expect(html.window.localStorage[_transferKey], isNull);
      expect(
        LibraryZipCodec.decode(
          await library.exportLibraryZipBytes(),
        ).customizations,
        isNull,
      );
      final WebLibraryZipRestoreResult accepted = await library
          .importLibraryZipData(archive, applySettings: true);
      expect(accepted.complete, isTrue);
      final LibraryZipData exported = LibraryZipCodec.decode(
        await library.exportLibraryZipBytes(),
      );
      expect(exported.customizations, archive.customizations);
      expect(accepted.report.settingsStatus, contains('网页版不应用'));
      expect(
        _customizations(_decode(exported.books.single))['bookId'],
        'native-book-a',
      );
    },
  );

  test(
    'full ZIP export removes absent book scope without binding it to new shelf entries',
    () async {
      final LibraryZipData archive = _archive([
        _native('native-book-a'),
        _native('native-book-b', paragraph: 'Bob reads another story.'),
      ]);
      await library.importLibraryZipData(archive, applySettings: true);
      final WebBookMeta removed = (await library.list()).singleWhere(
        (b) => b.title == 'Portable native-book-a',
      );
      await library.remove(removed.id);
      await library.importFile(
        'Fresh.txt',
        Uint8List.fromList(
          utf8.encode('Chapter 1\nA completely unrelated book.'),
        ),
      );
      final LibraryZipData exported = LibraryZipCodec.decode(
        await library.exportLibraryZipBytes(),
      );
      final Json custom = exported.customizations!;
      expect(
        (custom['books'] as List<Object?>).map(
          (row) => (row as Json)['bookId'],
        ),
        ['native-book-b'],
      );
      expect(
        (custom['purification'] as List<Object?>).map(
          (row) => (row as Json)['id'],
        ),
        ['global-before', 'global-after-first', 'native-book-b-rule'],
      );
      // The retained source is not mutated by export, so recycling the same book
      // also restores its exact original scoped transfer data.
      final WebTrashEntry trash = (await library.listTrash()).single;
      await library.restoreFromTrash(trash.key);
      expect(
        LibraryZipCodec.decode(
          await library.exportLibraryZipBytes(),
        ).customizations,
        archive.customizations,
      );
    },
  );

  test(
    'different full-library rule order is reported without overwriting stored data or settings',
    () async {
      final LibraryZipData first = _archive([_native('native-book-a')]);
      await library.importLibraryZipData(first, applySettings: true);
      final String saved = html.window.localStorage[_transferKey]!;
      final String prefs = html.window.localStorage['thusfar-web-prefs']!;
      final Json changed = jsonDecode(jsonEncode(first.customizations)) as Json;
      changed['purification'] = (changed['purification'] as List<Object?>)
          .reversed
          .toList();
      final WebLibraryZipRestoreResult result = await library
          .importLibraryZipData(
            LibraryZipData(first.books, <String, Object?>{
              'reader': <String, Object?>{'fontSize': 31},
            }, customizations: changed),
            applySettings: true,
          );
      expect(result.complete, isFalse);
      expect(result.settingsError, contains('阅读自定义不同'));
      expect(html.window.localStorage[_transferKey], saved);
      expect(html.window.localStorage['thusfar-web-prefs'], prefs);
    },
  );

  test(
    'damaged retained full-library customizations fail export rather than disappearing',
    () async {
      await library.importBackup(_bytes(_native('native-book-a')));
      html.window.localStorage[_transferKey] = '{broken';
      await expectLater(library.exportLibraryZipBytes(), throwsFormatException);
      expect(html.window.localStorage[_transferKey], '{broken');
    },
  );

  test(
    'direct library restore cannot retain a forged source binding',
    () async {
      final LibraryZipData archive = _archive([_native('native-book-a')]);
      final Json forged =
          jsonDecode(jsonEncode(archive.customizations)) as Json;
      ((forged['books'] as List<Object?>).single as Json)['source'] = '0' * 64;
      final WebLibraryZipRestoreResult result = await library
          .importLibraryZipData(
            LibraryZipData(
              archive.books,
              archive.settings,
              customizations: forged,
            ),
            applySettings: true,
          );
      expect(result.complete, isFalse);
      expect(result.imported, 1);
      expect(result.settingsError, contains('来源不符'));
      expect(html.window.localStorage[_transferKey], isNull);
    },
  );

  testWidgets(
    'WebDAV upload and confirmed snapshot merge retain native customizations',
    (WidgetTester tester) async {
      final Json native = _native('native-book-a');
      final String id = (await tester.runAsync(
        () => library.importBackup(_bytes(native)),
      ))!;
      final List<WebBookMeta> books = (await tester.runAsync(library.list))!;
      final _SnapshotLibrary transferLibrary = _SnapshotLibrary(library);
      final _SnapshotClient client = _SnapshotClient();
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(
            Brightness.light,
          ).copyWith(splashFactory: InkRipple.splashFactory),
          home: WebDavSyncPage(
            library: transferLibrary,
            books: books,
            clientFactory: (_, _, _) => client,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('上传新快照'));
      await _tapForTransfer(
        tester,
        find.text('上传新快照'),
        client.uploadedReady,
        'upload',
        transferLibrary,
      );
      await tester.pumpAndSettle();
      expect(client.uploaded, isNotNull);
      expect(
        _customizations(_decode(client.uploaded!)),
        native['reader_customizations'],
      );
      await tester.ensureVisible(find.text('2026-10-06 01:02:03 UTC'));
      await _tapForTransfer(
        tester,
        find.text('2026-10-06 01:02:03 UTC'),
        transferLibrary.previewed,
        'preview',
        transferLibrary,
      );
      await tester.pumpAndSettle();
      await _tapForTransfer(
        tester,
        find.text('导入到此浏览器'),
        transferLibrary.imported,
        'import',
        transferLibrary,
      );
      await tester.pumpAndSettle();
      final Uint8List exported = (await tester.runAsync(
        () => library.exportBackupBytes(id),
      ))!;
      expect(
        _customizations(_decode(exported)),
        native['reader_customizations'],
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test(
    'full ZIP export rejects a reused native ID with stale retained source policy',
    () async {
      final LibraryZipData archive = _archive([_native('native-book-a')]);
      expect(
        (await library.importLibraryZipData(
          archive,
          applySettings: true,
        )).complete,
        isTrue,
      );
      final String id = (await library.list()).single.id;
      await library.remove(id);
      await library.importBackup(
        _bytes(
          _native('native-book-a', paragraph: 'A different immutable source.'),
        ),
      );
      await expectLater(library.exportLibraryZipBytes(), throwsFormatException);
    },
  );
  test(
    'removed-book self-export reimports without a false policy conflict',
    () async {
      final LibraryZipData original = _archive([
        _native('native-book-a'),
        _native('native-book-b', paragraph: 'A different book.'),
      ]);
      expect(
        (await library.importLibraryZipData(
          original,
          applySettings: true,
        )).complete,
        isTrue,
      );
      final String removed = (await library.list())
          .singleWhere((book) => book.title == 'Portable native-book-a')
          .id;
      await library.remove(removed);
      final LibraryZipData remaining = LibraryZipCodec.decode(
        await library.exportLibraryZipBytes(),
      );
      expect(
        (await library.importLibraryZipData(
          remaining,
          applySettings: true,
        )).complete,
        isTrue,
      );
      expect(
        LibraryZipCodec.decode(
          await library.exportLibraryZipBytes(),
        ).customizations,
        remaining.customizations,
      );
      final WebTrashEntry trash = (await library.listTrash()).single;
      await library.restoreFromTrash(trash.key);
      expect(
        LibraryZipCodec.decode(
          await library.exportLibraryZipBytes(),
        ).customizations,
        original.customizations,
      );
    },
  );
}
