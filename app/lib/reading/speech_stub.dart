import 'speech_backend.dart';

SpeechBackend createSpeechBackend() => _UnavailableSpeech();

class _UnavailableSpeech implements SpeechBackend {
  @override
  Future<SpeechAvailability> initialize() async =>
      const SpeechAvailability(false, message: '此设备暂不支持听书，可在安卓版或支持语音的浏览器中使用。');

  @override
  Future<void> speak(
    String text, {
    required double rate,
    required String language,
    required void Function(SpeechEvent) onEvent,
  }) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> openSettings() async {}

  @override
  void dispose() {}
}
