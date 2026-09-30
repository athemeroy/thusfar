"""Support checks follow the actual claim and survive judge-only retries without extraction."""
import copy
import json
import os
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from pipeline.extract import segments
from pipeline.llm import LLMError
from pipeline.run import Runner, drop_unsupported


def verdict(choice='supported'):
    return {'choice': choice, 'p': 1.0 if choice == 'supported' else 0.0,
            'probs': {choice: 1.0}}


class SupportCache(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.runner = Runner.__new__(Runner)
        r = self.runner
        r.root = Path(self.temp.name)
        r.work = r.root / 'work'
        r.lock = threading.RLock()
        r.usage = {'jev_calls': 0}
        r.count = Mock()
        text = 'Alice speaks to Bob about an ordinary book. ' * 30
        r.book = {'title': 'fixture', 'lang': 'zh', 'chapters': [
            {'title': 'Chapter', 'b0': 0, 'b1': 1, 'o0': 0, 'o1': len(text), 'kind': 'body'}],
            'blocks': [{'k': 'p', 't': text, 'o': 0}]}
        r.segs = segments(r.book, [0])
        self.data = {'people': [{'id': 'a', 'name': 'Alice', 'names': ['Alice']},
                                {'id': 'b', 'name': 'Bob', 'names': ['Bob']}],
                     'same': [], 'events': [{'who': ['a', 'b'], 'text': 'Alice speaks to Bob.',
                                            'imp': 1, 'para': 1, 'quote': 'Alice speaks to Bob'}],
                     'facts': [{'who': 'a', 'key': 'identity', 'value': 'a speaker'}], 'rels': []}
        self.env = patch.dict(os.environ, {'EVENT_CHECK_ONE_IN': '1', 'VERIFY_RECORDS': '1',
                                          'JUDGE_RELATIONS': '1', 'CARD_LANG': 'zh'})
        self.env.start()
        self.addCleanup(self.env.stop)

    def record(self, legacy=False):
        rec = {'seg': 0, 'model': 'fixture', 'data': copy.deepcopy(self.data)}
        if legacy:
            rec['support'] = {'e0': verdict(), 'a0': verdict()}
        return rec

    @staticmethod
    def combined(_text, items, *_args):
        return {key: verdict() for key in items}, {}

    def test_added_worded_relation_gets_own_check_and_negative_is_dropped(self):
        rec = self.record()
        relation = {'ties': [{'role': 'other', 'family': 'social', 'p': 0.9}], 'state': None, 'stance': None}
        with patch('pipeline.run.check_and_families', side_effect=self.combined) as combined, \
                patch('pipeline.run.relations_by_judge', return_value={('a', 'b'): relation}), \
                patch.object(self.runner, 'name_relations', return_value={('a', 'b'): {'b_is': '房东'}}), \
                patch('pipeline.run.verify_records', return_value={'r0': verdict('not_in_passage')}) as verify:
            self.runner.add_support(self.runner.add_relations(rec, 0), 0)
        self.assertEqual(set(combined.call_args.args[1]), {'e0', 'a0'})
        self.assertEqual(set(verify.call_args.args[1]), {'r0'})
        self.assertEqual(rec['data']['rels'][0]['by'], 'judge+llm')
        kept, dropped = drop_unsupported(rec['data'], rec['support'])
        self.assertEqual(kept['rels'], [])
        self.assertEqual(dropped, [['r0', 0.0, 'not_in_passage']])
        self.assertEqual(rec['support']['a0'], verdict())
        self.assertEqual(set(rec['support_fingerprints']), {'e0', 'a0', 'r0'})

    def test_changed_existing_wording_invalidates_only_its_old_check(self):
        rec = self.record(legacy=True)
        rec['data']['rels'] = [{'a': 'a', 'b': 'b', 'b_is': 'B 对 A 而言是一个有待确认的关系', 'a_is': ''}]
        rec['support']['r0'] = verdict()
        relation = {'ties': [{'role': 'friend', 'family': 'social', 'p': 0.9}], 'state': None, 'stance': None}
        with patch('pipeline.run.check_and_families', side_effect=self.combined) as combined, \
                patch('pipeline.run.relations_by_judge', return_value={('a', 'b'): relation}), \
                patch('pipeline.run.verify_records', return_value={'r0': verdict('contradicted')}) as verify:
            self.runner.add_support(self.runner.add_relations(rec, 0), 0)
        self.assertEqual(combined.call_args.args[1], {})
        self.assertEqual(set(verify.call_args.args[1]), {'r0'})
        self.assertEqual(rec['data']['rels'][0]['b_is'], '朋友')
        self.assertEqual(drop_unsupported(rec['data'], rec['support'])[0]['rels'], [])
        self.assertEqual(rec['support']['e0'], verdict())

    def test_confident_context_judge_corrects_a_canonical_reversed_role(self):
        rec = self.record(legacy=True)
        rec['relation_context'] = {'story_before_this_passage': 'Alice is Bob’s mother.',
                                   'character_context': {'a': {'known_before': {'bio': 'Bob的母亲'}},
                                                         'b': {'known_before': {'bio': 'Alice的儿子'}}}}
        rec['data']['rels'] = [{'a': 'a', 'b': 'b', 'b_is': '父母', 'a_is': '子女'}]
        rec['support']['r0'] = verdict()
        relation = {'ties': [{'role': 'child', 'family': 'kin', 'p': .97}], 'state': None, 'stance': None}
        with patch('pipeline.run.check_and_families', side_effect=self.combined), \
                patch('pipeline.run.relations_by_judge', return_value={('a', 'b'): relation}) as judged, \
                patch('pipeline.run.verify_records', return_value={'r0': verdict()}):
            self.runner.add_support(self.runner.add_relations(rec, 0), 0)
        self.assertEqual((rec['data']['rels'][0]['b_is'], rec['data']['rels'][0]['a_is']), ('子女', '父母'))
        self.assertEqual(judged.call_args.args[-1], rec['relation_context'])

    def test_legacy_cached_rewrite_is_checked_once_and_other_keys_survive(self):
        rec = self.record(legacy=True)
        rec['judge_rels'] = {}
        rec['data']['rels'] = [{'a': 'a', 'b': 'b', 'b_is': '朋友', 'fixed_by': 'judge'}]
        rec['support']['r0'] = verdict()
        with patch('pipeline.run.verify_records', return_value={'r0': verdict()}) as verify:
            self.runner.add_support(rec, 0)
            self.runner.add_support(rec, 0)
        verify.assert_called_once()
        self.assertEqual(set(verify.call_args.args[1]), {'r0'})
        self.assertEqual(rec['support_sampling'], 'legacy')
        self.assertEqual(set(rec['support_legacy_adopted']), {'e0', 'a0'})

    def test_fingerprints_detect_changed_claim_and_complete_passage(self):
        rec = self.record(legacy=True)
        with patch('pipeline.run.verify_records') as verify:
            self.runner.add_support(rec, 0)
        verify.assert_not_called()
        old_event = rec['support_fingerprints']['e0']
        rec['data']['facts'][0]['value'] = 'a different identity'
        with patch('pipeline.run.verify_records', return_value={'a0': verdict('not_in_passage')}) as verify:
            self.runner.add_support(rec, 0)
        self.assertEqual(set(verify.call_args.args[1]), {'a0'})
        self.assertEqual(rec['support_fingerprints']['e0'], old_event)
        text = self.runner.book['blocks'][0]['t']
        self.runner.book['blocks'][0]['t'] = text[:300] + 'changed evidence' + text[300:]
        with patch('pipeline.run.verify_records', return_value={'a0': verdict(), 'e0': verdict()}) as verify:
            self.runner.add_support(rec, 0)
        self.assertEqual(set(verify.call_args.args[1]), {'a0', 'e0'})
        self.assertNotEqual(rec['support_fingerprints']['e0'], old_event)

    def test_fresh_event_sampling_is_stable_and_legacy_sampling_is_preserved(self):
        data = copy.deepcopy(self.data)
        data['events'] = [{'text': f'Ordinary event {i}.', 'imp': 1} for i in range(60)]
        with patch.dict(os.environ, {'EVENT_CHECK_ONE_IN': '6'}):
            with patch('builtins.hash', return_value=0):
                first = self.runner.support_items(data)
            with patch('builtins.hash', return_value=1):
                second = self.runner.support_items(data)
            self.assertEqual(first, second)
            sampled = {key for key in first if key.startswith('e')}
            self.assertTrue(0 < len(sampled) < 60)
            old_key = next(f'e{i}' for i in range(60) if f'e{i}' not in sampled)
            rec = {'data': data, 'support': {old_key: verdict(), 'a0': verdict()}}
            with patch('pipeline.run.verify_records') as verify:
                self.runner.add_support(rec, 0)
            verify.assert_not_called()
            self.assertEqual(set(rec['support']), {old_key, 'a0'})

    def test_failed_check_retries_from_cache_without_reextracting(self):
        usage = {'prompt_tokens': 3, 'completion_tokens': 4, '_raw': '{}'}
        with patch.dict(os.environ, {'JUDGE_RELATIONS': '0'}), \
                patch('pipeline.run.extract_local', return_value=(copy.deepcopy(self.data), usage)) as extract, \
                patch('pipeline.run.verify_records', side_effect=[RuntimeError('judge unavailable'),
                            {'e0': verdict(), 'a0': verdict()}]) as verify, \
                patch('pipeline.run.time.sleep') as sleep:
            with self.assertRaisesRegex(RuntimeError, 'judge unavailable'):
                self.runner._local_job(0, 'fixture')
            cached = json.loads(self.runner.local_path(0).read_text())
            self.assertIn('support_error', cached)
            result = self.runner._local_job(0, 'fixture')
        extract.assert_called_once()
        sleep.assert_not_called()
        self.assertEqual(verify.call_count, 2)
        self.assertNotIn('support_error', result)

    def test_partial_answer_retries_only_missing_question(self):
        rec = self.record()
        with patch('pipeline.run.verify_records', side_effect=[{'a0': verdict()}, {'e0': verdict()}]) as verify:
            with self.assertRaises(LLMError):
                self.runner.add_support(rec, 0)
            cached = json.loads(self.runner.local_path(0).read_text())
            self.assertEqual(set(cached['support']), {'a0'})
            self.runner.add_support(cached, 0)
        self.assertEqual(set(verify.call_args_list[0].args[1]), {'a0', 'e0'})
        self.assertEqual(set(verify.call_args_list[1].args[1]), {'e0'})

    def test_relation_failure_keeps_successful_checks_and_never_reextracts(self):
        usage = {'prompt_tokens': 3, 'completion_tokens': 4, '_raw': '{}'}
        with patch('pipeline.run.extract_local', return_value=(copy.deepcopy(self.data), usage)) as extract, \
                patch('pipeline.run.check_and_families', side_effect=self.combined) as combined, \
                patch('pipeline.run.relations_by_judge', side_effect=[RuntimeError('relation unavailable'), {}]), \
                patch('pipeline.run.verify_records') as verify:
            with self.assertRaisesRegex(RuntimeError, 'relation unavailable'):
                self.runner._local_job(0, 'fixture')
            result = self.runner._local_job(0, 'fixture')
        extract.assert_called_once()
        verify.assert_not_called()
        self.assertEqual(set(combined.call_args_list[0].args[1]), {'e0', 'a0'})
        self.assertEqual(combined.call_args_list[1].args[1], {})
        self.assertNotIn('relation_check_error', result)


if __name__ == '__main__':
    unittest.main()
