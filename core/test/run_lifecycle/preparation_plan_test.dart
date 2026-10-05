import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/jobs.dart' as jobs;
import 'package:thusfar_core/run.dart';
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/pipeline/judge.dart' as judge;
import 'package:thusfar_core/src/pipeline/llm.dart' as llm;
import 'package:thusfar_core/src/pipeline/local.dart' as local;
import 'package:thusfar_core/src/pipeline/preparation_plan.dart';

typedef Json = Map<String, Object?>;

Json read(Directory root, String name) =>
    jsonDecode(File('${root.path}/$name').readAsStringSync()) as Json;
void save(Directory root, String name, Object? data) =>
    writeJson(File('${root.path}/$name'), data);

class OfflineTransport implements llm.ChatTransport {
  int calls = 0;
  @override
  Future<llm.ChatResponse> post(llm.ChatRequest request, Duration timeout) {
    calls++;
    throw StateError('No real network is allowed');
  }
}

class ScopedBackend extends RunBackend {
  final List<int> extracted = <int>[];
  final List<String> sent = <String>[];
  bool allowGenre = false;
  @override
  Future<Json> evaluate(Object? state, Json questions) async {
    sent.add(jsonEncode(<Object?>[state, questions]));
    if (!allowGenre || !questions.containsKey('k')) {
      throw StateError('Unexpected model classification');
    }
    return <String, Object?>{
      'k': <String, Object?>{
        'choice': 'novel',
        'probabilities': <String, Object?>{'novel': .99},
      },
    };
  }

  @override
  Future<(Object?, Json)> generate(
    String model,
    List<Map<String, String>> messages, {
    bool jsonOutput = false,
    int maxTokens = 8000,
    double temperature = .2,
  }) async => throw StateError('Unexpected generated finalization');

  @override
  Future<(Json, Json)> extractLocal(
    Json book,
    Json seg,
    Json? previous,
    String model,
    String hint,
  ) async {
    extracted.add(seg['i']! as int);
    sent.add(jsonEncode(local.build(book, seg, previous, castHint: hint)));
    return (
      local.sanitize(<String, Object?>{}),
      <String, Object?>{'prompt_tokens': 10, 'completion_tokens': 2},
    );
  }
}

Directory fixture(Directory parent, {bool known = true}) {
  final Directory root = Directory('${parent.path}/book')..createSync();
  final List<String> passages = <String>[
    '已读甲。' * 120,
    '以后乙。' * 120,
    '秘密丙。' * 120,
  ];
  int offset = 0;
  final List<Json> blocks = <Json>[];
  final List<Json> chapters = <Json>[];
  for (int i = 0; i < passages.length; i++) {
    final String text = passages[i];
    blocks.add(<String, Object?>{'k': 'p', 't': text, 'o': offset});
    chapters.add(<String, Object?>{
      'title': <String>['已读章', '以后章', '秘密章'][i],
      'b0': i,
      'b1': i + 1,
      'o0': offset,
      'o1': offset + text.length,
      'kind': 'body',
    });
    offset += text.length;
  }
  save(root, 'book.json', <String, Object?>{
    'title': '离线范围测试',
    'author': '',
    'lang': 'zh',
    if (known) 'genre': 'novel',
    'classified': known,
    'len': offset,
    'blocks': blocks,
    'chapters': chapters,
    'notes': <String, Object?>{},
  });
  save(root, 'meta.json', <String, Object?>{'auto': false});
  save(root, 'status.json', <String, Object?>{'state': 'idle'});
  return root;
}

Json plan(int end) => <String, Object?>{
  'version': 1,
  'scope': 'through',
  'end_offset': end,
};

