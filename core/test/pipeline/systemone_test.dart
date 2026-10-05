import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/llm.dart' as llm;
import 'package:thusfar_core/model_settings.dart';
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/pipeline/jev.dart' as judge;

typedef Json = Map<String, Object?>;

class SystemOneTransport implements llm.ChatTransport {
  final List<llm.ChatRequest> requests = [];
  Json answers = {
    'q': {
      'type': 'choice',
      'choice': 'yes',
      'probabilities': {'yes': 0.9, 'no': 0.1},
    },
  };
  @override
  Future<llm.ChatResponse> post(
    llm.ChatRequest request,
    Duration timeout,
  ) async {
    requests.add(request);
    return llm.ChatResponse(
      200,
      'application/json',
      Stream.value(utf8.encode(jsonEncode({'answers': answers}))),
    );
  }
}

void main() {
  final Json questions = {
    'q': {
      'type': 'choice',
      'instructions': 'Is the claim supported?',
      'criteria': {'yes': 'Supported', 'no': 'Not supported'},
    },
  };
  late Directory root;
  late Map<String, String> saved;
  late llm.ChatTransport previous;
  late SystemOneTransport fake;
  setUp(() {
    root = Directory.systemTemp.createTempSync('systemone-test-');
    saved = Map.of(environ);
    previous = llm.transport;
    environ.clear();
    llm.resetEnvCache();
    ModelSettings(File('${root.path}/.model.env')).save({
      'base_url': 'https://qwen.invalid/v1',
      'model': 'qwen',
      'api_key': 'fixture-key',
      'jev_route': 'systemone',
      'judge_url': 'https://decisions.invalid/choose',
      'judge_model': 'my-small-model',
      'judge_api_key': 'judge-fixture-key',
    });
    environ['JUDGE_LOG_DIR'] = '${root.path}/judge';
    fake = SystemOneTransport();
    llm.transport = fake;
    judge.resetJevStats();
  });
  tearDown(() {
    llm.transport = previous;
    environ
      ..clear()
      ..addAll(saved);
    llm.resetEnvCache();
    root.deleteSync(recursive: true);
  });

  test(
    'System One preserves Qwen settings and caches only its own verdicts',
    () async {
      expect(environ['EXTRACT_MODEL'], 'qwen');
      expect(environ['JUDGE_API_URL'], 'https://decisions.invalid/choose');
      final Json first = await judge.jev('fixture passage', questions);
      expect((first['q'] as Json)['by'], 'my-small-model');
      expect(await judge.jev('fixture passage', questions), first);
      expect(fake.requests.length, 1);
      expect(fake.requests.single.url.path, '/choose');
      expect(
        fake.requests.single.headers['Authorization'],
        'Bearer judge-fixture-key',
      );
      expect(
        (jsonDecode(fake.requests.single.body) as Json)['questions'],
        questions,
      );
      expect(
        (jsonDecode(fake.requests.single.body) as Json)['model'],
        'my-small-model',
      );
      expect(judge.jevStats['paid_chars'], 0);
      expect(judge.jevStats['model_calls'], 0);
      expect(judge.jevStats['local_calls'], 1);
      environ['JUDGE_API_URL'] = 'https://other.invalid/v1/systemone';
      await judge.jev('fixture passage', questions);
      expect(fake.requests.length, 2);
      final List<File> cache =
          Directory(
            '${root.path}/judge/cache',
          ).listSync().whereType<File>().toList();
      expect(cache.length, 2);
      expect(
        (jsonDecode(cache.first.readAsStringSync()) as Json)['model'],
        'my-small-model',
      );
    },
  );

  test(
    'incomplete System One answers never use another provider or create a cache',
    () async {
      fake.answers = {};
      await expectLater(
        judge.jev('fixture passage', questions),
        throwsA(isA<llm.LLMError>()),
      );
      expect(fake.requests.length, 1);
      expect(fake.requests.single.url.path, '/choose');
      expect(Directory('${root.path}/judge/cache').existsSync(), false);
      fake.answers = {
        'q': {
          'choice': 'yes',
          'probabilities': {'yes': 1.0},
        },
      };
      await expectLater(
        judge.jev('fixture passage', questions),
        throwsA(isA<llm.LLMError>()),
      );
      expect(fake.requests.length, 2);
      expect(Directory('${root.path}/judge/cache').existsSync(), false);
    },
  );
}
