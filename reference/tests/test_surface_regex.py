"""Pin dynamic KG surface patterns to the Python 3.11 production helper."""

from __future__ import annotations

import unittest

from oracle.semantics import record_surface_regex as oracle


class SurfaceRegexOracleTests(unittest.TestCase):
    def test_fixture_matches_kg_plan(self):
        self.assertEqual(oracle.FIXTURE.read_text(encoding='utf-8'), oracle.render())

    def test_dynamic_risks_are_represented(self):
        rows = {row['id']: row for row in oracle.record()}
        self.assertEqual(set(rows), {
            'cjk_astral_generic', 'latin_ascii_letter_boundaries',
            'overlap_longest_first', 'escaped_punctuation_and_space',
            'empty_surfaces', 'all_surfaces_filtered',
        })
        self.assertEqual(rows['cjk_astral_generic']['blocks'][0]['matches'][0]['span_cp'], [1, 3])
        self.assertEqual(rows['cjk_astral_generic']['blocks'][0]['matches'][0]['span_utf16'], [2, 4])
        self.assertEqual([row['surface'] for row in rows['overlap_longest_first']['plan_occurrences']],
                         ['李四郎', '李四', '李四郎'])
        self.assertIn(r'\ ', rows['escaped_punctuation_and_space']['python_pattern'])
        self.assertNotIn(r'\ ', rows['escaped_punctuation_and_space']['dart_pattern'])
        self.assertIsNone(rows['empty_surfaces']['python_pattern'])
        self.assertIsNone(rows['all_surfaces_filtered']['dart_pattern'])


if __name__ == '__main__':
    unittest.main()
