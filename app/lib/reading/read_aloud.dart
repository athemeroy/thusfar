import 'dart:async';

import 'package:flutter/widgets.dart';

import 'speech_backend.dart';
import 'speech_stub.dart'
    if (dart.library.io) 'speech_native.dart'
    if (dart.library.html) 'speech_web.dart';

export 'read_aloud_panel.dart' show openReadAloud, ReadAloudPanel;

enum ReadAloudState { idle, preparing, playing, paused, stopped, unavailable }

/// Unmodified source text with its exact UTF-16 offset in the book.
/// Pass only the current chapter, clipped to the requested starting position.
@immutable
class ReadAloudPassage {
  const ReadAloudPassage({required this.text, required this.start});
  final String text;
  final int start;
  int get end => start + text.length;
}

/// Split long paragraphs without losing or changing any source positions.
/// Small utterances also avoid browser speech timeouts on very long paragraphs.
List<ReadAloudPassage> splitReadAloudPassages(
  Iterable<ReadAloudPassage> passages,
) {
  final List<ReadAloudPassage> chunks = <ReadAloudPassage>[];
  for (final ReadAloudPassage passage in passages) {
    if (passage.start < 0) continue;
    final String text = passage.text;
    int from = 0;
    for (int at = 0; at < text.length; at++) {
      final int unit = text.codeUnitAt(at);
      final bool sentenceEnd = const <int>{
        10,
        13,
        33,
        46,
        59,
        63,
        0x3002,
        0xff01,
        0xff1b,
        0xff1f,
      }.contains(unit);
      final bool split =
          sentenceEnd || at - from >= 179 || at == text.length - 1;
      if (!split) continue;
      // Never cut between the two code units of a supplementary character.
      if (unit >= 0xd800 && unit <= 0xdbff && at + 1 < text.length) continue;
      // Keep a closing quotation mark with its sentence. A punctuation-only
      // utterance can fail on engines that have no voice for the fallback locale.
      if (sentenceEnd) {
        while (at + 1 < text.length &&
            const <int>{
              34,
              39,
              0x2019,
              0x201d,
              0x3009,
              0x300b,
              0x300d,
              0x300f,
            }.contains(text.codeUnitAt(at + 1))) {
          at++;
        }
      }
      final String part = text.substring(from, at + 1);
      if (part.trim().isNotEmpty) {
        chunks.add(ReadAloudPassage(text: part, start: passage.start + from));
      }
      from = at + 1;
    }
  }
  return chunks;
}

/// Own one controller per open reader and dispose it when leaving that reader.
/// Backgrounding pauses speech. Returning never restarts it without a tap.
class ReadAloudController extends ChangeNotifier with WidgetsBindingObserver {
  ReadAloudController({SpeechBackend? backend})
    : _backend = backend ?? createSpeechBackend() {
    WidgetsBinding.instance.addObserver(this);
  }

  final SpeechBackend _backend;
  ReadAloudState _state = ReadAloudState.idle;
  ReadAloudState get state => _state;
  double _rate = 1;
  double get rate => _rate;
  String? _message;
  String? get message => _message;
  bool _settingsAvailable = false;
  bool get settingsAvailable => _settingsAvailable;
  bool _available = false;
  bool get available => _available;
  bool _disposed = false;
  Future<void>? _initializing;
  List<ReadAloudPassage> _chunks = const <ReadAloudPassage>[];
  int _index = 0;
  int _withinChunk = 0;
  int _generation = 0;
  int? _heardThrough;
  int? get heardThrough => _heardThrough;
  void Function(int)? _onProgress;
  Timer? _sleepTimer;
  Timer? _sleepTicker;
  Timer? _startTimeout;
  DateTime? _stopAt;
  Duration? _sleepDuration;
  Duration? get sleepDuration => _sleepDuration;
  Duration? get remaining {
    final DateTime? deadline = _stopAt;
    if (deadline == null) return null;
    final Duration duration = deadline.difference(DateTime.now());
    return duration.isNegative ? Duration.zero : duration;
  }

  bool get playing => _state == ReadAloudState.playing;
  bool get paused => _state == ReadAloudState.paused;
  bool get hasSession => _chunks.isNotEmpty && _index < _chunks.length;

  Future<void> initialize() {
    if (_disposed || _available) return Future<void>.value();
    return _initializing ??= _initialize().whenComplete(
      () => _initializing = null,
    );
  }

  Future<void> _initialize() async {
    _state = ReadAloudState.preparing;
    _message = null;
    _notify();
    SpeechAvailability result;
    try {
      result = await _backend.initialize();
    } on Object {
      result = const SpeechAvailability(false, message: '系统语音暂不可用，请稍后重试。');
    }
    if (_disposed) return;
    _available = result.available;
    _settingsAvailable = result.settings;
    _message = result.message;
    if (_state == ReadAloudState.preparing) {
      _state = _available ? ReadAloudState.idle : ReadAloudState.unavailable;
    }
    _notify();
  }

  Future<void> play(
    List<ReadAloudPassage> passages, {
    void Function(int heardThrough)? onProgress,
  }) async {
    if (_disposed) return;
    final int generation = ++_generation;
    _startTimeout?.cancel();
    _cancelSleepTimer();
    await _backend.stop();
    if (_disposed || generation != _generation) return;
    await initialize();
    if (_disposed || generation != _generation || !_available) return;
    _chunks = splitReadAloudPassages(passages);
    _index = 0;
    _withinChunk = 0;
    _heardThrough = null;
    _onProgress = onProgress;
    if (_chunks.isEmpty) {
      _state = ReadAloudState.stopped;
      _message = '此处没有可朗读的正文。';
      _notify();
      return;
    }
    _message = null;
    _state = ReadAloudState.playing;
    _startSleepTimer();
    _notify();
    await _speakCurrent(generation);
  }

