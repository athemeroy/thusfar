import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/src/errors.dart';
import 'package:thusfar_core/src/pipeline/epub.dart';
import 'package:thusfar_core/src/pipeline/parse.dart';

void main() {
  final Map<String, Object?> report =
      jsonDecode(
            File('../oracle/goldens/parsed/report.json').readAsStringSync(),
          )
          as Map<String, Object?>;
  for (final Object? raw in report['cases']! as List<Object?>) {
    final Map<String, Object?> c = raw! as Map<String, Object?>;
    final String input = c['input']! as String;
    final bool epub = input.endsWith('.epub');
    test('parse $input', () {
      final File src = File('../oracle/corpus/$input');
      final String stem = src.uri.pathSegments.last.replaceAll(
        RegExp(r'\.(txt|epub)$'),
        '',
      );
      final Map<String, int> images = <String, int>{};
      Map<String, Object?> parse() =>
          epub
              ? parseEpubFile(
                src.readAsBytesSync(),
                stem,
                (String name, List<int> data) => images[name] = data.length,
              )
              : parseTxt(src.readAsBytesSync(), stem);
      if (c['outcome'] == 'expected_rejection') {
        expect(parse, throwsA(isA<ValueError>()));
        return;
      }
      final Object? want = jsonDecode(
        File(
          '../oracle/goldens/parsed/${c['output']}/book.json',
        ).readAsStringSync(),
      );
      final Object? got = jsonDecode(jsonEncode(parse()));
      final Map<String, Object?> w = want! as Map<String, Object?>;
      final Map<String, Object?> g = got! as Map<String, Object?>;
      for (final String k in w.keys) {
        expect(g[k], w[k], reason: k);
      }
      expect(g.keys.toList(), w.keys.toList());
    });
  }
}
