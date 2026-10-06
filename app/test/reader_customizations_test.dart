import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_core/storage.dart' as storage;
import 'package:thusfar_core/thusfar_core.dart' show PyJson;
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/purification_store.dart';
import 'package:thusfar_app/data/reader_customizations.dart';
import 'package:thusfar_app/data/reader_directory.dart';
import 'package:thusfar_app/reader/text_purification.dart';

Json _copy(Json value) => jsonDecode(jsonEncode(value)) as Json;

Json _book([
  List<String> lines = const <String>['序😀', '  第一章 开始  ', '第二章 相逢'],
]) {
  int offset = 0;
  final List<Json> blocks = <Json>[];
  for (final String line in lines) {
    blocks.add(<String, Object?>{'k': 'p', 't': line, 'o': offset});
    offset += line.length + 1;
  }
  return <String, Object?>{
    'title': 'Test',
    'len': offset - 1,
    'blocks': blocks,
    'notes': <String, Object?>{'n': 'note'},
    'chapters': <Json>[
      <String, Object?>{
        'title': 'Original',
        'kind': 'body',
        'b0': 0,
        'b1': blocks.length,
        'o0': 0,
        'o1': offset - 1,
        'spoil': true,
      },
    ],
  };
}

Json _directory(Json book, {bool enabled = true}) => <String, Object?>{
  'version': 1,
  'bookId': 'book-a',
  'length': book['len'],
  'enabled': enabled,
  'rule': 'automatic',
  'prefix': '',
  'rows': <Json>[
    for (final Json raw
        in (book['blocks']! as List<Object?>).skip(1).cast<Json>())
      <String, Object?>{
        'title': raw['t'].toString().trim(),
        'offset':
            (raw['o']! as int) +
            (raw['t']! as String).indexOf((raw['t']! as String).trim()),
      },
  ],
};

PurificationRule _rule(
  String id, {
  String? bookId = 'book-a',
  String? find,
  String replacement = '',
  bool enabled = true,
}) => PurificationRule(
  id: id,
  bookId: bookId,
  find: find ?? id,
  replacement: replacement,
  enabled: enabled,
);

const Json _txt = <String, Object?>{'filename': 'Original.TXT'};

Json _payload(Json book, {Object? directory, List<PurificationRule>? rules}) =>
    exportReaderCustomizations(
      book: book,
      bookId: 'book-a',
      rules: rules ?? <PurificationRule>[_rule('r1', enabled: false)],
      directory: directory,
      meta: _txt,
    );

Json? _validate(Json payload, Json book, {String? destination}) =>
    validatedReaderCustomizations(
      payload,
      book: book,
      bookId: 'book-a',
      destinationBookId: destination,
      meta: _txt,
    );

