/// Python decimal-string parsing for bounded indices and numeric text.
library;

import 'py_compat.dart';
import 'py_re.dart';

// Unicode 14 decimal digits, matching the frozen Python 3.11 oracle.
const List<int> _decimalZeros = [
  0x30,
  0x660,
  0x6f0,
  0x7c0,
  0x966,
  0x9e6,
  0xa66,
  0xae6,
  0xb66,
  0xbe6,
  0xc66,
  0xce6,
  0xd66,
  0xde6,
  0xe50,
  0xed0,
  0xf20,
  0x1040,
  0x1090,
  0x17e0,
  0x1810,
  0x1946,
  0x19d0,
  0x1a80,
  0x1a90,
  0x1b50,
  0x1bb0,
  0x1c40,
  0x1c50,
  0xa620,
  0xa8d0,
  0xa900,
  0xa9d0,
  0xa9f0,
  0xaa50,
  0xabf0,
  0xff10,
  0x104a0,
  0x10d30,
  0x11066,
  0x110f0,
  0x11136,
  0x111d0,
  0x112f0,
  0x11450,
  0x114d0,
  0x11650,
  0x116c0,
  0x11730,
  0x118e0,
  0x11950,
  0x11c50,
  0x11d50,
  0x11da0,
  0x16a60,
  0x16ac0,
  0x16b50,
  0x1d7ce,
  0x1d7d8,
  0x1d7e2,
  0x1d7ec,
  0x1d7f6,
  0x1e140,
  0x1e2f0,
  0x1e950,
  0x1fbf0,
];

/// Parse Python `int(text)` syntax without hexadecimal prefixes.
///
/// Unlike Dart `int.tryParse`, Python accepts Unicode decimal digits and
/// underscores between digits, while rejecting `0x` without an explicit base.
/// Invalid input returns null; arbitrary precision preserves safe range checks.
BigInt? tryPythonDecimal(String text) {
  // int() rejects the four ASCII information separators that str.strip() accepts.
  if (text.runes.any((r) => r >= 0x1c && r <= 0x1f)) return null;
  final String value = PyCompat.strip(text);
  if (!pyRe(r'^[+-]?\d(?:_?\d)*\Z').hasMatch(value)) return null;
  final StringBuffer ascii = StringBuffer();
  for (final int rune in value.runes) {
    if (rune == 0x5f) continue;
    if (rune == 0x2b || rune == 0x2d) {
      ascii.writeCharCode(rune);
      continue;
    }
    int? digit;
    for (final int zero in _decimalZeros) {
      if (rune >= zero && rune < zero + 10) {
        digit = rune - zero;
        break;
      }
    }
    if (digit == null) return null;
    ascii.write(digit);
  }
  return BigInt.tryParse(ascii.toString());
}
