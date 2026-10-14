import 'dart:io';

import 'library.dart';

/// Worker-owned evidence: this file never depends on the UI isolate or a frame.
/// Timings are observation times, not proof of an Android freezer decision.
final class ProcessingWorkerHeartbeat {
  ProcessingWorkerHeartbeat(
    this.book, {
    int Function()? nowMs,
    int Function()? elapsedMs,
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch),
       _elapsedMs = elapsedMs ?? _clock();

  final Directory book;
  final int Function() _nowMs;
  final int Function() _elapsedMs;
  final List<Map<String, Object?>> _samples = <Map<String, Object?>>[];
  int? _previous;
  int _sequence = 0;

  static int Function() _clock() {
    final Stopwatch clock = Stopwatch()..start();
    return () => clock.elapsedMilliseconds;
  }

  Map<String, Object?> record({bool finished = false}) {
    final int elapsed = _elapsedMs();
    final Map<String, Object?> sample = <String, Object?>{
      'pid': pid,
      'sequence': ++_sequence,
      'at_ms': _nowMs(),
      'elapsed_ms': elapsed,
      'gap_ms': _previous == null ? 0 : elapsed - _previous!,
      'finished': finished,
    };
    _previous = elapsed;
    _samples.add(sample);
    if (_samples.length > 64) _samples.removeAt(0);
    try {
      writeJson(
        File('${book.path}/work/worker-heartbeat.json'),
        <String, Object?>{'samples': _samples},
      );
    } on Object {
      // Diagnostics must not fail, pause, resume, or replay model work.
    }
    return sample;
  }
}
