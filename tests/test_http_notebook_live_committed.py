"""Verify the published Aq who/ask HTTP observations using only checked-in tapes."""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from oracle.record.scan import scan


ROOT = Path(__file__).resolve().parents[1]
CASSETTES = ROOT / 'oracle/cassettes/live'
RECEIPTS = ROOT / 'oracle/goldens/http/live'
GOLDENS = ROOT / 'oracle/goldens/http'
TOP_LEVEL = {'intent.json', 'outbound.jsonl', 'attempt-http.jsonl',
             'live-http.jsonl', 'observation.json', 'work'}


class PublishedNotebookHttp(unittest.TestCase):
    def test_who_and_ask_match_the_observed_http_and_two_offline_replays(self):
        for route in ('who', 'ask'):
            with self.subTest(route=route), tempfile.TemporaryDirectory(
                    prefix=f'thusfar-{route}-committed-http-') as temporary:
                receipt = RECEIPTS / route
                self.assertFalse(receipt.is_symlink())
                self.assertEqual({path.name for path in receipt.iterdir()}, TOP_LEVEL)
                for path in receipt.rglob('*'):
                    self.assertFalse(path.is_symlink(), path)
                    self.assertTrue(path.is_file() or path.is_dir(), path)
                self.assertGreater(scan(receipt), 0)

                golden = GOLDENS / f'aq_{route}_live.jsonl'
                report = GOLDENS / f'aq_{route}_live-report.json'
                self.assertEqual((receipt / 'live-http.jsonl').read_bytes(), golden.read_bytes())

                output = Path(temporary) / golden.name
                result = subprocess.run(
                    [sys.executable, '-m', 'oracle.record.http_notebook_live', 'verify',
                     '--route', route, '--cassettes', str(CASSETTES),
                     '--receipt', str(receipt), '--out', str(output)],
                    cwd=ROOT, env={**os.environ, 'PYTHONHASHSEED': '1'},
                    capture_output=True, timeout=600, check=False,
                )
                self.assertEqual(result.returncode, 0,
                                 f'{route} offline HTTP verification failed with exit {result.returncode}')
                self.assertEqual(output.read_bytes(), golden.read_bytes())
                self.assertEqual(output.with_name(output.stem + '-report.json').read_bytes(),
                                 report.read_bytes())


if __name__ == '__main__':
    unittest.main()
