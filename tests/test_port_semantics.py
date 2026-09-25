"""The Python side of the cross-language semantic fixtures."""

import json
import hashlib
import unittest
from pathlib import Path

from oracle.semantics.record_general import evaluate

CASES = Path(__file__).resolve().parents[1] / "oracle" / "semantics" / "py_json.jsonl"
GENERAL = CASES.with_name("general.jsonl")
HASHES = CASES.with_name("hashes.jsonl")


class TestPyJsonOracle(unittest.TestCase):
    def test_ten_thousand_recorded_values_match_python(self):
        with CASES.open(encoding="utf-8") as source:
            for line in source:
                case = json.loads(line)
                with self.subTest(case=case["id"]):
                    actual = json.dumps(
                        case["value"],
                        ensure_ascii=case["ensure_ascii"],
                        sort_keys=case["sort_keys"],
                        separators=(",", ":") if case["compact"] else None,
                    )
                    self.assertEqual(actual, case["expected"])

    def test_non_finite_and_unicode_key_order(self):
        self.assertEqual(json.dumps([float("nan"), float("inf"), -float("inf")]),
                         "[NaN, Infinity, -Infinity]")
        self.assertEqual(json.dumps({"𠮷": 1, "\ue000": 2}, ensure_ascii=False,
                                    sort_keys=True), '{"\ue000": 2, "𠮷": 1}')
        with self.assertRaises(ValueError):
            json.dumps(float("nan"), allow_nan=False)


class TestGeneralSemanticOracle(unittest.TestCase):
    def test_recorded_general_cases_match_python(self):
        count = 0
        with GENERAL.open(encoding="utf-8") as source:
            for line in source:
                case = json.loads(line)
                with self.subTest(case=case["id"], op=case["op"]):
                    self.assertEqual(evaluate(case["op"], case["args"]),
                                     case["expected"])
                count += 1
        self.assertEqual(count, 5726)

    def test_hash_cases_match_python_and_frozen_source(self):
        count = 0
        with HASHES.open(encoding="utf-8") as source:
            for line in source:
                case = json.loads(line)
                ident = case["id"]
                if ident == "extractor-revision":
                    raw = (CASES.parents[2] / case["source"]).read_bytes()
                elif ident.startswith("utf8-"):
                    raw = case["value"].encode("utf-8")
                else:
                    serialized = json.dumps(
                        case["value"], ensure_ascii=False, sort_keys=True,
                        separators=(",", ":") if case["compact"] else None)
                    self.assertEqual(serialized, case["serialized"])
                    raw = serialized.encode("utf-8")
                with self.subTest(case=ident):
                    self.assertEqual(hashlib.sha256(raw).hexdigest(), case["sha256"])
                count += 1
        self.assertEqual(count, 12)


if __name__ == "__main__":
    unittest.main()
