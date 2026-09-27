"""Verify model-free staging of the five frozen public-domain parser fixtures."""
from __future__ import annotations

import json
import shutil
import socket
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from oracle.record.stage_corpus import BOOKS, CORPUS, PARSED, stage_public_book


def copied_fixture(root: Path) -> tuple[Path, Path]:
    corpus, parsed = root / 'corpus', root / 'parsed'
    (corpus / 'books').mkdir(parents=True)
    (parsed / 'books__jekyll.txt').mkdir(parents=True)
    shutil.copy2(CORPUS / 'manifest.json', corpus / 'manifest.json')
    shutil.copy2(CORPUS / BOOKS['jekyll'], corpus / BOOKS['jekyll'])
    shutil.copy2(PARSED / 'report.json', parsed / 'report.json')
    shutil.copy2(PARSED / 'books__jekyll.txt/book.json',
                 parsed / 'books__jekyll.txt/book.json')
    return corpus, parsed


class StageCorpusTests(unittest.TestCase):
    def test_all_five_stage_twice_with_exact_public_bytes_and_no_network(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-stage-test-') as tmp, \
                patch.object(socket.socket, 'connect', side_effect=AssertionError('network')):
            root = Path(tmp)
            for book_id, source_rel in BOOKS.items():
                with self.subTest(book=book_id):
                    outputs = [root / f'{book_id}-{index}' for index in (1, 2)]
                    proofs = [stage_public_book(book_id, out) for out in outputs]
                    self.assertEqual(proofs[0], proofs[1])
                    self.assertEqual((outputs[0] / 'source.txt').read_bytes(),
                                     (CORPUS / source_rel).read_bytes())
                    case = source_rel.replace('/', '__')
                    self.assertEqual((outputs[0] / 'book.json').read_bytes(),
                                     (PARSED / case / 'book.json').read_bytes())
                    self.assertEqual({path.name for path in outputs[0].iterdir()},
                                     {'source.txt', 'book.json', '.oracle-stage.json'})
                    for name in ('source.txt', 'book.json', '.oracle-stage.json'):
                        self.assertEqual((outputs[0] / name).read_bytes(),
                                         (outputs[1] / name).read_bytes())
                    with self.assertRaises(FileExistsError):
                        stage_public_book(book_id, outputs[0])
            dangling = root / 'dangling'
            dangling.symlink_to(root / 'missing')
            with self.assertRaises(FileExistsError):
                stage_public_book('jekyll', dangling)

    def test_tampered_source_golden_or_report_cannot_stage(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-stage-tamper-') as tmp:
            root = Path(tmp)
            corpus, parsed = copied_fixture(root)
            source = corpus / BOOKS['jekyll']
            golden = parsed / 'books__jekyll.txt/book.json'
            report = parsed / 'report.json'
            original_source, original_golden, original_report = (
                source.read_bytes(), golden.read_bytes(), report.read_bytes())
            source.write_bytes(original_source + b'changed')
            with self.assertRaisesRegex(ValueError, 'manifest mismatch'):
                stage_public_book('jekyll', root / 'bad-source', corpus=corpus, parsed=parsed)
            self.assertFalse((root / 'bad-source').exists())

            source.write_bytes(original_source)
            golden.write_bytes(original_golden + b' ')
            with self.assertRaisesRegex(ValueError, 'golden bytes differ'):
                stage_public_book('jekyll', root / 'bad-golden', corpus=corpus, parsed=parsed)
            self.assertFalse((root / 'bad-golden').exists())

            golden.write_bytes(original_golden)
            value = json.loads(original_report)
            value['parser_sha256'] = '0' * 64
            report.write_text(json.dumps(value), encoding='utf-8')
            with self.assertRaisesRegex(ValueError, 'provenance mismatch'):
                stage_public_book('jekyll', root / 'bad-report', corpus=corpus, parsed=parsed)
            self.assertFalse((root / 'bad-report').exists())

    def test_frozen_input_tree_is_not_a_staging_destination(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-stage-location-') as tmp:
            root = Path(tmp)
            corpus, parsed = copied_fixture(root)
            with self.assertRaisesRegex(ValueError, 'frozen oracle inputs'):
                stage_public_book('jekyll', corpus / 'new-book', corpus=corpus, parsed=parsed)


if __name__ == '__main__':
    unittest.main()
