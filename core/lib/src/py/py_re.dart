/// Python 3.11 `re` patterns executed on Dart's `RegExp`.
///
/// [pyRe] rewrites the Python-only syntax and the Unicode classes whose
/// meaning differs between the engines, so a pattern can be copied from the
/// oracle verbatim. Matching positions are UTF-16 offsets on the Dart side.
library;

const String _ws = r'\u0009-\u000D\u001C- \u0085   -     　';
const String _word = r'\p{L}\p{N}_';
const String _wordBoundary =
    '(?:(?<![$_word])(?=[$_word])|(?<=[$_word])(?![$_word]))';
const String _notWordBoundary =
    '(?:(?<![$_word])(?![$_word])|(?<=[$_word])(?=[$_word]))';

final Map<String, RegExp> _cache = <String, RegExp>{};

/// Compiles Python pattern [pattern] with Python flags.
RegExp pyRe(
  String pattern, {
  bool ignoreCase = false,
  bool multiLine = false,
  bool dotAll = false,
  bool verbose = false,
}) {
  final String key =
      '${ignoreCase ? 'i' : ''}${multiLine ? 'm' : ''}'
      '${dotAll ? 's' : ''}${verbose ? 'x' : ''}\u0000$pattern';
  return _cache[key] ??= _compile(
    pattern,
    ignoreCase,
    multiLine,
    dotAll,
    verbose,
  );
}

RegExp _compile(
  String pattern,
  bool ignoreCase,
  bool multiLine,
  bool dotAll,
  bool verbose,
) {
  String source = pattern;
  // Leading inline flags, e.g. `(?i)` or `(?is)`.
  final RegExpMatch? inline = RegExp(r'^\(\?([aiLmsux]+)\)').firstMatch(source);
  if (inline != null) {
    final String flags = inline.group(1)!;
    ignoreCase |= flags.contains('i');
    multiLine |= flags.contains('m');
    dotAll |= flags.contains('s');
    verbose |= flags.contains('x');
    source = source.substring(inline.end);
  }
  final String translated = _translate(source, multiLine, dotAll, verbose);
  return RegExp(translated, caseSensitive: !ignoreCase, unicode: true);
}