void main() {
  late Directory books;
  late Map<String, String> oldEnvironment;
  late llm.ChatTransport oldTransport;
  late OfflineTransport transport;
  late Future<Json> Function(Object?, Json) oldJudge;
  final List<String> judgments = <String>[];
  setUp(() {
    books = Directory.systemTemp.createTempSync('thusfar-plan-test-');
    oldEnvironment = Map<String, String>.of(environ);
    environ.addAll(<String, String>{
      'JUDGE_TITLES': '1',
      'JUDGE_RELATIONS': '0',
      'VERIFY_RECORDS': '0',
      'JUDGE_LOG': '0',
      'JUDGE_IMPORTANCE': '0',
      'LOCAL_SEGMENT_RETRIES': '1',
    });
    oldTransport = llm.transport;
    llm.transport = transport = OfflineTransport();
    oldJudge = judge.judgeCall;
    judgments.clear();
    judge.judgeCall = (Object? state, Json questions) async {
      judgments.add(jsonEncode(<Object?>[state, questions]));
      return <String, Object?>{
        for (final String key in questions.keys)
          key: <String, Object?>{
            'choice': 'safe',
            'probabilities': <String, Object?>{'safe': .99, 'spoils': .01},
          },
      };
    };
  });
  tearDown(() {
    llm.transport = oldTransport;
    judge.judgeCall = oldJudge;
    environ
      ..clear()
      ..addAll(oldEnvironment);
    expect(transport.calls, 0);
    books.deleteSync(recursive: true);
  });

  test('scope labels cannot conceal a wider chapter boundary', () {
    final Directory root = fixture(books);
    final Json book = read(root, 'book.json');
    expect(
      validatePreparationPlan(<String, Object?>{
        ...plan(480),
        'scope': 'first',
      }, book)['end_offset'],
      480,
    );
    for (final Json wrong in <Json>[
      <String, Object?>{...plan(1440), 'scope': 'first'},
      <String, Object?>{...plan(480), 'scope': 'all'},
      <String, Object?>{
        ...plan(1440),
        'scope': 'range',
        'goal_start_chapter': 1,
        'goal_end_chapter': 1,
      },
      <String, Object?>{...plan(960), 'scope': 'range'},
    ]) {
      expect(
        () => validatePreparationPlan(wrong, book),
        throwsA(isA<Exception>()),
      );
    }
  });

  test('bounded new book sends no future genre samples or titles', () async {
    final Directory root = fixture(books, known: false);
    save(root, 'meta.json', <String, Object?>{'preparation_plan': plan(480)});
    final ScopedBackend backend = ScopedBackend()..allowGenre = true;
    await runBook(
      root,
      backend: backend,
      concurrency: 4,
      localModel: 'offline',
    );
    expect(backend.extracted, <int>[0]);
    final String requests = <String>[...backend.sent, ...judgments].join('\n');
    expect(requests, contains('已读甲'));
    expect(requests, isNot(contains('以后乙')));
    expect(requests, isNot(contains('秘密丙')));
    expect(requests, isNot(contains('以后章')));
    expect(requests, isNot(contains('秘密章')));
    final Json status = read(root, 'status.json');
    expect(status['state'], 'paused');
    expect(status['pause_reason'], 'scope_complete');
    expect(status['done'], 1);
    expect(status['total'], 3);
    expect((status['plan']! as Json)['state'], 'complete');
    expect(read(root, 'book.json')['classification_source'], 'local-bounded');
  });

  test(
    'expansion reuses immutable prefix and smaller plan preserves coverage',
    () async {
      final Directory root = fixture(books);
      final ScopedBackend backend = ScopedBackend();
      save(root, 'meta.json', <String, Object?>{'preparation_plan': plan(480)});
      await runBook(root, backend: backend, localModel: 'offline');
      final String first =
          File('${root.path}/work/segs/0000.json').readAsStringSync();
      save(root, 'meta.json', <String, Object?>{'preparation_plan': plan(960)});
      await runBook(root, backend: backend, localModel: 'offline');
      expect(backend.extracted, <int>[0, 1]);
      expect(
        File('${root.path}/work/segs/0000.json').readAsStringSync(),
        first,
      );
      save(root, 'meta.json', <String, Object?>{'preparation_plan': plan(480)});
      await runBook(root, backend: backend, localModel: 'offline');
      expect(backend.extracted, <int>[0, 1]);
      expect(read(root, 'status.json')['done'], 2);
      expect(
        (read(root, 'status.json')['plan']! as Json)['completed_segments'],
        1,
      );
      expect(File('${root.path}/work/segs/0001.json').existsSync(), isTrue);
    },
  );

  test(
    'mid-segment target stops at prior boundary and never sends next text',
    () async {
      final Directory root = fixture(books);
      save(root, 'meta.json', <String, Object?>{'preparation_plan': plan(700)});
      final ScopedBackend backend = ScopedBackend();
      await runBook(root, backend: backend, localModel: 'offline');
      expect(backend.extracted, <int>[0]);
      final Json status = read(root, 'status.json');
      expect((status['plan']! as Json)['effective_end_offset'], 480);
      expect(backend.sent.join(), isNot(contains('以后乙')));
    },
  );

  test('no complete segment fails before any model call', () async {
    final Directory root = fixture(books, known: false);
    save(root, 'meta.json', <String, Object?>{'preparation_plan': plan(80)});
    final ScopedBackend backend = ScopedBackend()..allowGenre = true;
    await expectLater(
      runBook(root, backend: backend),
      throwsA(isA<Exception>()),
    );
    expect(backend.sent, isEmpty);
    expect(judgments, isEmpty);
  });

  test(
    'worker treats selected goal as terminal and resume keeps scope',
    () async {
      final Directory root = fixture(books);
      final ScopedBackend backend = ScopedBackend();
      final jobs.Worker worker = jobs.Worker(
        books,
        run:
            (
              Directory root, {
              required jobs.RunCancellation cancellation,
              required bool retryQuality,
              required String model,
              required String localModel,
              required int concurrency,
            }) => runBook(
              root,
              cancellation: cancellation,
              backend: backend,
              retryQuality: retryQuality,
              model: 'offline',
              localModel: 'offline',
              concurrency: concurrency,
            ),
      );
      try {
        await worker.startBook(root, plan: plan(480));
        await worker.waitIdle();
        expect(read(root, 'meta.json')['auto'], isFalse);
        expect(read(root, 'status.json')['pause_reason'], 'scope_complete');
        await worker.processBook(root);
        expect(backend.extracted, <int>[0]);
        await worker.startBook(root);
        await worker.waitIdle();
        expect(backend.extracted, <int>[0]);
        expect(
          (read(root, 'meta.json')['preparation_plan']! as Json)['end_offset'],
          480,
        );
        await worker.startBook(root, plan: plan(960));
        await worker.waitIdle();
        expect(backend.extracted, <int>[0, 1]);
        expect(read(root, 'meta.json')['auto'], isFalse);
      } finally {
        await worker.close();
      }
    },
  );

  test(
    'fully prepared book records a smaller complete goal without enabling work',
    () async {
      final Directory root = fixture(books);
      save(root, 'status.json', <String, Object?>{
        'state': 'done',
        'done': 3,
        'total': 3,
        'frontier': 1440,
        'quality': <String, Object?>{
          'state': 'verified',
          'pending': <Object?>[],
        },
      });
      bool ran = false;
      final jobs.Worker worker = jobs.Worker(
        books,
        run: (
          Directory root, {
          required jobs.RunCancellation cancellation,
          required bool retryQuality,
          required String model,
          required String localModel,
          required int concurrency,
        }) async {
          ran = true;
          throw StateError(
            'Changing an already-covered goal must not run models',
          );
        },
      );
      try {
        await worker.startBook(root, plan: plan(480));
        await worker.waitIdle();
        final Json state = read(root, 'status.json');
        expect(state['state'], 'done');
        expect(state['done'], 3);
        expect((state['plan']! as Json)['target_segments'], 1);
        expect((state['plan']! as Json)['completed_segments'], 1);
        expect((state['plan']! as Json)['state'], 'complete');
        expect(read(root, 'meta.json')['auto'], isFalse);
        expect(ran, isFalse);
      } finally {
        await worker.close();
      }
    },
  );

  test(
    'invalid plan cannot enable worker or widen saved authorization',
    () async {
      final Directory root = fixture(books);
      final jobs.Worker worker = jobs.Worker(books);
      try {
        await expectLater(
          worker.startBook(root, plan: plan(99999)),
          throwsA(isA<Exception>()),
        );
        expect(read(root, 'meta.json'), <String, Object?>{'auto': false});
        expect(read(root, 'status.json')['state'], 'idle');
      } finally {
        await worker.close();
      }
    },
  );

  test(
    'temporary model prefix clips UTF16 without changing original source',
    () {
      final Json source = <String, Object?>{
        'len': 6,
        'blocks': <Json>[
          <String, Object?>{'o': 0, 't': 'a😀bcd', 'k': 'p'},
        ],
        'chapters': <Json>[
          <String, Object?>{
            'o0': 0,
            'o1': 6,
            'b0': 0,
            'b1': 1,
            'title': 'future',
          },
        ],
      };
      final Json prefix = preparationBookPrefix(source, 2);
      expect((prefix['blocks']! as List<Json>).single['t'], 'a');
      expect(prefix['chapters'], isEmpty);
      expect((source['blocks']! as List<Json>).single['t'], 'a😀bcd');
    },
  );
}
