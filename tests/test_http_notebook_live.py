"""Offline contracts for the opt-in real notebook HTTP recorder; no provider calls."""
from __future__ import annotations

import base64
import copy
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.request
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

from oracle.record.cassettes import CassetteStore, request_envelope
from oracle.record.common import UnsafeValue, canonical, digest, write_json
from oracle.record.functions import LoopbackOnly
from oracle.record import http_notebook_live as notebook

ROOT = Path(__file__).resolve().parents[1]
PYTHON = sys.executable
FAKE_KEY = 'ORACLE_NOTEBOOK_FAKE_KEY_123456789'
ASK_TEXT = '赵太爷打了阿Q一个嘴巴。'
COMMENT = '赵太爷这一下也太蛮横了，阿Q都没来得及躲。'


def _synthetic_rows(route: str) -> list[dict]:
    source = [json.loads(line) for line in
              (ROOT / 'oracle/goldens/http/aq_model_synthetic.jsonl').read_text().splitlines()]
    indices = {'who': (0,), 'ask': (1,), 'marginalia': (2, 3)}[route]
    result = [copy.deepcopy(source[index]) for index in indices]
    case = notebook.CASES[route]
    for index, row in enumerate(result):
        row['route'] = case['id'] + ('-cached' if index else '')
        row['request'] = {'method': 'POST', 'path': case['path'],
                          'headers': {'Content-Type': 'application/json'},
                          'body_json': case['body']}
        row['transport'] = {'http_version': 'HTTP/1.1'}
    return result


def _outbound(route: str) -> list[dict]:
    kinds = {'who': ('jev',), 'marginalia': ('model', 'jev'),
             'ask': ('jev', 'jev', 'model', 'jev')}[route]
    return [{'sha256': f'{index + 1:064x}', 'kind': kind}
            for index, kind in enumerate(kinds)]


class _MemoryReply(io.BytesIO):
    def __init__(self, data: bytes, content_type: str):
        super().__init__(data)
        self.headers = {'Content-Type': content_type}
        self.status = 200


class _FixtureOpener:
    """Synthetic in-memory replies; it persists keyless tapes for a later real replay."""

    def __init__(self, store: CassetteStore, attempts: dict):
        self.store, self.attempts = store, attempts

    def open(self, request, timeout=None):
        envelope = request_envelope(request, (FAKE_KEY,))
        kind = notebook.live_request_allowed(envelope, request)
        body = json.loads(envelope['body_utf8'])
        if kind == 'jev':
            dimensions = {}
            for name, question in body['dimensions'].items():
                labels = question['labels']
                if 'P2' in labels:
                    choice = 'P2'
                elif 'recap' in labels:
                    choice = 'recap'
                elif 'answers' in labels:
                    choice = 'answers'
                elif 'supported' in labels:
                    choice = 'supported'
                else:
                    raise AssertionError('synthetic fixture received an unreviewed JEV dimension')
                dimensions[name] = {'label': choice, 'confidence': .96,
                                    'scores': {label: (.96 if label == choice else .01)
                                               for label in labels}}
            raw = canonical({'results': [{'dimensions': dimensions}]}).encode('utf-8')
            content_type = 'application/json'
        else:
            cap = body['max_tokens']
            text = COMMENT if cap == 160 else ASK_TEXT if cap == 1200 else None
            if text is None:
                raise AssertionError('synthetic fixture received an unreviewed model cap')
            raw = (b'data: ' + canonical({'choices': [{'delta': {'content': text}}]}).encode()
                   + b'\n\ndata: ' + canonical({'choices': [], 'usage': {
                       'prompt_tokens': 30, 'completion_tokens': 15}}).encode()
                   + b'\n\ndata: [DONE]\n\n')
            content_type = 'text/event-stream'
        sha = digest(envelope)
        self.attempts.setdefault(sha, (envelope, []))[1].append(
            {'kind': 'response', 'status': 200, 'headers': {'Content-Type': content_type},
             'chunks_base64': [base64.b64encode(raw).decode('ascii')]})
        self.store.count += 1
        return _MemoryReply(raw, content_type)


def build_offline_fixture(route: str, directory: Path) -> None:
    """Run the real handler with a synthetic opener, then write replay-only tapes."""
    tapes = directory / 'cassettes'
    tapes.mkdir()
    store = CassetteStore(tapes, 'record', secrets=(FAKE_KEY,),
                          max_model_attempts=notebook.CASES[route]['model_cap'],
                          max_jev_attempts=notebook.CASES[route]['jev_cap'])
    attempts = {}

    @contextmanager
    def fake_install(_directory, _mode, **_kwargs):
        from pipeline import llm
        previous = llm._opener
        llm._opener = lambda: _FixtureOpener(store, attempts)
        try:
            yield store
        finally:
            llm._opener = previous

    with patch.object(notebook, 'install', fake_install), LoopbackOnly():
        observed = []
        rows, outbound, first_count, count, work_hashes = notebook.exercise(
            route, 'record', tapes, FAKE_KEY, directory / 'work',
            on_observation=observed.append)
    assert observed == rows
    notebook.assert_success(route, rows, outbound, first_count, count, (FAKE_KEY,))
    for sha, (envelope, replies) in attempts.items():
        write_json(tapes / (sha + '.json'), {'schema': 1, 'request_sha256': sha,
                                            'request': envelope, 'attempts': replies,
                                            'overlap_groups': []})
    write_json(directory / 'expected.json', {'rows': rows, 'outbound': outbound,
                                              'work_hashes': work_hashes})


