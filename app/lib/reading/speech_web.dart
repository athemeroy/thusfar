// Uses the browser's installed speech service. No API key or paid API is used.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:async';
import 'dart:html' as html;

import 'speech_backend.dart';

SpeechBackend createSpeechBackend() => _BrowserSpeech();

class _BrowserSpeech implements SpeechBackend {
  final List<StreamSubscription<html.Event>> _events =
      <StreamSubscription<html.Event>>[];
  html.SpeechSynthesisUtterance? _utterance;
  bool _disposed = false;

  @override
  Future<SpeechAvailability> initialize() async {
    try {
      if (html.window.speechSynthesis == null) {
        return const SpeechAvailability(
          false,
          message: '此浏览器暂不支持听书，请换用支持系统语音的浏览器。',
        );
      }
      // Some browsers discover voices only after this first call. A default
      // voice can still work when getVoices has not returned its list yet.
      html.window.speechSynthesis!.getVoices();
      return const SpeechAvailability(true);
    } on Object {
      return const SpeechAvailability(false, message: '浏览器语音暂不可用，请检查设备的语音设置。');
    }
  }

  @override
  Future<void> speak(
    String text, {
    required double rate,
    required String language,
    required void Function(SpeechEvent) onEvent,
  }) async {
    if (_disposed) return;
    _clearListeners();
    final html.SpeechSynthesisUtterance utterance =
        html.SpeechSynthesisUtterance(text)
          ..lang = language
          ..rate = rate;
    _utterance = utterance;
    final List<html.SpeechSynthesisVoice> voices = html.window.speechSynthesis!
        .getVoices()
        .where(
          (html.SpeechSynthesisVoice voice) =>
              voice.lang?.toLowerCase().startsWith(language.substring(0, 2)) ??
              false,
        )
        .toList();
    if (voices.isNotEmpty) {
      utterance.voice = voices.firstWhere(
        (html.SpeechSynthesisVoice voice) => voice.localService == true,
        orElse: () => voices.first,
      );
    }
    bool current() => !_disposed && identical(utterance, _utterance);
    _events.addAll(<StreamSubscription<html.Event>>[
      utterance.onStart.listen((html.SpeechSynthesisEvent _) {
        if (current()) onEvent(const SpeechEvent(SpeechEventType.start));
      }),
      utterance.onBoundary.listen((html.SpeechSynthesisEvent event) {
        if (current()) {
          onEvent(
            SpeechEvent(SpeechEventType.boundary, offset: event.charIndex ?? 0),
          );
        }
      }),
      utterance.onEnd.listen((html.SpeechSynthesisEvent _) {
        if (current()) {
          onEvent(SpeechEvent(SpeechEventType.done, offset: text.length));
        }
      }),
      utterance.onError.listen((html.Event _) {
        if (current()) {
          onEvent(
            const SpeechEvent(
              SpeechEventType.error,
              message: '未能朗读，请检查系统语音数据，或换用其他浏览器。',
            ),
          );
        }
      }),
    ]);
    try {
      html.window.speechSynthesis!.speak(utterance);
    } on Object {
      if (current()) {
        onEvent(
          const SpeechEvent(
            SpeechEventType.error,
            message: '浏览器未能启动语音，请再次点按播放。',
          ),
        );
      }
    }
  }

  void _clearListeners() {
    for (final StreamSubscription<html.Event> event in _events) {
      unawaited(event.cancel());
    }
    _events.clear();
  }

  @override
  Future<void> stop() async {
    final bool ownedSpeech = _utterance != null;
    _utterance = null;
    _clearListeners();
    if (ownedSpeech) html.window.speechSynthesis?.cancel();
  }

  @override
  Future<void> openSettings() async {}

  @override
  void dispose() {
    unawaited(stop());
    _disposed = true;
  }
}
