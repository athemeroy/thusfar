"""The committed settings success is an original HTTP observation with an offline proof."""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from oracle.record.common import require_reference_runtime
from oracle.record.scan import scan

ROOT = Path(__file__).resolve().parents[1]
CASSETTES = ROOT / 'oracle/cassettes/live'
RECEIPT = ROOT / 'oracle/goldens/http/live/settings-test'
GOLDEN = ROOT / 'oracle/goldens/http/settings_test_live.jsonl'
REPORT = ROOT / 'oracle/goldens/http/settings_test_live-report.json'
REQUEST_SHA = '33b5bffb4690b459db4c721365d16c02ef4c32088214ebbe86ac0f7251a6ef64'


class CommittedSettingsLiveHTTP(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        require_reference_runtime()

    def test_original_receipt_and_golden_are_byte_bound(self):
        self.assertEqual({path.name for path in RECEIPT.iterdir()},
                         {'intent.json', 'attempt-http.jsonl', 'live-http.jsonl', 'observation.json'})
        intent = json.loads((RECEIPT / 'intent.json').read_text(encoding='utf-8'))
        observed = json.loads((RECEIPT / 'observation.json').read_text(encoding='utf-8'))
        report = json.loads(REPORT.read_text(encoding='utf-8'))
        original = (RECEIPT / 'live-http.jsonl').read_bytes()
        self.assertEqual(intent['request_sha256'], REQUEST_SHA)
        self.assertEqual(report['request_sha256'], REQUEST_SHA)
        self.assertEqual(report['passes'], 2)
        self.assertEqual(report['hash_seeds'], ['1', '2'])
        self.assertEqual(report['route'], 'POST /api/settings/test')
        self.assertEqual(report['status'], 200)
        self.assertEqual((RECEIPT / 'attempt-http.jsonl').read_bytes(), original)
        self.assertEqual(GOLDEN.read_bytes(), original)
        self.assertEqual(observed['intent_sha256'],
                         hashlib.sha256((RECEIPT / 'intent.json').read_bytes()).hexdigest())
        self.assertEqual(observed['live_http_sha256'], hashlib.sha256(original).hexdigest())
        self.assertEqual(report['live_http_sha256'], hashlib.sha256(original).hexdigest())
        self.assertEqual(report['verified_http_sha256'], hashlib.sha256(original).hexdigest())
        self.assertEqual(observed['tape_sha256'],
                         hashlib.sha256((CASSETTES / (REQUEST_SHA + '.json')).read_bytes()).hexdigest())
        row = json.loads(original)
        self.assertEqual(row['request']['path'], '/api/settings/test')
        self.assertEqual(row['response']['status'], 200)
        self.assertIs(row['response']['body_json']['ok'], True)
        self.assertNotIn('api_key_last4', row['response']['body_json'])
        self.assertEqual(scan(RECEIPT), 4)

    def test_two_portable_independent_offline_verifications_match_committed_bytes(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-settings-committed-replay-') as tmp:
            for seed in ('1', '982451653'):
                directory = Path(tmp) / seed
                directory.mkdir()
                output = directory / GOLDEN.name
                result = subprocess.run(
                    [sys.executable, '-m', 'oracle.record.http_model_live', 'verify',
                     '--cassettes', str(CASSETTES), '--receipt', str(RECEIPT),
                     '--out', str(output)], cwd=ROOT,
                    env={**os.environ, 'PYTHONHASHSEED': seed},
                    capture_output=True, timeout=40, check=False,
                )
                self.assertEqual(result.returncode, 0,
                                 f'offline settings replay failed at seed {seed}')
                self.assertEqual(output.read_bytes(), GOLDEN.read_bytes())
                self.assertEqual(output.with_name('settings_test_live-report.json').read_bytes(),
                                 REPORT.read_bytes())


if __name__ == '__main__':
    unittest.main()
