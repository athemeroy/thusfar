import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/src/py/py_re.dart';

void main() {
  final List<String> lines =
      File('../oracle/semantics/py_re.jsonl').readAsLinesSync();
  for (final String line in lines) {
    final Map<String, Object?> row = jsonDecode(line) as Map<String, Object?>;
    final String pattern = row['pattern']! as String;
    final List<Object?> flags = row['flags']! as List<Object?>;
    test('pyRe $pattern $flags', () {
      final RegExp re = pyRe(
        pattern,
        ignoreCase: flags.contains('I'),
        multiLine: flags.contains('M'),
        dotAll: flags.contains('S'),
        verbose: flags.contains('X'),
      );
      for (final Object? raw in row['cases']! as List<Object?>) {
        final Map<String, Object?> c = raw! as Map<String, Object?>;
        final String text = c['text']! as String;
        final List<Object?> found = <Object?>[
          for (final RegExpMatch m in pyFinditer(re, text))
            <Object?>[
              m.start,
              m.end,
              <String?>[for (int g = 1; g <= m.groupCount; g++) m.group(g)],
            ],
        ];
        expect(found, c['finditer'], reason: 'finditer ${jsonEncode(text)}');
        final RegExpMatch? head = pyMatch(re, text);
        expect(
          head == null ? null : <int>[head.start, head.end],
          c['match'],
          reason: 'match ${jsonEncode(text)}',
        );
        expect(
          pyFullmatch(re, text) != null,
          c['fullmatch'],
          reason: 'fullmatch ${jsonEncode(text)}',
        );
        expect(
          pySplit(re, text),
          c['split'],
          reason: 'split ${jsonEncode(text)}',
        );
      }
    });
  }
}
