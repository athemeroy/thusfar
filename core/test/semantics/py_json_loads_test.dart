import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/src/errors.dart';
import 'package:thusfar_core/src/py/py_json.dart';
import 'package:thusfar_core/src/py/py_json_decode.dart';

void main() {
  test('pyJsonLoads matches Python json.loads values and messages', () {
    for (final String line
        in File('../oracle/semantics/json_loads.jsonl').readAsLinesSync()) {
      final Map<String, Object?> c = jsonDecode(line) as Map<String, Object?>;
      final String text = c['text']! as String;
      if (c.containsKey('error')) {
        expect(
          () => pyJsonLoads(text),
          throwsA(
            isA<PyJsonDecodeError>().having(
              (PyJsonDecodeError e) => e.message,
              'message',
              c['error'],
            ),
          ),
          reason: jsonEncode(text),
        );
      } else {
        expect(
          PyJson.encode(pyJsonLoads(text)),
          c['ok'],
          reason: jsonEncode(text),
        );
      }
    }
  });
}
