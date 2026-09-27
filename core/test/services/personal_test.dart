import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/model_settings.dart' as settings;
import 'package:thusfar_core/notebook.dart' as notebook;
import 'package:thusfar_core/reading_list.dart' as reading;
import 'package:thusfar_core/thusfar_core.dart' show PyException;

typedef Json = Map<String, Object?>;

void main() {
  final List<Object?> rows =
      jsonDecode(
            File('test/services/fixtures/personal.json').readAsStringSync(),
          )
          as List<Object?>;
  for (int i = 0; i < rows.length; i++) {
    final Json row = rows[i]! as Json;
    test('Python personal reference $i ${row['operation']}', () {
      final List<Object?> args = row['args']! as List<Object?>;
      Object? invoke() {
        switch (row['operation']) {
          case 'notebook.validate':
            return notebook.validate(args[0], args[1]! as Json);
          case 'notebook.source_quote':
            return notebook.sourceQuote(
              args[0]! as Json,
              args[1]! as int,
              args[2]! as int,
            );
          case 'notebook.restore':
            return notebook.restore(
              args[0],
              args[1]! as Json,
              now: () => 1000.25,
            );
          case 'notebook.apply':
            final (List<Object?> items, Json? item, bool conflict) = notebook
                .apply(
                  args[0]! as List<Object?>,
                  args[1]! as Json,
                  args[2]! as Json,
                  now: () => 1000.25,
                );
            return <Object?>[items, item, conflict];
          case 'reading_list.apply':
            final (Json value, bool conflict) = reading.apply(
              args[0]! as Json,
              args[1]! as Json,
              (String id) => (row['visible']! as List<Object?>).contains(id),
              now: () => 1000.25,
            );
            return <Object?>[value, conflict];
          case 'model_settings.normalize':
            final (String url, String model) = settings.ModelSettings.normalize(
              args[0]! as String,
              args[1]! as String,
            );
            return <Object?>[url, model];
          default:
            throw StateError('${row['operation']}');
        }
      }

      if (row['error'] is Json) {
        final Json expected = row['error']! as Json;
        expect(
          invoke,
          throwsA(
            isA<PyException>()
                .having(
                  (PyException e) => e.pyType,
                  'type',
                  'builtins.${expected['type']}',
                )
                .having(
                  (PyException e) => e.message,
                  'message',
                  expected['message'],
                ),
          ),
        );
      } else {
        expect(invoke(), row['result']);
      }
    });
  }
}
