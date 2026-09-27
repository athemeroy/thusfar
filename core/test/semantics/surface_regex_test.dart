import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

Map<String, Object?> _map(Object? value) => value as Map<String, Object?>;

void main() {
  final List<Map<String, Object?>> cases =
      File(
        '../oracle/semantics/surface_regex.jsonl',
      ).readAsLinesSync().map((String line) => _map(jsonDecode(line))).toList();

  test('six production KG surface pattern cases are recorded', () {
    expect(cases, hasLength(6));
    expect(cases.map((Map<String, Object?> row) => row['id']).toSet(), {
      'cjk_astral_generic',
      'latin_ascii_letter_boundaries',
      'overlap_longest_first',
      'escaped_punctuation_and_space',
      'empty_surfaces',
      'all_surfaces_filtered',
    });
  });

  for (final Map<String, Object?> row in cases) {
    test('Python KG surface regex in Dart: ${row['id']}', () {
      final String? pattern = row['dart_pattern'] as String?;
      final RegExp? regex =
          pattern == null ? null : RegExp(pattern, unicode: true);
      for (final Object? rawBlock in row['blocks'] as List<Object?>) {
        final Map<String, Object?> block = _map(rawBlock);
        final String source = block['text'] as String;
        final List<Map<String, Object?>> actual = <Map<String, Object?>>[];
        for (final RegExpMatch match
            in regex?.allMatches(source) ?? <RegExpMatch>[]) {
          actual.add(<String, Object?>{
            'text': match.group(0),
            'groups': <String?>[
              for (int index = 1; index <= match.groupCount; index++)
                match.group(index),
            ],
            'named': <String, Object?>{},
            'span_cp': <int>[
              source.substring(0, match.start).runes.length,
              source.substring(0, match.end).runes.length,
            ],
            'span_utf16': <int>[match.start, match.end],
          });
        }
        expect(
          actual,
          block['matches'],
          reason: '${row['id']} block ${block['bi']}',
        );
      }
    });
  }
}
