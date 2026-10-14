import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:thusfar_core/jobs.dart'
    show
        AlreadyRunning,
        BookPauseReason,
        RunLease,
        RunCancellation,
        Worker,
        WorkerSettings,
        hasUnsettledModelRequests;
import 'package:thusfar_core/llm.dart' as llm;
import 'package:thusfar_core/run.dart' show recordBookActivity, runBook;
import 'package:thusfar_core/thusfar_core.dart' show environ;

import 'library.dart';
import 'model_settings.dart';
import 'processing_background_session.dart';
import 'processing_notification_bridge.dart';
import 'processing_worker_heartbeat.dart';

/// UI contract; tests substitute a worker without making model requests.
abstract class BookProcessing extends ChangeNotifier {
  Map<String, Object?> get health => const <String, Object?>{};
  Future<void> initialize();
  Future<void> startBook(BookEntry book);

  /// Explicit bounded authorization. Older implementations must not silently
  /// turn a limited request into an all-book run.
  Future<void> startBookWithPlan(BookEntry book, Json plan) =>
      Future<void>.error(UnsupportedError('当前整理器不支持范围，请更新后重试'));
  Future<void> pauseBook(BookEntry book);

  /// Used before changing a paid route: returns only when this book is idle.
  Future<void> pauseBookUntilIdle(BookEntry book);

  /// Fakes and older implementations retain their ordinary pause behavior.
  Future<void> pauseForBackgroundLimit(BookEntry book) => pauseBook(book);

  /// Complete only after this book has no in-flight work or another live owner.
  Future<void> prepareRemoval(BookEntry book);
  Future<void> close();
}

/// A dead worker cannot keep claiming active books. Preserve an authorized
/// auto request so the next worker can resume it from its cached frontier.
/// Check the book lease first so an independent live owner wins.
Future<void> reconcileStoppedWorker(Library library, String reason) async {
  for (final BookEntry book in List<BookEntry>.of(library.books)) {
    if (!book.status.isActive || !book.dir.existsSync()) continue;
    final RunLease lease;
    try {
      lease = await RunLease.acquire(book.dir);
    } on AlreadyRunning {
      continue;
    }
    try {
      final File file = File('${book.dir.path}/status.json');
      final Object? raw = readJson(file);
      if (raw is! Json || !ProcessStatus(raw).isActive) continue;
      final Json meta =
          (readJson(File('${book.dir.path}/meta.json')) as Json?) ??
          <String, Object?>{};
      final bool manualPause = raw['pause_reason'] == 'user';
      final bool uncertain = hasUnsettledModelRequests(book.dir);
      final bool resume = meta['auto'] == true && !manualPause && !uncertain;
      if (uncertain) {
        meta['auto'] = false;
        writeJson(File('${book.dir.path}/meta.json'), meta);
        raw.addAll(<String, Object?>{
          'pause_reason': 'request_outcome_unknown',
          'request_outcome': 'unknown',
          'retryable': false,
        });
        raw.remove('retry_at');
      }
      if (manualPause) {
        meta['auto'] = false;
        writeJson(File('${book.dir.path}/meta.json'), meta);
      }
      raw.addAll(<String, Object?>{
        'state': resume ? 'queued' : 'paused',
        'error': uncertain ? raw['error'] : null,
        'notice': resume ? reason : null,
        'updated': DateTime.now().microsecondsSinceEpoch / 1e6,
      });
      if (resume) {
        raw.remove('pause_reason');
      } else {
        raw['pause_reason'] ??= 'interrupted';
      }
      writeJson(file, raw);
      recordBookActivity(
        book.dir,
        resume ? 'queued' : 'paused',
        uncertain
            ? '没有收到完整结果，已完成的内容已保留。可以点“继续整理”再试'
            : resume
            ? '整理任务意外中断，重新打开应用后自动继续'
            : '整理任务意外中断，等待手动继续',
      );
    } finally {
      lease.release();
    }
  }
}

/// A single worker isolate owns model settings, queue and in-flight requests.
/// UI widgets only issue explicit commands and observe durable status files.

/// Model requests a phone runs at once while reading a book.
const int phoneConcurrency = 1;

