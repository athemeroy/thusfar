"""Check the observed JEV accounting difference without replay or normalization."""
from __future__ import annotations

import json
import unittest

from oracle.record.resume import GOLDEN


class ResumeJevAccountingReceiptTests(unittest.TestCase):
    def test_only_observed_jev_telemetry_differs(self):
        receipt = json.loads(GOLDEN.read_text(encoding='utf-8'))
        runs = receipt['runs']
        fresh_hashes = runs['fresh']['artifact_sha256']
        resumed_hashes = runs['resume']['artifact_sha256']
        self.assertEqual(len(fresh_hashes), 154)
        self.assertEqual(fresh_hashes.keys(), resumed_hashes.keys())
        differing = {name for name in fresh_hashes
                     if fresh_hashes[name] != resumed_hashes[name]}
        self.assertEqual(differing, {'status.json', 'work/usage.json'})
        self.assertEqual(set(receipt['changed_artifacts']), differing)

        prefix_status = runs['prefix']['usage_artifacts']['status.json']
        baseline = prefix_status['usage']['jev']
        self.assertEqual(baseline, {
            'calls': 35, 'chars': 253674, 'questions': 204,
            'paid_chars': 0, 'passage_chars': 116395,
            'attempts': 36, 'retries': 1,
        })

        expected_jev_fields = set(baseline)
        for artifact in ('status.json', 'work/usage.json'):
            with self.subTest(artifact=artifact):
                pair = receipt['changed_artifacts'][artifact]
                fresh = pair['fresh']
                resumed = pair['resumed']
                self.assertEqual(fresh, runs['fresh']['usage_artifacts'][artifact])
                self.assertEqual(resumed, runs['resume']['usage_artifacts'][artifact])
                if artifact == 'status.json':
                    self.assertEqual({k: v for k, v in fresh.items() if k != 'usage'},
                                     {k: v for k, v in resumed.items() if k != 'usage'})
                    fresh_usage, resumed_usage = fresh['usage'], resumed['usage']
                else:
                    fresh_usage, resumed_usage = fresh, resumed
                self.assertEqual({k: v for k, v in fresh_usage.items() if k != 'jev'},
                                 {k: v for k, v in resumed_usage.items() if k != 'jev'})
                fresh_jev = fresh_usage['jev']
                resumed_jev = resumed_usage['jev']
                self.assertEqual(set(fresh_jev) | set(resumed_jev), expected_jev_fields)
                self.assertEqual(fresh_jev['paid_chars'], resumed_jev['paid_chars'])
                for field in expected_jev_fields:
                    self.assertEqual(fresh_jev.get(field, 0) - resumed_jev.get(field, 0),
                                     baseline[field], f'{artifact}: {field}')


if __name__ == '__main__':
    unittest.main()
