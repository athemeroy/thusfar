import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/reading/read_aloud.dart';
import 'package:thusfar_app/reading/speech_backend.dart';

class _Voice implements SpeechBackend {
  SpeechAvailability availability = const SpeechAvailability(true);
  final List<String> spoken = <String>[];
  final List<void Function(SpeechEvent)> listeners =
      <void Function(SpeechEvent)>[];
  int stops = 0;
  bool disposed = false;

  @override
  Future<SpeechAvailability> initialize() async => availability;

  @override
  Future<void> speak(
    String text, {
    required double rate,
    required String language,
    required void Function(SpeechEvent) onEvent,
  }) async {
    spoken.add(text);
    listeners.add(onEvent);
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> openSettings() async {}
  @override
  void dispose() {
    disposed = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('speech chunks preserve source offsets and surrogate pairs', () {
    final String text = '${'字' * 179}😀。下一句！';
    final List<ReadAloudPassage> chunks = splitReadAloudPassages(
      <ReadAloudPassage>[ReadAloudPassage(text: text, start: 37)],
    );
    expect(chunks.map((ReadAloudPassage p) => p.text).join(), text);
    int at = 37;
    for (final ReadAloudPassage part in chunks) {
      expect(part.start, at);
      expect(part.text.codeUnitAt(0), isNot(inInclusiveRange(0xdc00, 0xdfff)));
      expect(
        part.text.codeUnitAt(part.text.length - 1),
        isNot(inInclusiveRange(0xd800, 0xdbff)),
      );
      at = part.end;
    }
  });

  testWidgets('only heard boundaries advance progress; pause resumes safely', (
    WidgetTester tester,
  ) async {
    final _Voice voice = _Voice();
    final ReadAloudController controller = ReadAloudController(backend: voice);
    final List<int> progress = <int>[];
    await controller.play(const <ReadAloudPassage>[
      ReadAloudPassage(text: '你好世界。下一句。', start: 100),
    ], onProgress: progress.add);
    expect(voice.spoken, <String>['你好世界。']);
    voice.listeners.first(const SpeechEvent(SpeechEventType.start));
    expect(progress, isEmpty);
    voice.listeners.first(
      const SpeechEvent(SpeechEventType.boundary, offset: 2),
    );
    expect(progress, <int>[102]);
    await controller.pause();
    voice.listeners.first(const SpeechEvent(SpeechEventType.done));
    expect(progress, <int>[102]);
    await controller.resume();
    expect(voice.spoken.last, '世界。');
    voice.listeners.last(const SpeechEvent(SpeechEventType.done));
    await tester.pump();
    expect(progress.last, 105);
    expect(voice.spoken.last, '下一句。');
    await controller.stop();
    voice.listeners.last(const SpeechEvent(SpeechEventType.done));
    expect(progress.last, 105);
    expect(controller.state, ReadAloudState.stopped);
    controller.dispose();
  });

  testWidgets('timer stops speech and rejects late progress', (
    WidgetTester tester,
  ) async {
    final _Voice voice = _Voice();
    final ReadAloudController controller = ReadAloudController(backend: voice);
    final List<int> progress = <int>[];
    controller.setSleepTimer(const Duration(seconds: 5));
    await controller.play(const <ReadAloudPassage>[
      ReadAloudPassage(text: '仍在朗读的一句话。', start: 0),
    ], onProgress: progress.add);
    voice.listeners.last(const SpeechEvent(SpeechEventType.start));
    await tester.pump(const Duration(seconds: 5));
    expect(controller.state, ReadAloudState.stopped);
    expect(controller.message, '定时已到，听书已停止。');
    voice.listeners.last(const SpeechEvent(SpeechEventType.done));
    expect(progress, isEmpty);
    controller.dispose();
  });

  testWidgets('background pauses and disposal rejects every pending callback', (
    WidgetTester tester,
  ) async {
    final _Voice voice = _Voice();
    final ReadAloudController controller = ReadAloudController(backend: voice);
    final List<int> progress = <int>[];
    await controller.play(const <ReadAloudPassage>[
      ReadAloudPassage(text: '这一句。后一句。', start: 20),
    ], onProgress: progress.add);
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(controller.paused, isTrue);
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(controller.paused, isTrue);
    controller.dispose();
    voice.listeners.last(const SpeechEvent(SpeechEventType.done));
    expect(progress, isEmpty);
    expect(voice.spoken, hasLength(1));
    expect(voice.disposed, isTrue);
  });

  testWidgets('missing speech shows actionable message without playing', (
    WidgetTester tester,
  ) async {
    final _Voice voice = _Voice()
      ..availability = const SpeechAvailability(
        false,
        message: '请下载系统语音。',
        settings: true,
      );
    final ReadAloudController controller = ReadAloudController(backend: voice);
    await controller.play(const <ReadAloudPassage>[
      ReadAloudPassage(text: '正文', start: 0),
    ]);
    expect(controller.state, ReadAloudState.unavailable);
    expect(controller.message, '请下载系统语音。');
    expect(controller.settingsAvailable, isTrue);
    expect(voice.spoken, isEmpty);
    controller.dispose();
  });
}
