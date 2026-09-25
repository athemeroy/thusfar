"""Reproduce completion-order effects at the finalization boundary."""

import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
from concurrent.futures import Future

from pipeline.parse import finish
from pipeline.run import Runner


class FinalizationOrderTests(unittest.TestCase):
    def _published_order(self, first: str) -> list[dict]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            book = finish([{'k': 'p', 't': 'Alice met Bob.'}], [(0, 'Chapter', 0)], {}, 'fixture', '')
            book.update(classified=True, genre='novel')
            book['chapters'][0].update(kind='body', spoil=False)
            (root / 'book.json').write_text(json.dumps(book), encoding='utf-8')
            with patch.dict(os.environ, {'JUDGE_LOG_DIR': str(root / 'judge')}):
                runner = Runner(root, 'fixture')
            runner.kg.people['P1'] = {'name': 'Alice', 'profile_p': -1}
            position = runner.segs[0]['o1']
            started = {name: threading.Event() for name in ('bio', 'recap')}
            release = {name: threading.Event() for name in ('bio', 'recap')}

            def bio(*_args):
                started['bio'].set()
                if not release['bio'].wait(5):
                    raise TimeoutError('bio was not released')
                runner._apply_bios({'bios': {'P1': {'bio': 'Alice biography',
                                                    'chk': {'verdict': 'ok'}}}}, position)

            def recap(*_args):
                started['recap'].set()
                if not release['recap'].wait(5):
                    raise TimeoutError('recap was not released')
                with runner.lock:
                    runner.kg.add_recap(0, position, 'Chapter recap', '')

            try:
                with patch.object(runner, '_bio_job', side_effect=bio), \
                     patch.object(runner, '_chapter_recap_job', side_effect=recap):
                    futures = {
                        'bio': runner.queue_final('bio', 0, [0, position], runner.pool),
                        'recap': runner.queue_final('recap', 0, [0, position], runner.recap_pool),
                    }
                    self.assertTrue(all(event.wait(5) for event in started.values()))
                    release[first].set()
                    futures[first].result(timeout=5)
                    second = 'recap' if first == 'bio' else 'bio'
                    release[second].set()
                    futures[second].result(timeout=5)
                runner.publish()
                return json.loads((root / 'kg.json').read_text(encoding='utf-8'))['log']
            finally:
                for event in release.values():
                    event.set()
                runner.close()

    def test_bio_and_recap_publish_in_logical_order(self):
        bio_first = self._published_order('bio')
        recap_first = self._published_order('recap')
        self.assertEqual(bio_first, recap_first)
        self.assertEqual([row['t'] for row in bio_first], ['profile', 'recap'])


class CrossChapterBarrierTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        book = finish([{'k': 'p', 't': 'Alice met Bob. ' * 12},
                       {'k': 'p', 't': 'Bob read a letter. ' * 12}],
                      [(0, 'First', 0), (1, 'Second', 0)], {}, 'fixture', '')
        book.update(classified=True, genre='novel')
        for chapter in book['chapters']:
            chapter.update(kind='body', spoil=False)
        (self.root / 'book.json').write_text(json.dumps(book), encoding='utf-8')
        with patch.dict(os.environ, {'JUDGE_LOG_DIR': str(self.root / 'judge')}):
            self.runner = Runner(self.root, 'fixture')
        self.addCleanup(self.runner.close)
        self.assertEqual([seg['chapter'] for seg in self.runner.segs], [0, 1])
        self.runner.kg.people['P1'] = {
            'id': 'P1', 'name': 'Alice', 'aliases': set(), 'weak': set(),
            'first': 0, 'mentions': 1, 'last_seg': 0, 'intro': 'original',
            'tagline': '', 'bio': '', 'profile_p': -1,
        }

    def _delayed_bio(self, gate: threading.Event, entered: threading.Event) -> None:
        def update():
            entered.set()
            if not gate.wait(5):
                raise TimeoutError('finalization was not released')
            self.runner._apply_bios({'bios': {'P1': {
                'tagline': 'new tagline', 'bio': 'new biography',
                'chk': {'verdict': 'ok'},
            }}}, self.runner.segs[0]['o1'])

        self.runner.pending.append(self.runner.pool.submit(update))

    def _drive(self, action):
        done = threading.Event()
        error = []

        def invoke():
            try:
                action()
            except BaseException as exc:
                error.append(exc)
            finally:
                done.set()

        thread = threading.Thread(target=invoke)
        thread.start()
        return thread, done, error

    def test_run2_holds_next_chapter_submission_until_finalization(self):
        runner = self.runner
        gate, entered = threading.Event(), threading.Event()
        submitted = []

        class LocalPool:
            def __init__(self, _workers):
                pass

            def submit(self, fn, i, model, hint, memory):
                submitted.append((i, hint, memory))
                future = Future()
                try:
                    future.set_result(fn(i, model, hint, memory))
                except BaseException as exc:
                    future.set_exception(exc)
                return future

            def shutdown(self, *args, **kwargs):
                pass

        record = {'link': {'decisions': {}}, 'timing': {'link': 0},
                  'data': {'events': [], 'rels': []}}

        def chapter_end(i):
            if i == 0:
                self._delayed_bio(gate, entered)

        with patch('pipeline.run.ThreadPoolExecutor', LocalPool), \
             patch.object(runner, 'mark_titles'), \
             patch.object(runner, '_local_job', return_value={'seconds': 0}), \
             patch.object(runner, 'link', return_value=record), \
             patch.object(runner, 'apply'), \
             patch.object(runner, '_maybe_recap', side_effect=chapter_end), \
             patch.object(runner, 'notify'), \
             patch.object(runner, 'finish_quality_retry'):
            thread, done, error = self._drive(lambda: runner.run2(concurrency=2, model='fixture'))
            try:
                self.assertTrue(entered.wait(5))
                self.assertEqual([i for i, _, _ in submitted], [0])
                self.assertFalse(done.wait(.05))
            finally:
                gate.set()
                thread.join(5)
            self.assertFalse(thread.is_alive())
            if error:
                raise error[0]
        self.assertEqual([i for i, _, _ in submitted], [0, 1])
        self.assertIn('new tagline', submitted[1][1])
        self.assertEqual(submitted[1][2]['people']['P1']['bio'], 'new biography')

    def test_classic_run_waits_before_next_process_reads_kg(self):
        runner = self.runner
        gate, entered = threading.Event(), threading.Event()
        processed = []
        record = {'data': {'new_people': [], 'events': [], 'rels': [], 'profiles': []},
                  'timing': {}, 'decisions': {}, 'guard': {}}

        def process(i):
            with runner.lock:
                processed.append((i, runner.cast_hint()))
            return record

        def chapter_end(i):
            if i == 0:
                self._delayed_bio(gate, entered)

        with patch.object(runner, 'process', side_effect=process), \
             patch.object(runner, 'apply'), \
             patch.object(runner, '_maybe_recap', side_effect=chapter_end), \
             patch.object(runner, 'finish_quality_retry'):
            thread, done, error = self._drive(runner.run)
            try:
                self.assertTrue(entered.wait(5))
                self.assertEqual([i for i, _ in processed], [0])
                self.assertFalse(done.wait(.05))
            finally:
                gate.set()
                thread.join(5)
            self.assertFalse(thread.is_alive())
            if error:
                raise error[0]
        self.assertEqual([i for i, _ in processed], [0, 1])
        self.assertIn('new tagline', processed[1][1])

    def test_classic_run_drains_resumed_jobs_before_processing(self):
        runner = self.runner
        gate, entered = threading.Event(), threading.Event()
        processed = []
        record = {'data': {'new_people': [], 'events': [], 'rels': [], 'profiles': []},
                  'timing': {}, 'decisions': {}, 'guard': {}}

        def process(i):
            processed.append((i, runner.cast_hint()))
            return record

        with patch.object(runner, 'resume_final_jobs',
                          side_effect=lambda: self._delayed_bio(gate, entered)), \
             patch.object(runner, 'process', side_effect=process), \
             patch.object(runner, 'apply'), \
             patch.object(runner, '_maybe_recap'), \
             patch.object(runner, 'finish_quality_retry'):
            thread, done, error = self._drive(lambda: runner.run(limit=1))
            try:
                self.assertTrue(entered.wait(5))
                self.assertEqual(processed, [])
                self.assertFalse(done.wait(.05))
            finally:
                gate.set()
                thread.join(5)
            self.assertFalse(thread.is_alive())
            if error:
                raise error[0]
        self.assertEqual([i for i, _ in processed], [0])
        self.assertIn('new tagline', processed[0][1])

    def test_run2_drains_resumed_jobs_before_local_submission(self):
        runner = self.runner
        gate, entered = threading.Event(), threading.Event()
        submitted = []
        record = {'link': {'decisions': {}}, 'timing': {'link': 0},
                  'data': {'events': [], 'rels': []}}

        def local(i, _model, hint, memory):
            submitted.append((i, hint, memory))
            return {'seconds': 0}

        with patch.object(runner, 'resume_final_jobs',
                          side_effect=lambda: self._delayed_bio(gate, entered)), \
             patch.object(runner, 'mark_titles'), \
             patch.object(runner, '_local_job', side_effect=local), \
             patch.object(runner, 'link', return_value=record), \
             patch.object(runner, 'apply'), \
             patch.object(runner, '_maybe_recap'), \
             patch.object(runner, 'notify'), \
             patch.object(runner, 'finish_quality_retry'):
            thread, done, error = self._drive(lambda: runner.run2(limit=1, concurrency=1, model='fixture'))
            try:
                self.assertTrue(entered.wait(5))
                self.assertEqual(submitted, [])
                self.assertFalse(done.wait(.05))
            finally:
                gate.set()
                thread.join(5)
            self.assertFalse(thread.is_alive())
            if error:
                raise error[0]
        self.assertEqual([i for i, _, _ in submitted], [0])
        self.assertIn('new tagline', submitted[0][1])
        self.assertEqual(submitted[0][2]['people']['P1']['bio'], 'new biography')


if __name__ == '__main__':
    unittest.main()
