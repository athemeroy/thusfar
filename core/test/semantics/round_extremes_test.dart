import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/src/py/py_compat.dart';

void main() {
  test('700 Python float rounding extremes match Dart', () {
    int count = 0;
    for (final String line
        in File('../oracle/semantics/round_extremes.jsonl').readAsLinesSync()) {
      final Map<String, Object?> item =
          jsonDecode(line) as Map<String, Object?>;
      final double value = (item['value']! as num).toDouble();
      final int digits = item['digits']! as int;
      if (item['error'] == 'OverflowError') {
        expect(
          () => PyCompat.roundDigits(value, digits),
          throwsRangeError,
          reason: 'case ${item['id']}',
        );
      } else {
        final double actual = PyCompat.roundDigits(value, digits);
        expect(actual, item['expected'], reason: 'case ${item['id']}');
        if (actual == 0.0) {
          expect(
            actual.isNegative,
            item['negative_zero'],
            reason: 'signed zero case ${item['id']}',
          );
        }
      }
      count++;
    }
    expect(count, 700);
  });
}
