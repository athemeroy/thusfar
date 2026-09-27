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

  test('identical text under different book titles remains separate', () async {
    final Json firstBook = sample();
    final Json secondBook = jsonDecode(jsonEncode(firstBook)) as Json;
    (secondBook['book']! as Json)['title'] = 'Another book';
    final ImportResult first = restoreBackup(
      library,
      'first.yedu.json',
      bytes(firstBook),
    );
    final ImportResult second = restoreBackup(
      library,
      'second.yedu.json',
      bytes(secondBook),
    );
    expect(first.error, isNull);
    expect(second.error, isNull);
    expect(second.existed, isFalse);
    expect(second.id, isNot(first.id));
    await library.scan();
    expect(library.books.map((BookEntry book) => book.title).toSet(), <String>{
      'Backup fixture',
      'Another book',
    });
  });

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

  test('failed progress write rolls back a newly published book', () {
    // A directory at the progress file path makes its atomic rename fail
    // after the new book directory has been staged.
    Directory('${root.path}/progress.json').createSync();
    final ImportResult restored = restoreBackup(
      library,
      'fixture.yedu.json',
      bytes(sample()),
    );
    expect(restored.error, isNotNull);
    expect(library.booksDir.listSync(), isEmpty);
    expect(library.progress, isEmpty);
  });

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

  test('same-book merge waits for an active preparation to pause', () {
    final ImportResult first = restoreBackup(
      library,
      'fixture.yedu.json',
      bytes(sample()),
    );
    expect(first.error, isNull);
    final File status = File(
      '${library.booksDir.path}/${first.id}/status.json',
    );
    final Object? original = jsonDecode(status.readAsStringSync());
    status.writeAsStringSync(jsonEncode(<String, Object?>{'state': 'running'}));
    final ImportResult incoming = restoreBackup(
      library,
      'same.yedu.json',
      bytes(sample()),
    );
    expect(incoming.error, contains('先暂停整理'));
    expect(jsonDecode(status.readAsStringSync()), <String, Object?>{
      'state': 'running',
    });
    status.writeAsStringSync(jsonEncode(original));
  });

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

  test(
    'interrupted same-book merge rolls back before export or shelf scan',
    () async {
      final ImportResult restored = restoreBackup(
        library,
        'fixture.yedu.json',
        bytes(sample()),
      );
      expect(restored.error, isNull);
      await library.scan();
      final BookEntry book = library.books.single;
      final File notebookFile = File('${book.dir.path}/notebook.json');
      final Object? originalNotebook = jsonDecode(
        notebookFile.readAsStringSync(),
      );
      final Object? originalManual = jsonDecode(
        File('${book.dir.path}/manual-entities.json').readAsStringSync(),
      );
      final File marker = File('${book.dir.path}/.sync-merge-pending.json');
      marker.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'id': book.id,
          'notebook': originalNotebook,
          'manual_entities': originalManual,
          'web_transfer': null,
          'progress': library.progressOf(book.id)!.toJson(),
        }),
      );
      final List<Object?> partial =
          jsonDecode(notebookFile.readAsStringSync()) as List<Object?>;
      (partial.single! as Json)['text'] = 'partially merged';
      notebookFile.writeAsStringSync(jsonEncode(partial));
      library.saveProgress(book.id, 8, 16, 16);

      expect(() => exportBookBytes(library, book), throwsA(isA<ValueError>()));
      expect(recoverPendingBackupMerges(root), 1);
      expect(marker.existsSync(), isFalse);
      expect(jsonDecode(notebookFile.readAsStringSync()), originalNotebook);
      await library.scan();
      expect(library.progressOf(book.id)!.pos, 0);
      expect(() => exportBookBytes(library, book), returnsNormally);
    },
  );

  test(
    'stale Web graph only merges reading data and keeps newer local graph',
    () async {
      final Json native = sample();
      final ImportResult first = restoreBackup(
        library,
        'fixture.yedu.json',
        bytes(native),
      );
      expect(first.error, isNull);
      await library.scan();
      final BookEntry book = library.books.single;
      final File graph = File('${book.dir.path}/kg.json');
      final Json local = jsonDecode(graph.readAsStringSync()) as Json;
      (local['log']! as List<Object?>).add(<String, Object?>{
        't': 'profile',
        'id': 'p1',
        'p': 10,
        'bio': 'Local profile',
      });
      graph.writeAsStringSync(jsonEncode(local));
      final Json remote = <String, Object?>{
        'format': webExportFormat,
        'book': native['book'],
        'images': <String, Object?>{},
        'state': <String, Object?>{
          'chapter': 0,
          'fraction': 0.5,
          'lastOpened': DateTime.now().millisecondsSinceEpoch + 10000,
          'bookmarks': <Object?>[],
          'notes': <Object?>[],
        },
        'native_backup': <String, Object?>{
          for (final MapEntry<String, Object?> field in native.entries)
            if (field.key != 'book' && field.key != 'assets')
              field.key: field.value,
          'id': book.id,
        },
      };
      final ImportResult merged = restoreBackup(
        library,
        'web.json',
        bytes(remote),
      );
      expect(merged.error, isNull);
      expect(merged.existed, isTrue);
      expect(library.progressOf(book.id)!.pos, 8);
      expect(
        (jsonDecode(graph.readAsStringSync()) as Json)['log'],
        hasLength(2),
      );
    },
  );

  test(
    'newer native graph imports inserted biographies, mentions and frontier',
    () async {
      final Json old = sample();
      old['status'] = <String, Object?>{'state': 'paused', 'frontier': 8};
      final ImportResult first = restoreBackup(
        library,
        'old.yedu.json',
        bytes(old),
      );
      expect(first.error, isNull);
      final Json newer = jsonDecode(jsonEncode(old)) as Json;
      final Json knowledge = newer['kg']! as Json;
      (knowledge['log']! as List<Object?>).addAll(<Json>[
        <String, Object?>{'t': 'recap', 'text': 'New verified recap', 'p': 6},
        <String, Object?>{
          't': 'profile',
          'id': 'p1',
          'bio': 'New verified biography',
          'p': 10,
        },
      ]);
      knowledge['segments'] = <Object?>[
        <Object?>[0, 8, 0],
        <Object?>[8, 16, 0],
      ];
      final Json newMentions = newer['mentions']! as Json;
      newMentions.remove('0000');
      newMentions['0'] = <Object?>[
        <Object?>[0, 5, 'p1', 0],
        <Object?>[6, 9, 'p1', 0],
      ];
      newer['status'] = <String, Object?>{
        'state': 'done',
        'frontier': 16,
        'people': 1,
      };
      final ImportResult merged = restoreBackup(
        library,
        'newer.yedu.json',
        bytes(newer),
      );
      expect(merged.error, isNull);
      expect(merged.existed, isTrue);
      await library.scan();
      final BookEntry book = library.books.single;
      final Json exported =
          jsonDecode(utf8.decode(exportBookBytes(library, book))) as Json;
      expect((exported['kg']! as Json)['log'], (newer['kg']! as Json)['log']);
      expect(
        (exported['mentions']! as Json)['0000'],
        (newer['mentions']! as Json)['0'],
      );
      expect((exported['status']! as Json)['frontier'], 16);
      expect((exported['status']! as Json)['state'], 'done');
      expect(Directory('${root.path}/sync-backups').listSync(), isNotEmpty);
      expect(
        File('${book.dir.path}/.sync-merge-pending.json').existsSync(),
        isFalse,
      );

      final ImportResult stale = restoreBackup(
        library,
        'old-again.yedu.json',
        bytes(old),
      );
      expect(stale.error, isNull);
      expect(stale.existed, isTrue);
      final Json after =
          jsonDecode(utf8.decode(exportBookBytes(library, book))) as Json;
      expect(after['kg'], exported['kg']);
      expect(after['mentions'], exported['mentions']);
      expect(after['status'], exported['status']);
    },
  );

  test('divergent mention history cannot overwrite an extended graph', () {
    final Json old = sample();
    final ImportResult first = restoreBackup(library, 'old.json', bytes(old));
    expect(first.error, isNull);
    final Json newer = jsonDecode(jsonEncode(old)) as Json;
    ((newer['kg']! as Json)['log']! as List<Object?>).add(<String, Object?>{
      't': 'profile',
      'id': 'p1',
      'bio': 'New biography',
      'p': 10,
    });
    (newer['mentions']! as Json)['0000'] = <Object?>[
      <Object?>[1, 5, 'p1', 0],
    ];
    final ImportResult conflict = restoreBackup(
      library,
      'new.json',
      bytes(newer),
    );
    expect(conflict.error, contains('人物索引分叉'));
    final Directory book = Directory('${library.booksDir.path}/${first.id}');
    expect(
      (jsonDecode(File('${book.path}/kg.json').readAsStringSync())
          as Json)['log'],
      (old['kg']! as Json)['log'],
    );
    expect(Directory('${root.path}/sync-backups').existsSync(), isFalse);
  });

  test(
    'Web export carrying newer native knowledge advances installed book',
    () {
      final Json old = sample();
      final ImportResult first = restoreBackup(library, 'old.json', bytes(old));
      expect(first.error, isNull);
      final Json newer = jsonDecode(jsonEncode(old)) as Json;
      ((newer['kg']! as Json)['log']! as List<Object?>).add(<String, Object?>{
        't': 'profile',
        'id': 'p1',
        'bio': 'Verified on another client',
        'p': 10,
      });
      final Json wrapper = <String, Object?>{
        'format': webExportFormat,
        'book': newer['book'],
        'images': <String, Object?>{},
        'state': <String, Object?>{
          'chapter': 0,
          'fraction': 0.5,
          'lastOpened': DateTime.now().millisecondsSinceEpoch,
          'bookmarks': <Object?>[],
          'notes': <Object?>[],
        },
        'native_backup': <String, Object?>{
          for (final MapEntry<String, Object?> field in newer.entries)
            if (field.key != 'book' && field.key != 'assets')
              field.key: field.value,
          'id': first.id,
        },
      };
      final ImportResult merged = restoreBackup(
        library,
        'web.json',
        bytes(wrapper),
      );
      expect(merged.error, isNull);
      expect(merged.existed, isTrue);
      final Json graph =
          jsonDecode(
                File(
                  '${library.booksDir.path}/${first.id}/kg.json',
                ).readAsStringSync(),
              )
              as Json;
      expect(graph['log'], (newer['kg']! as Json)['log']);
    },
  );

  test('interrupted knowledge merge restores graph, mentions and status', () {
    final Json old = sample();
    final ImportResult first = restoreBackup(library, 'old.json', bytes(old));
    expect(first.error, isNull);
    final Directory book = Directory('${library.booksDir.path}/${first.id}');
    final File graphFile = File('${book.path}/kg.json');
    final File statusFile = File('${book.path}/status.json');
    final File mentionsFile = File('${book.path}/mentions/0000.json');
    final Object? graph = jsonDecode(graphFile.readAsStringSync());
    final Object? status = jsonDecode(statusFile.readAsStringSync());
    final Object? mentions = jsonDecode(mentionsFile.readAsStringSync());
    final File marker = File('${book.path}/.sync-merge-pending.json');
    marker.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'id': first.id,
        'notebook': old['notebook'],
        'manual_entities': old['manual_entities'],
        'web_transfer': null,
        'progress': library.progressOf(first.id!)!.toJson(),
        'kg': graph,
        'status': status,
        'mentions': <String, Object?>{'0000': mentions},
      }),
    );
    graphFile.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'log': <Object?>[
          ...((graph! as Json)['log']! as List<Object?>),
          <String, Object?>{
            't': 'profile',
            'id': 'p1',
            'bio': 'partial',
            'p': 10,
          },
        ],
      }),
    );
    statusFile.writeAsStringSync(
      jsonEncode(<String, Object?>{'state': 'done', 'frontier': 16}),
    );
    mentionsFile.writeAsStringSync(
      jsonEncode(<Object?>[
        ...(mentions! as List<Object?>),
        <Object?>[6, 9, 'p1', 0],
      ]),
    );
    expect(recoverPendingBackupMerges(root), 1);
    expect(jsonDecode(graphFile.readAsStringSync()), graph);
    expect(jsonDecode(statusFile.readAsStringSync()), status);
    expect(jsonDecode(mentionsFile.readAsStringSync()), mentions);
    expect(marker.existsSync(), isFalse);
  });

  test(
    'a verified title decision merges without changing the book identity',
    () {
      final Json old = sample();
      (old['book']! as Json)['chapters'] = <Json>[
        <String, Object?>{
          ...((sample()['book']! as Json)['chapters']! as List<Object?>).single!
              as Json,
          'spoil': true,
        },
      ];
      (old['status']! as Json)['quality'] = <String, Object?>{
        'state': 'pending',
        'pending': <String>['chapter-titles'],
      };
      final ImportResult first = restoreBackup(library, 'old.json', bytes(old));
      expect(first.error, isNull);
      final Json newer = jsonDecode(jsonEncode(old)) as Json;
      final Json chapter =
          ((newer['book']! as Json)['chapters']! as List<Object?>).single!
              as Json;
      chapter['spoil'] = false;
      chapter['spoilSource'] = 'model';
      (newer['status']! as Json)['quality'] = <String, Object?>{
        'state': 'verified',
        'pending': <String>[],
      };
      final ImportResult merged = restoreBackup(
        library,
        'new.json',
        bytes(newer),
      );
      expect(merged.error, isNull);
      expect(merged.existed, isTrue);
      final Json saved =
          jsonDecode(
                File(
                  '${library.booksDir.path}/${first.id}/book.json',
                ).readAsStringSync(),
              )
              as Json;
      final Json savedChapter =
          (saved['chapters']! as List<Object?>).single! as Json;
      expect(savedChapter['spoil'], false);
      expect(savedChapter['spoilSource'], 'model');
    },
  );

  test('cross-device reading timestamps remain source timestamps', () {
    final Json first = sample();
    first['progress'] = <String, Object?>{'pos': 2, 'cutoff': 4, 't': 100};
    final ImportResult result = restoreBackup(library, 'a.json', bytes(first));
    expect(result.error, isNull);
    expect(library.progressOf(result.id!)!.t, 100);
    final Json later = jsonDecode(jsonEncode(first)) as Json;
    later['progress'] = <String, Object?>{'pos': 12, 'cutoff': 14, 't': 200};
    expect(restoreBackup(library, 'later.json', bytes(later)).error, isNull);
    expect(library.progressOf(result.id!)!.pos, 12);
    expect(library.progressOf(result.id!)!.t, 200);
    final Json samePosition = jsonDecode(jsonEncode(later)) as Json;
    (samePosition['progress']! as Json)['t'] = 300;
    expect(
      restoreBackup(library, 'same.json', bytes(samePosition)).error,
      isNull,
    );
    expect(library.progressOf(result.id!)!.t, 300);
  });

  test(
    'unchanged native to Web to native backup keeps one ranged note',
    () async {
      final ImportResult first = restoreBackup(
        library,
        'native.json',
        bytes(sample()),
      );
      expect(first.error, isNull);
      await library.scan();
      final Json native =
          jsonDecode(
                utf8.decode(exportBookBytes(library, library.books.single)),
              )
              as Json;
      final Json wrapper = <String, Object?>{
        'format': webExportFormat,
        'book': native['book'],
        'images': <String, Object?>{},
        'state': native['web_state'],
        'native_backup': <String, Object?>{
          for (final MapEntry<String, Object?> field in native.entries)
            if (!const <String>{
              'book',
              'assets',
              'web_state',
              'web_preparation',
            }.contains(field.key))
              field.key: field.value,
        },
      };
      final ImportResult roundTrip = restoreBackup(
        library,
        'web.json',
        bytes(wrapper),
      );
      expect(roundTrip.error, isNull);
      final List<Object?> saved =
          jsonDecode(
                File(
                  '${library.booksDir.path}/${first.id}/notebook.json',
                ).readAsStringSync(),
              )
              as List<Object?>;
      expect(saved, hasLength(1));
      expect((saved.single! as Json)['end'], 5);
    },
  );

  test('opposite verified title decisions report a merge conflict', () {
    final Json first = sample();
    final Json firstChapter =
        ((first['book']! as Json)['chapters']! as List<Object?>).single!
            as Json;
    firstChapter['spoil'] = false;
    firstChapter['spoilSource'] = 'model';
    final ImportResult restored = restoreBackup(
      library,
      'first.json',
      bytes(first),
    );
    expect(restored.error, isNull);
    final Json conflicting = jsonDecode(jsonEncode(first)) as Json;
    final Json nextChapter =
        ((conflicting['book']! as Json)['chapters']! as List<Object?>).single!
            as Json;
    nextChapter['spoil'] = true;
    final ImportResult next = restoreBackup(
      library,
      'next.json',
      bytes(conflicting),
    );
    expect(next.error, contains('剧透判断不同'));
    final Json saved =
        jsonDecode(
              File(
                '${library.booksDir.path}/${restored.id}/book.json',
              ).readAsStringSync(),
            )
            as Json;
    expect(
      ((saved['chapters']! as List<Object?>).single! as Json)['spoil'],
      false,
    );
  });

  test('an interrupted title merge restores the original book', () {
    final ImportResult imported = restoreBackup(
      library,
      'original.json',
      bytes(sample()),
    );
    expect(imported.error, isNull);
    final Directory directory = Directory(
      '${library.booksDir.path}/${imported.id}',
    );
    final File bookFile = File('${directory.path}/book.json');
    final Json original = jsonDecode(bookFile.readAsStringSync()) as Json;
    final File marker = File('${directory.path}/.sync-merge-pending.json');
    marker.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'id': imported.id,
        'book': original,
        'notebook': sample()['notebook'],
        'manual_entities': sample()['manual_entities'],
        'web_transfer': null,
        'progress': library.progressOf(imported.id!)!.toJson(),
      }),
    );
    final Json partial = jsonDecode(jsonEncode(original)) as Json;
    ((partial['chapters']! as List<Object?>).single! as Json)['spoil'] = true;
    bookFile.writeAsStringSync(jsonEncode(partial));
    expect(recoverPendingBackupMerges(root), 1);
    expect(jsonDecode(bookFile.readAsStringSync()), original);
  });

  test('newer native note tombstone survives an older backup', () async {
    final Json old = sample();
    final ImportResult first = restoreBackup(library, 'old.json', bytes(old));
    expect(first.error, isNull);
    await library.scan();
    final Json newer = jsonDecode(jsonEncode(old)) as Json;
    final Json removed = (newer['notebook']! as List<Object?>).single! as Json;
    removed['deleted'] = true;
    removed['revision'] = 4;
    removed['updated'] = 30;
    removed['operation'] = 'operation3';
    expect(restoreBackup(library, 'deleted.json', bytes(newer)).error, isNull);
    expect(restoreBackup(library, 'old-again.json', bytes(old)).error, isNull);
    final Json exported =
        jsonDecode(utf8.decode(exportBookBytes(library, library.books.single)))
            as Json;
    final Json saved = (exported['notebook']! as List<Object?>).single! as Json;
    expect(saved['deleted'], true);
    expect(saved['revision'], 4);
    expect(saved['quote'], 'Alice');
    final Json webNote =
        ((exported['web_state']! as Json)['notes']! as List<Object?>).single!
            as Json;
    expect(webNote['id'], 'note0001');
    expect(webNote['deleted'], true);
    final Directory freshRoot = Directory.systemTemp.createTempSync(
      'thusfar-tombstone-roundtrip-',
    );
    final Library fresh = Library(freshRoot);
    try {
      await fresh.scan();
      expect(
        restoreBackup(fresh, 'round-trip.json', bytes(exported)).error,
        isNull,
      );
      await fresh.scan();
      final Json roundTrip =
          jsonDecode(utf8.decode(exportBookBytes(fresh, fresh.books.single)))
              as Json;
      expect(
        ((roundTrip['notebook']! as List<Object?>).single! as Json)['deleted'],
        true,
      );
    } finally {
      fresh.dispose();
      freshRoot.deleteSync(recursive: true);
    }
  });

  test('Web deletion of native note keeps its source range', () async {
    final ImportResult first = restoreBackup(
      library,
      'native.json',
      bytes(sample()),
    );
    expect(first.error, isNull);
    await library.scan();
    final Json native =
        jsonDecode(utf8.decode(exportBookBytes(library, library.books.single)))
            as Json;
    final Json webState = jsonDecode(jsonEncode(native['web_state'])) as Json;
    final Json removed = (webState['notes']! as List<Object?>).single! as Json;
    removed['deleted'] = true;
    removed['revision'] = 4;
    removed['updated'] = 30000;
    final Json wrapper = <String, Object?>{
      'format': webExportFormat,
      'book': native['book'],
      'images': <String, Object?>{},
      'state': webState,
      'native_backup': <String, Object?>{
        for (final MapEntry<String, Object?> field in native.entries)
          if (!const <String>{
            'book',
            'assets',
            'web_state',
            'web_preparation',
          }.contains(field.key))
            field.key: field.value,
      },
    };
    expect(
      restoreBackup(library, 'web-deleted.json', bytes(wrapper)).error,
      isNull,
    );
    final List<Object?> rows =
        jsonDecode(
              File(
                '${library.booksDir.path}/${first.id}/notebook.json',
              ).readAsStringSync(),
            )
            as List<Object?>;
    final Json saved = rows.single! as Json;
    expect(saved['id'], 'note0001');
    expect(saved['deleted'], true);
    expect(saved['revision'], 4);
    expect(saved['end'], 5);
    expect(saved['quote'], 'Alice');
    expect(saved['text'], 'remember');
    final Json stale = jsonDecode(jsonEncode(wrapper)) as Json;
    final Json staleState = stale['state']! as Json;
    (staleState['notes']! as List<Object?>)[0] =
        ((native['web_state']! as Json)['notes']! as List<Object?>).single;
    expect(
      restoreBackup(library, 'stale-web.json', bytes(stale)).error,
      isNull,
    );
    final List<Object?> after =
        jsonDecode(
              File(
                '${library.booksDir.path}/${first.id}/notebook.json',
              ).readAsStringSync(),
            )
            as List<Object?>;
    expect((after.single! as Json)['deleted'], true);
  });

  test('Web note anchor survives a no-edit Native round trip', () async {
    expect(
      restoreBackup(library, 'native.json', bytes(sample())).error,
      isNull,
    );
    await library.scan();
    final Json native =
        jsonDecode(utf8.decode(exportBookBytes(library, library.books.single)))
            as Json;
    final Json webState = jsonDecode(jsonEncode(native['web_state'])) as Json;
    final Json webNote = <String, Object?>{
      'id': 'web12345678901234567890123456789012',
      'chapter': 0,
      'fraction': 0.123456,
      'text': 'extra',
      'created': 40000,
      'revision': 1,
      'updated': 40000,
      'deleted': false,
    };
    (webState['notes']! as List<Object?>).add(webNote);
    final Json wrapper = <String, Object?>{
      'format': webExportFormat,
      'book': native['book'],
      'images': <String, Object?>{},
      'state': webState,
      'native_backup': <String, Object?>{
        for (final MapEntry<String, Object?> field in native.entries)
          if (!const <String>{
            'book',
            'assets',
            'web_state',
            'web_preparation',
          }.contains(field.key))
            field.key: field.value,
      },
    };
    expect(
      restoreBackup(library, 'from-web.json', bytes(wrapper)).error,
      isNull,
    );
    await library.scan();
    final Json roundTrip =
        jsonDecode(utf8.decode(exportBookBytes(library, library.books.single)))
            as Json;
    final List<Object?> notes =
        (roundTrip['web_state']! as Json)['notes']! as List<Object?>;
    expect(
      notes.whereType<Json>().singleWhere(
        (Json row) => row['id'] == webNote['id'],
      ),
      webNote,
    );
    expect(
      restoreBackup(library, 'same-web.json', bytes(wrapper)).error,
      isNull,
    );
  });

  test(
    'legacy Web rows gain stable IDs and deletion survives stale sync',
    () async {
      final Json wrapper = <String, Object?>{
        'format': webExportFormat,
        'book': sample()['book'],
        'images': <String, Object?>{},
        'state': <String, Object?>{
          'chapter': 0,
          'fraction': 0.25,
          'lastOpened': 1000,
          'bookmarks': <Json>[
            <String, Object?>{'chapter': 0, 'fraction': 0.5},
          ],
          'notes': <Json>[
            <String, Object?>{
              'chapter': 0,
              'fraction': 0.25,
              'text': 'legacy note',
              'created': 1000,
            },
          ],
        },
      };
      final ImportResult first = restoreBackup(
        library,
        'legacy-web.json',
        bytes(wrapper),
      );
      expect(first.error, isNull);
      await library.scan();
      final Json native =
          jsonDecode(
                utf8.decode(exportBookBytes(library, library.books.single)),
              )
              as Json;
      final Json state = jsonDecode(jsonEncode(native['web_state'])) as Json;
      // Earlier Web imports used an index-based ID for the native projection.
      final File notebookFile = File(
        '${library.booksDir.path}/${first.id}/notebook.json',
      );
      final List<Object?> historical =
          jsonDecode(notebookFile.readAsStringSync()) as List<Object?>;
      for (int i = 0; i < historical.length; i++) {
        (historical[i]! as Json)['id'] =
            'webhistorical${i.toString().padLeft(12, '0')}';
      }
      notebookFile.writeAsStringSync(jsonEncode(historical));
      for (final String key in <String>['bookmarks', 'notes']) {
        final Json row = (state[key]! as List<Object?>).single! as Json;
        expect(row['id'], startsWith('web'));
        row['revision'] = 2;
        row['updated'] = 2000;
        row['deleted'] = true;
      }
      final Json deleted = <String, Object?>{...wrapper, 'state': state};
      expect(
        restoreBackup(library, 'deleted-web.json', bytes(deleted)).error,
        isNull,
      );
      expect(
        restoreBackup(library, 'old-web-again.json', bytes(wrapper)).error,
        isNull,
      );
      final Json exported =
          jsonDecode(
                utf8.decode(exportBookBytes(library, library.books.single)),
              )
              as Json;
      final List<Object?> personal = exported['notebook']! as List<Object?>;
      expect(personal, hasLength(4));
      expect(
        personal.every((Object? row) => (row! as Json)['deleted'] == true),
        true,
      );
      final Json exportedState = exported['web_state']! as Json;
      for (final String key in <String>['bookmarks', 'notes']) {
        expect(
          (exportedState[key]! as List<Object?>).every(
            (Object? row) => (row! as Json)['deleted'] == true,
          ),
          true,
        );
      }
    },
  );
}
