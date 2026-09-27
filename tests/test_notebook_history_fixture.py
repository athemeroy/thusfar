"""Exact Aq notebook API history, source preservation, and offline regeneration."""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from oracle.corpus import notebook_history
from oracle.record.common import require_reference_runtime

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'oracle/corpus/snapshots/aq_complete'
SNAPSHOT = ROOT / 'oracle/corpus/snapshots/aq_notebook_history'
RECEIPT = ROOT / 'oracle/goldens/http/aq_notebook_history.json'


def tree(root: Path) -> dict[str, bytes]:
    return {path.relative_to(root).as_posix(): path.read_bytes()
            for path in sorted(root.rglob('*')) if path.is_file()}


class AqNotebookHistoryFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        require_reference_runtime()

    def test_original_48_files_and_utf16_note_states(self):
        source, final = tree(SOURCE), tree(SNAPSHOT)
        self.assertEqual(len(source), 48)
        self.assertEqual(set(final), set(source) | {'notebook.json'})
        for name, raw in source.items():
            self.assertEqual(final[name], raw, name)
        book = json.loads(final['book.json'])
        notes = json.loads(final['notebook.json'])
        self.assertEqual(len(notes), 2)
        self.assertEqual([item['revision'] for item in notes], [2, 2])
        self.assertEqual([item['deleted'] for item in notes], [False, True])
        self.assertEqual([item['knowledge_cutoff'] for item in notes], [1000, 900])
        self.assertEqual([(item['start'], item['end']) for item in notes], [(14, 22), (820, 847)])
        for item in notes:
            matching = [block for block in book['blocks']
                        if block['o'] <= item['start'] < item['end'] <=
                        block['o'] + len(block['t'].encode('utf-16-le')) // 2]
            self.assertEqual(len(matching), 1)
            block = matching[0]
            quoted = block['t'].encode('utf-16-le')[
                (item['start'] - block['o']) * 2:(item['end'] - block['o']) * 2].decode('utf-16-le')
            self.assertEqual(item['quote'], quoted)

    def test_real_http_receipt_covers_retry_conflict_tombstone_and_empty_import(self):
        receipt = json.loads(RECEIPT.read_text(encoding='utf-8'))
        events = receipt['events']
        self.assertEqual(receipt['source_files_preserved'], 48)
        self.assertTrue(receipt['import_target_initially_empty'])
        self.assertTrue(receipt['version_relation_verified'])
        self.assertIs(receipt['historical_personal_data'], False)
        self.assertEqual([row['route'] for row in events], [
            'initial-get', 'put-first', 'idempotent-retry', 'put-independent',
            'edit-first', 'stale-conflict', 'tombstone-second', 'final-get',
            'markdown-excludes-tombstone', 'export', 'empty-library',
            'import-into-empty-library', 'imported-notebook-get', 'idempotent-import',
        ])
        self.assertEqual([row['response']['status'] for row in events],
                         [200, 200, 200, 200, 200, 409, 200, 200, 200, 200, 200, 200, 200, 200])
        self.assertEqual(events[1]['response']['body_json'], events[2]['response']['body_json'])
        edited = events[4]['response']['body_json']['item']
        self.assertEqual(events[5]['response']['body_json'],
                         {'error': '这条摘记已在其他设备修改', 'item': edited})
        tombstone = events[6]['response']['body_json']['item']
        self.assertTrue(tombstone['deleted'])
        self.assertEqual(events[7]['response']['body_json']['items'], [edited, tombstone])
        self.assertEqual(events[10]['response']['body_json'], [])
        self.assertEqual(events[9]['response']['body_json']['notebook'],
                         events[12]['response']['body_json']['items'])
        self.assertEqual(events[11]['response']['body_json']['id'],
                         events[13]['response']['body_json']['id'])
        self.assertEqual(receipt['final_notebook_sha256'],
                         hashlib.sha256((SNAPSHOT / 'notebook.json').read_bytes()).hexdigest())
        self.assertEqual(receipt['final_notebook_sha256'], receipt['imported_notebook_sha256'])

    def test_two_independent_api_regenerations_match_committed_bytes(self):
        result = subprocess.run(
            [sys.executable, '-m', 'oracle.corpus.notebook_history', '--verify'], cwd=ROOT,
            env={**os.environ, 'PYTHONHASHSEED': '17'}, capture_output=True,
            timeout=40, check=False,
        )
        self.assertEqual(result.returncode, 0, 'offline notebook history regeneration failed')

    def test_validator_rejects_byte_identical_linked_snapshot_and_receipt(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-aq-history-link-test-') as tmp:
            root = Path(tmp)
            linked_snapshot = root / 'snapshot'
            shutil.copytree(SNAPSHOT, linked_snapshot)
            book = linked_snapshot / 'book.json'
            book.unlink()
            book.symlink_to((SOURCE / 'book.json').resolve())
            with patch.object(notebook_history, 'TARGET', linked_snapshot):
                with self.assertRaisesRegex(ValueError, 'linked'):
                    notebook_history.verify()
            linked_receipt = root / 'receipt.json'
            linked_receipt.symlink_to(RECEIPT.resolve())
            with patch.object(notebook_history, 'GOLDEN', linked_receipt):
                with self.assertRaisesRegex(ValueError, 'linked'):
                    notebook_history.verify()


if __name__ == '__main__':
    unittest.main()
