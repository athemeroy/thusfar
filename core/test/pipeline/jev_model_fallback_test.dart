import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/judge_budget.dart' as budget;
import 'package:thusfar_core/llm.dart' as llm;
import 'package:thusfar_core/model_settings.dart';
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/pipeline/jev.dart' as judge;
import 'package:thusfar_core/src/pipeline/judge_context.dart';
import 'package:thusfar_core/src/pipeline/provenance.dart' as provenance;

typedef Json = Map<String, Object?>;

final class JudgeTransport implements llm.ChatTransport {
  JudgeTransport({
    this.freeStatus = 403,
    this.modelStatus = 200,
    this.modelReplies = const <String>[],
  });

  int freeStatus;
  int modelStatus;
  final List<String> modelReplies;
  final List<llm.ChatRequest> requests = <llm.ChatRequest>[];

  @override
  Future<llm.ChatResponse> post(
    llm.ChatRequest request,
    Duration timeout,
  ) async {
    requests.add(request);
    if (request.url.host == 'classifier.dev') {
      if (freeStatus == 403) {
        return llm.ChatResponse(
          403,
          'application/json',
          Stream<List<int>>.value(
            utf8.encode(
              '{"error":"Anonymous proxy traffic requires a funded API key.","code":"proxy_requires_payment","retryable":false}',
            ),
          ),
        );
      }
      if (freeStatus >= 400) {
        return llm.ChatResponse(
          freeStatus,
          'application/json',
          Stream<List<int>>.value(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'error': 'echo ${request.headers['Authorization'] ?? ''}',
              }),
            ),
          ),
        );
      }
      return llm.ChatResponse(
        200,
        'application/json',
        Stream<List<int>>.value(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'results': <Object?>[
                <String, Object?>{
                  'dimensions': <String, Object?>{
                    'd0': <String, Object?>{
                      'label': 'yes',
                      'scores': <String, Object?>{'yes': 0.9, 'no': 0.1},
                      'confidence': 0.9,
                    },
                  },
                },
              ],
            }),
          ),
        ),
      );
    }
    final int modelCall =
        requests.where((r) => r.url.host == 'offline.invalid').length;
    if (modelStatus >= 400) {
      return llm.ChatResponse(
        modelStatus,
        'application/json',
        Stream<List<int>>.value(utf8.encode('{"error":"unavailable"}')),
      );
    }
    final String answer = modelReplies[modelCall - 1];
    return llm.ChatResponse(
      200,
      'text/event-stream',
      Stream<List<int>>.value(
        utf8.encode(
          'data: ${jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'delta': <String, Object?>{'content': answer},
              },
            ],
            'usage': <String, Object?>{'prompt_tokens': 100, 'completion_tokens': 20},
          })}\n\ndata: [DONE]\n\n',
        ),
      ),
    );
  }
}

final class PaidJudgeTransport implements llm.ChatTransport {
  PaidJudgeTransport(this.answer);
  final String answer;
  final List<llm.ChatRequest> requests = <llm.ChatRequest>[];

  @override
  Future<llm.ChatResponse> post(
    llm.ChatRequest request,
    Duration timeout,
  ) async {
    requests.add(request);
    if (request.url.host == 'classifier.dev') {
      return llm.ChatResponse(
        403,
        'application/json',
        Stream<List<int>>.value(
          utf8.encode('{"code":"proxy_requires_payment"}'),
        ),
      );
    }
    return llm.ChatResponse(
      200,
      'application/json',
      Stream<List<int>>.value(utf8.encode('{"answers":$answer}')),
    );
  }
}

