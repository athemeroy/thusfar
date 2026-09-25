import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'unicode_data.dart';

/// Python operations whose Dart defaults differ from the frozen 3.11 oracle.
final class PyCompat {
  const PyCompat._();

  static bool _inRanges(int value, List<(int, int)> ranges) {
    int lo = 0;
    int hi = ranges.length;
    while (lo < hi) {
      final int mid = (lo + hi) ~/ 2;
      final (int start, int end) = ranges[mid];
      if (value < start) {
        hi = mid;
      } else if (value > end) {
        lo = mid + 1;
      } else {
        return true;
      }
    }
    return false;
  }

  static int codePointLength(String value) => value.runes.length;

  static int utf16Length(String value) => value.length;

  static int utf16Offset(String value, int codePointOffset) {
    if (codePointOffset < 0) {
      throw RangeError.value(codePointOffset, 'codePointOffset');
    }
    int offset = 0;
    int seen = 0;
    for (final int rune in value.runes) {
      if (seen == codePointOffset) return offset;
      offset += rune > 0xffff ? 2 : 1;
      seen++;
    }
    if (seen == codePointOffset) return offset;
    throw RangeError.value(codePointOffset, 'codePointOffset');
  }

  /// Mirrors Python's UTF-16 decode with `errors='ignore'` at a cutoff.
  static String utf16Prefix(String value, int codeUnits) {
    final int end = codeUnits.clamp(0, value.length);
    if (end > 0 &&
        end < value.length &&
        value.codeUnitAt(end - 1) >= 0xd800 &&
        value.codeUnitAt(end - 1) <= 0xdbff &&
        value.codeUnitAt(end) >= 0xdc00 &&
        value.codeUnitAt(end) <= 0xdfff) {
      return value.substring(0, end - 1);
    }
    return value.substring(0, end);
  }

  static String slice(String value, int? start, int? end) {
    final List<int> runes = value.runes.toList();
    final int size = runes.length;
    final int from = _sliceIndex(start ?? 0, size);
    final int to = _sliceIndex(end ?? size, size);
    return String.fromCharCodes(runes.sublist(from, math.max(from, to)));
  }

  static int _sliceIndex(int index, int length) {
    final int adjusted = index < 0 ? length + index : index;
    return adjusted.clamp(0, length);
  }

  static String strip(String value, {String? chars}) {
    final List<int> runes = value.runes.toList();
    final Set<int>? trimSet = chars?.runes.toSet();
    bool shouldStrip(int rune) =>
        trimSet?.contains(rune) ?? _inRanges(rune, pyWhitespaceRanges);
    int start = 0;
    int end = runes.length;
    while (start < end && shouldStrip(runes[start])) {
      start++;
    }
    while (end > start && shouldStrip(runes[end - 1])) {
      end--;
    }
    return String.fromCharCodes(runes.sublist(start, end));
  }

  static List<String> split(String value, {String? separator}) {
    if (separator != null) {
      if (separator.isEmpty) throw ArgumentError.value(separator, 'separator');
      return value.split(separator);
    }
    final List<String> pieces = <String>[];
    final List<int> runes = value.runes.toList();
    int index = 0;
    while (index < runes.length) {
      while (index < runes.length &&
          _inRanges(runes[index], pyWhitespaceRanges)) {
        index++;
      }
      final int start = index;
      while (index < runes.length &&
          !_inRanges(runes[index], pyWhitespaceRanges)) {
        index++;
      }
      if (start != index) {
        pieces.add(String.fromCharCodes(runes.sublist(start, index)));
      }
    }
    return pieces;
  }

  static bool isDigit(String value) =>
      value.isNotEmpty &&
      value.runes.every((int rune) => _inRanges(rune, pyDigitRanges));

  static String casefold(String value) =>
      value.runes
          .map((int rune) => pyCasefoldMap[rune] ?? String.fromCharCode(rune))
          .join();

