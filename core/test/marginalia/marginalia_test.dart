import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/marginalia.dart' as m;
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/errors.dart';
import 'package:thusfar_core/src/pipeline/llm.dart' as llm;
import 'package:thusfar_core/src/server/storage.dart' as storage;

import '../golden/codec.dart';

typedef Json = Map<String, Object?>;
final Json fixture =
    jsonDecode(File('test/marginalia/fixtures/oracles.json').readAsStringSync())
        as Json;
Json obj(Object? v) => v as Json? ?? {};
Object? clone(Object? v) => jsonDecode(jsonEncode(v));

class ScriptBackend extends m.MarginaliaBackend {
  ScriptBackend(this.script);
  final Json script;
  final List<Json> calls = [];
  int chats = 0, guards = 0;
  @override
  List<String> styles(int count) => m.commentStyles.take(count).toList();
  @override
  double now() => 1234.5;
  @override
  Future<String> complete(
    String model,
    List<Map<String, String>> messages, {
    required int maxTokens,
    required double temperature,
    required double timeout,
    required int retries,
  }) async {
    calls.add({
      'kind': 'chat',
      'model': model,
      'messages': messages,
      'max_tokens': maxTokens,
      'temperature': temperature,
      'timeout': timeout,
      'retries': retries,
    });
    final String result =
        (script['replies']! as List<Object?>)[chats++]! as String;
    if (result == 'error') throw StateError('fixture draft outage');
    return result;
  }

  @override
  Future<Json> guard(String passage, Json items) async {
    calls.add({
      'kind': 'guard',
      'passage': passage,
      'earlier': <String, Object?>{},
      'items': items,
    });
    final Object? result = (script['guards']! as List<Object?>)[guards++];
    if (result == 'error') throw StateError('fixture judge outage');
    return obj(result);
  }

  @override
  Future<Json> evaluate(Json state, Json questions) async {
    calls.add({'kind': 'judge', 'state': state, 'questions': questions});
    return obj(script['answers']);
  }
}

class BlockingBackend extends m.MarginaliaBackend {
  final Completer<void> started = Completer<void>(),
      release = Completer<void>();
  int calls = 0, guards = 0, active = 0, maxActive = 0;
  @override
  List<String> styles(int count) => m.commentStyles.take(count).toList();
  @override
  Future<String> complete(
    String model,
    List<Map<String, String>> messages, {
    required int maxTokens,
    required double temperature,
    required double timeout,
    required int retries,
  }) async {
    calls++;
    active++;
    if (active > maxActive) maxActive = active;
    if (!started.isCompleted) started.complete();
    await release.future;
    active--;
    return '这一声关门，比开口说话还让人在意。';
  }

  @override
  Future<Json> guard(String passage, Json items) async {
    guards++;
    return {
      for (final String key in items.keys) key: {'verdict': 'ok', 'p': .9},
    };
  }
}

class NoNetwork implements llm.ChatTransport {
  @override
  Future<llm.ChatResponse> post(llm.ChatRequest request, Duration timeout) =>
      throw StateError('Real network is prohibited');
}

