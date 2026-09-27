import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:thusfar_core/jobs.dart' show Worker, WorkerSettings;
import 'package:thusfar_core/llm.dart' as llm;
import 'package:thusfar_core/thusfar_core.dart' show environ;

import 'library.dart';
import 'model_settings.dart';

/// UI contract; tests substitute a worker without making model requests.
abstract class BookProcessing extends ChangeNotifier {
  Future<void> initialize();
  Future<void> startBook(BookEntry book);
  Future<void> pauseBook(BookEntry book);

  /// Complete only after this book has no in-flight work or another live owner.
  Future<void> prepareRemoval(BookEntry book);
  Future<void> close();
}

/// A single worker isolate owns model settings, queue and in-flight requests.
/// UI widgets only issue explicit commands and observe durable status files.

/// Model requests a phone runs at once while reading a book.
const int phoneConcurrency = 4;

class ProcessingController extends BookProcessing {
  ProcessingController(this.library);

  final Library library;
  SendPort? _commands;
  Future<void>? _initializing;
  Timer? _poll;
  final Map<int, Completer<void>> _pending = <int, Completer<void>>{};
  int _sequence = 0;
  bool _closing = false;
  bool _disposed = false;

  @override
  Future<void> initialize() {
    if (_closing) return Future<void>.error(const llm.LLMError('整理任务正在停止'));
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    final Completer<void> ready = Completer<void>();
    final ReceivePort events = ReceivePort();
    events.listen((Object? message) {
      if (message is SendPort) {
        _commands = message;
        return;
      }
      if (message is Map<String, Object?>) {
        if (message['ready'] == true) {
          _refresh();
          if (!ready.isCompleted) ready.complete();
        } else if (message['health'] is Map<String, Object?>) {
          final Map<String, Object?> health =
              message['health']! as Map<String, Object?>;
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
        <Object?>[library.root.path, events.sendPort],
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

  void _failed(Completer<void> ready, String text) {
    final llm.LLMError error = llm.LLMError(text);
    if (!ready.isCompleted) ready.completeError(error);
    for (final Completer<void> pending in _pending.values) {
      pending.completeError(error);
    }
    _pending.clear();
    _poll?.cancel();
    _poll = null;
    _refresh();
  }

  void _refresh() {
    if (_disposed) return;
    for (final BookEntry entry in List<BookEntry>.of(library.books)) {
      library.refreshStatus(entry);
    }
    notifyListeners();
  }

  Future<void> _send(String operation, [BookEntry? book]) async {
    if (_closing && operation != 'close') throw const llm.LLMError('整理任务正在停止');
    if (operation == 'close') {
      await _initializing;
    } else {
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
    });
    await done.future;
  }

  @override
  Future<void> startBook(BookEntry book) => _send('start', book);

  @override
  Future<void> pauseBook(BookEntry book) => _send('pause', book);

  @override
  Future<void> prepareRemoval(BookEntry book) => _send('prepareRemoval', book);

  @override
  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    _poll?.cancel();
    _poll = null;
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
    environ['LOCAL_CONCURRENCY'] = '4';
    return WorkerSettings(
      model: model,
      localModel: model,
      concurrency: phoneConcurrency,
    );
  }

  final Worker worker = Worker(
    Directory('${data.path}/books'),
    settings: snapshot,
    onChange: (Map<String, Object?> health) =>
        parent.send(<String, Object?>{'health': health}),
  );
  parent.send(commands.sendPort);
  try {
    await worker.start();
    parent.send(<String, Object?>{'ready': true});
  } on Object {
    parent.send(<String, Object?>{'fatal': '无法读取整理任务，请检查书籍数据后重试'});
    commands.close();
    return;
  }
  commands.listen((Object? raw) async {
    final Map<String, Object?> message = raw! as Map<String, Object?>;
    final Object? id = message['id'];
    try {
      final String operation = message['operation']! as String;
      if (operation == 'close') {
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
        await worker.startBook(root);
      } else if (operation == 'pause' || operation == 'prepareRemoval') {
        await worker.pauseBook(root);
        if (operation == 'prepareRemoval') await worker.waitBookIdle(root);
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
