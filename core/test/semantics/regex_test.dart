import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

Map<String, Object?> _map(Object? value) => value as Map<String, Object?>;

bool _matches(Map<String, Object?> dart, String mode, String input) {
  final String pattern = dart['pattern'] as String;
  final RegExp regex = RegExp(
    mode == 'fullmatch' ? '(?:$pattern)(?![\\s\\S])' : pattern,
    caseSensitive: dart['case_sensitive'] as bool,
    multiLine: dart['multi_line'] as bool,
    dotAll: dart['dot_all'] as bool,
    unicode: dart['unicode'] as bool,
  );
  if (mode == 'match' || mode == 'fullmatch') {
    return regex.matchAsPrefix(input) != null;
  }
  return regex.hasMatch(input);
}

void _checkCase(String site, Map<String, Object?> dart, Map<String, Object?> examples) {
  final String positive = examples['positive'] as String;
  final String negative = examples['negative'] as String;
  final String mode = examples['mode'] as String;
  expect(_matches(dart, mode, positive), isTrue, reason: '$site positive $positive');
  expect(_matches(dart, mode, negative), isFalse, reason: '$site negative $negative');
}

void main() {
  final File fixture = File('../docs/port/REGEX.json');
  final Map<String, Object?> data = _map(jsonDecode(fixture.readAsStringSync()));
  final List<Object?> rows = data['calls'] as List<Object?>;

  test('all static Python regex examples also run in Dart', () {
    int cases = 0;
    for (final Object? item in rows) {
      final Map<String, Object?> row = _map(item);
      final String id = row['id'] as String;
      if (row['examples'] != null) {
        _checkCase(id, _map(row['dart']), _map(row['examples']));
        cases++;
      }
      final Object? rawVariants = row['variant_examples'];
      if (rawVariants != null) {
        final Map<String, Object?> variants = _map(rawVariants);
        for (final MapEntry<String, Object?> variant in variants.entries) {
          final Map<String, Object?> detail = _map(variant.value);
          _checkCase('$id:${variant.key}', _map(detail['dart']), _map(detail['examples']));
          cases++;
        }
      }
    }
    expect(cases, 153);
  });
}
