import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/src/py/py_json.dart';

void main() {
  test('10,000 Python json.dumps values match byte for byte', () {
    final File source = File('../oracle/semantics/py_json.jsonl');
    int count = 0;
    for (final String line in source.readAsLinesSync()) {
      final Map<String, Object?> caseData =
          jsonDecode(line) as Map<String, Object?>;
      final String actual = PyJson.encode(
        caseData['value'],
        ensureAscii: caseData['ensure_ascii']! as bool,
        sortKeys: caseData['sort_keys']! as bool,
        compact: caseData['compact']! as bool,
      );
      expect(actual, caseData['expected'], reason: 'case ${caseData['id']}');
      count++;
    }
    expect(count, 10000);
  });

  test('non-finite numbers and Unicode key order match Python', () {
    expect(
      PyJson.encode(<Object?>[
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]),
      '[NaN, Infinity, -Infinity]',
    );
    expect(
      PyJson.encode(
        <String, int>{'𠮷': 1, '\ue000': 2},
        ensureAscii: false,
        sortKeys: true,
      ),
      '{"\ue000": 2, "𠮷": 1}',
    );
    expect(
      () => PyJson.encode(double.nan, allowNan: false),
      throwsArgumentError,
    );
    expect(
      () => PyJson.encode(HashMap<String, int>.of(<String, int>{'a': 1})),
      throwsArgumentError,
    );
  });
}
