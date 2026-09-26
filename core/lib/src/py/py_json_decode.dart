/// Python 3.11 `json.loads` with its exact error messages.
///
/// Accepts `NaN`, `Infinity` and `-Infinity` like Python; objects keep
/// insertion order and a repeated key keeps its first position with the
/// last value. Positions in messages are code points, as Python reports.
library;

import '../errors.dart';

Object? pyJsonLoads(String s) => _Decoder(s).decode();

final class _Decoder {
  _Decoder(this.s);

  final String s;

  static final RegExp _ws = RegExp(r'[ \t\n\r]*');
  static final RegExp _number = RegExp(
    r'(-?(?:0|[1-9]\d*))(\.\d+)?([eE][-+]?\d+)?',
  );

  Never _fail(String msg, int pos) {
    final String before = s.substring(0, pos);
    final int line = '\n'.allMatches(before).length + 1;
    final int lastNl = before.lastIndexOf('\n');
    final int cpPos = _cp(before);
    final int col =
        lastNl < 0 ? cpPos + 1 : cpPos - _cp(s.substring(0, lastNl + 1)) + 1;
    throw PyJsonDecodeError('$msg: line $line column $col (char $cpPos)');
  }

  static int _cp(String t) {
    int n = t.length;
    for (int i = 0; i + 1 < t.length; i++) {
      final int c = t.codeUnitAt(i);
      if (c >= 0xd800 && c <= 0xdbff) {
        final int d = t.codeUnitAt(i + 1);
        if (d >= 0xdc00 && d <= 0xdfff) {
          n--;
          i++;
        }
      }
    }
    return n;
  }

  int _skip(int i) => _ws.matchAsPrefix(s, i)!.end;

  Object? decode() {
    final int start = _skip(0);
    final (Object? value, int end) = _value(start);
    final int after = _skip(end);
    if (after != s.length) _fail('Extra data', after);
    return value;
  }

  (Object?, int) _value(int i) {
    if (i >= s.length) _fail('Expecting value', i);
    final String c = s[i];
    if (c == '"') return _string(i + 1);
    if (c == '{') return _object(i + 1);
    if (c == '[') return _array(i + 1);
    if (c == 'n' && s.startsWith('null', i)) return (null, i + 4);
    if (c == 't' && s.startsWith('true', i)) return (true, i + 4);
    if (c == 'f' && s.startsWith('false', i)) return (false, i + 5);
    final Match? m = _number.matchAsPrefix(s, i);
    if (m != null) {
      if (m.group(2) != null || m.group(3) != null) {
        return (double.parse(m.group(0)!), m.end);
      }
      return (int.tryParse(m.group(0)!) ?? BigInt.parse(m.group(0)!), m.end);
    }
    if (c == 'N' && s.startsWith('NaN', i)) return (double.nan, i + 3);
    if (c == 'I' && s.startsWith('Infinity', i))
      return (double.infinity, i + 8);
    if (c == '-' && s.startsWith('-Infinity', i))
      return (double.negativeInfinity, i + 9);
    _fail('Expecting value', i);
  }

  (String, int) _string(int start) {
    final StringBuffer out = StringBuffer();
    int i = start;
    while (true) {
      if (i >= s.length) _fail('Unterminated string starting at', start - 1);
      final int c = s.codeUnitAt(i);
      if (c == 0x22) return (out.toString(), i + 1);
      if (c == 0x5c) {
        if (i + 1 >= s.length)
          _fail('Unterminated string starting at', start - 1);
        final String e = s[i + 1];
        switch (e) {
          case '"':
            out.write('"');
          case r'\':
            out.write(r'\');
          case '/':
            out.write('/');
          case 'b':
            out.write('\b');
          case 'f':
            out.write('\f');
          case 'n':
            out.write('\n');
          case 'r':
            out.write('\r');
          case 't':
            out.write('\t');
          case 'u':
            final String hex =
                i + 6 <= s.length ? s.substring(i + 2, i + 6) : '';
            if (!RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(hex))
              _fail('Invalid \\uXXXX escape', i + 1);
            int code = int.parse(hex, radix: 16);
            i += 6;
            if (code >= 0xd800 && code <= 0xdbff && s.startsWith(r'\u', i)) {
              final String low =
                  i + 6 <= s.length ? s.substring(i + 2, i + 6) : '';
              if (RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(low)) {
                final int lo = int.parse(low, radix: 16);
                if (lo >= 0xdc00 && lo <= 0xdfff) {
                  code = 0x10000 + ((code - 0xd800) << 10) + (lo - 0xdc00);
                  i += 6;
                }
              }
            }
            out.writeCharCode(code);
            continue;
          default:
            _fail('Invalid \\escape', i);
        }
        i += 2;
        continue;
      }
      if (c < 0x20) _fail('Invalid control character at', i);
      out.writeCharCode(c);
      i++;
    }
  }

  (Map<String, Object?>, int) _object(int i) {
    final Map<String, Object?> out = <String, Object?>{};
    int j = _skip(i);
    if (j < s.length && s[j] == '}') return (out, j + 1);
    while (true) {
      if (j >= s.length || s[j] != '"') {
        _fail('Expecting property name enclosed in double quotes', j);
      }
      final (String key, int afterKey) = _string(j + 1);
      j = _skip(afterKey);
      if (j >= s.length || s[j] != ':') _fail("Expecting ':' delimiter", j);
      j = _skip(j + 1);
      final (Object? value, int afterValue) = _value(j);
      out[key] = value;
      j = _skip(afterValue);
      if (j < s.length && s[j] == '}') return (out, j + 1);
      if (j >= s.length || s[j] != ',') _fail("Expecting ',' delimiter", j);
      j = _skip(j + 1);
    }
  }

  (List<Object?>, int) _array(int i) {
    final List<Object?> out = <Object?>[];
    int j = _skip(i);
    if (j < s.length && s[j] == ']') return (out, j + 1);
    while (true) {
      final (Object? value, int after) = _value(j);
      out.add(value);
      j = _skip(after);
      if (j < s.length && s[j] == ']') return (out, j + 1);
      if (j >= s.length || s[j] != ',') _fail("Expecting ',' delimiter", j);
      j = _skip(j + 1);
    }
  }
}
