// Generated from docs/port/inventory.json by core/tool/generate_ported_tests.py.
// Some callbacks contain translated assertions but remain skipped until their Dart owners exist.
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

void main() {
  test(
    "tests.test_judge_client.JudgeClient.test_explicit_zero_retries_overrides_default_without_final_sleep",
    () => fail(
      "Dart port not implemented: tests.test_judge_client.JudgeClient.test_explicit_zero_retries_overrides_default_without_final_sleep",
    ),
    skip:
        "Dart implementation of pipeline.llm.jev is pending (A3, A4); required to check 'explicit zero retries overrides default without final sleep'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_lower_environment_retry_count_is_honored",
    () => fail(
      "Dart port not implemented: tests.test_judge_client.JudgeClient.test_lower_environment_retry_count_is_honored",
    ),
    skip:
        "Dart implementation of pipeline.llm.jev is pending (A3, A4); required to check 'lower environment retry count is honored'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_success_after_retry_is_validated_and_logged_once",
    () => fail(
      "Dart port not implemented: tests.test_judge_client.JudgeClient.test_success_after_retry_is_validated_and_logged_once",
    ),
    skip:
        "Dart implementation of pipeline.llm.jev is pending (A3, A4); required to check 'success after retry is validated and logged once'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_timeout_exhaustion_has_no_final_sleep",
    () => fail(
      "Dart port not implemented: tests.test_judge_client.JudgeClient.test_timeout_exhaustion_has_no_final_sleep",
    ),
    skip:
        "Dart implementation of pipeline.llm.jev is pending (A3, A4); required to check 'timeout exhaustion has no final sleep'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_free_long_retry_advice_falls_back_immediately",
    () => fail(
      "Dart port not implemented: tests.test_judge_client.JudgeClient.test_free_long_retry_advice_falls_back_immediately",
    ),
    skip:
        "Dart implementation of pipeline.llm.jev is pending (A3, A4); required to check 'free long retry advice falls back immediately'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_free_exhaustion_has_no_final_sleep",
    () => fail(
      "Dart port not implemented: tests.test_judge_client.JudgeClient.test_free_exhaustion_has_no_final_sleep",
    ),
    skip:
        "Dart implementation of pipeline.llm.jev_free is pending (A3, A4); required to check 'free exhaustion has no final sleep'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_free_valid_response_keeps_wire_contract",
    () => fail(
      "Dart port not implemented: tests.test_judge_client.JudgeClient.test_free_valid_response_keeps_wire_contract",
    ),
    skip:
        "Dart implementation of pipeline.llm.jev_free is pending (A3, A4); required to check 'free valid response keeps wire contract'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_free_batches_honor_serialized_unicode_dimension_limit",
    () => fail(
      "Dart port not implemented: tests.test_judge_client.JudgeClient.test_free_batches_honor_serialized_unicode_dimension_limit",
    ),
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
    () => fail(
      "Dart port not implemented: tests.test_judge_client.JudgeClient.test_long_guard_note_is_kept_in_state_with_short_instructions",
    ),
    skip:
        "Dart implementation of pipeline.judge.guard_texts is pending (A3, A4); required to check 'long guard note is kept in state with short instructions'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_oversized_single_dimension_goes_paid_without_partial_free_calls",
    () => fail(
      "Dart port not implemented: tests.test_judge_client.JudgeClient.test_oversized_single_dimension_goes_paid_without_partial_free_calls",
    ),
    skip:
        "Dart implementation of pipeline.llm.jev is pending (A3, A4); required to check 'oversized single dimension goes paid without partial free calls'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_missing_paid_answers_are_not_logged_as_training_labels",
    () => fail(
      "Dart port not implemented: tests.test_judge_client.JudgeClient.test_missing_paid_answers_are_not_logged_as_training_labels",
    ),
    skip:
        "Dart implementation of pipeline.llm.jev is pending (A3, A4); required to check 'missing paid answers are not logged as training labels'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_invalid_paid_scores_are_rejected",
    () => fail(
      "Dart port not implemented: tests.test_judge_client.JudgeClient.test_invalid_paid_scores_are_rejected",
    ),
    skip:
        "Dart implementation of pipeline.llm.jev is pending (A3, A4); required to check 'invalid paid scores are rejected'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_malformed_or_missing_free_dimensions_are_rejected",
    () => fail(
      "Dart port not implemented: tests.test_judge_client.JudgeClient.test_malformed_or_missing_free_dimensions_are_rejected",
    ),
    skip:
        "Dart implementation of pipeline.llm.jev_free is pending (A3, A4); required to check 'malformed or missing free dimensions are rejected'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_chat_exhaustion_has_no_final_sleep",
    () => fail(
      "Dart port not implemented: tests.test_judge_client.JudgeClient.test_chat_exhaustion_has_no_final_sleep",
    ),
    skip:
        "Dart implementation of pipeline.llm.chat is pending (A3, A4); required to check 'chat exhaustion has no final sleep'.",
  );
  test(
    "tests.test_judge_client.JudgeClient.test_retry_after_dates_and_invalid_values",
    () => fail(
      "Dart port not implemented: tests.test_judge_client.JudgeClient.test_retry_after_dates_and_invalid_values",
    ),
    skip:
        "Dart implementation of pipeline.llm._retry_after is pending (A3, A4); required to check 'retry after dates and invalid values'.",
  );
  test(
    "tests.test_judge_client.Breaker.test_cooldown_allows_only_one_recovery_probe",
    () => fail(
      "Dart port not implemented: tests.test_judge_client.Breaker.test_cooldown_allows_only_one_recovery_probe",
    ),
    skip:
        "Dart implementation of pipeline.llm._Breaker.__init__ is pending (A3, A4); required to check 'cooldown allows only one recovery probe'.",
  );
  test(
    "tests.test_judge_client.TeacherLog.test_parallel_writes_are_complete_and_have_one_state",
    () => fail(
      "Dart port not implemented: tests.test_judge_client.TeacherLog.test_parallel_writes_are_complete_and_have_one_state",
    ),
    skip:
        "Dart implementation of pipeline.llm._teacher_log is pending (A3, A4); required to check 'parallel writes are complete and have one state'.",
  );
  test(
    "tests.test_judge_client.TeacherLog.test_state_deduplication_is_scoped_to_log_directory",
    () => fail(
      "Dart port not implemented: tests.test_judge_client.TeacherLog.test_state_deduplication_is_scoped_to_log_directory",
    ),
    skip:
        "Dart implementation of pipeline.llm._teacher_log is pending (A3, A4); required to check 'state deduplication is scoped to log directory'.",
  );
  test(
    "tests.test_judge_client.TeacherLog.test_failed_state_write_is_visible_and_remains_retryable",
    () => fail(
      "Dart port not implemented: tests.test_judge_client.TeacherLog.test_failed_state_write_is_visible_and_remains_retryable",
    ),
    skip:
        "Dart implementation of pipeline.llm._teacher_log is pending (A3, A4); required to check 'failed state write is visible and remains retryable'.",
  );
}
