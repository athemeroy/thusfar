"""The successful model-backed HTTP oracle must stay synthetic and byte stable."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
import urllib.request
from pathlib import Path

from oracle.record.http_model_synthetic import (ASK_ANSWER, CHAT_URL, CLASSIFIER_URL,
                                                SyntheticModelTransport)

ROOT = Path(__file__).resolve().parents[1]


class SyntheticModelHTTPOracleTests(unittest.TestCase):
    def test_transport_refuses_unreviewed_endpoint_prompt_and_credentials(self):
        transport = SyntheticModelTransport()
        unknown = urllib.request.Request('https://actual-provider.invalid/v1/chat/completions',
                                         data=b'{}', method='POST')
        with self.assertRaisesRegex(AssertionError, 'unreviewed endpoint'):
            transport.open(unknown)
        classify = urllib.request.Request(CLASSIFIER_URL, data=b'{}', method='POST',
                                          headers={'Authorization': 'Bearer forbidden'})
        with self.assertRaisesRegex(AssertionError, 'API key'):
            transport.open(classify)
        chat = urllib.request.Request(CHAT_URL, data=json.dumps({
            'model': 'different-model', 'thinking': {'type': 'disabled'}, 'stream': True,
            'messages': [{'role': 'user', 'content': ASK_ANSWER}],
        }).encode(), method='POST', headers={'Authorization': 'Bearer oracle-http-transport-fixture-only'})
        with self.assertRaisesRegex(AssertionError, 'different model'):
            transport.open(chat)
        self.assertEqual(transport.calls, [])

    def test_full_http_routes_are_byte_stable_across_independent_interpreters(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-http-model-test-') as temp:
            root = Path(temp)
            baseline = root / 'baseline'
            outputs = [root / 'first.jsonl', root / 'second.jsonl']
            env = dict(os.environ, HTTPS_PROXY='http://127.0.0.1:1',
                       HTTP_PROXY='http://127.0.0.1:1', ALL_PROXY='http://127.0.0.1:1')
            for output in outputs:
                completed = subprocess.run([
                    sys.executable, '-m', 'oracle.record.http_model_synthetic',
                    'oracle/corpus/snapshots/aq_complete', '--baseline', str(baseline),
                    '--out', str(output),
                ], cwd=ROOT, env=env, capture_output=True, text=True, timeout=30)
                self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(outputs[0].read_bytes(), outputs[1].read_bytes())
            reports = [path.with_name(path.stem + '-report.json') for path in outputs]
            self.assertEqual(reports[0].read_bytes(), reports[1].read_bytes())
            report = json.loads(reports[0].read_text())
            self.assertEqual(report['routes'], 4)
            self.assertEqual(report['passes'], 2)
            self.assertEqual(report['transport']['fixture_calls'], 6)
            self.assertFalse(report['transport']['outbound_model_network'])
            self.assertTrue(report['source'].startswith('synthetic in-memory transport'))
            rows = [json.loads(line) for line in outputs[0].read_text().splitlines()]
            self.assertEqual([row['response']['status'] for row in rows], [200] * 4)
            self.assertEqual(rows[0]['response']['body_json']['id'], 'P2')
            self.assertFalse(rows[2]['response']['body_json']['cached'])
            self.assertTrue(rows[3]['response']['body_json']['cached'])


if __name__ == '__main__':
    unittest.main()
