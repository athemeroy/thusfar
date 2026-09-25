"""The continuation receipt must preserve notes and expose meaningful drift."""
from __future__ import annotations

import copy
import json
import unittest

from oracle.record.resume import (GOLDEN, build_receipt, validate_outputs,
                                  validate_prefix, validate_requests)


class ResumeReceiptTests(unittest.TestCase):
    def setUp(self):
        self.receipt = json.loads(GOLDEN.read_text())

    def test_committed_receipt_matches_two_independent_offline_runs(self):
        self.assertEqual(build_receipt(), self.receipt)
        self.assertEqual(self.receipt['request_counts'], {
            'fresh': {'model': 21, 'jev': 82},
            'prefix': {'model': 8, 'jev': 36},
            'resume': {'model': 13, 'jev': 46},
        })
        self.assertEqual(set(self.receipt['runs']['resume']['preserved_sha256']),
                         {'source.txt', 'notebook.json'})

    def test_changed_frontier_is_rejected_even_with_usage_differences(self):
        changed = copy.deepcopy(self.receipt['changed_artifacts'])
        changed['status.json']['resumed']['frontier'] -= 1
        with self.assertRaisesRegex(ValueError, 'status outside usage'):
            validate_outputs(self.receipt['runs']['fresh']['artifact_sha256'],
                             self.receipt['runs']['resume']['artifact_sha256'], changed)

    def test_changed_paid_usage_is_rejected(self):
        changed = copy.deepcopy(self.receipt['changed_artifacts'])
        changed['work/usage.json']['resumed']['unexpected_model_charge'] = 1
        with self.assertRaisesRegex(ValueError, 'paid-model accounting'):
            validate_outputs(self.receipt['runs']['fresh']['artifact_sha256'],
                             self.receipt['runs']['resume']['artifact_sha256'], changed)

    def test_dropped_artifact_is_rejected(self):
        resumed = dict(self.receipt['runs']['resume']['artifact_sha256'])
        resumed.pop('kg.json')
        with self.assertRaisesRegex(ValueError, 'artifact file set'):
            validate_outputs(self.receipt['runs']['fresh']['artifact_sha256'],
                             resumed, self.receipt['changed_artifacts'])

    def test_repeated_cached_model_request_is_rejected(self):
        runs = copy.deepcopy(self.receipt['runs'])
        repeated = next(row for row in runs['prefix']['requests'] if row['kind'] == 'model')
        # Preserve the count partition so the independent repeated-cache guard fires.
        runs['resume']['requests'].append(dict(repeated))
        fresh = next(row for row in runs['fresh']['requests'] if row['sha256'] == repeated['sha256'])
        fresh['count'] += repeated['count']
        with self.assertRaisesRegex(ValueError, 'repeated a paid-model request'):
            validate_requests(runs)

    def test_duplicate_request_rows_cannot_hide_a_cached_request(self):
        runs = copy.deepcopy(self.receipt['runs'])
        repeated = next(row for row in runs['prefix']['requests'] if row['kind'] == 'model')
        runs['resume']['requests'].extend([dict(repeated), dict(repeated, count=0)])
        with self.assertRaisesRegex(ValueError, 'invalid row|duplicate digest'):
            validate_requests(runs)
        runs['resume']['requests'][-1]['count'] = 1
        with self.assertRaisesRegex(ValueError, 'duplicate digest'):
            validate_requests(runs)

    def test_request_counts_require_positive_integers(self):
        for count in (0, -1, True, 1.5, '1'):
            with self.subTest(count=count):
                runs = copy.deepcopy(self.receipt['runs'])
                runs['resume']['requests'][0]['count'] = count
                with self.assertRaisesRegex(ValueError, 'invalid row'):
                    validate_requests(runs)

    def test_paused_source_requires_exact_prefix_cache_and_frontier(self):
        prefix = self.receipt['runs']['prefix']
        source = dict(prefix['artifact_sha256'])
        source.pop('work/run.lock')
        source['status.json'] = 'paused state changes this hash'
        state = dict(prefix['usage_artifacts']['status.json'], state='paused')
        validate_prefix(prefix, source, state)
        with self.assertRaisesRegex(ValueError, 'expected paused 4/9 frontier'):
            validate_prefix(prefix, source, dict(state, frontier=8834))
        source['work/segs/0000.json'] = 'changed'
        with self.assertRaisesRegex(ValueError, 'cache differs'):
            validate_prefix(prefix, source, state)


if __name__ == '__main__':
    unittest.main()
