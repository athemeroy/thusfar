/// Durable book leases shared by Python, Dart processes and worker isolates.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

final class Cancelled implements Exception {
  const Cancelled();
  @override
  String toString() => 'Cancelled';
}

final class AlreadyRunning implements Exception {
  const AlreadyRunning(this.message);
  final String message;
  @override
  String toString() => message;
}

final class RunCancellation {
  final Completer<void> _signal = Completer<void>();
  bool get isCancelled => _signal.isCompleted;
  Future<void> get whenCancelled => _signal.future;
  void cancel() {
    if (!isCancelled) _signal.complete();
  }

  void checkpoint() {
    if (isCancelled) throw const Cancelled();
  }

  void check() => checkpoint();
  Future<T> wait<T>(Future<T> operation) async {
    checkpoint();
    return Future.any([
      operation,
      whenCancelled.then<T>((_) => throw const Cancelled()),
    ]);
  }
}

typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _Malloc = Pointer<Void> Function(int);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _Free = void Function(Pointer<Void>);
typedef _OpenNative = Int32 Function(Pointer<Uint8>, Int32);
typedef _Open = int Function(Pointer<Uint8>, int);
typedef _FlockNative = Int32 Function(Int32, Int32);
typedef _Flock = int Function(int, int);
typedef _CloseNative = Int32 Function(Int32);
typedef _Close = int Function(int);

final class _PosixLocks {
  _PosixLocks()
    : libc = DynamicLibrary.open(
        Platform.isAndroid
            ? 'libc.so'
            : Platform.isMacOS || Platform.isIOS
            ? '/usr/lib/libSystem.B.dylib'
            : 'libc.so.6',
      );
  final DynamicLibrary libc;
  late final _Malloc malloc = libc.lookupFunction<_MallocNative, _Malloc>(
    'malloc',
  );
  late final _Free free = libc.lookupFunction<_FreeNative, _Free>('free');
  late final _Open open = libc.lookupFunction<_OpenNative, _Open>('open');
  late final _Flock flock = libc.lookupFunction<_FlockNative, _Flock>('flock');
  late final _Close close = libc.lookupFunction<_CloseNative, _Close>('close');
  int openPath(String path) {
    final List<int> bytes = utf8.encode(path);
    final Pointer<Uint8> buffer = malloc(bytes.length + 1).cast<Uint8>();
    if (buffer == nullptr) throw StateError('Could not allocate lock path');
    try {
      buffer.asTypedList(bytes.length + 1).setAll(0, [...bytes, 0]);
      return open(buffer, 2); // O_RDWR; the file is created by Dart first.
    } finally {
      free(buffer.cast<Void>());
    }
  }
}

/// POSIX uses the same flock primitive as Python 1.7, including independent
/// locks for descriptors opened in different isolates of the same process.
final class RunLease {
  RunLease._(this.path, this._fd, this._file);
  final String path;
  int? _fd;
  RandomAccessFile? _file;
  static _PosixLocks? _posix;
  static final Set<String> _windowsActive = {};

  static Future<RunLease> acquire(Directory root) async {
    final Directory work = Directory('${root.path}/work')
      ..createSync(recursive: true);
    final File file = File('${work.path}/run.lock');
    if (!file.existsSync()) file.createSync();
    final String path = file.resolveSymbolicLinksSync();
    if (!Platform.isWindows) {
      final _PosixLocks api = _posix ??= _PosixLocks();
      final int fd = api.openPath(path);
      if (fd < 0) throw FileSystemException('无法打开书籍处理锁', path);
      if (api.flock(fd, 2 | 4) != 0) {
        api.close(fd);
        throw AlreadyRunning('${root.path} is already being processed');
      }
      return RunLease._(path, fd, null);
    }
    if (!_windowsActive.add(path))
      throw AlreadyRunning('${root.path} is already being processed');
    RandomAccessFile? opened;
    try {
      opened = file.openSync(mode: FileMode.append);
      opened.lockSync(FileLock.exclusive);
      return RunLease._(path, null, opened);
    } on FileSystemException {
      opened?.closeSync();
      _windowsActive.remove(path);
      throw AlreadyRunning('${root.path} is already being processed');
    }
  }

  void release() {
    final int? fd = _fd;
    _fd = null;
    if (fd != null) {
      try {
        _posix!.flock(fd, 8);
      } finally {
        _posix!.close(fd);
      }
    }
    final RandomAccessFile? file = _file;
    _file = null;
    if (file != null) {
      try {
        file.unlockSync();
      } finally {
        file.closeSync();
        _windowsActive.remove(path);
      }
    }
  }
}

Future<bool> isBookRunning(Directory root) async {
  try {
    final RunLease lease = await RunLease.acquire(root);
    lease.release();
    return false;
  } on AlreadyRunning {
    return true;
  }
}
