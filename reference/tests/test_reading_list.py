"""Reading intent must survive uncertain responses, concurrent devices and deletion."""
import concurrent.futures
import json
import unittest

import test_server_repair as fixtures
from server import app


class ReadingListHTTP(unittest.TestCase):
    setUp = fixtures.HTTPRepair.setUp
    request = fixtures.HTTPRepair.request
    make_book = fixtures.HTTPRepair.make_book

    def save(self, items, operation='list-operation-01', expected=0):
        status, _, raw = self.request('PUT', '/api/reading-list', {
            'items': items, 'operation': operation, 'expected_revision': expected})
        return status, json.loads(raw)

    def test_order_receipt_conflict_and_no_progress_inference(self):
        self.make_book('one'); self.make_book('two')
        self.assertEqual(json.loads(self.request('GET', '/api/reading-list')[2])['items'], [])
        status, first = self.save(['two', 'one'])
        self.assertEqual(status, 200)
        self.assertEqual(first['items'], ['two', 'one'])
        self.assertEqual(self.save(['two', 'one']), (200, first))
        self.assertEqual(self.save(['one']), (400, {'error': '同一个书单操作不能提交不同内容'}))
        code, conflict = self.save(['one'], 'list-operation-02')
        self.assertEqual(code, 409)
        self.assertEqual(conflict['list'], first)
        self.assertEqual(self.save(['one'], 'list-operation-03', 1)[1]['revision'], 2)
        self.assertFalse((self.root / 'progress.json').exists())

    def test_concurrent_reorders_have_exactly_one_winner(self):
        self.make_book('one'); self.make_book('two')
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            calls = [pool.submit(self.save, ids, f'list-operation-{n:02d}')
                     for n, ids in enumerate([['one', 'two'], ['two', 'one']])]
            results = [call.result()[0] for call in calls]
        self.assertEqual(sorted(results), [200, 409])

    def test_unavailable_slots_preserved_but_new_hidden_or_missing_books_rejected(self):
        self.make_book('one'); self.make_book('two')
        hidden = self.make_book('hidden')
        app.wjson(hidden / 'meta.json', {'hidden': True})
        self.assertEqual(self.save(['hidden'])[0], 400)
        self.assertEqual(self.save(['missing'])[0], 400)
        self.assertEqual(self.save(['one', 'two'])[0], 200)
        self.assertEqual(self.request('DELETE', '/api/books/one')[0], 200)
        self.assertEqual(self.save(['two', 'one'], 'list-operation-02', 1)[0], 200)
        self.assertEqual(self.save(['two'], 'list-operation-03', 2)[0], 200)
        self.assertEqual(self.save(['one', 'two'], 'list-operation-04', 3)[0], 400)

    def test_bad_payload_never_creates_state(self):
        self.make_book('one')
        for items in [['one', 'one'], ['../one'], [True], 'one', ['one'] * 201]:
            self.assertEqual(self.save(items)[0], 400)
        for revision in [True, -1, 0.5, None]:
            self.assertEqual(self.save(['one'], expected=revision)[0], 400)
        self.assertFalse((self.root / 'reading-list.json').exists())


if __name__ == '__main__':
    unittest.main()
