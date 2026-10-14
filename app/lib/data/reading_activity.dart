import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'reading_activity_storage.dart';

String readingDayKey(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

/// Device-local elapsed reading time. Every root has one writer, even when two
/// readers are open. An overlapping second reader never doubles elapsed time.
class ReadingActivityStore extends ChangeNotifier {
  ReadingActivityStore._(this._storage, this._clock, this._useTimer) {
    try {
      final String? raw = _storage?.read();
      if (raw != null) {
        final Map<String, dynamic> data =
            jsonDecode(raw) as Map<String, dynamic>;
        _goalMinutes = ((data['goalMinutes'] as num?)?.toInt() ?? 20).clamp(
          5,
          120,
        );
        final Map<String, dynamic> days =
            (data['days'] as Map<String, dynamic>?) ?? <String, dynamic>{};
        for (final entry in days.entries) {
          final Map<String, dynamic> books =
              entry.value as Map<String, dynamic>;
          _days[entry.key] = <String, double>{
            for (final book in books.entries)
              if (book.value is num &&
                  (book.value as num).isFinite &&
                  (book.value as num) >= 0)
                book.key: (book.value as num).toDouble(),
          };
        }
        final Map<String, dynamic> titles =
            (data['titles'] as Map<String, dynamic>?) ?? <String, dynamic>{};
        _titles.addAll(titles.map((key, value) => MapEntry(key, '$value')));
      }
    } on Object {
      _writeBlocked = true;
      error = '暂时无法读取阅读记录，原记录已保留。';
    }
    _lastTick = _clock();
  }

  factory ReadingActivityStore.forRoot(String rootKey) => _stores.putIfAbsent(
    rootKey,
    () => ReadingActivityStore._(
      ReadingActivityStorage(rootKey),
      DateTime.now,
      true,
    ),
  );

  @visibleForTesting
  factory ReadingActivityStore.memory({DateTime Function()? clock}) =>
      ReadingActivityStore._(null, clock ?? DateTime.now, false);

  static final Map<String, ReadingActivityStore> _stores =
      <String, ReadingActivityStore>{};
  final ReadingActivityStorage? _storage;
  final DateTime Function() _clock;
  final bool _useTimer;
  final Map<String, Map<String, double>> _days =
      <String, Map<String, double>>{};
  final Map<String, String> _titles = <String, String>{};
  final Set<ReadingActivitySession> _sessions = <ReadingActivitySession>{};
  late DateTime _lastTick;
  Timer? _timer;
  bool _writeBlocked = false;
  int _goalMinutes = 20;
  String? error;

  int get goalMinutes => _goalMinutes;
  DateTime get today => _clock();
  int secondsOn(DateTime day) =>
      (_days[readingDayKey(day)]?.values.fold<double>(
                0,
                (sum, seconds) => sum + seconds,
              ) ??
              0)
          .floor();
  int get todaySeconds => secondsOn(today);
  int get totalSeconds => _days.values
      .fold<double>(
        0,
        (sum, books) =>
            sum + books.values.fold<double>(0, (sum, seconds) => sum + seconds),
      )
      .floor();
  Map<String, int> get bookSeconds {
    final Map<String, double> result = <String, double>{};
    for (final books in _days.values) {
      for (final entry in books.entries) {
        result[entry.key] = (result[entry.key] ?? 0) + entry.value;
      }
    }
    return result.map((key, value) => MapEntry(key, value.floor()));
  }

  String titleOf(String id) => _titles[id] ?? '未命名书籍';

  /// A reading day has at least one real recorded minute. Before today's first
  /// minute, yesterday can remain the end of the current streak.
  int get streakDays {
    DateTime day = DateTime(today.year, today.month, today.day);
    if (secondsOn(day) < 60) day = DateTime(day.year, day.month, day.day - 1);
    int count = 0;
    while (secondsOn(day) >= 60) {
      count++;
      day = DateTime(day.year, day.month, day.day - 1);
    }
    return count;
  }

  ReadingActivitySession startSession({
    required String bookId,
    required String title,
  }) {
    flush();
    _titles[bookId] = title;
    final ReadingActivitySession session = ReadingActivitySession._(
      this,
      bookId,
      _clock(),
    );
    _sessions.add(session);
    if (_useTimer) {
      _timer ??= Timer.periodic(const Duration(seconds: 10), (_) => flush());
    }
    return session;
  }

  void setGoalMinutes(int minutes) {
    _goalMinutes = minutes.clamp(5, 120);
    _persist();
    notifyListeners();
  }

  void flush() {
    final DateTime now = _clock();
    if (now.isBefore(_lastTick)) {
      _lastTick = now;
      return;
    }
    ReadingActivitySession? owner;
    for (final session in _sessions) {
      if (session._active &&
          (owner == null || session._touched.isAfter(owner._touched))) {
        owner = session;
      }
    }
    bool changed = false;
    if (owner != null) {
      final DateTime idleAt = owner._touched.add(const Duration(seconds: 90));
      final DateTime until = now.isBefore(idleAt) ? now : idleAt;
      DateTime cursor = _lastTick;
      while (cursor.isBefore(until)) {
        final DateTime midnight = DateTime(
          cursor.year,
          cursor.month,
          cursor.day + 1,
        );
        final DateTime end = until.isBefore(midnight) ? until : midnight;
        final double seconds =
            end.difference(cursor).inMicroseconds /
            Duration.microsecondsPerSecond;
        final Map<String, double> books = _days.putIfAbsent(
          readingDayKey(cursor),
          () => <String, double>{},
        );
        books[owner.bookId] = (books[owner.bookId] ?? 0) + seconds;
        cursor = end;
        changed = true;
      }
    }
    _lastTick = now;
    if (changed) {
      _persist();
      notifyListeners();
    }
  }

  void _persist() {
    if (_writeBlocked) return;
    try {
      _storage?.write(
        jsonEncode(<String, Object?>{
          'version': 1,
          'goalMinutes': _goalMinutes,
          'days': _days,
          'titles': _titles,
        }),
      );
      error = null;
    } on Object {
      error = '阅读记录暂未保存，请检查设备存储空间。';
    }
  }

  void _close(ReadingActivitySession session) {
    flush();
    _sessions.remove(session);
    if (_sessions.isEmpty) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    flush();
    _timer?.cancel();
    _sessions.clear();
    _stores.removeWhere((_, value) => identical(value, this));
    super.dispose();
  }
}

class ReadingActivitySession {
  ReadingActivitySession._(this._store, this.bookId, this._touched);
  final ReadingActivityStore _store;
  final String bookId;
  DateTime _touched;
  bool _active = true;
  bool _closed = false;
  void touch() {
    if (_closed) return;
    _store.flush();
    _touched = _store._clock();
  }

  void setActive(bool active) {
    if (_closed || active == _active) return;
    _store.flush();
    _active = active;
    if (active) _touched = _store._clock();
  }

  void dispose() {
    if (_closed) return;
    _store._close(this);
    _closed = true;
  }
}
