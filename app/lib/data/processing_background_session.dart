import 'dart:async';

import 'library.dart';
import 'processing_notification_bridge.dart';

Duration Function() _monotonicClock() {
  final Stopwatch clock = Stopwatch()..start();
  return () => clock.elapsed;
}

/// The worker/controller owns this session, never a screen or Activity.
/// A finite native CPU lease is renewed only while this Dart owner is alive.
class ProcessingBackgroundSession {
  ProcessingBackgroundSession({
    Future<bool> Function(BookEntry book, String phase)? start,
    Future<bool> Function(BookEntry book, String phase)? update,
    Future<void> Function(String id)? stop,
    required this.onUnavailable,
    this.heartbeatInterval = const Duration(seconds: 30),
    Duration Function()? elapsed,
  }) : _elapsed = elapsed ?? _monotonicClock(),
       _start = start ?? _startNative,
       _update = update ?? _updateNative,
       _stop = stop ?? ProcessingNotificationBridge.stop;

  final Future<bool> Function(BookEntry, String) _start;
  final Future<bool> Function(BookEntry, String) _update;
  final Future<void> Function(String) _stop;
  final Future<void> Function(String id) onUnavailable;
  final Duration heartbeatInterval;
  final Map<String, BookEntry> _books = <String, BookEntry>{};
  final Map<String, String> _stamps = <String, String>{};
  final Map<String, Duration> _updatedAt = <String, Duration>{};
  final Map<String, Object> _leases = <String, Object>{};
  final Map<String, Object> _starts = <String, Object>{};
  Timer? _heartbeat;
  bool _updating = false;
  bool _hasWork = false;
  String? _current;
  bool _closed = false;
  final Duration Function() _elapsed;
  Duration? _lastWorkerHeartbeat;
  Duration? _lastRefresh;
  Duration? _resumeGraceUntil;

  void workerHeartbeat() => _lastWorkerHeartbeat = _elapsed();

  static Future<bool> _startNative(BookEntry book, String phase) =>
      ProcessingNotificationBridge.start(
        bookId: book.id,
        title: book.title,
        phase: phase,
        done: book.status.done,
        total: book.status.total,
      );

  static Future<bool> _updateNative(BookEntry book, String phase) =>
      ProcessingNotificationBridge.update(
        bookId: book.id,
        title: book.title,
        phase: phase,
        done: book.status.done,
        total: book.status.total,
      );

  Future<void> acquire(BookEntry book) async {
    if (_closed) throw StateError('整理任务正在停止');
    final Object attempt = Object();
    _starts[book.id] = attempt;
    try {
      // Success means startForeground completed; the bool only describes
      // notification-drawer visibility, which does not gate execution.
      await _start(book, 'preparing');
      if (_closed || !identical(_starts[book.id], attempt)) {
        // A cancelled/superseded attempt no longer owns this book. Its stop
        // was issued by stopBook; never stop a newer admission here.
        throw StateError('整理任务已停止');
      }
      _books[book.id] = book;
      _leases[book.id] = attempt;
      workerHeartbeat();
      _lastRefresh = _elapsed();
      _resumeGraceUntil = null;
      _current = book.id;
      _hasWork = true;
      _heartbeat ??= Timer.periodic(
        heartbeatInterval,
        (_) => unawaited(refresh()),
      );
      // Keep the old foreground service until the next book has acquired it.
      for (final String old in _books.keys.toList()) {
        if (old != book.id) await stopBook(old);
      }
    } on Object {
      if (identical(_starts[book.id], attempt)) {
        _books.remove(book.id);
        _leases.remove(book.id);
        await _stop(book.id);
      }
      rethrow;
    } finally {
      if (identical(_starts[book.id], attempt)) _starts.remove(book.id);
    }
  }

  /// Queue transitions keep one foreground service alive. It holds no CPU
  /// lease while queued and is removed as soon as the whole worker is idle.
  void synchronize(Map<String, Object?> health) {
    _current = health['current'] as String?;
    _hasWork =
        health['alive'] == true &&
        (_current != null ||
            ((health['queued'] as List<Object?>?) ?? const []).isNotEmpty);
    if (!_hasWork) {
      unawaited(stopAll());
    }
  }

  Future<void> refresh() async {
    if (_updating || _closed) return;
    _updating = true;
    try {
      final Duration now = _elapsed();
      final Duration? previousRefresh = _lastRefresh;
      _lastRefresh = now;
      if (previousRefresh != null &&
          now - previousRefresh > const Duration(seconds: 60)) {
        // If this observer was suspended too, queued worker messages need one
        // interval to arrive. This is not a worker heartbeat or a CPU renewal.
        _resumeGraceUntil = now + heartbeatInterval;
      }
      final Duration? last = _lastWorkerHeartbeat;
      // A live UI is not evidence of a live worker. Release native protection
      // before asking an unresponsive worker to settle its durable state.
      if (last == null || now - last > const Duration(seconds: 60)) {
        if (last != null &&
            _resumeGraceUntil != null &&
            now < _resumeGraceUntil!) {
          return;
        }
        for (final MapEntry<String, Object> stale in _leases.entries.toList()) {
          if (identical(_leases[stale.key], stale.value)) {
            await _unavailable(stale.key);
          }
        }
        return;
      }
      _resumeGraceUntil = null;
      for (final BookEntry book in _books.values.toList()) {
        final Object? lease = _leases[book.id];
        if (lease == null) continue;
        final String phase = !_hasWork || book.id != _current
            ? 'queued'
            : book.status.state == 'finalizing'
            ? 'finalizing'
            : (book.status.notice ?? '').contains('等待')
            ? 'waiting'
            : 'running';
        final String stamp =
            '$phase/${book.status.done}/${book.status.total}/${book.title}';
        final Duration? updated = _updatedAt[book.id];
        if (_stamps[book.id] == stamp &&
            updated != null &&
            _elapsed() - updated < heartbeatInterval) {
          continue;
        }
        try {
          final bool present = await _update(book, phase);
          if (!identical(_leases[book.id], lease)) continue;
          if (!present) {
            await _unavailable(book.id);
          } else {
            _stamps[book.id] = stamp;
            _updatedAt[book.id] = _elapsed();
          }
        } on Object {
          if (identical(_leases[book.id], lease)) await _unavailable(book.id);
        }
      }
    } finally {
      _updating = false;
    }
  }

  Future<void> _unavailable(String id) async {
    try {
      await stopBook(id);
    } on Object {
      /* The native service is already unavailable. */
    }
    if (_starts.containsKey(id) || _leases.containsKey(id)) return;
    try {
      await onUnavailable(id);
    } on Object {
      /* Worker exit also reconciles durable state. */
    }
  }

  Future<void> stopBook(String id) async {
    _starts.remove(id);
    _books.remove(id);
    _leases.remove(id);
    _stamps.remove(id);
    _updatedAt.remove(id);
    if (_books.isEmpty) {
      _heartbeat?.cancel();
      _heartbeat = null;
    }
    await _stop(id);
  }

  Future<void> stopAll() async {
    final Map<String, Object> owners = <String, Object>{..._leases, ..._starts};
    for (final MapEntry<String, Object> owner in owners.entries) {
      final String id = owner.key;
      if (!identical(_leases[id], owner.value) &&
          !identical(_starts[id], owner.value)) {
        continue;
      }
      try {
        await stopBook(id);
      } on Object {
        /* Continue releasing other tasks. */
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    _heartbeat?.cancel();
    _heartbeat = null;
    await stopAll();
  }
}
