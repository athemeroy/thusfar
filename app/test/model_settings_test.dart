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
  final List<Completer<llm.ChatResponse>> replies = [];
  final List<llm.ChatRequest> requests = [];
  int get calls => requests.length;

  @override
  Future<llm.ChatResponse> post(llm.ChatRequest request, Duration timeout) {
    requests.add(request);
    final Completer<llm.ChatResponse> reply = Completer<llm.ChatResponse>();
    replies.add(reply);
    return reply.future;
  }

  void succeed({int? index}) {
    final int i = index ?? replies.length - 1;
    final String event = requests[i].headers.containsKey('x-goog-api-key')
        ? '{"candidates":[{"content":{"parts":[{"text":"可以"}]}}]}'
        : requests[i].headers.containsKey('x-api-key')
        ? '{"type":"content_block_delta","delta":{"type":"text_delta","text":"可以"}}'
        : '{"choices":[{"delta":{"content":"可以"}}]}';
    replies[i].complete(
      llm.ChatResponse(
        200,
        'text/event-stream',
        Stream<List<int>>.value(
          utf8.encode('data: $event\n\ndata: [DONE]\n\n'),
        ),
      ),
    );
  }

  void fail({int? index}) => replies[index ?? replies.length - 1].completeError(
    const llm.LLMError('HTTP 401: offline fixture'),
  );
}

class SaveFailingSettings extends ModelSettings {
  SaveFailingSettings(super.file);
  bool rejectWrites = true;

