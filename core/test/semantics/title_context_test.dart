import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/src/py/py_compat.dart';

void main() {
  test('Python 3.11 final sigma title context matches Dart', () {
    int count = 0;
    for (final String line
        in File('../oracle/semantics/title_context.jsonl').readAsLinesSync()) {
      final Map<String, Object?> item =
          jsonDecode(line) as Map<String, Object?>;
      expect(
        PyCompat.title(item['source']! as String),
        item['expected'],
        reason: 'case ${item['id']}',
      );
      count++;
    }
    expect(count, greaterThanOrEqualTo(300));
  });
}
