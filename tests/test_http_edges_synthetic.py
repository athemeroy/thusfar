"""The isolated HTTP edge oracle is synthetic and independently reproducible."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GOLDEN = ROOT / 'oracle/goldens/http/aq_edges_synthetic.jsonl'


class SyntheticEdgeHTTPOracleTests(unittest.TestCase):
    def test_two_independent_interpreters_match_committed_golden(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-edge-test-') as temp:
            root = Path(temp)
            outputs = [root / 'first.jsonl', root / 'second.jsonl']
            env = dict(os.environ, HTTPS_PROXY='http://127.0.0.1:1',
                       HTTP_PROXY='http://127.0.0.1:1', ALL_PROXY='http://127.0.0.1:1')
            for output in outputs:
                result = subprocess.run([
                    sys.executable, '-m', 'oracle.record.http_edges_synthetic',
                    '--baseline', str(root / 'baseline'), '--out', str(output),
                ], cwd=ROOT, env=env, capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(outputs[0].read_bytes(), outputs[1].read_bytes())
            self.assertEqual(outputs[0].read_bytes(), GOLDEN.read_bytes())
            reports = [path.with_name(path.stem + '-report.json') for path in outputs]
            self.assertEqual(reports[0].read_bytes(), reports[1].read_bytes())
            self.assertEqual(reports[0].read_bytes(), GOLDEN.with_name('aq_edges_synthetic-report.json').read_bytes())
            report = json.loads(reports[0].read_text(encoding='utf-8'))
            self.assertEqual((report['routes'], report['passes']), (11, 2))
            self.assertFalse(report['transport']['outbound_model_network'])
            self.assertIn('synthetic', report['source'])
            self.assertTrue(report['acceptance']['ask_guard_withheld'])
            self.assertTrue(report['acceptance']['auto_marginalia_and_cache'])
            for secret in ('fixture-settings-key', 'oracle-http-transport-fixture-only'):
                self.assertNotIn(secret, outputs[0].read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
