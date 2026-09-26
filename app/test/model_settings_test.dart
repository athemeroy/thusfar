import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/model_settings.dart';
import 'package:thusfar_app/screens/model_settings_screen.dart';
import 'package:thusfar_app/ui/theme.dart';
import 'package:thusfar_core/llm.dart' as llm;
import 'package:thusfar_core/thusfar_core.dart' show environ;

class PendingTransport implements llm.ChatTransport {
  final Completer<llm.ChatResponse> reply = Completer<llm.ChatResponse>();
  int calls = 0;

  @override
  Future<llm.ChatResponse> post(llm.ChatRequest request, Duration timeout) {
    calls++;
    return reply.future;
  }

  void succeed() => reply.complete(
    llm.ChatResponse(
      200,
      'text/event-stream',
      Stream<List<int>>.value(
        utf8.encode(
          'data: {"choices":[{"delta":{"content":"可以"}}]}\n\n'
          'data: [DONE]\n\n',
        ),
      ),
    ),
  );
}

void main() {
  late Directory root;
  late ModelSettings settings;
  late PendingTransport pending;
  late llm.ChatTransport oldTransport;
  late Map<String, String> oldEnvironment;

  setUp(() {
    root = Directory.systemTemp.createTempSync('thusfar-settings-ui-');
    settings = ModelSettings(File('${root.path}/.model.env'));
    oldEnvironment = Map<String, String>.of(environ);
    environ.clear();
    llm.resetEnvCache();
    oldTransport = llm.transport;
  });

  tearDown(() {
    llm.transport = oldTransport;
    environ
      ..clear()
      ..addAll(oldEnvironment);
    llm.resetEnvCache();
    root.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester, {bool hasKey = true}) async {
    // Build pending futures inside the widget test's zone so fake-async pumps
    // observe both stream completion and errors.
    pending = PendingTransport();
    llm.transport = pending;
    if (hasKey) {
      expect(
        settings.save(
          url: 'https://offline.invalid/v1',
          model: 'offline',
          key: 'offline-test-placeholder',
        ),
        isNull,
      );
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ModelSettingsScreen(settings: settings),
      ),
    );
    await tester.tap(find.text('测试连接'));
    await tester.pump();
  }

  testWidgets('missing key is reported without any request', (tester) async {
    await open(tester, hasKey: false);
    expect(pending.calls, 0);
    expect(find.text('还没有填写模型 API 密钥，请先填写并保存'), findsOneWidget);
  });

  testWidgets('save cannot launch a second connection test in flight', (
    tester,
  ) async {
    await open(tester);
    expect(pending.calls, 1);
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(pending.calls, 1);
    pending.succeed();
    await tester.pumpAndSettle();
    expect(find.text('连接成功'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final bool fail in <bool>[false, true]) {
    testWidgets('late ${fail ? 'error' : 'success'} after leaving is safe', (
      tester,
    ) async {
      await open(tester);
      expect(pending.calls, 1);
      await tester.pumpWidget(const SizedBox());
      if (fail) {
        pending.reply.completeError(const llm.LLMError('HTTP 401: offline'));
      } else {
        pending.succeed();
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
