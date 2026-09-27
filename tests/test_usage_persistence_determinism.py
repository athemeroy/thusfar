"""Settled usage must not depend on the last model/biography guard finishing first."""
import json
import os
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from pipeline import run
from pipeline.parse import finish


class UsagePersistenceDeterminismTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        book = finish([{'k': 'p', 't': 'Alice met Bob.'}], [(0, 'Chapter', 0)], {},
                      'Usage fixture', '')
        book.update(classified=True, genre='novel')
        book['chapters'][0].update(kind='body', spoil=False)
        (self.root / 'book.json').write_text(json.dumps(book), encoding='utf-8')
        network = patch('pipeline.llm._opener', side_effect=AssertionError('network forbidden'))
        network.start()
        self.addCleanup(network.stop)
        environment = patch.dict(os.environ, {'JUDGE_LOG_DIR': str(self.root / 'judge')})
        environment.start()
        self.addCleanup(environment.stop)
        stats = patch.dict(run.JEV_STATS, {'calls': 4, 'chars': 40, 'questions': 4,
                                         'paid_chars': 0, 'passage_chars': 30}, clear=True)
        stats.start()
        self.addCleanup(stats.stop)

    def runner(self):
        runner = run.Runner(self.root, 'fixture')
        self.addCleanup(runner.close)
        return runner

    def test_done_boundary_keeps_guard_increment_after_last_model_write(self):
        outputs = []
        for model_first in (True, False):
            with self.subTest(model_first=model_first):
                usage_path = self.root / 'work/usage.json'
                usage_path.unlink(missing_ok=True)
                runner = self.runner()
                entered, release = threading.Event(), threading.Event()

                def guard(*_args):
                    entered.set()
                    if not release.wait(5):
                        raise TimeoutError('biography guard was not released')
                    return {'P1': {'verdict': 'ok', 'p': 1.0}}

                try:
                    with patch.object(runner, 'cached_generation', return_value={
                            'P1': {'bio': 'A person in the fixture.'}}), \
                            patch('pipeline.run.guard_texts', side_effect=guard):
                        future = runner.pool.submit(runner._bio_job, 0,
                                                    runner.segs[0]['o1'], 'fixture dossier', ['P1'])
                        self.assertTrue(entered.wait(5))
                        if not model_first:
                            release.set()
                            future.result(timeout=5)
                        with runner.lock:
                            runner.count('fixture', {'prompt_tokens': 5, 'completion_tokens': 7})
                        before_boundary = json.loads(usage_path.read_text())
                        self.assertEqual(before_boundary['jev_calls'], 0 if model_first else 1)
                        release.set()
                        future.result(timeout=5)
                    # The real finalization barrier has now settled both operations.
                    runner.status('done', 1)
                    usage = json.loads(usage_path.read_text())
                    status = json.loads((self.root / 'status.json').read_text())
                    outputs.append(usage)
                    self.assertEqual(usage, status['usage'])
                    self.assertEqual(usage['jev_calls'], 1)
                    self.assertEqual((usage['prompt'], usage['completion'], usage['llm_calls']),
                                     (5, 7, 1))
                finally:
                    release.set()
                    runner.close()
        self.assertEqual(outputs[0], outputs[1])

    def test_partial_boundary_is_restorable_without_recounting_paid_usage(self):
        runner = self.runner()
        with runner.lock:
            runner.count('fixture', {'prompt_tokens': 11, 'completion_tokens': 13})
            runner.usage['jev_calls'] += 2
        runner.status('running', 0)
        stored = json.loads(runner.usage_path.read_text())
        self.assertEqual(stored['jev_calls'], 2)
        self.assertEqual(stored, json.loads((self.root / 'status.json').read_text())['usage'])
        runner.close()
        restored = self.runner()
        self.assertEqual(restored.usage, stored)
        self.assertEqual(restored.usage['by_model']['fixture'],
                         {'calls': 1, 'prompt': 11, 'completion': 13})


if __name__ == '__main__':
    unittest.main()
