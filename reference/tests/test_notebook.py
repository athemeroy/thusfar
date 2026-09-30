"""Personal records must survive uncertain writes, conflicts and book portability."""
import copy
import json
import unittest
import test_server_repair as fixtures
from server import app, notebook


class NotebookHTTP(unittest.TestCase):
    setUp = fixtures.HTTPRepair.setUp
    request = fixtures.HTTPRepair.request
    make_book = fixtures.HTTPRepair.make_book

    def note(self, **overrides):
        return dict(id='note-test-0001', kind='note', start=0, end=5, quote='Alice',
                    text='An early thought', knowledge_cutoff=8, operation='operation-0001', expected_revision=0) | overrides

    def save(self, item):
        status, _, raw = self.request('PUT', '/api/books/fixture/notebook', item)
        return status, json.loads(raw)

    def test_idempotency_conflict_and_independent_notes(self):
        self.make_book()
        status, first = self.save(self.note())
        self.assertEqual(status, 200)
        self.assertEqual(first['item']['revision'], 1)
        self.assertEqual(self.save(self.note()), (200, first))
        self.assertEqual(self.save(self.note(operation='operation-0002'))[0], 409)
        self.assertEqual(self.save(self.note(id='note-test-0002', operation='operation-0003'))[0], 200)
        status, second = self.save(self.note(operation='operation-0004', expected_revision=1, text='Later thought', knowledge_cutoff=12))
        self.assertEqual(second['item']['revision'], 2)
        self.assertEqual(second['item']['knowledge_cutoff'], 12)
        self.assertEqual(self.save(self.note(operation='operation-0005', expected_revision=1, deleted=True))[0], 409)
        self.assertEqual(len(json.loads(self.request('GET', '/api/books/fixture/notebook')[2])['items']), 2)

    def test_anchors_reject_fabricated_quote_surrogate_split_and_future_bounds(self):
        root = self.make_book()
        for changed in [dict(quote='Wrong'), dict(start=-1), dict(end=500), dict(knowledge_cutoff=3), dict(text='x'*10001), dict(kind='unknown')]:
            self.assertEqual(self.save(self.note(**changed))[0], 400, changed.keys())
        self.assertFalse((root / 'notebook.json').exists())
        book = app.cached_json(root / 'book.json')
        book = copy.deepcopy(book)
        book['blocks'][0]['t'] = '😀Alice'
        app.wjson(root / 'book.json', book)
        self.assertEqual(self.save(self.note(start=2, end=7))[0], 200)
        self.assertEqual(self.save(self.note(id='note-test-0002', start=1, end=7))[0], 400)

    def test_export_import_preserves_notes_and_refuses_different_personal_records(self):
        self.make_book()
        before = json.loads(self.request('GET', '/api/books/fixture/offline-manifest')[2])
        self.save(self.note())
        after = json.loads(self.request('GET', '/api/books/fixture/offline-manifest')[2])
        self.assertNotEqual(before['version'], after['version'])
        self.assertEqual(after['notebook']['url'], '/api/books/fixture/notebook')
        exported = json.loads(self.request('GET', '/api/books/fixture/export')[2])
        self.assertEqual(exported['notebook'][0]['quote'], 'Alice')
        code, _, raw = self.request('POST', '/api/books/import', exported)
        self.assertEqual(code, 200, raw)
        new_id = json.loads(raw)['id']
        restored = json.loads(self.request('GET', f'/api/books/{new_id}/notebook')[2])['items']
        self.assertEqual(restored, exported['notebook'])
        self.assertEqual(self.request('POST', '/api/books/import', exported)[0], 200)
        exported['notebook'][0]['text'] = 'Different thought'
        self.assertEqual(self.request('POST', '/api/books/import', exported)[0], 409)

    def test_delete_tombstone_markdown_and_book_removal_preserve_personal_data(self):
        self.make_book()
        self.save(self.note())
        self.assertEqual(self.save(self.note(operation='operation-0002', expected_revision=1, deleted=True))[0], 200)
        body = self.request('GET', '/api/books/fixture/notebook.md')[2].decode()
        self.assertNotIn('An early thought', body)
        self.assertEqual(self.request('DELETE', '/api/books/fixture')[0], 200)
        self.assertTrue(next((self.root / 'trash').glob('*/notebook.json')).is_file())


if __name__ == '__main__':
    unittest.main()
