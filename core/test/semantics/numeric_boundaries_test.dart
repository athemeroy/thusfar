import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/src/py/py_compat.dart';
import 'package:thusfar_core/src/py/py_json.dart';

Object parseNumber(List<Object?> pair) {
  final String kind = pair[0]! as String;
  final String raw = pair[1]! as String;
  if (kind == 'float') return double.parse(raw);
  return BigInt.parse(raw);
}

Object? evaluate(Map<String, Object?> item) {
  switch (item['op']) {
    case 'round':
      return PyCompat.round(double.parse(item['value']! as String)).toString();
    case 'truncate':
      return PyCompat.truncate(
        double.parse(item['value']! as String),
      ).toString();
    case 'compare':
      return PyCompat.compare(
        parseNumber(item['left']! as List<Object?>),
        parseNumber(item['right']! as List<Object?>),
      );
    case 'floor_div':
      return PyCompat.floorDiv(
        BigInt.parse(item['left']! as String),
        BigInt.parse(item['right']! as String),
      ).toString();
    case 'modulo':
      return PyCompat.modulo(
        BigInt.parse(item['left']! as String),
        BigInt.parse(item['right']! as String),
      ).toString();
    case 'round_floor_div':
      return PyCompat.floorDiv(
        PyCompat.round(double.parse(item['value']! as String)),
        BigInt.parse(item['right']! as String),
      ).toString();
    case 'json_int':
      return PyJson.encode(BigInt.parse(item['value']! as String));
    case 'json_bool_keys':
      return PyJson.encode(<bool, String>{
        true: 'yes',
        false: 'no',
      }, sortKeys: true);
    case 'sort_signed_zero':
      return PyCompat.stableSorted<double>(
        <double>[0.0, -0.0],
        key: (double value) => value,
      ).map((double value) => value.isNegative ? '-0' : '+0').toList();
  }
  throw ArgumentError.value(item['op'], 'op');
}

void main() {
  test('Python integer width and float ordering match Dart', () {
    int count = 0;
    for (final String line
        in File(
          '../oracle/semantics/numeric_boundaries.jsonl',
        ).readAsLinesSync()) {
      final Map<String, Object?> item =
          jsonDecode(line) as Map<String, Object?>;
      if (item['error'] == 'OverflowError') {
        expect(
          () => evaluate(item),
          throwsRangeError,
          reason: 'case ${item['id']}',
        );
      } else if (item['error'] == 'ValueError') {
        expect(
          () => evaluate(item),
          throwsArgumentError,
          reason: 'case ${item['id']}',
        );
      } else {
        expect(evaluate(item), item['expected'], reason: 'case ${item['id']}');
      }
      count++;
    }
    expect(count, greaterThanOrEqualTo(50));
  });
}
