"""Offline safety and exact-route contracts for the opt-in live settings recorder."""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from oracle.record.common import UnsafeValue, canonical, digest, write_json, write_jsonl
from oracle.record.http_model_live import (BASE_URL, MODEL, MODEL_URL, ExactOpener,
                                           _read_intent,
                                           assert_no_key_suffix, assert_success,
                                           assert_tape_no_key_suffix, exclusive_live_lock,
                                           isolated_settings,
                                           load_home_key, no_redirect_transport,
                                           planned_envelope, preflight, reconcile)

ROOT = Path(__file__).resolve().parents[1]
PYTHON = sys.executable
FAKE_KEY = 'ORACLE_FAKE_KEY_123456789'


class HttpModelLiveSafety(unittest.TestCase):
    def test_home_key_ignores_ambient_override_and_never_enters_envelope(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-settings-key-test-') as tmp:
            home = Path(tmp) / '.env'
            home.write_text("export NAS_DEFAULT_KEY='" + FAKE_KEY + "'\n", encoding='utf-8')
            original_ambient = os.environ.get('NAS_DEFAULT_KEY')
            with patch.dict(os.environ, {'NAS_DEFAULT_KEY': 'wrong-ambient-key',
                                         'LLM_BASE_URL_OPENAI': 'https://wrong.invalid/v1',
                                         'LLM_KEY_MAP': 'deepseek-flash=WRONG_KEY'}):
                self.assertEqual(load_home_key(home), FAKE_KEY)
                with isolated_settings(FAKE_KEY, Path(tmp)):
                    envelope = planned_envelope()
                    self.assertEqual(envelope['url'], MODEL_URL)
                    self.assertEqual(json.loads(envelope['body_utf8'])['model'], 'deepseek-flash')
                    self.assertEqual(json.loads(envelope['body_utf8'])['thinking'],
                                     {'type': 'disabled'})
                    self.assertNotIn(FAKE_KEY, canonical(envelope))
                    self.assertNotIn('authorization', canonical(envelope).lower())
            self.assertTrue(os.environ.get('NAS_DEFAULT_KEY') == original_ambient)
            self.assertEqual(BASE_URL, 'https://open.xiaojingai.com/v1')
            self.assertEqual(MODEL, 'deepseek-flash+nothink')

    def test_budget_and_existing_digest_stop_before_open(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-settings-guard-test-') as tmp:
            directory = Path(tmp)
            with isolated_settings(FAKE_KEY, directory):
                envelope = planned_envelope()
            audit = {'budget': {'guarded_charged_cny': 0.999, 'max_cny': 1.0}}
            with self.assertRaisesRegex(RuntimeError, 'shared ¥1'):
                preflight(directory, envelope, audit)
            tape = directory / (digest(envelope) + '.json')
            tape.write_text('{}', encoding='utf-8')
            with self.assertRaisesRegex(FileExistsError, 'already has a cassette'):
                preflight(directory, envelope, {'budget': {'guarded_charged_cny': 0.0,
                                                           'max_cny': 1.0}})

            class NeverOpen:
                def open(self, *_args, **_kwargs):
                    raise AssertionError('duplicate request reached the network')

            with isolated_settings(FAKE_KEY, directory):
                request = __import__('pipeline.llm', fromlist=['_request'])._request(
                    'openai', 'deepseek-flash', [{'role': 'user', 'content': '只回答两个字：可以'}],
                    FAKE_KEY, 16, 0, 'nothink')
                with self.assertRaisesRegex(FileExistsError, 'already recorded'):
                    ExactOpener(NeverOpen(), digest(envelope), (FAKE_KEY,), tape, 'record', []).open(request)

    def test_http_200_application_failure_and_key_suffix_are_not_success(self):
        request = {'method': 'POST', 'path': '/api/settings/test',
                   'headers': {'Content-Type': 'application/json'}, 'body_json': {}}
        row = {'route': 'settings-test-live', 'request': request,
               'transport': {'http_version': 'HTTP/1.1'},
               'response': {'status': 200,
                            'headers': {'content-type': 'application/json; charset=utf-8',
                                        'x-yedu-release': '1.7.5'},
                            'body_json': {'ok': False, 'message': '连接失败'}}}
        with self.assertRaisesRegex(ValueError, 'real-model HTTP success'):
            assert_success(row, (FAKE_KEY,))
        row['response']['body_json'] = {'ok': True,
                                        'message': '连接成功：deepseek-flash+nothink 用 0.0 秒回复了「6789」'}
        with self.assertRaisesRegex(ValueError, 'credential suffix'):
            assert_success(row, (FAKE_KEY,))
        row['response']['body_json'] = {'ok': True,
                                        'message': '连接成功：deepseek-flash+nothink 用 0.0 秒回复了「可以。」'}
        assert_success(row, (FAKE_KEY,))
        row['response']['body_json'] = {'ok': True,
                                        'message': '连接成功：deepseek-flash+nothink 用 0.0 秒回复了「可以」',
                                        'api_key_last4': '6789'}
        with self.assertRaisesRegex(ValueError, 'real-model HTTP success'):
            assert_success(row, (FAKE_KEY,))

    def test_failed_response_and_wire_chunks_reject_masked_key_tail(self):
        with self.assertRaises(UnsafeValue):
            assert_no_key_suffix('gateway rejected ***6789', FAKE_KEY)
        with tempfile.TemporaryDirectory(prefix='thusfar-settings-tail-test-') as tmp:
            tape = Path(tmp) / 'attempt.json'
            write_json(tape, {'attempts': [{'kind': 'http_error',
                                            'body_base64': base64.b64encode(
                                                b'{"error":"key ****6789"}').decode('ascii')}]})
            with self.assertRaises(UnsafeValue):
                assert_tape_no_key_suffix(tape, FAKE_KEY)

    def test_gateway_redirect_cannot_forward_authorization(self):
        received = []

        class RedirectingHandler(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                received.append(self.path)
                self.send_response(302)
                self.send_header('Location', '/second-host-simulation')
                self.send_header('Content-Length', '0')
                self.end_headers()

            def do_GET(self):
                received.append(self.path)
                self.send_response(200)
                self.send_header('Content-Length', '0')
                self.end_headers()

        server = ThreadingHTTPServer(('127.0.0.1', 0), RedirectingHandler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            with no_redirect_transport():
                from pipeline import llm
                request = urllib.request.Request(
                    f'http://127.0.0.1:{server.server_port}/gateway', data=b'{}',
                    headers={'Authorization': 'Bearer ' + FAKE_KEY}, method='POST')
                with self.assertRaises(urllib.error.HTTPError) as failure:
                    llm._opener().open(request, timeout=3)
            self.assertEqual(failure.exception.code, 302)
            self.assertEqual(received, ['/gateway'])
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=3)

    def test_bypass_proxy_keeps_direct_transport_with_redirects_disabled(self):
        with patch.dict(os.environ, {'LLM_BYPASS_PROXY': '1',
                                     'HTTPS_PROXY': 'http://127.0.0.1:1'}):
            with patch('oracle.record.http_model_live.urllib.request.build_opener') as build:
                with no_redirect_transport():
                    from pipeline import llm
                    llm._opener()
                handlers = build.call_args.args
                self.assertTrue(any(isinstance(handler, urllib.request.ProxyHandler)
                                    and not handler.proxies for handler in handlers))
                self.assertTrue(any(getattr(handler, '__name__', type(handler).__name__) == 'NoRedirect'
                                    for handler in handlers))

    def test_cross_process_live_lock_blocks_duplicate_recorder(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-settings-lock-test-') as tmp:
            directory = Path(tmp) / 'tape'
            directory.mkdir()
            marker = Path(tmp) / 'child-ready'
            script = (
                'import sys\n'
                'from pathlib import Path\n'
                'import fcntl\n'
                'from oracle.record.http_model_live import exclusive_live_lock\n'
                'original = fcntl.flock\n'
                'def entering(fd, operation):\n'
                ' if operation == fcntl.LOCK_EX:\n'
                '  Path(sys.argv[2]).write_text("entering")\n'
                ' return original(fd, operation)\n'
                'fcntl.flock = entering\n'
                'with exclusive_live_lock(Path(sys.argv[1])):\n'
                ' print("acquired", flush=True)\n'
            )
            with exclusive_live_lock(directory):
                child = subprocess.Popen(
                    [PYTHON, '-c', script, str(directory), str(marker)], cwd=ROOT,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                )
                deadline = time.monotonic() + 3
                while not marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(marker.exists())
                time.sleep(0.15)
                self.assertIsNone(child.poll())
            stdout, stderr = child.communicate(timeout=3)
            self.assertEqual(child.returncode, 0, stderr)
            self.assertEqual(stdout.strip(), 'acquired')

    def test_intent_only_reconciliation_never_creates_an_observed_http_receipt(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-settings-intent-test-') as tmp:
            root = Path(tmp)
            cassette = root / 'cassettes'
            receipt = root / 'receipt'
            cassette.mkdir()
            receipt.mkdir()
            with isolated_settings(FAKE_KEY, root):
                envelope = planned_envelope()
            sha = digest(envelope)
            write_json(receipt / 'intent.json', {
                'schema': 1, 'task_id': 'a' * 32, 'route': 'settings-test-live',
                'model': MODEL, 'base_url': BASE_URL,
                'clock_unix_seconds': 1_750_000_000.0,
                'cassette_directory': str(cassette.resolve()),
                'request_sha256': sha, 'tape_tree_before_sha256': 'b' * 64,
                'model_attempts_before': 0, 'guarded_charge_before_cny': 0.0,
                'preflight_reserved_cny': 0.005440934, 'max_cny': 1.0,
            })
            write_json(cassette / 'budget-ledger.json', {'schema': 1, 'max_cny': 1.0,
                                                         'entries': []})
            first = reconcile(receipt, cassette)
            self.assertEqual(first['state'], 'intent_without_recorded_attempt')
            relocated = root / 'relocated-cassettes'
            with self.assertRaisesRegex(ValueError, 'reviewed paid request'):
                _read_intent(receipt, relocated)
            self.assertEqual(_read_intent(receipt, relocated, allow_relocation=True)['task_id'], 'a' * 32)
            tape = cassette / (sha + '.json')
            write_json(tape, {'schema': 1, 'request_sha256': sha, 'request': envelope,
                              'attempts': [{'kind': 'pending'}], 'overlap_groups': []})
            write_json(cassette / 'budget-ledger.json', {'schema': 1, 'max_cny': 1.0,
                        'entries': [{'request_sha256': sha, 'state': 'reserved'}]})
            self.assertEqual(reconcile(receipt, cassette)['state'], 'pending_original_attempt')
            write_json(tape, {'schema': 1, 'request_sha256': sha, 'request': envelope,
                              'attempts': [{'kind': 'response'}], 'overlap_groups': []})
            write_json(cassette / 'budget-ledger.json', {'schema': 1, 'max_cny': 1.0,
                        'entries': [{'request_sha256': sha, 'state': 'completed'}]})
            before = {path.name: path.read_bytes() for path in (receipt / 'intent.json', tape,
                                                                 cassette / 'budget-ledger.json')}
            with patch('oracle.record.http_model_live.verify_live_cassettes') as audit:
                settled = reconcile(receipt, cassette)
            audit.assert_called_once_with(cassette)
            self.assertEqual(settled['state'], 'settled_wire_original_http_missing')
            self.assertFalse(settled['original_live_http_present'])
            self.assertFalse((receipt / 'observation.json').exists())
            self.assertEqual(before, {path.name: path.read_bytes() for path in (
                receipt / 'intent.json', tape, cassette / 'budget-ledger.json')})
            row = {
                'route': 'settings-test-live',
                'request': {'method': 'POST', 'path': '/api/settings/test',
                            'headers': {'Content-Type': 'application/json'}, 'body_json': {}},
                'transport': {'http_version': 'HTTP/1.1'},
                'response': {'status': 200,
                             'headers': {'content-type': 'application/json; charset=utf-8',
                                         'x-yedu-release': '1.7.5'},
                             'body_json': {'ok': True,
                                           'message': '连接成功：deepseek-flash+nothink 用 0.0 秒回复了「可以。」'}},
            }
            write_jsonl(receipt / 'attempt-http.jsonl', [row])
            write_jsonl(receipt / 'live-http.jsonl', [row])
            with patch('oracle.record.http_model_live.verify_live_cassettes') as audit:
                observed = reconcile(receipt, cassette)
            audit.assert_called_once_with(cassette)
            self.assertEqual(observed['state'], 'observed_live_http_without_observation')
            self.assertTrue(observed['original_live_http_present'])

    def test_application_error_persists_original_http_attempt_before_success_gate(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-settings-error-test-') as tmp:
            directory = Path(tmp)
            with isolated_settings(FAKE_KEY, directory):
                envelope = planned_envelope()
            request_sha = digest(envelope)
            body = b'{"error":{"message":"unauthorized"}}'
            write_json(directory / (request_sha + '.json'), {
                'schema': 1, 'request_sha256': request_sha, 'request': envelope,
                'attempts': [{'kind': 'response', 'status': 401,
                              'headers': {'Content-Type': 'application/json'},
                              'chunks_base64': [base64.b64encode(body).decode('ascii')]}],
                'overlap_groups': [],
            })
            observed_path = directory / 'observed-http.jsonl'
            # A full test run may already have imported server.app with a different
            # DATA path. Exercise its import-time settings guard in a fresh process.
            script = (
                'import sys\n'
                'from pathlib import Path\n'
                'from oracle.record.common import canonical, write_jsonl\n'
                'from oracle.record.http_model_live import exercise\n'
                'key = sys.argv[3]\n'
                'observed = Path(sys.argv[4])\n'
                'def save(row, secrets):\n'
                ' if key in canonical(row):\n'
                '  raise AssertionError("credential appeared in HTTP receipt")\n'
                ' write_jsonl(observed, [row])\n'
                'try:\n'
                ' exercise("replay", Path(sys.argv[1]), key, sys.argv[2], save)\n'
                'except ValueError as exc:\n'
                ' if "real-model HTTP success" not in str(exc):\n'
                '  raise\n'
                'else:\n'
                ' raise AssertionError("application failure passed the success gate")\n'
            )
            result = subprocess.run(
                [PYTHON, '-c', script, str(directory), request_sha, FAKE_KEY,
                 str(observed_path)], cwd=ROOT,
                env={**os.environ, 'PYTHONHASHSEED': '1'}, capture_output=True,
                text=True, timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            recorded = json.loads(observed_path.read_text(encoding='utf-8'))
            self.assertEqual(recorded['response']['status'], 200)
            self.assertFalse(recorded['response']['body_json']['ok'])

    def test_real_handler_and_python_client_replay_exact_synthetic_reply_offline(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-settings-replay-test-') as tmp:
            directory = Path(tmp)
            with isolated_settings(FAKE_KEY, directory):
                envelope = planned_envelope()
            request_sha = digest(envelope)
            events = (
                'data: {"choices":[{"delta":{"content":"可以"}}]}\n\n'
                'data: {"usage":{"prompt_tokens":12,"completion_tokens":2}}\n\n'
                'data: [DONE]\n\n'
            ).encode('utf-8')
            write_json(directory / (request_sha + '.json'), {
                'schema': 1, 'request_sha256': request_sha, 'request': envelope,
                'attempts': [{'kind': 'response', 'status': 200,
                              'headers': {'Content-Type': 'text/event-stream'},
                              'chunks_base64': [base64.b64encode(events).decode('ascii')]}],
                'overlap_groups': [],
            })
            script = (
                'import sys\n'
                'from pathlib import Path\n'
                'from oracle.record.common import canonical\n'
                'from oracle.record.http_model_live import exercise\n'
                'row, count = exercise("replay", Path(sys.argv[1]), sys.argv[2], sys.argv[3])\n'
                'assert count == 1\n'
                'print(canonical(row))\n'
            )
            outputs = []
            for seed in ('1', '2'):
                result = subprocess.run(
                    [PYTHON, '-c', script, str(directory), FAKE_KEY, request_sha], cwd=ROOT,
                    env={**os.environ, 'PYTHONHASHSEED': seed}, capture_output=True, text=True,
                    check=True,
                )
                outputs.append(result.stdout)
            self.assertEqual(outputs[0], outputs[1])
            self.assertNotIn(FAKE_KEY, outputs[0])
            row = json.loads(outputs[0])
            assert_success(row, (FAKE_KEY,))
            self.assertEqual(row['response']['body_json'], {
                'ok': True,
                'message': '连接成功：deepseek-flash+nothink 用 0.0 秒回复了「可以」',
            })
            self.assertEqual(row['response']['status'], 200)


if __name__ == '__main__':
    unittest.main()
