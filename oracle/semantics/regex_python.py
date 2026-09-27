#!/usr/bin/env python3
"""Execute the regex audit's positive and negative examples with Python re."""

from __future__ import annotations

import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
DATA = json.loads((ROOT / "docs/port/REGEX.json").read_text(encoding="utf-8"))
FLAG_BITS = {"I": re.I, "M": re.M, "S": re.S, "X": re.X, "A": re.A}


class RegexAuditTests(unittest.TestCase):
    def check_case(self, site: str, pattern: str, encoding: str, flags: list[str], examples: dict) -> None:
        compiled = re.compile(pattern.encode("latin1") if encoding == "bytes" else pattern,
                              sum(FLAG_BITS[flag] for flag in flags))
        mode = examples["mode"]
        test = compiled.fullmatch if mode == "fullmatch" else compiled.match if mode == "match" else compiled.search
        for label, expected in (("positive", True), ("negative", False)):
            text = examples[label]
            self.assertIsNotNone(text, f"{site}: missing {label}")
            probe = text.encode("latin1") if encoding == "bytes" else text
            self.assertEqual(test(probe) is not None, expected, f"{site}: {label} {text!r}")

    def test_every_static_pattern(self) -> None:
        sites = 0
        for row in DATA["calls"]:
            if row["examples"] is not None:
                with self.subTest(site=row["id"]):
                    self.check_case(row["id"], row["pattern"], row["pattern_encoding"], row["flags"], row["examples"])
                sites += 1
            for name, variant in row.get("variant_examples", {}).items():
                with self.subTest(site=row["id"], variant=name):
                    self.check_case(f"{row['id']}:{name}", variant["pattern"], "text", row["flags"], variant["examples"])
                sites += 1
        self.assertEqual(sites, 153)

    def test_call_coverage(self) -> None:
        direct = [row for row in DATA["calls"] if row["receiver"] is None]
        self.assertEqual(len(direct), 112)
        self.assertEqual(sum(row["module"] == "pipeline.parse" for row in direct), 34)
        self.assertEqual(len(DATA["calls"]), 148)
        self.assertTrue(all(row["receiver"] is not None or row["operation"] in dir(re) for row in DATA["calls"]))


if __name__ == "__main__":
    unittest.main()
