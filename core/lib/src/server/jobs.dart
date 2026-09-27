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
import '../pipeline/judge_context.dart';
import '../pipeline/run.dart' as pipeline;
import '../pipeline/run_lease.dart';
import '../py/py_compat.dart';
import 'storage.dart';

export '../pipeline/run_lease.dart'
    show RunCancellation, Cancelled, AlreadyRunning, RunLease, isBookRunning;

typedef Json = Map<String, Object?>;

/// A safe, durable explanation for why a book stopped processing.
enum BookPauseReason {
  user('user'),
  backgroundTimeLimit('background_time_limit');

  const BookPauseReason(this.value);
  final String value;
}

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
final RegExp _finalJobName = RegExp(r'^(bio|recap|classic-recap|saga)-\d+$');
final RegExp _bioJobName = RegExp(r'^bio-\d+$');

bool _failedBioJob(Directory root, Json quality, {bool contentOnly = false}) {
  final Object? pending = quality['pending'];
  if (pending is! List) return false;
  for (final Object? item in pending) {
    if (item is! String || !_bioJobName.hasMatch(item)) continue;
    final Json? job = _readJson(File('${root.path}/work/jobs/$item.json'));
    if (job?['state'] == 'failed' &&
        (!contentOnly || job?['failure_kind'] == 'bio_content'))
      return true;
  }
  return false;
}

bool _resumeBioFinalJobsInPlace(Directory root, Json quality) {
  final Object? pending = quality['pending'];
  if (pending is! List || pending.isEmpty || !_failedBioJob(root, quality))
    return false;
  for (final Object? item in pending) {
    // Two-phase runs retry title classification before replaying final jobs.
    // A pending title check does not require archiving verified biographies.
    if (item == 'chapter-titles') continue;
    if (item is! String ||
        !_finalJobName.hasMatch(item) ||
        !File('${root.path}/work/jobs/$item.json').existsSync())
      return false;
  }
  return true;
}

bool _retryOnlyTitlesInPlace(Json quality) {
  final Object? pending = quality['pending'];
  return pending is List &&
      pending.isNotEmpty &&
      pending.every((Object? item) => item == 'chapter-titles');
}

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

