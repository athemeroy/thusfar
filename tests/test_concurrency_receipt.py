"""Default concurrency evidence must compare the entire completed book."""
import copy
import json
import unittest

from oracle.record.concurrency import GOLDEN, build_receipt, validate_runs


class ConcurrencyReceiptTests(unittest.TestCase):
    def setUp(self):
        self.receipt = json.loads(GOLDEN.read_text())
        self.reference = self.receipt['runs'][0]['artifact_sha256']

    def test_four_independent_replays_match_committed_receipt(self):
        self.assertEqual(build_receipt(), self.receipt)
        self.assertEqual(self.receipt['artifact_count'], 154)

    def test_missing_or_duplicate_configuration_is_rejected(self):
        runs = copy.deepcopy(self.receipt['runs'])
        for changed in (runs[:-1], runs[:3] + [runs[0]], list(reversed(runs))):
            with self.subTest(changed=changed[0]['workers']):
                with self.assertRaisesRegex(ValueError, 'all four independent runs'):
                    validate_runs(changed, self.reference)

    def test_changed_or_missing_artifacts_are_rejected(self):
        for artifact in ('kg.json', 'status.json', 'work/usage.json'):
            for remove in (False, True):
                runs = copy.deepcopy(self.receipt['runs'])
                if remove:
                    runs[1]['artifact_sha256'].pop(artifact)
                else:
                    runs[1]['artifact_sha256'][artifact] = '0' * 64
                with self.subTest(artifact=artifact, remove=remove):
                    with self.assertRaisesRegex(ValueError, 'full committed artifact set'):
                        validate_runs(runs, self.reference)


if __name__ == '__main__':
    unittest.main()
