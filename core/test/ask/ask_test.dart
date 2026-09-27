import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/ask.dart';
import 'package:thusfar_core/llm.dart' as llm;
import 'package:thusfar_core/thusfar_core.dart' show environ;

Json obj(Object? v) => v! as Json;
List<Json> rows(Object? v) => (v! as List<Object?>).cast<Json>();

class RecordedBackend extends AskBackend {
  RecordedBackend(this.script);
  final Json script;
  final List<Json> calls = <Json>[];
  int chats = 0, guards = 0, routes = 0;
  @override
  Future<(String, Json)> route(String question) async {
    routes++;
    return (script['route']! as String, obj(script['probs']));
  }

  @override
  Future<String> complete(
    String model,
    List<Map<String, String>> messages, {
    required int maxTokens,
    required double temperature,
    required double timeout,
  }) async {
    calls.add(<String, Object?>{
      'model': model,
      'messages': messages,
      'max_tokens': maxTokens,
      'temperature': temperature,
      'timeout': timeout,
      'retries': 0,
    });
    return (script['replies']! as List<Object?>)[chats++]! as String;
  }

  @override
  Future<Json> guard(String material, String text) async {
    final Object? v = (script['guards']! as List<Object?>)[guards++];
    if (v == 'error') throw StateError('fixture outage');
    return obj(v);
  }
}

class RepeatBackend extends AskBackend {
  int routes = 0, chats = 0;
  final List<String> materials = <String>[];
  @override
  Future<(String, Json)> route(String question) async {
    routes++;
    return ('other', <String, Object?>{});
  }

  @override
  Future<String> complete(
    String model,
    List<Map<String, String>> messages, {
    required int maxTokens,
    required double temperature,
    required double timeout,
  }) async {
    chats++;
    materials.add(messages.last['content']!);
    return 'Alice came. [1]';
  }

  @override
  Future<Json> guard(String material, String text) async => <String, Object?>{
    'a': <String, Object?>{'verdict': 'ok', 'p': .9},
  };
}

class SuspendedBackend extends RepeatBackend {
  final Completer<String> pending = Completer<String>();
  int checks = 0;
  @override
  Future<String> complete(
    String model,
    List<Map<String, String>> messages, {
    required int maxTokens,
    required double temperature,
    required double timeout,
  }) => pending.future;
  @override
  Future<Json> guard(String material, String text) async {
    checks++;
    return super.guard(material, text);
  }
}

class EvaluateBackend extends AskBackend {
  final List<Json> calls = <Json>[];
  @override
  Future<Json> evaluate(Object? state, Json questions) async {
    calls.add(<String, Object?>{'state': state, 'questions': questions});
    return <String, Object?>{
      'w': <String, Object?>{
        'choice': 'p19',
        'probabilities': <String, Object?>{'p19': .9},
      },
    };
  }
}

class WireBackend extends RepeatBackend {
  @override
  Future<String> complete(
    String model,
    List<Map<String, String>> messages, {
    required int maxTokens,
    required double temperature,
    required double timeout,
  }) => const AskBackend().complete(
    model,
    messages,
    maxTokens: maxTokens,
    temperature: temperature,
    timeout: timeout,
  );
}

class OfflineTransport implements llm.ChatTransport {
  final List<llm.ChatRequest> requests = <llm.ChatRequest>[];
  @override
  Future<llm.ChatResponse> post(
    llm.ChatRequest request,
    Duration timeout,
  ) async {
    requests.add(request);
    final String event = jsonEncode(<String, Object?>{
      'choices': <Object?>[
        <String, Object?>{
          'delta': <String, Object?>{'content': 'Alice came. [1]'},
        },
      ],
    });
    return llm.ChatResponse(
      200,
      'text/event-stream',
      Stream<List<int>>.value(utf8.encode('data: $event\n\ndata: [DONE]\n\n')),
    );
  }
}

class RejectBackend extends RepeatBackend {
  @override
  Future<Json> guard(String material, String text) async => <String, Object?>{
    'a': <String, Object?>{'verdict': 'flag', 'p': .01},
  };
}