void main() {
  const Json questions = <String, Object?>{
    'q1': <String, Object?>{
      'instructions': 'Does the passage say yes?',
      'criteria': <String, Object?>{'yes': 'supported', 'no': 'not supported'},
    },
  };
  const String valid =
      '{"q1":{"choice":"yes","probabilities":{"yes":0.9,"no":0.1}}}';
  late Directory root;
  late Map<String, String> savedEnv;
  late llm.ChatTransport savedTransport;
  late ModelSettings settings;

  setUp(() {
    root = Directory.systemTemp.createTempSync('thusfar-model-judge-');
    savedEnv = Map<String, String>.of(environ);
    savedTransport = llm.transport;
    environ.clear();
    llm.resetEnvCache();
    judge.freeBreaker
      ..bad = 0
      ..until = 0
      ..probing = false;
    judge.resetJevStats();
    settings = ModelSettings(File('${root.path}/.model.env'));
    environ['JUDGE_LOG_DIR'] = '${root.path}/book/work/judge';
    settings.save(<String, Object?>{
      'base_url': 'https://offline.invalid/v1',
      'model': 'deepseek-test',
      'api_key': 'offline-model-key',
    });
  });

  tearDown(() {
    llm.transport = savedTransport;
    environ
      ..clear()
      ..addAll(savedEnv);
    llm.resetEnvCache();
    judge.freeBreaker
      ..bad = 0
      ..until = 0
      ..probing = false;
    root.deleteSync(recursive: true);
  });

  test(
    'old free-only setting never silently spends the configured model',
    () async {
      expect(settings.read()['jev_route'], 'free-only');
      final JudgeTransport fake = JudgeTransport(modelReplies: <String>[valid]);
      llm.transport = fake;
      await expectLater(
        judge.jev('passage', questions),
        throwsA(isA<llm.LLMError>()),
      );
      expect(fake.requests.map((r) => r.url.host), <String>['classifier.dev']);
      expect(
        File('${root.path}/book/work/judge/model-budget.json').existsSync(),
        false,
      );
    },
  );

  test(
    '403 falls back to saved model, caches strict answer, and cools free route',
    () async {
      settings.save(<String, Object?>{'jev_route': 'free-then-model'});
      final JudgeTransport fake = JudgeTransport(
        modelReplies: <String>[valid, valid],
      );
      llm.transport = fake;
      final Json answer = await judge.jev('passage', questions);
      expect((answer['q1'] as Json)['choice'], 'yes');
      expect((answer['q1'] as Json)['by'], 'deepseek-test+nothink');
      expect(fake.requests.map((r) => r.url.host), <String>[
        'classifier.dev',
        'offline.invalid',
      ]);
      expect(judge.freeBreaker.open(), true);
      expect(
        (budget.readModelJudgeBudget(
          File('${root.path}/book/work/judge/model-budget.json'),
        )['calls']),
        1,
      );
      await judge.jev('passage', questions);
      expect(
        fake.requests,
        hasLength(2),
        reason: 'completed judgment is cached',
      );
      await judge.jev('other passage', questions);
      expect(fake.requests.map((r) => r.url.host), <String>[
        'classifier.dev',
        'offline.invalid',
        'offline.invalid',
      ]);
      expect(judge.jevStats['model_calls'], 2);
    },
  );

  test(
    'explicit book model route rechecks even a cached free verdict',
    () async {
      final Directory book = Directory('${root.path}/book')..createSync();
      final JudgeTransport fake = JudgeTransport(
        freeStatus: 200,
        modelReplies: <String>[valid],
      );
      llm.transport = fake;
      await judge.jev('same passage', questions);
      File(
        '${book.path}/meta.json',
      ).writeAsStringSync('{"judge_fallback_route":"model-direct"}');
      await withBookJudgeContext(
        book,
        () => judge.jev('same passage', questions),
      );
      expect(fake.requests.map((r) => r.url.host), <String>[
        'classifier.dev',
        'offline.invalid',
      ]);
      expect(
        budget.readModelJudgeBudget(
          File('${book.path}/work/judge/model-budget.json'),
        )['calls'],
        1,
      );
    },
  );

  test('explicit book Jev route skips a successful free verdict', () async {
    final Directory book = Directory('${root.path}/book')..createSync();
    File(
      '${book.path}/meta.json',
    ).writeAsStringSync('{"judge_fallback_route":"jev-direct"}');
    environ['JEV_API_KEY'] = 'selected-gateway-key';
    final PaidJudgeTransport fake = PaidJudgeTransport(valid);
    llm.transport = fake;
    await withBookJudgeContext(book, () => judge.jev('passage', questions));
    expect(fake.requests.map((r) => r.url.host), <String>[
      'ai-gateway.vercel.sh',
    ]);
    expect(
      provenance.readPaidJudgeBudget(
        File('${book.path}/work/judge/paid-budget.json'),
      )['calls'],
      1,
    );
  });

  test(
    'incomplete model answers get one repair, then fail without a cache',
    () async {
      settings.save(<String, Object?>{'jev_route': 'free-then-model'});
      final JudgeTransport fake = JudgeTransport(
        modelReplies: const <String>[
          '{"q1":{"choice":"yes"}}',
          '{"q1":{"choice":"yes","probabilities":{"yes":0,"no":0}}}',
        ],
      );
      llm.transport = fake;
      await expectLater(
        judge.jev('passage', questions),
        throwsA(isA<llm.LLMError>()),
      );
      expect(
        fake.requests.where((r) => r.url.host == 'offline.invalid'),
        hasLength(2),
      );
      expect(
        Directory('${root.path}/book/work/judge/cache').existsSync(),
        false,
      );
      expect(
        budget.readModelJudgeBudget(
          File('${root.path}/book/work/judge/model-budget.json'),
        )['calls'],
        2,
      );
    },
  );

  test(
    'malformed JSON is repaired once instead of aborting the book',
    () async {
      settings.save(<String, Object?>{'jev_route': 'free-then-model'});
      final JudgeTransport fake = JudgeTransport(
        modelReplies: <String>['{"q1": ???}', valid],
      );
      llm.transport = fake;
      final Json answer = await judge.jev('passage', questions);
      expect((answer['q1'] as Json)['choice'], 'yes');
      expect(
        fake.requests.where((r) => r.url.host == 'offline.invalid'),
        hasLength(2),
      );
      expect(
        budget.readModelJudgeBudget(
          File('${root.path}/book/work/judge/model-budget.json'),
        )['calls'],
        2,
      );
    },
  );

  test(
    'classifier workspace key uses the free endpoint, never the model key',
    () async {
      settings.save(<String, Object?>{
        'classifier_key': 'offline-classifier-key',
      });
      final JudgeTransport fake = JudgeTransport(freeStatus: 200);
      llm.transport = fake;
      final Json answer = await judge.jev('passage', questions);
      expect((answer['q1'] as Json)['choice'], 'yes');
      expect(
        fake.requests.single.headers['Authorization'],
        'Bearer offline-classifier-key',
      );
      expect(fake.requests.single.url.host, 'classifier.dev');
    },
  );

  test(
    'a newly saved workspace key immediately bypasses an anonymous 403 cooldown',
    () async {
      settings.save(<String, Object?>{'jev_route': 'free-then-model'});
      final JudgeTransport fake = JudgeTransport(modelReplies: <String>[valid]);
      llm.transport = fake;
      await judge.jev('first passage', questions);
      expect(judge.freeBreaker.open(), true);
      settings.save(<String, Object?>{'classifier_key': 'new-workspace-key'});
      fake.freeStatus = 200;
      final Json answer = await judge.jev('second passage', questions);
      expect((answer['q1'] as Json)['choice'], 'yes');
      expect(fake.requests.last.url.host, 'classifier.dev');
      expect(
        fake.requests.last.headers['Authorization'],
        'Bearer new-workspace-key',
      );
    },
  );

  test(
    'enabling model fallback reuses prior successful free-only cache',
    () async {
      final JudgeTransport fake = JudgeTransport(freeStatus: 200);
      llm.transport = fake;
      await judge.jev('same passage', questions);
      settings.save(<String, Object?>{'jev_route': 'free-then-model'});
      fake.freeStatus = 403;
      final Json answer = await judge.jev('same passage', questions);
      expect((answer['q1'] as Json)['choice'], 'yes');
      expect(fake.requests, hasLength(1));
      expect(
        File('${root.path}/book/work/judge/model-budget.json').existsSync(),
        false,
      );
    },
  );

  test(
    'enabling paid Jev fallback also reuses prior free-only cache',
    () async {
      final JudgeTransport fake = JudgeTransport(freeStatus: 200);
      llm.transport = fake;
      await judge.jev('same passage', questions);
      environ['JEV_ROUTE'] = 'free-then-paid';
      environ['JEV_API_KEY'] = 'selected-gateway-key';
      fake.freeStatus = 403;
      final Json answer = await judge.jev('same passage', questions);
      expect((answer['q1'] as Json)['choice'], 'yes');
      expect(fake.requests, hasLength(1));
      expect(provenance.paidBudgetFile().existsSync(), false);
    },
  );

  test(
    'current-route cache wins if both model and old free answers exist',
    () async {
      settings.save(<String, Object?>{'jev_route': 'free-then-model'});
      const String no =
          '{"q1":{"choice":"no","probabilities":{"yes":0.1,"no":0.9}}}';
      final JudgeTransport fake = JudgeTransport(
        modelReplies: const <String>[no],
      );
      llm.transport = fake;
      expect(
        ((await judge.jev('same passage', questions))['q1'] as Json)['choice'],
        'no',
      );
      settings.save(<String, Object?>{'jev_route': 'free-only'});
      judge.freeBreaker
        ..bad = 0
        ..until = 0
        ..probing = false;
      fake.freeStatus = 200;
      expect(
        ((await judge.jev('same passage', questions))['q1'] as Json)['choice'],
        'yes',
      );
      settings.save(<String, Object?>{'jev_route': 'free-then-model'});
      expect(
        ((await judge.jev('same passage', questions))['q1'] as Json)['choice'],
        'no',
      );
      expect(fake.requests, hasLength(3));
    },
  );

  test(
    'model transport failure spends one reservation and makes one request',
    () async {
      settings.save(<String, Object?>{'jev_route': 'free-then-model'});
      environ['LLM_RETRIES'] = '4';
      final JudgeTransport fake = JudgeTransport(modelStatus: 503);
      llm.transport = fake;
      await expectLater(
        judge.jev('passage', questions),
        throwsA(isA<llm.LLMError>()),
      );
      expect(
        fake.requests.where((r) => r.url.host == 'offline.invalid'),
        hasLength(1),
      );
      expect(
        budget.readModelJudgeBudget(
          File('${root.path}/book/work/judge/model-budget.json'),
        )['calls'],
        1,
      );
    },
  );

  test('model judge usage and cost survive worker counter reset', () async {
    settings.save(<String, Object?>{
      'model': 'deepseek-flash',
      'jev_route': 'free-then-model',
    });
    final JudgeTransport fake = JudgeTransport(modelReplies: <String>[valid]);
    llm.transport = fake;
    await judge.jev('passage', questions);
    final num before = judge.jevStats['model_cost_high']!;
    expect(before, greaterThan(0));
    judge.resetJevStats();
    expect(judge.jevStats['model_calls'], 1);
    expect(judge.jevStats['model_prompt_tokens'], 100);
    expect(judge.jevStats['model_cost_high'], before);
  });

  test(
    'keyed classifier errors distinguish credentials and redact echoes',
    () async {
      settings.save(<String, Object?>{
        'classifier_key': 'private-workspace-key',
      });
      final JudgeTransport denied = JudgeTransport();
      llm.transport = denied;
      await expectLater(
        judge.jev('passage', questions),
        throwsA(
          predicate(
            (Object e) =>
                e.toString().contains('工作区密钥访问被拒绝') &&
                !e.toString().contains('匿名'),
          ),
        ),
      );
      judge.freeBreaker
        ..bad = 0
        ..until = 0
        ..probing = false;
      environ['JEV_FREE_RETRIES'] = '0';
      final JudgeTransport unavailable = JudgeTransport(freeStatus: 503);
      llm.transport = unavailable;
      await expectLater(
        judge.jev('another passage', questions),
        throwsA(
          predicate(
            (Object e) => !e.toString().contains('private-workspace-key'),
          ),
        ),
      );
    },
  );

  test(
    'book allowance can be extended explicitly without losing usage',
    () async {
      final File file = File('${root.path}/book/work/judge/model-budget.json');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'calls': 1,
          'chars': 20,
          'questions': 1,
          'max_calls': 1,
          'max_chars': 1000,
        }),
      );
      expect(() => budget.reserveModelJudge(10, 1), throwsA(isA<Exception>()));
      final Json updated = budget.extendModelJudgeBudget(file);
      expect(updated['calls'], 1);
      expect(updated['max_calls'], 1 + budget.modelJudgeTopUpCalls);
      final Json reserved = budget.reserveModelJudge(10, 1);
      expect(reserved['calls'], 2);
      expect(reserved['chars'], 30);
    },
  );

  test(
    'concurrent reader books keep distinct routes and budget files',
    () async {
      final Directory modelBook = Directory('${root.path}/reader-model')
        ..createSync();
      final Directory jevBook = Directory('${root.path}/reader-jev')
        ..createSync();
      final Directory freeBook = Directory('${root.path}/reader-free')
        ..createSync();
      File(
        '${modelBook.path}/meta.json',
      ).writeAsStringSync('{"judge_fallback_route":"model"}');
      File(
        '${jevBook.path}/meta.json',
      ).writeAsStringSync('{"judge_fallback_route":"jev"}');
      environ['JEV_ROUTE'] = 'free-only';
      environ['JEV_BUDGET_FILE'] = '${root.path}/wrong-shared-paid-budget.json';
      final Completer<void> continueTogether = Completer<void>();
      Future<(String, String, String)> capture(Directory book) =>
          withBookJudgeContext(book, () async {
            await continueTogether.future;
            return (
              selectedJudgeRoute(),
              provenance.modelJudgeBudgetFile().path,
              provenance.paidBudgetFile().path,
            );
          });
      final Future<(String, String, String)> model = capture(modelBook);
      final Future<(String, String, String)> jev = capture(jevBook);
      final Future<(String, String, String)> free = capture(freeBook);
      continueTogether.complete();
      expect(await model, (
        'free-then-model',
        '${modelBook.path}/work/judge/model-budget.json',
        '${modelBook.path}/work/judge/paid-budget.json',
      ));
      expect(await jev, (
        'free-then-paid',
        '${jevBook.path}/work/judge/model-budget.json',
        '${jevBook.path}/work/judge/paid-budget.json',
      ));
      expect(await free, (
        'free-only',
        '${freeBook.path}/work/judge/model-budget.json',
        '${freeBook.path}/work/judge/paid-budget.json',
      ));
      expect(environ['JEV_ROUTE'], 'free-only');
      expect(environ['JUDGE_LOG_DIR'], '${root.path}/book/work/judge');
    },
  );

  test('paid Jev top-up is durable and retains a custom base limit', () {
    environ['JEV_PAID_MAX_CALLS'] = '1';
    environ['JEV_PAID_MAX_CHARS'] = '100';
    final File ledger = provenance.paidBudgetFile();
    expect(provenance.readPaidJudgeBudget(ledger)['max_calls'], 1);
    expect(provenance.reservePaid(80, 1)['calls'], 1);
    expect(() => provenance.reservePaid(1, 1), throwsA(isA<Exception>()));
    final Json raised = provenance.extendPaidJudgeBudget(ledger);
    expect(raised['max_calls'], 1 + provenance.paidJudgeTopUpCalls);
    expect(raised['max_chars'], 100 + provenance.paidJudgeTopUpChars);
    expect(raised['calls'], 1);
    expect(provenance.reservePaid(1, 1)['calls'], 2);
    expect(provenance.readPaidJudgeBudget(ledger)['calls'], 2);
    expect(
      provenance.readPaidJudgeBudget(ledger)['max_calls'],
      raised['max_calls'],
    );
  });

  test('app worker ledger stays per-book despite a legacy global override', () {
    final String inherited = '${root.path}/legacy-global-ledger.json';
    environ['JEV_BUDGET_FILE'] = inherited;
    expect(environ['LLM_SETTINGS_AUTHORITY'], '1');
    expect(
      provenance.paidBudgetFile().path,
      '${root.path}/book/work/judge/paid-budget.json',
    );
    environ.remove('LLM_SETTINGS_AUTHORITY');
    expect(provenance.paidBudgetFile().path, inherited);
  });

  test(
    'saved Jev gateway key wins over inherited key and clearing stops paid calls',
    () async {
      environ['JEV_ROUTE'] = 'free-then-paid';
      environ['JEV_API_KEY'] = 'selected-gateway-key';
      environ['VERCEL_AI_GATEWAY_KEY'] = 'ambient-gateway-key';
      final PaidJudgeTransport fake = PaidJudgeTransport(valid);
      llm.transport = fake;
      await judge.jev('first passage', questions);
      expect(fake.requests.map((r) => r.url.host), <String>[
        'classifier.dev',
        'ai-gateway.vercel.sh',
      ]);
      expect(
        fake.requests.last.headers['Authorization'],
        'Bearer selected-gateway-key',
      );
      final File ledger = provenance.paidBudgetFile();
      expect(provenance.readPaidJudgeBudget(ledger)['calls'], 1);
      environ['JEV_API_KEY'] = '';
      await expectLater(
        judge.jev('second passage', questions),
        throwsA(predicate((Object e) => e.toString().contains('缺少 Jev 密钥'))),
      );
      expect(fake.requests, hasLength(2));
      expect(provenance.readPaidJudgeBudget(ledger)['calls'], 1);
    },
  );
}
