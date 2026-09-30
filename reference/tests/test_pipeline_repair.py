"""Product invariants at temporal, verification, replay, and spending boundaries."""
import copy
import io
import json
import os
import tempfile
import threading
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

from pipeline import llm, provenance
from pipeline.classify import classify_chapters
from pipeline.extract import segments
from pipeline.judge import family_questions, relations_by_judge
from pipeline.kg import KG, quarantine_identities
from pipeline.link import to_classic
from pipeline.parse import DocParser, finish, parse_epub
from pipeline.run import Runner


def make_book(texts):
    book = finish([{'k': 'p', 't': t} for t in texts], [(0, 'Chapter', 0)], {}, 'fixture', '')
    book.update(classified=True, genre='novel')
    for chapter in book['chapters']:
        chapter.update(kind='body', spoil=False)
    return book


def local():
    return {'people': [{'id': 'a', 'name': 'Alice', 'names': ['Alice'], 'para': 1, 'quote': 'Alice met Bob'},
                       {'id': 'b', 'name': 'Bob', 'names': ['Bob'], 'para': 1, 'quote': 'Alice met Bob'}],
            'same': [], 'facts': [], 'rels': [],
            'events': [{'who': ['a', 'b'], 'text': 'Alice met Bob', 'quote': 'Alice met Bob', 'para': 1}]}


