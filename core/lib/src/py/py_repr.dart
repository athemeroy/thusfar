/// Python `repr()` / `str()` for JSON-shaped values, as f-strings print them.
library;

import 'py_json.dart';

String pyStr(Object? v) => v is String ? v : pyRepr(v);

String pyRepr(Object? v) {
  if (v == null) return 'None';
  if (v is bool) return v ? 'True' : 'False';
  if (v is double) {
    if (v.isNaN) return 'nan';
    if (v.isInfinite) return v > 0 ? 'inf' : '-inf';
    return PyJson.floatRepr(v);
  }
  if (v is int || v is BigInt) return '$v';
  if (v is String) return _strRepr(v);
  if (v is List<Object?>) return '[${v.map(pyRepr).join(', ')}]';
  if (v is Map<Object?, Object?>) {
    return '{${v.entries.map((MapEntry<Object?, Object?> e) => '${pyRepr(e.key)}: ${pyRepr(e.value)}').join(', ')}}';
  }
  return '$v';
}

String _strRepr(String s) {
  final String quote = s.contains("'") && !s.contains('"') ? '"' : "'";
  final StringBuffer out = StringBuffer(quote);
  for (final int r in s.runes) {
    if (r == quote.codeUnitAt(0) || r == 0x5c) {
      out.write('\\${String.fromCharCode(r)}');
    } else if (r == 0x0a) {
      out.write(r'\n');
    } else if (r == 0x0d) {
      out.write(r'\r');
    } else if (r == 0x09) {
      out.write(r'\t');
    } else if (r < 0x20 || r == 0x7f) {
      out.write('\\x${r.toRadixString(16).padLeft(2, '0')}');
    } else if (r >= 0x80 && r <= 0xa0 || r == 0xad) {
      out.write('\\x${r.toRadixString(16).padLeft(2, '0')}');
    } else if (r >= 0xd800 && r <= 0xdfff) {
      out.write('\\u${r.toRadixString(16).padLeft(4, '0')}');
    } else {
      out.writeCharCode(r);
    }
  }
  out.write(quote);
  return out.toString();
}
