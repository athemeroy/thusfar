@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/ui/theme.dart';
import 'package:thusfar_app/web/web_ai_engine.dart';
import 'package:thusfar_app/web/web_ai_panel.dart';
import 'package:thusfar_app/web/web_model_session.dart';
import 'package:thusfar_app/web/web_storage.dart';

class _Library extends Fake implements WebLibrary {
  final Map<int, Completer<bool>> renewalGates = <int, Completer<bool>>{};
  final List<Json> saves = <Json>[];
  int acquisitions = 0;
  int renewals = 0;
  int releases = 0;
  Json? saved;

  @override
  Future<Json?> loadPreparation(String bookId) async => saved;

  @override
  Future<bool> otherPreparationLeaseActive(String bookId, String owner) async =>
      false;

  @override
  Future<bool> acquirePreparationLease(String bookId, String owner) async {
    acquisitions++;
    return true;
  }

  @override
  Future<bool> renewPreparationLease(String bookId, String owner) async {
    renewals++;
    return renewalGates[renewals]?.future ?? true;
  }

  @override
  Future<void> releasePreparationLease(String bookId, String owner) async {
    releases++;
  }

  @override
  Future<void> savePreparation(String bookId, Json value) async {
    saved = jsonDecode(jsonEncode(value)) as Json;
    saves.add(saved!);
  }
}

class _Model {
  int calls = 0;
  int analyses = 0;
  final List<WebAiChunk> chunks = <WebAiChunk>[];
  bool retry = false;
  Completer<void>? reply;

  Future<WebAiResult> analyze(
    WebAiConfig config,
    WebAiChunk chunk, {
    Future<bool> Function()? beforeRequest,
  }) async {
    analyses++;
    if (!await beforeRequest!()) throw const WebAiException('cancelled');
    calls++;
    chunks.add(chunk);
    if (reply != null) await reply!.future;
    if (retry) {
      if (!await beforeRequest()) throw const WebAiException('cancelled retry');
      calls++;
    }
    return const WebAiResult(
      summary: '林远读完来信。',
      summaryEvidence: '林远读完来信。',
      characterFacts: <WebAiCharacterFact>[],
      relationships: <WebAiRelationship>[],
      requestCount: 1,
    );
  }
}

WebBook _book({int chunks = 2, int chapters = 1}) {
  const String passage = '林远读完来信。';
  final String text = List<String>.filled(
    (WebAiEngine.maxChunkChars * (chunks - 1) + 100) ~/ passage.length + 1,
    passage,
  ).join();
  return WebBook(
    meta: WebBookMeta(
      id: 'cancellation-fixture',
      title: 'Cancellation fixture',
      author: '',
      length: text.length * chapters,
      chapters: chapters,
      added: 0,
    ),
    data: <String, Object?>{
      'blocks': <Json>[
        for (int i = 0; i < chapters; i++)
          <String, Object?>{'k': 'p', 't': text, 'o': i * text.length},
      ],
      'chapters': <Json>[
        for (int i = 0; i < chapters; i++)
          <String, Object?>{
            'title': '第 ${i + 1} 章',
            'kind': 'body',
            'b0': i,
            'b1': i + 1,
            'o0': i * text.length,
            'o1': (i + 1) * text.length,
          },
      ],
    },
    images: <String, String>{},
  );
}

