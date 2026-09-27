"""The provenance check must fail on content and file-set drift."""

from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from oracle.record.verify_book_artifacts import verify_book


class BookArtifactIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='thusfar-book-integrity-')
        self.addCleanup(self.temp.cleanup)
        self.book = Path(self.temp.name) / 'synthetic'
        self.book.mkdir()
        self.data = {'book.json': b'{"len": 1}\n', 'kg.json': b'{}\n',
                     'status.json': b'{}\n', 'work/usage.json': b'{}\n'}
        for name, contents in self.data.items():
            path = self.book / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)
        (self.book / 'provenance.json').write_text(json.dumps({
            'artifact_sha256': {
                name: hashlib.sha256(contents).hexdigest()
                for name, contents in self.data.items()}
        }), encoding='utf-8')
        (self.book / 'fold.jsonl').write_text('excluded from artifact map\n', encoding='utf-8')

    def test_valid_map_excludes_provenance_and_fold(self):
        self.assertEqual(verify_book(self.book), len(self.data))

    def test_tampered_artifact_is_rejected(self):
        (self.book / 'status.json').write_bytes(b'{"stale": true}\n')
        with self.assertRaisesRegex(RuntimeError, 'SHA-256 differs: .*status.json'):
            verify_book(self.book)

    def test_missing_and_extra_artifacts_are_rejected(self):
        (self.book / 'kg.json').unlink()
        with self.assertRaisesRegex(RuntimeError, "missing=\\['kg.json'\\]"):
            verify_book(self.book)
        (self.book / 'kg.json').write_bytes(self.data['kg.json'])
        (self.book / 'work/extra.json').write_bytes(b'{}\n')
        with self.assertRaisesRegex(RuntimeError, "extra=\\['work/extra.json'\\]"):
            verify_book(self.book)


if __name__ == '__main__':
    unittest.main()