class PipelineRepair(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.block = patch('pipeline.llm._opener', side_effect=AssertionError('network forbidden'))
        self.block.start()
        self.addCleanup(self.block.stop)
        self.env = patch.dict(os.environ, {'JUDGE_LOG_DIR': str(self.root / 'judge'), 'JEV_ROUTE': 'free-only'})
        self.env.start()
        self.addCleanup(self.env.stop)

    def runner(self, book=None):
        book = book or make_book(['Alice met Bob at the station.', 'Later she revealed Bob was her brother.'])
        (self.root / 'book.json').write_text(json.dumps(book))
        runner = Runner(self.root, 'fixture')
        for pool in (runner.pool, runner.recap_pool, runner.saga_pool):
            self.addCleanup(pool.shutdown)
        return runner

    def test_relation_status_survives_conversion_and_kg(self):
        for status in ('new', 'changed', 'ended'):
            data = local()
            data['rels'] = [{'a': 'a', 'b': 'b', 'b_is': 'friend', 'status': status}]
            converted = to_classic(data, {})
            self.assertEqual(converted['rels'][0]['status'], status)
            book = make_book(['Alice met Bob.'])
            seg = segments(book, [0])[0]
            kg = KG(book)
            records = kg.commit(seg, converted, kg.plan(seg, converted), {})
            self.assertEqual(next(x for x in records if x['t'] == 'rel')['status'], status)

    def test_short_identity_reveal_and_unicode_entry(self):
        book = make_book(['😀黑衣人推门走入客栈。', '随后他才报出真名：陈明。'])
        seg = segments(book, [0])[0]
        data = {'new_people': [{'ref': 'N1', 'name': '陈明', 'para': 1, 'quote': '黑衣人推门走入客栈', 'intro': '失踪的陈明'}],
                'surfaces': {'N1': ['黑衣人', '陈明']}}
        kg = KG(book)
        records = kg.commit(seg, data, kg.plan(seg, data), {})
        person = next(x for x in records if x['t'] == 'person')
        reveal = next(x for x in records if x['t'] == 'name')
        self.assertEqual(person['name'], '黑衣人')
        self.assertEqual(person['intro'], '')
        self.assertGreaterEqual(reveal['p'], book['blocks'][1]['o'])
        self.assertTrue(all('陈明' not in str(x) for x in records if x['p'] < book['blocks'][1]['o']))

    def test_merge_between_existing_people_does_not_rewrite_past(self):
        book = make_book(['黑衣人离开了。王子留在宫里。', '黑衣人偷走了信件。', '此时才揭晓：黑衣人就是王子。'])
        kg = KG(book)
        first = {'blocks': [0], 'o0': 0, 'o1': book['blocks'][1]['o'] - 1}
        second = {'blocks': [1, 2], 'o0': book['blocks'][1]['o'], 'o1': book['len'] - 1}
        data = {'new_people': [{'ref': 'N1', 'name': '黑衣人', 'para': 1, 'quote': '黑衣人离开了'},
                               {'ref': 'N2', 'name': '王子', 'para': 1, 'quote': '王子留在宫里'}]}
        kg.commit(first, data, kg.plan(first, data), {})
        data = {'merges': [{'from': 'P1', 'into': 'P2', 'para': 2, 'quote': '黑衣人就是王子'}],
                'events': [{'who': ['P1'], 'text': '黑衣人偷信', 'para': 1, 'quote': '黑衣人偷走了信件'}]}
        records = kg.commit(second, data, kg.plan(second, data), {})
        event, merge = [next(x for x in records if x['t'] == kind) for kind in ('event', 'merge')]
        self.assertEqual(event['who'], ['P1'])
        self.assertLess(event['p'], merge['p'])
        self.assertEqual(kg.canon('P1'), 'P2')

    def test_judge_relation_uses_evidence_frontier(self):
        r = self.runner()
        data = local()
        data['rels'] = [{'a': 'a', 'b': 'b', 'by': 'judge', 'b_is': 'sibling', 'para': 1, 'quote': 'Alice met Bob'}]
        data = to_classic(data, {})
        recs = r.kg.commit(r.segs[0], data, r.kg.plan(r.segs[0], data), {})
        self.assertEqual(next(x for x in recs if x['t'] == 'rel')['p'], r.segs[0]['o1'])

    def test_missing_facets_propagate_for_retry(self):
        with patch('pipeline.judge.jev', side_effect=[
            {'l1': {'choice': 'spouse', 'probabilities': {'spouse': .99}}}, llm.LLMError('outage')]):
            with self.assertRaises(llm.LLMError):
                relations_by_judge('fixture', [('a', 'b')], {'a': 'Alice', 'b': 'Bob'},
                                   {('a', 'b'): [('marriage', .99)]})

    def test_relation_judge_receives_character_memory_but_requires_current_evidence(self):
        context = {'story_before_this_passage': 'Alice has been hiding a family secret.',
                   'previous_passage_tail': 'Bob called her sister before leaving.',
                   'character_context': {'a': {'known_before': {'name': 'Alice', 'bio': 'Bob的姐姐'}},
                                         'b': {'known_before': {'name': 'Bob', 'bio': 'Alice的弟弟'}}}}
        answer = {'l1': {'choice': 'sibling', 'probabilities': {'sibling': .96, 'other': .04}}}
        with patch('pipeline.judge.jev', return_value=answer) as judge:
            result = relations_by_judge('Alice met Bob again.', [('a', 'b')], {'a': 'Alice', 'b': 'Bob'},
                                        {('a', 'b'): [('kin', .9)]}, context=context)
        state, questions = judge.call_args.args
        self.assertEqual(state['character_context'], context['character_context'])
        self.assertEqual(state['previous_passage_tail'], context['previous_passage_tail'])
        self.assertIn('the tie must still be established',
                      next(iter(family_questions([('a', 'b')], {'a': 'Alice', 'b': 'Bob'},
                                                 has_context=True).values()))['instructions'])
        self.assertEqual(result[('a', 'b')]['ties'][0]['role'], 'sibling')

    def test_relation_memory_keeps_biography_events_and_existing_ties(self):
        runner = self.runner()
        common = {'aliases': set(), 'weak': set(), 'first': 0, 'mentions': 8, 'last_seg': 0,
                  'imp': 2, 'merged_into': None, 'intro': ''}
        runner.kg.people = {
            'P1': dict(common, id='P1', name='Alice', tagline='寄住在车站的姐姐', bio='一路照料弟弟并隐瞒来信。'),
            'P2': dict(common, id='P2', name='Bob', tagline='Alice的弟弟', bio='刚回到镇上。'),
        }
        runner.kg.rels = {'P1|P2': {'a': 'P1', 'b': 'P2', 'a_is': '姐姐', 'b_is': '弟弟', 'desc': '姐弟', 'status': 'new'}}
        runner.kg.log = [{'t': 'event', 'p': 4, 'who': ['P1', 'P2'], 'text': 'Alice在站台接到了Bob。'}]
        runner.kg.recent = ['Alice在站台接到了Bob。']
        runner.kg.saga = '姐弟二人在车站重逢。'
        memory = runner.relation_memory()
        context = runner.relation_context(0, {'people': [
            {'id': 'a', 'name': 'Alice', 'known': 'P1', 'known_name': 'Alice', 'role': '写信的人'},
            {'id': 'b', 'name': 'Bob', 'known': 'P2', 'known_name': 'Bob', 'role': '回乡者'}]}, memory)
        alice = context['character_context']['a']['known_before']
        self.assertEqual(alice['bio'], '一路照料弟弟并隐瞒来信。')
        self.assertIn('Bob（弟弟）', alice['known_relations'])
        self.assertIn('Alice在站台接到了Bob。', alice['recent_events'])
        self.assertIn('姐弟二人在车站重逢', context['story_before_this_passage'])

    def test_critical_outage_keeps_extraction_and_does_not_publish(self):
        r = self.runner()
        data = to_classic(local(), {})
        data['events'][0]['text'] = 'Alice杀死了Bob。'
        with patch('pipeline.run.link_segment', return_value=(data, {'decisions': {}})), \
                patch.object(r, 'verify_critical', side_effect=llm.LLMError('outage')):
            with self.assertRaises(llm.LLMError):
                r.link(0, {'data': local(), 'model': 'fixture'})
        self.assertFalse(r.seg_path(0).exists())
        self.assertEqual(json.loads((r.work / 'verification/0000.json').read_text())['state'], 'failed')

    def test_biography_order_and_unchecked_publication(self):
        r = self.runner()
        r.kg.people['P1'] = {'name': 'Alice'}
        def bio(text, verdict='ok'):
            return {'bios': {'P1': {'bio': text, 'chk': {'verdict': verdict}}}}
        r._apply_bios(bio('new'), 200)
        r._apply_bios(bio('old'), 100)
        r._apply_bios(bio('unchecked', 'unchecked'), 300)
        self.assertEqual(r.kg.people['P1']['bio'], 'new')
        self.assertEqual([x['p'] for x in r.kg.log], [200, 100])

    def test_complete_replay_is_model_free_and_preserves_final_decisions(self):
        r = self.runner()
        data = to_classic(local(), {})
        data['attrs'] = [{'who': 'Na', 'key': '住处', 'value': 'old', 'para': 1},
                         {'who': 'Na', 'key': '住处', 'value': 'new', 'para': 2}]
        r.prior_log = [{'t': 'imp', 'p': r.segs[0]['o1'], 'id': 'P1', 'imp': 3}]
        for path, value in {
            r.seg_path(0): {'seg': 0, 'mode': 'two-phase', 'data': data},
            r.dedupe_path(0): {'pairs': [], 'merged': []}, r.bio_path(0): {'bios': {}},
            r.recap_path(0): {'recap': 'cached', 'guard': {'recap': {'verdict': 'ok'}}},
            r.saga_path(r.segs[0]['o1']): {'saga': 'cached', 'guard': {'saga': {'verdict': 'ok'}}},
        }.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(value))
        with patch('pipeline.run.importance', side_effect=AssertionError('rejudge')), \
                patch('pipeline.run.current_value', side_effect=AssertionError('rejudge')):
            r.run2(limit=0)
        self.assertEqual(r.kg.people['P1']['imp'], 3)

    def test_generation_draft_is_reused_after_failed_guard(self):
        r = self.runner()
        with patch('pipeline.run.chat_json', return_value=({'P1': {'bio': 'biography'}}, {})) as generate, \
                patch('pipeline.run.guard_texts', side_effect=[llm.LLMError('outage'), {'P1': {'verdict': 'ok', 'p': .9}}]):
            with self.assertRaises(llm.LLMError):
                r._bio_job(0, 100, 'original dossier', ['P1'])
            self.assertFalse(r.bio_path(0).exists())
            r._bio_job(0, 100, 'original dossier', ['P1'])
        self.assertEqual(generate.call_count, 1)

    def test_collection_keeps_interstitial_front_matter(self):
        with patch('pipeline.classify.classify_by_judge', return_value=['body', 'front', 'body']):
            self.assertEqual(classify_chapters({}), ['body', 'front', 'body'])

    def test_free_alias_never_reads_paid_credentials_on_outage(self):
        for route in ('free', 'free-only'):
            with patch.dict(os.environ, {'JEV_ROUTE': route, 'JUDGE_CACHE': '0'}), \
                    patch.object(llm, '_free_breaker', llm._Breaker('fixture')), \
                    patch.object(llm, 'jev_free', side_effect=llm.LLMError('outage')), \
                    patch.object(llm, '_env', side_effect=AssertionError('paid credentials')):
                with self.assertRaises(llm.LLMError):
                    llm.jev('state', {'q': {'criteria': {'a': 'A'}}})

    def test_paid_budget_persists_and_concurrency_cannot_exceed_cap(self):
        from concurrent.futures import ThreadPoolExecutor
        with patch.dict(os.environ, {'JEV_BUDGET_FILE': str(self.root / 'budget.json'),
                                    'JEV_PAID_MAX_CALLS': '3', 'JEV_PAID_MAX_CHARS': '100'}):
            def reserve(_):
                try:
                    provenance.reserve_paid(20, 1)
                    return True
                except RuntimeError:
                    return False
            with ThreadPoolExecutor(8) as pool:
                self.assertEqual(sum(pool.map(reserve, range(20))), 3)
            self.assertEqual(json.loads((self.root / 'budget.json').read_text())['calls'], 3)
            with self.assertRaises(RuntimeError):
                provenance.reserve_paid(1, 1)

    def test_paid_budget_default_uses_durable_data_directory(self):
        with patch.dict(os.environ, {'DATA_DIR': str(self.root), 'JEV_PAID_MAX_CALLS': '1'}, clear=True):
            provenance.reserve_paid(1, 1)
            self.assertEqual(json.loads((self.root / 'paid-budget.json').read_text())['calls'], 1)
            with self.assertRaises(RuntimeError):
                provenance.reserve_paid(1, 1)

    def test_legacy_chat_fallback_cannot_bypass_route_or_teacher_provenance(self):
        with patch.dict(os.environ, {'JEV_ROUTE': 'paid', 'JUDGE_FALLBACK': '1'}), \
                patch.object(llm, '_env', return_value=None), \
                patch.object(llm, 'llm_judge', side_effect=AssertionError('chat fallback')):
            with self.assertRaises(llm.LLMError):
                llm.jev('state', {'q': {'criteria': {'yes': 'yes', 'no': 'no'}}})

    def test_saga_refuses_missing_or_unverified_recap_before_generation(self):
        r = self.runner()
        for record in (None, {'recap': 'unchecked'}):
            if record:
                r.recap_path(0).parent.mkdir(parents=True, exist_ok=True)
                r.recap_path(0).write_text(json.dumps(record))
            with patch.object(r, 'cached_generation', side_effect=AssertionError('generation')):
                with self.assertRaises(llm.LLMError):
                    r._saga_job(r.segs[0]['o1'], [0])

    def test_verified_output_reconciles_unacknowledged_job_without_calls(self):
        r = self.runner()
        r.two_phase = True
        path = r.work / 'jobs/recap-0.json'
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({'kind': 'recap', 'key': 0, 'state': 'pending'}))
        r.quality_pending.add('recap-0')
        r.recap_path(0).parent.mkdir(parents=True)
        r.recap_path(0).write_text(json.dumps({'recap': 'verified', 'guard': {'recap': {'verdict': 'ok'}}}))
        with patch.object(r, 'cached_generation', side_effect=AssertionError('generation')):
            r.recap(0, r.segs[0]['o1'], 0)
        self.assertNotIn('recap-0', r.quality_pending)
        self.assertEqual(json.loads(path.read_text())['state'], 'complete')

    def test_identity_taint_propagates_at_temporal_merge_boundaries(self):
        rows = [{'t': 'merge', 'p': 5, 'from': 'P1', 'into': 'P2'},
                {'t': 'merge', 'p': 20, 'from': 'P2', 'into': 'P3'},
                {'t': 'event', 'p': 8, 'who': ['P2'], 'text': 'early'},
                {'t': 'event', 'p': 12, 'who': ['P2'], 'text': 'tainted'},
                {'t': 'event', 'p': 19, 'who': ['P3'], 'text': 'before later merge'},
                {'t': 'event', 'p': 21, 'who': ['P3'], 'text': 'after later merge'}]
        kept, mentions, dropped, _, taint = quarantine_identities(rows, [[9, 11, 'P2', 0], [18, 19, 'P3', 0]], {'P1': 10})
        self.assertEqual(taint, {'P1': 10, 'P2': 10, 'P3': 20})
        self.assertEqual([r['text'] for r in kept if r['t'] == 'event'], ['early', 'before later merge'])
        self.assertEqual(mentions, [[18, 19, 'P3', 0]])
        self.assertEqual(len(dropped), 3)

    def test_tainted_person_retains_source_identity_without_unverified_intro(self):
        person = {'t': 'person', 'p': 1, 'id': 'P1', 'name': 'Alice', 'intro': 'Secret identity claim'}
        kept, _, withheld, _, _ = quarantine_identities([person], [], {'P1': 0})
        self.assertEqual(kept, [dict(person, intro='')])
        self.assertEqual(withheld, [person])

    def test_rebuilding_journal_filters_old_graph_on_fresh_runner_without_cli_flag(self):
        r = self.runner()
        (r.root / 'kg.json').write_text(json.dumps({'log': [
            {'t': 'merge', 'p': 20, 'from': 'P2', 'into': 'P1', 'kind': 'dedupe'},
            {'t': 'imp', 'p': 20, 'id': 'P1', 'imp': 3},
            {'t': 'attr', 'p': 20, 'id': 'P1', 'key': 'old', 'value': 'tainted', 'by': 'judge'}]}))
        (r.work / 'quality-retry.json').write_text(json.dumps({
            'state': 'rebuilding', 'first_segment': 0, 'input_sha256': r.input_sha256}))
        restarted = self.runner()
        self.assertEqual(restarted.prior_log, [])

    def test_explicit_quality_retry_archives_and_can_complete_from_preserved_extraction(self):
        r = self.runner()
        source = {'seg': 0, 'data': local(), 'model': 'fixture'}
        data = to_classic(source['data'], {})
        rec = {'seg': 0, 'mode': 'two-phase', 'data': data, 'link': {'decisions': {}},
               'timing': {'link': 0}, 'guard': {}}
        for path, value in {r.local_path(0): source, r.seg_path(0): rec,
                            r.recap_path(0): {'recap': 'old unchecked'}}.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps(value))
        original = r.local_path(0).read_bytes()
        r.repair_policy = {'quarantine_after': 0, 'blocked': ['work/recaps/0000.json'],
                           'pending': ['derived-context-review']}
        r.quality_pending = {'derived-context-review'}
        r.prepare_quality_retry()
        self.assertFalse(r.seg_path(0).exists())
        self.assertFalse(r.recap_path(0).exists())
        self.assertEqual(r.local_path(0).read_bytes(), original)
        transaction = json.loads((r.work / 'quality-retry.json').read_text())
        archived = r.root / transaction['archive']
        self.assertEqual(json.loads((archived / 'work/recaps/0000.json').read_text())['recap'], 'old unchecked')
        self.assertEqual(r.quality_pending, {'quality-rebuild'})
        # Repeated CLI flag after an interrupted child acknowledges the same
        # rebuild, preserving any new partial cache instead of rearchiving it.
        r.seg_path(0).write_text(json.dumps(rec))
        r.prepare_quality_retry()
        self.assertTrue(r.seg_path(0).exists())
        self.assertEqual(json.loads((r.work / 'quality-retry.json').read_text())['archive'], transaction['archive'])
        r.seg_path(0).unlink()
        with patch.object(r, '_local_job', return_value=source), patch.object(r, 'link', return_value=rec), \
                patch.object(r, '_maybe_recap'):
            r.run2(concurrency=1, model='fixture')
        self.assertEqual(json.loads((r.root / 'status.json').read_text())['quality']['state'], 'verified')
        self.assertEqual(json.loads((r.work / 'quality-retry.json').read_text())['state'], 'complete')
        self.assertEqual(r.local_path(0).read_bytes(), original)

    def test_math_preserves_fraction_and_exponent(self):
        p = DocParser('fixture')
        p.feed('<p>Equation: <math><mfrac><msup><mi>x</mi><mn>2</mn></msup><mi>y</mi></mfrac></math>.</p>')
        p.close()
        self.assertIn('((x)^(2))/(y)', p.blocks[0]['t'])

    def test_svg_keeps_accessible_text_or_explicit_unavailable_marker(self):
        p = DocParser('fixture')
        p.feed('<p>Diagram <svg><title>Flow</title><text>A to B</text></svg> and <svg><path d="M0,0"/></svg>.</p>')
        p.close()
        self.assertIn('图形：Flow；A to B', p.blocks[0]['t'])
        self.assertIn('图形缺少可读取文本', p.blocks[0]['t'])

    def test_oversized_paragraph_is_refused_before_extraction(self):
        book = make_book(['Alice ' + 'x' * 12000])
        (self.root / 'book.json').write_text(json.dumps(book))
        with self.assertRaisesRegex(ValueError, '长段落'):
            Runner(self.root, 'fixture')

    def test_archive_rejected_before_member_read(self):
        path = self.root / 'book.epub'
        with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('oversized', 'x' * 100)
        with patch('pipeline.parse.MAX_EPUB_MEMBER_BYTES', 20), \
                patch.object(zipfile.ZipFile, 'read', side_effect=AssertionError('decompression')):
            with self.assertRaises(ValueError):
                parse_epub(path, self.root)

    def test_epub_detects_english_for_cost_and_extraction(self):
        path = self.root / 'english.epub'
        with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.writestr('META-INF/container.xml',
                             '<container><rootfiles><rootfile full-path="OPS/content.opf"/></rootfiles></container>')
            archive.writestr('OPS/content.opf',
                             '<package><metadata><title>English story</title></metadata>'
                             '<manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>'
                             '<spine><itemref idref="chapter"/></spine></package>')
            archive.writestr('OPS/chapter.xhtml',
                             '<html><body><p>' + 'Mr. Utterson met Dr. Jekyll at the door. ' * 50 +
                             '</p></body></html>')
        self.assertEqual(parse_epub(path, self.root)['lang'], 'en')

    def test_request_deadline_spans_stages_and_refuses_unaffordable_retry(self):
        now = [100.0]
        with patch.object(llm.time, 'monotonic', side_effect=lambda: now[0]), \
                patch.object(llm.time, 'sleep') as sleep:
            with llm.request_budget(5):
                self.assertEqual(llm._timeout(90), 5)
                now[0] += 4
                self.assertEqual(llm._timeout(90), 1)
                with self.assertRaises(llm.DeadlineExceeded):
                    llm._sleep(2)
                with llm.request_budget(99):
                    self.assertEqual(llm._timeout(90), 1)
            sleep.assert_not_called()
            self.assertEqual(llm._timeout(90), 90)

    def test_trickled_response_cannot_reset_request_deadline(self):
        now = [100.0]
        class Trickled:
            def __init__(self):
                self.reads = 0
            def read(self, size):
                self.reads += 1
                now[0] += .7
                return b'x'
            read1 = read
        response = Trickled()
        with patch.object(llm.time, 'monotonic', side_effect=lambda: now[0]):
            with llm.request_budget(2):
                with self.assertRaises(llm.DeadlineExceeded):
                    list(llm._chunks(response))
        self.assertEqual(response.reads, 3)

    def test_expired_request_does_not_contact_any_route(self):
        now = [100.0]
        with patch.object(llm.time, 'monotonic', side_effect=lambda: now[0]), \
                patch.object(llm, 'jev_free', side_effect=AssertionError('late request')):
            with llm.request_budget(2):
                now[0] += 3
                with self.assertRaises(llm.DeadlineExceeded):
                    llm.jev('state', {'q': {'criteria': {'a': 'A'}}})

    def test_free_context_limit_never_silently_changes_teacher_input(self):
        with patch.object(llm, '_free_breaker', llm._Breaker('fixture')):
            with self.assertRaises(llm.LLMError):
                llm.jev_free('x' * 31001, {'q': {'criteria': {'a': 'A'}}})

    def test_classic_guard_outage_reuses_raw_extraction(self):
        r = self.runner()
        data = to_classic(local(), {})
        data['profiles'] = [{'who': 'Na', 'tagline': 'A traveler', 'bio': 'Alice traveled.', 'para': 1}]
        with patch('pipeline.run.extract_segment', return_value=(data, {})) as extract, \
                patch('pipeline.run.guard_texts', side_effect=[llm.LLMError('outage'), {'Na': {'verdict': 'ok', 'p': .9}}]), \
                patch('pipeline.run.check_attrs', return_value={}), \
                patch('pipeline.run.resolve_mentions', return_value=({}, {})):
            with self.assertRaises(llm.LLMError):
                r.process(0)
            self.assertFalse(r.seg_path(0).exists())
            record = r.process(0)
        self.assertEqual(extract.call_count, 1)
        self.assertEqual(record['guard']['checks']['Na']['verdict'], 'ok')

    def test_classic_rejected_rewrite_is_withheld(self):
        r = self.runner()
        data = to_classic(local(), {})
        data['profiles'] = [{'who': 'Na', 'tagline': 'Invented', 'bio': 'Unsupported.', 'para': 1}]
        with patch('pipeline.run.extract_segment', return_value=(data, {})), \
                patch('pipeline.run.guard_texts', side_effect=[{'Na': {'verdict': 'flag', 'p': .1}}, {'Na': {'verdict': 'flag', 'p': .2}}]), \
                patch('pipeline.run.chat_json', return_value=({'tagline': 'Still unsupported', 'bio': 'Still unsupported.'}, {})), \
                patch('pipeline.run.check_attrs', return_value={}), \
                patch('pipeline.run.resolve_mentions', return_value=({}, {})):
            record = r.process(0)
        self.assertEqual(record['data']['profiles'], [])
        self.assertEqual(record['guard']['checks']['Na']['verdict'], 'withheld')

    def test_flagged_cache_needs_explicit_deterministic_fallback(self):
        record = {'recap': 'claim', 'guard': {'recap': {'verdict': 'flag'}}}
        self.assertFalse(Runner.verified_summary(record, 'recap'))
        record.update(recap_flagged='original', fallback_kind='verified-input-excerpt')
        self.assertTrue(Runner.verified_summary(record, 'recap'))


if __name__ == '__main__':
    unittest.main()
