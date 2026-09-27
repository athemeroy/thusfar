/// Small concurrency tools standing in for Python's threading primitives.
library;

import 'dart:async';
import 'dart:collection';

/// `threading.Semaphore`/`Lock` for async code, FIFO fair.
final class Semaphore {
  Semaphore(this._permits);

  int _permits;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<void> acquire() {
    if (_permits > 0) {
      _permits--;
      return Future<void>.value();
    }
    final Completer<void> c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  bool tryAcquire() {
    if (_permits > 0) {
      _permits--;
      return true;
    }
    return false;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    } else {
      _permits++;
    }
  }

  Future<T> run<T>(Future<T> Function() body) async {
    await acquire();
    try {
      return await body();
    } finally {
      release();
    }
  }
}
