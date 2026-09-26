import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/backup.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_core/thusfar_core.dart' show ValueError;

Json sample() => <String, Object?>{
  'format': 'yedu-book/2',
  'book': <String, Object?>{
    'title': 'Backup fixture',
    'len': 16,
    'lang': 'en',
    'blocks': <Json>[
      <String, Object?>{'k': 'p', 't': 'Alice saw a fox.', 'o': 0},
    ],
    'chapters': <Json>[
      <String, Object?>{
        'title': 'One',
        'b0': 0,
        'b1': 1,
        'o0': 0,
        'o1': 16,
        'kind': 'body',
      },
    ],
    'notes': <String, Object?>{},
  },
  'kg': <String, Object?>{
    'log': <Json>[
      <String, Object?>{'t': 'person', 'id': 'p1', 'name': 'Alice', 'p': 0},
    ],
  },
  'meta': <String, Object?>{'auto': true},
  'status': <String, Object?>{'state': 'done', 'frontier': 16},
  'mentions': <String, Object?>{
    '0000': <Object?>[
      <Object?>[0, 5, 'p1', 0],
    ],
  },
  'notebook': <Json>[
    <String, Object?>{
      'id': 'note0001',
      'kind': 'note',
      'start': 0,
      'end': 5,
      'quote': 'Alice',
      'text': 'remember',
      'knowledge_cutoff': 5,
      'deleted': false,
      'revision': 3,
      'operation': 'operation1',
      'created': 10,
      'updated': 20,
    },
  ],
  'manual_entities': <Json>[
    <String, Object?>{
      'id': 'manual01',
      'kind': 'concept',
      'name': 'fox',
      'source_start': 12,
      'knowledge_cutoff': 16,
      'versions': <Json>[
        <String, Object?>{'p': 16, 'note': 'animal'},
      ],
      'deleted': false,
      'revision': 1,
      'operation': 'operation2',
      'created': 10,
      'updated': 20,
    },
  ],
  'progress': <String, Object?>{'pos': 0, 'cutoff': 16},
};

Uint8List bytes(Json value) => utf8.encode(jsonEncode(value));

void main() {
  late Directory root;
  late Library library;
  setUp(() async {
    root = Directory.systemTemp.createTempSync('thusfar-backup-test-');
    library = Library(root);
    await library.scan();
  });
  tearDown(() {
    library.dispose();
    root.deleteSync(recursive: true);
  });

  test(
    'full backup keeps graph, mentions, notes, manual history and reading progress',
    () async {
      final Json input = sample();
      final ImportResult restored = restoreBackup(
        library,
        'fixture.yedu.json',
        bytes(input),
      );
      expect(restored.error, isNull);
      await library.scan();
      final BookEntry book = library.books.single;
      expect(library.progressOf(book.id)!.cutoff, 16);
      final Json output =
          jsonDecode(utf8.decode(exportBookBytes(library, book))) as Json;
      for (final String key in <String>[
        'book',
        'kg',
        'mentions',
        'notebook',
        'manual_entities',
      ]) {
        expect(output[key], input[key], reason: key);
      }
      expect((output['meta']! as Json)['auto'], isFalse);
      final ImportResult repeated = restoreBackup(
        library,
        'same.yedu.json',
        bytes(input),
      );
      expect(repeated.error, isNull);
      expect(repeated.existed, isTrue);
    },
  );

  test(
    'invalid progress is rejected before any directory or progress is published',
    () {
      final Json input = sample()
        ..['progress'] = <String, Object?>{'pos': 50, 'cutoff': 50};
      final ImportResult restored = restoreBackup(
        library,
        'bad.yedu.json',
        bytes(input),
      );
      expect(restored.error, isNotNull);
      expect(library.booksDir.listSync(), isEmpty);
      expect(library.progress, isEmpty);
    },
  );

  test(
    'changed knowledge or personal notes conflict instead of claiming success',
    () {
      final Json input = sample();
      final ImportResult first = restoreBackup(
        library,
        'first.yedu.json',
        bytes(input),
      );
      expect(first.error, isNull);
      final File graph = File('${library.booksDir.path}/${first.id}/kg.json');
      final File notes = File(
        '${library.booksDir.path}/${first.id}/notebook.json',
      );
      final String graphBefore = graph.readAsStringSync();
      final String notesBefore = notes.readAsStringSync();
      ((input['notebook']! as List<Object?>).single! as Json)['text'] =
          'newer notes';
      final ImportResult conflict = restoreBackup(
        library,
        'new.yedu.json',
        bytes(input),
      );
      expect(conflict.error, contains('不同资料'));
      expect(conflict.existed, isFalse);
      expect(graph.readAsStringSync(), graphBefore);
      expect(notes.readAsStringSync(), notesBefore);
      final Json changedGraph = sample();
      (((changedGraph['kg']! as Json)['log']! as List<Object?>).single!
              as Json)['name'] =
          'Alice changed';
      expect(
        restoreBackup(library, 'graph.yedu.json', bytes(changedGraph)).error,
        contains('不同资料'),
      );
      expect(graph.readAsStringSync(), graphBefore);
    },
  );

  test(
    'malformed notes, manual anchors, state and duplicate chapter keys publish nothing',
    () {
      final List<Json> bad = <Json>[
        sample()..['notebook'] = <Object?>[null],
        sample()..['notebook'] = 'not a list',
        sample()..['status'] = <String, Object?>{'frontier': -1},
        sample()..['progress'] = 'not an object',
        sample()..['meta'] = <Object?>[],
        sample()
          ..['mentions'] = <String, Object?>{
            '0': <Object?>[],
            '0000': <Object?>[],
          },
      ];
      final Json wrongQuote = sample();
      ((wrongQuote['notebook']! as List<Object?>).single! as Json)['quote'] =
          'other';
      bad.add(wrongQuote);
      final Json wrongAnchor = sample();
      ((wrongAnchor['manual_entities']! as List<Object?>).single!
              as Json)['source_start'] =
          0;
      bad.add(wrongAnchor);
      for (final Json input in bad) {
        expect(
          restoreBackup(library, 'bad.yedu.json', bytes(input)).error,
          isNotNull,
        );
        expect(library.booksDir.listSync(), isEmpty);
      }
    },
  );

  test(
    'corrupted notes or graph cannot become an apparently complete empty backup',
    () async {
      final ImportResult result = restoreBackup(
        library,
        'fixture.yedu.json',
        bytes(sample()),
      );
      expect(result.error, isNull);
      await library.scan();
      final BookEntry book = library.books.single;
      final File notes = File('${book.dir.path}/notebook.json');
      final String before = notes.readAsStringSync();
      notes.writeAsStringSync('{broken');
      expect(() => exportBookBytes(library, book), throwsA(isA<ValueError>()));
      notes.writeAsStringSync(before);
      File('${book.dir.path}/kg.json').writeAsStringSync('[]');
      expect(() => exportBookBytes(library, book), throwsA(isA<ValueError>()));
    },
  );
}
