import '../ui/reader_message.dart';
import '../ui/info_button.dart';
// Browser-only, per-book preparation controls. Model credentials live only in
// this browser tab's memory; the IndexedDB checkpoint contains results and status.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'package:thusfar_core/thusfar_core.dart' as knowledge;
import 'package:thusfar_core/chapter_verdicts.dart' show titleCheckPending;

import '../ui/theme.dart';
import '../data/preparation_scope.dart';
import 'web_preparation_activity.dart';
import 'reading_boundary.dart';
import 'web_ai_engine.dart';
import 'web_model_provider.dart';
import 'web_model_session.dart';
import 'web_storage.dart';

const String _officialEndpoint = WebAiConfig.geminiEndpoint;
const String _officialModel = WebAiConfig.geminiFlashLiteModel;
const String _deepSeekEndpoint = 'https://api.deepseek.com/v1';
const String _deepSeekModel = 'deepseek-flash';
const String _tabOwnerKey = 'thusfar-web-ai-tab-owner-v1';

String _newOwner() =>
    '${DateTime.now().microsecondsSinceEpoch}-${math.Random().nextInt(1 << 30)}';

bool _browserLocksAvailable() {
  try {
    final JSObject navigator = globalContext['navigator'] as JSObject;
    return navigator['locks'] != null;
  } on Object {
    return false;
  }
}

String _ownerForDocument(bool hasBrowserLock) {
  // A duplicated tab copies sessionStorage. Reuse its owner only when the
  // browser's exclusive per-book Web Lock also protects every run and clear.
  if (!hasBrowserLock) return _newOwner();
  try {
    final html.Storage storage = html.window.sessionStorage;
    final String? existing = storage[_tabOwnerKey];
    if (existing != null && RegExp(r'^\d+-\d+$').hasMatch(existing)) {
      return existing;
    }
    final String created = _newOwner();
    storage[_tabOwnerKey] = created;
    return created;
  } on Object {
    return _newOwner();
  }
}

class WebAiPanel extends StatefulWidget {
  const WebAiPanel({
    super.key,
    required this.book,
    required this.reading,
    required this.library,
    this.cutoffOffset,
    this.focusPersonId,
    this.focusPersonName,
    this.analyze = WebAiEngine.analyze,
    this.readingBuilder,
  });

  final Widget Function(BuildContext, WebPreparationActivity)? readingBuilder;

  final WebBook book;
  final WebReadingState reading;
  final WebLibrary library;

  /// Exclusive end of the original text already visible in the reader.
  /// Null keeps the conservative chapter-level cutoff used from the shelf.
  final int? cutoffOffset;
  final String? focusPersonId;
  final String? focusPersonName;

  /// Allows browser regression tests to exercise cancellation without sending
  /// book text or credentials to a model service.
  @visibleForTesting
  final Future<WebAiResult> Function(
    WebAiConfig config,
    WebAiChunk chunk, {
    Future<bool> Function()? beforeRequest,
  })
  analyze;

  @override
  State<WebAiPanel> createState() => _WebAiPanelState();
}

class _WebAiPanelState extends State<WebAiPanel> {
  late final List<WebAiChunk> _chunks = WebAiEngine.chunks(widget.book);
  late final Map<String, WebAiChunk> _chunkByKey = <String, WebAiChunk>{
    for (final WebAiChunk chunk in _chunks) _chunkKey(chunk): chunk,
  };
  final Map<String, Json> _results = <String, Json>{};
  final List<Json> _events = <Json>[];
  final bool _hasBrowserLock = _browserLocksAvailable();
  late final String _owner = _ownerForDocument(_hasBrowserLock);
  Timer? _leaseTimer;
  Timer? _observeTimer;
  bool _leaseHeld = false;
  bool _leaseLost = false;
  bool _otherLeaseActive = false;
  bool _observing = false;
  WebAiConfig? _activeConfig;
  String _endpoint = _officialEndpoint;
  String _model = _officialModel;
  WebModelProtocol _protocol = WebModelProtocol.gemini;
  String _scope = 'first';
  final WebPreparationActivity _readingActivity = WebPreparationActivity();
  String _requestStage = 'idle';
  bool _openingReader = false;
  bool _activityDisposed = false;
  String _phase = 'idle';
  String? _lastError;
  String? _inFlight;
  String? _activeChunk;
  bool _loading = true;
  bool _running = false;
  bool _starting = false;
  bool _clearing = false;
  bool _configuring = false;
  bool _routeExited = false;
  bool _stopRequested = false;
  bool _revealCurrentChapter = false;
  int _generation = 0;

  String _chunkKey(WebAiChunk chunk) =>
      '${chunk.chapterIndex}:${chunk.chunkIndex}';

  /// A backup can carry an old or hand-edited preparation record. Never let
  /// it claim that future-chapter text belongs to an earlier chapter, or show
  /// an uncited model draft as if it had passed the current local check.
  bool _validSavedResult(String key, Json record) {
    final WebAiChunk? chunk = _chunkByKey[key];
    if (chunk == null ||
        record['chapter_index'] != chunk.chapterIndex ||
        record['chunk_index'] != chunk.chunkIndex) {
      return false;
    }
    final Object? raw = record['result'];
    if (raw is! Map<String, Object?>) return false;
    final String summary = '${raw['summary'] ?? ''}';
    final String summaryEvidence = '${raw['summary_evidence'] ?? ''}';
    if (summary.isNotEmpty != summaryEvidence.isNotEmpty ||
        (summaryEvidence.isNotEmpty && !chunk.text.contains(summaryEvidence))) {
      return false;
    }
    final Object? facts = raw['character_facts'];
    final Object? links = raw['relationships'];
    if (facts is! List || links is! List) return false;
    for (final Object? item in facts) {
      if (item is! Map<String, Object?>) return false;
      final String name = '${item['name'] ?? ''}';
      final String evidence = '${item['evidence'] ?? ''}';
      if (name.isEmpty ||
          evidence.isEmpty ||
          !evidence.contains(name) ||
          !chunk.text.contains(evidence)) {
        return false;
      }
    }
    for (final Object? item in links) {
      if (item is! Map<String, Object?>) return false;
      final String from = '${item['from'] ?? ''}';
      final String to = '${item['to'] ?? ''}';
      final String evidence = '${item['evidence'] ?? ''}';
      if (from.isEmpty ||
          to.isEmpty ||
          from == to ||
          evidence.isEmpty ||
          !evidence.contains(from) ||
          !evidence.contains(to) ||
          !chunk.text.contains(evidence)) {
        return false;
      }
    }
    return summary.isNotEmpty || facts.isNotEmpty || links.isNotEmpty;
  }

  List<WebAiChunk> get _bodyChunks => <WebAiChunk>[
    for (final WebAiChunk chunk in _chunks)
      if (chunk.text.trim().isNotEmpty) chunk,
  ];

  List<WebAiChunk> _targets(String scope) {
    final List<WebAiChunk> chunks = _bodyChunks;
    if (chunks.isEmpty) return const <WebAiChunk>[];
    final PreparationScope selected = PreparationScope.parse(scope);
    if (selected.kind == 'all') return chunks;
    if (selected.kind == 'range') {
      return chunks
          .where(
            (WebAiChunk chunk) =>
                chunk.chapterIndex >= selected.fromChapter &&
                chunk.chapterIndex <= selected.toChapter,
          )
          .toList();
    }
    if (selected.kind == 'read') {
      final int cutoff = selected.cutoff ?? _readingCutoff;
      return chunks
          .where(
            (WebAiChunk chunk) =>
                chunk.endOffset > chunk.startOffset &&
                chunk.endOffset <= cutoff,
          )
          .toList();
    }
    final int firstChapter = chunks
        .firstWhere(
          (WebAiChunk chunk) => chunk.text.trim().runes.length >= 80,
          orElse: () => chunks.first,
        )
        .chapterIndex;
    return <WebAiChunk>[
      for (final WebAiChunk chunk in chunks)
        if (chunk.chapterIndex == firstChapter) chunk,
    ];
  }

  int get _readingCutoff {
    if (widget.cutoffOffset != null) return widget.cutoffOffset!;
    if (widget.book.chapters.isEmpty) return 0;
    final Json chapter =
        widget.book.chapters[widget.reading.chapter.clamp(
          0,
          widget.book.chapters.length - 1,
        )];
    return ((chapter[widget.reading.fraction >= 0.99 ? 'o1' : 'o0'] as num?)
            ?.toInt() ??
        0);
  }

  void _publishReadingActivity() {
    if (_activityDisposed) return;
    final List<WebAiChunk> targets = _targets(_scope);
    _readingActivity.update(
      running: _running,
      stopping: _stopRequested,
      done: _done(targets),
      total: targets.length,
      label: _running
          ? (_stopRequested ? '正在停止整理' : '正在整理')
          : _phase == 'complete'
          ? '本次整理完成'
          : _phase == 'error'
          ? '整理遇到问题'
          : '整理已暂停',
      stop: _pause,
    );
  }