def probe_timeout_teardown(directory: Path) -> None:
    """A disconnected client cannot outlive the reviewed provider transport."""
    tapes = directory / 'cassettes'
    tapes.mkdir()
    store = CassetteStore(tapes, 'record', secrets=(FAKE_KEY,),
                          max_model_attempts=0, max_jev_attempts=2)
    entered, released, finished = threading.Event(), threading.Event(), threading.Event()
    gate_states = []
    attempts = {}

    @contextmanager
    def fake_install(_directory, _mode, **_kwargs):
        from pipeline import llm
        previous = llm._opener
        llm._opener = lambda: _FixtureOpener(store, attempts)
        try:
            yield store
        finally:
            llm._opener = previous

    def timeout_send(connection, case, _case_id, _secrets):
        from pipeline import llm
        from server import app
        original = app.Handler.do_POST

        def delayed(handler):
            entered.set()
            try:
                if not released.wait(3):
                    raise AssertionError('test handler was not released')
                gate_states.append(isinstance(llm._opener(), notebook.ReviewedOpener))
                return original(handler)
            finally:
                finished.set()

        app.Handler.do_POST = delayed
        connection.timeout = .03
        connection.request('POST', case['path'], body=canonical(case['body']).encode(),
                           headers={'Content-Type': 'application/json'})
        if not entered.wait(2):
            raise AssertionError('test handler did not start')
        try:
            connection.getresponse()
        finally:
            threading.Timer(.1, released.set).start()

    with patch.object(notebook, 'install', fake_install), \
            patch.object(notebook, '_send', timeout_send), LoopbackOnly():
        try:
            try:
                notebook.exercise('who', 'record', tapes, FAKE_KEY, directory / 'work')
            except TimeoutError:
                pass
            else:
                raise AssertionError('client timeout was not observed')
        finally:
            released.set()
            if not finished.wait(3):
                raise AssertionError('late HTTP handler did not finish')
    if gate_states != [True] or store.count != 1:
        raise AssertionError('late provider call escaped the reviewed cassette opener')


