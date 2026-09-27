"""Keep the shared operation-level regex fixture pinned to Python 3.11."""

import unittest

from oracle.semantics import record_regex_operations as oracle


class RegexOperationOracleTests(unittest.TestCase):
    def test_fixture_matches_python_311(self):
        self.assertEqual(oracle.FIXTURE.read_text(encoding="utf-8"), oracle.render())

    def test_operation_and_risk_coverage(self):
        rows = oracle.record()
        self.assertEqual(len(rows), 26)
        self.assertEqual(len({row["id"] for row in rows}), 26)
        self.assertEqual(
            {row["topic"] for row in rows},
            {"named_captures", "match_vs_search", "unicode_word_boundary", "unicode_classes",
             "flags_S_M_X", "fullmatch", "split_captured_groups",
             "sub_replacement", "span_codepoint_utf16"},
        )
        self.assertEqual({row["operation"] for row in rows},
                         {"search", "match", "fullmatch", "split", "sub"})
        by_id = {row["id"]: row["expected"] for row in rows}
        self.assertFalse(by_id["unicode_word_boundary_reject_inside_han"]["matched"])
        self.assertEqual(by_id["span_astral_prefix"]["span_cp"], [2, 3])
        self.assertEqual(by_id["span_astral_prefix"]["span_utf16"], [4, 5])
        self.assertEqual(by_id["split_optional_group_null"]["parts"][2], None)
        self.assertFalse(by_id["fullmatch_trailing_newline"]["matched"])
        self.assertFalse(by_id["unicode_decimal_reject_superscript"]["matched"])
        self.assertTrue(by_id["unicode_word_accept_superscript"]["matched"])


if __name__ == "__main__":
    unittest.main()
