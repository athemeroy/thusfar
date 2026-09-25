"""Oracle credential, budget and paid-work reconciliation regressions."""
from __future__ import annotations

import base64
import json
import os
import tempfile
import types
import unittest
import urllib.request
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

from oracle.record.cassettes import CassetteStore, install, request_envelope
from oracle.record.common import UnsafeValue, canonical, encode, known_secrets, require_reference_runtime
from oracle.record.functions import LoopbackOnly
from oracle.record.scan import scan
from oracle.record.workload import prepare_working_book

_MODEL_ENV = ('EXTRACT_MODEL', 'LOCAL_MODEL', 'RECAP_MODEL', 'JUDGE_MODEL', 'CLASSIFY_MODEL')


def model_envelope(max_tokens: int = 16) -> dict:
    return {'method': 'POST', 'url': 'https://open.xiaojingai.com/v1/chat/completions',
            'headers': {'content-type': 'application/json'},
            'body_utf8': json.dumps({'model': 'deepseek-flash',
                                     'thinking': {'type': 'disabled'},
                                     'max_tokens': max_tokens,
                                     'messages': [{'role': 'user', 'content': 'oracle fixture'}]})}


def response(text: str, usage: bool = False) -> dict:
    body = ('data: ' + json.dumps({'usage': {'prompt_tokens': 100, 'completion_tokens': 20}}) + '\n\n'
            if usage else text)
    return {'kind': 'response', 'status': 200, 'headers': {'content-type': 'text/event-stream'},
            'chunks_base64': [base64.b64encode(body.encode()).decode()]}