void main() {
  late _Library library;
  late _Model model;
  late GlobalKey<NavigatorState> navigator;

  Future<void> until(WidgetTester tester, bool Function() condition) async {
    for (int i = 0; i < 100 && !condition(); i++) {
      // Browser Web Locks settle outside Flutter's fake clock.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(
      condition(),
      isTrue,
      reason:
          'Fixture state: acquisitions=${library.acquisitions}, '
          'renewals=${library.renewals}, releases=${library.releases}, '
          'analyses=${model.analyses}, calls=${model.calls}, '
          'phase=${library.saved?['phase']}, '
          'configuration dialogs=${find.byType(AlertDialog).evaluate().length}',
    );
  }

  setUp(() {
    library = _Library();
    model = _Model();
    navigator = GlobalKey<NavigatorState>();
    WebModelSession.current.set(
      const WebAiConfig(
        endpoint: 'http://localhost:11434/v1',
        model: 'fixture',
        apiKey: '',
      ),
    );
  });

  tearDown(() {
    WebModelSession.current.clear();
    html.window.localStorage.remove('thusfar-web-model-profile-v1');
  });

  Future<void> open(
    WidgetTester tester, {
    int chunks = 2,
    int chapters = 1,
    int? cutoff,
  }) async {
    tester.view.physicalSize = const Size(1100, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: Text('Reader')),
      ),
    );
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => WebAiPanel(
            book: _book(chunks: chunks, chapters: chapters),
            cutoffOffset: cutoff,
            reading: WebReadingState(),
            library: library,
            analyze: model.analyze,
            readingBuilder: (_, _) =>
                const Scaffold(body: Text('Reading while preparing')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> configure(WidgetTester tester) async {
    await tester.tap(find.text('开始整理'));
    await tester.pumpAndSettle();
    expect(find.text('整理这本书'), findsOneWidget);
  }

  Future<void> start(WidgetTester tester) async {
    await configure(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('开始整理'),
      ),
    );
    await tester.pump();
  }

  testWidgets('reading above preparation keeps the same run alive', (
    WidgetTester tester,
  ) async {
    final Completer<void> response = Completer<void>();
    model.reply = response;
    await open(tester, chunks: 3);
    await start(tester);
    await until(tester, () => model.calls == 1);
    await tester.tap(find.text('边读边整理'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Reading while preparing'), findsOneWidget);
    response.complete();
    await until(tester, () => library.releases == 1);
    expect(model.calls, 3);
    expect(library.acquisitions, 1);
    expect(library.saves.last['phase'], 'complete');
    expect(find.textContaining('本次整理完成'), findsOneWidget);
    await tester.tap(find.text('查看整理'));
    await tester.pumpAndSettle();
    expect(find.byType(WebAiPanel), findsOneWidget);
    expect(model.calls, 3);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'stop from reading saves current chunk without scheduling another',
    (WidgetTester tester) async {
      final Completer<void> response = Completer<void>();
      model.reply = response;
      await open(tester, chunks: 3);
      await start(tester);
      await until(tester, () => model.calls == 1);
      await tester.tap(find.text('边读边整理'));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byTooltip('停止整理'));
      response.complete();
      await until(tester, () => library.releases == 1);
      expect(model.calls, 1);
      expect(library.saves.last['phase'], 'paused');
      expect((library.saves.last['results'] as Map).length, 1);
      expect(find.text('Reading while preparing'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('selected chapter range skips earlier and later chunks', (
    WidgetTester tester,
  ) async {
    library.saved = <String, Object?>{'scope': 'range:1:1'};
    await open(tester, chunks: 1, chapters: 3);
    await start(tester);
    await until(tester, () => library.releases == 1);
    expect(model.chunks.map((WebAiChunk c) => c.chapterIndex), <int>[1]);
    expect(library.saves.last['scope'], 'range:1:1');
    expect(library.saves.last['phase'], 'complete');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'read scope freezes boundary and sends only complete earlier chunks',
    (WidgetTester tester) async {
      final int firstEnd = WebAiEngine.chunks(_book(chunks: 3)).first.endOffset;
      library.saved = <String, Object?>{'scope': 'read:${firstEnd + 20}'};
      await open(tester, chunks: 3, cutoff: 999999);
      await start(tester);
      await until(tester, () => library.releases == 1);
      expect(model.calls, 1);
      expect(model.chunks.single.endOffset, firstEnd);
      expect(library.saves.last['scope'], 'read:${firstEnd + 20}');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'cancelling configuration never acquires a lease or calls a model',
    (WidgetTester tester) async {
      await open(tester);
      await configure(tester);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(library.acquisitions, 0);
      expect(model.calls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'cancelling the large-run confirmation never starts preparation',
    (WidgetTester tester) async {
      await open(tester, chunks: 30);
      await start(tester);
      await tester.pumpAndSettle();
      expect(find.text('确认并开始（可能收费）'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '返回'));
      await tester.pumpAndSettle();
      expect(library.acquisitions, 0);
      expect(model.calls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('Back during initial lease renewal cannot resurrect a run', (
    WidgetTester tester,
  ) async {
    final Completer<bool> renewal = Completer<bool>();
    library.renewalGates[1] = renewal;
    await open(tester);
    await start(tester);
    await until(tester, () => library.renewals == 1);
    await tester.pumpAndSettle();
    navigator.currentState!.pop();
    renewal.complete(true);
    await until(tester, () => library.releases == 1);
    await tester.pumpAndSettle();
    expect(model.analyses, 0);
    expect(model.calls, 0);
    expect(library.saves, isEmpty);
    expect(find.text('Reader'), findsOneWidget);
  });

  for (final bool leave in <bool>[false, true]) {
    testWidgets(
      '${leave ? 'Back' : 'Pause'} during request gate blocks the call',
      (WidgetTester tester) async {
        final Completer<bool> renewal = Completer<bool>();
        library.renewalGates[4] = renewal;
        await open(tester);
        await start(tester);
        await until(tester, () => library.renewals == 4);
        await tester.pumpAndSettle();
        if (leave) {
          final State<StatefulWidget> panel = tester.state(
            find.byType(WebAiPanel),
          );
          navigator.currentState!.pop();
          expect(panel.mounted, isTrue); // Exit animation has not disposed it.
        } else {
          await tester.tap(find.text('暂停整理'));
        }
        renewal.complete(true);
        await until(tester, () => library.releases == 1);
        await tester.pumpAndSettle();
        expect(model.calls, 0);
        expect(library.saves.last['phase'], 'paused');
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('Back during a retry gate prevents a second billable request', (
    WidgetTester tester,
  ) async {
    model.retry = true;
    final Completer<bool> renewal = Completer<bool>();
    library.renewalGates[5] = renewal;
    await open(tester);
    await start(tester);
    await until(tester, () => library.renewals == 5);
    await tester.pumpAndSettle();
    expect(model.calls, 1);
    navigator.currentState!.pop();
    renewal.complete(true);
    await until(tester, () => library.releases == 1);
    await tester.pumpAndSettle();
    expect(model.calls, 1);
    expect(library.saves.last['phase'], 'paused');
  });

  testWidgets(
    'Back preserves an in-flight result but never starts the next chunk',
    (WidgetTester tester) async {
      final Completer<void> response = Completer<void>();
      model.reply = response;
      await open(tester, chunks: 3);
      await start(tester);
      await until(tester, () => model.calls == 1);
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      response.complete();
      await until(tester, () => library.releases == 1);
      expect(model.calls, 1);
      expect(library.saves.last['phase'], 'paused');
      expect((library.saves.last['results'] as Map<String, Object?>).length, 1);
      expect(library.saves.last['in_flight'], isNull);
    },
  );
}
