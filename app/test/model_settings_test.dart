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
  final List<llm.ChatRequest> requests = <llm.ChatRequest>[];

  @override
  Future<llm.ChatResponse> post(llm.ChatRequest request, Duration timeout) {
    calls++;
    requests.add(request);
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
    expect(find.text('还没有填写模型 API 密钥，请先填写'), findsOneWidget);
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
    expect(find.textContaining('当前输入尚未保存'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('test connection uses unsaved inputs without saving them', (
    tester,
  ) async {
    settings.save(
      url: 'https://offline.invalid/v1',
      model: 'saved',
      key: 'saved-fixture-key',
    );
    final String before = settings.file.readAsStringSync();
    pending = PendingTransport();
    llm.transport = pending;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: ModelSettingsScreen(settings: settings),
      ),
    );
    await tester.enterText(find.byType(TextField).at(1), 'draft-model');
    await tester.tap(find.text('测试连接'));
    await tester.pump();
    expect(
      (jsonDecode(pending.requests.single.body)
          as Map<String, Object?>)['model'],
      'draft-model',
    );
    expect(settings.file.readAsStringSync(), before);
    pending.succeed();
    await tester.pumpAndSettle();
    expect(find.textContaining('当前输入尚未保存'), findsOneWidget);
    expect(settings.read().$2, 'saved');
  });

  testWidgets(
    'clearing then typing a replacement key keeps form visible and saves replacement',
    (tester) async {
      settings.save(
        url: 'https://offline.invalid/v1',
        model: 'fixture',
        key: 'saved-fixture-key',
      );
      pending = PendingTransport();
      llm.transport = pending;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: ModelSettingsScreen(settings: settings),
        ),
      );
      await tester.tap(find.text('清除'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(2), 'new-fixture-key');
      await tester.pump();
      expect(find.byType(TextField), findsNWidgets(3));
      expect(
        tester.widget<TextField>(find.byType(TextField).at(2)).controller!.text,
        'new-fixture-key',
      );
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(settings.read().$3, 'new-fixture-key');
      pending.succeed();
      await tester.pumpAndSettle();
      expect(find.text('连接成功'), findsOneWidget);
      await tester.enterText(find.byType(TextField).at(1), 'changed-again');
      await tester.pump();
      expect(find.text('连接成功'), findsNothing);
    },
  );

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

  for (final (String protocol, String label, String suffix, String header)
      in <(String, String, String, String)>[
        (
          'gemini',
          'Gemini',
          '/models/fixture:streamGenerateContent',
          'x-goog-api-key',
        ),
        ('anthropic', 'Claude Compatible', '/messages', 'x-api-key'),
      ]) {
    testWidgets('$label selection persists and routes a custom endpoint', (
      tester,
    ) async {
      pending = PendingTransport();
      llm.transport = pending;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: ModelSettingsScreen(settings: settings),
        ),
      );
      expect(find.text('OpenAI Compatible'), findsOneWidget);
      expect(find.text('小鲸'), findsNothing);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      final Finder fields = find.byType(TextField);
      await tester.enterText(fields.at(0), 'https://custom.invalid/proxy');
      await tester.enterText(fields.at(1), 'fixture');
      await tester.enterText(fields.at(2), 'offline-new-key');
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(settings.protocol, protocol);
      expect(settings.read().$1, 'https://custom.invalid/proxy');
      expect(pending.requests.single.url.path, '/proxy$suffix');
      expect(pending.requests.single.headers[header], 'offline-new-key');
      pending.reply.completeError(
        const llm.LLMError('HTTP 401: offline fixture'),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: ModelSettingsScreen(settings: ModelSettings(settings.file)),
        ),
      );
      expect(find.text(label), findsOneWidget);
      expect(find.text('https://custom.invalid/proxy'), findsOneWidget);
    });
  }
}
