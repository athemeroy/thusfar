// Translated from tests/test_judge_client.py. These contracts stay skipped until
// the A3/A4 judge client and its deterministic test transport are registered.
import 'package:test/test.dart';
import 'package:thusfar_core/src/py/py_json.dart';

import 'contract_invoker.dart';

List<Object?> classifierBatches(Map<String, Object?> questions) =>
    callPorted('pipeline.llm._classifier_batches', {'questions': questions})
        as List<Object?>;

List<Object?> batchTuple(Object? value) =>
    (value as Map<String, Object?>)['\$tuple'] as List<Object?>;

Map<String, Object?> choiceQuestion(String instructions) => {
  'type': 'choice',
  'instructions': instructions,
  'criteria': {'yes': 'Supported', 'no': 'Unsupported'},
};

String repeatText(String text, int count) => List.filled(count, text).join();

const questions = <String, Object?>{
  'q': {
    'type': 'choice',
    'instructions': 'Is it supported?',
    'criteria': {'yes': 'Supported', 'no': 'Unsupported'},
  },
};
const answers = <String, Object?>{
  'q': {
    'type': 'choice',
    'choice': 'yes',
    'probabilities': {'yes': 0.9, 'no': 0.1},
  },
};
const freeAnswer = <String, Object?>{
  'results': [
    {
      'dimensions': {
        'd0': {
          'label': 'yes',
          'scores': {'yes': 0.9, 'no': 0.1},
        },
      },
    },
  ],
};

/// Test-only invocation contract for a real Dart owner. `$script` injects a
/// sequence of transport replies, a fixed clock, captured sleep calls and a
/// synthetic secret. No network is used. The adapter returns `result` or
/// `error: {type, message}`, plus ordered `requests`, `sleeps`, `diagnostics`,
/// `teacher` log calls and `freeBreakerOpen`. Request `body` is decoded JSON.
/// A reply's `{'$nonFinite': 'nan'|'inf'}` marker becomes a non-finite wire
/// number, matching Python's scripted `json.dumps` response fixture.
Map<String, Object?> scripted(
  String functionId, {
  Object? state = 'state',
  Map<String, Object?>? questionsArg,
  int? retries,
  String route = 'paid',
  Map<String, String> environment = const {},
  List<Object?> replies = const [],
  Map<String, Object?> extra = const {},
}) {
  return callPorted(functionId, {
        'state': state,
        'questions': questionsArg ?? questions,
        if (retries != null) 'retries': retries,
        'route': route,
        ...extra,
        r'$script': {
          'environment': environment,
          'replies': replies,
          'now': 0,
          'random': 0,
          'secret': 'unit-test-secret',
        },
      })
      as Map<String, Object?>;
}

Map<String, Object?> limited([String retryAfter = '59']) => {
  'kind': 'httpError',
  'status': 429,
  'retryAfter': retryAfter,
  'body': {'error': 'busy'},
};

Map<String, Object?> reply(Object? body) => {'kind': 'json', 'body': body};

Map<String, Object?> object(Object? value) => value as Map<String, Object?>;

List<Object?> array(Object? value) => value as List<Object?>;

void expectClientError(Map<String, Object?> run) {
  expect(object(run['error'])['type'], 'pipeline.llm.LLMError');
}