class ProcessingController extends BookProcessing {
  ProcessingController(
    this.library, {
    ProcessingBackgroundSession? background,
  }) {
    _background =
        background ??
        ProcessingBackgroundSession(
          onUnavailable: (String id) async {
            final BookEntry? book = library.byId(id);
            if (book != null && !_closing) {
              await _send('pauseBackgroundUnavailable', book);
            }
          },
        );
  }

  late final ProcessingBackgroundSession _background;

  final Library library;
  Map<String, Object?> _health = const <String, Object?>{};
  @override
  Map<String, Object?> get health => _health;
  SendPort? _commands;
  Future<void>? _initializing;
  Timer? _poll;
  final Map<int, Completer<void>> _pending = <int, Completer<void>>{};
  int _sequence = 0;
  bool _closing = false;
  bool _ready = false;
  bool _disposed = false;

  @override
  Future<void> initialize() {
    if (_closing) return Future<void>.error(const llm.LLMError('整理任务正在停止'));
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    ProcessingNotificationBridge.onBackgroundTimeLimit(_pauseBackgroundLimited);
    final List<String> startupLimits =
        await ProcessingNotificationBridge.takeBackgroundTimeLimitBookIds();
    final Completer<void> ready = Completer<void>();
    final ReceivePort events = ReceivePort();
    events.listen((Object? message) {
      if (message is SendPort) {
        _commands = message;
        return;
      }
      if (message is Map<String, Object?>) {
        if (message['backgroundStart'] is String &&
            message['reply'] is SendPort) {
          unawaited(
            _startBackground(
              message['backgroundStart']! as String,
              message['reply']! as SendPort,
            ),
          );
        } else if (message['ready'] == true) {
          _ready = true;
          _refresh();
          if (!ready.isCompleted) ready.complete();
        } else if (message['heartbeat'] == true) {
          _background.workerHeartbeat();
          final Object? sample = message['sample'];
          if (sample is Map<String, Object?>) {
            unawaited(
              ProcessingNotificationBridge.recordWorkerHeartbeat(sample),
            );
          }
        } else if (message['health'] is Map<String, Object?>) {
          final Map<String, Object?> health =
              message['health']! as Map<String, Object?>;
          _health = health;
          _background.synchronize(health);
          final bool active =
              health['current'] != null ||
              ((health['queued'] as List<Object?>?) ?? const []).isNotEmpty;
          if (active && !_closing && !_disposed) {
            _poll ??= Timer.periodic(
              const Duration(seconds: 1),
              (_) => _refresh(),
            );
          } else {
            _poll?.cancel();
            _poll = null;
          }
          _refresh();
        } else if (message['id'] is int) {
          final Completer<void>? done = _pending.remove(message['id']);
          final Object? error = message['error'];
          if (error != null) {
            done?.completeError(llm.LLMError('$error'));
          } else {
            done?.complete();
          }
          _refresh();
        } else if (message['fatal'] is String) {
          _failed(ready, message['fatal']! as String);
        }
      } else if (message == null) {
        if (!_closing) _failed(ready, '整理任务已停止，请重新打开应用后继续');
        events.close();
        _commands = null;
      } else if (message is List<Object?>) {
        _failed(ready, '整理任务发生错误，请重新打开应用后继续');
      }
    });
    try {
      await Isolate.spawn<List<Object?>>(
        _processingIsolate,
        <Object?>[library.root.path, events.sendPort, startupLimits],
        onError: events.sendPort,
        onExit: events.sendPort,
        debugName: 'thusfar-book-worker',
      );
      await ready.future;
    } on Object {
      events.close();
      _initializing = null;
      _commands = null;
      rethrow;
    }
  }

  Future<void> _startBackground(String id, SendPort reply) async {
    try {
      final BookEntry? book = library.byId(id);
      if (book == null || _closing) throw StateError('整理任务已停止');
      await _background.acquire(book);
      reply.send(null);
    } on Object {
      reply.send('后台整理服务未能启动，请回到页读后重试');
    }
  }

  Future<void> _pauseBackgroundLimited(List<String> ids) async {
    for (final String id in ids) {
      final BookEntry? book = library.byId(id);
      if (book != null && !_closing) await _send('pauseBackgroundLimit', book);
    }
  }

