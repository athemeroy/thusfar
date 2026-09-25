"""Android mode keeps explicit processing and private settings without a subprocess."""
import json
import os
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from pipeline.run import Cancelled, run_book
from server import app, jobs, storage
from test_server_repair import book_fixture


class ThreadWorker(unittest.TestCase):
    def test_manual_start_cancel_resume_and_lock_release(self):
        with tempfile.TemporaryDirectory() as temp:
            books = Path(temp)
            root = books / 'fixture'
            root.mkdir()
            storage.write_json(root / 'book.json', book_fixture())
            storage.write_json(root / 'meta.json', {'auto': False})
            storage.write_json(root / 'status.json', {'state': 'idle'})
            cache = storage.JsonCache()
            started = threading.Event()
            finished = threading.Event()
            calls = []

            def simulate_pipeline(directory, *, cancel_event, **_):
                calls.append(directory)
                if len(calls) == 1:
                    started.set()
                    if not cancel_event.wait(2):
                        raise AssertionError('worker did not deliver cancellation')
                    raise Cancelled()
                storage.write_json(directory / 'status.json', {'state': 'done'})
                finished.set()

            with patch.dict(os.environ, {'YEDU_WORKER_MODE': 'thread'}), \
                 patch('pipeline.run.run_book', side_effect=simulate_pipeline), \
                 patch.object(jobs.subprocess, 'Popen', side_effect=AssertionError('subprocess forbidden')):
                worker = jobs.Worker(books, books, cache.get, storage.write_json, enabled=False)
                worker.start()
                try:
                    worker.set_auto(root, True)
                    self.assertTrue(started.wait(2))
                    worker.cancel(root, timeout=2)
                    self.assertEqual(cache.get(root / 'status.json')['state'], 'paused')
                    self.assertFalse(cache.get(root / 'meta.json')['auto'])
                    with jobs.book_lease(root):
                        pass
                    worker.set_auto(root, True)
                    self.assertTrue(finished.wait(2))
                    deadline = time.monotonic() + 2
                    while worker.current is not None and time.monotonic() < deadline:
                        time.sleep(.01)
                    self.assertEqual(cache.get(root / 'status.json')['state'], 'done')
                    self.assertEqual(len(calls), 2)
                finally:
                    worker.stop()
                    worker.join(timeout=2)

    def test_pipeline_pre_cancel_releases_its_file_lock(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            cancelled = threading.Event()
            cancelled.set()
            with self.assertRaises(Cancelled):
                run_book(root, cancel_event=cancelled)
            with jobs.book_lease(root):
                pass


class PrivateSettings(unittest.TestCase):
    def test_cost_prompt_does_not_quote_a_paid_judge_or_unknown_model_price(self):
        from pipeline.models import estimate
        with patch.dict(os.environ, {'JEV_ROUTE': 'free-only', 'MODEL_PRICES': '{}'}):
            free = estimate(100_000, model='deepseek-flash+nothink')
            unknown = estimate(100_000, model='private-reader-model')
        with patch.dict(os.environ, {'JEV_ROUTE': 'paid', 'MODEL_PRICES': '{}'}):
            paid = estimate(100_000, model='deepseek-flash+nothink')
        self.assertLess(free['high'], paid['high'])
        self.assertIsNone(unknown['high'])

    def test_saved_model_is_used_by_questions_comments_and_new_pipeline_jobs(self):
        from pipeline import llm
        from server import ask, marginalia, model_settings
        with tempfile.TemporaryDirectory() as temp, \
             patch.dict(os.environ, {'SECRETS_FILE': str(Path(temp) / '.model.env'),
                                  'LLM_BASE_URL': '', 'LLM_API_KEY': '', 'LLM_KEY_MAP': '',
                                  'LLM_KEY_NAME': ''}), \
             patch.object(ask, 'QA_MODEL', ask.QA_MODEL), \
             patch.object(marginalia, 'MODEL', marginalia.MODEL), \
             patch.object(marginalia, 'AUTO_MODEL', marginalia.AUTO_MODEL):
            try:
                model_settings.save({'base_url': 'https://models.example/v1',
                                     'model': 'reader-model', 'api_key': 'temporary-example-key',
                                     'jev_route': 'free-only'})
                self.assertEqual(llm.base_for('openai'), 'https://models.example/v1')
                self.assertEqual(llm.key_for('reader-model'), 'temporary-example-key')
                self.assertEqual(ask.QA_MODEL, 'reader-model')
                self.assertEqual(marginalia.MODEL, 'reader-model')
                self.assertEqual(marginalia.AUTO_MODEL, 'reader-model')
                self.assertEqual(os.environ['CLASSIFY_MODEL'], 'reader-model')
            finally:
                with llm._env_lock:
                    llm._env_cache = None

    def test_key_is_private_and_never_returned_by_api(self):
        from test_server_repair import HTTPRepair
        case = HTTPRepair(methodName='runTest')
        case.setUp()
        try:
            path = case.root / '.model.env'
            with patch.dict(os.environ, {'SECRETS_FILE': str(path)}), patch.object(app, 'LOCAL_MODE', True):
                code, _, raw = case.request('PUT', '/api/settings', {
                    'base_url': 'https://api.deepseek.com/v1', 'model': 'deepseek-flash+nothink',
                    'api_key': 'sk-private-example-4321', 'jev_route': 'free-only'})
                self.assertEqual(code, 200)
                self.assertNotIn(b'sk-private-example', raw)
                self.assertEqual(json.loads(raw)['api_key_last4'], '4321')
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
                code, _, raw = case.request('GET', '/api/settings')
                self.assertEqual(code, 200)
                self.assertNotIn(b'sk-private-example', raw)
                self.assertNotIn('api_key', json.loads(raw))
        finally:
            case.doCleanups()


    def test_processing_without_a_key_is_refused_with_the_reason(self):
        from test_server_repair import HTTPRepair
        case = HTTPRepair(methodName='runTest')
        case.setUp()
        try:
            with patch.dict(os.environ, {'SECRETS_FILE': str(case.root / '.model.env')}), \
                 patch.object(app, 'LOCAL_MODE', True):
                bid = case.make_book(state='idle').name
                code, _, raw = case.request('POST', f'/api/books/{bid}/process')
                self.assertEqual(code, 409)
                self.assertIn('API 密钥', json.loads(raw)['error'])
                self.assertNotEqual((app.cached_json(app.BOOKS / bid / 'status.json') or {}).get('state'), 'queued')
        finally:
            case.doCleanups()


class ModelFailures(unittest.TestCase):
    def test_hopeless_failures_are_explained_and_transient_ones_are_not(self):
        from pipeline.llm import LLMError, explain
        self.assertIn('模型设置', explain(LLMError('缺少模型访问密钥')))
        self.assertIn('HTTP 401', explain(LLMError('HTTP 401: {"error":{"message":"Authentication Fails"}}')))
        self.assertIn('Authentication Fails', explain(LLMError('HTTP 401: {"error":{"message":"Authentication Fails"}}')))
        self.assertIn('余额', explain(LLMError('HTTP 402: {"error":{"message":"Insufficient Balance"}}')))
        self.assertIn('模型名', explain(LLMError('HTTP 400: Model Not Exist')))
        self.assertIsNone(explain(LLMError('HTTP 503: busy')))
        self.assertIsNone(explain(TimeoutError('timed out')))


if __name__ == '__main__':
    unittest.main()