  @override
  String? save({
    required String url,
    required String model,
    String? key,
    bool clearKey = false,
    String? protocol,
    bool? judgeFallback,
    String? judgeRoute,
    String? judgeUrl,
    String? judgeModel,
    String? judgeKey,
    bool clearJudgeKey = false,
    String? classifierKey,
    bool clearClassifierKey = false,
    String? jevApiKey,
    bool clearJevApiKey = false,
  }) => rejectWrites
      ? '离线存储失败'
      : super.save(
          url: url,
          model: model,
          key: key,
          clearKey: clearKey,
          protocol: protocol,
          judgeFallback: judgeFallback,
          judgeRoute: judgeRoute,
          judgeUrl: judgeUrl,
          judgeModel: judgeModel,
          judgeKey: judgeKey,
          clearJudgeKey: clearJudgeKey,
          classifierKey: classifierKey,
          clearClassifierKey: clearClassifierKey,
          jevApiKey: jevApiKey,
          clearJevApiKey: clearJevApiKey,
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
    oldTransport = llm.transport;
    environ.clear();
    llm.resetEnvCache();
    pending = PendingTransport();
    llm.transport = pending;
  });

  tearDown(() {
    llm.transport = oldTransport;
    environ
      ..clear()
      ..addAll(oldEnvironment);
    llm.resetEnvCache();
    root.deleteSync(recursive: true);
  });

  Finder field(String label) => find.byWidgetPredicate(
    (Widget widget) =>
        widget is TextField && widget.decoration?.labelText == label,
  );

  void seed({String url = 'https://offline.invalid/v1'}) {
    expect(
      settings.save(
        url: url,
        model: 'saved-model',
        key: 'saved-fixture-key',
        classifierKey: 'saved-classifier-key',
        jevApiKey: 'saved-jev-key',
      ),
      isNull,
    );
  }

  Future<void> open(WidgetTester tester, {bool route = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: route
            ? Builder(
                builder: (BuildContext context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<bool>(
                        builder: (_) => ModelSettingsScreen(
                          settings: settings,
                          returnOnSuccess: true,
                        ),
                      ),
                    ),
                    child: const Text('Open settings'),
                  ),
                ),
              )
            : ModelSettingsScreen(settings: settings),
      ),
    );
    if (route) {
      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();
    }
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.pump(const Duration(milliseconds: 300));
    if (find.text(text).evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        find.text(text),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
    }
    await tester.ensureVisible(find.text(text).first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(text).first);
    await tester.pump();
  }

  testWidgets(
    'judging is selectable and does not change the generation model',
    (tester) async {
      seed();
      await open(tester);
      expect(settings.judgeRoute, 'free-only');
      await tester.scrollUntilVisible(
        find.text('免费服务'),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('免费服务').first);
      await tester.tap(find.text('免费服务').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('专用检查模型').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(field('检查服务地址'));
      await tester.enterText(
        field('检查服务地址'),
        'https://my-model.invalid/v1/systemone',
      );
      await tester.ensureVisible(field('检查用的模型（可选）'));
      await tester.enterText(field('检查用的模型（可选）'), 'my-model');
      expect(settings.judgeRoute, 'free-only');
      await tap(tester, '跳过测试，直接保存');
      await tester.pumpAndSettle();
      expect(settings.judgeRoute, 'systemone');
      expect(settings.judgeModel, 'my-model');
      expect(settings.judgeUrl, 'https://my-model.invalid/v1/systemone');
      expect(settings.read().$2, 'saved-model');
      expect(pending.calls, 0);
    },
  );

  testWidgets('opening and missing-key validation never request or save', (
    tester,
  ) async {
    await open(tester);
    expect(pending.calls, 0);
    expect(settings.file.existsSync(), false);
    await tap(tester, '测试并保存');
    expect(pending.calls, 0);
    expect(find.textContaining('还没有填写模型 API 密钥'), findsOneWidget);
    expect(settings.file.existsSync(), false);
  });

  testWidgets(
    'test and save commits only after success and repeated taps are inert',
    (tester) async {
      seed();
      final String before = settings.file.readAsStringSync();
      final Map<String, String> env = Map.of(environ);
      await open(tester);
      await tester.enterText(field('模型'), 'draft-model');
      final VoidCallback submit = tester
          .widget<Pill>(find.widgetWithText(Pill, '测试并保存'))
          .onTap!;
      submit();
      submit();
      await tester.pump();
      expect(pending.calls, 1);
      expect(settings.file.readAsStringSync(), before);
      expect(environ, env);
      expect(
        tester.widget<Pill>(find.widgetWithText(Pill, '测试连接')).onTap,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '跳过测试，直接保存'))
            .onPressed,
        isNull,
      );
      pending.succeed();
      await tester.pumpAndSettle();
      expect(settings.read().$2, 'draft-model');
      expect(environ['EXTRACT_MODEL'], 'draft-model');
      expect(settings.hasClassifierKey, true);
      expect(settings.hasJevApiKey, true);
      expect(find.text('设置已保存'), findsOneWidget);
      expect(pending.calls, 1);
    },
  );

  testWidgets(
    'failed test and save preserves every saved setting and routing',
    (tester) async {
      seed();
      final String before = settings.file.readAsStringSync();
      final Map<String, String> env = Map.of(environ);
      await open(tester);
      await tester.enterText(field('模型'), 'broken-model');
      await tap(tester, '测试并保存');
      pending.fail();
      await tester.pumpAndSettle();
      expect(settings.file.readAsStringSync(), before);
      expect(environ, env);
      expect(find.textContaining('未保存，原有设置保持不变'), findsOneWidget);
      expect(find.text('broken-model'), findsOneWidget);
      await tap(tester, '跳过测试，直接保存');
      await tester.pumpAndSettle();
      expect(pending.calls, 1);
      expect(settings.read().$2, 'broken-model');
      expect(find.textContaining('但未验证连接'), findsOneWidget);
    },
  );

  testWidgets('successful test is reused by saving unchanged effective inputs', (
    tester,
  ) async {
    seed();
    final String before = settings.file.readAsStringSync();
    await open(tester);
    await tester.enterText(field('模型'), 'draft-model');
    await tap(tester, '测试连接');
    expect(
      (jsonDecode(pending.requests.single.body) as Map)['model'],
      'draft-model',
    );
    pending.succeed();
    await tester.pumpAndSettle();
    expect(settings.file.readAsStringSync(), before);
    expect(find.textContaining('当前输入尚未保存'), findsOneWidget);
    await tap(tester, '测试连接');
    expect(pending.calls, 1);
    // Normalization-equivalent whitespace should not incur another model call.
    await tester.enterText(field('模型'), ' draft-model ');
    await tap(tester, '测试并保存');
    await tester.pumpAndSettle();
    expect(pending.calls, 1);
    expect(settings.read().$2, 'draft-model');
    await tap(tester, '测试并保存');
    expect(pending.calls, 1);
  });

  testWidgets('editing tested parameters requires a new successful test', (
    tester,
  ) async {
    seed();
    await open(tester);
    await tap(tester, '测试连接');
    pending.succeed();
    await tester.pumpAndSettle();
    await tester.enterText(field('模型'), 'changed-model');
    await tap(tester, '测试并保存');
    expect(pending.calls, 2);
    expect(settings.read().$2, 'saved-model');
    pending.fail();
    await tester.pumpAndSettle();
    expect(settings.read().$2, 'saved-model');
  });

  testWidgets('clear then replace key remains a draft until test succeeds', (
    tester,
  ) async {
    seed();
    await open(tester);
    await tap(tester, '清除');
    await tester.enterText(field('API 密钥'), 'new-fixture-key');
    await tap(tester, '测试并保存');
    expect(settings.read().$3, 'saved-fixture-key');
    expect(
      pending.requests.single.headers['Authorization'],
      'Bearer new-fixture-key',
    );
    pending.succeed();
    await tester.pumpAndSettle();
    expect(settings.read().$3, 'new-fixture-key');
    expect(find.textContaining('new-fixture-key'), findsNothing);
  });

  testWidgets('explicit unverified key clearing makes no connection request', (
    tester,
  ) async {
    seed();
    await open(tester);
    await tap(tester, '清除');
    await tap(tester, '跳过测试，直接保存');
    await tester.pumpAndSettle();
    expect(settings.hasKey, false);
    expect(environ['LLM_API_KEY'], '');
    expect(pending.calls, 0);
  });

  testWidgets(
    'Jev gateway key alone saves explicitly without enabling paid calls',
    (tester) async {
      await open(tester);
      await tester.scrollUntilVisible(
        find.text('其他服务的密钥（可选）'),
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('其他服务的密钥（可选）'));
      await tester.pumpAndSettle();
      final Finder jev = field('TypeSafe AI / Jev API 密钥');
      await tester.scrollUntilVisible(
        jev,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(jev, 'offline-jev-fixture-key');
      await tap(tester, '跳过测试，直接保存');
      await tester.pumpAndSettle();
      expect(settings.hasJevApiKey, true);
      expect(settings.judgeFallbackEnabled, false);
      expect(pending.calls, 0);
      expect(find.text('设置已保存（未验证）'), findsOneWidget);
      expect(find.textContaining('fixture-key'), findsNothing);
    },
  );

  testWidgets(
    'preset switches isolate keys and restore the original working draft',
    (tester) async {
      seed(url: 'https://api.openai.com/v1');
      final String before = settings.file.readAsStringSync();
      await open(tester);
      await tap(tester, 'DeepSeek');
      expect(find.textContaining('独立 API 密钥'), findsOneWidget);
      expect(field('API 密钥'), findsOneWidget);
      expect(tester.widget<TextField>(field('API 密钥')).controller!.text, '');
      await tap(tester, '测试并保存');
      expect(pending.calls, 0);
      expect(settings.file.readAsStringSync(), before);
      await tester.scrollUntilVisible(
        field('API 密钥'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(field('API 密钥'), 'deepseek-fixture-key');
      await tap(tester, 'OpenAI');
      expect(find.textContaining('独立 API 密钥'), findsNothing);
      expect(
        tester.widget<TextField>(field('模型')).controller!.text,
        'saved-model',
      );
      expect(field('API 密钥'), findsNothing);
      await tap(tester, 'DeepSeek');
      expect(
        tester.widget<TextField>(field('API 密钥')).controller!.text,
        'deepseek-fixture-key',
      );
      await tap(tester, 'OpenAI');
      await tap(tester, '测试连接');
      expect(
        pending.requests.single.headers['Authorization'],
        'Bearer saved-fixture-key',
      );
      pending.succeed();
      await tester.pumpAndSettle();
      expect(settings.file.readAsStringSync(), before);
    },
  );

  testWidgets(
    'manual endpoint changes immediately isolate an entered replacement key',
    (tester) async {
      seed();
      await open(tester);
      await tap(tester, '更换');
      await tester.enterText(field('API 密钥'), 'replacement-fixture-key');
      await tester.scrollUntilVisible(
        field('接口地址'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(field('接口地址'), 'https://other.invalid/v1');
      await tester.pump();
      expect(find.textContaining('独立 API 密钥'), findsOneWidget);
      expect(tester.widget<TextField>(field('API 密钥')).controller!.text, '');
      await tester.enterText(field('接口地址'), 'https://offline.invalid/v1');
      await tester.pump();
      expect(
        tester.widget<TextField>(field('API 密钥')).controller!.text,
        'replacement-fixture-key',
      );
      expect(pending.calls, 0);
    },
  );

  for (final bool fail in [false, true]) {
    testWidgets(
      'late ${fail ? 'error' : 'success'} after Back never saves or pops another route',
      (tester) async {
        seed();
        final String before = settings.file.readAsStringSync();
        await open(tester, route: true);
        await tester.enterText(field('模型'), 'abandoned-model');
        await tap(tester, '测试并保存');
        // Resolve during the reverse transition, while the old State may still be mounted.
        await tester.tap(find.byType(BackButton));
        await tester.pump();
        if (fail) {
          pending.fail();
        } else {
          pending.succeed();
        }
        await tester.pumpAndSettle();
        expect(settings.file.readAsStringSync(), before);
        expect(find.text('Open settings'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'failed persistence keeps prior config and retries without re-testing',
    (tester) async {
      seed();
      final String before = settings.file.readAsStringSync();
      final Map<String, String> env = Map.of(environ);
      final SaveFailingSettings failing = SaveFailingSettings(settings.file);
      settings = failing;
      await open(tester);
      await tester.enterText(field('模型'), 'draft-model');
      await tap(tester, '测试并保存');
      pending.succeed();
      await tester.pumpAndSettle();
      expect(settings.file.readAsStringSync(), before);
      expect(environ, env);
      expect(find.textContaining('离线存储失败'), findsOneWidget);
      failing.rejectWrites = false;
      await tap(tester, '测试并保存');
      await tester.pumpAndSettle();
      expect(settings.read().$2, 'draft-model');
      expect(pending.calls, 1);
    },
  );

  testWidgets('abandoned probe cannot save or close a reopened settings form', (
    tester,
  ) async {
    seed();
    await open(tester, route: true);
    await tester.enterText(field('模型'), 'abandoned-model');
    await tap(tester, '测试并保存');
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    await tester.enterText(field('模型'), 'newest-model');
    await tap(tester, '测试并保存');
    expect(pending.calls, 2);
    pending.succeed(index: 0);
    await tester.pump(const Duration(milliseconds: 400));
    expect(settings.read().$2, 'saved-model');
    expect(find.text('正在测试…'), findsOneWidget);
    pending.succeed(index: 1);
    await tester.pumpAndSettle();
    expect(settings.read().$2, 'newest-model');
    expect(find.text('Open settings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'concurrent saved changes are not overwritten by a late successful probe',
    (tester) async {
      seed();
      await open(tester);
      await tester.enterText(field('模型'), 'draft-model');
      await tap(tester, '测试并保存');
      settings.save(url: 'https://offline.invalid/v1', model: 'newer-model');
      pending.succeed();
      await tester.pumpAndSettle();
      expect(settings.read().$2, 'newer-model');
      expect(find.textContaining('测试期间发生变化'), findsOneWidget);
    },
  );

  for (final (String protocol, String label, String suffix, String header) in [
    (
      'gemini',
      'Gemini',
      '/models/fixture:streamGenerateContent',
      'x-goog-api-key',
    ),
    ('anthropic', 'Claude Compatible', '/messages', 'x-api-key'),
  ]) {
    testWidgets('$label custom endpoint is tested before persistence', (
      tester,
    ) async {
      seed();
      final String before = settings.file.readAsStringSync();
      await open(tester);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      expect(find.textContaining('独立 API 密钥'), findsOneWidget);
      await tester.enterText(field('接口地址'), 'https://custom.invalid/proxy');
      await tester.enterText(field('模型'), 'fixture');
      await tester.ensureVisible(field('API 密钥'));
      await tester.enterText(field('API 密钥'), 'offline-new-key');
      await tap(tester, '测试并保存');
      expect(settings.file.readAsStringSync(), before);
      expect(pending.requests.single.url.path, '/proxy$suffix');
      expect(pending.requests.single.headers[header], 'offline-new-key');
      pending.succeed();
      await tester.pumpAndSettle();
      expect(settings.protocol, protocol);
      expect(settings.read().$1, 'https://custom.invalid/proxy');
      await tester.pumpWidget(const SizedBox());
      await open(tester);
      expect(find.text(label), findsOneWidget);
      expect(find.text('https://custom.invalid/proxy'), findsOneWidget);
    });
  }
}