String _translate(String p, bool multiLine, bool dotAll, bool verbose) {
  final StringBuffer out = StringBuffer();
  bool inClass = false;
  int i = 0;
  while (i < p.length) {
    final String c = p[i];
    if (c == r'\') {
      if (i + 1 >= p.length) throw FormatException('trailing backslash', p);
      final String n = p[i + 1];
      i += 2;
      switch (n) {
        case 's':
          out.write(inClass ? _ws : '[$_ws]');
        case 'S':
          out.write(inClass ? _classComplement('S') : '[^$_ws]');
        case 'w':
          out.write(inClass ? _word : '[$_word]');
        case 'W':
          out.write(inClass ? _classComplement('W') : '[^$_word]');
        case 'd':
          out.write(r'\p{Nd}');
        case 'D':
          out.write(r'\P{Nd}');
        case 'b':
          out.write(inClass ? r'\u0008' : _wordBoundary);
        case 'B':
          out.write(_notWordBoundary);
        case 'A':
          out.write(r'(?<![\s\S])');
        case 'Z':
          out.write(r'(?![\s\S])');
        case "'":
        case '"':
        case '`':
        case ' ':
        case '#':
        case '&':
        case '~':
        case '%':
        case ',':
        case ';':
        case ':':
        case '<':
        case '>':
        case '=':
        case '@':
        case '!':
        case '_':
          out.write(n == ' ' ? r' ' : _escapeLiteral(n));
        case 'x':
          out.write(r'\x');
        case 'u':
          out.write(r'\u');
        case 'U':
          final String hex = p.substring(i, i + 8);
          i += 8;
          out.write('\\u{${int.parse(hex, radix: 16).toRadixString(16)}}');
        default:
          out.write('\\$n');
      }
      continue;
    }
    if (inClass) {
      if (c == ']') {
        inClass = false;
      } else if (c == '[') {
        out.write(r'\[');
        i++;
        continue;
      }
      out.write(c);
      i++;
      continue;
    }
    if (verbose) {
      if (c == ' ' ||
          c == '\t' ||
          c == '\n' ||
          c == '\r' ||
          c == '\f' ||
          c == '\v') {
        i++;
        continue;
      }
      if (c == '#') {
        while (i < p.length && p[i] != '\n') {
          i++;
        }
        continue;
      }
    }
    switch (c) {
      case '[':
        inClass = true;
        out.write('[');
        i++;
        if (i < p.length && p[i] == '^') {
          out.write('^');
          i++;
        }
        // A leading `]` is a literal in Python.
        if (i < p.length && p[i] == ']') {
          out.write(r'\]');
          i++;
        }
      case '(':
        if (p.startsWith('(?P<', i)) {
          out.write('(?<');
          i += 4;
        } else if (p.startsWith('(?P=', i)) {
          final int end = p.indexOf(')', i);
          out.write('\\k<${p.substring(i + 4, end)}>');
          i = end + 1;
        } else {
          out.write('(');
          i++;
        }
      case '.':
        out.write(dotAll ? r'[\s\S]' : r'[^\n]');
        i++;
      case r'$':
        out.write(multiLine ? r'(?=\n|(?![\s\S]))' : r'(?=\n?(?![\s\S]))');
        i++;
      case '^':
        out.write(multiLine ? r'(?<=\n|^)' : '^');
        i++;
      case '{':
        // Python treats a brace that does not form a quantifier as literal.
        final Match? q = RegExp(r'\{\d*(,\d*)?\}').matchAsPrefix(p, i);
        if (q == null || q.group(0) == '{}' || q.group(0) == '{,}') {
          out.write(r'\{');
          i++;
        } else {
          final String body = q.group(0)!;
          out.write(body.startsWith('{,') ? '{0${body.substring(1)}' : body);
          i = q.end;
        }
      case '}':
        out.write(r'\}');
        i++;
      default:
        out.write(c);
        i++;
    }
  }
  return out.toString();
}

String _escapeLiteral(String c) {
  final int code = c.codeUnitAt(0);
  return '\\u${code.toRadixString(16).padLeft(4, '0')}';
}

Never _classComplement(String which) =>
    throw UnsupportedError(
      'Python \\$which inside a character class has no direct Dart form',
    );

/// Python `re.sub` replacement templates: `\1`, `\g<1>`, `\g<name>`.
String pySubTemplate(RegExpMatch m, String template) {
  final StringBuffer out = StringBuffer();
  int i = 0;
  while (i < template.length) {
    final String c = template[i];
    if (c != r'\' || i + 1 >= template.length) {
      out.write(c);
      i++;
      continue;
    }
    final String n = template[i + 1];
    if (n == 'g') {
      final int end = template.indexOf('>', i);
      final String name = template.substring(i + 3, end);
      final int? index = int.tryParse(name);
      out.write((index != null ? m.group(index) : m.namedGroup(name)) ?? '');
      i = end + 1;
    } else if (RegExp('[0-9]').hasMatch(n)) {
      int j = i + 1;
      while (j < template.length &&
          j < i + 3 &&
          RegExp('[0-9]').hasMatch(template[j])) {
        j++;
      }
      out.write(m.group(int.parse(template.substring(i + 1, j))) ?? '');
      i = j;
    } else {
      const Map<String, String> escapes = <String, String>{
        'n': '\n',
        't': '\t',
        'r': '\r',
        'f': '\f',
        'v': '\v',
        'a': '\x07',
        r'\': r'\',
      };
      out.write(escapes[n] ?? '\\$n');
      i += 2;
    }
  }
  return out.toString();
}

