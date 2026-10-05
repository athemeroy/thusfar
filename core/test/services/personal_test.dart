import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/model_settings.dart' as settings;
import 'package:thusfar_core/notebook.dart' as notebook;
import 'package:thusfar_core/reading_list.dart' as reading;
import 'package:thusfar_core/thusfar_core.dart' show PyException;

typedef Json = Map<String, Object?>;

// personal.json is an unchanged recording of the Python 1.7.x oracle, not a
// fixture for the current settings contract. Release 2.0.10 (7cf423b) deliberately
// stopped adding +nothink to arbitrary deepseek-* IDs. Pin both historical rows
// and current results so this exception cannot hide other reference drift.
const Map<int, ({Json python, List<String> current})> _normalize210 = {
  64: (
    python: {
      'operation': 'model_settings.normalize',
      'args': [' https://example.invalid/v1/ ', ' deepseek-test '],
      'result': ['https://example.invalid/v1', 'deepseek-test+nothink'],
    },
    current: ['https://example.invalid/v1', 'deepseek-test'],
  ),
  65: (
    python: {
      'operation': 'model_settings.normalize',
      'args': ['https://example.invalid/proxy/v1', 'DeepSeek-Test'],
      'result': ['https://example.invalid/proxy/v1', 'DeepSeek-Test+nothink'],
    },
    current: ['https://example.invalid/proxy/v1', 'DeepSeek-Test'],
  ),
};

void main() {
  final List<Object?> rows =
      jsonDecode(
            File('test/services/fixtures/personal.json').readAsStringSync(),
          )
          as List<Object?>;
  test('2.0.10 normalization changes retain exact Python source rows', () {
    for (final entry in _normalize210.entries) {
      expect(rows[entry.key], entry.value.python);
    }
  });
  for (int i = 0; i < rows.length; i++) {
    final Json row = rows[i]! as Json;
    final change = _normalize210[i];
    final String contract =
        change == null ? 'Python personal reference' : '2.0.10 model contract';
    test('$contract $i ${row['operation']}', () {
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
        expect(invoke(), change?.current ?? row['result']);
      }
    });
  }
}
