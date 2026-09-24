"""Manual entries stay source anchored, versioned by reading cutoff, and exportable."""
import json
import unittest

from server import manual_entities
from tests.test_server_repair import HTTPRepair


class ManualRules(unittest.TestCase):
    def setUp(self):
        self.book = {'len': 30, 'blocks': [{'k': 'p', 'o': 0, 't': '😀尼尔遇见黑月。', 'fn': []}]}
        self.graph = {'log': []}
        self.base = {'id': '12345678-abcd', 'kind': 'person', 'name': '尼尔',
                     'note': '已出现', 'knowledge_cutoff': 10, 'expected_revision': 0,
                     'operation': 'aaaaaaaa-bbbb'}

    def test_utf16_anchor_and_versions_do_not_spoil_earlier_pages(self):
        rows, item, conflict = manual_entities.apply([], self.base, self.book, self.graph)
        self.assertFalse(conflict)
        self.assertEqual(item['source_start'], 2)
        self.assertEqual(manual_entities.rows(rows)[0]['p'], 10)
        self.assertEqual(manual_entities.rows(rows)[0]['s'], 2)
        newer = dict(self.base, note='后来才知道', knowledge_cutoff=20,
                     expected_revision=1, operation='cccccccc-dddd')
        rows, item, _ = manual_entities.apply(rows, newer, self.book, self.graph)
        self.assertEqual([x['p'] for x in manual_entities.rows(rows)], [10, 10, 20])
        self.assertEqual(manual_entities.restore(rows, self.book), rows)
        same, replay, _ = manual_entities.apply(rows, newer, self.book, self.graph)
        self.assertIs(same, rows)
        self.assertEqual(replay['revision'], 2)
        with self.assertRaisesRegex(ValueError, '内容已经变化'):
            manual_entities.apply(rows, dict(newer, note='不同的重试内容'), self.book, self.graph)

    def test_existing_visible_name_is_not_duplicated(self):
        with self.assertRaisesRegex(ValueError, '已有这个名称'):
            manual_entities.apply([], self.base, self.book,
                                  {'log': [{'t': 'person', 'p': 8, 'id': 'P1', 'name': '尼尔'}]})

    def test_name_must_be_in_already_read_source(self):
        with self.assertRaisesRegex(ValueError, '当前已读原文'):
            manual_entities.apply([], dict(self.base, name='黑月', knowledge_cutoff=4), self.book, self.graph)

    def test_inline_mentions_preserve_generated_names_and_utf16_positions(self):
        items = [dict(id='12345678-abcd', kind='person', name='尼尔', deleted=False),
                 dict(id='abcdefgh-1234', kind='concept', name='黑月', deleted=False),
                 dict(id='deleted-1234', kind='person', name='遇见', deleted=True)]
        existing = [[2, 4, 'P1']]
        self.assertEqual(manual_entities.mentions(self.book['blocks'], items, existing),
                         [[2, 4, 'P1'], [6, 8, 'Uabcdefgh-1234']])
        self.assertEqual(manual_entities.mentions(self.book['blocks'], items, []),
                         [[2, 4, 'U12345678-abcd'], [6, 8, 'Uabcdefgh-1234']])


class ManualHTTP(HTTPRepair):
    def test_manual_endpoint_cutoff_retry_export_and_delete(self):
        self.make_book()
        base = {'id': '12345678-abcd', 'kind': 'concept', 'name': 'came', 'note': '一个概念',
                'knowledge_cutoff': 10, 'expected_revision': 0, 'operation': 'aaaaaaaa-bbbb'}
        status, _, raw = self.request('PUT', '/api/books/fixture/manual-entities', base)
        self.assertEqual(status, 200, raw)
        self.assertEqual(json.loads(raw)['item']['source_start'], 6)
        self.assertEqual(self.request('PUT', '/api/books/fixture/manual-entities', base)[0], 200)
        self.assertEqual(json.loads(self.request('GET', '/api/books/fixture/manual-entities?to=9')[2])['items'], [])
        self.assertEqual(len(json.loads(self.request('GET', '/api/books/fixture/kg?from=-1&to=9')[2])['records']), 1)
        visible = json.loads(self.request('GET', '/api/books/fixture/kg?from=-1&to=10')[2])['records']
        self.assertEqual([r['t'] for r in visible], ['person', 'person', 'profile'])
        chapter = json.loads(self.request('GET', '/api/books/fixture/chapters/0')[2])
        self.assertEqual(chapter['mentions'], [[0, 5, 'p1'], [6, 10, 'U12345678-abcd']])
        exported = json.loads(self.request('GET', '/api/books/fixture/export')[2])
        self.assertEqual(exported['manual_entities'][0]['name'], 'came')
        imported = json.loads(self.request('POST', '/api/books/import', exported)[2])
        self.assertEqual(json.loads((self.books / imported['id'] / 'manual-entities.json').read_text()), exported['manual_entities'])
        deleted = dict(base, deleted=True, knowledge_cutoff=12, expected_revision=1, operation='cccccccc-dddd')
        self.assertEqual(self.request('PUT', '/api/books/fixture/manual-entities', deleted)[0], 200)
        after = json.loads(self.request('GET', '/api/books/fixture/kg?from=-1&to=12')[2])['records']
        self.assertEqual(len(after), 1)
        chapter = json.loads(self.request('GET', '/api/books/fixture/chapters/0')[2])
        self.assertEqual(chapter['mentions'], [[0, 5, 'p1']])


if __name__ == '__main__':
    unittest.main()