  Future<void> _readWhilePreparing() async {
    if (_openingReader || widget.readingBuilder == null || !mounted) return;
    _openingReader = true;
    _publishReadingActivity();
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => WebPreparationReader(
            activity: _readingActivity,
            child: widget.readingBuilder!(context, _readingActivity),
          ),
        ),
      );
    } finally {
      _openingReader = false;
      if (mounted) setState(() {});
    }
  }

  int _done(List<WebAiChunk> targets) => targets
      .where((WebAiChunk chunk) => _results.containsKey(_chunkKey(chunk)))
      .length;

  Future<bool> _withBrowserLock(Future<void> Function() action) async {
    if (!_hasBrowserLock) {
      await action();
      return true;
    }
    // Web Locks are released by the browser when a document unloads. Keeping
    // this lock for the whole operation lets a refreshed tab reuse its
    // session owner immediately, while a duplicated live tab cannot do so.
    final JSObject navigator = globalContext['navigator'] as JSObject;
    final JSObject manager = navigator['locks'] as JSObject;
    final JSObject options = JSObject()..['ifAvailable'] = true.toJS;
    bool granted = false;
    final JSPromise<JSAny?> promise = manager.callMethod<JSPromise<JSAny?>>(
      'request'.toJS,
      'thusfar-web-ai:${widget.book.meta.id}'.toJS,
      options,
      ((JSAny? lock) {
        if (lock == null) return null;
        granted = true;
        return action().then<JSAny?>((_) => null).toJS;
      }).toJS,
    );
    await promise.toDart;
    return granted;
  }

  Future<bool> _renewLease() async {
    if (!_leaseHeld || _leaseLost) return false;
    try {
      final bool renewed = await widget.library.renewPreparationLease(
        widget.book.meta.id,
        _owner,
      );
      if (!renewed) {
        _leaseLost = true;
        _stopRequested = true;
      }
      return renewed;
    } on Object {
      _leaseLost = true;
      _stopRequested = true;
      return false;
    }
  }

  Future<void> _releaseLease() async {
    _leaseTimer?.cancel();
    _leaseTimer = null;
    if (!_leaseHeld) return;
    _leaseHeld = false;
    try {
      await widget.library.releasePreparationLease(widget.book.meta.id, _owner);
    } on Object {
      // The IndexedDB lease expires if the browser closes during cleanup.
    }
  }

  Future<void> _observeOtherLease() async {
    if (_observing || _running || !mounted) return;
    _observing = true;
    try {
      final bool active = await widget.library.otherPreparationLeaseActive(
        widget.book.meta.id,
        _owner,
      );
      if (!mounted || _running) return;
      if (_otherLeaseActive != active) {
        setState(() => _otherLeaseActive = active);
      }
      if (active) await _load(quiet: true);
    } on Object {
      // Fail closed in the UI. acquirePreparationLease is checked again before
      // every actual run, so a temporary read error never authorizes a call.
      if (mounted && !_running) setState(() => _otherLeaseActive = true);
    } finally {
      _observing = false;
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    unawaited(_observeOtherLease());
    _observeTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      unawaited(_observeOtherLease());
    });
  }

  Future<void> _load({bool quiet = false}) async {
    final int generation = _generation;
    try {
      final Json? saved = await widget.library.loadPreparation(
        widget.book.meta.id,
      );
      if (!mounted || _running || generation != _generation) return;
      setState(() => _hydrate(saved));
    } on Object {
      if (!quiet && mounted && !_running && generation == _generation) {
        setState(() {
          _loading = false;
          _lastError = '无法读取本地整理记录；请检查浏览器存储空间。';
        });
      }
    }
  }

  /// IndexedDB is authoritative after acquiring the cross-tab lease. A tab
  /// can miss the final observer poll after another tab finishes; hydrating
  /// again before the first request prevents sending any completed chunk twice.
  void _hydrate(Json? saved) {
    final Object? rawResults = saved?['results'];
    final Map<String, Json> restored = <String, Json>{};
    if (rawResults is Map) {
      for (final MapEntry<Object?, Object?> item in rawResults.entries) {
        if (item.key is String && item.value is Map<String, Object?>) {
          final String key = item.key! as String;
          final Json record = item.value! as Json;
          if (_validSavedResult(key, record)) restored[key] = record;
        }
      }
    }
    final List<Json> events = <Json>[];
    final Object? rawEvents = saved?['events'];
    if (rawEvents is List) {
      for (final Object? item in rawEvents) {
        if (item is Map<String, Object?>) events.add(item);
      }
    }
    _results
      ..clear()
      ..addAll(restored);
    _events
      ..clear()
      ..addAll(events);
    final bool oldUnusedDefault =
        _results.isEmpty &&
        _events.isEmpty &&
        (saved?['phase'] == null || saved?['phase'] == 'idle') &&
        (saved?['endpoint'] == _deepSeekEndpoint ||
            saved?['endpoint'] == 'https://api.deepseek.com') &&
        saved?['model'] == _deepSeekModel;
    final Json? profile =
        WebModelSession.current.config == null &&
            _results.isEmpty &&
            _events.isEmpty &&
            (saved?['phase'] == null || saved?['phase'] == 'idle')
        ? WebLibrary.savedModelProfile()
        : null;
    _endpoint = profile?['base_url'] is String
        ? profile!['base_url']! as String
        : oldUnusedDefault
        ? _officialEndpoint
        : saved?['endpoint'] is String
        ? saved!['endpoint']! as String
        : _officialEndpoint;
    _model = profile?['model'] is String
        ? profile!['model']! as String
        : oldUnusedDefault
        ? _officialModel
        : saved?['model'] is String
        ? saved!['model']! as String
        : _officialModel;
    _protocol = profile?['protocol'] is String
        ? WebModelProtocol.fromName(profile!['protocol']! as String, _endpoint)
        : oldUnusedDefault
        ? WebModelProtocol.gemini
        : WebModelProtocol.fromName(saved?['protocol'] as String?, _endpoint);
    _scope = validPreparationScope(saved?['scope'])
        ? saved!['scope']! as String
        : 'first';
    _phase = saved?['phase'] is String ? saved!['phase']! as String : 'idle';
    _lastError = saved?['last_error'] as String?;
    _inFlight = saved?['in_flight'] as String?;
    _loading = false;
  }

  Json _checkpoint() => <String, Object?>{
    'schema': 'thusfar-web-ai-v1',
    'scope': _scope,
    'phase': _phase,
    'target_count': _targets(_scope).length,
    'completed_count': _done(_targets(_scope)),
    'endpoint': _endpoint,
    'model': _model,
    'protocol': _protocol.name,
    'in_flight': _inFlight,
    'last_error': _lastError,
    'updated_at': DateTime.now().millisecondsSinceEpoch,
    'results': <String, Object?>{..._results},
    'events': <Json>[..._events],
  };

  Future<void> _save() =>
      widget.library.savePreparation(widget.book.meta.id, _checkpoint());

  void _event(String kind, String message) {
    _events.add(<String, Object?>{
      'at': DateTime.now().millisecondsSinceEpoch,
      'kind': kind,
      'message': message,
    });
    if (_events.length > 120) _events.removeRange(0, _events.length - 120);
    _publishReadingActivity();
  }

  String _safeError(Object error) {
    final String raw = error is WebAiException ? error.message : '$error';
    String safe = raw;
    final String? key = _activeConfig?.apiKey;
    if (key != null && key.isNotEmpty) safe = safe.replaceAll(key, '[密钥]');
    safe = safe.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (safe.length > 300) safe = '${safe.substring(0, 300)}…';
    return readerMessage(safe, fallback: '整理未完成，请检查网络和 AI 设置。');
  }

  Future<void> _run(WebAiConfig config, String scope) async {
    if (!mounted ||
        _routeExited ||
        _running ||
        _starting ||
        _clearing ||
        _loading) {
      return;
    }
    _starting = true;
    // Only an explicit new run may clear cancellation, before any async work.
    // Clearing it after a lease await can undo a Back/Close during setup.
    _stopRequested = false;
    try {
      final bool granted = await _withBrowserLock(
        () => _runLocked(config, scope),
      );
      if (!granted) {
        _message('另一个标签页正在整理这本书，请先在那边暂停。尚未开始整理。');
      }
    } on Object {
      _message('暂时无法开始整理，请刷新页面后重试。');
    } finally {
      _starting = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _runLocked(WebAiConfig config, String scope) async {
    if (!_canStartRequest) return;
    if (_targets(scope).isEmpty) {
      _message('当前范围没有读完的正文。可继续阅读，或明确选择第一章试整理。');
      return;
    }
    final bool acquired;
    try {
      acquired = await widget.library.acquirePreparationLease(
        widget.book.meta.id,
        _owner,
      );
    } on Object {
      _message('暂时无法开始整理，请刷新页面后重试。');
      return;
    }
    if (!acquired) {
      if (mounted) setState(() => _otherLeaseActive = true);
      _message('另一个标签页正在整理这本书，请先在那边暂停。尚未开始整理。');
      return;
    }
    _leaseHeld = true;
    _leaseLost = false;
    _otherLeaseActive = false;
    if (!_canStartRequest) {
      await _releaseLease();
      return;
    }
    // Ignore an observer read that began before this tab acquired the lease.
    _generation++;
    try {
      final Json? latest = await widget.library.loadPreparation(
        widget.book.meta.id,
      );
      if (!_canStartRequest || !await _renewLease() || !_canStartRequest) {
        await _releaseLease();
        return;
      }
      // This must run before _save and before any model request. The other tab
      // may have completed after our last 4-second observer poll.
      _hydrate(latest);
    } on Object {
      await _releaseLease();
      _message('无法读取最新整理进度，已停止；尚未开始整理。');
      return;
    }
    final List<WebAiChunk> targets = _targets(scope);
    if (targets.isEmpty || _done(targets) == targets.length) {
      await _releaseLease();
      if (mounted) setState(() {});
      _message(
        targets.isEmpty ? '当前范围没有读完的正文，尚未开始整理。' : '所选范围已由另一个标签页整理完成，无需重复整理。',
      );
      return;
    }
    // A credential-like token in a novel passage would make the strict local
    // checkpoint refuse its citation *after* billing. Check the selected work
    // before making any model call.
    if (targets.any(
      (WebAiChunk chunk) =>
          !_results.containsKey(_chunkKey(chunk)) &&
          webPreparationPassageContainsCredential(chunk.text),
    )) {
      await _releaseLease();
      _message('所选正文含疑似密钥格式，浏览器不会发送或保存这段内容；尚未开始整理。');
      return;
    }
    _activeConfig = config;
    _running = true;
    _scope = scope;
    _endpoint = config.endpoint;
    _model = config.model;
    _protocol = config.protocol;
    _phase = 'running';
    _requestStage = 'preparing';
    _lastError = null;
    if (_inFlight != null && !_results.containsKey(_inFlight)) {
      _event('warning', '上次有一段请求未确认结果；继续时该段可能重新计费。');
    }
    _event('start', '开始${_scopeLabel(scope)}，从已保存进度继续。');
    if (mounted) setState(() {});
    _leaseTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(_renewLease());
    });
    try {
      await _save();
      for (final WebAiChunk chunk in targets) {
        if (!_canStartRequest) break;
        final String key = _chunkKey(chunk);
        if (_results.containsKey(key)) continue;
        if (!await _renewLease()) {
          throw const WebAiException('整理已停止，请刷新页面后继续。');
        }
        if (!_canStartRequest) break;
        _activeChunk = key;
        _requestStage = 'model';
        _inFlight = key;
        _event(
          'request',
          '正在整理第 ${chunk.chapterIndex + 1} 章 · 片段 ${chunk.chunkIndex + 1}。',
        );
        if (mounted) setState(() {});
        await _save();
        // Renew immediately before the billable request, then again after its
        // response before writing any result. A lost lease stops this tab.
        if (!await _renewLease()) {
          throw const WebAiException('整理已停止，请刷新页面后继续。');
        }
        if (!_canStartRequest) break;
        final WebAiResult answer = await widget.analyze(
          config,
          chunk,
          beforeRequest: _beforeRequest,
        );
        if (!await _renewLease()) {
          throw const WebAiException('整理结果未能保存，重试可能再次收费。');
        }
        _requestStage = 'saving';
        if (mounted) setState(() {});
        _results[key] = <String, Object?>{
          'chapter_index': chunk.chapterIndex,
          'chunk_index': chunk.chunkIndex,
          'result': answer.toJson(),
          'completed_at': DateTime.now().millisecondsSinceEpoch,
        };
        _inFlight = null;
        _activeChunk = null;
        _event(
          'done',
          '已完成第 ${chunk.chapterIndex + 1} 章 · 片段 ${chunk.chunkIndex + 1}。',
        );
        await _save();
        if (mounted) setState(() {});
      }
      final bool completed = _done(targets) == targets.length;
      _phase = completed ? 'complete' : 'paused';
      _event(
        completed ? 'complete' : 'pause',
        completed ? '所选范围已整理完成。' : '已暂停，完成的片段已保存。',
      );
    } on Object catch (error) {
      if (_stopRequested && !_leaseLost) {
        _phase = 'paused';
        _lastError = null;
        _event('pause', '已暂停；未完成的片段下次继续时可能重新计费。');
      } else {
        _phase = 'error';
        _lastError = _safeError(error);
        _event('error', _lastError!);
      }
    } finally {
      _running = false;
      _requestStage = 'idle';
      _activeChunk = null;
      _activeConfig = null;
      if (!_leaseLost && await _renewLease()) {
        try {
          await _save();
        } on Object {
          _lastError = '浏览器未能保存最新整理记录；请检查存储空间。';
          _phase = 'error';
        }
      } else {
        _phase = 'error';
        _lastError = '整理已停止，未保存的内容可能已经收费。请刷新页面查看进度。';
      }
      await _releaseLease();
      _publishReadingActivity();
      if (mounted) setState(() {});
    }
  }

  bool get _canStartRequest => mounted && !_routeExited && !_stopRequested;

  Future<bool> _beforeRequest() async {
    if (!_canStartRequest) return false;
    final bool renewed = await _renewLease();
    // Pause or Back can arrive while IndexedDB is renewing the lease. The
    // check must follow that await for both the first call and a retry.
    return renewed && _canStartRequest;
  }

  void _pause() {
    if (!_running) return;
    setState(() => _stopRequested = true);
    _publishReadingActivity();
    _message('正在暂停，已完成的内容会保留。');
  }

  Future<void> _configureAndStart() async {
    if (!mounted ||
        _routeExited ||
        _configuring ||
        _running ||
        _starting ||
        _clearing) {
      return;
    }
    _configuring = true;
    try {
      await _configureAndStartOnce();
    } finally {
      _configuring = false;
    }
  }

  Future<void> _configureAndStartOnce() async {
    final WebAiConfig? shared = WebModelSession.current.config;
    final Json? profile = shared == null
        ? WebLibrary.savedModelProfile()
        : null;
    final String initialEndpoint =
        shared?.endpoint ??
        (profile?['base_url'] is String
            ? profile!['base_url']! as String
            : _endpoint);
    final String initialModel =
        shared?.model ??
        (profile?['model'] is String ? profile!['model']! as String : _model);
    WebModelProtocol protocol =
        shared?.protocol ??
        WebModelProtocol.fromName(
          profile?['protocol'] is String
              ? profile!['protocol']! as String
              : _protocol.name,
          initialEndpoint,
        );
    // Treat a tab credential as an atomic endpoint/model/key tuple. A book's
    // migrated default must never be paired with another provider's key.
    final TextEditingController endpoint = TextEditingController(
      text: initialEndpoint,
    );
    final TextEditingController model = TextEditingController(
      text: initialModel,
    );
    final TextEditingController key = TextEditingController(
      text: shared?.apiKey ?? '',
    );
    String keyEndpoint = shared?.endpoint ?? '';
    String provider =
        WebModelPreset.matching(protocol, endpoint.text, model.text)?.id ??
        'custom';
    String scope = _scope == 'read' ? 'read:$_readingCutoff' : _scope;
    final int lastChapter = math.max(0, widget.book.chapters.length - 1);
    final PreparationScope previousScope = PreparationScope.parse(scope);
    if (previousScope.kind == 'read') {
      scope =
          'read:${math.min(previousScope.cutoff ?? _readingCutoff, _readingCutoff)}';
    }
    int rangeFrom = previousScope.fromChapter.clamp(0, lastChapter);
    int rangeTo = previousScope.toChapter.clamp(rangeFrom, lastChapter);
    if (previousScope.kind == 'range') {
      scope = widget.book.chapters.isEmpty
          ? 'first'
          : 'range:$rangeFrom:$rangeTo';
    }
    String? error;
    bool showKey = false;
    _RunChoice? choice;
    try {
      choice = await showDialog<_RunChoice>(
        context: context,
        builder: (BuildContext context) => StatefulBuilder(
          builder: (BuildContext context, StateSetter redraw) {
            final Tokens t = context.tk;
            final Uri? uri = Uri.tryParse(endpoint.text.trim());
            final String host = uri?.host.isNotEmpty == true
                ? uri!.host
                : '所填模型服务商';
            final int remaining = _targets(scope)
                .where(
                  (WebAiChunk chunk) => !_results.containsKey(_chunkKey(chunk)),
                )
                .length;
            return Theme(
              data: Theme.of(context).copyWith(
                // Bundle Chinese glyphs for model forms and offline settings.
                textTheme: Theme.of(context).textTheme.apply(fontFamily: sans),
              ),
              child: AlertDialog(
                backgroundColor: t.sheet,
                insetPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 16,
                ),
                title: const Text('整理这本书'),
                content: SizedBox(
                  width: 520,
                  child: Scrollbar(
                    child: SingleChildScrollView(
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.onDrag,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '选择范围并填写自己的模型密钥。点击开始后才会发送正文。',
                            style: TextStyle(color: t.ink2, height: 1.4),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '整理范围',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: t.ink,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: <Widget>[
                              for (final String option in const <String>[
                                'first',
                                'read',
                                'range',
                                'all',
                              ])
                                if (option != 'range' ||
                                    widget.book.chapters.isNotEmpty)
                                  ChoiceChip(
                                    label: Text(switch (option) {
                                      'first' => '首章',
                                      'read' => '读到这里',
                                      'range' => '选章节',
                                      _ => '全书',
                                    }),
                                    selected:
                                        PreparationScope.parse(scope).kind ==
                                        option,
                                    showCheckmark: false,
                                    visualDensity: VisualDensity.compact,
                                    onSelected: (bool selected) {
                                      if (selected) {
                                        redraw(
                                          () => scope = option == 'range'
                                              ? 'range:$rangeFrom:$rangeTo'
                                              : option == 'read'
                                              ? 'read:$_readingCutoff'
                                              : option,
                                        );
                                      }
                                    },
                                  ),
                            ],
                          ),
                          if (PreparationScope.parse(scope).kind == 'range')
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: DropdownButtonFormField<int>(
                                    initialValue: rangeFrom.clamp(
                                      0,
                                      widget.book.chapters.length - 1,
                                    ),
                                    decoration: const InputDecoration(
                                      labelText: '从哪一章',
                                    ),
                                    items: <DropdownMenuItem<int>>[
                                      for (
                                        int i = 0;
                                        i < widget.book.chapters.length;
                                        i++
                                      )
                                        DropdownMenuItem(
                                          value: i,
                                          child: Text('第 ${i + 1} 章'),
                                        ),
                                    ],
                                    onChanged: (int? v) {
                                      if (v != null) {
                                        redraw(() {
                                          rangeFrom = v;
                                          if (rangeTo < v) rangeTo = v;
                                          scope = 'range:$rangeFrom:$rangeTo';
                                        });
                                      }
                                    },
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: DropdownButtonFormField<int>(
                                    key: ValueKey<String>(
                                      'web-plan-to-$rangeFrom-$rangeTo',
                                    ),
                                    initialValue: rangeTo.clamp(
                                      rangeFrom,
                                      widget.book.chapters.length - 1,
                                    ),
                                    decoration: const InputDecoration(
                                      labelText: '到哪一章',
                                    ),
                                    items: <DropdownMenuItem<int>>[
                                      for (
                                        int i = rangeFrom;
                                        i < widget.book.chapters.length;
                                        i++
                                      )
                                        DropdownMenuItem(
                                          value: i,
                                          child: Text('第 ${i + 1} 章'),
                                        ),
                                    ],
                                    onChanged: (int? v) {
                                      if (v != null) {
                                        redraw(() {
                                          rangeTo = v;
                                          scope = 'range:$rangeFrom:$rangeTo';
                                        });
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
                          const SizedBox(height: 4),
                          Text(
                            '${switch (PreparationScope.parse(scope).kind) {
                              'first' => '先试首章，未读结果仍隐藏。',
                              'read' => '仅发送本次已确认阅读终点之前的完整片段。继续阅读不会自行扩大本次范围。',
                              'range' => '仅整理选中章节的独立引文草稿，前面未处理的章节保持空缺，不会补齐或收费。',
                              _ => '整理全书，未读结果仍隐藏。',
                            }}  $remaining 段待处理。',
                            style: TextStyle(color: t.ink2, fontSize: 12),
                          ),
                          if (PreparationScope.parse(scope).kind == 'read' &&
                              (PreparationScope.parse(scope).cutoff ?? 0) <
                                  _readingCutoff)
                            TextButton(
                              onPressed: () =>
                                  redraw(() => scope = 'read:$_readingCutoff'),
                              child: const Text('把终点更新到当前阅读位置'),
                            ),
                          if (PreparationScope.parse(scope).kind == 'read' &&
                              _targets(scope).isEmpty)
                            Text(
                              '当前阅读位置之前还没有完整片段，请继续阅读或明确选择首章试整理。',
                              style: TextStyle(color: t.amber, fontSize: 12),
                            ),
                          const SizedBox(height: 16),
                          Text(
                            '模型服务商',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: t.ink,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            children: <Widget>[
                              for (final (String value, String label)
                                  in <(String, String)>[
                                    for (final WebModelPreset preset
                                        in WebModelPreset.all)
                                      (preset.id, preset.label),
                                    ('custom', '自定义'),
                                  ])
                                ChoiceChip(
                                  label: Text(label),
                                  selected: provider == value,
                                  showCheckmark: false,
                                  visualDensity: VisualDensity.compact,
                                  onSelected: (bool selected) {
                                    if (!selected || provider == value) {
                                      return;
                                    }
                                    redraw(() {
                                      provider = value;
                                      key.clear();
                                      keyEndpoint = '';
                                      error = null;
                                      if (value != 'custom') {
                                        final WebModelPreset preset =
                                            WebModelPreset.all.firstWhere(
                                              (WebModelPreset item) =>
                                                  item.id == value,
                                            );
                                        protocol = preset.protocol;
                                        endpoint.text = preset.endpoint;
                                        model.text = preset.model;
                                      }
                                    });
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          if (provider == 'gemini')
                            Text(
                              '${model.text} · 有可用免费额度，受账户、地区及官方限额约束；免费档内容可能用于改进产品。',
                              style: TextStyle(color: t.qing, fontSize: 12),
                            )
                          else if (provider == 'deepseek')
                            Text(
                              '${model.text} · DeepSeek 按其账户规则收费。',
                              style: TextStyle(color: t.amber, fontSize: 12),
                            )
                          else if (provider == 'ollama')
                            Text(
                              '本机 Ollama 指当前浏览设备，不是 NAS；可留空密钥，但服务需允许此网页来源。',
                              style: TextStyle(color: t.ink2, fontSize: 12),
                            )
                          else if (provider != 'custom')
                            Text(
                              '请求会直接发往 ${Uri.parse(endpoint.text).host}，服务商可能收费。',
                              style: TextStyle(color: t.ink2, fontSize: 12),
                            ),
                          if (provider == 'custom') ...<Widget>[
                            const SizedBox(height: 12),
                            Text('服务类型', style: TextStyle(color: t.ink)),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: <Widget>[
                                for (final (
                                      WebModelProtocol value,
                                      String label,
                                    )
                                    in const <(WebModelProtocol, String)>[
                                      (WebModelProtocol.openai, 'OpenAI 兼容'),
                                      (WebModelProtocol.gemini, 'Gemini 原生'),
                                      (WebModelProtocol.anthropic, 'Claude 兼容'),
                                    ])
                                  ChoiceChip(
                                    label: Text(label),
                                    selected: protocol == value,
                                    showCheckmark: false,
                                    visualDensity: VisualDensity.compact,
                                    onSelected: (bool selected) {
                                      if (!selected || protocol == value) {
                                        return;
                                      }
                                      redraw(() {
                                        protocol = value;
                                        key.clear();
                                        keyEndpoint = '';
                                        error = null;
                                      });
                                    },
                                  ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: endpoint,
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.next,
                              scrollPadding: const EdgeInsets.only(bottom: 120),
                              decoration: const InputDecoration(
                                labelText: '服务地址',
                                hintText: 'https://example.com/v1',
                              ),
                              onChanged: (String value) => redraw(() {
                                if (key.text.isNotEmpty &&
                                    value.trim() != keyEndpoint) {
                                  key.clear();
                                  keyEndpoint = '';
                                  error = '地址已改变，请填写对应服务商的密钥。';
                                }
                              }),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: model,
                              textInputAction: TextInputAction.next,
                              scrollPadding: const EdgeInsets.only(bottom: 120),
                              decoration: const InputDecoration(
                                labelText: '模型名称',
                              ),
                            ),
                          ],
                          const SizedBox(height: 12),
                          TextField(
                            controller: key,
                            obscureText: !showKey,
                            autocorrect: false,
                            enableSuggestions: false,
                            textInputAction: TextInputAction.done,
                            scrollPadding: const EdgeInsets.only(bottom: 120),
                            decoration: InputDecoration(
                              labelText:
                                  WebModelProvider.allowsEmptyKey(
                                    protocol,
                                    endpoint.text,
                                  )
                                  ? '你的 服务密钥（本机可留空）'
                                  : '你的 服务密钥',
                              suffixIcon: IconButton(
                                tooltip: showKey ? '隐藏密钥' : '显示密钥',
                                onPressed: () =>
                                    redraw(() => showKey = !showKey),
                                icon: Icon(
                                  showKey
                                      ? Icons.visibility_off
                                      : Icons.visibility,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '密钥仅存于当前标签页，关闭后需重填。最多可能调用模型 ${remaining * 2} 次；服务商可能收费。',
                            style: TextStyle(
                              fontSize: 12,
                              color: t.ink2,
                              height: 1.35,
                            ),
                          ),
                          if (error != null) ...<Widget>[
                            const SizedBox(height: 12),
                            Text(error!, style: TextStyle(color: t.danger)),
                          ],
                          ExpansionTile(
                            tilePadding: EdgeInsets.zero,
                            childrenPadding: EdgeInsets.zero,
                            title: const Text('费用与连接说明'),
                            children: <Widget>[
                              Text(
                                '由 $host 提供服务。未完成的内容可能再试一次，使用付费服务时可能再次收费。',
                                style: TextStyle(color: t.ink2, fontSize: 12),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '关闭页面后整理会暂停，回来后可手动继续。密钥不会保存，其他模型设置会保留。使用电脑上的模型时，请确认电脑和模型服务已开启。',
                                style: TextStyle(color: t.ink2, fontSize: 12),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: _targets(scope).isEmpty
                        ? null
                        : () {
                            try {
                              WebModelProvider.validateBase(endpoint.text);
                              WebModelProvider.validateModel(model.text);
                              if (key.text.trim().isEmpty &&
                                  !WebModelProvider.allowsEmptyKey(
                                    protocol,
                                    endpoint.text,
                                  )) {
                                throw const WebModelException('请填写你自己的 服务密钥。');
                              }
                            } on WebModelException catch (failure) {
                              redraw(() => error = failure.message);
                              return;
                            }
                            Navigator.pop(
                              context,
                              _RunChoice(
                                WebAiConfig(
                                  endpoint: endpoint.text.trim(),
                                  model: model.text.trim(),
                                  apiKey: key.text.trim(),
                                  protocol: protocol,
                                ),
                                scope,
                              ),
                            );
                          },
                    child: const Text('开始整理'),
                  ),
                ],
              ),
            );
          },
        ),
      );
    } finally {
      endpoint.dispose();
      model.dispose();
      key.dispose();
    }
    if (choice == null || !mounted || _routeExited) return;
    final _RunChoice selected = choice;
    final int remaining = _targets(selected.scope)
        .where((WebAiChunk chunk) => !_results.containsKey(_chunkKey(chunk)))
        .length;
    if (remaining > 20) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: Text('确认整理${_scopeLabel(selected.scope)}？'),
          content: Text(
            '本次将整理 $remaining 段，未完成的内容可能再试一次。'
            '费用由 ${Uri.parse(selected.config.endpoint).host} 收取，具体金额以该服务的账单为准。'
            '网页关闭后不会自动继续。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认并开始（可能收费）'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || _routeExited) return;
    }
    WebModelSession.current.set(selected.config);
    WebLibrary.saveModelProfile(<String, Object?>{
      ...?WebLibrary.savedModelProfile(),
      'protocol': selected.config.protocol.name,
      'base_url': selected.config.endpoint,
      'model': selected.config.model,
    });
    await _run(selected.config, selected.scope);
  }

  String _scopeLabel(String scope) => PreparationScope.parse(scope).label;

  Future<void> _clear() async {
    if (_running || _starting || _clearing) {
      _message('请等待当前整理操作结束后再清除。');
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('清除这本书的网页整理？'),
        content: const Text('人物线索、前情、关系和整理记录会从当前浏览器移除；原书及阅读进度保留。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (_running || _starting || _clearing) return;
    _clearing = true;
    try {
      final bool granted = await _withBrowserLock(() async {
        final bool acquired = await widget.library.acquirePreparationLease(
          widget.book.meta.id,
          _owner,
        );
        if (!acquired) {
          _message('另一个标签页正在整理，已取消清除。');
          return;
        }
        _leaseHeld = true;
        _leaseLost = false;
        try {
          await widget.library.clearPreparation(widget.book.meta.id);
          if (!mounted) return;
          setState(() {
            _results.clear();
            _events.clear();
            _phase = 'idle';
            _lastError = null;
            _inFlight = null;
            _scope = 'first';
          });
        } finally {
          await _releaseLease();
        }
      });
      if (!granted) {
        _message('另一个标签页正在整理这本书，已取消清除。');
      }
    } on Object {
      _message('清除失败，请检查浏览器存储空间。');
    } finally {
      _clearing = false;
      if (mounted) setState(() {});
    }
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  String _diagnosticErrorCode(String message) {
    final String value = message.toLowerCase();
    if (RegExp(r'\b(401|unauthorized)\b').hasMatch(value)) return 'auth_401';
    if (RegExp(r'\b(402|payment|required|balance)\b').hasMatch(value)) {
      return 'payment_or_balance';
    }
    if (RegExp(r'\b(403|forbidden)\b').hasMatch(value)) return 'forbidden_403';
    if (RegExp(r'\b(429|rate.limit)\b').hasMatch(value)) return 'rate_limit';
    if (value.contains('cors') || value.contains('跨域')) return 'cors';
    if (value.contains('timeout') || value.contains('超时')) return 'timeout';
    if (value.contains('引文') || value.contains('格式')) {
      return 'invalid_model_output';
    }
    if (value.contains('整理锁')) return 'lease';
    if (value.contains('存储') || value.contains('保存')) return 'storage';
    if (value.contains('网络') || value.contains('连接')) return 'network';
    return 'other';
  }

  Json _diagnosticEvent(Json event) {
    final String rawKind = '${event['kind'] ?? ''}';
    final String kind =
        const <String>{
          'start',
          'request',
          'done',
          'warning',
          'pause',
          'complete',
          'error',
        }.contains(rawKind)
        ? rawKind
        : 'unknown';
    final String message = '${event['message'] ?? ''}';
    final RegExpMatch? position = RegExp(
      r'第 (\d+) 章 · 片段 (\d+)',
    ).firstMatch(message);
    return <String, Object?>{
      'at': (event['at'] as num?)?.toInt(),
      'kind': kind,
      if (position != null) ...<String, Object?>{
        'chapter': int.tryParse(position.group(1) ?? ''),
        'chunk': int.tryParse(position.group(2) ?? ''),
      },
      if (kind == 'error') 'error_code': _diagnosticErrorCode(message),
    };
  }

  void _exportDiagnostics() {
    try {
      final String bookHash = sha256
          .convert(utf8.encode(widget.book.meta.id))
          .toString();
      final (int prompt, int completion, int calls) = _usage();
      final Json data = <String, Object?>{
        'format': 'thusfar-web-ai-diagnostic-v1',
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'book_id_sha256': bookHash,
        'scope': _scope,
        'phase': _running ? 'running' : _phase,
        'target_count': _targets(_scope).length,
        'completed_count': _done(_targets(_scope)),
        'has_unconfirmed_request':
            _inFlight != null && !_results.containsKey(_inFlight),
        'provider_host': Uri.tryParse(_endpoint)?.host ?? '',
        'model': _model == _officialModel ? _officialModel : '[custom]',
        'saved_prompt_tokens': prompt,
        'saved_completion_tokens': completion,
        'saved_request_count': calls,
        'events': <Json>[
          for (final Json event in _events) _diagnosticEvent(event),
        ],
      };
      final html.Blob blob = html.Blob(<Object>[
        jsonEncode(data),
      ], 'application/json');
      final String url = html.Url.createObjectUrlFromBlob(blob);
      final html.AnchorElement anchor = html.AnchorElement(href: url)
        ..download = '页读-整理诊断-${bookHash.substring(0, 12)}.json';
      html.document.body?.append(anchor);
      anchor.click();
      anchor.remove();
      Future<void>.delayed(
        const Duration(seconds: 2),
        () => html.Url.revokeObjectUrl(url),
      );
      _message('整理诊断已导出；只有进度、时间、错误类型与用量，不含书籍正文或密钥。');
    } on Object {
      _message('导出整理诊断失败，请检查浏览器下载权限。');
    }
  }

  @override
  void dispose() {
    _routeExited = true;
    _stopRequested = true;
    _observeTimer?.cancel();
    _activityDisposed = true;
    _readingActivity.dispose();
    // An in-flight request retains its lease until _runLocked's finally.
    // During setup/clear, those async paths also release it on completion.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final List<WebAiChunk> targets = _targets(_scope);
    final int done = _done(targets);
    final bool otherTab = !_running && _otherLeaseActive;
    return PopScope<void>(
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) return;
        // A popped route stays mounted through its exit animation. Cancel at
        // the navigation event, before dispose, but let in-flight results save.
        _routeExited = true;
        _stopRequested = true;
      },
      child: DefaultTabController(
        length: 4,
        child: Scaffold(
          backgroundColor: t.paper,
          appBar: AppBar(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(widget.focusPersonName == null ? '浏览器整理草稿' : '人物详情'),
                Text(
                  widget.book.meta.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: t.ink2),
                ),
              ],
            ),
            actions: <Widget>[
              PopupMenuButton<String>(
                tooltip: '整理选项',
                onSelected: (String value) {
                  if (value == 'clear') unawaited(_clear());
                  if (value == 'export') _exportDiagnostics();
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(
                    value: 'export',
                    child: Text('导出整理诊断'),
                  ),
                  PopupMenuItem<String>(
                    value: 'clear',
                    enabled: !_running && !_starting && !_clearing && !otherTab,
                    child: const Text('清除本书网页整理'),
                  ),
                ],
              ),
            ],
          ),
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1080),
              child: NestedScrollView(
                headerSliverBuilder:
                    (BuildContext context, bool innerScrolled) => <Widget>[
                      if (widget.focusPersonName == null)
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
                          sliver: SliverToBoxAdapter(
                            child: _overview(t, done, targets.length, otherTab),
                          ),
                        ),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                        sliver: SliverToBoxAdapter(child: _visibilityNote(t)),
                      ),
                      SliverToBoxAdapter(
                        child: ColoredBox(
                          color: t.paper,
                          child: TabBar(
                            isScrollable: true,
                            tabAlignment: TabAlignment.start,
                            labelColor: t.zhu,
                            unselectedLabelColor: t.ink2,
                            indicatorColor: t.zhu,
                            tabs: const <Tab>[
                              Tab(text: '人物'),
                              Tab(text: '前情'),
                              Tab(text: '关系'),
                              Tab(text: '记录'),
                            ],
                          ),
                        ),
                      ),
                    ],
                body: TabBarView(
                  children: <Widget>[
                    widget.focusPersonName == null
                        ? _characterTab(t)
                        : _focusedPersonTab(t),
                    _summaryTab(t),
                    _relationshipTab(t),
                    _logTab(t),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _overview(Tokens t, int done, int total, bool otherTab) {
    final String phase = _running
        ? (_stopRequested ? '正在暂停，已完成的内容会保留' : '正在整理')
        : _starting || _clearing
        ? '正在核对本地整理状态'
        : otherTab
        ? '另一标签页正在整理'
        : _phase == 'running'
        ? '网页已关闭或刷新，等待你手动继续'
        : switch (_phase) {
            'complete' => '所选范围已完成',
            'paused' => '已暂停',
            'error' => '遇到问题',
            _ => '尚未整理',
          };
    final (int prompt, int completion, int calls) = _usage();
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: t.sheet,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: t.rule),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 10,
            runSpacing: 9,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: t.zhuSoft,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'AI 草稿',
                  style: TextStyle(
                    color: t.zhu,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFamily: sans,
                  ),
                ),
              ),
              Text(
                phase,
                style: TextStyle(
                  color: _phase == 'error' ? t.danger : t.ink,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 13),
          Text(
            '$done / $total 段 · ${_scopeLabel(_scope)}',
            style: TextStyle(
              color: t.ink,
              fontSize: 23,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 9),
          LinearProgressIndicator(
            value: total <= 0 ? 0 : done / total,
            minHeight: 7,
            borderRadius: BorderRadius.circular(9),
            backgroundColor: t.rule,
            color: t.zhu,
          ),
          const SizedBox(height: 9),
          Text(
            '全书已整理 ${_results.length} / ${_bodyChunks.length} 段',
            style: TextStyle(fontSize: 12, color: t.ink2),
          ),

          if (_running)
            Text(switch (_requestStage) {
              'saving' => '正在保存整理结果',
              'model' => '正在整理人物和情节',
              _ => '正在准备整理',
            }, style: TextStyle(fontSize: 12, color: t.ink2)),
          const SizedBox(height: 5),
          Text(
            _activeChunk == null
                ? '关闭页面后，整理会暂停'
                : '正在整理第 ${int.parse(_activeChunk!.split(':').first) + 1} 章',
            style: TextStyle(fontSize: 12, color: t.ink2),
          ),
          if (!_running && done == 0 && _phase == 'idle') ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '点击“开始整理”，选择整理范围。',
              style: TextStyle(
                fontSize: 12,
                color: t.ink2,
                height: 1.4,
                fontFamily: serif,
              ),
            ),
          ],
          if (done > 0) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              'AI 整理可能有误，可以对照原文查看。',
              style: TextStyle(
                fontSize: 12,
                color: t.ink2,
                height: 1.4,
                fontFamily: serif,
              ),
            ),
          ],
          if (_inFlight != null &&
              !_running &&
              !_results.containsKey(_inFlight)) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              '上次有一段请求未确认结果；重试这一段可能再次计费。',
              style: TextStyle(color: t.amber, fontSize: 12),
            ),
          ],
          if (_lastError != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(_lastError!, style: TextStyle(color: t.danger, height: 1.4)),
          ],
          if (prompt > 0 || completion > 0 || calls > 0) ...<Widget>[
            const SizedBox(height: 11),
            InfoButton(
              title: '整理用量',
              message: '已保存 $calls 次整理结果。未完成的整理也可能收费，实际费用以服务商账单为准。',
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: <Widget>[
              if (widget.readingBuilder != null)
                OutlinedButton.icon(
                  onPressed: _openingReader ? null : _readWhilePreparing,
                  icon: const Icon(Icons.menu_book_outlined),
                  label: const Text('边读边整理'),
                ),
              if (_running)
                OutlinedButton.icon(
                  onPressed: _stopRequested ? null : _pause,
                  icon: const Icon(Icons.pause_circle_outline),
                  label: Text(_stopRequested ? '暂停中…' : '暂停整理'),
                )
              else
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: t.ink,
                    foregroundColor: t.sheet,
                    textStyle: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      fontFamily: sans,
                    ),
                  ),
                  onPressed: _loading || _starting || _clearing || otherTab
                      ? null
                      : _configureAndStart,
                  icon: Icon(
                    done == 0 ? Icons.auto_awesome : Icons.play_arrow,
                    color: t.sheet,
                  ),
                  label: Text(
                    done == 0 ? '开始整理' : '继续或调整范围',
                    style: TextStyle(color: t.sheet, fontFamily: sans),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  (int, int, int) _usage() {
    int prompt = 0, completion = 0, calls = 0;
    for (final Json record in _results.values) {
      final Json result = _asJson(record['result']);
      prompt += (result['prompt_tokens'] as num?)?.toInt() ?? 0;
      completion += (result['completion_tokens'] as num?)?.toInt() ?? 0;
      calls += (result['request_count'] as num?)?.toInt() ?? 0;
    }
    return (prompt, completion, calls);
  }

  Widget _visibilityNote(Tokens t) {
    final int hidden = _results.values.where((Json record) {
      final int chapter = (record['chapter_index'] as num?)?.toInt() ?? 0;
      return chapter > widget.reading.chapter ||
          (chapter == widget.reading.chapter && !_revealCurrentChapter);
    }).length;
    final int nativeHidden = _nativeLog.where((Json row) {
      final int? position = (row['p'] as num?)?.toInt();
      return position != null &&
          position > _nativeCutoff &&
          const <String>{'profile', 'recap', 'rel'}.contains(row['t']);
    }).length;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: t.qingSoft,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Wrap(
        spacing: 10,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Icon(Icons.visibility_off_outlined, size: 18, color: t.qing),
          Text(
            widget.cutoffOffset == null
                ? '阅读保护：当前在第 ${widget.reading.chapter + 1} 章，本章和以后默认隐藏${hidden > 0 ? ' · 已隐藏 $hidden 段网页草稿' : ''}${nativeHidden > 0 ? ' · $nativeHidden 条安装版资料' : ''}'
                : '阅读保护：安装版资料截至当前页；网页草稿只显示读完的章节${hidden > 0 ? ' · 已隐藏 $hidden 段网页草稿' : ''}${nativeHidden > 0 ? ' · $nativeHidden 条后续资料' : ''}',
            style: TextStyle(fontSize: 12, color: t.qing, fontFamily: serif),
          ),
          if (_hasCurrentResults && widget.focusPersonName == null)
            TextButton(
              onPressed: _toggleCurrentChapter,
              child: Text(
                _revealCurrentChapter ? '收起当前章' : '查看当前章整理（可能包含本章后续内容）',
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _toggleCurrentChapter() async {
    if (_revealCurrentChapter) {
      setState(() => _revealCurrentChapter = false);
      return;
    }
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('查看当前章的全部整理？'),
        content: const Text('当前章后半段的线索可能提前揭示情节。确定后只在本次打开的页面中显示。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('暂不查看'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('仍要查看'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      setState(() => _revealCurrentChapter = true);
    }
  }

  bool get _hasCurrentResults {
    if (_results.values.any(
      (Json record) =>
          (record['chapter_index'] as num?)?.toInt() == widget.reading.chapter,
    )) {
      return true;
    }
    final Json current = widget.book.chapters[widget.reading.chapter];
    final int start = (current['o0'] as num?)?.toInt() ?? 0;
    final int end = (current['o1'] as num?)?.toInt() ?? start;
    return _nativeLog.any((Json row) {
      final int? position = (row['p'] as num?)?.toInt();
      return position != null &&
          position >= start &&
          position <= end &&
          const <String>{'profile', 'recap', 'rel'}.contains(row['t']);
    });
  }

  List<Json> get _nativeLog {
    final Object? raw = widget.book.nativeBackup?['kg'];
    if (raw is! Json || raw['log'] is! List) return const <Json>[];
    return <Json>[
      for (final Object? row in raw['log'] as List<Object?>)
        if (row is Json) row,
    ];
  }

  int get _nativeCutoff => nativeCutoff(
    widget.book.chapters[widget.reading.chapter],
    pageEnd: widget.cutoffOffset,
    revealCurrentChapter: _revealCurrentChapter,
  );

  int _nativeChapterAt(int position) =>
      nativeChapterAt(widget.book.chapters, position);

  Iterable<Json> get _visibleNativeRecords =>
      visibleNativeRecords(_nativeLog, _nativeCutoff);

  Iterable<(int, int, Json)> get _visibleResults sync* {
    final List<(int, int, Json)> sorted = <(int, int, Json)>[];
    for (final Json record in _results.values) {
      final int chapter = (record['chapter_index'] as num?)?.toInt() ?? -1;
      final int chunk = (record['chunk_index'] as num?)?.toInt() ?? -1;
      if (chapter < 0 || chunk < 0 || chapter > widget.reading.chapter) {
        continue;
      }
      if (chapter == widget.reading.chapter && !_revealCurrentChapter) continue;
      sorted.add((chapter, chunk, _asJson(record['result'])));
    }
    sorted.sort((a, b) {
      final int byChapter = a.$1.compareTo(b.$1);
      return byChapter == 0 ? a.$2.compareTo(b.$2) : byChapter;
    });
    yield* sorted;
  }

  Json _asJson(Object? value) =>
      value is Map<String, Object?> ? value : <String, Object?>{};

  String _chapterLabel(int index) => webChapterTitle(
    widget.book.chapters,
    index,
    widget.reading.chapter,
    checkPending: titleCheckPending(widget.book.nativeBackup?['status']),
  );

  Widget _empty(Tokens t, IconData icon, String title, String subtitle) =>
      Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 42, color: t.ink3),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: t.ink,
                  fontSize: 20,
                  fontFamily: display,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(color: t.ink2, height: 1.5),
              ),
            ],
          ),
        ),
      );

  Widget _evidence(Tokens t, String quote) => Container(
    margin: const EdgeInsets.only(top: 10),
    padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
    decoration: BoxDecoration(
      color: t.paper,
      border: Border(left: BorderSide(color: t.zhu, width: 2)),
    ),
    child: Text(
      '原文  $quote',
      style: TextStyle(color: t.ink2, fontFamily: serif, height: 1.5),
    ),
  );

  Widget _card(Tokens t, Widget child) => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: t.sheet,
      border: Border.all(color: t.rule),
      borderRadius: BorderRadius.circular(17),
    ),
    child: child,
  );

  /// A tap on a name opens this person first. Fold the imported graph at the
  /// exact visible text end instead of using the chapter's saved progress:
  /// reading progress may be ahead of the page currently on screen.
  Widget _focusedPersonTab(Tokens t) {
    final String requested = widget.focusPersonName!.trim();
    knowledge.World? world;
    try {
      if (_nativeLog.isNotEmpty) {
        world = knowledge.fold(_nativeLog, _nativeCutoff);
      }
    } on Object {
      // Optional imported graph data must never prevent opening the reader.
    }
    knowledge.Person? person;
    final String? requestedId = widget.focusPersonId;
    if (world != null && requestedId != null) {
      person = world.person(requestedId);
    }
    if (world != null && person == null) {
      for (final Json raw in world.people.values) {
        final knowledge.Person candidate = knowledge.Person(raw);
        if (candidate.name == requested ||
            candidate.aliases.contains(requested)) {
          person = candidate;
          break;
        }
      }
    }
    final String name = person?.name ?? requested;
    final Set<String> knownNames = <String>{
      requested,
      if (person != null) person.name,
      if (person != null) ...person.aliases,
    };

    final List<Json> verifiedProfiles = <Json>[
      if (person != null && world != null)
        for (final Json row in _visibleNativeRecords)
          if (row['t'] == 'profile' &&
              row['kind'] == 'chapter' &&
              row['id'] is String &&
              world.canon(row['id'] as String) == person.id &&
              _asJson(row['chk'])['verdict'] == 'ok' &&
              '${row['bio'] ?? ''}'.trim().isNotEmpty)
            row,
    ];
    final List<(int, Json)> draftFacts = <(int, Json)>[];
    for (final (int chapter, int _, Json result) in _visibleResults) {
      // A browser chunk can span an unread part of the current chapter.
      // Evidence validation alone cannot make that chunk page-safe.
      if (chapter >= widget.reading.chapter) continue;
      final Object? facts = result['character_facts'];
      if (facts is! List) continue;
      for (final Object? raw in facts) {
        final Json fact = _asJson(raw);
        if (knownNames.contains('${fact['name'] ?? ''}'.trim())) {
          draftFacts.add((chapter, fact));
        }
      }
    }
    final List<Json> nativeRelationships = person != null && world != null
        ? world.relsOf(person.id)
        : const <Json>[];
    final List<Json> events = person?.events ?? const <Json>[];
    final Json? latestProfile = verifiedProfiles.isEmpty
        ? null
        : verifiedProfiles.last;
    final String introduction = '${person?.raw['intro'] ?? ''}'.trim();
    final List<Widget> cards = <Widget>[
      _card(
        t,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              name,
              style: TextStyle(fontFamily: display, fontSize: 27, color: t.ink),
            ),
            const SizedBox(height: 7),
            Text(
              '只显示截至当前阅读位置的资料',
              style: TextStyle(color: t.ink2, fontSize: 13),
            ),
            if (person != null && person.aliases.isNotEmpty) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '又称 ${person.aliases.join('、')}',
                style: TextStyle(color: t.ink2),
              ),
            ],
            if (person != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '已读出场 ${person.mentions} 次',
                style: TextStyle(color: t.ink3, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      if (latestProfile != null)
        _card(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('已核对人物小传', style: TextStyle(color: t.qing, fontSize: 13)),
              const SizedBox(height: 10),
              Text(
                '${latestProfile['bio']}',
                style: TextStyle(color: t.ink, height: 1.65, fontFamily: serif),
              ),
              const SizedBox(height: 8),
              Text(
                '截至 ${_chapterLabel(_nativeChapterAt((latestProfile['p'] as num).toInt()))}',
                style: TextStyle(color: t.ink3, fontSize: 12),
              ),
            ],
          ),
        )
      else
        _card(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '截至这一页暂无核对通过的人物小传',
                style: TextStyle(color: t.ink, fontSize: 16),
              ),
              if (introduction.isNotEmpty) ...<Widget>[
                const SizedBox(height: 9),
                Text(
                  introduction,
                  style: TextStyle(color: t.ink2, height: 1.55),
                ),
                const SizedBox(height: 5),
                Text('已读人物线索', style: TextStyle(color: t.ink3, fontSize: 12)),
              ],
            ],
          ),
        ),
      if (nativeRelationships.isNotEmpty)
        _card(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('已读人物关系', style: TextStyle(color: t.ink, fontSize: 18)),
              const SizedBox(height: 8),
              for (final Json relation in nativeRelationships.take(12))
                if (world?.person('${relation['other'] ?? ''}')
                    case final other?)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${other.name} · ${relation['desc'] ?? relation['role'] ?? '有关联'}',
                      style: TextStyle(color: t.ink2, height: 1.5),
                    ),
                  ),
            ],
          ),
        ),
      if (events.isNotEmpty)
        _card(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('已读经历', style: TextStyle(color: t.ink, fontSize: 18)),
              const SizedBox(height: 8),
              for (final Json event in events.reversed.take(12))
                if ('${event['text'] ?? ''}'.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '${event['text']}',
                      style: TextStyle(color: t.ink2, height: 1.5),
                    ),
                  ),
            ],
          ),
        ),
      if (draftFacts.isNotEmpty)
        _card(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('网页 AI 草稿 · 尚未核对', style: TextStyle(color: t.ink3)),
              const SizedBox(height: 8),
              for (final (int chapter, Json fact) in draftFacts.reversed.take(
                8,
              ))
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '${fact['fact'] ?? ''}',
                        style: TextStyle(color: t.ink, height: 1.5),
                      ),
                      _evidence(t, '${fact['evidence'] ?? ''}'),
                      const SizedBox(height: 5),
                      Text(
                        _chapterLabel(chapter),
                        style: TextStyle(color: t.ink3, fontSize: 12),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
    ];
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
      itemCount: cards.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (BuildContext context, int index) => cards[index],
    );
  }

  Widget _characterTab(Tokens t) {
    final Map<String, String> nativeNames = <String, String>{};
    final Map<String, String> nativeIntros = <String, String>{};
    final Map<String, List<Json>> nativeProfiles = <String, List<Json>>{};
    for (final Json row in _visibleNativeRecords) {
      final String id = '${row['id'] ?? ''}';
      if (id.isEmpty) continue;
      if (row['t'] == 'person' || row['t'] == 'name') {
        final String name = '${row['name'] ?? ''}'.trim();
        if (name.isNotEmpty) nativeNames[id] = name;
        if (row['t'] == 'person' && '${row['intro'] ?? ''}'.trim().isNotEmpty) {
          nativeIntros[id] = '${row['intro']}';
        }
      } else if (row['t'] == 'profile' &&
          row['kind'] == 'chapter' &&
          _asJson(row['chk'])['verdict'] == 'ok' &&
          '${row['bio'] ?? ''}'.trim().isNotEmpty) {
        nativeProfiles.putIfAbsent(id, () => <Json>[]).add(row);
      }
    }
    final Map<String, List<(int, Json)>> people = <String, List<(int, Json)>>{};
    for (final (int chapter, int _, Json result) in _visibleResults) {
      final Object? facts = result['character_facts'];
      if (facts is! List) continue;
      for (final Object? raw in facts) {
        final Json fact = _asJson(raw);
        final String name = '${fact['name'] ?? ''}'.trim();
        if (name.isNotEmpty) {
          people.putIfAbsent(name, () => <(int, Json)>[]).add((chapter, fact));
        }
      }
    }
    if (people.isEmpty && nativeNames.isEmpty) {
      return _empty(
        t,
        Icons.people_outline,
        '还没有可看的已读人物线索',
        '安装版已核对的人物小传与网页整理草稿会在已读范围内显示。当前章默认隐藏。',
      );
    }
    final List<Widget> cards = <Widget>[];
    final List<String> nativeIds = nativeNames.keys.toList()
      ..sort(
        (String a, String b) => nativeNames[a]!.compareTo(nativeNames[b]!),
      );
    for (final String id in nativeIds) {
      final List<Json> profiles = nativeProfiles[id] ?? const <Json>[];
      cards.add(
        _card(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                nativeNames[id]!,
                style: TextStyle(
                  fontFamily: display,
                  fontSize: 24,
                  color: t.ink,
                ),
              ),
              const SizedBox(height: 5),
              Text('安装版人物资料', style: TextStyle(fontSize: 12, color: t.ink3)),
              if (nativeIntros[id] != null) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  nativeIntros[id]!,
                  style: TextStyle(color: t.ink, height: 1.5),
                ),
              ],
              for (final Json profile in profiles) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  '${profile['bio']}',
                  style: TextStyle(color: t.ink, height: 1.55),
                ),
                const SizedBox(height: 6),
                Text(
                  '已核对小传 · ${_chapterLabel(_nativeChapterAt((profile['p'] as num).toInt()))}',
                  style: TextStyle(fontSize: 12, color: t.qing),
                ),
              ],
            ],
          ),
        ),
      );
    }
    final List<String> names = people.keys.toList()..sort();
    for (final String name in names) {
      final List<(int, Json)> facts = people[name]!;
      cards.add(
        _card(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                name,
                style: TextStyle(
                  fontFamily: display,
                  fontSize: 24,
                  color: t.ink,
                ),
              ),
              Text('网页 AI 草稿', style: TextStyle(fontSize: 12, color: t.ink3)),
              const SizedBox(height: 11),
              for (final (int chapter, Json fact) in facts) ...<Widget>[
                Text(
                  '${fact['fact'] ?? ''}',
                  style: TextStyle(color: t.ink, height: 1.5),
                ),
                _evidence(t, '${fact['evidence'] ?? ''}'),
                Padding(
                  padding: const EdgeInsets.only(top: 7, bottom: 13),
                  child: Text(
                    _chapterLabel(chapter),
                    style: TextStyle(fontSize: 12, color: t.ink3),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
      itemCount: cards.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (BuildContext context, int index) => cards[index],
    );
  }

  Widget _summaryTab(Tokens t) {
    final List<Json> nativeSummaries = <Json>[
      for (final Json row in _visibleNativeRecords)
        if (row['t'] == 'recap' && '${row['text'] ?? ''}'.trim().isNotEmpty)
          row,
    ];
    final List<(int, Json)> summaries = <(int, Json)>[];
    for (final (int chapter, int _, Json result) in _visibleResults) {
      if ('${result['summary'] ?? ''}'.trim().isNotEmpty) {
        summaries.add((chapter, result));
      }
    }
    if (summaries.isEmpty && nativeSummaries.isEmpty) {
      return _empty(
        t,
        Icons.menu_book_outlined,
        '还没有可看的已读前情',
        '安装版前情与网页整理草稿只展示已读完的章节。',
      );
    }
    final List<Widget> cards = <Widget>[
      for (final Json row in nativeSummaries)
        _card(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '安装版前情 · ${_chapterLabel(_nativeChapterAt((row['p'] as num).toInt()))}',
                style: TextStyle(color: t.ink2, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Text(
                '${row['text']}',
                style: TextStyle(color: t.ink, height: 1.6, fontSize: 16),
              ),
            ],
          ),
        ),
      for (final (int chapter, Json result) in summaries)
        _card(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '网页 AI 草稿 · ${_chapterLabel(chapter)}',
                style: TextStyle(color: t.ink2, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Text(
                '${result['summary']}',
                style: TextStyle(color: t.ink, height: 1.6, fontSize: 16),
              ),
              _evidence(t, '${result['summary_evidence'] ?? ''}'),
            ],
          ),
        ),
    ];
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
      itemCount: cards.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (BuildContext context, int index) => cards[index],
    );
  }

  Widget _relationshipTab(Tokens t) {
    final List<Json> native = _visibleNativeRecords.toList();
    final Map<String, String> nativeNames = <String, String>{};
    for (final Json row in native) {
      if ((row['t'] == 'person' || row['t'] == 'name') &&
          row['id'] is String &&
          row['name'] is String) {
        nativeNames[row['id'] as String] = row['name'] as String;
      }
    }
    final List<Json> nativeLinks = <Json>[
      for (final Json row in native)
        if (row['t'] == 'rel' &&
            nativeNames.containsKey(row['a']) &&
            nativeNames.containsKey(row['b']) &&
            '${row['desc'] ?? ''}'.trim().isNotEmpty)
          row,
    ];
    final List<(int, Json)> links = <(int, Json)>[];
    for (final (int chapter, int _, Json result) in _visibleResults) {
      final Object? rows = result['relationships'];
      if (rows is! List) continue;
      for (final Object? raw in rows) {
        final Json link = _asJson(raw);
        if (link.isNotEmpty) links.add((chapter, link));
      }
    }
    if (links.isEmpty && nativeLinks.isEmpty) {
      return _empty(
        t,
        Icons.hub_outlined,
        '还没有可看的已读人物关系',
        '人物关系只展示已读范围内的安装版资料与网页草稿；未来章节默认隐藏。',
      );
    }
    final List<Widget> cards = <Widget>[
      for (final Json link in nativeLinks)
        _card(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '${nativeNames[link['a']]}  ·  ${nativeNames[link['b']]}',
                style: TextStyle(
                  fontFamily: display,
                  fontSize: 21,
                  color: t.ink,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${link['desc']}',
                style: TextStyle(color: t.ink, height: 1.5),
              ),
              const SizedBox(height: 8),
              Text(
                '安装版人物关系 · ${_chapterLabel(_nativeChapterAt((link['p'] as num).toInt()))}',
                style: TextStyle(color: t.ink3, fontSize: 12),
              ),
            ],
          ),
        ),
      for (final (int chapter, Json link) in links)
        _card(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '${link['from'] ?? ''}  ·  ${link['to'] ?? ''}',
                style: TextStyle(
                  fontFamily: display,
                  fontSize: 21,
                  color: t.ink,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${link['relationship'] ?? ''}',
                style: TextStyle(color: t.ink, height: 1.5),
              ),
              _evidence(t, '${link['evidence'] ?? ''}'),
              const SizedBox(height: 8),
              Text(
                '网页 AI 草稿 · ${_chapterLabel(chapter)}',
                style: TextStyle(color: t.ink3, fontSize: 12),
              ),
            ],
          ),
        ),
    ];
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
      itemCount: cards.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (BuildContext context, int index) => cards[index],
    );
  }

  Widget _logTab(Tokens t) {
    if (_events.isEmpty) {
      return _empty(
        t,
        Icons.receipt_long_outlined,
        '尚无整理记录',
        '开始整理后，可在这里查看进展。',
      );
    }
    final List<Json> events = _events.reversed.toList();
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 32),
      itemCount: events.length,
      separatorBuilder: (_, _) => Divider(color: t.rule, height: 1),
      itemBuilder: (BuildContext context, int index) {
        final Json event = events[index];
        final int at = (event['at'] as num?)?.toInt() ?? 0;
        final DateTime time = DateTime.fromMillisecondsSinceEpoch(at);
        final String label =
            '${time.month}/${time.day} '
            '${time.hour.toString().padLeft(2, '0')}:'
            '${time.minute.toString().padLeft(2, '0')}:'
            '${time.second.toString().padLeft(2, '0')}';
        final bool error = event['kind'] == 'error';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(label, style: TextStyle(color: t.ink3, fontSize: 12)),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  '${event['message'] ?? ''}',
                  style: TextStyle(
                    color: error ? t.danger : t.ink2,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RunChoice {
  const _RunChoice(this.config, this.scope);
  final WebAiConfig config;
  final String scope;
}
