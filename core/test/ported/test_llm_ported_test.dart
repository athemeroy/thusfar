// Generated from docs/port/inventory.json by core/tool/generate_ported_tests.py.
// Some callbacks contain translated assertions but remain skipped until their Dart owners exist.
import 'package:test/test.dart';

import 'contract_invoker.dart';

void main() {
  test(
    "tests.test_llm.RepairTest.test_inner_quote_followed_by_text",
    () {
      final result =
          callPorted('pipeline.llm.parse_json', {'text': '{"t": "他说"好"然后走了"}'})
              as Map<String, Object?>;
      expect(result['t'], '他说"好"然后走了');
    },
    skip:
        "Dart implementation of pipeline.llm.parse_json is pending (A3); required to check 'inner quote followed by text'.",
  );
  test(
    "tests.test_llm.RepairTest.test_inner_quote_followed_by_ascii_comma",
    () {
      final result =
          callPorted('pipeline.llm.parse_json', {
                'text': '{"t": "他喊"快走",大家散了", "n": 1}',
              })
              as Map<String, Object?>;
      expect(result['t'], '他喊"快走",大家散了');
    },
    skip:
        "Dart implementation of pipeline.llm.parse_json is pending (A3); required to check 'inner quote followed by ascii comma'.",
  );
  test(
    "tests.test_llm.RepairTest.test_inner_quote_followed_by_colon",
    () {
      final result =
          callPorted('pipeline.llm.parse_json', {
                'text': '{"t": "她说:"好"", "n": 1}',
              })
              as Map<String, Object?>;
      expect(result['t'], '她说:"好"');
    },
    skip:
        "Dart implementation of pipeline.llm.parse_json is pending (A3); required to check 'inner quote followed by colon'.",
  );
  test(
    "tests.test_llm.RepairTest.test_fences_and_trailing_commas",
    () {
      expect(
        callPorted('pipeline.llm.parse_json', {
          'text': '```json\n{"a": [1, 2,],}\n```',
        }),
        {
          'a': [1, 2],
        },
      );
    },
    skip:
        "Dart implementation of pipeline.llm.parse_json is pending (A3); required to check 'fences and trailing commas'.",
  );
  test(
    "tests.test_llm.RepairTest.test_valid_json_untouched",
    () {
      expect(
        callPorted('pipeline.llm.parse_json', {
          'text': '{"a": "x", "b": ["y", "z"], "c": true}',
        }),
        {
          'a': 'x',
          'b': ['y', 'z'],
          'c': true,
        },
      );
    },
    skip:
        "Dart implementation of pipeline.llm.parse_json is pending (A3); required to check 'valid json untouched'.",
  );
}