class OracleRecordSafety(unittest.TestCase):
    def test_synthetic_stream_http_error_and_free_jev_replay_offline(self):
        from pipeline import llm
        cassettes = Path(__file__).resolve().parents[1] / 'oracle/cassettes/synthetic'
        previous_classifier = llm.CLASSIFIER_URL
        try:
            with patch.dict(os.environ, {'LLM_BASE_URL_OPENAI': 'https://open.xiaojingai.com/v1',
                                         'ORACLE_REPLAY_KEY': 'oracle-placeholder'}):
                llm.CLASSIFIER_URL = 'https://classifier.dev/v1/classify'
                with LoopbackOnly(), install(cassettes, 'replay') as tape:
                    def fixture(name):
                        return llm.chat('deepseek-flash+nothink',
                                        [{'role': 'user', 'content': 'oracle fixture: ' + name}],
                                        max_tokens=16, temperature=0, retries=0,
                                        key_name='ORACLE_REPLAY_KEY')

                    self.assertEqual(fixture('split-stream')[0], '可以')
                    with self.assertRaisesRegex(llm.LLMError, 'HTTP 401'):
                        fixture('http-401')
                    state = {'passage': '𠮷😀 asked a question.'}
                    questions = {'q1': {'type': 'choice', 'instructions': 'Is this supported?',
                                        'criteria': {'yes': 'Supported', 'no': 'Not supported'}}}
                    answers = llm.jev_free(state, questions, retries=0)
                    self.assertEqual(answers['q1']['choice'], 'yes')
                    self.assertEqual(tape.count, 3)
        finally:
            llm.CLASSIFIER_URL = previous_classifier

    def test_replay_overrides_and_restores_hostile_model_environment(self):
        from oracle.record import artifacts, functions
        from pipeline import run
        original_recap = run.RECAP_MODEL

        @contextmanager
        def fake_install(*_args, **_kwargs):
            yield types.SimpleNamespace(count=1)

        seen = []

        def fake_run_book(_path, **kwargs):
            seen.append({name: os.environ[name] for name in _MODEL_ENV})
            self.assertEqual(kwargs['model'], 'deepseek-flash+nothink')
            self.assertEqual(kwargs['local_model'], 'deepseek-flash+nothink')

        hostile = {name: 'hostile-model' for name in _MODEL_ENV}
        with tempfile.TemporaryDirectory(prefix='thusfar-replay-env-test-') as tmp:
            source = Path(tmp) / 'source'
            source.mkdir()
            (source / 'book.json').write_text('{}')
            book = Path(tmp) / 'one-pass'
            with patch.dict(os.environ, hostile), \
                    patch('pipeline.run.run_book', fake_run_book), \
                    patch('oracle.record.cassettes.install', fake_install), \
                    patch('oracle.record.artifacts.install', fake_install):
                functions.run_book_replay(source, Path(tmp) / 'tapes', 'fresh', 1)
                book.mkdir()
                artifacts.one_pass(book, Path(tmp) / 'tapes', 1)
                self.assertEqual({name: os.environ[name] for name in _MODEL_ENV}, hostile)
                self.assertEqual(run.RECAP_MODEL, original_recap)
        self.assertEqual(len(seen), 2)
        self.assertTrue(all(all(value == 'deepseek-flash+nothink' for value in row.values())
                            for row in seen))

    def test_reference_runtime_requires_python_311_and_unicode_14(self):
        require_reference_runtime()
        with patch('oracle.record.common.sys', types.SimpleNamespace(version_info=(3, 13))):
            with self.assertRaisesRegex(RuntimeError, 'Python 3.11'):
                require_reference_runtime()
        with patch('oracle.record.common.unicodedata',
                   types.SimpleNamespace(unidata_version='15.0.0')):
            with self.assertRaisesRegex(RuntimeError, 'Unicode 14.0.0'):
                require_reference_runtime()

    def test_nas_default_key_is_screened_from_headers_and_decoded_chunks(self):
        fake = 'ORACLE_TEST_ONLY_987654321'
        with patch.dict(os.environ, {'NAS_DEFAULT_KEY': fake}):
            secrets = known_secrets()
            self.assertIn(fake, secrets)
            request = urllib.request.Request(
                'https://open.xiaojingai.com/v1/chat/completions',
                data=b'{}', method='POST',
                headers={'Authorization': 'Bearer ' + fake, 'Content-Type': 'application/json'})
            envelope = request_envelope(request, secrets)
            self.assertNotIn(fake, canonical(envelope))
            self.assertNotIn('authorization', canonical(envelope).lower())
            with tempfile.TemporaryDirectory(prefix='thusfar-secret-test-') as tmp:
                path = Path(tmp) / 'cassette.json'
                path.write_text(json.dumps({'chunks_base64': [base64.b64encode(fake.encode()).decode()]}))
                with self.assertRaises(UnsafeValue):
                    scan(Path(tmp))
            with self.assertRaises(UnsafeValue):
                encode(b'prefix:' + fake.encode() + b':suffix', secrets)

    def test_peak_rate_ledger_is_cumulative_across_store_restarts(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-budget-test-') as tmp:
            directory = Path(tmp)
            envelope = model_envelope(max_tokens=9000)
            store = CassetteStore(directory, 'record', secrets=(), max_cny=.1)
            reservation, slot = store.reserve_live('model', envelope)
            self.assertGreater(store.budget_summary()['charged_cny'], .08)
            attempt = response('ignored', usage=True)
            store.append(envelope, attempt, slot)
            store.settle_live(reservation, attempt)
            summary = store.budget_summary()
            self.assertEqual(summary['charged_cny'], 2 * summary['configured_rate_estimate_cny'])
            restarted = CassetteStore(directory, 'record', secrets=(), max_cny=.1)
            reservation, slot = restarted.reserve_live('model', envelope)
            failure = {'kind': 'error', 'error': {'type': 'TimeoutError', 'message': 'fixture'}}
            restarted.append(envelope, failure, slot)
            restarted.settle_live(reservation, failure)
            with self.assertRaisesRegex(RuntimeError, 'budget'):
                restarted.reserve_live('model', envelope)
            self.assertEqual(restarted.budget_summary()['usage_unavailable'], 1)

    def test_reversed_completion_keeps_slots_and_rejects_ambiguous_replay(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-order-test-') as tmp:
            directory = Path(tmp)
            envelope = model_envelope()
            store = CassetteStore(directory, 'record', secrets=(), max_cny=.1)
            first_reservation, first_slot = store.reserve_live('model', envelope)
            second_reservation, second_slot = store.reserve_live('model', envelope)
            self.assertEqual((first_slot, second_slot), (0, 1))
            second, first = response('second'), response('first')
            store.append(envelope, second, second_slot)
            store.settle_live(second_reservation, second)
            store.append(envelope, first, first_slot)
            store.settle_live(first_reservation, first)
            tape = json.loads(store.path(envelope).read_text())
            self.assertEqual(tape['attempts'], [first, second])
            with self.assertRaisesRegex(RuntimeError, 'ambiguous'):
                CassetteStore(directory, 'replay', secrets=()).next(envelope)
            with self.assertRaises(UnsafeValue):
                scan(directory)

    def test_sequential_503_then_success_replays_in_order(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-retry-test-') as tmp:
            directory = Path(tmp)
            envelope = model_envelope()
            store = CassetteStore(directory, 'record', secrets=(), max_cny=.1)
            reservation, slot = store.reserve_live('model', envelope)
            failure = {'kind': 'http_error', 'status': 503, 'reason': 'fixture',
                       'headers': {'content-type': 'application/json'},
                       'body_base64': base64.b64encode(b'{}').decode()}
            store.append(envelope, failure, slot)
            store.settle_live(reservation, failure)
            reservation, slot = store.reserve_live('model', envelope)
            success = response('data: {"choices":[{"delta":{"content":"ok"}}]}\n\n')
            store.append(envelope, success, slot)
            store.settle_live(reservation, success)
            self.assertEqual(json.loads(store.path(envelope).read_text())['overlap_groups'], [])
            replay = CassetteStore(directory, 'replay', secrets=())
            self.assertEqual(replay.next(envelope), failure)
            self.assertEqual(replay.next(envelope), success)
            self.assertEqual(scan(directory), 2)

    def test_separate_concurrent_groups_may_have_sequentially_different_replies(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-groups-test-') as tmp:
            directory = Path(tmp)
            envelope = model_envelope()
            store = CassetteStore(directory, 'record', secrets=(), max_cny=.1)
            for label in ('first', 'second'):
                left_reservation, left_slot = store.reserve_live('model', envelope)
                right_reservation, right_slot = store.reserve_live('model', envelope)
                reply = response(label)
                store.append(envelope, reply, right_slot)
                store.settle_live(right_reservation, reply)
                store.append(envelope, reply, left_slot)
                store.settle_live(left_reservation, reply)
            tape = json.loads(store.path(envelope).read_text())
            self.assertEqual(tape['overlap_groups'], [[0, 1], [2, 3]])
            replay = CassetteStore(directory, 'replay', secrets=())
            self.assertEqual([replay.next(envelope) for _ in range(4)],
                             [response('first'), response('first'),
                              response('second'), response('second')])
            self.assertEqual(scan(directory), 2)

    def test_resume_uses_original_source_and_rejects_pending_attempt(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-resume-test-') as tmp:
            root = Path(tmp)
            source = root / 'source'
            source.mkdir()
            (source / 'book.json').write_text('{"title":"fixture"}')
            (source / 'source.txt').write_text('original')
            working, cassettes = root / 'working', root / 'cassettes'
            prepare_working_book(source, working, cassettes, 'fresh', False)
            prepare_working_book(source, working, cassettes, 'fresh', True)
            cassettes.mkdir()
            (cassettes / 'pending.json').write_text(json.dumps({
                'request_sha256': 'fixture', 'attempts': [{'kind': 'pending'}]}))
            with self.assertRaises(UnsafeValue):
                prepare_working_book(source, working, cassettes, 'fresh', True)
            (cassettes / 'pending.json').unlink()
            (source / 'source.txt').write_text('changed')
            with self.assertRaisesRegex(ValueError, 'differs'):
                prepare_working_book(source, working, cassettes, 'fresh', True)


if __name__ == '__main__':
    unittest.main()
