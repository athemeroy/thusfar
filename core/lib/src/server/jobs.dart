/// Serialized book worker (`server/jobs.py`) for the native Dart application.
///
/// Existing meta/status and quality-retry files remain authoritative. The
/// additional worker receipt records ownership transitions, never model secrets.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../async_util.dart';
import '../env.dart';
import '../errors.dart';
import '../pipeline/jev.dart' as jev;
import '../pipeline/run.dart' as pipeline;
import '../pipeline/run_lease.dart';
import '../py/py_compat.dart';
import 'storage.dart';

export '../pipeline/run_lease.dart'
    show RunCancellation, Cancelled, AlreadyRunning, RunLease, isBookRunning;

typedef Json = Map<String, Object?>;
typedef WorkerRun =
    Future<void> Function(
      Directory root, {
      required RunCancellation cancellation,
      required bool retryQuality,
      required String model,
      required String localModel,
      required int concurrency,
    });

final class BusyBook extends RuntimeError {
  const BusyBook() : super('这本书正在由另一个任务处理，请先停止该任务');
}

/// Execute while owning the same kernel lease used by Python's book_lease.
Future<T> bookLease<T>(Directory root, FutureOr<T> Function() action) async {
  final RunLease lease;
  try {
    lease = await RunLease.acquire(root);
  } on AlreadyRunning {
    throw const BusyBook();
  }
  try {
    return await action();
  } finally {
    lease.release();
  }
}

/// Resolved immediately before each job; UI settings stay outside this module.
class WorkerSettings {
  const WorkerSettings({
    this.model = 'deepseek-flash+nothink',
    this.localModel = 'deepseek-flash+nothink',
    this.concurrency = 4,
  });

  factory WorkerSettings.environment() => WorkerSettings(
    model: environ['EXTRACT_MODEL'] ?? 'deepseek-flash+nothink',
    localModel: environ['LOCAL_MODEL'] ?? 'deepseek-flash+nothink',
    concurrency: int.parse(environ['LOCAL_CONCURRENCY'] ?? '4'),
  );

  final String model;
  final String localModel;
  final int concurrency;
}

Future<void> _run(
  Directory root, {
  required RunCancellation cancellation,
  required bool retryQuality,
  required String model,
  required String localModel,
  required int concurrency,
}) async {
  await pipeline.runBook(
    root,
    cancellation: cancellation,
    retryQuality: retryQuality,
    model: model,
    localModel: localModel,
    concurrency: concurrency,
  );
}

Json? _readJson(File file) {
  if (!file.existsSync()) return null;
  final Object? value = jsonDecode(file.readAsStringSync());
  if (value is! Json) throw const ValueError('任务状态文件格式无效');
  return value;
}

double _now() => DateTime.now().millisecondsSinceEpoch / 1000;
bool _truth(Object? v) =>
    v != null &&
    v != false &&
    v != 0 &&
    v != '' &&
    !(v is Iterable<Object?> && v.isEmpty) &&
    !(v is Map<Object?, Object?> && v.isEmpty);
Json _object(Object? v) => v as Json? ?? <String, Object?>{};
String _name(Directory root) =>
    root.uri.pathSegments.where((String s) => s.isNotEmpty).last;
String _short(Object error) => PyCompat.slice(error.toString(), 0, 200);
bool _same(Object? a, Object? b) {
  if (a is Map<String, Object?> && b is Map<String, Object?>) {
    return a.length == b.length &&
        a.keys.every((String k) => b.containsKey(k) && _same(a[k], b[k]));
  }
  if (a is List<Object?> && b is List<Object?>) {
    return a.length == b.length &&
        Iterable<int>.generate(a.length).every((int i) => _same(a[i], b[i]));
  }
  return a == b;
}

/// Application-owned worker. Construct and use in one isolate; start() never
/// enables automatic paid requests. The default mode only runs explicit actions.
class Worker {
  Worker(
    this.books, {
    this.enabled = false,
    WorkerRun? run,
    WorkerSettings Function()? settings,
    this.onChange,
    Json? Function(File)? read,
    void Function(File, Json)? write,
    Future<bool> Function(Directory)? probe,
    double Function()? clock,
    this.scanInterval = const Duration(seconds: 30),
  }) : _runBook = run ?? _run,
       _settings = settings ?? WorkerSettings.environment,
       _read = read ?? _readJson,
       _write = write ?? writeJson,
       _probe = probe ?? isBookRunning,
       _clock = clock ?? _now;