class ConfigChangingBackend extends RepeatBackend {
  @override
  Future<Json> guard(String material, String text) async {
    environ['JUDGE_MODEL'] = 'changed-during-question';
    return super.guard(material, text);
  }
}

void main() {
  final Json fixture = obj(
    jsonDecode(File('test/ask/fixtures/python_ask.json').readAsStringSync()),
  );
  late Map<String, String> saved;
  setUp(() {
    saved = Map<String, String>.of(environ);
    environ['QA_MODEL'] = 'fixture-model';
    environ['QUERY_TRANSLATION'] = '0';
    environ['JUDGE_RETRIEVAL'] = '0';
  });
  tearDown(() {
    environ
      ..clear()
      ..addAll(saved);
  });

  test(
    'Existing committed Python recent-text goldens including long Unicode paragraphs',
    () {
      final File file = File('../oracle/goldens/server/ask/recent_text.jsonl');
      for (final String line in file.readAsLinesSync().where(
        (String line) => line.isNotEmpty,
      )) {
        final Json row = obj(jsonDecode(line));
        final Json input = obj(row['input']);
        expect(
          recentText(
            obj(input['book']),
            input['pos']! as int,
            chars: input['chars']! as int,
          ),
          row['output'],
        );
      }
    },
  );

  for (final Json row in rows(fixture['recent'])) {
    final Json input = obj(row['input']);
    test('Python recent prefix at ${input['pos']}', () {
      expect(
        recentText(
          obj(input['book']),
          input['pos']! as int,
          chars: input['chars']! as int,
        ),
        row['output'],
      );
    });
  }
  for (final Json row in rows(fixture['retrieve'])) {
    final Json input = obj(row['input']);
    test('Python retrieval ${input['q']} at ${input['pos']}', () {
      final List<Json> result = retrieve(
        obj(input['book']),
        input['q']! as String,
        (input['names']! as List<Object?>).cast<String>(),
        input['pos']! as int,
        k: input['k']! as int,
      );
      expect(result, row['output']);
      for (final Json p in result) {
        expect(
          (p['o']! as int) + (p['t']! as String).length,
          lessThanOrEqualTo(input['pos']!),
        );
      }
    });
  }
  for (final Json row in rows(fixture['answers'])) {
    test(
      'Python full answer, exact prompts and events: ${row['name']}',
      () async {
        final Json input = obj(row['input']);
        final RecordedBackend backend = RecordedBackend(obj(row['script']));
        final List<Json> events = <Json>[];
        await answerSnapshot(
          obj(input['book']),
          obj(input['kg']),
          obj(input['status']),
          input['question']! as String,
          input['pos']! as int,
          backend: backend,
          onEvent:
              (String kind, Json value) => events.add(<String, Object?>{
                'kind': kind,
                'value': <String, Object?>{...value}..remove('ms'),
              }),
        );
        expect(events, row['events']);
        expect(backend.calls, row['chat']);
        expect(jsonEncode(events), isNot(contains('REJECTED')));
        expect(jsonEncode(backend.calls), isNot(contains('UNREAD')));
        expect(
          jsonEncode(backend.calls),
          isNot(contains('Future identity revealed')),
        );
      },
    );
  }

  test('Acceptance requires finite numeric probability in range', () {
    for (final Object? p in <Object?>[
      null,
      true,
      '0.9',
      double.nan,
      double.infinity,
      -.1,
      .399,
      1.01,
    ]) {
      expect(accepted(<String, Object?>{'verdict': 'ok', 'p': p}), isFalse);
    }
    for (final num p in <num>[.4, .95, 1]) {
      expect(accepted(<String, Object?>{'verdict': 'ok', 'p': p}), isTrue);
    }
  });

  test('Python Unicode whitespace and UTF16 split surrogate behavior', () {
    expect(bigrams('甲\u001c乙'), <String>{'甲乙'});
    expect(prefixText('A😀B', 2), 'A');
    expect(prefixText('A😀B', 3), 'A😀');
  });

  final Json input = obj(rows(fixture['answers']).first['input']);
  late Directory root, bookDir;
  void prepare() {
    root = Directory.systemTemp.createTempSync('thusfar-ask-');
    bookDir = Directory('${root.path}/books/fixture')
      ..createSync(recursive: true);
    for (final String name in <String>['book', 'kg', 'status']) {
      File(
        '${bookDir.path}/$name.json',
      ).writeAsStringSync(jsonEncode(input[name]));
    }
    addTearDown(() => root.deleteSync(recursive: true));
  }

  test(
    'Cache isolates prefix, question, source repair and model configuration',
    () async {
      prepare();
      final RepeatBackend backend = RepeatBackend();
      final AskService service = AskService(backend: backend);
      final int pos = input['pos']! as int;
      await service.answer(bookDir, 'Alice?', pos);
      final Json cached = await service.answer(bookDir, 'Alice?', pos);
      expect(cached['cached'], true);
      expect(backend.chats, 1);
      await service.answer(bookDir, 'Alice?', 10);
      expect(backend.chats, 2);
      await service.answer(bookDir, 'Bob?', pos);
      expect(backend.chats, 3);
      final File graph = File('${bookDir.path}/kg.json');
      final DateTime stamp = graph.statSync().modified;
      graph.writeAsStringSync(
        graph.readAsStringSync().replaceAll('writer', 'sailor'),
      );
      graph.setLastModifiedSync(stamp);
      await service.answer(bookDir, 'Alice?', pos);
      expect(
        backend.chats,
        4,
        reason: 'same size and mtime repair must invalidate cache',
      );
      environ['QA_MODEL'] = 'different-model';
      await service.answer(bookDir, 'Alice?', pos);
      expect(backend.chats, 5);
      final Json copy = await service.answer(bookDir, 'Alice?', pos);
      copy['text'] = 'mutated';
      expect(
        (await service.answer(bookDir, 'Alice?', pos))['text'],
        isNot('mutated'),
      );
    },
  );

  test('Corrupt graph and invalid prefix fail before any model call', () async {
    prepare();
    final RepeatBackend backend = RepeatBackend();
    final AskService service = AskService(backend: backend);
    await expectLater(service.answer(bookDir, '', 1), throwsA(isA<Object>()));
    await expectLater(
      service.answer(bookDir, 'Alice?', -1),
      throwsA(isA<Object>()),
    );
    await expectLater(
      service.answer(bookDir, 'Alice?', 999999),
      throwsA(isA<Object>()),
    );
    File('${bookDir.path}/kg.json').writeAsStringSync('{');
    await expectLater(
      service.answer(bookDir, 'Alice?', 10),
      throwsA(isA<FormatException>()),
    );
    expect(backend.routes, 0);
  });

  test('Cancellation after generation skips guard and publication', () async {
    prepare();
    final SuspendedBackend backend = SuspendedBackend();
    final AskCancellation cancel = AskCancellation();
    final List<String> events = <String>[];
    final Future<Json> pending = AskService(backend: backend).answer(
      bookDir,
      'Alice?',
      input['pos']! as int,
      cancellation: cancel,
      onEvent: (String kind, Json value) => events.add(kind),
    );
    final Future<void> check = expectLater(
      pending,
      throwsA(isA<llm.LLMError>()),
    );
    await Future<void>.delayed(Duration.zero);
    cancel.cancel();
    backend.pending.complete('Private unverified reply');
    await check;
    expect(backend.checks, 0);
    expect(events, isNot(contains('answer')));
  });

  test(
    'Timeout never publishes a late reply or launches a later guard',
    () async {
      prepare();
      final SuspendedBackend backend = SuspendedBackend();
      final List<String> events = <String>[];
      final AskService service = AskService(
        backend: backend,
        timeout: const Duration(milliseconds: 10),
      );
      await expectLater(
        service.answer(
          bookDir,
          'Alice?',
          input['pos']! as int,
          onEvent: (String kind, Json value) => events.add(kind),
        ),
        throwsA(isA<llm.DeadlineExceeded>()),
      );
      backend.pending.complete('Private late reply');
      await Future<void>.delayed(Duration.zero);
      expect(backend.checks, 0);
      expect(events, isNot(contains('answer')));
    },
  );
  for (final Json row in rows(fixture['who'])) {
    test('Python exact pronoun span and nearby candidates', () async {
      final Json i = obj(row['input']);
      final EvaluateBackend backend = EvaluateBackend();
      expect(
        await whoIs(
          obj(i['book']),
          rows(i['log']),
          i['pos']! as int,
          i['start']! as int,
          i['end']! as int,
          backend: backend,
        ),
        row['output'],
      );
      expect(backend.calls, row['calls']);
      expect(
        (await whoIs(
          obj(i['book']),
          rows(i['log']),
          19,
          18,
          20,
          backend: backend,
        ))['ok'],
        false,
      );
      expect(
        backend.calls.length,
        1,
        reason: 'an unread selected span is rejected before the judge',
      );
    });
  }

  test(
    'Timed-out transports retain the two-request concurrency limit',
    () async {
      prepare();
      final SuspendedBackend backend = SuspendedBackend();
      final AskService service = AskService(
        backend: backend,
        timeout: const Duration(milliseconds: 5),
      );
      for (int i = 0; i < 2; i++) {
        await expectLater(
          service.answer(bookDir, 'Alice $i?', 20),
          throwsA(isA<llm.DeadlineExceeded>()),
        );
      }
      await expectLater(
        service.answer(bookDir, 'Alice third?', 20),
        throwsA(
          isA<llm.LLMError>().having(
            (llm.LLMError e) => e.message,
            'message',
            contains('正在回答其他问题'),
          ),
        ),
      );
      backend.pending.complete('late answer');
      await Future<void>.delayed(Duration.zero);
      expect(backend.routes, 2);
      expect(backend.checks, 0);
    },
  );

  test(
    'Real chat wire uses selected model and prefix only, via offline transport',
    () async {
      prepare();
      final llm.ChatTransport original = llm.transport;
      final OfflineTransport transport = OfflineTransport();
      llm.transport = transport;
      addTearDown(() {
        llm.transport = original;
        llm.resetEnvCache();
      });
      environ['LLM_API_KEY'] = 'offline-fixture';
      environ['LLM_PROTOCOL'] = 'openai';
      environ['LLM_BASE_URL'] = 'https://offline.invalid/v1';
      environ.remove('LLM_KEY_MAP');
      environ.remove('LLM_KEY_NAME');
      environ.remove('LLM_PROTOCOL_MAP');
      final Json answer = await AskService(
        backend: WireBackend(),
      ).answer(bookDir, 'Alice?', input['pos']! as int);
      expect(answer['text'], 'Alice came. [1]');
      expect(transport.requests.length, 1);
      final Json body = obj(jsonDecode(transport.requests.single.body));
      expect(body['model'], 'fixture-model');
      expect(transport.requests.single.body, isNot(contains('UNREAD')));
      expect(body['max_tokens'], 1200);
    },
  );

  test('Withheld responses are audited locally and never cached', () async {
    prepare();
    final RejectBackend backend = RejectBackend();
    final AskService service = AskService(backend: backend);
    for (int i = 0; i < 2; i++) {
      final Json answer = await service.answer(
        bookDir,
        'Alice?',
        input['pos']! as int,
      );
      expect(obj(answer['guard'])['verdict'], 'withheld');
      expect(answer['cites'], isEmpty);
    }
    expect(backend.chats, 4);
    expect(
      File('${root.path}/qa-audit/fixture.jsonl').readAsLinesSync().length,
      2,
    );
  });

  test(
    'Configuration changes during generation cannot poison the previous cache key',
    () async {
      prepare();
      final ConfigChangingBackend backend = ConfigChangingBackend();
      final AskService service = AskService(backend: backend);
      environ['JUDGE_MODEL'] = 'initial';
      await service.answer(bookDir, 'Alice?', 20);
      environ['JUDGE_MODEL'] = 'initial';
      await service.answer(bookDir, 'Alice?', 20);
      expect(backend.chats, 2);
    },
  );
}