  static String title(String value) {
    final StringBuffer result = StringBuffer();
    bool previousCased = false;
    final List<int> runes = value.runes.toList();
    for (int i = 0; i < runes.length; i++) {
      final int rune = runes[i];
      final bool cased = _inRanges(rune, pyCasedRanges);
      final Map<int, String> mapping = previousCased ? pyLowerMap : pyTitleMap;
      if (previousCased && rune == 0x03a3) {
        // Python 3.11 applies Unicode Final_Sigma to the source string. A
        // case-ignorable rune can itself be cased (for example U+0345), so
        // inspecting only the adjacent rune gives the wrong answer.
        int before = i - 1;
        while (before >= 0 && _inRanges(runes[before], pyCaseIgnorableRanges)) {
          before--;
        }
        int after = i + 1;
        while (after < runes.length &&
            _inRanges(runes[after], pyCaseIgnorableRanges)) {
          after++;
        }
        final bool precedingCased =
            before >= 0 && _inRanges(runes[before], pyCasedRanges);
        final bool followingCased =
            after < runes.length && _inRanges(runes[after], pyCasedRanges);
        result.write(precedingCased && !followingCased ? 'ς' : 'σ');
      } else {
        result.write(mapping[rune] ?? String.fromCharCode(rune));
      }
      previousCased = cased;
    }
    return result.toString();
  }

  static Object floorDiv(int a, int b) {
    if (b == 0) throw const PyZeroDivisionError();
    return _narrow(_floorDivBig(BigInt.from(a), BigInt.from(b)));
  }

  static Object modulo(int a, int b) {
    if (b == 0) throw const PyZeroDivisionError();
    final BigInt left = BigInt.from(a);
    final BigInt right = BigInt.from(b);
    return _narrow(left - _floorDivBig(left, right) * right);
  }

  static BigInt _floorDivBig(BigInt a, BigInt b) {
    final BigInt quotient = a ~/ b;
    final BigInt remainder = a.remainder(b);
    return remainder != BigInt.zero && remainder.isNegative != b.isNegative
        ? quotient - BigInt.one
        : quotient;
  }

  static Object _narrow(BigInt value) {
    if (value >= BigInt.parse('-9223372036854775808') &&
        value <= BigInt.parse('9223372036854775807')) {
      return value.toInt();
    }
    return value;
  }

  /// Exact rational represented by a finite IEEE-754 double.
  static (BigInt, BigInt) _floatRatio(double value) {
    final ByteData bytes = ByteData(8)..setFloat64(0, value, Endian.big);
    final int hi = bytes.getUint32(0, Endian.big);
    final int low = bytes.getUint32(4, Endian.big);
    final bool negative = (hi & 0x80000000) != 0;
    final int rawExponent = (hi >> 20) & 0x7ff;
    BigInt mantissa = (BigInt.from(hi & 0xfffff) << 32) | BigInt.from(low);
    if (rawExponent != 0) mantissa |= BigInt.one << 52;
    final int exponent = (rawExponent == 0 ? -1022 : rawExponent - 1023) - 52;
    BigInt numerator = mantissa;
    BigInt denominator = BigInt.one;
    if (exponent >= 0) {
      numerator <<= exponent;
    } else {
      denominator <<= -exponent;
    }
    return (negative ? -numerator : numerator, denominator);
  }

  static void _requireFiniteIntegerInput(double value) {
    if (value.isNaN) {
      throw ArgumentError.value(
        value,
        'value',
        'cannot convert NaN to integer',
      );
    }
    if (!value.isFinite) {
      throw RangeError.value(
        value,
        'value',
        'cannot convert infinity to integer',
      );
    }
  }

  static Object truncate(double value) {
    _requireFiniteIntegerInput(value);
    final (BigInt numerator, BigInt denominator) = _floatRatio(value);
    return _narrow(numerator ~/ denominator);
  }

  static Object round(double value) {
    _requireFiniteIntegerInput(value);
    final (BigInt numerator, BigInt denominator) = _floatRatio(value);
    final bool negative = numerator.isNegative;
    final BigInt magnitude = numerator.abs();
    final BigInt quotient = magnitude ~/ denominator;
    final BigInt remainder = magnitude.remainder(denominator);
    final int half = (remainder * BigInt.two).compareTo(denominator);
    final BigInt rounded =
        half > 0 || (half == 0 && quotient.isOdd)
            ? quotient + BigInt.one
            : quotient;
    return _narrow(negative ? -rounded : rounded);
  }

