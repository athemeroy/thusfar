import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/manual_entities.dart';
import 'package:thusfar_core/thusfar_core.dart' show PyException;

void main() {
  final Json fixture =
      jsonDecode(
            File(
              'test/manual_entities/fixtures/python.json',
            ).readAsStringSync(),
          )
          as Json;
  List<Json> maps(Object? value) => (value! as List<Object?>).cast<Json>();
  for (final (int index, Object? value)
      in (fixture['cases']! as List<Object?>).indexed) {
    final Json row = value! as Json;
    test('$index ${row['label']}', () {
      final List<Object?> args = row['args']! as List<Object?>;
      Object? invoke() => switch (row['function']) {
        'anchor' => manualAnchor(
          args[0]! as Json,
          args[1]! as String,
          args[2]! as int,
        ),
        'rows' => manualRows(maps(args[0])),
        'mentions' => manualMentions(
          maps(args[0]),
          maps(args[1]),
          (args[2]! as List<Object?>).cast<List<Object?>>(),
        ),
        'restore' => manualRestore(args[0], args[1]! as Json),
        'apply' =>
          (() {
            final (List<Json> items, Json? item, bool conflict) = manualApply(
              maps(args[0]),
              args[1]! as Json,
              args[2]! as Json,
              args[3]! as Json,
              clock: () => 1234.5,
            );
            return <Object?>[items, item, conflict];
          })(),
        _ => throw StateError('Unknown oracle function'),
      };
      if (row['error'] case final Json error) {
        expect(
          invoke,
          throwsA(
            isA<PyException>()
                .having(
                  (PyException e) => e.pyType.split('.').last,
                  'type',
                  error['type'],
                )
                .having(
                  (PyException e) => e.message,
                  'message',
                  error['message'],
                ),
          ),
        );
      } else {
        expect(invoke(), row['value']);
      }
    });
  }

  group('persistent store', () {
    late Directory directory;
    late File file;
    late ManualEntityStore store;
    final Json replay = (fixture['cases']! as List<Object?>)
        .cast<Json>()
        .firstWhere((Json row) => row['label'] == 'operation replay');
    final List<Object?> args = replay['args']! as List<Object?>;
    setUp(() {
      directory = Directory.systemTemp.createTempSync('thusfar-manual-store-');
      file = File('${directory.path}/manual-entities.json');
      store = ManualEntityStore(file);
    });
    tearDown(() => directory.deleteSync(recursive: true));

    test('operation replay does not rewrite the original receipt', () {
      file.writeAsStringSync(jsonEncode(args[0]));
      final DateTime sentinel = DateTime.utc(2000);
      file.setLastModifiedSync(sentinel);
      final String original = file.readAsStringSync();
      final result = store.apply(
        args[1]! as Json,
        args[2]! as Json,
        args[3]! as Json,
        clock: () => 9999,
      );
      expect(result.$3, isFalse);
      expect(file.readAsStringSync(), original);
      expect(file.lastModifiedSync().toUtc(), sentinel);
    });

    test('an unknown revision conflict creates no file or person', () {
      final Json payload = <String, Object?>{
        ...args[1]! as Json,
        'expected_revision': 1,
      };
      final result = store.apply(payload, args[2]! as Json, args[3]! as Json);
      expect(result.$3, isTrue);
      expect(result.$2, isNull);
      expect(file.existsSync(), isFalse);
    });

    test('malformed stored data survives failed writes unchanged', () {
      file.writeAsStringSync('[null]');
      expect(
        () => store.apply(args[1]! as Json, args[2]! as Json, args[3]! as Json),
        throwsA(isA<PyException>()),
      );
      expect(file.readAsStringSync(), '[null]');
    });
  });
}
