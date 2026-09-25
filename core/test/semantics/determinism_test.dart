import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';
import 'package:thusfar_core/src/py/injected_sources.dart';

final class FixedClock implements ClockSource {
  const FixedClock(this.value);

  final double value;

  @override
  double wallSeconds() => value;

  @override
  double monotonicSeconds() => value;
}

final class FixedRandom implements RandomSource {
  const FixedRandom(this.value);

  final double value;

  @override
  double nextUnit() => value;
}

/// Test-side interpretation of the Python retry rule; A3 replaces this with
/// the Dart model client's implementation and retains the same fixture.
double? retryAfter(
  String? header,
  int attempt,
  double cap,
  ClockSource clock,
  RandomSource random,
) {
  double? hint;
  if (header != null) {
    hint = double.tryParse(header);
    if (hint == null) {
      hint =
          HttpDate.parse(header).millisecondsSinceEpoch / 1000 -
          clock.wallSeconds();
    }
    hint = math.max(0, hint);
  }
  if (hint != null && hint > cap) return null;
  if (hint != null) return hint + random.nextUnit();
  return math.min(8, 0.5 * math.pow(2, attempt)) + random.nextUnit();
}

void main() {
  test('Python retry timing uses injected clock and random source', () {
    int count = 0;
    for (final String line
        in File('../oracle/semantics/determinism.jsonl').readAsLinesSync()) {
      final Map<String, Object?> item =
          jsonDecode(line) as Map<String, Object?>;
      final double? actual = retryAfter(
        item['header'] as String?,
        item['attempt']! as int,
        item['cap']! as double,
        FixedClock((item['now']! as num).toDouble()),
        FixedRandom(item['jitter']! as double),
      );
      expect(actual, item['expected'], reason: item['id']! as String);
      count++;
    }
    expect(count, 4);
  });

  test(
    'Future.wait publishes in input order when completion is reversed',
    () async {
      final List<Future<int>> pending = <Future<int>>[
        Future<int>.delayed(const Duration(milliseconds: 2), () => 0),
        Future<int>.delayed(const Duration(milliseconds: 1), () => 1),
        Future<int>.value(2),
      ];
      expect(await Future.wait(pending), <int>[0, 1, 2]);
    },
  );
}
