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
            'earlier_saga.jsonl', 'manual_base.jsonl',
            'manual_mentions.jsonl', 'manual_restore.jsonl',
            'manual_rows.jsonl', 'marginalia_key.jsonl',
            'notebook_validate.jsonl', 'provenance.json',
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

    def test_fixed_revision_hashes_and_rejections_are_preserved(self):
        keys = [json.loads(line) for line in
                (DEFAULT_OUT / 'marginalia_key.jsonl').read_text(encoding='utf-8').splitlines()]
        self.assertEqual([row['output'] for row in keys], [
            '63968aded00d8f5cb296ddcfa0aef65f',
            'cebdf3a30ddaa6f11d1b9f3ff2235aa9',
            'e7c39dd2af9207c9e3204d61eb70fb7f',
        ])
        for row in keys:
            self.assertEqual(row['input']['payload']['graph_revision']['$tuple'][:2],
                             [1730000000123456789, 481])

        for name in ('manual_base', 'manual_restore', 'notebook_validate'):
            rows = [json.loads(line) for line in
                    (DEFAULT_OUT / f'{name}.jsonl').read_text(encoding='utf-8').splitlines()]
            self.assertTrue(any('$error' in row['output'] for row in rows))
            self.assertTrue(any('$error' not in row['output'] for row in rows))


if __name__ == '__main__':
    unittest.main()