  /// Decimal-place rounding against the exact binary value, with ties to even.
  static double roundDigits(double value, int digits) {
    if (!value.isFinite) return value;
    if (value == 0) return value;
    if (digits > 323) return value;
    if (digits < -308) return value.isNegative ? -0.0 : 0.0;
    final ByteData bytes = ByteData(8)..setFloat64(0, value, Endian.big);
    final int hi = bytes.getUint32(0, Endian.big);
    final int low = bytes.getUint32(4, Endian.big);
    final bool negative = (hi & 0x80000000) != 0;
    final int rawExponent = (hi >> 20) & 0x7ff;
    BigInt mantissa = (BigInt.from(hi & 0xfffff) << 32) | BigInt.from(low);
    if (rawExponent != 0) mantissa |= BigInt.one << 52;
    final int binaryExponent =
        (rawExponent == 0 ? -1022 : rawExponent - 1023) - 52;
    BigInt numerator = mantissa;
    BigInt denominator = BigInt.one;
    if (binaryExponent >= 0) {
      numerator <<= binaryExponent;
    } else {
      denominator <<= -binaryExponent;
    }
    final BigInt scale = BigInt.from(10).pow(digits.abs());
    if (digits >= 0) {
      numerator *= scale;
    } else {
      denominator *= scale;
    }
    final BigInt quotient = numerator ~/ denominator;
    final BigInt remainder = numerator.remainder(denominator);
    final int comparison = (remainder * BigInt.two).compareTo(denominator);
    final BigInt rounded =
        comparison > 0 || (comparison == 0 && quotient.isOdd)
            ? quotient + BigInt.one
            : quotient;
    final String roundedText = rounded.toString();
    final String decimal;
    if (digits > 0) {
      final String padded = roundedText.padLeft(digits + 1, '0');
      final int point = padded.length - digits;
      decimal = '${padded.substring(0, point)}.${padded.substring(point)}';
    } else if (digits < 0) {
      decimal = '$roundedText${List<String>.filled(-digits, '0').join()}';
    } else {
      decimal = '$roundedText.0';
    }
    final double result = double.parse(decimal);
    if (!result.isFinite) {
      throw RangeError.value(
        value,
        'value',
        'Rounded value exceeds double range',
      );
    }
    return negative ? -result : result;
  }

  static int compare(Object? a, Object? b) {
    if (a is bool) a = a ? 1 : 0;
    if (b is bool) b = b ? 1 : 0;
    if (a is double && b is double) return (a > b ? 1 : 0) - (a < b ? 1 : 0);
    if (a is int || a is BigInt) {
      final BigInt left = a is int ? BigInt.from(a) : a! as BigInt;
      if (b is int || b is BigInt) {
        final BigInt right = b is int ? BigInt.from(b) : b! as BigInt;
        return left.compareTo(right);
      }
      if (b is double) {
        if (b.isNaN) return 0;
        if (b == double.infinity) return -1;
        if (b == double.negativeInfinity) return 1;
        final (BigInt numerator, BigInt denominator) = _floatRatio(b);
        return (left * denominator).compareTo(numerator);
      }
    }
    if (a is double && (b is int || b is BigInt)) return -compare(b, a);
    if (a is String && b is String) {
      final Iterator<int> left = a.runes.iterator;
      final Iterator<int> right = b.runes.iterator;
      while (true) {
        final bool l = left.moveNext();
        final bool r = right.moveNext();
        if (!l || !r) return l == r ? 0 : (l ? 1 : -1);
        final int result = left.current.compareTo(right.current);
        if (result != 0) return result;
      }
    }
    if (a is List<Object?> && b is List<Object?>) {
      final int limit = math.min(a.length, b.length);
      for (int i = 0; i < limit; i++) {
        final int result = compare(a[i], b[i]);
        if (result != 0) return result;
      }
      return a.length.compareTo(b.length);
    }
    throw ArgumentError(
      'Python cannot compare ${a.runtimeType} with ${b.runtimeType}',
    );
  }

  static List<T> stableSorted<T>(
    Iterable<T> values, {
    required Object? Function(T) key,
    bool reverse = false,
  }) {
    final List<(int, T, Object?)> rows = <(int, T, Object?)>[];
    int index = 0;
    for (final T value in values) {
      rows.add((index++, value, key(value)));
    }
    rows.sort(((int, T, Object?) a, (int, T, Object?) b) {
      final int order = compare(a.$3, b.$3);
      if (order != 0) return reverse ? -order : order;
      return a.$1.compareTo(b.$1);
    });
    return rows.map(((int, T, Object?) row) => row.$2).toList();
  }

  static LinkedHashMap<K, V> orderedMap<K, V>() => LinkedHashMap<K, V>();
}

final class PyZeroDivisionError implements Exception {
  const PyZeroDivisionError();

  @override
  String toString() => 'division by zero';
}
