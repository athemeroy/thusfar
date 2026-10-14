import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/backup.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/library_zip.dart';
import 'package:thusfar_app/data/shelf_organization.dart';

import 'backup_test.dart' as backup_fixture;

void main() {
  late Directory root;
  late Library library;
  late String id;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('shelf-organization-');
    library = Library(root);
    final ImportResult imported = restoreBackup(
      library,
      'fixture',
      backup_fixture.bytes(backup_fixture.sample()),
    );
    expect(imported.error, isNull);
    id = imported.id!;
    await library.scan();
  });
  tearDown(() {
    library.dispose();
    root.deleteSync(recursive: true);
  });

  test(
    'marking finished and rereading never moves the spoiler boundary',
    () async {
      library.saveProgress(id, 3, 5, 16);
      final String progress = File(
        '${root.path}/progress.json',
      ).readAsStringSync();
      library.setBookFinished(id, true);
      expect(library.isFinished(id), isTrue);
      library.setBookFinished(id, false);
      expect(library.isFinished(id), isFalse);
      await library.scan();
      expect(library.isFinished(id), isFalse);
      expect(File('${root.path}/progress.json').readAsStringSync(), progress);
    },
  );

  test(
    'rename and remove a collection preserve books and completed state',
    () async {
      library.createCollection('想重读');
      library.setBookCollection(id, '想重读');
      library.setBookFinished(id, true);
      library.renameCollection('想重读', '经典');
      await library.scan();
      expect(library.collectionOf(id), '经典');
      library.removeCollection('经典');
      expect(library.collectionOf(id), isNull);
      expect(library.books, hasLength(1));
      expect(library.isFinished(id), isTrue);
    },
  );

  test(
    'single-book and library archives carry shelf labels without changing progress',
    () async {
      library.createCollection('小说');
      library.createCollection('还没放书');
      library.setBookCollection(id, '小说');
      library.saveProgress(id, 3, 5, 16);
      library.setBookFinished(id, true);
      final Uint8List bytes = exportBookBytes(library, library.books.single);
      final Map<String, Object?> payload =
          jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
      expect(payload['shelf_organization'], <String, Object?>{
        'collections': <String>['小说'],
        'books': <Object?>[
          <String, Object?>{'index': 0, 'collection': '小说', 'finished': true},
        ],
      });
      final Directory target = Directory.systemTemp.createTempSync(
        'shelf-restore-',
      );
      final Library restored = Library(target);
      addTearDown(() {
        restored.dispose();
        target.deleteSync(recursive: true);
      });
      final ImportResult result = restoreBackup(restored, 'fixture', bytes);
      expect(result.error, isNull);
      await restored.scan();
      expect(restored.collectionOf(result.id!), '小说');
      expect(restored.isFinished(result.id!), isTrue);
      expect(restored.progressOf(result.id!)!.cutoff, 5);
      final Map<String, Object?> portable = library.organization.exportPortable(
        <String>[id],
      );
      final LibraryZipData zip = LibraryZipCodec.decode(
        LibraryZipCodec.encode(
          books: [bytes],
          settings: <String, Object?>{'shelfOrganization': portable},
        ),
      );
      final ShelfOrganization model = ShelfOrganization()
        ..mergePortable(zip.settings['shelfOrganization'], <String>['new-id']);
      expect(model.collections, <String>['小说', '还没放书']);
      expect(model.books['new-id']!.finished, isTrue);
    },
  );

  test('preview and invalid archive labels cannot mutate a shelf', () {
    final Json payload = backup_fixture.sample();
    payload['shelf_organization'] = <String, Object?>{
      'collections': <String>['小说'],
      'books': <Object?>[
        <String, Object?>{'index': 0, 'collection': '小说', 'finished': true},
      ],
    };
    final ImportResult preview = restoreBackup(
      library,
      'preview',
      backup_fixture.bytes(payload),
      previewOnly: true,
    );
    expect(preview.error, isNull);
    expect(library.organization.collections, isEmpty);
    expect(File('${root.path}/shelf-organization.json').existsSync(), isFalse);
    (payload['shelf_organization']! as Json)['books'] = <Object?>[
      <String, Object?>{'index': 1, 'finished': true},
    ];
    final ImportResult invalid = restoreBackup(
      library,
      'invalid',
      backup_fixture.bytes(payload),
    );
    expect(invalid.error, isNotNull);
    expect(library.organization.collections, isEmpty);
  });
  test('Web highlights roundtrip as native quotes, not thoughts', () async {
    final Json source = backup_fixture.sample();
    final Json wrapper = <String, Object?>{
      'format': webExportFormat,
      'book': source['book'],
      'images': <String, Object?>{},
      'state': <String, Object?>{
        'chapter': 0,
        'fraction': 0.5,
        'sourceOffset': 7,
        'lastOpened': 100,
        'bookmarks': <Object?>[],
        'notes': <Json>[
          <String, Object?>{
            'id': 'webhighlight001',
            'chapter': 0,
            'fraction': 0.5,
            'text': 'Alice',
            'style': 'highlight',
            'sourceStart': 0,
            'sourceEnd': 5,
            'created': 100,
            'updated': 100,
            'revision': 1,
            'deleted': false,
          },
        ],
      },
    };
    final ImportResult result = restoreBackup(
      library,
      'Web highlight',
      backup_fixture.bytes(wrapper),
    );
    expect(result.error, isNull);
    await library.scan();
    final Json exported =
        jsonDecode(utf8.decode(exportBookBytes(library, library.byId(id)!)))
            as Json;
    final Json note = (exported['notebook']! as List<Object?>)
        .cast<Json>()
        .singleWhere((row) => row['id'] == 'webhighlight001');
    expect(note['text'], '');
    expect(note['quote'], 'Alice');
    expect(note['start'], 0);
    expect(note['end'], 5);
    final Json webNote =
        ((exported['web_state']! as Json)['notes']! as List<Object?>)
            .cast<Json>()
            .singleWhere((row) => row['id'] == 'webhighlight001');
    expect(webNote['style'], 'highlight');
    expect(webNote['text'], 'Alice');
    expect(webNote['sourceStart'], 0);
    expect(webNote['sourceEnd'], 5);
    expect(webNote['fraction'], 0.5);
    expect((exported['progress']! as Json)['pos'], 7);
    expect((exported['web_state']! as Json)['sourceOffset'], 7);
  });
}
