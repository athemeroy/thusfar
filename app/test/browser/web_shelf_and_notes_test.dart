@TestOn('browser')
library;

import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/shelf_organization.dart';
import 'package:thusfar_app/web/web_storage.dart';

const String _organizationKey = 'thusfar-web-shelf-organization-v1';

Json _nativeFixture() {
  const String text = 'Alice reads beside the river.';
  return <String, Object?>{
    'format': 'yedu-book/2',
    'id': '0123456789abcdef',
    'book': <String, Object?>{
      'title': '书摘示例',
      'author': '作者',
      'lang': 'en',
      'len': text.length,
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
        },
      ],
      'notes': <String, Object?>{},
    },
    'assets': <String, Object?>{},
    'kg': <String, Object?>{'log': <Object?>[]},
    'meta': <String, Object?>{},
    'status': <String, Object?>{'state': 'done', 'frontier': text.length},
    'notebook': <Json>[
      <String, Object?>{
        'id': 'highlight0001',
        'kind': 'note',
        'start': 0,
        'end': 5,
        'quote': 'Alice',
        'text': '',
        'revision': 1,
        'created': 1,
        'updated': 1,
        'deleted': false,
      },
      <String, Object?>{
        'id': 'thought00001',
        'kind': 'note',
        'start': 6,
        'end': 11,
        'quote': 'reads',
        'text': '我的想法',
        'revision': 1,
        'created': 1,
        'updated': 1,
        'deleted': false,
      },
    ],
    'shelf_organization': <String, Object?>{
      'collections': <String>['小说'],
      'books': <Json>[
        <String, Object?>{'index': 0, 'collection': '小说', 'finished': true},
      ],
    },
  };
}

Uint8List _bytes(Json value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
Json _decode(Uint8List bytes) => jsonDecode(utf8.decode(bytes)) as Json;

void main() {
  late WebLibrary library;
  late String databaseName;
  String? oldOrganization;
  setUp(() async {
    oldOrganization = html.window.localStorage[_organizationKey];
    html.window.localStorage.remove(_organizationKey);
    databaseName = 'web_shelf_notes_${DateTime.now().microsecondsSinceEpoch}';
    library = await WebLibrary.open(databaseName: databaseName);
  });
  tearDown(() async {
    library.close();
    await html.window.indexedDB!.deleteDatabase(databaseName);
    if (oldOrganization == null) {
      html.window.localStorage.remove(_organizationKey);
    } else {
      html.window.localStorage[_organizationKey] = oldOrganization!;
    }
  });

  test(
    'native highlights keep their category, anchors and shelf labels',
    () async {
      final String id = await library.importBackup(_bytes(_nativeFixture()));
      final WebReadingState state = await library.state(id);
      final WebPersonalItem highlight = state.notes.singleWhere(
        (item) => item.id == 'highlight0001',
      );
      expect(highlight.style, 'highlight');
      expect(highlight.text, 'Alice');
      expect(highlight.sourceStart, 0);
      expect(highlight.sourceEnd, 5);
      expect(
        state.notes.singleWhere((item) => item.id == 'thought00001').style,
        'thought',
      );
      expect(WebLibrary.shelfOrganization().books[id]!.collection, '小说');
      expect(WebLibrary.shelfOrganization().books[id]!.finished, isTrue);
      final Json exported = _decode(await library.exportBackupBytes(id));
      expect(
        exported['shelf_organization'],
        _nativeFixture()['shelf_organization'],
      );
      expect(
        (exported['native_backup']! as Json)['shelf_organization'],
        exported['shelf_organization'],
      );
    },
  );

  test(
    'Web shelf edits replace the embedded native copy when exported',
    () async {
      final String id = await library.importBackup(_bytes(_nativeFixture()));
      final ShelfOrganization organization = WebLibrary.shelfOrganization();
      organization.collections.add('经典');
      organization.books[id] = const ShelfBookState(
        collection: '经典',
        finished: false,
      );
      WebLibrary.saveShelfOrganization(organization);
      final Json exported = _decode(await library.exportBackupBytes(id));
      final Json shelf = exported['shelf_organization']! as Json;
      expect((shelf['books']! as List<Object?>).single, <String, Object?>{
        'index': 0,
        'collection': '经典',
        'finished': false,
      });
      expect((exported['native_backup']! as Json)['shelf_organization'], shelf);
      expect((exported['state']! as Json)['fraction'], 0);
    },
  );

  test(
    'preview and invalid shelf references leave browser data unchanged',
    () async {
      final Json fixture = _nativeFixture();
      await library.importBackup(_bytes(fixture), previewOnly: true);
      expect(await library.list(), isEmpty);
      expect(html.window.localStorage[_organizationKey], isNull);
      (fixture['shelf_organization']! as Json)['books'] = <Json>[
        <String, Object?>{'index': 1, 'finished': true},
      ];
      await expectLater(
        library.importBackup(_bytes(fixture)),
        throwsFormatException,
      );
      expect(await library.list(), isEmpty);
      expect(html.window.localStorage[_organizationKey], isNull);
    },
  );

  test('a conflicting personal record cannot overwrite shelf labels', () async {
    final String id = await library.importBackup(_bytes(_nativeFixture()));
    final Json wrapper = _decode(await library.exportBackupBytes(id));
    final String before = html.window.localStorage[_organizationKey]!;
    final List<Object?> notes =
        (wrapper['state']! as Json)['notes']! as List<Object?>;
    (notes.last! as Json)['text'] = '冲突的想法';
    wrapper['shelf_organization'] = <String, Object?>{
      'collections': <String>['另一个分类'],
      'books': <Json>[
        <String, Object?>{'index': 0, 'collection': '另一个分类'},
      ],
    };
    await expectLater(
      library.importBackup(_bytes(wrapper)),
      throwsA(isA<WebBackupConflict>()),
    );
    expect(html.window.localStorage[_organizationKey], before);
    expect((await library.state(id)).notes.last.text, '我的想法');
  });

  test(
    'precise reading positions survive browser save, merge and export',
    () async {
      final String id = await library.importBackup(_bytes(_nativeFixture()));
      final WebReadingState reading = await library.state(id);
      reading.sourceOffset = 7;
      reading.fraction = 0.5;
      reading.lastOpened = 100;
      await library.saveState(id, reading);
      final Json wrapper = _decode(await library.exportBackupBytes(id));
      expect((wrapper['state']! as Json)['sourceOffset'], 7);
      // A legacy local record can gain precision at the same reading timestamp.
      reading.sourceOffset = null;
      await library.saveState(id, reading);
      await library.importBackup(_bytes(wrapper));
      expect((await library.state(id)).sourceOffset, 7);
      (wrapper['state']! as Json)['sourceOffset'] = 999;
      await expectLater(
        library.importBackup(_bytes(wrapper)),
        throwsFormatException,
      );
      expect((await library.state(id)).sourceOffset, 7);
    },
  );

  test(
    'old native projections infer style without changing their revision',
    () async {
      final String id = await library.importBackup(_bytes(_nativeFixture()));
      final Json wrapper = _decode(await library.exportBackupBytes(id));
      final List<Object?> notes =
          (wrapper['state']! as Json)['notes']! as List<Object?>;
      for (final Json row in notes.cast<Json>()) {
        row.remove('style');
        row.remove('sourceStart');
        row.remove('sourceEnd');
      }
      await library.importBackup(_bytes(wrapper));
      final WebPersonalItem highlight = (await library.state(id)).notes.first;
      expect(highlight.style, 'highlight');
      expect(highlight.revision, 1);
      expect(highlight.sourceEnd, 5);
    },
  );
}