/// Application-owned worker. Construct and use in one isolate. An explicit
/// client may opt into recovering work it previously authorized on startup.
class Worker {
  Worker(
    this.books, {
    this.enabled = false,
    this.resumeInterrupted = false,
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
  final bool resumeInterrupted;
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
  Timer? _retryTimer;
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
    _scheduleRetryWake();
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
        String? reconciled;
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
          final bool manualPause =
              state['pause_reason'] == BookPauseReason.user.value;
          final String next =
              (enabled || resumeInterrupted) &&
                      _truth(meta['auto']) &&
                      !manualPause
                  ? 'queued'
                  : 'paused';
          if (manualPause && _truth(meta['auto'])) {
            // A crash between writing the user's pause cause and disabling
            // auto must never turn that explicit stop into an auto resume.
            meta['auto'] = false;
            _save(root, 'meta.json', meta);
          }
          reconciled = next;
          state.addAll(<String, Object?>{
            'state': next,
            'updated': _clock(),
            'error': null,
          });
          if (next == 'queued') {
            state.remove('pause_reason');
          } else {
            state['pause_reason'] ??= 'interrupted';
          }
          _save(root, 'status.json', state);
          _receipt(root, <String, Object?>{
            'phase': next,
            'reason': next == 'queued' ? 'recovered' : 'reconciled',
            'owner_pid': null,
          });
        });
        if (reconciled == 'queued' && !enabled) _queue.add(_name(root));
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
    if (_alive && _queue.isNotEmpty) _wake();
  }

  Future<void> startBook(Directory root) async {
    await start();
    await setAuto(root, true);
  }

  Future<void> resumeBook(Directory root) => startBook(root);

  /// Preserve Python's explicit quality-retry acknowledgement protocol.
  Future<void> setAuto(
    Directory root,
    bool value, {
    bool preserveQualityRetry = false,
  }) async {
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
    final bool resumeFinalJobs = _resumeBioFinalJobsInPlace(root, quality);
    final bool retryOnlyTitles = _retryOnlyTitlesInPlace(quality);
    final bool resumeInPlace = resumeFinalJobs || retryOnlyTitles;
    final Object? pendingQuality = quality['pending'];
    final bool criticalRepair =
        (pendingQuality is List &&
            pendingQuality.contains('quarantined-critical-checks')) ||
        _truth(_json(root, 'work/repair-policy.json')['identity_taint']);
    // A transient failure continues the same run from its cached frontier.
    // Preserve its retry count when the user asks to try immediately.
    final bool continuingTransientFailure =
        value &&
        !criticalRepair &&
        state['retryable'] == true &&
        <String>{'error', 'paused'}.contains(state['state']);
    final bool retryQuality =
        value &&
        (state['state'] == 'done' ||
            (criticalRepair &&
                <String>{'error', 'paused'}.contains(state['state']))) &&
        (criticalRepair ||
            (!resumeInPlace &&
                (_truth(quality['pending']) || quality['state'] == 'pending')));
    final bool preserveQualityTransaction =
        !value &&
        preserveQualityRetry &&
        _truth(meta['retry_quality']) &&
        state['state'] != 'done' &&
        <String>{
          'queued',
          'running',
          'finalizing',
          'cancelling',
          'paused',
          'error',
        }.contains(state['state']);
    meta['auto'] = value;
    if (retryQuality) {
      meta['retry_quality'] = true;
    } else if ((!value && !preserveQualityTransaction) ||
        (resumeInPlace && state['state'] == 'done')) {
      meta.remove('retry_quality');
    }
    _save(root, 'meta.json', meta);
    final bool queued =
        value &&
        (retryQuality ||
            (retryOnlyTitles && state['state'] == 'done') ||
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
      state
        ..remove('pause_reason')
        ..remove('retryable')
        ..remove('retry_at');
      if (!continuingTransientFailure) state.remove('retry_count');
      _save(root, 'status.json', state);
      _receipt(
        root,
        <String, Object?>{
          'phase': 'queued',
          'retry_quality': _truth(meta['retry_quality']),
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
    _scheduleRetryWake();
    _wake();
  }

  /// Cooperative cancellation waits for the current boundary. A timeout keeps
  /// the slot and run.lock owned until the actual run Future settles.
  Future<void> pauseBook(
    Directory root, {
    Duration timeout = const Duration(seconds: 15),
    bool preserveAuto = false,
    BookPauseReason reason = BookPauseReason.user,
  }) async {
    _checkRoot(root);
    final String id = _name(root);
    // A later Android timeout must not turn an explicit user pause into an
    // automatically resumable background-limit pause.
    if (reason == BookPauseReason.backgroundTimeLimit &&
        _json(root, 'status.json')['pause_reason'] ==
            BookPauseReason.user.value) {
      return;
    }
    if (_current != id && await _probe(root)) throw const BusyBook();
    if (_current == id && !preserveAuto) {
      // Persist the cause before signalling cancellation. The pipeline can
      // settle immediately and must see the same reason in its paused state.
      final Json state = _json(root, 'status.json');
      if (state['state'] != 'done') {
        state['pause_reason'] = reason.value;
        _save(root, 'status.json', state);
      }
    }
    // Mark intent before the first await, so a rapid resume cannot flip auto
    // back on while this run is already leaving its cancellation boundary.
    if (_current == id) _cancellation?.cancel();
    if (!preserveAuto) {
      await setAuto(root, false, preserveQualityRetry: true);
    }
    _queue.remove(id);
    final Completer<void>? active = _current == id ? _currentDone : null;
    if (active != null) {
      _cancellation!.cancel();
      final Json state = _json(root, 'status.json');
      state.addAll(<String, Object?>{
        'state': 'cancelling',
        'updated': _clock(),
        if (!preserveAuto)
          'pause_reason':
              state['pause_reason'] == BookPauseReason.user.value
                  ? BookPauseReason.user.value
                  : reason.value,
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
        if (preserveAuto) {
          state.remove('pause_reason');
        } else {
          state['pause_reason'] =
              state['pause_reason'] == BookPauseReason.user.value
                  ? BookPauseReason.user.value
                  : reason.value;
        }
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
    BookPauseReason reason = BookPauseReason.user,
  }) => pauseBook(
    root,
    timeout: timeout,
    preserveAuto: preserveAuto,
    reason: reason,
  );

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
          roots = <Directory>[
            for (final String id in ids) Directory('${books.path}/$id'),
          ];
        }
        for (final Directory root in roots) {
          if (_stopping) break;
          _queue.remove(_name(root));
          _notify();
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

  static double _retryDelay(int count) {
    // No retry cap for a transient outage; delay stops growing at 15 minutes.
    final int power = (count - 1).clamp(0, 5);
    final double seconds = 30.0 * (1 << power);
    return seconds > 900 ? 900 : seconds;
  }

  double _retryAt(Json state) {
    final Object? stored = state['retry_at'];
    if (stored is num && stored.isFinite) return stored.toDouble();
    final int count = ((state['retry_count'] as num?)?.toInt() ?? 1).clamp(
      1,
      1000000,
    );
    final double updated = (state['updated'] as num?)?.toDouble() ?? _clock();
    return updated + _retryDelay(count);
  }

  bool _retryPending(Json meta, Json state) =>
      _truth(meta['auto']) &&
      state['state'] == 'error' &&
      state['retryable'] == true;

  /// One-shot wakeups are enough for the explicit client worker. Re-read
  /// durable files on each wake so an external lease or a user pause wins.
  void _scheduleRetryWake() {
    _retryTimer?.cancel();
    _retryTimer = null;
    if (!_alive || _stopping || (!enabled && !resumeInterrupted)) return;
    final double now = _clock();
    double? next;
    bool queued = false;
    for (final Directory root in _roots()) {
      try {
        final Json meta = _json(root, 'meta.json');
        final Json state = _json(root, 'status.json');
        if (!_retryPending(meta, state)) continue;
        final double at = _retryAt(state);
        if (at <= now && _current != _name(root)) {
          _queue.add(_name(root));
          queued = true;
        }
        // If a separate process owns a due book, retry the lease check later.
        final double wake = at <= now ? now + 60 : at;
        if (next == null || wake < next) next = wake;
      } on Object catch (error) {
        _lastError = <String, Object?>{
          'book': _name(root),
          'message': _short(error),
          'at': now,
        };
      }
    }
    if (next != null) {
      final int millis = ((next - now) * 1000).ceil().clamp(1, 900000);
      _retryTimer = Timer(Duration(milliseconds: millis), _scheduleRetryWake);
    }
    if (queued) {
      _notify();
      _wake();
    }
  }

  bool _eligible(Directory root, Json meta, Json state) =>
      _file(root, 'book.json').existsSync() &&
      _truth(meta['auto']) &&
      !(state['state'] == 'done' && !_truth(meta['retry_quality'])) &&
      (state['state'] != 'error' ||
          (_retryPending(meta, state) && _clock() >= _retryAt(state)));

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
    final int priorRetryCount =
        (state['retry_count'] as num?)?.toInt().clamp(0, 1000000) ?? 0;
    final Json? retryBefore =
        retryQuality ? _read(_file(root, 'work/quality-retry.json')) : null;
    final WorkerSettings settings = _settings();
    if (settings.concurrency < 1) throw const ValueError('并发数量必须大于零');
    final RunCancellation cancellation = RunCancellation();
    _current = _name(root);
    _cancellation = cancellation;
    _currentDone = Completer<void>();
    final String? previousJudgeDirectory = environ['JUDGE_LOG_DIR'];
    final String route =
        bookJudgeRoute(meta) ?? environ['JEV_ROUTE'] ?? 'free-only';
    int code = 1;
    try {
      // A native worker runs several books in one isolate. Give each attempt
      // the cache location and fresh process counters of the original worker.
      environ['JUDGE_LOG_DIR'] = '${root.path}/work/judge';
      jev.resetJevStats();
      final Json prior = _json(root, 'work/worker-receipt.json');
      if (state['state'] == 'error') {
        // An interrupted retry is an active task on the next launch, rather
        // than an error that has silently lost its retry schedule.
        state
          ..['state'] = 'running'
          ..['updated'] = _clock()
          ..remove('retryable')
          ..remove('retry_at');
        _save(root, 'status.json', state);
      }
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
        await withJudgeRoute(
          route,
          () => _runBook(
            root,
            cancellation: cancellation,
            retryQuality: retryQuality,
            model: settings.model,
            localModel: settings.localModel,
            concurrency: settings.concurrency,
          ),
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
      final bool stopAfterBioFailure =
          code != 0 &&
          _failedBioJob(root, _object(state['quality']), contentOnly: true);
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
        if (state['retryable'] == true && !stopAfterBioFailure) {
          final int count = priorRetryCount + 1;
          state['retry_count'] = count;
          state['retry_at'] = _clock() + _retryDelay(count);
        } else {
          state.remove('retry_at');
          if (stopAfterBioFailure) state['retryable'] = false;
        }
        _save(root, 'status.json', state);
        _lastError = <String, Object?>{
          'book': _name(root),
          'message': state['error'],
          'at': _clock(),
        };
      }
      if (stopAfterBioFailure) {
        // A new biography draft must require another explicit tap, rather
        // than the worker's timed error retry silently issuing paid requests.
        meta['auto'] = false;
        meta.remove('retry_quality');
        _save(root, 'meta.json', meta);
      }
      _receipt(root, <String, Object?>{
        'phase': state['state'] ?? (code == 75 ? 'interrupted' : 'error'),
        'exit_code': code,
        'owner_pid': null,
        'finished_at': _clock(),
      });
      _scheduleRetryWake();
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
    final String phase = '${fields['phase'] ?? ''}';
    final Json receipt = <String, Object?>{
      'schema': 1,
      'book': _name(root),
      'request_id': '${(now * 1000000).round()}-$pid-${++_sequence}',
      'requested_at': now,
      'attempt': 0,
      ...previous,
      ...fields,
      'updated': now,
    };
    final String? pauseReason;
    if (phase == 'paused' || phase == 'cancelling') {
      final Object? cause =
          fields['pause_reason'] ?? _json(root, 'status.json')['pause_reason'];
      pauseReason = cause is String ? cause : null;
      if (pauseReason != null) receipt['pause_reason'] = pauseReason;
    } else {
      pauseReason = null;
      receipt.remove('pause_reason');
    }
    _save(root, 'work/worker-receipt.json', receipt);
    final String? message = switch (phase) {
      'queued' when fields['reason'] == 'recovered' => '中断后自动继续',
      'queued' => '已加入整理队列',
      'running' => '正在检查书籍和整理缓存',
      'cancelling' when pauseReason == 'background_time_limit' =>
        '系统后台整理时段结束，正在暂停',
      'cancelling' => '正在暂停，等待当前请求结束',
      'paused' when pauseReason == 'background_time_limit' => '系统后台整理时段结束，已暂停',
      'paused' when pauseReason == 'user' => '已手动暂停整理',
      'paused' when pauseReason == 'interrupted' => '整理中断，等待手动继续',
      'paused' => '整理已暂停',
      'done' => '整理完成',
      'error' => '整理出错，请查看状态详情',
      _ => null,
    };
    if (message != null) {
      pipeline.recordBookActivity(root, phase, message, at: now);
    }
  }

  /// Stop accepting work and preserve automatic intent for an explicit restart.
  /// No model Future is abandoned and no guessed process identifier is killed.
  void stop() {
    _stopping = true;
    _timer?.cancel();
    _timer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
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
