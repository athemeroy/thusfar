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
      if (previousCased &&
          rune == 0x03a3 &&
          (i + 1 == runes.length || !_inRanges(runes[i + 1], pyCasedRanges))) {
        result.write('ς');
      } else {
        result.write(mapping[rune] ?? String.fromCharCode(rune));
      }
      previousCased = cased;
    }
    return result.toString();
  }

  static int floorDiv(int a, int b) {
    if (b == 0) throw const PyZeroDivisionError();
    final int q = a ~/ b;
    final int r = a.remainder(b);
    return r != 0 && ((r < 0) != (b < 0)) ? q - 1 : q;
  }

  static int modulo(int a, int b) => a - floorDiv(a, b) * b;

  static int truncate(double value) => value.truncate();

  static int round(double value) {
    if (!value.isFinite) throw ArgumentError.value(value, 'value');
    final int lower = value.floor();
    final double fraction = value - lower;
    if (fraction < 0.5) return lower;
    if (fraction > 0.5) return lower + 1;
    return lower.isEven ? lower : lower + 1;
  }

  /// Decimal-place rounding against the exact binary value, with ties to even.
  static double roundDigits(double value, int digits) {
    if (!value.isFinite) return value;
    if (value == 0) return value;
    if (digits.abs() > 308) {
      throw RangeError.value(digits, 'digits', 'Outside the recorded range');
    }
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
    final double result =
        digits >= 0
            ? rounded.toDouble() / math.pow(10, digits)
            : rounded.toDouble() * math.pow(10, -digits);
    return negative ? -result : result;
  }

  static int compare(Object? a, Object? b) {
    if (a is bool) a = a ? 1 : 0;
    if (b is bool) b = b ? 1 : 0;
    if (a is num && b is num) return a.compareTo(b);
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
