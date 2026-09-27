"""Check the frozen Python context window used as the Dart port oracle."""

import json
from pathlib import Path
from types import SimpleNamespace
import unittest

from pipeline.run import Runner
from oracle.semantics.record_utf16_offsets import render


FIXTURE = Path(__file__).resolve().parents[1] / 'oracle/semantics/utf16_offsets.json'


class FrozenUtf16Offsets(unittest.TestCase):
    def test_recording_is_current(self):
        self.assertEqual(FIXTURE.read_text(encoding='utf-8'), render())

    def test_context_window_matches_frozen_python(self):
        data = json.loads(FIXTURE.read_text(encoding='utf-8'))
        self.assertEqual(len(data['cases']), 4)
        for case in data['cases']:
            with self.subTest(case=case['id']):
                book = {'blocks': [{'o': 0, 't': case['text']}]}
                actual = Runner._text_around(SimpleNamespace(book=book),
                                             case['position_utf16'], case['width_codepoints'])
                self.assertEqual(actual, case['frozen_175'])
        self.assertNotEqual(data['cases'][1]['frozen_175'], data['cases'][1]['codepoint_centered'])


if __name__ == '__main__':
    unittest.main()
