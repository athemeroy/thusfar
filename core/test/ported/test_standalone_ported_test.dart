// Translated Python 1.7.5 Android-mode contracts; enabled by their A stages.
import 'package:test/test.dart';

import 'contract_invoker.dart';

Map<String, Object?> _scenario(String owner, Map<String, Object?> input) =>
    callPorted(owner, input) as Map<String, Object?>;

void main() {
  test(
    "tests.test_standalone.ThreadWorker.test_manual_start_cancel_resume_and_lock_release",
    () {
      // The A5 test adapter runs two scripted pipelines on one Worker. The
      // first waits for cancellation; the second publishes done.
      final result = _scenario('server.jobs.Worker.__init__', {
        'mode': 'thread',
        'initial': {
          'meta': {'auto': false},
          'status': {'state': 'idle'},
        },
        'pipeline': ['waitUntilCancelled', 'publishDone'],
        'actions': [
          'start',
          'setAutoTrue',
          'cancel',
          'acquireBookLease',
          'setAutoTrue',
          'awaitDone',
          'stopAndJoin',
        ],
      });
      expect(result['firstStarted'], isTrue);
      expect(result['statusAfterCancel'], 'paused');
      expect(result['autoAfterCancel'], isFalse);
      expect(result['leaseAfterCancel'], isTrue);
      expect(result['secondFinished'], isTrue);
      expect(result['finalStatus'], 'done');
      expect(result['pipelineCalls'], 2);
      expect(result['subprocessCalls'], 0);
    },
    skip: 'A5 thread Worker and lock test adapter are pending.',
  );
  test(
    "tests.test_standalone.ThreadWorker.test_pipeline_pre_cancel_releases_its_file_lock",
    () {
      final result = _scenario('pipeline.run.run_book', {
        'cancelBeforeStart': true,
        'checkBookLeaseAfterException': true,
      });
      expect(result['errorType'], 'Cancelled');
      expect(result['leaseAcquiredAfterCancel'], isTrue);
    },
    skip: 'A5 run_book pre-cancel and file lease adapter are pending.',
  );
  test(
    "tests.test_standalone.PrivateSettings.test_cost_prompt_does_not_quote_a_paid_judge_or_unknown_model_price",
    () {
      final free = _scenario('pipeline.models.estimate', {
        'chars': 100000,
        'model': 'deepseek-flash+nothink',
        'env': {'JEV_ROUTE': 'free-only', 'MODEL_PRICES': '{}'},
      });
      final unknown = _scenario('pipeline.models.estimate', {
        'chars': 100000,
        'model': 'private-reader-model',
        'env': {'JEV_ROUTE': 'free-only', 'MODEL_PRICES': '{}'},
      });
      final paid = _scenario('pipeline.models.estimate', {
        'chars': 100000,
        'model': 'deepseek-flash+nothink',
        'env': {'JEV_ROUTE': 'paid', 'MODEL_PRICES': '{}'},
      });
      expect((free['high'] as num) < (paid['high'] as num), isTrue);
      expect(unknown['high'], isNull);
    },
    skip: 'A1 model estimate and injected JEV-route adapter are pending.',
  );
  test(
    "tests.test_standalone.PrivateSettings.test_saved_model_is_used_by_questions_comments_and_new_pipeline_jobs",
    () {
      const sampleKey = 'temporary-example-key';
      final result = _scenario('server.model_settings.save', {
        'settings': {
          'base_url': 'https://models.example/v1',
          'model': 'reader-model',
          'api_key': sampleKey,
          'jev_route': 'free-only',
        },
        'readAfterSave': [
          'llm.base_for(openai)',
          'llm.key_for(reader-model)',
          'ask.QA_MODEL',
          'marginalia.MODEL',
          'marginalia.AUTO_MODEL',
          'CLASSIFY_MODEL',
        ],
      });
      expect(result['llm.base_for(openai)'], 'https://models.example/v1');
      expect(result['llm.key_for(reader-model)'], sampleKey);
      for (final name in [
        'ask.QA_MODEL',
        'marginalia.MODEL',
        'marginalia.AUTO_MODEL',
        'CLASSIFY_MODEL',
      ]) {
        expect(result[name], 'reader-model', reason: name);
      }
    },
    skip: 'A3/A6 settings persistence and model routing adapter are pending.',
  );
  test(
    "tests.test_standalone.PrivateSettings.test_key_is_private_and_never_returned_by_api",
    () {
      const sampleKey = 'private-example-4321';
      final result = _scenario('server.app.Handler.route', {
        'fixture': 'HTTPRepair.localMode',
        'steps': [
          {
            'method': 'PUT',
            'path': '/api/settings',
            'body': {
              'base_url': 'https://api.deepseek.com/v1',
              'model': 'deepseek-flash+nothink',
              'api_key': sampleKey,
              'jev_route': 'free-only',
            },
          },
          {'method': 'GET', 'path': '/api/settings'},
        ],
        'inspectSecretsFileMode': true,
      });
      final responses =
          (result['responses'] as List<Object?>).cast<Map<String, Object?>>();
      expect(responses[0]['status'], 200);
      expect(responses[0]['rawBody'].toString(), isNot(contains(sampleKey)));
      expect(
        (responses[0]['body'] as Map<String, Object?>)['api_key_last4'],
        '4321',
      );
      expect(result['secretsFileMode'], 384); // 0600
      expect(responses[1]['status'], 200);
      expect(responses[1]['rawBody'].toString(), isNot(contains(sampleKey)));
      expect(
        (responses[1]['body'] as Map<String, Object?>).containsKey('api_key'),
        isFalse,
      );
    },
    skip: 'A6 settings HTTP route and private-file adapter are pending.',
  );
  test(
    "tests.test_standalone.PrivateSettings.test_processing_without_a_key_is_refused_with_the_reason",
    () {
      final result = _scenario('server.app.Handler.route', {
        'fixture': 'HTTPRepair.localModeIdleBook',
        'secretsFile': 'absent',
        'steps': [
          {'method': 'POST', 'path': '/api/books/fixture/process'},
        ],
        'inspectStatus': true,
      });
      final response =
          (result['responses'] as List<Object?>).first as Map<String, Object?>;
      expect(response['status'], 409);
      expect(
        (response['body'] as Map<String, Object?>)['error'],
        contains('API 密钥'),
      );
      expect(result['statusState'], isNot('queued'));
    },
    skip: 'A6 processing admission and missing-key HTTP adapter are pending.',
  );
  test(
    "tests.test_standalone.PrivateSettings.test_unread_post_body_does_not_poison_the_next_request_on_the_same_connection",
    () {
      final result = _scenario('server.app.Handler.route', {
        'fixture': 'HTTPRepair.localModeIdleBook',
        'oneTcpConnection': true,
        'steps': [
          {
            'method': 'POST',
            'path': '/api/books/fixture/process',
            'bodyUtf8': '{}',
            'contentType': 'application/json',
          },
          {'method': 'GET', 'path': '/api/books'},
          {'directive': 'installSampleKey'},
          {
            'method': 'POST',
            'path': '/api/books/fixture/process',
            'bodyUtf8': '{}',
            'contentType': 'application/json',
          },
          {'method': 'GET', 'path': '/api/books'},
        ],
      });
      final responses =
          (result['responses'] as List<Object?>).cast<Map<String, Object?>>();
      expect(responses.map((row) => row['status']), [409, 200, 200, 200]);
      expect(responses[1]['body'], isA<List<Object?>>());
      expect(responses[3]['body'], isA<List<Object?>>());
      expect(result['sameSocketAfterSuccess'], isTrue);
    },
    skip:
        'A6 persistent HTTP connection and unread-body draining adapter are pending.',
  );
  test(
    "tests.test_standalone.ModelFailures.test_hopeless_failures_are_explained_and_transient_ones_are_not",
    () {
      Object? explain(String type, String message) =>
          callPorted('pipeline.llm.explain', {
            'error': {
              '\$error': {'type': type, 'message': message},
            },
          });
      const llmError = 'pipeline.llm.LLMError';
      expect(explain(llmError, '缺少模型访问密钥'), contains('模型设置'));
      const unauthorized =
          'HTTP 401: {"error":{"message":"Authentication Fails"}}';
      expect(explain(llmError, unauthorized), contains('HTTP 401'));
      expect(explain(llmError, unauthorized), contains('Authentication Fails'));
      expect(
        explain(
          llmError,
          'HTTP 402: {"error":{"message":"Insufficient Balance"}}',
        ),
        contains('余额'),
      );
      expect(explain(llmError, 'HTTP 400: Model Not Exist'), contains('模型名'));
      expect(explain(llmError, 'HTTP 503: busy'), isNull);
      expect(explain('builtins.TimeoutError', 'timed out'), isNull);
      expect(explain(llmError, '模型调用失败：NOT_API: 接口地址返回的是网页'), contains('/v1'));
      expect(explain(llmError, 'THINKING_ONLY: 只思考'), contains('+nothink'));
    },
    skip: 'A3 pipeline.llm.explain is pending.',
  );
  test(
    "tests.test_standalone.ModelFailures.test_a_refusal_is_named_without_a_second_fix_call",
    () {
      final result = _scenario('pipeline.local.extract_local', {
        'seg': {'o0': 0, 'o1': 10, 'chars': 10, 'chapter': 0},
        'model': 'deepseek-flash+nothink',
        'buildMessages': <Object?>[],
        'scriptedChat': [
          {'text': '抱歉，我无法回答这个问题。', 'usage': <String, Object?>{}},
        ],
      });
      expect(result['error'], startsWith('REFUSED:'));
      expect(result['chatCalls'], 1);
    },
    skip: 'A4 refusal handling and scripted model adapter are pending.',
  );
  test(
    "tests.test_standalone.ModelFailures.test_a_hung_stream_is_given_up_on_in_proportion_to_the_model",
    () {
      final result = _scenario('pipeline.llm._stall_timeout', {
        'initialTimeoutEnv': '',
        'recordReplies': {
          'fast': [8, 12, 10],
          'slow': [150, 175, 160],
        },
        'overrideTimeoutEnv': '42',
      });
      expect(result['beforeSamplesFast'], 300);
      expect(result['afterSamplesFast'], 90);
      expect(result['afterSamplesSlow'], 525);
      expect(result['withOverrideFast'], 42);
    },
    skip: 'A3 adaptive stream timeout and injected clock adapter are pending.',
  );
  test(
    "tests.test_standalone.ModelFailures.test_settings_fill_in_v1_and_nothink",
    () {
      Object? normalize(String url, String model) => callPorted(
        'server.model_settings.normalize',
        {'url': url, 'model': model},
      );
      expect(normalize('https://open.example.com/', 'deepseek-flash'), {
        '\$tuple': ['https://open.example.com/v1', 'deepseek-flash+nothink'],
      });
      expect(normalize('https://api.example.com/v1beta/openai', 'gpt-6-luna'), {
        '\$tuple': ['https://api.example.com/v1beta/openai', 'gpt-6-luna'],
      });
      final deepseek =
          normalize('https://api.deepseek.com/v1', 'deepseek-flash+think')
              as Map<String, Object?>;
      expect((deepseek['\$tuple'] as List<Object?>)[1], 'deepseek-flash+think');
    },
    skip: 'A6 model-settings normalization is pending.',
  );
  test(
    "tests.test_standalone.ModelFailures.test_web_page_and_thinking_only_replies_are_named",
    () {
      final result = _scenario('pipeline.llm.chat', {
        'model': 'deepseek-flash',
        'messages': [
          {'role': 'user', 'content': 'x'},
        ],
        'retries': 0,
        'transportScript': [
          {
            'contentType': 'text/html; charset=utf-8',
            'bodyUtf8': '<!doctype html><html></html>',
          },
          {
            'contentType': 'text/event-stream',
            'bodyUtf8':
                'data: {"choices":[{"delta":{"reasoning_content":"hmm"}}]}\n\ndata: [DONE]\n\n',
          },
        ],
      });
      final failures =
          (result['failures'] as List<Object?>).cast<Map<String, Object?>>();
      expect(failures, hasLength(2));
      expect(failures[0]['type'], 'LLMError');
      expect(failures[0]['explanation'], contains('/v1'));
      expect(failures[1]['type'], 'LLMError');
      expect(failures[1]['explanation'], contains('+nothink'));
    },
    skip:
        'A3 synthetic HTTP response and error explanation adapter are pending.',
  );
}
