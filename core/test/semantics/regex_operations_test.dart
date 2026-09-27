import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// Test-only adapters for the shared operation examples. The production regex
// port still needs per-call-site goldens and its own compatibility routines.
Map<String, Object?> _map(Object? value) => value as Map<String, Object?>;

RegExp _compiled(Map<String, Object?> row) {
  final String pattern = row['dart_pattern'] as String;
  final List<Object?> flags = row['flags'] as List<Object?>;
  // Python fullmatch requires the absolute end. A plain $ would also accept
  // the position before a final newline in JavaScript-style regex engines.
  final String effective =
      row['operation'] == 'fullmatch' ? '(?:$pattern)(?![\\s\\S])' : pattern;
  return RegExp(
    effective,
    dotAll: flags.contains('S'),
    multiLine: flags.contains('M'),
    unicode: row['unicode'] == true,
  );
}

Map<String, Object?> _matched(
  Map<String, Object?> row,
  RegExp regex,
  String input,
) {
  final String operation = row['operation'] as String;
  final RegExpMatch? match =
      operation == 'search'
          ? regex.firstMatch(input)
          : regex.matchAsPrefix(input) as RegExpMatch?;
  if (match == null) return {'matched': false};
  final Map<String, Object?> expected = _map(row['expected']);
  final Map<String, Object?> expectedNamed = _map(expected['named']);
  final Map<String, Object?> named = {
    for (final String name in expectedNamed.keys) name: match.namedGroup(name),
  };
  return {
    'matched': true,
    'text': match.group(0),
    'groups': [
      for (int index = 1; index <= match.groupCount; index++)
        match.group(index),
    ],
    'named': named,
    'span_cp': [
      input.substring(0, match.start).runes.length,
      input.substring(0, match.end).runes.length,
    ],
    'span_utf16': [match.start, match.end],
  };
}

List<Object?> _splitWithGroups(RegExp regex, String input, int maxsplit) {
  final List<Object?> parts = [];
  int cursor = 0;
  int splits = 0;
  for (final RegExpMatch match in regex.allMatches(input)) {
    if (maxsplit != 0 && splits >= maxsplit) break;
    parts.add(input.substring(cursor, match.start));
    for (int index = 1; index <= match.groupCount; index++) {
      parts.add(match.group(index));
    }
    cursor = match.end;
    splits++;
  }
  parts.add(input.substring(cursor));
  return parts;
}

String _expand(RegExpMatch match, String replacement) {
  final StringBuffer result = StringBuffer();
  for (int index = 0; index < replacement.length; index++) {
    final String char = replacement[index];
    if (char != '\\') {
      result.write(char);
      continue;
    }
    if (++index >= replacement.length) {
      throw const FormatException('Dangling Python replacement escape');
    }
    final String escape = replacement[index];
    if (escape == 'g' &&
        index + 1 < replacement.length &&
        replacement[index + 1] == '<') {
      final int close = replacement.indexOf('>', index + 2);
      if (close < 0)
        throw const FormatException('Unclosed Python group reference');
      final String key = replacement.substring(index + 2, close);
      final int? number = int.tryParse(key);
      result.write(
        number == null
            ? match.namedGroup(key) ?? ''
            : match.group(number) ?? '',
      );
      index = close;
    } else if (RegExp(r'[1-9]').hasMatch(escape)) {
      result.write(match.group(int.parse(escape)) ?? '');
    } else {
      result.write(switch (escape) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        '\\' => '\\',
        _ =>
          throw FormatException(
            'Unsupported Python replacement escape: $escape',
          ),
      });
    }
  }
  return result.toString();
}

Map<String, Object?> _sub(
  RegExp regex,
  String input,
  String replacement,
  int limit,
) {
  final StringBuffer output = StringBuffer();
  int cursor = 0;
  int replacements = 0;
  for (final RegExpMatch match in regex.allMatches(input)) {
    if (limit != 0 && replacements >= limit) break;
    output.write(input.substring(cursor, match.start));
    output.write(_expand(match, replacement));
    cursor = match.end;
    replacements++;
  }
  output.write(input.substring(cursor));
  return {'output': output.toString(), 'replacements': replacements};
}

Map<String, Object?> _run(Map<String, Object?> row) {
  final String input = row['input'] as String;
  final RegExp regex = _compiled(row);
  return switch (row['operation']) {
    'search' || 'match' || 'fullmatch' => _matched(row, regex, input),
    'split' => {
      'parts': _splitWithGroups(regex, input, row['maxsplit'] as int),
    },
    'sub' => _sub(
      regex,
      input,
      row['replacement'] as String,
      row['count'] as int,
    ),
    _ => throw FormatException('Unknown regex operation: ${row['operation']}'),
  };
}

void main() {
  final List<Map<String, Object?>> cases =
      File(
        '../oracle/semantics/regex_operations.jsonl',
      ).readAsLinesSync().map((line) => _map(jsonDecode(line))).toList();
  for (final Map<String, Object?> row in cases) {
    test('Python 3.11 regex operation: ${row['id']}', () {
      expect(
        _run(row),
        equals(row['expected']),
        reason: row['topic'] as String,
      );
    });
  }
}