  final Directory books;
  final bool enabled;
  final void Function(Json)? onChange;
  final Duration scanInterval;
  final WorkerRun _runBook;
  final WorkerSettings Function() _settings;
  final Json? Function(File) _read;
  final void Function(File, Json) _write;
  final Future<bool> Function(Directory) _probe;
  final double Function() _clock;
  final LinkedHashSet<String> _queue = LinkedHashSet<String>();
  final Semaphore _processGate = Semaphore(1);
  Future<void>? _initializing;
  Future<void>? _draining;
  Completer<void>? _currentDone;
  RunCancellation? _cancellation;
  Timer? _timer;
  bool _alive = false;
  bool _stopping = false;
  bool _scanAgain = false;
  int _sequence = 0;
  String? _current;
  Json? _lastError;
  double _lastScan = 0;

  Json health() => <String, Object?>{
    'enabled': enabled,
    'alive': _alive,
    'current': _current,
    'mode': 'dart',
    'pid': null,
    'last_scan': _lastScan,
    'last_error': _lastError == null ? null : <String, Object?>{..._lastError!},
    'queued': _queue.toList()..sort(),
    'stopping': _stopping,
  };

  void _notify() {
    // A disconnected UI observer cannot terminate or relaunch the book task.
    try {
      onChange?.call(health());
    } on Object {
      /* Observer is not the worker. */
    }
  }

  File _file(Directory root, String path) => File('${root.path}/$path');
  Json _json(Directory root, String path) => <String, Object?>{
    ...?_read(_file(root, path)),
  };
  void _save(Directory root, String path, Json value) =>
      _write(_file(root, path), value);

  Future<void> _withLease(Directory root, void Function() action) async {
    await bookLease<void>(root, action);
  }

