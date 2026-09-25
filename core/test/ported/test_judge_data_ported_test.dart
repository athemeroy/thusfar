// Generated from docs/port/inventory.json by core/tool/generate_ported_tests.py.
// Skipped failing callbacks are unported assertions, not translations.
import 'package:test/test.dart';

void main() {
  test(
    "tests.test_judge_data.StateFormat.test_export_matches_what_the_pipeline_sends",
    () => fail(
      "Dart port not implemented: tests.test_judge_data.StateFormat.test_export_matches_what_the_pipeline_sends",
    ),
    skip:
        "Dart implementation of pipeline.llm._state_text is pending (A3); required to check 'export matches what the pipeline sends'.",
  );
  test(
    "tests.test_judge_data.Windowing.test_finds_what_the_claim_borrowed_from_the_passage",
    () => fail(
      "Dart port not implemented: tests.test_judge_data.Windowing.test_finds_what_the_claim_borrowed_from_the_passage",
    ),
    skip:
        "Dart implementation of pipeline.llm is pending (A3); required to check 'finds what the claim borrowed from the passage'.",
  );
  test(
    "tests.test_judge_data.Windowing.test_keeps_the_people_the_question_names",
    () => fail(
      "Dart port not implemented: tests.test_judge_data.Windowing.test_keeps_the_people_the_question_names",
    ),
    skip:
        "Dart implementation of pipeline.llm is pending (A3); required to check 'keeps the people the question names'.",
  );
  test(
    "tests.test_judge_data.Windowing.test_no_anchor_keeps_the_passage_rather_than_its_opening",
    () => fail(
      "Dart port not implemented: tests.test_judge_data.Windowing.test_no_anchor_keeps_the_passage_rather_than_its_opening",
    ),
    skip:
        "Dart implementation of pipeline.llm is pending (A3); required to check 'no anchor keeps the passage rather than its opening'.",
  );
  test(
    "tests.test_judge_data.Splits.test_full_evidence_and_options_distinguish_questions",
    () => fail(
      "Dart port not implemented: tests.test_judge_data.Splits.test_full_evidence_and_options_distinguish_questions",
    ),
    skip:
        "Dart implementation of pipeline.llm is pending (A3); required to check 'full evidence and options distinguish questions'.",
  );
  test(
    "tests.test_judge_data.Splits.test_reruns_of_one_book_are_one_work",
    () => fail(
      "Dart port not implemented: tests.test_judge_data.Splits.test_reruns_of_one_book_are_one_work",
    ),
    skip:
        "Dart implementation of pipeline.llm is pending (A3); required to check 'reruns of one book are one work'.",
  );
  test(
    "tests.test_judge_data.Labels.test_options_become_english_sentences",
    () => fail(
      "Dart port not implemented: tests.test_judge_data.Labels.test_options_become_english_sentences",
    ),
    skip:
        "Dart implementation of pipeline.llm is pending (A3); required to check 'options become english sentences'.",
  );
  test(
    "tests.test_judge_data.Labels.test_two_options_never_collapse_into_one_label",
    () => fail(
      "Dart port not implemented: tests.test_judge_data.Labels.test_two_options_never_collapse_into_one_label",
    ),
    skip:
        "Dart implementation of pipeline.llm is pending (A3); required to check 'two options never collapse into one label'.",
  );
  test(
    "tests.test_judge_data.Labels.test_round_trip_through_the_wire_format",
    () => fail(
      "Dart port not implemented: tests.test_judge_data.Labels.test_round_trip_through_the_wire_format",
    ),
    skip:
        "Dart implementation of pipeline.llm is pending (A3); required to check 'round trip through the wire format'.",
  );
  test(
    "tests.test_judge_data.LogIntegrity.test_missing_state_is_not_exported_as_empty_passage",
    () => fail(
      "Dart port not implemented: tests.test_judge_data.LogIntegrity.test_missing_state_is_not_exported_as_empty_passage",
    ),
    skip:
        "Dart implementation of pipeline.llm is pending (A3); required to check 'missing state is not exported as empty passage'.",
  );
  test(
    "tests.test_judge_data.LogIntegrity.test_corrupt_interior_line_is_not_silently_skipped",
    () => fail(
      "Dart port not implemented: tests.test_judge_data.LogIntegrity.test_corrupt_interior_line_is_not_silently_skipped",
    ),
    skip:
        "Dart implementation of pipeline.llm is pending (A3); required to check 'corrupt interior line is not silently skipped'.",
  );
}