void main() {
  test(
    'shared byte-limit encoding matches the native compact sidecar writer',
    () {
      final String text = String.fromCharCodes(<int>[
        for (int i = 0; i < 128; i++) i,
        0x2028,
        0x2029,
        0x4e00,
        0xffff,
        0x1f600,
        0x10ffff,
      ]);
      final Json payload = <String, Object?>{
        'version': 1,
        'bookId': 'book-a',
        'length': 1234567,
        'enabled': true,
        'rule': 'prefix',
        'prefix': '章节😀',
        'rows': <Json>[
          <String, Object?>{'title': text, 'offset': 0},
        ],
      };
      expect(
        utf8.encode(jsonEncode(payload)),
        utf8.encode(PyJson.encode(payload, ensureAscii: false, compact: true)),
      );
    },
  );

  group('immutable source identities', () {
    test(
      'key order, title metadata and AI verdict changes preserve identity',
      () {
        final Json original = _book();
        final Json changed = _copy(original);
        changed['title'] = 'Reader title';
        changed['author'] = 'Changed metadata';
        final Json chapter =
            (changed['chapters']! as List<Object?>).single! as Json;
        chapter['spoil'] = false;
        chapter['spoilSource'] = 'model';
        changed['blocks'] = <Json>[
          for (final Json block
              in (changed['blocks']! as List<Object?>).cast<Json>())
            <String, Object?>{
              for (final String key in block.keys.toList().reversed)
                key: block[key],
            },
        ];
        expect(
          readerCustomizationSource(changed),
          readerCustomizationSource(original),
        );
      },
    );

    test(
      'text, UTF-16 positions, chapter structure and notes bind identity',
      () {
        final Json original = _book();
        for (final void Function(Json) change in <void Function(Json)>[
          (Json book) =>
              ((book['blocks']! as List<Object?>).first! as Json)['t'] = '序😃',
          (Json book) =>
              ((book['blocks']! as List<Object?>)[1]! as Json)['o'] = 3,
          (Json book) =>
              ((book['chapters']! as List<Object?>).first! as Json)['title'] =
                  'Different',
          (Json book) => (book['notes']! as Json)['n'] = 'Changed',
        ]) {
          final Json changed = _copy(original);
          change(changed);
          expect(
            readerCustomizationSource(changed),
            isNot(readerCustomizationSource(original)),
          );
        }
      },
    );

    test(
      'all core-valid empty paragraphs and EPUB images can be fingerprinted',
      () {
        for (final Json book in <Json>[
          _book(<String>['']),
          _book(<String>['', 'Body'])
            ..['blocks'] = <Json>[
              <String, Object?>{
                'k': 'img',
                't': '',
                'o': 0,
                'src': 'cover.jpg',
              },
              <String, Object?>{'k': 'p', 't': 'Body', 'o': 1},
            ],
        ]) {
          expect(storage.validateBook(book), book);
          expect(
            readerCustomizationSource(book),
            matches(RegExp(r'^[a-f0-9]{64}$')),
          );
          expect(_payload(book)['directory'], isNull);
        }
      },
    );

    test('invalid source offsets and malformed UTF-16 fail safely', () {
      final Json original = _book();
      for (final Object value in <Object>[-1, 1.5, '0']) {
        final Json changed = _copy(original);
        ((changed['blocks']! as List<Object?>).first! as Json)['o'] = value;
        expect(() => readerCustomizationSource(changed), throwsFormatException);
      }
      final Json changed = _copy(original);
      ((changed['blocks']! as List<Object?>).first! as Json)['t'] =
          String.fromCharCode(0xd800);
      expect(() => readerCustomizationSource(changed), throwsFormatException);
    });
  });

  group('strict single-book portability', () {
    test(
      'omits global/foreign rules, discloses globals and preserves stable IDs',
      () {
        final Json book = _book();
        final Json sourceCopy = _copy(book);
        final Json sidecar = _directory(book);
        final Json sidecarCopy = _copy(sidecar);
        final Json result = _payload(
          book,
          directory: sidecar,
          rules: <PurificationRule>[
            _rule('global', bookId: null),
            _rule('r1', enabled: false),
            _rule('other', bookId: 'other'),
            _rule('r2'),
          ],
        );
        final List<PurificationRule> rules = decodeReaderPurificationRules(
          result['purification'],
        );
        expect(rules.map((PurificationRule r) => r.id), <String>['r1', 'r2']);
        expect(rules.first.enabled, isFalse);
        expect(result['globalRulesOmitted'], 1);
        expect(result['directory'], sidecar);
        expect(book, sourceCopy);
        expect(sidecar, sidecarCopy);
      },
    );

    test('safe source-verified remap updates only scope and sidecar ID', () {
      final Json book = _book();
      final Json original = _payload(book, directory: _directory(book));
      final Json result = _validate(
        original,
        book,
        destination: 'destination',
      )!;
      expect(result['bookId'], 'destination');
      expect((result['directory']! as Json)['bookId'], 'destination');
      final PurificationRule rule = decodeReaderPurificationRules(
        result['purification'],
      ).single;
      expect(rule.id, 'r1');
      expect(rule.bookId, 'destination');
      expect(rule.enabled, isFalse);
      expect(original['bookId'], 'book-a');
      final Json different = _book(<String>['序😃', '  第一章 开始  ', '第二章 相逢']);
      expect(
        () => _validate(original, different, destination: 'destination'),
        throwsFormatException,
      );
    });

    test(
      'rejects global or foreign scopes and unrelated exporter identities',
      () {
        final Json book = _book();
        for (final String? scope in <String?>[null, 'other']) {
          final Json payload = _payload(book);
          ((payload['purification']! as List<Object?>).single!
                  as Json)['bookId'] =
              scope;
          expect(() => _validate(payload, book), throwsFormatException);
        }
        final Json payload = _payload(book)..['bookId'] = 'other';
        expect(() => _validate(payload, book), throwsFormatException);
      },
    );

    test(
      'missing legacy payload remains absent and empty payload is explicit',
      () {
        final Json book = _book();
        expect(
          validatedReaderCustomizations(
            null,
            book: book,
            bookId: 'book-a',
            meta: _txt,
          ),
          isNull,
        );
        expect(
          _payload(book, rules: <PurificationRule>[])['purification'],
          isEmpty,
        );
        expect(
          () => _validate(<String, Object?>{}, book),
          throwsFormatException,
        );
      },
    );

    test(
      'rejects unknown fields, malformed versions, fingerprints and omission counts',
      () {
        final Json book = _book();
        for (final MapEntry<String, Object?> field in <String, Object?>{
          'unknown': true,
          'version': 1.0,
          'source': 'bad',
          'globalRulesOmitted': 65,
        }.entries) {
          final Json payload = _payload(book)..[field.key] = field.value;
          expect(
            () => _validate(payload, book),
            throwsFormatException,
            reason: field.key,
          );
        }
        final Json payload = _payload(book)..remove('directory');
        expect(() => _validate(payload, book), throwsFormatException);
      },
    );
  });

  group('source-verified corrected directories', () {
    test(
      'matches ReaderDirectory preview verification for whitespace and emoji offsets',
      () {
        final Json book = _book();
        final Directory root = Directory.systemTemp.createTempSync(
          'reader-custom-source',
        );
        addTearDown(() => root.deleteSync(recursive: true));
        writeJson(File('${root.path}/book.json'), book);
        writeJson(File('${root.path}/meta.json'), _txt);
        final BookData opened = BookData.open(
          BookEntry(
            id: 'book-a',
            dir: root,
            meta: _txt,
            status: ProcessStatus(<String, Object?>{}),
            added: 0,
          ),
        );
        addTearDown(() {
          opened.directory.dispose();
          opened.notes.dispose();
          opened.dispose();
        });
        final Json sidecar = _directory(book);
        final List<Json> rows = (sidecar['rows']! as List<Object?>)
            .cast<Json>();
        expect(opened.directory.previewEntries(rows).length, 3);
        expect(
          validatedReaderDirectory(
            sidecar,
            book: book,
            bookId: 'book-a',
            meta: _txt,
          ),
          sidecar,
        );
        for (final Json row in rows) {
          final List<Json> damaged = <Json>[
            _copy(row)..['offset'] = (row['offset']! as int) + 1,
          ];
          expect(
            () => opened.directory.previewEntries(damaged),
            throwsFormatException,
          );
          expect(
            () => validatedReaderDirectory(
              <String, Object?>{...sidecar, 'rows': damaged},
              book: book,
              bookId: 'book-a',
              meta: _txt,
            ),
            throwsFormatException,
          );
        }
      },
    );

    test(
      'disabled minimal and complete sidecars preserve data, corrupt disabled rows reject',
      () {
        final Json book = _book();
        final Json minimal = <String, Object?>{
          'version': 1,
          'bookId': 'book-a',
          'length': book['len'],
          'enabled': false,
        };
        expect(_payload(book, directory: minimal)['directory'], minimal);
        final Json complete = _directory(book, enabled: false);
        expect(_payload(book, directory: complete)['directory'], complete);
        ((complete['rows']! as List<Object?>).first! as Json)['title'] =
            'wrong';
        expect(
          () => _payload(book, directory: complete),
          throwsFormatException,
        );
      },
    );

    test('requires confirmed TXT and rejects EPUB even with TXT metadata', () {
      final Json book = _book();
      final Json sidecar = _directory(book);
      for (final Json meta in <Json>[
        <String, Object?>{},
        <String, Object?>{'filename': 'book.epub'},
      ]) {
        expect(
          () => validatedReaderDirectory(
            sidecar,
            book: book,
            bookId: 'book-a',
            meta: meta,
          ),
          throwsFormatException,
        );
      }
      expect(
        validatedReaderDirectory(
          sidecar,
          book: book,
          bookId: 'book-a',
          meta: <String, Object?>{},
          hasSourceTxt: true,
        ),
        sidecar,
      );
      expect(
        () => validatedReaderDirectory(
          sidecar,
          book: book,
          bookId: 'book-a',
          meta: _txt,
          hasSourceTxt: true,
          hasSourceEpub: true,
        ),
        throwsFormatException,
      );
    });

    test(
      'strict fields, versions, ownership, length, rule and prefix limits',
      () {
        final Json book = _book();
        for (final MapEntry<String, Object?> field in <String, Object?>{
          'unknown': true,
          'version': 1.0,
          'bookId': 'other',
          'length': (book['len']! as int) + 1,
          'enabled': 0,
          'rule': 'regex',
          'prefix': 'x' * 33,
        }.entries) {
          final Json sidecar = _directory(book)..[field.key] = field.value;
          expect(
            () => _payload(book, directory: sidecar),
            throwsFormatException,
            reason: field.key,
          );
        }
        for (final String prefix in <String>['', '   ', 'x\ny', 'x\ry']) {
          final Json sidecar = _directory(book)
            ..['rule'] = 'prefix'
            ..['prefix'] = prefix;
          expect(
            () => _payload(book, directory: sidecar),
            throwsFormatException,
          );
        }
        final Json valid = _directory(book)
          ..['rule'] = 'prefix'
          ..['prefix'] = 'x' * 32;
        expect(_payload(book, directory: valid)['directory'], valid);
      },
    );

    test(
      'row schema, source text, ordered offsets, title and heading bounds',
      () {
        final Json book = _book();
        final Json valid = _directory(book);
        final Json first = ((valid['rows']! as List<Object?>).first! as Json);
        for (final List<Object?> rows in <List<Object?>>[
          <Object?>[],
          <Object?>[
            <String, Object?>{...first, 'extra': true},
          ],
          <Object?>[
            <String, Object?>{...first, 'title': 'partial'},
          ],
          <Object?>[
            <String, Object?>{...first, 'offset': -1},
          ],
          <Object?>[
            <String, Object?>{...first, 'offset': 6.0},
          ],
          <Object?>[first, first],
          (valid['rows']! as List<Object?>).reversed.toList(),
          List<Object?>.filled(10001, first),
        ]) {
          expect(
            () => _payload(
              book,
              directory: <String, Object?>{...valid, 'rows': rows},
            ),
            throwsFormatException,
          );
        }
        final Json longBook = _book(<String>['start', 'x' * 121]);
        expect(
          () => _payload(longBook, directory: _directory(longBook)),
          throwsFormatException,
        );
      },
    );

    test(
      '10000 source-verified headings fit, escaped 4MiB sidecar overflows reject',
      () {
        final Json book = _book(<String>[
          'start',
          ...List<String>.filled(10000, 'Heading'),
        ]);
        final Json sidecar = _directory(book);
        expect(
          validatedReaderDirectory(
            sidecar,
            book: book,
            bookId: 'book-a',
            meta: _txt,
          )!['rows'],
          hasLength(10000),
        );
        final Json huge = _book(<String>[
          'start',
          ...List<String>.filled(10000, '\u0001' * 120),
        ]);
        final Json oversized = _directory(huge);
        expect(
          utf8.encode(jsonEncode(oversized)).length,
          greaterThan(readerDirectoryByteLimit),
        );
        expect(
          () => validatedReaderDirectory(
            oversized,
            book: huge,
            bookId: 'book-a',
            meta: _txt,
          ),
          throwsFormatException,
        );
      },
    );
  });

  group('native rule snapshots and append-only merging', () {
    test(
      'strict store snapshot preserves IDs, order, scope and disabled rules',
      () {
        final List<PurificationRule> rules = <PurificationRule>[
          _rule('global', bookId: null, enabled: false),
          _rule('local'),
        ];
        final Json encoded = PurificationStore.encodeStore(rules);
        expect(
          PurificationStore.encodeStore(PurificationStore.decodeStore(encoded)),
          encoded,
        );
        expect(
          () => PurificationStore.decodeStore(<String, Object?>{
            ...encoded,
            'extra': true,
          }),
          throwsFormatException,
        );
        expect(
          () => PurificationStore.decodeStore(<String, Object?>{
            ...encoded,
            'version': 1.0,
          }),
          throwsFormatException,
        );
        expect(
          () => PurificationStore.decodeStore(null),
          throwsFormatException,
        );
        final Json row = ((encoded['rules']! as List<Object?>).first! as Json)
          ..['extra'] = true;
        expect(
          () => decodeReaderPurificationRules(<Object?>[row]),
          throwsFormatException,
        );
      },
    );

    test(
      'invalid IDs, scopes, duplicate IDs and rule validation are rejected',
      () {
        for (final List<PurificationRule> rules in <List<PurificationRule>>[
          <PurificationRule>[_rule('')],
          <PurificationRule>[_rule('x' * 129)],
          <PurificationRule>[_rule('id', bookId: '')],
          <PurificationRule>[_rule('same'), _rule('same')],
          <PurificationRule>[_rule('id', find: '')],
          <PurificationRule>[_rule('id', find: 'a\nb')],
          <PurificationRule>[_rule('id', find: 'a', replacement: 'x' * 9)],
          <PurificationRule>[_rule('id', find: 'x' * 513)],
          <PurificationRule>[_rule('id', find: String.fromCharCode(0xd800))],
        ]) {
          expect(
            () => PurificationStore.encodeStore(rules),
            throwsFormatException,
          );
        }
      },
    );

    test('maximum valid escaped rules round-trip with stable IDs', () {
      final List<PurificationRule> rules = <PurificationRule>[
        for (int i = 0; i < 64; i++)
          _rule(
            '$i',
            find: '\u0001' * 510 + '$i'.padLeft(2, '0'),
            replacement: '\u0002' * 512,
            enabled: i.isEven,
          ),
      ];
      final Json encoded = PurificationStore.encodeStore(rules);
      expect(
        utf8.encode(jsonEncode(encoded)).length,
        lessThan(PurificationStore.maxImportBytes),
      );
      expect(PurificationStore.decodeStore(encoded), hasLength(64));
    });

    test(
      'append preserves local order and enabled state; semantic duplicates skip',
      () {
        final List<PurificationRule> local = <PurificationRule>[
          _rule('first', find: 'A', enabled: false),
          _rule('second', find: 'B'),
        ];
        final List<PurificationRule> incoming = <PurificationRule>[
          _rule('first', find: 'A', enabled: true),
          _rule('another-id', find: 'B', enabled: false),
          _rule('new', find: 'C', enabled: false),
        ];
        final List<PurificationRule> merged = PurificationStore.mergeRules(
          local,
          incoming,
        );
        expect(merged.map((PurificationRule r) => r.id), <String>[
          'first',
          'second',
          'new',
        ]);
        expect(merged.map((PurificationRule r) => r.enabled), <bool>[
          false,
          true,
          false,
        ]);
        expect(
          PurificationStore.encodeStore(
            PurificationStore.mergeRules(merged, incoming),
          ),
          PurificationStore.encodeStore(merged),
        );
        expect(local, hasLength(2));
      },
    );

    test('stable-ID semantics conflicts cannot hide behind duplicate text', () {
      final List<PurificationRule> local = <PurificationRule>[
        _rule('a', find: 'A'),
        _rule('b', find: 'B'),
      ];
      for (final PurificationRule incoming in <PurificationRule>[
        _rule('a', find: 'B'),
        _rule('a', find: 'A', replacement: 'changed'),
        _rule('a', find: 'A', bookId: null),
      ]) {
        expect(
          () =>
              PurificationStore.mergeRules(local, <PurificationRule>[incoming]),
          throwsFormatException,
        );
      }
    });

    test(
      'merged overflow rejects without mutating local or incoming rules',
      () {
        final List<PurificationRule> local = <PurificationRule>[
          for (int i = 0; i < 64; i++) _rule('$i'),
        ];
        final List<PurificationRule> incoming = <PurificationRule>[
          _rule('new'),
        ];
        expect(
          () => PurificationStore.mergeRules(local, incoming),
          throwsFormatException,
        );
        expect(local, hasLength(64));
        expect(incoming, hasLength(1));
      },
    );

    test(
      'strict bounded disk read rejects corruption and leaves bytes untouched',
      () {
        final Directory root = Directory.systemTemp.createTempSync(
          'reader-custom-rules',
        );
        addTearDown(() => root.deleteSync(recursive: true));
        final File file = File('${root.path}/rules.json');
        expect(PurificationStore.readSnapshot(file), isEmpty);
        for (final String bad in <String>[
          '{broken',
          'null',
          ' ' * (PurificationStore.maxImportBytes + 1),
        ]) {
          file.writeAsStringSync(bad);
          expect(
            () => PurificationStore.readSnapshot(file),
            throwsFormatException,
          );
          expect(file.readAsStringSync(), bad);
        }
        file.writeAsBytesSync(<int>[255]);
        expect(
          () => PurificationStore.readSnapshot(file),
          throwsFormatException,
        );
        file.deleteSync();
        Directory(file.path).createSync();
        expect(
          () => PurificationStore.readSnapshot(file),
          throwsFormatException,
        );
        Directory(file.path).deleteSync();
        final File target = File('${root.path}/target.json')
          ..writeAsStringSync('{}');
        Link(file.path).createSync(target.path);
        expect(
          () => PurificationStore.readSnapshot(file),
          throwsFormatException,
        );
        Link(file.path).deleteSync();
        writeJson(
          file,
          PurificationStore.encodeStore(<PurificationRule>[_rule('restored')]),
        );
        final PurificationStore store = PurificationStore(file);
        addTearDown(store.dispose);
        writeJson(
          file,
          PurificationStore.encodeStore(<PurificationRule>[_rule('new')]),
        );
        store.reload();
        expect(store.rules.single.id, 'new');
      },
    );
  });

  group('source-bound full-library snapshots', () {
    late String source;
    late Json payload;
    setUp(() {
      source = readerCustomizationSource(_book());
      payload = <String, Object?>{
        'format': 'thusfar-reader-library',
        'version': 1,
        'books': <Json>[
          <String, Object?>{'bookId': 'book-a', 'source': source},
        ],
        'purification': encodeReaderPurificationRules(<PurificationRule>[
          _rule('global', bookId: null, enabled: false),
          _rule('local'),
        ]),
      };
    });

    test(
      'subset identities accepted and all rule scope/order/enabled retained',
      () {
        final Json validated = validatedReaderLibrary(
          payload,
          sources: <String, String>{'book-a': source, 'unreferenced': source},
        );
        expect(validated, payload);
        final Json remapped = validatedReaderLibrary(
          payload,
          sources: <String, String>{'book-a': source},
          destinationBookIds: <String, String>{'book-a': 'target'},
        );
        final List<PurificationRule> rules = decodeReaderPurificationRules(
          remapped['purification'],
        );
        expect(rules.first.bookId, isNull);
        expect(rules.first.enabled, isFalse);
        expect(rules.last.bookId, 'target');
        expect(rules.last.id, 'local');
        expect(payload['books'], <Json>[
          <String, Object?>{'bookId': 'book-a', 'source': source},
        ]);
      },
    );

    test(
      'unbound, foreign, duplicate, mismatched and unknown metadata reject',
      () {
        expect(
          () => validatedReaderLibrary(payload, sources: <String, String>{}),
          throwsFormatException,
        );
        expect(
          () => validatedReaderLibrary(
            payload,
            sources: <String, String>{'book-a': '0' * 64},
          ),
          throwsFormatException,
        );
        for (final Json bad in <Json>[
          <String, Object?>{...payload, 'extra': true},
          <String, Object?>{...payload, 'version': 2},
          <String, Object?>{
            ...payload,
            'books': <Json>[
              <String, Object?>{
                'bookId': 'book-a',
                'source': source,
                'extra': true,
              },
            ],
          },
          <String, Object?>{
            ...payload,
            'books': <Object?>[
              ...(payload['books']! as List<Object?>),
              ...(payload['books']! as List<Object?>),
            ],
          },
          <String, Object?>{
            ...payload,
            'purification': encodeReaderPurificationRules(<PurificationRule>[
              _rule('foreign', bookId: 'foreign'),
            ]),
          },
        ]) {
          expect(
            () => validatedReaderLibrary(
              bad,
              sources: <String, String>{'book-a': source},
            ),
            throwsFormatException,
          );
        }
        expect(
          () => validatedReaderLibrary(
            payload,
            sources: <String, String>{'book-a': source},
            destinationBookIds: <String, String>{'foreign': 'target'},
          ),
          throwsFormatException,
        );
      },
    );

    test('multiple source identities cannot collapse onto one destination', () {
      (payload['books']! as List<Object?>).add(<String, Object?>{
        'bookId': 'second',
        'source': source,
      });
      expect(
        () => validatedReaderLibrary(
          payload,
          sources: <String, String>{'book-a': source, 'second': source},
          destinationBookIds: <String, String>{
            'book-a': 'target',
            'second': 'target',
          },
        ),
        throwsFormatException,
      );
    });
  });
}