/// Python `pattern.sub(repl, text, count)` with a template or a function.
String pySub(RegExp re, String text, Object replacement, {int count = 0}) {
  final StringBuffer out = StringBuffer();
  int last = 0;
  int done = 0;
  for (final RegExpMatch m in _pyFinditer(re, text)) {
    if (count > 0 && done >= count) break;
    out.write(text.substring(last, m.start));
    out.write(
      replacement is String
          ? pySubTemplate(m, replacement)
          : (replacement as String Function(RegExpMatch))(m),
    );
    last = m.end;
    done++;
  }
  out.write(text.substring(last));
  return out.toString();
}

/// Python 3.7+ `finditer`: after an empty match the next match may not be
/// empty at the same position; after a non-empty match it may.
Iterable<RegExpMatch> _pyFinditer(RegExp re, String text) sync* {
  int pos = 0;
  bool mustAdvance = false;
  while (pos <= text.length) {
    RegExpMatch? m = _first(re, text, pos);
    if (m == null) return;
    if (mustAdvance && m.start == pos && m.end == pos) {
      if (pos >= text.length) return;
      m = _first(re, text, _advance(text, pos));
      if (m == null) return;
    }
    yield m;
    pos = m.end;
    mustAdvance = m.start == m.end;
  }
}

RegExpMatch? _first(RegExp re, String text, int pos) {
  for (final RegExpMatch m in re.allMatches(text, pos)) {
    return m;
  }
  return null;
}

int _advance(String text, int pos) {
  if (pos + 1 < text.length &&
      text.codeUnitAt(pos) >= 0xd800 &&
      text.codeUnitAt(pos) <= 0xdbff &&
      text.codeUnitAt(pos + 1) >= 0xdc00 &&
      text.codeUnitAt(pos + 1) <= 0xdfff) {
    return pos + 2;
  }
  return pos + 1;
}

/// Python `re.finditer`.
Iterable<RegExpMatch> pyFinditer(RegExp re, String text) =>
    _pyFinditer(re, text);

/// Python `re.findall`: whole match, the single group, or a group tuple.
List<Object?> pyFindall(RegExp re, String text) => <Object?>[
  for (final RegExpMatch m in _pyFinditer(re, text))
    if (m.groupCount == 0)
      m.group(0)
    else if (m.groupCount == 1)
      m.group(1) ?? ''
    else
      <String>[for (int g = 1; g <= m.groupCount; g++) m.group(g) ?? ''],
];

/// Python `re.match`: anchored at the start (or at [pos]).
RegExpMatch? pyMatch(RegExp re, String text, [int pos = 0]) =>
    re.matchAsPrefix(text, pos) as RegExpMatch?;

/// Python `re.fullmatch`.
final Map<RegExp, RegExp> _anchored = <RegExp, RegExp>{};

RegExpMatch? pyFullmatch(RegExp re, String text) {
  final RegExp anchored =
      _anchored[re] ??= RegExp(
        '(?:${re.pattern})(?![\\s\\S])',
        caseSensitive: re.isCaseSensitive,
        unicode: re.isUnicode,
        multiLine: re.isMultiLine,
        dotAll: re.isDotAll,
      );
  return anchored.matchAsPrefix(text) as RegExpMatch?;
}

/// Python `re.search`.
RegExpMatch? pySearch(RegExp re, String text) => re.firstMatch(text);

/// Python `re.split` including captured groups and `maxsplit`.
List<String?> pySplit(RegExp re, String text, {int maxsplit = 0}) {
  final List<String?> out = <String?>[];
  int last = 0;
  int done = 0;
  for (final RegExpMatch m in _pyFinditer(re, text)) {
    if (maxsplit > 0 && done >= maxsplit) break;
    out.add(text.substring(last, m.start));
    for (int g = 1; g <= m.groupCount; g++) {
      out.add(m.group(g));
    }
    last = m.end;
    done++;
  }
  out.add(text.substring(last));
  return out;
}