  Future<void> _speakCurrent(int generation) async {
    if (_disposed || generation != _generation || !playing) return;
    if (_index >= _chunks.length) {
      unawaited(_backend.stop());
      _state = ReadAloudState.stopped;
      _message = '本章已听完。';
      _cancelSleepTimer();
      _notify();
      return;
    }
    final int index = _index;
    final ReadAloudPassage chunk = _chunks[index];
    final int from = _withinChunk.clamp(0, chunk.text.length);
    final String text = chunk.text.substring(from);
    if (text.trim().isEmpty) {
      _index++;
      _withinChunk = 0;
      await _speakCurrent(generation);
      return;
    }
    // A blocked browser can reject playback without sending an error event.
    // Never leave the player claiming it is talking indefinitely.
    _startTimeout?.cancel();
    _startTimeout = Timer(const Duration(seconds: 12), () {
      if (_disposed ||
          generation != _generation ||
          !playing ||
          _index != index) {
        return;
      }
      unawaited(pause());
      _message = '语音尚未启动，请检查系统语音后重试。';
      _notify();
    });
    try {
      await _backend.speak(
        text,
        rate: _rate,
        language: RegExp(r'[\u3400-\u9fff]').hasMatch(text) ? 'zh-CN' : 'en-US',
        onEvent: (SpeechEvent event) {
          if (_disposed ||
              generation != _generation ||
              !playing ||
              _index != index) {
            return;
          }
          _startTimeout?.cancel();
          switch (event.type) {
            case SpeechEventType.start:
              // Starting a sentence does not mean the sentence has been heard.
              break;
            case SpeechEventType.boundary:
              final int heard = _safeBoundary(text, event.offset);
              _withinChunk = from + heard;
              _reportProgress(chunk.start + _withinChunk);
            case SpeechEventType.done:
              _reportProgress(chunk.end);
              _index++;
              _withinChunk = 0;
              // Do not start a new sentence if the callback navigated away.
              if (!_disposed && generation == _generation && playing) {
                unawaited(_speakCurrent(generation));
              }
            case SpeechEventType.interrupted:
              unawaited(pause());
              _message = '听书已暂停，点按后继续。';
              _notify();
            case SpeechEventType.error:
              unawaited(pause());
              _message = event.message ?? '系统语音暂不可用，请稍后重试。';
              _notify();
          }
        },
      );
    } on Object {
      if (!_disposed && generation == _generation && playing) {
        await pause();
        _message = '系统语音暂不可用，请稍后重试。';
        _notify();
      }
    }
  }

  int _safeBoundary(String text, int offset) {
    int at = offset.clamp(0, text.length);
    if (at > 0 &&
        at < text.length &&
        text.codeUnitAt(at - 1) >= 0xd800 &&
        text.codeUnitAt(at - 1) <= 0xdbff &&
        text.codeUnitAt(at) >= 0xdc00 &&
        text.codeUnitAt(at) <= 0xdfff) {
      at--;
    }
    return at;
  }

  void _reportProgress(int offset) {
    if (_heardThrough != null && offset <= _heardThrough!) return;
    _heardThrough = offset;
    _onProgress?.call(offset);
  }

  Future<void> pause() async {
    if (_disposed || !playing) return;
    _generation++;
    _startTimeout?.cancel();
    _state = ReadAloudState.paused;
    _notify();
    await _backend.stop();
  }

  Future<void> resume() async {
    if (_disposed || !paused || !hasSession) return;
    final int generation = ++_generation;
    _state = ReadAloudState.playing;
    _message = null;
    if (_stopAt == null) _startSleepTimer();
    _notify();
    await _speakCurrent(generation);
  }

  Future<void> stop() async {
    if (_disposed) return;
    _generation++;
    _startTimeout?.cancel();
    _state = ReadAloudState.stopped;
    _chunks = const <ReadAloudPassage>[];
    _onProgress = null;
    _message = null;
    _cancelSleepTimer();
    _notify();
    await _backend.stop();
  }

  Future<void> setRate(double value) async {
    if (_disposed || !value.isFinite) return;
    final double next = value.clamp(.5, 2);
    if (next == _rate) return;
    final bool restart = playing;
    _rate = next;
    _notify();
    if (restart) await pause();
    if (_disposed) return;
    if (restart && paused) await resume();
  }

  void setSleepTimer(Duration? duration) {
    if (_disposed) return;
    _sleepDuration = duration != null && duration > Duration.zero
        ? duration
        : null;
    _cancelSleepTimer();
    if (playing || paused) _startSleepTimer();
    _notify();
  }

  void _startSleepTimer() {
    _cancelSleepTimer();
    final Duration? duration = _sleepDuration;
    if (duration == null) return;
    _stopAt = DateTime.now().add(duration);
    _sleepTimer = Timer(duration, () {
      unawaited(stop());
      _message = '定时已到，听书已停止。';
      _notify();
    });
    _sleepTicker = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _notify(),
    );
  }

  void _cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTicker?.cancel();
    _stopAt = null;
  }

  Future<void> openSettings() => _backend.openSettings();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && playing) unawaited(pause());
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _startTimeout?.cancel();
    _cancelSleepTimer();
    _onProgress = null;
    WidgetsBinding.instance.removeObserver(this);
    _backend.dispose();
    super.dispose();
  }
}
