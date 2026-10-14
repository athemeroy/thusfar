/// Device speech events use UTF-16 offsets, like the reader's source text.
enum SpeechEventType { start, boundary, done, interrupted, error }

class SpeechEvent {
  const SpeechEvent(this.type, {this.offset = 0, this.message});
  final SpeechEventType type;
  final int offset;
  final String? message;
}

class SpeechAvailability {
  const SpeechAvailability(
    this.available, {
    this.message,
    this.settings = false,
  });
  final bool available;
  final String? message;
  final bool settings;
}

abstract interface class SpeechBackend {
  Future<SpeechAvailability> initialize();
  Future<void> speak(
    String text, {
    required double rate,
    required String language,
    required void Function(SpeechEvent) onEvent,
  });
  Future<void> stop();
  Future<void> openSettings();
  void dispose();
}
