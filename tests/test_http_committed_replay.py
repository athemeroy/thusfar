"""Replay the committed Aq HTTP oracles without a provider or stable filesystem inodes."""
from __future__ import annotations

import copy
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from oracle.record.common import canonical, digest


ROOT = Path(__file__).resolve().parents[1]
GOLDENS = ROOT / 'oracle/goldens/http'
SOURCE = 'oracle/corpus/snapshots/aq_complete'
HEX_64 = re.compile(r'[0-9a-f]{64}\Z')
HEX_32 = re.compile(r'[0-9a-f]{32}\Z')

# The source tree is copied to a new baseline on CI. Its inode enters these
# revisions and their derived marginalia cache keys. Every other value must
# match the committed oracle exactly, including the rest of the import request.
BASELINE_DYNAMIC = {
    'book-get': (('response', 'body_json', 'version'),),
    'book-export': (('response', 'body_json', 'version'),),
    'book-offline-manifest': (
        ('response', 'body_json', 'version'),
        ('response', 'body_json', 'book', 'version'),
    ),
    'book-marginalia-empty-cues': (('response', 'body_json', 'key'),),
    'book-marginalia-empty-cues-cached': (('response', 'body_json', 'key'),),
    'books-import-success': (('request', 'body_json', 'version'),),
    'books-import-duplicate': (('request', 'body_json', 'version'),),
}
MODEL_DYNAMIC = {
    'marginalia-manual-synthetic': (('response', 'body_json', 'key'),),
    'marginalia-manual-cached-synthetic': (('response', 'body_json', 'key'),),
}


class CommittedHTTPReplayTests(unittest.TestCase):
    def _replay(self, module: str, name: str) -> tuple[list[bytes], dict]:
        with tempfile.TemporaryDirectory(prefix='thusfar-http-committed-') as temp:
            workspace = Path(temp)
            baseline = workspace / 'baseline'
            outputs = [workspace / 'first.jsonl', workspace / 'second.jsonl']
            # The HTTP server uses loopback only; the synthetic model transport
            # rejects every URL outside its explicit .invalid fixture endpoints.
            env = dict(os.environ, HTTPS_PROXY='http://127.0.0.1:1',
                       HTTP_PROXY='http://127.0.0.1:1', ALL_PROXY='http://127.0.0.1:1')
            for output in outputs:
                result = subprocess.run([
                    sys.executable, '-m', module, SOURCE, '--baseline', str(baseline),
                    '--out', str(output),
                ], cwd=ROOT, env=env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(outputs[0].read_bytes(), outputs[1].read_bytes())
            reports = [path.with_name(path.stem + '-report.json') for path in outputs]
            self.assertEqual(reports[0].read_bytes(), reports[1].read_bytes())
            lines = outputs[0].read_bytes().splitlines(keepends=True)
            report = json.loads(reports[0].read_bytes())
        self._compare_committed(name, lines, report)
        return lines, report

    def _compare_committed(self, name: str, lines: list[bytes], report: dict) -> None:
        expected_lines = (GOLDENS / f'{name}.jsonl').read_bytes().splitlines(keepends=True)
        expected_report = json.loads((GOLDENS / f'{name}-report.json').read_bytes())
        dynamic = BASELINE_DYNAMIC if name == 'aq_complete' else MODEL_DYNAMIC
        self.assertEqual(len(lines), len(expected_lines))
        actual_rows = [json.loads(line) for line in lines]
        expected_rows = [json.loads(line) for line in expected_lines]
        self.assertEqual([row['route'] for row in actual_rows],
                         [row['route'] for row in expected_rows])
        self.assertEqual(len({row['route'] for row in actual_rows}), len(lines))
        for line, expected_line, actual, expected in zip(
                lines, expected_lines, actual_rows, expected_rows):
            route = actual['route']
            if route not in dynamic:
                self.assertEqual(line, expected_line, route)
                continue
            actual_copy, expected_copy = copy.deepcopy(actual), copy.deepcopy(expected)
            for path in dynamic[route]:
                for row in (actual_copy, expected_copy):
                    field = row
                    for part in path[:-1]:
                        field = field[part]
                    value = field[path[-1]]
                    pattern = HEX_32 if path[-1] == 'key' else HEX_64
                    self.assertIsInstance(value, str, route)
                    self.assertRegex(value, pattern, route)
                    field[path[-1]] = '<inode-derived>'
            self.assertEqual(canonical(actual_copy), canonical(expected_copy), route)

        # The report digest changes only because the checked inode-derived
        # response fields change. Verify each digest before excluding it.
        for candidate, rows in ((report, actual_rows), (expected_report, expected_rows)):
            self.assertEqual(candidate['recorded_response_sha256'],
                             digest([row['response'] for row in rows]))
        actual_copy, expected_copy = copy.deepcopy(report), copy.deepcopy(expected_report)
        actual_copy['recorded_response_sha256'] = '<checked-derived-digest>'
        expected_copy['recorded_response_sha256'] = '<checked-derived-digest>'
        self.assertEqual(canonical(actual_copy), canonical(expected_copy))

    def test_complete_aq_routes_match_committed_oracle(self):
        lines, report = self._replay('oracle.record.http_routes', 'aq_complete')
        self.assertEqual((len(lines), report['routes'], report['passes']), (60, 60, 2))

    def test_synthetic_model_routes_match_committed_oracle(self):
        lines, report = self._replay('oracle.record.http_model_synthetic',
                                     'aq_model_synthetic')
        self.assertEqual((len(lines), report['routes'], report['passes']), (4, 4, 2))
        self.assertFalse(report['transport']['outbound_model_network'])
        self.assertIn('synthetic in-memory transport', report['source'])


if __name__ == '__main__':
    unittest.main()
