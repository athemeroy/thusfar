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
            'notebook_validate.jsonl', 'settle_rewrites_state.jsonl',
            'classify_state.jsonl', 'finish_state.jsonl',
            'provenance.json',
        })
        provenance = json.loads(files['provenance.json'])
        self.assertEqual(provenance['passes'], 2)
        self.assertEqual(provenance['python'].split('.')[:2], ['3', '11'])
        self.assertIn('handwritten synthetic direct calls', provenance['source'])
        self.assertIn('no model or network', provenance['source'])
        self.assertIn('pipeline/parse.py', provenance['sources_sha256'])

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

    def test_rewrite_golden_records_mutated_profile_and_threshold_boundaries(self):
        rows = [json.loads(line) for line in
                (DEFAULT_OUT / 'settle_rewrites_state.jsonl').read_text(encoding='utf-8').splitlines()]
        self.assertEqual([row['case'] for row in rows], [
            'below_jev_threshold_reverts_profile_and_verdict',
            'equal_jev_threshold_keeps_rewrite',
            'verified_ok_keeps_low_jev_rewrite',
        ])
        self.assertTrue(all(row['return'] is None for row in rows))
        self.assertTrue(all('timing' not in row['before']['rec'] for row in rows))
        rollback = rows[0]
        self.assertEqual(rollback['before']['rec']['data']['profiles'][0]['bio'], '改写介绍')
        self.assertEqual(rollback['after']['rec']['data']['profiles'][0]['bio'], '原介绍')
        self.assertEqual(rollback['after']['rec']['data']['profiles'][0]['tagline'], '原称号')
        self.assertEqual(rollback['after']['rec']['guard']['checks']['P1']['verdict'], 'kept')
        self.assertEqual(rows[1]['before'], rows[1]['after'])
        self.assertEqual(rows[2]['before'], rows[2]['after'])

    def test_classify_golden_records_in_place_kinds_and_unused_blocks(self):
        rows = [json.loads(line) for line in
                (DEFAULT_OUT / 'classify_state.jsonl').read_text(encoding='utf-8').splitlines()]
        self.assertTrue(all(row['return'] is None for row in rows))
        self.assertTrue(all(row['before']['blocks'] == row['after']['blocks'] for row in rows))
        self.assertTrue(all('kind' not in chapter for row in rows
                            for chapter in row['before']['chapters']))
        self.assertEqual([chapter['kind'] for chapter in rows[0]['after']['chapters']],
                         ['front', 'front', 'body', 'back', 'back'])
        self.assertEqual([chapter['kind'] for chapter in rows[1]['after']['chapters']],
                         ['body', 'body', 'body'])

    def test_finish_golden_records_input_mutation_return_and_aliases(self):
        row = json.loads((DEFAULT_OUT / 'finish_state.jsonl').read_text(encoding='utf-8'))
        before_blocks = row['before']['blocks']
        after_blocks = row['after']['blocks']
        self.assertEqual(before_blocks[0]['t'], '😀')
        self.assertEqual(after_blocks[1]['o'], 3)  # emoji: two UTF-16 units, plus separator
        self.assertIn('cls', before_blocks[0])
        self.assertNotIn('cls', after_blocks[0])
        self.assertNotIn('ids', after_blocks[0])
        self.assertEqual(after_blocks[0]['fn'], [[0, 'n1']])
        self.assertNotIn('fn', after_blocks[1])
        self.assertEqual(row['return']['blocks'], after_blocks)
        self.assertEqual(row['return']['notes'], {'n1': '脚注原文'})
        self.assertEqual([chapter['kind'] for chapter in row['return']['chapters']],
                         ['front', 'body'])
        self.assertEqual(row['aliases'], {
            'return_blocks_is_input_blocks': True,
            'return_first_block_is_input_first_block': True,
        })


if __name__ == '__main__':
    unittest.main()
