"""Unit tests for the temporal knowledge graph (no model calls: extraction output is synthetic).

run: python -m unittest tests.test_kg -v
"""
import unittest

from pipeline.kg import KG, zh, good_alias, generic_word
from pipeline.parse import finish
from pipeline.extract import segments
from server.temporal import fold


def make_book(paragraphs):
    blocks = [{'k': 'p', 't': t} for t in paragraphs]
    book = finish(blocks, [(0, '第一章', 0)], {}, '测试书', '作者')
    for c in book['chapters']:
        c['kind'] = 'body'
    return book


TEXT = [
    '一个穿黑斗篷的人走进了客栈，大家都叫他黑衣人。',
    '掌柜的给黑衣人倒了一碗酒，黑衣人一句话也不说。',
    '夜深了，黑衣人摘下斗篷，原来他就是失踪多年的陈明。',
    '陈明对掌柜说：我回来了。掌柜的哭了。',
]

EXTRACTION = {
    'new_people': [
        {'ref': 'N1', 'name': '黑衣人', 'gender': '男', 'importance': 3, 'para': 1, 'quote': '一个穿黑斗篷的人走进了客栈', 'intro': '穿黑斗篷的神秘人'},
        {'ref': 'N2', 'name': '掌柜', 'gender': '男', 'importance': 2, 'para': 2, 'quote': '掌柜的给黑衣人倒了一碗酒', 'intro': '客栈掌柜'},
        {'ref': 'N3', 'name': '陈明', 'gender': '男', 'importance': 3, 'para': 3, 'quote': '原来他就是失踪多年的陈明', 'intro': '失踪多年的人'},
    ],
    'surfaces': {'N1': ['黑衣人'], 'N2': ['*掌柜'], 'N3': ['陈明']},
    'aliases': [],
    'merges': [{'from': 'N1', 'into': 'N3', 'para': 3, 'quote': '原来他就是失踪多年的陈明', 'reason': '黑衣人摘下斗篷'}],
    # the model (knowing the reveal) wrongly credits the early events to 陈明 and names him too early
    'events': [
        {'who': ['N3', 'N2'], 'text': '陈明进客栈，掌柜给他倒酒', 'para': 2, 'quote': '掌柜的给黑衣人倒了一碗酒', 'importance': 2},
        {'who': ['N3'], 'text': '陈明摘下斗篷露出真面目', 'para': 3, 'quote': '黑衣人摘下斗篷', 'importance': 3},
        {'who': ['N3', 'N2'], 'text': '陈明对掌柜说他回来了', 'para': 4, 'quote': '陈明对掌柜说：我回来了', 'importance': 2},
    ],
    'attrs': [{'who': 'N2', 'key': '职业', 'value': '客栈掌柜', 'para': 1, 'quote': '走进了客栈'}],
    'rels': [],
    'profiles': [{'who': 'N3', 'tagline': '失踪多年后归来的人', 'bio': '陈明失踪多年，今夜回到客栈。', 'para': 4}],
}


class KGTest(unittest.TestCase):
    def setUp(self):
        self.book = make_book(TEXT)
        self.seg = segments(self.book, [0])[0]
        self.kg = KG(self.book)
        plan = self.kg.plan(self.seg, EXTRACTION)
        decisions = {o['key']: o['ids'][0] for o in plan['occs'] if o['ambiguous']}
        self.log = self.kg.commit(self.seg, EXTRACTION, plan, decisions)
        self.intro = {r['id']: r['p'] for r in self.log if r['t'] == 'person'}
        self.reveal = next(r for r in self.log if r['t'] == 'merge')['p']

    def test_nothing_about_a_person_before_they_enter(self):
        for r in self.log:
            if r['t'] in ('attr', 'profile', 'alias', 'name') and r.get('id') in self.intro:
                self.assertGreaterEqual(r['p'], self.intro[r['id']], r)

    def test_early_events_belong_to_the_identity_the_reader_knows(self):
        early = [r for r in self.log if r['t'] == 'event' and r['p'] < self.reveal]
        self.assertTrue(early)
        for r in early:
            self.assertNotIn('P3', r['who'], r)      # 陈明 is not known yet
            self.assertIn('P1', r['who'], r)         # it was the man in black

    def test_revealed_name_not_used_before_the_reveal(self):
        for r in self.log:
            text = ' '.join(str(r.get(k) or '') for k in ('text', 'tagline', 'bio', 'intro', 'value'))
            if '陈明' in text:
                self.assertGreaterEqual(r['p'], self.book['blocks'][2]['o'], r)

    def test_merge_links_the_two_records(self):
        m = next(r for r in self.log if r['t'] == 'merge')
        self.assertEqual((m['from'], m['into']), ('P1', 'P3'))
        self.assertEqual(self.kg.canon('P1'), 'P3')

    def test_generic_title_needs_a_decision(self):
        plan = KG(self.book).plan(self.seg, EXTRACTION)
        amb = {o['surface'] for o in plan['occs'] if o['ambiguous']}
        self.assertIn('掌柜', amb)
        self.assertNotIn('陈明', amb)

    def test_mentions_are_positioned_on_the_text(self):
        full = '\n'.join(b['t'] for b in self.book['blocks'])
        for s, e, pid, g in self.kg.mentions:
            self.assertIn(full[s:e], ('黑衣人', '陈明', '掌柜'))


class TextTest(unittest.TestCase):
    def test_generic_reveal_keeps_old_label_only_before_the_reveal(self):
        self.assertTrue(generic_word('少女'))
        log = [{'t': 'person', 'p': 10, 'id': 'P1', 'name': '少女'},
               {'t': 'person', 'p': 30, 'id': 'P2', 'name': '丛雨'},
               {'t': 'merge', 'p': 35, 'from': 'P2', 'into': 'P1'}]
        self.assertEqual(fold(log, 34)['people']['P1']['name'], '少女')
        after = fold(log, 35)['people']['P1']
        self.assertEqual(after['name'], '丛雨')
        self.assertNotIn('少女', after['aliases'])
        kg = KG(make_book(['少女自称丛雨。']))
        kg.people = {'P1': {'name': '少女', 'aliases': {'少女'}, 'mentions': 1},
                     'P2': {'name': '丛雨', 'aliases': {'丛雨'}, 'mentions': 1}}
        kg.merge('P2', 'P1', 35, 30, '原文点名')
        self.assertEqual(kg.people['P1']['name'], '丛雨')

    def test_zh_punctuation(self):
        self.assertEqual(zh('他说"好",然后(笑了)'), '他说“好”，然后（笑了）')
        self.assertEqual(zh('Hello, world'), 'Hello, world')

    def test_alias_filter(self):
        for bad in ('太太', '查理夫妇', '卢欧老爹的女儿', '未婚女婿', '他们'):
            self.assertFalse(good_alias(bad), bad)
        for ok in ('老Q', '小D', '爱玛', '包法利先生'):
            self.assertTrue(good_alias(ok), ok)


if __name__ == '__main__':
    unittest.main()