void main() {
  test(
    "tests.test_judge_client.JudgeClient.test_explicit_zero_retries_overrides_default_without_final_sleep",
    () {
      final run = scripted(
        'pipeline.llm.jev',
        retries: 0,
        replies: [limited()],
      );
      expectClientError(run);
      expect(array(run['requests']), hasLength(1));
      expect(array(run['sleeps']), isEmpty);
    },
    skip:
        "Dart implementation of pipeline.llm.jev is pending (A3, A4); required to check 'explicit zero retries overrides default without final sleep'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_lower_environment_retry_count_is_honored",
    () {
      final run = scripted(
        'pipeline.llm.jev',
        environment: {'JEV_RETRIES': '1'},
        replies: [limited(), limited()],
      );
      expectClientError(run);
      expect(array(run['requests']), hasLength(2));
      expect(array(run['sleeps']), [59]);
      final log = run['diagnostics']! as String;
      expect(log, contains('HTTP 429'));
      expect(log, contains('等待=59.0s'));
      expect(log, isNot(contains('unit-test-secret')));
      expect(log, isNot(contains('Authorization')));
    },
    skip:
        "Dart implementation of pipeline.llm.jev is pending (A3, A4); required to check 'lower environment retry count is honored'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_success_after_retry_is_validated_and_logged_once",
    () {
      final run = scripted(
        'pipeline.llm.jev',
        retries: 1,
        replies: [
          limited('2'),
          reply({'answers': answers}),
        ],
      );
      expect(run['result'], answers);
      expect(array(run['sleeps']), [2]);
      expect(array(run['teacher']), [
        {'state': 'state', 'questions': questions, 'answers': answers},
      ]);
      expect(run['diagnostics'], contains('已恢复'));
    },
    skip:
        "Dart implementation of pipeline.llm.jev is pending (A3, A4); required to check 'success after retry is validated and logged once'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_timeout_exhaustion_has_no_final_sleep",
    () {
      final run = scripted(
        'pipeline.llm.jev',
        retries: 0,
        replies: [
          {'kind': 'timeout', 'message': 'timeout'},
        ],
      );
      expectClientError(run);
      expect(array(run['requests']), hasLength(1));
      expect(array(run['sleeps']), isEmpty);
    },
    skip:
        "Dart implementation of pipeline.llm.jev is pending (A3, A4); required to check 'timeout exhaustion has no final sleep'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_free_long_retry_advice_falls_back_immediately",
    () {
      final run = scripted(
        'pipeline.llm.jev',
        route: 'free-then-paid',
        retries: 0,
        replies: [
          limited(),
          reply({'answers': answers}),
        ],
      );
      expect(run['result'], answers);
      expect(array(run['requests']), hasLength(2));
      expect(run['freeBreakerOpen'], isTrue);
      expect(array(run['sleeps']), isEmpty);
    },
    skip:
        "Dart implementation of pipeline.llm.jev is pending (A3, A4); required to check 'free long retry advice falls back immediately'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_free_exhaustion_has_no_final_sleep",
    () {
      final run = scripted(
        'pipeline.llm.jev_free',
        retries: 0,
        replies: [limited('1')],
      );
      expectClientError(run);
      expect(array(run['requests']), hasLength(1));
      expect(array(run['sleeps']), isEmpty);
    },
    skip:
        "Dart implementation of pipeline.llm.jev_free is pending (A3, A4); required to check 'free exhaustion has no final sleep'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_free_valid_response_keeps_wire_contract",
    () {
      final run = scripted(
        'pipeline.llm.jev_free',
        retries: 0,
        replies: [reply(freeAnswer)],
      );
      final answer = object(object(run['result'])['q']);
      expect(answer['choice'], 'yes');
      expect(answer['probabilities'], {'yes': 0.9, 'no': 0.1});
    },
    skip:
        "Dart implementation of pipeline.llm.jev_free is pending (A3, A4); required to check 'free valid response keeps wire contract'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_free_batches_honor_serialized_unicode_dimension_limit",
    () {
      final instruction = repeatText('甲😀"\\\n', 300);
      final testQuestions = <String, Object?>{
        for (var i = 0; i < 7; i++) 'q$i': choiceQuestion('$instruction$i'),
      };
      final run = scripted(
        'pipeline.llm.jev_free',
        questionsArg: testQuestions,
        retries: 0,
        replies: List<Object?>.filled(7, {
          'kind': 'freeEcho',
          'label': 'yes',
          'scores': {'yes': 0.9, 'no': 0.1},
        }),
      );
      expect(object(run['result']).keys.toSet(), testQuestions.keys.toSet());
      final requests = array(run['requests']);
      expect(requests.length, greaterThan(1));
      final instructions = <String>[];
      for (final request in requests) {
        final dimensions = object(
          object(object(request)['body'])['dimensions'],
        );
        expect(
          PyJson.encode(dimensions, ensureAscii: false).length,
          lessThanOrEqualTo(16000),
        );
        expect(dimensions.length, lessThanOrEqualTo(20));
        for (final value in dimensions.values) {
          instructions.add(
            (object(value)['instructions']! as String)
                .split('\nChoose one label:\n')
                .first,
          );
        }
      }
      expect(instructions, [
        for (final q in testQuestions.values) object(q)['instructions'],
      ]);
    },
    skip:
        "Dart implementation of pipeline.llm.jev_free is pending (A3, A4); required to check 'free batches honor serialized unicode dimension limit'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_free_batches_preserve_twenty_dimension_limit",
    () {
      final questions = <String, Object?>{
        for (var i = 0; i < 41; i++) 'q$i': choiceQuestion('Is it supported?'),
      };
      final sizes =
          classifierBatches(questions)
              .map((batch) => (batchTuple(batch)[0] as List<Object?>).length)
              .toList();
      expect(sizes, [20, 20, 1]);
    },
    skip:
        "Dart implementation of pipeline.llm._classifier_batches is pending (A3, A4); required to check 'free batches preserve twenty dimension limit'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_free_serialized_dimension_boundary_is_inclusive",
    () {
      final questions = <String, Object?>{
        for (var i = 0; i < 5; i++)
          'q$i': choiceQuestion(i < 4 ? repeatText('甲', 3000) : ''),
      };
      Map<String, Object?> firstDimensions() =>
          batchTuple(classifierBatches(questions).first)[1]
              as Map<String, Object?>;
      final overhead =
          PyJson.encode(firstDimensions(), ensureAscii: false).length;
      final fifth = questions['q4']! as Map<String, Object?>;
      fifth['instructions'] = repeatText('甲', 16000 - overhead);
      expect(
        PyJson.encode(firstDimensions(), ensureAscii: false).length,
        16000,
      );
      fifth['instructions'] = (fifth['instructions']! as String) + '甲';
      final sizes =
          classifierBatches(questions)
              .map((batch) => (batchTuple(batch)[0] as List<Object?>).length)
              .toList();
      expect(sizes, [4, 1]);
    },
    skip:
        "Dart implementation of pipeline.llm._classifier_batches is pending (A3, A4); required to check 'free serialized dimension boundary is inclusive'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_free_instruction_limit_is_checked_before_submission",
    () {
      final response =
          callPorted('pipeline.llm._classifier_batches', {
                'questions': {'q': choiceQuestion(repeatText('甲', 4000))},
              })
              as Map<String, Object?>;
      final error = response['\$error']! as Map<String, Object?>;
      expect(error['type'], 'pipeline.llm.LLMError');
      expect(error['message'], contains('4000'));
    },
    skip:
        "Dart implementation of pipeline.llm._classifier_batches is pending (A3, A4); required to check 'free instruction limit is checked before submission'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_long_guard_note_is_kept_in_state_with_short_instructions",
    () {
      final note = repeatText('The story so far. ', 300);
      final answer = {
        'g1': {
          'choice': 'supported',
          'probabilities': {
            'supported': 0.9,
            'beyond_text': 0.1,
            'contradicted': 0,
          },
        },
      };
      // The scripted guard adapter invokes the real guard_texts owner with a
      // recorded jev result and captures its sole state/questions call.
      final run =
          callPorted('pipeline.judge.guard_texts', {
                'passage': 'source passage',
                'earlier': <String, Object?>{},
                'items': {'saga': note},
                r'$script': {'jevAnswer': answer},
              })
              as Map<String, Object?>;
      final calls = array(run['jevCalls']);
      expect(calls, hasLength(1));
      final call = object(calls.single);
      expect(object(call['state'])['note_g1'], note);
      final instructions =
          object(object(call['questions'])['g1'])['instructions']! as String;
      expect(instructions, isNot(contains(note)));
      expect(instructions.length, lessThan(4000));
      expect(object(object(run['result'])['saga'])['verdict'], 'ok');
    },
    skip:
        "Dart implementation of pipeline.judge.guard_texts is pending (A3, A4); required to check 'long guard note is kept in state with short instructions'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_oversized_single_dimension_goes_paid_without_partial_free_calls",
    () {
      final testQuestions = <String, Object?>{
        'small': questions['q'],
        'large': choiceQuestion(repeatText('甲', 16000)),
      };
      final expected = {
        for (final key in testQuestions.keys) key: answers['q'],
      };
      final run = scripted(
        'pipeline.llm.jev',
        route: 'free-then-paid',
        questionsArg: testQuestions,
        retries: 0,
        replies: [
          reply({'answers': expected}),
        ],
      );
      expect(run['result'], expected);
      final requests = array(run['requests']);
      expect(requests, hasLength(1));
      expect(
        object(requests.single)['url'],
        'https://ai-gateway.vercel.sh/v1/evaluate',
      );
    },
    skip:
        "Dart implementation of pipeline.llm.jev is pending (A3, A4); required to check 'oversized single dimension goes paid without partial free calls'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_missing_paid_answers_are_not_logged_as_training_labels",
    () {
      for (final response in <Object?>[
        <String, Object?>{},
        {'answers': <String, Object?>{}},
        <Object?>[],
        {'error': 'failed'},
        {
          'answers': {'other': answers['q']},
        },
      ]) {
        final run = scripted(
          'pipeline.llm.jev',
          retries: 0,
          replies: [reply(response)],
        );
        expectClientError(run);
        expect(array(run['teacher']), isEmpty, reason: '$response');
        expect(array(run['sleeps']), isEmpty, reason: '$response');
      }
    },
    skip:
        "Dart implementation of pipeline.llm.jev is pending (A3, A4); required to check 'missing paid answers are not logged as training labels'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_invalid_paid_scores_are_rejected",
    () {
      for (final scores in <Map<String, Object?>>[
        {},
        {
          'yes': {r'$nonFinite': 'nan'},
        },
        {
          'yes': {r'$nonFinite': 'inf'},
        },
        {'yes': -0.1},
        {'yes': 1.1},
        {'yes': true},
        {'yes': '0.9'},
        {'yes': 0, 'no': 0},
        {'yes': 0.9, 'unexpected': 0.1},
      ]) {
        final run = scripted(
          'pipeline.llm.jev',
          retries: 0,
          replies: [
            reply({
              'answers': {
                'q': {'choice': 'yes', 'probabilities': scores},
              },
            }),
          ],
        );
        expectClientError(run);
        expect(array(run['teacher']), isEmpty, reason: '$scores');
      }
    },
    skip:
        "Dart implementation of pipeline.llm.jev is pending (A3, A4); required to check 'invalid paid scores are rejected'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_malformed_or_missing_free_dimensions_are_rejected",
    () {
      for (final response in <Object?>[
        <String, Object?>{},
        {'results': <Object?>[]},
        {
          'results': [
            {'dimensions': <String, Object?>{}},
          ],
        },
        {
          'results': [
            {
              'dimensions': {'d0': <Object?>[]},
            },
          ],
        },
      ]) {
        final run = scripted(
          'pipeline.llm.jev_free',
          retries: 0,
          replies: [reply(response)],
        );
        expectClientError(run);
      }
    },
    skip:
        "Dart implementation of pipeline.llm.jev_free is pending (A3, A4); required to check 'malformed or missing free dimensions are rejected'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_chat_exhaustion_has_no_final_sleep",
    () {
      final run = scripted(
        'pipeline.llm.chat',
        retries: 0,
        replies: [
          {'kind': 'timeout', 'message': 'timeout'},
        ],
        extra: {
          'model': 'test-model',
          'messages': [
            {'role': 'user', 'content': 'test'},
          ],
        },
      );
      expectClientError(run);
      expect(array(run['sleeps']), isEmpty);
    },
    skip:
        "Dart implementation of pipeline.llm.chat is pending (A3, A4); required to check 'chat exhaustion has no final sleep'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_retry_after_dates_and_invalid_values",
    () {
      Object? retryAfter(String value, {int? cap}) =>
          callPorted('pipeline.llm._retry_after', {
            'headers': {'Retry-After': value},
            'attempt': 0,
            if (cap != null) 'cap': cap,
            r'$script': {'now': 0},
          });
      expect(retryAfter('Thu, 01 Jan 1970 00:00:05 GMT'), 5);
      for (final bad in ['nonsense', 'NaN', 'inf']) {
        expect(retryAfter(bad), 0.5);
      }
      expect(retryAfter('120', cap: 60), isNull);
    },
    skip:
        "Dart implementation of pipeline.llm._retry_after is pending (A3, A4); required to check 'retry after dates and invalid values'.",
  );
  test(
    "tests.test_judge_client.Breaker.test_cooldown_allows_only_one_recovery_probe",
    () {
      // The adapter constructs a real breaker, applies these events at the
      // supplied clock values and returns allow results in event order.
      final run =
          callPorted('pipeline.llm._Breaker.__init__', {
                'name': 'test',
                'fails': 1,
                'cool': 10,
                r'$script': {
                  'events': [
                    {'at': 100, 'op': 'failed'},
                    {'at': 100, 'op': 'allow'},
                    {
                      'at': 111,
                      'op': 'allowConcurrent',
                      'count': 40,
                      'workers': 12,
                    },
                    {'at': 111, 'op': 'failed'},
                    {'at': 111, 'op': 'allow'},
                    {'at': 122, 'op': 'allow'},
                    {'at': 122, 'op': 'ok'},
                    {'at': 122, 'op': 'allow'},
                  ],
                },
              })
              as Map<String, Object?>;
      expect(run['allowResults'], [false, false, true, true]);
      expect(run['concurrentAllowed'], 1);
    },
    skip:
        "Dart implementation of pipeline.llm._Breaker.__init__ is pending (A3, A4); required to check 'cooldown allows only one recovery probe'.",
  );
  test(
    "tests.test_judge_client.TeacherLog.test_parallel_writes_are_complete_and_have_one_state",
    () {
      final state = {'this_passage': repeatText('甲', 5000)};
      final run =
          callPorted('pipeline.llm._teacher_log', {
                'state': state,
                'questions': questions,
                'answers': answers,
                r'$script': {
                  'invocations': [
                    {'directory': 'main', 'count': 60, 'parallelism': 12},
                  ],
                },
              })
              as Map<String, Object?>;
      final directory = object(object(run['byDirectory'])['main']);
      final states = array(directory['states']);
      final rows = array(directory['questions']);
      expect(states, hasLength(1));
      expect(rows, hasLength(60));
      final stateHash = object(states.single)['h'];
      expect({for (final row in rows) object(row)['state']}, {stateHash});
      expect(rows.every((row) => object(row)['choice'] == 'yes'), isTrue);
    },
    skip:
        "Dart implementation of pipeline.llm._teacher_log is pending (A3, A4); required to check 'parallel writes are complete and have one state'.",
  );
  test(
    "tests.test_judge_client.TeacherLog.test_state_deduplication_is_scoped_to_log_directory",
    () {
      final run =
          callPorted('pipeline.llm._teacher_log', {
                'state': 'same state',
                'questions': questions,
                'answers': answers,
                r'$script': {
                  'invocations': [
                    {'directory': 'one', 'count': 1},
                    {'directory': 'two', 'count': 1},
                  ],
                },
              })
              as Map<String, Object?>;
      final directories = object(run['byDirectory']);
      expect(array(object(directories['one'])['states']), hasLength(1));
      expect(array(object(directories['two'])['states']), hasLength(1));
    },
    skip:
        "Dart implementation of pipeline.llm._teacher_log is pending (A3, A4); required to check 'state deduplication is scoped to log directory'.",
  );
  test(
    "tests.test_judge_client.TeacherLog.test_failed_state_write_is_visible_and_remains_retryable",
    () {
      final run =
          callPorted('pipeline.llm._teacher_log', {
                'state': 'state',
                'questions': questions,
                'answers': answers,
                r'$script': {
                  'invocations': [
                    {'directory': 'main', 'count': 1, 'failStateOpen': true},
                    {'directory': 'main', 'count': 1},
                  ],
                },
              })
              as Map<String, Object?>;
      final afterEach = array(run['afterEach']);
      expect(object(afterEach.first)['diagnostics'], contains('训练日志写入失败'));
      expect(object(afterEach.first)['seenCount'], 0);
      expect(
        array(object(object(run['byDirectory'])['main'])['states']),
        hasLength(1),
      );
    },
    skip:
        "Dart implementation of pipeline.llm._teacher_log is pending (A3, A4); required to check 'failed state write is visible and remains retryable'.",
  );
}
