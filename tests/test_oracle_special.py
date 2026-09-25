"""Keep special-function goldens reproducible from Python 3.11 source."""

from __future__ import annotations

import json
import unittest

from oracle.record.special import DEFAULT_OUT, generate


class SpecialOracleTests(unittest.TestCase):
    def test_regeneration_is_byte_identical(self):
        files = generate(DEFAULT_OUT, verify=True)
        self.assertEqual(set(files), {
            'describe_factory.jsonl', 'attr_facts.jsonl',
            'earlier_saga.jsonl', 'provenance.json',
        })
        provenance = json.loads(files['provenance.json'])
        self.assertEqual(provenance['passes'], 2)
        self.assertEqual(provenance['python'].split('.')[:2], ['3', '11'])

    def test_closure_and_callback_contracts_are_explicit(self):
        description = json.loads((DEFAULT_OUT / 'describe_factory.jsonl').read_text(encoding='utf-8'))
        self.assertEqual(description['input']['returned_closure_calls'], ['P1', 'P2'])
        self.assertEqual(len(description['output']), 2)

        attributes = json.loads((DEFAULT_OUT / 'attr_facts.jsonl').read_text(encoding='utf-8'))
        self.assertEqual(sorted(attributes['input']['who_of_map']), ['P1', 'P2'])
        self.assertEqual(sorted(attributes['output']), ['0', '2'])


if __name__ == '__main__':
    unittest.main()
