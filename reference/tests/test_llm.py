"""JSON repair for model output. run: python -m unittest tests.test_llm -v"""
import unittest

from pipeline.llm import parse_json


class RepairTest(unittest.TestCase):
    def test_inner_quote_followed_by_text(self):
        self.assertEqual(parse_json('{"t": "他说"好"然后走了"}')['t'], '他说"好"然后走了')

    def test_inner_quote_followed_by_ascii_comma(self):
        self.assertEqual(parse_json('{"t": "他喊"快走",大家散了", "n": 1}')['t'], '他喊"快走",大家散了')

    def test_inner_quote_followed_by_colon(self):
        self.assertEqual(parse_json('{"t": "她说:"好"", "n": 1}')['t'], '她说:"好"')

    def test_fences_and_trailing_commas(self):
        self.assertEqual(parse_json('```json\n{"a": [1, 2,],}\n```'), {'a': [1, 2]})

    def test_valid_json_untouched(self):
        self.assertEqual(parse_json('{"a": "x", "b": ["y", "z"], "c": true}'), {'a': 'x', 'b': ['y', 'z'], 'c': True})


if __name__ == '__main__':
    unittest.main()