class NotebookLiveOfflineTests(unittest.TestCase):
    def test_fixed_aq_inputs_and_source_are_verified(self):
        self.assertEqual(len(notebook.source_hashes()), 48)
        self.assertEqual(notebook.CASES['who']['body'],
                         {'pos': 900, 'start': 751, 'end': 753})
        self.assertEqual(notebook.CASES['marginalia']['body'],
                         {'mode': 'manual', 'pos': 900, 'start': 820, 'end': 847,
                          'persona': 'empathy'})
        self.assertEqual(notebook.CASES['ask']['body'],
                         {'q': notebook.ASK_QUESTION, 'pos': 900})

    def test_success_contracts_reject_application_failure_and_cache_masking(self):
        for route in notebook.CASES:
            with self.subTest(route=route):
                rows, outbound = _synthetic_rows(route), _outbound(route)
                notebook.assert_success(route, rows, outbound, len(outbound), len(outbound), ())
                bad = copy.deepcopy(rows)
                if route == 'who':
                    bad[0]['response']['body_json']['ok'] = False
                elif route == 'marginalia':
                    bad[0]['response']['body_json']['cached'] = True
                else:
                    bad[0]['response']['body_base64'] = base64.b64encode(
                        b'event: error\ndata: {"message":"failed"}\n\n').decode('ascii')
                with self.assertRaises(ValueError):
                    notebook.assert_success(route, bad, outbound,
                                            len(outbound), len(outbound), ())
                if route == 'marginalia':
                    empty = copy.deepcopy(rows)
                    empty[0]['response']['body_json']['comment'] = ''
                    with self.assertRaises(ValueError):
                        notebook.assert_success(route, empty, outbound,
                                                len(outbound), len(outbound), ())
                elif route == 'ask':
                    wrong = copy.deepcopy(rows)
                    payload = base64.b64decode(wrong[0]['response']['body_base64']).decode()
                    wrong[0]['response']['body_base64'] = base64.b64encode(
                        payload.replace('"recap"', '"bogus"').encode()).decode('ascii')
                    with self.assertRaises(ValueError):
                        notebook.assert_success(route, wrong, outbound,
                                                len(outbound), len(outbound), ())
                    legitimate = copy.deepcopy(rows)
                    legitimate[0]['response']['body_base64'] = base64.b64encode(
                        payload.replace('"recap"', '"other"').encode()).decode('ascii')
                    notebook.assert_success(route, legitimate, outbound,
                                            len(outbound), len(outbound), ())
        rows, outbound = _synthetic_rows('marginalia'), _outbound('marginalia')
        with self.assertRaisesRegex(ValueError, 'cached marginalia'):
            notebook.assert_success('marginalia', rows, outbound,
                                    len(outbound) - 1, len(outbound), ())

    def test_outbound_gate_rejects_wrong_model_and_existing_paid_digest(self):
        class NoNetwork:
            def open(self, *_args, **_kwargs):
                return object()

        with tempfile.TemporaryDirectory(prefix='thusfar-notebook-gate-') as temp:
            directory = Path(temp)
            store = CassetteStore(directory, 'record', secrets=(FAKE_KEY,))
            seen = []
            gate = notebook.ReviewedOpener(NoNetwork(), store, 'record', 'marginalia',
                                           seen, directory / 'outbound.jsonl', (FAKE_KEY,),
                                           __import__('threading').Lock())
            from pipeline import llm
            with patch.dict(os.environ, {'LLM_BASE_URL': notebook.BASE_URL,
                                         'LLM_BASE_URL_OPENAI': notebook.BASE_URL}):
                request = llm._request('openai', 'deepseek-flash',
                                       [{'role': 'user', 'content': notebook.QUOTE}],
                                       FAKE_KEY, 160, .65, 'nothink')
                envelope = request_envelope(request, (FAKE_KEY,))
                store.path(envelope).write_text('{}', encoding='utf-8')
                with self.assertRaisesRegex(FileExistsError, 'already has a cassette'):
                    gate.open(request)
                self.assertFalse(seen)
                store.path(envelope).unlink()
                wrong = llm._request('openai', 'deepseek-flash',
                                     [{'role': 'user', 'content': notebook.QUOTE}],
                                     FAKE_KEY, 1200, .65, 'nothink')
                with self.assertRaisesRegex(ValueError, 'unreviewed model prompt'):
                    gate.open(wrong)
                self.assertFalse(seen)
                gate.open(request)
                self.assertEqual(seen, [{'sha256': digest(envelope), 'kind': 'model'}])
                self.assertEqual(notebook._outbound_rows(directory), seen)

    def test_masked_key_tail_is_rejected_inside_sse_base64(self):
        row = _synthetic_rows('ask')[0]
        row['response']['body_base64'] = base64.b64encode(
            b'event: stage\ndata: {"text":"hidden-6789"}\n\n').decode('ascii')
        with self.assertRaisesRegex(UnsafeValue, 'credential suffix'):
            notebook._assert_no_key_tail_in_row(row, FAKE_KEY)

    def test_all_three_handlers_replay_synthetic_tapes_in_two_fresh_processes(self):
        for route in notebook.CASES:
            with self.subTest(route=route), tempfile.TemporaryDirectory(
                    prefix='thusfar-notebook-fixture-') as temp:
                directory = Path(temp)
                fixture = subprocess.run(
                    [PYTHON, '-c',
                     'from pathlib import Path; import sys; '
                     'from tests.test_http_notebook_live import build_offline_fixture; '
                     'build_offline_fixture(sys.argv[1], Path(sys.argv[2]))',
                     route, str(directory)], cwd=ROOT, capture_output=True, text=True)
                self.assertEqual(fixture.returncode, 0, fixture.stderr)
                expected = json.loads((directory / 'expected.json').read_text())
                results = []
                for seed in ('1', '2'):
                    source = directory / ('source-' + seed) / notebook.BOOK_ID
                    shutil.copytree(notebook.SOURCE, source)
                    stamp = source / 'book.json'
                    os.utime(stamp, ns=(1_600_000_000_000_000_000,
                                        1_600_000_000_000_000_000 + int(seed) * 1_000_000_000))
                    script = ('from pathlib import Path; import sys; '
                              'from oracle.record import http_notebook_live as notebook; '
                              'from oracle.record.common import canonical; '
                              'notebook.SOURCE = Path(sys.argv[4]); '
                              'rows, outbound, first, count, hashes = notebook.exercise('
                              'sys.argv[1], "replay", Path(sys.argv[2]), "oracle-placeholder", Path(sys.argv[3])); '
                              'notebook.assert_success(sys.argv[1], rows, outbound, first, count, ()); '
                              'print(canonical({"rows": rows, "outbound": outbound, "work_hashes": hashes}))')
                    result = subprocess.run(
                        [PYTHON, '-c', script, route, str(directory / 'cassettes'),
                         str(directory / ('replay-' + seed)), str(source)], cwd=ROOT,
                        env={**os.environ, 'PYTHONHASHSEED': seed},
                        capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    results.append(json.loads(result.stdout))
                self.assertEqual(results[0], results[1])
                self.assertEqual(results[0], expected)

    def test_client_timeout_keeps_late_handler_inside_reviewed_transport(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-notebook-timeout-') as temp:
            result = subprocess.run(
                [PYTHON, '-c',
                 'from pathlib import Path; import sys; '
                 'from tests.test_http_notebook_live import probe_timeout_teardown; '
                 'probe_timeout_teardown(Path(sys.argv[1]))', temp],
                cwd=ROOT, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
