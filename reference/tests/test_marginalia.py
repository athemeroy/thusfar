"""AI marginalia stays source-anchored, spoiler-bounded and idempotent."""
import json
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from unittest.mock import patch

import test_server_repair as fixtures
from pipeline.parse import u16
from server import app, marginalia


class MarginaliaHTTP(unittest.TestCase):
    setUp = fixtures.HTTPRepair.setUp
    request = fixtures.HTTPRepair.request

    def make_story(self):
        root = self.books / 'story'; root.mkdir()
        text = '她已经听懂了暗示。那封信被她折成很小的一方。后来真相终于出现。'
        book = {'title': '故事', 'author': '测试', 'len': u16(text) + 1, 'lang': 'zh-CN', 'notes': {},
                'blocks': [{'k': 'p', 't': text, 'o': 0, 'fn': []}],
                'chapters': [{'title': '第一章', 'b0': 0, 'b1': 1, 'o0': 0, 'o1': u16(text), 'kind': 'body'}]}
        quote = '那封信被她折成很小的一方。'
        start = u16('她已经听懂了暗示。'); end = start + u16(quote)
        app.wjson(root / 'book.json', book)
        app.wjson(root / 'meta.json', {'auto': False})
        app.wjson(root / 'status.json', {'state': 'done', 'frontier': book['len']})
        app.wjson(root / 'kg.json', {'log': [
            {'t': 'saga', 'p': 2, 'text': '她收到了一封来历不明的信。'},
            {'t': 'event', 'p': start, 'who': [], 'text': '她听懂了暗示。'},
            {'t': 'event', 'p': end + 1, 'who': [], 'text': '未来事件绝不能出现。'},
        ]})
        return root, book, start, end, quote

    def post(self, payload):
        status, _, raw = self.request('POST', '/api/books/story/marginalia', payload)
        return status, json.loads(raw)

    def test_distinct_prefetch_pages_run_concurrently_and_keep_both_cache_rows(self):
        root, book, _, _, _ = self.make_story()
        barrier = threading.Barrier(2, timeout=10)

        def write(*_args, **_kwargs):
            barrier.wait()
            return [{'persona': 'empathy', 'comment': '这封信被折起来，话却像还在纸上。',
                     'guard': {'verdict': 'ok', 'p': .9}}]

        payloads = [{'mode': 'auto', 'purpose': 'prefetch', 'pos': end,
                     'page_start': start, 'page_end': end, 'persona': 'auto'}
                    for start, end in ((0, 18), (18, book['len'] - 1))]
        with patch.object(marginalia, '_generate_many', side_effect=write) as judge, ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(self.post, payloads))
        self.assertEqual([status for status, _ in results], [200, 200])
        self.assertEqual(judge.call_count, 2)
        self.assertEqual(len(json.loads((root / 'marginalia.json').read_text())), 2)
        with patch.object(marginalia, '_generate_many', side_effect=AssertionError('same page must hit cache')):
            status, result = self.post(payloads[0] | {'purpose': 'visible'})
        self.assertEqual((status, result['cached']), (200, True))

    def test_manual_comment_uses_only_text_through_anchor_and_reuses_cache(self):
        root, _, start, end, quote = self.make_story()
        prompts = []

        def fake_chat(_model, messages, **_kwargs):
            prompts.append(messages[-1]['content'])
            return '折得越小，藏不住的心事越大。', {}

        with patch.object(marginalia, 'chat', side_effect=fake_chat) as chat, \
             patch.object(marginalia, 'guard_texts', return_value={'comment': {'verdict': 'ok', 'p': .93}}) as guard:
            code, first = self.post({'mode': 'manual', 'pos': end, 'start': start, 'end': end, 'persona': 'cold'})
            self.assertEqual(code, 200)
            self.assertEqual((first['quote'], first['persona'], first['cached']), (quote, 'cold', False))
            self.assertIn('她收到了一封来历不明的信', prompts[0])
            self.assertIn(quote, prompts[0])
            self.assertNotIn('后来真相', prompts[0])
            self.assertNotIn('未来事件绝不能出现', prompts[0])
            self.assertNotIn('后来真相', guard.call_args.args[0])
            code, second = self.post({'mode': 'manual', 'pos': end, 'start': start, 'end': end, 'persona': 'cold'})
            self.assertEqual(code, 200)
            self.assertTrue(second['cached'])
            self.assertEqual(chat.call_count, 1)
            self.assertEqual(len(json.loads((root / 'marginalia.json').read_text())), 1)
            graph = app.cached_json(root / 'kg.json')
            app.wjson(root / 'kg.json', {'log': graph['log'][:2] + [
                {'t': 'event', 'p': start + 1, 'who': [], 'text': '她把信藏进了袖口。'}] + graph['log'][2:]})
            code, refreshed = self.post({'mode': 'manual', 'pos': end, 'start': start, 'end': end, 'persona': 'cold'})
            self.assertEqual((code, refreshed['cached'], chat.call_count), (200, False, 2))
            self.assertIn('她把信藏进了袖口', prompts[-1])
            self.assertEqual(len(json.loads((root / 'marginalia.json').read_text())), 2)

    def test_auto_reaction_uses_only_visible_page_and_reuses_cache(self):
        _, book, start, end, quote = self.make_story()
        prompts = []

        def write(model, messages, **_kwargs):
            prompts.append((model, messages[-1]['content']))
            return '她把信折得这么小，分明是不想让人看见。', {}

        with patch.object(marginalia, 'chat', side_effect=write) as chat, \
             patch.object(marginalia, 'guard_texts', return_value={
                 persona: {'verdict': 'ok', 'p': .88} for persona in ('empathy', 'detective', 'wit')}) as guard:
            payload = {'mode': 'auto', 'pos': end, 'page_start': start, 'page_end': end, 'persona': 'auto'}
            code, result = self.post(payload)
            code2, cached = self.post(payload)
        self.assertEqual(code, 200)
        self.assertEqual((code2, cached['cached'], chat.call_count), (200, True, 3))
        self.assertEqual((result['start'], result['end'], result['persona'], result['kind']),
                         (start, end, 'empathy', 'reader'))
        self.assertEqual(prompts[0][0], marginalia.AUTO_MODEL)
        self.assertIn('她收到了一封来历不明的信', prompts[0][1])
        self.assertIn(quote, prompts[0][1])
        self.assertNotIn('未来事件绝不能出现', prompts[0][1])
        self.assertNotIn('后来真相', prompts[0][1])
        self.assertNotIn('未来事件绝不能出现', guard.call_args.args[0])
        self.assertEqual(len(result['items']), 1)  # identical drafts are deduplicated
        self.assertLessEqual(result['end'], end)
        self.assertLessEqual(result['position'], book['len'])
        self.assertEqual(result['knowledge_cutoff'], end)

    def test_page_cues_call_jev_once_but_never_generate_prose_until_tapped(self):
        _, _, start, end, quote = self.make_story()
        payload = {'mode': 'cues', 'pos': end, 'page_start': 0,
                   'page_end': end, 'persona': 'auto'}
        choices = {'s1': {'choice': 'ordinary', 'probabilities': {'ordinary': .92}},
                   's2': {'choice': 'clue', 'probabilities': {'ordinary': .05, 'clue': .90}}}
        with patch.object(marginalia, 'jev', return_value=choices) as judge, \
             patch.object(marginalia, 'chat', side_effect=AssertionError('no writing on page turn')):
            code, first = self.post(payload)
            code2, again = self.post(payload)
        self.assertEqual((code, code2, again['cached'], judge.call_count), (200, 200, True, 1))
        self.assertEqual(len(first['items']), 1)
        self.assertEqual((first['items'][0]['quote'], first['items'][0]['persona']), (quote, 'detective'))
        self.assertNotIn('comment', first['items'][0])

    def test_page_cues_include_prior_source_but_no_future_story(self):
        _, _, start, end, quote = self.make_story()
        payload = {'mode': 'cues', 'pos': end, 'page_start': start,
                   'page_end': end, 'persona': 'auto'}
        with patch.object(marginalia, 'jev', return_value={}) as judge:
            code, _ = self.post(payload)
        self.assertEqual(code, 200)
        state = judge.call_args.args[0]
        self.assertIn('她已经听懂了暗示', state['source_before_this_page'])
        self.assertEqual(state['visible_page_sentences'], {'s1': quote})
        self.assertNotIn(quote, state['source_before_this_page'])
        self.assertNotIn('后来真相', str(state))
        self.assertNotIn('未来事件绝不能出现', str(state))

    def test_story_prioritizes_page_character_and_related_history(self):
        people = {f'p{i}': {'id': f'p{i}', 'name': f'路人{i}', 'aliases': [],
                            'n': 100 - i, 'imp': 1, 'bio': ''} for i in range(15)}
        people['p14'].update(name='尼尔', aliases=['奈尔'], n=1, bio='此前藏起了地图')
        world = {'people': people, 'events': [
            {'who': ['p14'], 'text': '尼尔曾经收起地图。'},
            *[{'who': ['p0'], 'text': f'另一条近期记录{i}。'} for i in range(15)]],
            'rels': {'old': {'a': 'p14', 'b': 'p0', 'desc': '曾一起寻找入口'}},
            'saga': ''}
        focused = marginalia._story(world, '奈尔重新看向地图')
        self.assertIn('尼尔｜', focused)
        self.assertIn('本页别名：奈尔', focused)
        self.assertIn('尼尔曾经收起地图', focused)
        self.assertIn('尼尔—路人0：曾一起寻找入口', focused)

    def test_prior_source_window_is_hard_bounded_at_utf16_cutoff(self):
        text = '甲' * 3000 + '😀已经看到。尚未看到。'
        book = {'blocks': [{'k': 'p', 'o': 0, 't': text}]}
        cutoff = u16('甲' * 3000 + '😀已经看到。')
        prior = marginalia._source_before(book, cutoff, chars=2400)
        self.assertLessEqual(len(prior), 2400)
        self.assertTrue(prior.endswith('😀已经看到。'))
        self.assertNotIn('尚未看到', prior)

    def test_clicked_cue_writes_three_distinct_plain_comments_in_parallel(self):
        root, _, start, end, quote = self.make_story()
        payload = {'mode': 'auto', 'pos': end, 'page_start': start,
                   'page_end': end, 'persona': 'detective'}
        barrier = threading.Barrier(3, timeout=5)
        def write(_model, messages, **_kwargs):
            barrier.wait()
            system = messages[0]['content']
            if '「侦探」' in system:
                return '她已经听懂了暗示，为什么还把信折起来？', {}
            if '「共情」' in system:
                return '这信都被折成一小方了，真不想让人看见吧。', {}
            return '嘴上什么也没说，手倒挺忙的。', {}

        with patch.object(marginalia, 'chat', side_effect=write) as writer, \
             patch.object(marginalia, 'guard_texts', return_value={
                 persona: {'verdict': 'ok', 'p': .93} for persona in ('detective', 'empathy', 'wit')}) as guard:
            code, first = self.post(payload)
            code2, second = self.post(payload)
        self.assertEqual((code, code2, second['cached'], writer.call_count), (200, 200, True, 3))
        self.assertEqual(len(first['items']), 3)
        self.assertEqual([item['persona'] for item in first['items']], ['detective', 'empathy', 'wit'])
        self.assertTrue(all(item['quote'] == quote and item['knowledge_cutoff'] == end for item in first['items']))
        self.assertEqual(set(guard.call_args.args[2]), {'detective', 'empathy', 'wit'})
        self.assertTrue(all(call.args[0] == marginalia.AUTO_MODEL for call in writer.call_args_list))
        systems = [call.args[1][0]['content'] for call in writer.call_args_list]
        self.assertEqual(len({system.split('这一次的口吻提示：', 1)[1] for system in systems}), 3)
        self.assertTrue(all('不强求句号' in system for system in systems))
        self.assertEqual(len(json.loads((root / 'marginalia.json').read_text())), 1)

    def test_partial_generation_or_guard_rejection_keeps_only_safe_comments(self):
        _, _, start, end, _ = self.make_story()
        def write(_model, messages, **_kwargs):
            if '「侦探」' in messages[0]['content']:
                raise RuntimeError('provider unavailable')
            return ('手里这封信，她是真不想让别人看见。' if '「共情」' in messages[0]['content']
                    else '这封信都快被她折没了。'), {}
        with patch.object(marginalia, 'chat', side_effect=write), \
             patch.object(marginalia, 'guard_texts', return_value={
                 'empathy': {'verdict': 'ok', 'p': .9}, 'wit': {'verdict': 'flag', 'p': .2}}):
            status, result = self.post({'mode': 'auto', 'pos': end, 'page_start': start,
                                        'page_end': end, 'persona': 'detective'})
        self.assertEqual(status, 200)
        self.assertEqual(len(result['items']), 1)
        self.assertEqual(result['items'][0]['persona'], 'empathy')

    def test_invalid_anchor_never_generates(self):
        _, _, start, end, _ = self.make_story()
        self.assertEqual(self.post({'mode': 'manual', 'pos': end, 'start': start, 'end': end + 2,
                                    'persona': 'empathy'})[0], 400)
        self.assertEqual(self.post({'mode': 'auto', 'pos': end, 'page_start': 0,
                                    'page_end': end + 1, 'persona': 'auto'})[0], 400)

    def test_utf16_candidate_offsets_round_trip(self):
        text = '😀她终于笑了。下一句话。'
        book = {'blocks': [{'k': 'p', 't': text, 'o': 10}]}
        rows = marginalia._page_candidates(book, 10, 10 + u16(text))
        self.assertEqual(rows[0]['start'], 10)
        self.assertEqual(rows[0]['end'], 10 + u16('😀她终于笑了。'))
        self.assertEqual(rows[0]['quote'], '😀她终于笑了。')

    def test_prompt_fragments_and_truncated_comments_are_not_published(self):
        self.assertEqual(marginalia._clean('、Markdown、表情等。'), '')
        self.assertEqual(marginalia._clean('争了半天责任，'), '')
        self.assertEqual(marginalia._clean('嘴上说着随便，这手倒是诚实得很嘛'),
                         '嘴上说着随便，这手倒是诚实得很嘛')
        self.assertEqual(marginalia._clean('他居然真的信了😂'), '他居然真的信了😂')
        self.assertEqual(marginalia._clean('这句我真的绷不住(￣▽￣)'), '这句我真的绷不住(￣▽￣)')


if __name__ == '__main__':
    unittest.main()
