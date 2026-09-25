// Generated from docs/port/inventory.json by core/tool/generate_ported_tests.py.
// Skipped failing callbacks are unported assertions, not translations.
import 'package:test/test.dart';

import 'contract_invoker.dart';

void main() {
  test(
    "tests.test_standalone.ThreadWorker.test_manual_start_cancel_resume_and_lock_release",
    () => fail(
      "Dart port not implemented: tests.test_standalone.ThreadWorker.test_manual_start_cancel_resume_and_lock_release",
    ),
    skip:
        "Dart implementation of server.jobs.Worker.__init__, server.jobs.book_lease, server.storage.JsonCache.__init__, server.storage.write_json is pending (A1/A6, A5, A6); required to check 'manual start cancel resume and lock release'.",
  );
  test(
    "tests.test_standalone.ThreadWorker.test_pipeline_pre_cancel_releases_its_file_lock",
    () => fail(
      "Dart port not implemented: tests.test_standalone.ThreadWorker.test_pipeline_pre_cancel_releases_its_file_lock",
    ),
    skip:
        "Dart implementation of pipeline.run.run_book, server.jobs.book_lease is pending (A1/A6, A5, A6); required to check 'pipeline pre cancel releases its file lock'.",
  );
  test(
    "tests.test_standalone.PrivateSettings.test_cost_prompt_does_not_quote_a_paid_judge_or_unknown_model_price",
    () => fail(
      "Dart port not implemented: tests.test_standalone.PrivateSettings.test_cost_prompt_does_not_quote_a_paid_judge_or_unknown_model_price",
    ),
    skip:
        "Dart implementation of pipeline.models.estimate is pending (A1, A1/A6, A5, A6); required to check 'cost prompt does not quote a paid judge or unknown model price'.",
  );
  test(
    "tests.test_standalone.PrivateSettings.test_saved_model_is_used_by_questions_comments_and_new_pipeline_jobs",
    () => fail(
      "Dart port not implemented: tests.test_standalone.PrivateSettings.test_saved_model_is_used_by_questions_comments_and_new_pipeline_jobs",
    ),
    skip:
        "Dart implementation of pipeline.llm.base_for, pipeline.llm.key_for, server.model_settings.save is pending (A1/A6, A3, A5, A6); required to check 'saved model is used by questions comments and new pipeline jobs'.",
  );
  test(
    "tests.test_standalone.PrivateSettings.test_key_is_private_and_never_returned_by_api",
    () => fail(
      "Dart port not implemented: tests.test_standalone.PrivateSettings.test_key_is_private_and_never_returned_by_api",
    ),
    skip:
        "Dart implementation of pipeline.run, server.app, server.jobs, server.storage is pending (A1/A6, A5, A6); required to check 'key is private and never returned by api'.",
  );
  test(
    "tests.test_standalone.PrivateSettings.test_processing_without_a_key_is_refused_with_the_reason",
    () => fail(
      "Dart port not implemented: tests.test_standalone.PrivateSettings.test_processing_without_a_key_is_refused_with_the_reason",
    ),
    skip:
        "Dart implementation of server.app.cached_json is pending (A1/A6, A5, A6); required to check 'processing without a key is refused with the reason'.",
  );
  test(
    "tests.test_standalone.PrivateSettings.test_unread_post_body_does_not_poison_the_next_request_on_the_same_connection",
    () => fail(
      "Dart port not implemented: tests.test_standalone.PrivateSettings.test_unread_post_body_does_not_poison_the_next_request_on_the_same_connection",
    ),
    skip:
        "Dart implementation of pipeline.run, server.app, server.jobs, server.storage is pending (A1/A6, A5, A6); required to check 'unread post body does not poison the next request on the same connection'.",
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
    skip:
        "Dart implementation of pipeline.llm.explain is pending (A1/A6, A3, A5, A6); required to check 'hopeless failures are explained and transient ones are not'.",
  );
  test(
    "tests.test_standalone.ModelFailures.test_a_refusal_is_named_without_a_second_fix_call",
    () => fail(
      "Dart port not implemented: tests.test_standalone.ModelFailures.test_a_refusal_is_named_without_a_second_fix_call",
    ),
    skip:
        "Dart implementation of pipeline.local.extract_local is pending (A1/A6, A4, A5, A6); required to check 'a refusal is named without a second fix call'.",
  );
  test(
    "tests.test_standalone.ModelFailures.test_a_hung_stream_is_given_up_on_in_proportion_to_the_model",
    () => fail(
      "Dart port not implemented: tests.test_standalone.ModelFailures.test_a_hung_stream_is_given_up_on_in_proportion_to_the_model",
    ),
    skip:
        "Dart implementation of pipeline.llm._record_reply, pipeline.llm._stall_timeout is pending (A1/A6, A3, A5, A6); required to check 'a hung stream is given up on in proportion to the model'.",
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
    skip:
        "Dart implementation of server.model_settings.normalize is pending (A1/A6, A5, A6); required to check 'settings fill in v1 and nothink'.",
  );
  test(
    "tests.test_standalone.ModelFailures.test_web_page_and_thinking_only_replies_are_named",
    () => fail(
      "Dart port not implemented: tests.test_standalone.ModelFailures.test_web_page_and_thinking_only_replies_are_named",
    ),
    skip:
        "Dart implementation of pipeline.llm.chat, pipeline.llm.explain is pending (A1/A6, A3, A5, A6); required to check 'web page and thinking only replies are named'.",
  );
}
