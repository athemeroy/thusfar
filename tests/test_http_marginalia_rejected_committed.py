"""Portable proof of the original Aq manual marginalia HTTP 400, never success."""
from __future__ import annotations

import hashlib
import json
import shutil
import tempfile
import unittest
from pathlib import Path

from oracle.record import http_notebook_live as notebook
from oracle.record.http_routes import ROOT, tree_hashes
from oracle.record.scan import scan

RECEIPT = ROOT / 'oracle/goldens/http/live/marginalia-rejected'
GOLDEN = ROOT / 'oracle/goldens/http/aq_marginalia_first400_live.jsonl'
REPORT = GOLDEN.with_name(GOLDEN.stem + '-report.json')
CASSETTES = ROOT / 'oracle/cassettes/live'
REVIEWED_HASHES = {
    'intent.json': 'a760640911b36338c5b34895d096ac0d6893827aec5f0e015b92aaca6c9df5b2',
    'outbound.jsonl': 'c71ccdd71055441627eb6472c7dbd6dc3be6887ff5da55ec4cf2e4546236ff20',
    'attempt-http.jsonl': '96e3fad858c56505cb1a88467ee06c026ca037dd8060e68ce483ebd2b9076a86',
    'failure.json': '1077203c52ef77305c89710cfcfaf947e208d9777c3de086643d480dcd6b516f',
}
GOLDEN_SHA256 = 'f4e7b217b217dce8a0e9c4b16466a75e49d9fe07c22bce81b2e7b7baf6b14bb2'
REPORT_SHA256 = '21f0987f5415596ca2c256ac72dc9b7fc7afe62134af58b488b0e916a7f10529'


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class CommittedMarginaliaRejectionTests(unittest.TestCase):
    def test_original_receipt_and_first_response_are_exact_and_labeled_rejection(self):
        files = tree_hashes(RECEIPT)
        self.assertEqual(len(files), 52)
        self.assertEqual({name for name in files if not name.startswith('work/')},
                         set(REVIEWED_HASHES))
        for name, expected in REVIEWED_HASHES.items():
            self.assertEqual(files[name], expected)
        self.assertEqual(scan(RECEIPT), 51)
        self.assertEqual(sha256(GOLDEN), GOLDEN_SHA256)
        self.assertEqual(sha256(REPORT), REPORT_SHA256)

        original = (RECEIPT / 'attempt-http.jsonl').read_bytes().splitlines(keepends=True)
        self.assertEqual(len(original), 2)
        self.assertEqual(GOLDEN.read_bytes(), original[0])
        first, second = (json.loads(line) for line in original)
        self.assertEqual(first['response']['status'], 400)
        self.assertEqual(first['response']['body_json'],
                         {'error': notebook.REJECTED_MARGINALIA_ERROR})
        self.assertEqual(second['response']['status'], 500)
        self.assertEqual(second['route'], notebook.CASES['marginalia']['id'] + '-cached')

        report = json.loads(REPORT.read_text(encoding='utf-8'))
        self.assertEqual(report['classification'], 'application_rejection_not_success')
        self.assertEqual(report['original_task_id'], notebook.REJECTED_MARGINALIA_TASK_ID)
        self.assertEqual((report['original_response_ordinal'], report['original_http_status']),
                         (1, 400))
        self.assertEqual(report['excluded_original_followup']['ordinal'], 2)
        self.assertEqual(report['excluded_original_followup']['http_status'], 500)
        self.assertEqual(report['new_provider_attempts'], 0)
        self.assertEqual(report['passes'], 2)
        self.assertEqual(report['hash_seeds'], ['1', '2'])
        self.assertEqual(report['original_intent_sha256'], REVIEWED_HASHES['intent.json'])
        self.assertEqual(report['original_outbound_sha256'], REVIEWED_HASHES['outbound.jsonl'])
        self.assertEqual(report['original_attempt_http_sha256'], REVIEWED_HASHES['attempt-http.jsonl'])
        self.assertEqual(report['original_failure_sha256'], REVIEWED_HASHES['failure.json'])
        self.assertEqual({name.removeprefix('work/'): value for name, value in files.items()
                          if name.startswith('work/')}, report['original_work_file_sha256'])
        self.assertEqual([row['kind'] for row in report['original_outbound']],
                         ['model', 'jev', 'model', 'jev'])

    def test_two_offline_replays_reproduce_committed_rejection_and_state(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-marginalia-rejected-') as temp:
            out = Path(temp) / 'first400.jsonl'
            notebook.verify_failure('marginalia', CASSETTES, RECEIPT, out)
            self.assertEqual(out.read_bytes(), GOLDEN.read_bytes())
            generated_report = out.with_name(out.stem + '-report.json')
            self.assertEqual(generated_report.read_bytes(), REPORT.read_bytes())

    def test_changed_original_http_row_is_refused_before_replay(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-marginalia-tamper-') as temp:
            copy = Path(temp) / 'receipt'
            shutil.copytree(RECEIPT, copy)
            target = copy / 'attempt-http.jsonl'
            original = target.read_bytes()
            self.assertIn(b'"status":400', original)
            target.write_bytes(original.replace(b'"status":400', b'"status":200', 1))
            with self.assertRaisesRegex(ValueError, 'original receipt'):
                notebook._read_rejected_marginalia(copy, CASSETTES)


if __name__ == '__main__':
    unittest.main()