void main() {
  late Directory root;
  late Map<String, String> savedEnv;
  late llm.ChatTransport savedTransport;
  setUp(() {
    root = Directory.systemTemp.createTempSync('thusfar-marginalia-');
    savedEnv = {...environ};
    environ
      ..clear()
      ..addAll({
        'MARGINALIA_MODEL': 'fixture-reader',
        'MARGINALIA_AUTO_MODEL': 'fixture-auto',
      });
    savedTransport = llm.transport;
    llm.transport = NoNetwork();
    storage.writeJson(File('${root.path}/book.json'), fixture['book']);
    storage.writeJson(File('${root.path}/kg.json'), {'log': fixture['log']});
    storage.writeJson(File('${root.path}/status.json'), {
      'frontier': fixture['frontier'],
    });
    storage.writeJson(File('${root.path}/notebook.json'), {
      'items': [
        {'id': 'untouched', 'text': '我的原始想法'},
      ],
    });
  });
  tearDown(() {
    llm.transport = savedTransport;
    environ
      ..clear()
      ..addAll(savedEnv);
    root.deleteSync(recursive: true);
  });
  final Map<String, Object? Function(Json)> helpers = {
    '_accepted': (i) => m.accepted(obj(i['verdict'])),
    '_clean': (i) => m.clean(i['text']! as String),
    '_comment_personas':
        (i) => {r'$tuple': m.commentPersonas(i['first']! as String)},
    '_material':
        (i) => m.material(
          obj(i['book']),
          (i['log']! as List<Object?>).cast<Json>(),
          i['frontier']! as int,
          i['end']! as int,
          i['quote']! as String,
        ),
    '_page_candidates':
        (i) => m.pageCandidates(
          obj(i['book']),
          i['start']! as int,
          i['end']! as int,
        ),
    '_slice_u16':
        (i) => m.sliceU16(
          i['text']! as String,
          i['start']! as int,
          i['end']! as int,
        ),
    '_source_before':
        (i) => m.sourceBefore(
          obj(i['book']),
          i['pos']! as int,
          chars: i['chars']! as int,
        ),
    '_story':
        (i) => m.story(
          obj(i['world']),
          focus: i['focus']! as String,
          limitPeople: i['limit_people']! as int,
        ),
  };
  for (final entry in helpers.entries) {
    test('historical ${entry.key}', () {
      for (final String line
          in File(
            '../oracle/goldens/server/marginalia/${entry.key}.jsonl',
          ).readAsLinesSync()) {
        final Json row = jsonDecode(line) as Json;
        expect(entry.value(decodeInput(row['input'])! as Json), row['output']);
      }
    });
  }
  test('historical key version and Python graph revision tuple', () {
    for (final String line
        in File(
          '../oracle/goldens/special/marginalia_key.jsonl',
        ).readAsLinesSync()) {
      final Json row = jsonDecode(line) as Json;
      expect(
        m.key(obj((decodeInput(row['input'])! as Json)['payload'])),
        row['output'],
      );
    }
  });
  test(
    'Python SequenceMatcher ratios including order, supplementary text and popular elements',
    () {
      for (final Json r
          in (fixture['similarity']! as List<Object?>).cast<Json>()) {
        expect(
          m.sequenceRatio(r['a']! as String, r['b']! as String),
          r['ratio'],
        );
      }
    },
  );
  for (final Json scenario
      in (fixture['cases']! as List<Object?>).cast<Json>()) {
    test('Python respond ${scenario['name']}', () async {
      final ScriptBackend backend = ScriptBackend(obj(scenario['script']));
      final List<Object?> writes = [];
      final List<int> notebook =
          File('${root.path}/notebook.json').readAsBytesSync();
      final m.MarginaliaService service = m.MarginaliaService(
        backend: backend,
        graphRevision: (_) => fixture['revision'],
        writeJson: (file, value) {
          writes.add(clone(value));
          storage.writeJson(file, value);
        },
      );
      Object? result;
      try {
        result = await service.respond(root, scenario['input']);
      } on PyException catch (e) {
        result = {
          'error': {'type': e.pyType.split('.').last, 'message': e.message},
        };
      } on StateError catch (e) {
        result = {
          'error': {'type': 'RuntimeError', 'message': e.message},
        };
      }
      expect(result, scenario['output']);
      if (scenario['cached'] != null)
        expect(
          await service.respond(root, scenario['input']),
          scenario['cached'],
        );
      expect(backend.calls, scenario['calls']);
      expect(writes, scenario['writes']);
      expect(File('${root.path}/notebook.json').readAsBytesSync(), notebook);
      for (final Json call in backend.calls) {
        expect(jsonEncode(call), isNot(contains('UNREAD SECRET')));
        expect(jsonEncode(call), isNot(contains('UNREAD GRAPH SECRET')));
      }
    });
  }
  Json request() =>
      obj((fixture['cases']! as List<Object?>).first)['input']! as Json;
  test('same page requests coalesce without duplicating generation', () async {
    final BlockingBackend backend = BlockingBackend();
    final m.MarginaliaService service = m.MarginaliaService(backend: backend);
    final Future<Json> first = service.respond(root, request());
    await backend.started.future;
    final Future<Json> second = service.respond(root, request());
    await Future<void>.delayed(Duration.zero);
    expect(backend.calls, 1);
    backend.release.complete();
    expect((await first)['cached'], false);
    expect((await second)['cached'], true);
    expect(backend.calls, 1);
    expect(backend.guards, 1);
  });
  test(
    'cancellation withholds successful late draft and does not guard or persist it',
    () async {
      final BlockingBackend backend = BlockingBackend();
      final m.MarginaliaService service = m.MarginaliaService(backend: backend);
      final m.MarginaliaCancellation token = m.MarginaliaCancellation();
      final Future<Json> operation = service.respond(
        root,
        request(),
        cancellation: token,
      );
      await backend.started.future;
      token.cancel();
      await expectLater(operation, throwsA(isA<m.MarginaliaCancelled>()));
      backend.release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(backend.guards, 0);
      expect(File('${root.path}/marginalia.json').existsSync(), false);
    },
  );
  test(
    'timeout retains model slot until transport settles and never persists late text',
    () async {
      final BlockingBackend backend = BlockingBackend();
      final m.MarginaliaService service = m.MarginaliaService(
        backend: backend,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        service.respond(root, request()),
        throwsA(isA<llm.DeadlineExceeded>()),
      );
      expect(backend.active, 1);
      backend.release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(backend.guards, 0);
      expect(File('${root.path}/marginalia.json').existsSync(), false);
    },
  );
  test('source change during generation prevents stale publication', () async {
    final BlockingBackend backend = BlockingBackend();
    final m.MarginaliaService service = m.MarginaliaService(backend: backend);
    final Future<Json> operation = service.respond(root, request());
    await backend.started.future;
    final Json book = clone(fixture['book'])! as Json;
    book['title'] = 'updated';
    storage.writeJson(File('${root.path}/book.json'), book);
    backend.release.complete();
    await expectLater(operation, throwsA(isA<ValueError>()));
    expect(File('${root.path}/marginalia.json').existsSync(), false);
  });
  test(
    'invalid cached guard cannot expose text and old rows are retained',
    () async {
      final ScriptBackend backend = ScriptBackend({
        'replies': ['这一声关门，比开口说话还让人在意。'],
        'guards': [
          {
            'comment': {'verdict': 'ok', 'p': .9},
          },
        ],
      });
      final m.MarginaliaService service = m.MarginaliaService(
        backend: backend,
        graphRevision: (_) => fixture['revision'],
      );
      final Json old = {
        ...obj(obj((fixture['cases']! as List<Object?>).first)['output']),
        'comment': 'REJECTED PRIVATE FUTURE',
        'guard': {'verdict': 'flag', 'p': .1},
      };
      storage.writeJson(File('${root.path}/marginalia.json'), [old]);
      final Json result = await service.respond(root, request());
      expect(result['comment'], isNot(old['comment']));
      expect(result['cached'], false);
      expect(
        (jsonDecode(File('${root.path}/marginalia.json').readAsStringSync())
                as List)
            .first,
        old,
      );
    },
  );
  test(
    'three request permits remain occupied until transport settles; cancelled queued job never starts',
    () async {
      final BlockingBackend backend = BlockingBackend();
      final m.MarginaliaService service = m.MarginaliaService(backend: backend);
      final List<m.MarginaliaCancellation> tokens = List.generate(
        4,
        (_) => m.MarginaliaCancellation(),
      );
      final List<Future<Json>> pending = [
        for (final (int i, String persona)
            in ['empathy', 'cold', 'scholar', 'wit'].indexed)
          service.respond(root, {
            ...request(),
            'persona': persona,
          }, cancellation: tokens[i]),
      ];
      await backend.started.future;
      await Future<void>.delayed(Duration.zero);
      expect(backend.calls, 3);
      expect(backend.maxActive, 3);
      tokens.last.cancel();
      await expectLater(pending.last, throwsA(isA<m.MarginaliaCancelled>()));
      backend.release.complete();
      await Future.wait(pending.take(3));
      await Future<void>.delayed(Duration.zero);
      expect(backend.calls, 3);
      expect(backend.guards, 3);
    },
  );
  test(
    'graph rewrite with same timestamp invalidates cache by content',
    () async {
      final ScriptBackend backend = ScriptBackend({
        'replies': ['这一声关门，比开口说话还让人在意。', '这个轻轻关门的动作，让人也安静下来。'],
        'guards': [
          {
            'comment': {'verdict': 'ok', 'p': .9},
          },
          {
            'comment': {'verdict': 'ok', 'p': .9},
          },
        ],
      });
      final m.MarginaliaService service = m.MarginaliaService(backend: backend);
      final Json first = await service.respond(root, request());
      final File graph = File('${root.path}/kg.json');
      final DateTime stamp = graph.lastModifiedSync();
      final Json data = jsonDecode(graph.readAsStringSync()) as Json;
      ((data['log']! as List<Object?>).first! as Json)['name'] = '小李';
      storage.writeJson(graph, data);
      graph.setLastModifiedSync(stamp);
      final Json second = await service.respond(root, request());
      expect(second['cached'], false);
      expect(second['key'], isNot(first['key']));
      expect(backend.chats, 2);
    },
  );
  test(
    'changed model endpoint while in flight suppresses response and cache',
    () async {
      final BlockingBackend backend = BlockingBackend();
      final m.MarginaliaService service = m.MarginaliaService(backend: backend);
      final Future<Json> pending = service.respond(root, request());
      await backend.started.future;
      environ['LLM_BASE_URL_GEMINI'] = 'https://example.invalid/new-endpoint';
      backend.release.complete();
      await expectLater(pending, throwsA(isA<ValueError>()));
      expect(File('${root.path}/marginalia.json').existsSync(), false);
    },
  );
}
