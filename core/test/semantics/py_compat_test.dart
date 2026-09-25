import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/src/py/py_compat.dart';

Object? evaluate(String op, List<Object?> args) {
  switch (op) {
    case 'code_point_length':
      return PyCompat.codePointLength(args[0]! as String);
    case 'utf16_length':
      return PyCompat.utf16Length(args[0]! as String);
    case 'utf16_offset':
      return PyCompat.utf16Offset(args[0]! as String, args[1]! as int);
    case 'utf16_prefix':
      return PyCompat.utf16Prefix(args[0]! as String, args[1]! as int);
    case 'slice':
      return PyCompat.slice(
        args[0]! as String,
        args[1] as int?,
        args[2] as int?,
      );
    case 'strip':
      return PyCompat.strip(args[0]! as String, chars: args[1] as String?);
    case 'split':
      return PyCompat.split(args[0]! as String, separator: args[1] as String?);
    case 'isdigit':
      return PyCompat.isDigit(args[0]! as String);
    case 'casefold':
      return PyCompat.casefold(args[0]! as String);
    case 'title':
      return PyCompat.title(args[0]! as String);
    case 'floor_div':
      return PyCompat.floorDiv(args[0]! as int, args[1]! as int);
    case 'modulo':
      return PyCompat.modulo(args[0]! as int, args[1]! as int);
    case 'truncate':
      return PyCompat.truncate(args[0]! as double);
    case 'round':
      return PyCompat.round(args[0]! as double);
    case 'round_digits':
      return PyCompat.roundDigits(args[0]! as double, args[1]! as int);
    case 'compare':
      return PyCompat.compare(args[0], args[1]);
    case 'stable_sort':
      final List<Object?> rows = args[0]! as List<Object?>;
      return PyCompat.stableSorted<List<Object?>>(
        rows.cast<List<Object?>>(),
        key: (List<Object?> row) => row[0],
      );
    case 'ordered_map':
      final List<Object?> rows = args[0]! as List<Object?>;
      final Map<String, Object?> ordered =
          PyCompat.orderedMap<String, Object?>();
      for (final Object? raw in rows) {
        final List<Object?> pair = raw! as List<Object?>;
        ordered[pair[0]! as String] = pair[1];
      }
      return ordered.entries
          .map((MapEntry<String, Object?> row) => <Object?>[row.key, row.value])
          .toList();
  }
  throw ArgumentError.value(op, 'op', 'Unknown semantic operation');
}

void main() {
  test('5,726 Python general semantic cases match Dart', () {
    int count = 0;
    for (final String line
        in File('../oracle/semantics/general.jsonl').readAsLinesSync()) {
      final Map<String, Object?> caseData =
          jsonDecode(line) as Map<String, Object?>;
      final String op = caseData['op']! as String;
      final List<Object?> args = caseData['args']! as List<Object?>;
      final Object? actual = evaluate(op, args);
      expect(
        actual,
        caseData['expected'],
        reason: 'case ${caseData['id']} ($op)',
      );
      count++;
    }
    expect(count, 5726);
  });
}
