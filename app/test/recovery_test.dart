import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/backup.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/library_zip.dart';
import 'package:thusfar_app/data/restore_report.dart';
import 'package:thusfar_app/screens/recovery_screen.dart';
import 'package:thusfar_app/ui/theme.dart';

import 'backup_test.dart' as fixture;

class _Library extends Library {
  _Library(super.root);
  bool failQueue = false;
  @override
  void setReadingList(List<String> ids) {
    if (failQueue) throw const FileSystemException('synthetic queue failure');
    super.setReadingList(ids);
  }
}

void main() {
  late Directory root;
  late _Library library;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('thusfar-recovery-fixture-');
    library = _Library(root);
    await library.scan();
  });
  tearDown(() {
    library.dispose();
    root.deleteSync(recursive: true);
  });

  Future<BookEntry> seed() async {
    final ImportResult result = restoreBackup(
      library,
      'fixture',
      fixture.bytes(fixture.sample()),
    );
    expect(result.error, isNull);
    await library.scan();
    return library.books.single;
  }

  Map<String, String> tree() => {
    for (final File file in root.listSync(recursive: true).whereType<File>())
      file.path.substring(root.path.length): base64Encode(
        file.readAsBytesSync(),
      ),
  };

  test(
    'restore preview validates new, identical and conflicting backups without writes',
    () async {
      final before = tree();
      expect(
        restoreBackup(
          library,
          'fixture',
          fixture.bytes(fixture.sample()),
          previewOnly: true,
        ).error,
        isNull,
      );
      expect(tree(), before);
      await seed();
      final existing = tree();
      expect(
        restoreBackup(
          library,
          'fixture',
          fixture.bytes(fixture.sample()),
          previewOnly: true,
        ).existed,
        isTrue,
      );
      expect(tree(), existing);
      final Json conflict = fixture.sample();
      ((conflict['notebook'] as List).single as Json)['text'] = 'different';
      expect(
        restoreBackup(
          library,
          'conflict',
          fixture.bytes(conflict),
          previewOnly: true,
        ).error,
        isNotNull,
      );
      expect(tree(), existing);
    },
  );

  test(
    'trash restore preserves exact book bytes, drafts, notes, progress and queue',
    () async {
      final BookEntry book = await seed();
      library.setReadingList([book.id]);
      File(
        '${book.dir.path}/.note-draft-test',
      ).writeAsStringSync('draft bytes');
      final String notebook = File(
        '${book.dir.path}/notebook.json',
      ).readAsStringSync();
      final Progress progress = library.progressOf(book.id)!;
      await library.remove(book);
      expect(library.books, isEmpty);
      expect(library.progressOf(book.id), isNull);
      final TrashedBook trash = library.listTrash().single;
      expect(trash.title, 'Backup fixture');
      expect(trash.bytes, greaterThan(0));
      await library.restoreFromTrash(trash);
      expect(library.books.single.id, book.id);
      expect(library.progressOf(book.id)!.toJson(), progress.toJson());
      expect(library.readingList, [book.id]);
      expect(
        File('${book.dir.path}/notebook.json').readAsStringSync(),
        notebook,
      );
      expect(
        File('${book.dir.path}/.note-draft-test').readAsStringSync(),
        'draft bytes',
      );
      expect(library.listTrash(), isEmpty);
    },
  );

  test(
    'queue failure rolls restored progress back on disk and leaves trash recoverable',
    () async {
      final BookEntry book = await seed();
      library.setReadingList([book.id]);
      await library.remove(book);
      final TrashedBook trash = library.listTrash().single;
      final before = tree();
      library.failQueue = true;
      await expectLater(
        library.restoreFromTrash(trash),
        throwsA(isA<FileSystemException>()),
      );
      expect(tree(), before);
      expect(library.progressOf(book.id), isNull);
      expect(library.readingList, isEmpty);
      expect(library.listTrash(), hasLength(1));
      library.failQueue = false;
      await library.restoreFromTrash(trash);
      expect(library.books.single.id, book.id);
    },
  );

  test('duplicate on shelf cannot overwrite the trash version', () async {
    final BookEntry book = await seed();
    await library.remove(book);
    final TrashedBook trash = library.listTrash().single;
    await seed();
    final before = tree();
    await expectLater(library.restoreFromTrash(trash), throwsStateError);
    expect(tree(), before);
  });

  test(
    'damaged trash entry stays visible without hiding valid entries',
    () async {
      final BookEntry book = await seed();
      await library.remove(book);
      final Directory broken = Directory(
        '${root.path}/trash/0123456789abcdef-broken',
      )..createSync();
      File('${broken.path}/book.json').writeAsStringSync('{broken');
      File('${broken.path}/trash-info.json').writeAsStringSync('[]');
      final List<TrashedBook> trash = library.listTrash();
      expect(trash, hasLength(2));
      expect(trash.where((e) => e.canRestore), hasLength(1));
      expect(trash.singleWhere((e) => !e.canRestore).issue, contains('损坏'));
      await library.restoreFromTrash(trash.singleWhere((e) => e.canRestore));
      expect(library.books.single.id, book.id);
      expect(broken.existsSync(), isTrue);
    },
  );

  test(
    'all failed ZIP restore retains every per-book error and durable settings status',
    () {
      final List<Json> bad = List.generate(
        5,
        (i) => fixture.sample()
          ..['book'] = {
            ...fixture.sample()['book'] as Json,
            'title': 'Damaged $i',
          }
          ..['progress'] = {'pos': 9999, 'cutoff': 9999},
      );
      final LibraryZipRestoreResult result = restoreLibraryZipData(
        library,
        LibraryZipData(bad.map(fixture.bytes).toList(), {}),
      );
      expect(result.imported, 0);
      expect(result.entries, hasLength(5));
      expect(
        result.entries.every((e) => e.status == 'conflict' && e.detail != null),
        isTrue,
      );
      final RestoreReport report = RestoreReport(
        created: DateTime.now(),
        entries: result.entries,
        settingsStatus: '冲突时保留当前设置',
      );
      library.saveRestoreReport(report);
      final Library reopened = Library(root);
      expect(
        reopened.lastRestoreReport!.entries.map((e) => e.title),
        bad.map((b) => (b['book'] as Json)['title']),
      );
      expect(reopened.lastRestoreReport!.failed, 5);
      expect(reopened.lastRestoreReport!.settingsStatus, report.settingsStatus);
      reopened.dispose();
    },
  );

  testWidgets(
    'permanent clear requires confirmation and cancellation keeps trash',
    (tester) async {
      final BookEntry book = await seed();
      await library.remove(book);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: TrashScreen(library: library),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('永久删除'));
      await tester.pumpAndSettle();
      expect(find.text('永久删除这本书？'), findsOneWidget);
      expect(find.textContaining('无法撤销'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(library.listTrash(), hasLength(1));
      await tester.tap(find.text('永久删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '永久删除').last);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pumpAndSettle();
      expect(library.listTrash(), isEmpty);
      expect(find.text('回收站是空的'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test(
    'damaged saved progress prevents restore without changing bytes',
    () async {
      final BookEntry book = await seed();
      await library.remove(book);
      final TrashedBook trash = library.listTrash().single;
      File(
        '${trash.dir.path}/reading-progress.json',
      ).writeAsStringSync('{bad progress');
      final before = tree();
      await expectLater(library.restoreFromTrash(trash), throwsStateError);
      expect(tree(), before);
      expect(library.books, isEmpty);
    },
  );

  for (final String scope in ['range:0:0', 'read:8']) {
    test('native backup and preview preserve new web scope $scope', () async {
      final Json input = fixture.sample()
        ..['web_preparation'] = {
          'schema': 'thusfar-web-ai-v1',
          'scope': scope,
          'phase': 'paused',
          'endpoint': 'https://fixture.invalid/v1',
          'model': 'synthetic-model',
          'updated_at': 0,
          'results': <String, Object?>{},
          'events': <Object?>[],
          'target_count': 0,
          'completed_count': 0,
        };
      final before = tree();
      final ImportResult preview = restoreBackup(
        library,
        'web-scope',
        fixture.bytes(input),
        previewOnly: true,
      );
      expect(preview.error, isNull);
      expect(tree(), before);
      expect(
        restoreBackup(library, 'web-scope', fixture.bytes(input)).error,
        isNull,
      );
      await library.scan();
      final Json exported =
          jsonDecode(
                utf8.decode(exportBookBytes(library, library.books.single)),
              )
              as Json;
      expect((exported['web_preparation'] as Json)['scope'], scope);
      expect(
        restoreBackup(library, 'roundtrip', fixture.bytes(exported)).error,
        isNull,
      );
    });
  }
}
