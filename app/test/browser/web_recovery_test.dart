@TestOn('browser')
library;

import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
// ignore: uri_does_not_exist
import 'dart:indexed_db' as idb;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library_zip.dart';
import 'package:thusfar_app/web/web_storage.dart';

void main() {
  late String databaseName;
  late WebLibrary library;
  setUp(() async {
    databaseName =
        'thusfar_recovery_test_${DateTime.now().microsecondsSinceEpoch}';
    library = await WebLibrary.open(databaseName: databaseName);
  });
  tearDown(() async {
    library.close();
    await html.window.indexedDB!.deleteDatabase(databaseName);
  });
  Future<WebBookMeta> seed() => library.importFile(
    'Synthetic book.txt',
    Uint8List.fromList(
      utf8.encode('Chapter 1\nAlice reads a book beside the river.\n' * 4),
    ),
  );

  test(
    'browser trash roundtrip retains book and exact notes and progress',
    () async {
      final WebBookMeta book = await seed();
      final WebReadingState reading = WebReadingState(
        fraction: 0.4,
        returnChapter: 0,
        returnFraction: 0.2,
        returnOffset: 5,
      )..addNote(0, 0.3, 'Fixture thought');
      await library.saveState(book.id, reading);
      final Json beforeBook = (await library.load(book.id))!.data;
      await library.remove(book.id);
      expect(await library.list(), isEmpty);
      final WebTrashEntry trash = (await library.listTrash()).single;
      expect(trash.title, book.title);
      expect(trash.issue, isNull);
      await library.restoreFromTrash(trash.key);
      expect((await library.load(book.id))!.data, beforeBook);
      expect((await library.state(book.id)).toJson(), reading.toJson());
      expect(await library.listTrash(), isEmpty);
    },
  );

  test('browser preview is readonly for new and duplicate books', () async {
    final WebBookMeta book = await seed();
    final Uint8List backup = await library.exportBackupBytes(book.id);
    expect(jsonDecode(utf8.decode(backup))['exported'], isA<num>());
    final Json before = (await library.state(book.id)).toJson();
    await library.importBackup(backup, previewOnly: true);
    expect((await library.state(book.id)).toJson(), before);
    await library.remove(book.id);
    await library.importBackup(backup, previewOnly: true);
    expect(await library.list(), isEmpty);
    expect(await library.listTrash(), hasLength(1));
  });

  test(
    'browser duplicate conflict keeps trash and explicit clear removes only its row',
    () async {
      final WebBookMeta book = await seed();
      await library.remove(book.id);
      final WebTrashEntry trash = (await library.listTrash()).single;
      await seed();
      await expectLater(library.restoreFromTrash(trash.key), throwsStateError);
      expect(await library.listTrash(), hasLength(1));
      expect(await library.list(), hasLength(1));
      await library.permanentlyDeleteFromTrash(trash.key);
      expect(await library.listTrash(), isEmpty);
      expect(await library.list(), hasLength(1));
    },
  );

  test(
    'damaged browser row is reported without hiding healthy recovery rows',
    () async {
      final WebBookMeta book = await seed();
      await library.remove(book.id);
      final idb.Database db = await html.window.indexedDB!.open(databaseName);
      final idb.Transaction write = db.transaction('trash', 'readwrite');
      final done = write.completed;
      await write
          .objectStore('trash')
          .put('{broken original bytes', 'broken-fixture');
      await done;
      final List<WebTrashEntry> rows = await library.listTrash();
      expect(rows, hasLength(2));
      expect(
        rows.singleWhere((row) => row.key == 'broken-fixture').issue,
        contains('损坏'),
      );
      await library.restoreFromTrash(
        rows.singleWhere((row) => row.issue == null).key,
      );
      expect(await library.list(), hasLength(1));
      final idb.Transaction read = db.transaction('trash', 'readonly');
      expect(
        await read.objectStore('trash').getObject('broken-fixture'),
        '{broken original bytes',
      );
      db.close();
    },
  );

  test(
    'all failed browser ZIP preserves all failures and explicit settings outcome',
    () async {
      final String? prior =
          html.window.localStorage['thusfar-web-restore-report-v1'];
      addTearDown(() {
        if (prior == null) {
          html.window.localStorage.remove('thusfar-web-restore-report-v1');
        } else {
          html.window.localStorage['thusfar-web-restore-report-v1'] = prior;
        }
      });
      final List<Uint8List> bad = List.generate(
        6,
        (index) => Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'format': 'thusfar-web-backup-v1',
              'meta': {'title': 'Broken $index'},
            }),
          ),
        ),
      );
      final WebLibraryZipRestoreResult result = await library
          .importLibraryZipData(LibraryZipData(bad, {}), applySettings: true);
      expect(result.imported, 0);
      expect(result.report.failed, 6);
      expect(result.failures, hasLength(6));
      expect(
        result.report.entries.map((entry) => entry.title),
        List.generate(6, (i) => 'Broken $i'),
      );
      expect(result.report.settingsStatus, contains('跳过'));
      expect(result.reportError, isNull);
      expect(library.lastRestoreReport!.toJson(), result.report.toJson());
    },
  );
}
