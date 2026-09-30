"""The source policy must fail on the markers it claims to check."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from docs.port.check_deferred_markers import find_markers


class CheckDeferredMarkersTests(unittest.TestCase):
    def test_reports_source_markers_with_line_numbers(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "sample.dart"
            source.write_text("final value = 1;\n// " + "TO" + "DO" + ": finish\n")
            self.assertEqual(
                find_markers([source]),
                [f"{source}:2: unresolved implementation marker"],
            )

    def test_ignores_unrelated_words_and_non_source_files(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "sample.dart"
            source.write_text("final hackathon = true;\n# todo is a regular word\n")
            prose = Path(directory) / "readme.md"
            prose.write_text("TO" + "DO" + ": documented here\n")
            self.assertEqual(find_markers([source, prose]), [])


if __name__ == "__main__":
    unittest.main()