  void _failed(Completer<void> ready, String text) {
    _ready = false;
    unawaited(_background.stopAll());
    final llm.LLMError error = llm.LLMError(text);
    _health = <String, Object?>{
      'alive': false,
      'current': null,
      'queued': const <String>[],
      'last_error': <String, Object?>{'message': text},
    };
    if (!ready.isCompleted) ready.completeError(error);
    for (final Completer<void> pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
    _poll?.cancel();
    _poll = null;
    _refresh();
    unawaited(
      reconcileStoppedWorker(
        library,
        text,
      ).catchError((Object _) {}).whenComplete(_refresh),
    );
  }

  void _refresh() {
    if (_disposed) return;
    for (final BookEntry entry in List<BookEntry>.of(library.books)) {
      library.refreshStatus(entry);
    }
    notifyListeners();
    unawaited(_background.refresh());
  }

  Future<void> _send(String operation, [BookEntry? book, Json? plan]) async {
    if (_closing && operation != 'close') throw const llm.LLMError('整理任务正在停止');
    if (operation == 'close') {
      await _initializing;
    } else if (!_ready) {
      await initialize();
    }
    final SendPort? port = _commands;
    if (port == null) throw const llm.LLMError('整理任务已停止，请重新打开应用后继续');
    final int id = ++_sequence;
    final Completer<void> done = Completer<void>();
    _pending[id] = done;
    port.send(<String, Object?>{
      'id': id,
      'operation': operation,
      if (book != null) 'book': book.id,
      'plan': ?plan,
    });
    if (book != null &&
        <String>{
          'pause',
          'pauseAndWait',
          'pauseBackgroundLimit',
          'pauseBackgroundUnavailable',
          'prepareRemoval',
        }.contains(operation)) {
      unawaited(_background.stopBook(book.id).catchError((Object _) {}));
    }
    await done.future;
  }

  @override
  Future<void> startBook(BookEntry book) => _send('start', book);

  @override
  Future<void> startBookWithPlan(BookEntry book, Json plan) =>
      _send('start', book, plan);

  @override
  Future<void> pauseBook(BookEntry book) => _send('pause', book);

  @override
  Future<void> pauseBookUntilIdle(BookEntry book) =>
      _send('pauseAndWait', book);

  @override
  Future<void> pauseForBackgroundLimit(BookEntry book) =>
      _send('pauseBackgroundLimit', book);

  @override
  Future<void> prepareRemoval(BookEntry book) => _send('prepareRemoval', book);

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _poll?.cancel();
    _poll = null;
    await _background.close();
    ProcessingNotificationBridge.onBackgroundTimeLimit(null);
    if (_initializing != null && _commands != null) {
      await _send('close');
    } else if (_initializing != null) {
      await _initializing;
      if (_commands != null) await _send('close');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    // Do not kill the isolate while a paid request is settling.
    unawaited(close().catchError((Object _) {}));
    super.dispose();
  }
}

Future<void> _processingIsolate(List<Object?> args) async {
  final Directory data = Directory(args[0]! as String);
  final SendPort parent = args[1]! as SendPort;
  final ReceivePort commands = ReceivePort();
  final ModelSettings settings = ModelSettings(File('${data.path}/.model.env'));
  WorkerSettings snapshot() {
    settings.applyEnvironment();
    final String model = settings.read().$2;
    environ['LOCAL_CONCURRENCY'] = '$phoneConcurrency';
    environ['LLM_MAX_CONCURRENT'] = '1';
    // These limits apply to this worker isolate only. The UI isolate retains
    // its own environment, including the model settings probe behavior.
    environ['LLM_RETRIES'] = '1';
    environ['LOCAL_EXTRACT_CHAT_RETRIES'] = '0';
    environ['LOCAL_SEGMENT_RETRIES'] = '2';
    environ['LLM_WALL_TIMEOUT'] = '300';
    return WorkerSettings(
      model: model,
      localModel: model,
      concurrency: phoneConcurrency,
    );
  }

  ProcessingWorkerHeartbeat? activeHeartbeat;
  final Worker worker = Worker(
    Directory('${data.path}/books'),
    resumeInterrupted: true,
    settings: snapshot,
    run:
        (
          Directory root, {
          required RunCancellation cancellation,
          required bool retryQuality,
          required String model,
          required String localModel,
          required int concurrency,
        }) async {
          final ReceivePort reply = ReceivePort();
          final ProcessingWorkerHeartbeat journal = ProcessingWorkerHeartbeat(
            root,
          );
          activeHeartbeat = journal;
          journal.record();
          try {
            parent.send(<String, Object?>{
              'backgroundStart': root.uri.pathSegments
                  .where((String s) => s.isNotEmpty)
                  .last,
              'reply': reply.sendPort,
            });
            final Object? failure = await cancellation.wait(
              reply.first.timeout(const Duration(seconds: 15)),
            );
            cancellation.checkpoint();
            if (failure != null) throw llm.LLMError('$failure');
            await runBook(
              root,
              cancellation: cancellation,
              retryQuality: retryQuality,
              model: model,
              localModel: localModel,
              concurrency: concurrency,
            );
          } finally {
            journal.record(finished: true);
            if (identical(activeHeartbeat, journal)) activeHeartbeat = null;
            reply.close();
          }
        },
    onChange: (Map<String, Object?> health) =>
        parent.send(<String, Object?>{'health': health}),
  );
  parent.send(commands.sendPort);
  try {
    // Consume a persisted Android timeout before reconciliation can schedule
    // another paid run. A stale signal must never cancel a newly admitted run.
    for (final String id in (args[2] as List<Object?>).whereType<String>()) {
      if (id.isEmpty ||
          id.contains('/') ||
          id.contains('\\') ||
          id.startsWith('.')) {
        continue;
      }
      final Directory book = Directory('${data.path}/books/$id');
      if (!book.existsSync()) continue;
      final Json? state = readJson(File('${book.path}/status.json')) as Json?;
      if (state != null && ProcessStatus(state).isActive) {
        await worker.pauseBook(
          book,
          reason: BookPauseReason.backgroundTimeLimit,
        );
      }
    }
    await worker.start();
    parent.send(<String, Object?>{'ready': true});
  } on Object {
    parent.send(<String, Object?>{'fatal': '无法读取整理任务，请检查书籍数据后重试'});
    commands.close();
    return;
  }
  final Timer heartbeat = Timer.periodic(const Duration(seconds: 15), (_) {
    final Map<String, Object?> health = worker.health();
    if (health['current'] != null ||
        ((health['queued'] as List<Object?>?) ?? const []).isNotEmpty) {
      parent.send(<String, Object?>{
        'heartbeat': true,
        'sample': activeHeartbeat?.record(),
      });
    }
  });
  commands.listen((Object? raw) async {
    final Map<String, Object?> message = raw! as Map<String, Object?>;
    final Object? id = message['id'];
    try {
      final String operation = message['operation']! as String;
      if (operation == 'close') {
        heartbeat.cancel();
        await worker.close();
        await worker.waitIdle();
        parent.send(<String, Object?>{'id': id});
        commands.close();
        return;
      }
      final String book = message['book']! as String;
      if (book.isEmpty ||
          book.contains('/') ||
          book.contains('\\') ||
          book.startsWith('.')) {
        throw const llm.LLMError('书籍编号无效');
      }
      final Directory root = Directory('${data.path}/books/$book');
      if (operation == 'start') {
        if (!settings.hasKey) {
          throw const llm.LLMError('还没有填写模型 API 密钥，请先到「模型设置」填写');
        }
        await worker.startBook(root, plan: message['plan'] as Json?);
      } else if (operation == 'pause' ||
          operation == 'pauseAndWait' ||
          operation == 'pauseBackgroundLimit' ||
          operation == 'pauseBackgroundUnavailable' ||
          operation == 'prepareRemoval') {
        await worker.pauseBook(
          root,
          reason: operation == 'pauseBackgroundLimit'
              ? BookPauseReason.backgroundTimeLimit
              : operation == 'pauseBackgroundUnavailable'
              ? BookPauseReason.backgroundUnavailable
              : BookPauseReason.user,
        );
        if (operation == 'prepareRemoval' || operation == 'pauseAndWait') {
          await worker.waitBookIdle(root);
        }
      } else {
        throw const llm.LLMError('整理操作无效');
      }
      parent.send(<String, Object?>{'id': id});
    } on Object catch (error) {
      parent.send(<String, Object?>{
        'id': id,
        'error': llm.explain(error) ?? '$error',
      });
    }
  });
}