  void _checkRoot(Directory root) {
    if (!root.existsSync() ||
        !books.existsSync() ||
        root.parent.resolveSymbolicLinksSync() !=
            books.resolveSymbolicLinksSync() ||
        _name(root).startsWith('.') ||
        FileSystemEntity.typeSync(root.path, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const ValueError('书籍目录无效');
    }
  }

  List<Directory> _roots() {
    if (!books.existsSync()) return <Directory>[];
    return books
        .listSync(followLinks: false)
        .whereType<Directory>()
        .where(
          (Directory d) =>
              !_name(d).startsWith('.') && _file(d, 'meta.json').existsSync(),
        )
        .toList()
      ..sort(
        (Directory a, Directory b) => PyCompat.compare(_name(a), _name(b)),
      );
  }

  /// Initialize and reconcile interrupted work without inferring new permission.
  Future<void> start() {
    if (_stopping) throw const RuntimeError('处理器已停止，请重新打开书库');
    return _initializing ??= _start();
  }

  Future<void> _start() async {
    await reconcile();
    if (_stopping) return;
    _alive = true;
    if (enabled) _timer = Timer.periodic(scanInterval, (_) => _wake());
    _notify();
    if (enabled || _queue.isNotEmpty) _wake();
  }

  /// Reconcile stale UI state only after proving that no live lease owns it.
  /// A completed book's pending quality marker never creates a retry request.
  Future<void> reconcile() async {
    for (final Directory root in _roots()) {
      if (_current == _name(root)) continue;
      try {
        Json state = _json(root, 'status.json');
        if (!<String>{
          'queued',
          'running',
          'finalizing',
          'cancelling',
        }.contains(state['state']))
          continue;
        if (await _probe(root)) continue;
        await _withLease(root, () {
          state = _json(root, 'status.json');
          if (!<String>{
            'queued',
            'running',
            'finalizing',
            'cancelling',
          }.contains(state['state']))
            return;
          final Json meta = _json(root, 'meta.json');
          final String next =
              enabled && _truth(meta['auto']) ? 'queued' : 'paused';
          state.addAll(<String, Object?>{
            'state': next,
            'updated': _clock(),
            'error': null,
          });
          _save(root, 'status.json', state);
          _receipt(root, <String, Object?>{
            'phase': next,
            'reason': 'reconciled',
            'owner_pid': null,
          });
        });
      } on BusyBook {
        continue;
      } on Object catch (error) {
        _lastError = <String, Object?>{
          'book': _name(root),
          'message': _short(error),
          'at': _clock(),
        };
      }
    }
    _notify();
  }

  Future<void> startBook(Directory root) async {
    await start();
    await setAuto(root, true);
  }

  Future<void> resumeBook(Directory root) => startBook(root);

  /// Preserve Python's explicit quality-retry acknowledgement protocol.
  Future<void> setAuto(Directory root, bool value) async {
    _checkRoot(root);
    if (value && _stopping) throw const RuntimeError('处理器已停止，请重新打开书库');
    if (value &&
        _current == _name(root) &&
        (_cancellation?.isCancelled ?? false)) {
      throw const RuntimeError('正在暂停，请等待当前请求结束后再继续');
    }
    final Json meta = _json(root, 'meta.json');
    final Json state = _json(root, 'status.json');
    final Json quality = _object(state['quality']);
    final bool retryQuality =
        value &&
        (_truth(quality['pending']) || quality['state'] == 'pending') &&
        !<String>{
          'running',
          'finalizing',
          'cancelling',
        }.contains(state['state']);
    meta['auto'] = value;
    if (retryQuality) {
      meta['retry_quality'] = true;
    } else if (!value) {
      meta.remove('retry_quality');
    }
    _save(root, 'meta.json', meta);
    final bool queued =
        value &&
        (retryQuality ||
            !<String>{
              'done',
              'running',
              'finalizing',
              'cancelling',
            }.contains(state['state']));
    if (queued) {
      state.addAll(<String, Object?>{
        'state': 'queued',
        'updated': _clock(),
        'error': null,
      });
      _save(root, 'status.json', state);
      _receipt(
        root,
        <String, Object?>{
          'phase': 'queued',
          'retry_quality': retryQuality,
          'owner_pid': null,
        },
        newRequest:
            retryQuality &&
            _json(root, 'work/worker-receipt.json')['phase'] == 'done',
      );
    }
    final String id = _name(root);
    if (!value) {
      _queue.remove(id);
    } else if (_current != id && (queued || !enabled)) {
      _queue.add(id);
    }
    _notify();
    _wake();
  }

  /// Cooperative cancellation waits for the current boundary. A timeout keeps
  /// the slot and run.lock owned until the actual run Future settles.
  Future<void> pauseBook(
    Directory root, {
    Duration timeout = const Duration(seconds: 15),
    bool preserveAuto = false,
  }) async {
    _checkRoot(root);
    // Mark intent before the first await, so a rapid resume cannot flip auto
    // back on while this run is already leaving its cancellation boundary.
    if (_current == _name(root)) _cancellation?.cancel();
    if (!preserveAuto) await setAuto(root, false);
    _queue.remove(_name(root));
    final Completer<void>? active =
        _current == _name(root) ? _currentDone : null;
    if (active != null) {
      _cancellation!.cancel();
      final Json state = _json(root, 'status.json');
      state.addAll(<String, Object?>{
        'state': 'cancelling',
        'updated': _clock(),
      });
      _save(root, 'status.json', state);
      _receipt(root, <String, Object?>{'phase': 'cancelling'});
      _notify();
      try {
        await active.future.timeout(timeout);
      } on TimeoutException {
        return;
      }
    }
    // A PID/status file is not proof of ownership; never stop an external job.
    if (await _probe(root)) throw const BusyBook();
    if (!root.existsSync()) return;
    await _withLease(root, () {
      final Json state = _json(root, 'status.json');
      if (state['state'] != 'done') {
        final String next = preserveAuto ? 'queued' : 'paused';
        state.addAll(<String, Object?>{
          'state': next,
          'updated': _clock(),
          'error': null,
        });
        _save(root, 'status.json', state);
        _receipt(root, <String, Object?>{'phase': next, 'owner_pid': null});
      }
    });
    _notify();
  }

  /// Compatibility spelling for callers migrating server.jobs.cancel.
  Future<void> cancel(
    Directory root, {
    Duration timeout = const Duration(seconds: 15),
    bool preserveAuto = false,
  }) => pauseBook(root, timeout: timeout, preserveAuto: preserveAuto);

  void _wake() {
    if (!_alive || _stopping) return;
    _scanAgain = true;
    _draining ??= _drain().whenComplete(() {
      _draining = null;
      if (_scanAgain && !_stopping) _wake();
    });
  }

  Future<void> _drain() async {
    while (_scanAgain && !_stopping) {
      _scanAgain = false;
      _lastScan = _clock();
      try {
        final List<Directory> roots;
        if (enabled) {
          roots = _roots();
          _queue.clear();
        } else {
          final List<String> ids = _queue.toList()..sort(PyCompat.compare);
          _queue.clear();
          roots = <Directory>[
            for (final String id in ids) Directory('${books.path}/$id'),
          ];
        }
        for (final Directory root in roots) {
          if (_stopping) break;
          try {
            await processBook(root);
          } on Object catch (error) {
            _lastError = <String, Object?>{
              'book': _name(root),
              'message': _short(error),
              'at': _clock(),
            };
            if (root.existsSync()) {
              try {
                final Json state = _json(root, 'status.json');
                state.addAll(<String, Object?>{
                  'state': 'error',
                  'error': '后台处理失败，请查看服务日志',
                  'updated': _clock(),
                });
                _save(root, 'status.json', state);
                _receipt(root, <String, Object?>{
                  'phase': 'error',
                  'owner_pid': null,
                  'error': state['error'],
                });
              } on Object {
                /* Preserve original failure in worker health. */
              }
            }
          }
          _notify();
        }
      } on Object catch (error) {
        _lastError = <String, Object?>{
          'message': _short(error),
          'at': _clock(),
        };
      }
      _notify();
    }
  }

  bool _eligible(Directory root, Json meta, Json state) =>
      _file(root, 'book.json').existsSync() &&
      _truth(meta['auto']) &&
      !(state['state'] == 'done' && !_truth(meta['retry_quality'])) &&
      !(state['state'] == 'error' &&
          _clock() - ((state['updated'] as num?) ?? 0) < 1800);

  /// One serialized attempt, also useful for deterministic offline executors.
  /// This does not grant permission: meta.auto must already be explicit/true.
  Future<void> processBook(Directory root) => _processGate.run(() async {
    if (_stopping || !root.existsSync()) return;
    _checkRoot(root);
    Json meta = _json(root, 'meta.json'), state = _json(root, 'status.json');
    if (!_eligible(root, meta, state) || await _probe(root)) return;
    meta = _json(root, 'meta.json');
    state = _json(root, 'status.json');
    if (_stopping || !_eligible(root, meta, state)) return;
    final bool retryQuality = _truth(meta['retry_quality']);
    final Json? retryBefore =
        retryQuality ? _read(_file(root, 'work/quality-retry.json')) : null;
    final WorkerSettings settings = _settings();
    if (settings.concurrency < 1) throw const ValueError('并发数量必须大于零');
    final RunCancellation cancellation = RunCancellation();
    _current = _name(root);
    _cancellation = cancellation;
    _currentDone = Completer<void>();
    final String? previousJudgeDirectory = environ['JUDGE_LOG_DIR'];
    int code = 1;
    try {
      // A native worker runs several books in one isolate. Give each attempt
      // the cache location and fresh process counters of the original worker.
      environ['JUDGE_LOG_DIR'] = '${root.path}/work/judge';
      jev.resetJevStats();
      final Json prior = _json(root, 'work/worker-receipt.json');
      _receipt(root, <String, Object?>{
        'phase': 'running',
        'owner_pid': pid,
        'attempt': ((prior['attempt'] as int?) ?? 0) + 1,
        'model': settings.model,
        'local_model': settings.localModel,
        'concurrency': settings.concurrency,
        'retry_quality': retryQuality,
      });
      _notify();
      try {
        await _runBook(
          root,
          cancellation: cancellation,
          retryQuality: retryQuality,
          model: settings.model,
          localModel: settings.localModel,
          concurrency: settings.concurrency,
        );
        code = 0;
      } on Cancelled {
        code = 75;
      } on AlreadyRunning {
        code = 75;
      } on Object catch (error) {
        code = 1;
        _lastError = <String, Object?>{
          'book': _name(root),
          'message': _short(error),
          'at': _clock(),
        };
      }
      if (!root.existsSync()) return;
      state = _json(root, 'status.json');
      meta = _json(root, 'meta.json');
      final bool auto = _truth(meta['auto']);
      if (retryQuality && code != 75) {
        final Json retryAfter = _json(root, 'work/quality-retry.json');
        final bool acknowledged =
            <String>{'rebuilding', 'complete'}.contains(retryAfter['state']) &&
            (!_same(retryAfter, retryBefore) ||
                retryBefore?['state'] == 'rebuilding');
        if (acknowledged) {
          meta.remove('retry_quality');
          _save(root, 'meta.json', meta);
        }
      }
      if (auto && _stopping && code != 0) {
        state.addAll(<String, Object?>{
          'state': 'queued',
          'updated': _clock(),
          'error': null,
        });
        _save(root, 'status.json', state);
      } else if (!auto) {
        if (state['state'] != 'done') {
          state.addAll(<String, Object?>{
            'state': 'paused',
            'updated': _clock(),
            'error': null,
          });
          _save(root, 'status.json', state);
        }
      } else if (code != 75 && (code != 0 || state['state'] != 'done')) {
        state.addAll(<String, Object?>{
          'state': 'error',
          'updated': _clock(),
          'error':
              _truth(state['error']) ? state['error'] : '处理进程未完成（退出码 $code）',
        });
        _save(root, 'status.json', state);
        _lastError = <String, Object?>{
          'book': _name(root),
          'message': state['error'],
          'at': _clock(),
        };
      }
      _receipt(root, <String, Object?>{
        'phase': state['state'] ?? (code == 75 ? 'interrupted' : 'error'),
        'exit_code': code,
        'owner_pid': null,
        'finished_at': _clock(),
      });
    } finally {
      if (previousJudgeDirectory == null) {
        environ.remove('JUDGE_LOG_DIR');
      } else {
        environ['JUDGE_LOG_DIR'] = previousJudgeDirectory;
      }
      _current = null;
      _cancellation = null;
      _currentDone!.complete();
      _currentDone = null;
      if (_stopping) _alive = false;
      _notify();
    }
  });

  void _receipt(Directory root, Json fields, {bool newRequest = false}) {
    final Json previous =
        newRequest
            ? <String, Object?>{}
            : _json(root, 'work/worker-receipt.json');
    final double now = _clock();
    _save(root, 'work/worker-receipt.json', <String, Object?>{
      'schema': 1,
      'book': _name(root),
      'request_id': '${(now * 1000000).round()}-$pid-${++_sequence}',
      'requested_at': now,
      'attempt': 0,
      ...previous,
      ...fields,
      'updated': now,
    });
  }

  /// Stop accepting work and preserve automatic intent for an explicit restart.
  /// No model Future is abandoned and no guessed process identifier is killed.
  void stop() {
    _stopping = true;
    _timer?.cancel();
    _timer = null;
    _cancellation?.cancel();
    _queue.clear();
    if (_current == null) _alive = false;
    _notify();
  }

  Future<void> waitIdle() async {
    while (_draining != null || _currentDone != null) {
      await (_draining ?? _currentDone!.future);
    }
  }

  /// For callers that need actual settlement after pauseBook before removal.
  Future<void> waitBookIdle(Directory root) async {
    while (_current == _name(root) && _currentDone != null) {
      await _currentDone!.future;
    }
    if (await _probe(root)) throw const BusyBook();
  }

  /// A timed-out close keeps health.current/lease truthful until run settles.
  Future<void> close({Duration timeout = const Duration(seconds: 15)}) async {
    stop();
    try {
      await waitIdle().timeout(timeout);
    } on TimeoutException {
      /* Still cancelling. */
    }
  }
}
