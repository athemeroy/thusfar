import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:thusfar_core/src/py/py_compat.dart';

void main() {
  final Map<String, Object?> data =
      jsonDecode(
            File('../oracle/semantics/utf16_offsets.json').readAsStringSync(),
          )
          as Map<String, Object?>;
  final List<Object?> cases = data['cases'] as List<Object?>;

  test('Python 1.7.5 mixed-unit context window is recorded', () {
    expect(cases, hasLength(4));
    for (final Object? item in cases) {
      final Map<String, Object?> row = item as Map<String, Object?>;
      final String source = row['text'] as String;
      final int position = row['position_utf16'] as int;
      final int radius = (row['width_codepoints'] as int) ~/ 2;
      final String frozen = PyCompat.slice(
        source,
        math.max(0, position - radius),
        position + radius,
      );
      expect(frozen, row['frozen_175'], reason: row['id'] as String);

      final int codepointPosition = PyCompat.codePointLength(
        PyCompat.utf16Prefix(source, position),
      );
      final String centered = PyCompat.slice(
        source,
        math.max(0, codepointPosition - radius),
        codepointPosition + radius,
      );
      expect(centered, row['codepoint_centered'], reason: row['id'] as String);
    }
  });
}
