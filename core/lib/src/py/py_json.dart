import 'dart:collection';

/// Python 3.12/3.13 `json.dumps` for JSON-compatible values.
///
/// The options expose the variants used for Thusfar's persisted hashes and
/// protocol bodies. Map insertion order is retained unless [sortKeys] is set.
final class PyJson {
  const PyJson._();

  static String encode(
    Object? value, {
    bool ensureAscii = true,
    bool sortKeys = false,
    bool compact = false,
    bool allowNan = true,
  }) {
    final StringBuffer out = StringBuffer();
    _write(value, out, ensureAscii, sortKeys, compact, allowNan);
    return out.toString();
  }

  static void _write(
    Object? value,
    StringBuffer out,
    bool ensureAscii,
    bool sortKeys,
    bool compact,
    bool allowNan,
  ) {
    if (value == null) {
      out.write('null');
    } else if (value is bool) {
      out.write(value ? 'true' : 'false');
    } else if (value is String) {
      _writeString(value, out, ensureAscii);
    } else if (value is int) {
      out.write(value);
    } else if (value is double) {
      if (!allowNan && !value.isFinite) {
        throw ArgumentError.value(value, 'value', 'Non-finite JSON number');
      }
      out.write(_float(value));
    } else if (value is List<Object?>) {
      out.write('[');
      for (int i = 0; i < value.length; i++) {
        if (i != 0) out.write(compact ? ',' : ', ');
        _write(value[i], out, ensureAscii, sortKeys, compact, allowNan);
      }
      out.write(']');
    } else if (value is HashMap<Object?, Object?>) {
      throw ArgumentError.value(value, 'value', 'Unordered collection');
    } else if (value is Map<Object?, Object?>) {
      final List<MapEntry<Object?, Object?>> entries = value.entries.toList();
      if (sortKeys) {
        entries.sort((
          MapEntry<Object?, Object?> a,
          MapEntry<Object?, Object?> b,
        ) {
          if (a.key is String && b.key is String) {
            return _compareCodePoints(a.key! as String, b.key! as String);
          }
          if (a.key is num && b.key is num) {
            return (a.key! as num).compareTo(b.key! as num);
          }
          throw ArgumentError('Python cannot sort mixed JSON key types');
        });
      }
      out.write('{');
      for (int i = 0; i < entries.length; i++) {
        if (i != 0) out.write(compact ? ',' : ', ');
        _writeString(_key(entries[i].key), out, ensureAscii);
        out.write(compact ? ':' : ': ');
        _write(entries[i].value, out, ensureAscii, sortKeys, compact, allowNan);
      }
      out.write('}');
    } else if (value is Set<Object?>) {
      throw ArgumentError.value(value, 'value', 'Unordered collection');
    } else {
      throw ArgumentError.value(value, 'value', 'Not JSON serializable');
    }
  }

  static String _key(Object? key) {
    if (key is String) return key;
    if (key == null) return 'null';
    if (key is bool) return key ? 'true' : 'false';
    if (key is int) return key.toString();
    if (key is double) return _float(key);
    throw ArgumentError.value(key, 'key', 'Not a JSON object key');
  }

  static int _compareCodePoints(String a, String b) {
    final Iterator<int> ai = a.runes.iterator;
    final Iterator<int> bi = b.runes.iterator;
    while (true) {
      final bool ah = ai.moveNext();
      final bool bh = bi.moveNext();
      if (!ah || !bh) return ah == bh ? 0 : (ah ? 1 : -1);
      final int c = ai.current.compareTo(bi.current);
      if (c != 0) return c;
    }
  }

  static String _float(double value) {
    if (value.isNaN) return 'NaN';
    if (value == double.infinity) return 'Infinity';
    if (value == double.negativeInfinity) return '-Infinity';
    final String raw = value.toString();
    final double magnitude = value.abs();
    if (magnitude == 0 || (magnitude >= 1e-4 && magnitude < 1e16)) {
      return raw;
    }
    final bool negative = raw.startsWith('-');
    final String unsigned = negative ? raw.substring(1) : raw;
    final int e = unsigned.indexOf('e');
    final String mantissa = e < 0 ? unsigned : unsigned.substring(0, e);
    final int extraExponent = e < 0 ? 0 : int.parse(unsigned.substring(e + 1));
    final int dot = mantissa.indexOf('.');
    final int decimalPosition = dot < 0 ? mantissa.length : dot;
    final String digits = mantissa.replaceAll('.', '');
    int first = 0;
    while (first < digits.length && digits.codeUnitAt(first) == 0x30) {
      first++;
    }
    if (first == digits.length) return negative ? '-0.0' : '0.0';
    int last = digits.length - 1;
    while (last > first && digits.codeUnitAt(last) == 0x30) {
      last--;
    }
    final String significant = digits.substring(first, last + 1);
    final int exponent = decimalPosition - first - 1 + extraExponent;
    final String coefficient =
        significant.length == 1
            ? significant
            : '${significant[0]}.${significant.substring(1)}';
    final String sign = exponent < 0 ? '-' : '+';
    final String exp = exponent.abs().toString().padLeft(2, '0');
    return '${negative ? '-' : ''}${coefficient}e$sign$exp';
  }

  static void _writeString(String value, StringBuffer out, bool ensureAscii) {
    out.write('"');
    for (final int cu in value.codeUnits) {
      switch (cu) {
        case 0x22:
          out.write(r'\"');
        case 0x5c:
          out.write(r'\\');
        case 0x08:
          out.write(r'\b');
        case 0x0c:
          out.write(r'\f');
        case 0x0a:
          out.write(r'\n');
        case 0x0d:
          out.write(r'\r');
        case 0x09:
          out.write(r'\t');
        default:
          if (cu < 0x20 || (ensureAscii && cu > 0x7f)) {
            out.write('\\u${cu.toRadixString(16).padLeft(4, '0')}');
          } else {
            out.writeCharCode(cu);
          }
      }
    }
    out.write('"');
  }
}
