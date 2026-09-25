"""Python A0.5 output and prompt inputs must ignore hash randomization."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / 'tests' / 'hash_seed_probe.py'


class HashSeedDeterminismTests(unittest.TestCase):
    def test_link_dedupe_and_spoiler_scrub_are_hash_seed_independent(self):
        expected = None
        for seed in ('1', '2', '3', '4', '5'):
            with self.subTest(seed=seed):
                result = subprocess.run(
                    [sys.executable, str(PROBE)], cwd=ROOT,
                    env={**os.environ, 'PYTHONHASHSEED': seed},
                    check=True, capture_output=True, text=True,
                )
                actual = json.loads(result.stdout)
                if expected is None:
                    expected = actual
                self.assertEqual(actual, expected)
                self.assertEqual(actual['proper'], 'Alice')
                self.assertEqual(actual['classic'], 'Alice')
                self.assertEqual(actual['candidates'],
                                 ['P1', 'P2', 'P3', 'P4', 'P5', 'P6'])
                self.assertEqual(actual['scrubbed'], '甲某人开始行动')
                self.assertEqual(actual['pairs'][0], ['P2', 'P1'])
                self.assertEqual(actual['dossier_keys'],
                                 ['P1', 'P2', 'P3', 'P4', 'P5'])


if __name__ == '__main__':
    unittest.main()
