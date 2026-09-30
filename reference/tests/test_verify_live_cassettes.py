"""Read-only audit covers the model/JEV tape and cumulative ¥1 ledger risks."""
from __future__ import annotations

import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from oracle.record.cassettes import CassetteStore, _CONFIGURED_PRICE, _GUARD_PRICE
from oracle.record.common import canonical, digest, write_json
from oracle.record.verify_live_cassettes import JEV_URL, MODEL_URL, verify

ROOT = Path(__file__).resolve().parents[1]
FAKE_SECRET = 'ORACLE_FAKE_KEY_123456789'


def _fixture(directory: Path) -> tuple[Path, Path, Path]:
    model = {'model': 'deepseek-flash',
             'messages': [{'role': 'system', 'content': 'Only the given text.'},
                          {'role': 'user', 'content': 'Who appears here?'}],
             'max_tokens': 1200, 'temperature': 0.2, 'stream': True,
             'stream_options': {'include_usage': True}, 'thinking': {'type': 'disabled'}}
    model_request = {'method': 'POST', 'url': MODEL_URL,
                     'headers': {'accept': 'text/event-stream',
                                 'content-type': 'application/json'},
                     'body_utf8': canonical(model)}
    model_sha = digest(model_request)
    model_path = directory / (model_sha + '.json')
    stream = (b'data: {"choices":[{"delta":{"content":"Known fact."}}]}\n\n'
              b'data: {"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":20}}\n\n'
              b'data: [DONE]\n\n')
    write_json(model_path, {'schema': 1, 'request_sha256': model_sha, 'request': model_request,
                            'attempts': [{'kind': 'response', 'status': 200,
                                          'headers': {'Content-Type': 'text/event-stream'},
                                          'chunks_base64': [base64.b64encode(stream).decode(), '']}],
                            'overlap_groups': []})
    jev_request = {'method': 'POST', 'url': JEV_URL,
                   'headers': {'content-type': 'application/json'},
                   'body_utf8': canonical({'items': ['known passage'],
                                           'dimensions': {'d0': {'labels': ['yes', 'no'],
                                                                 'instructions': 'Judge this claim'}}})}
    jev_sha = digest(jev_request)
    jev_path = directory / (jev_sha + '.json')
    jev_reply = b'{"results":[{"dimensions":{"d0":{"label":"yes","confidence":1.0}}}]}'
    write_json(jev_path, {'schema': 1, 'request_sha256': jev_sha, 'request': jev_request,
                          'attempts': [{'kind': 'response', 'status': 200,
                                        'headers': {'Content-Type': 'application/json'},
                                        'chunks_base64': [base64.b64encode(jev_reply).decode(), '']}],
                          'overlap_groups': []})
    reserved = CassetteStore._upper_bound(model_request)
    configured = round((100 * _CONFIGURED_PRICE[0] + 20 * _CONFIGURED_PRICE[1]) / 1_000_000, 9)
    guarded = round((100 * _GUARD_PRICE[0] + 20 * _GUARD_PRICE[1]) / 1_000_000, 9)
    ledger_path = directory / 'budget-ledger.json'
    write_json(ledger_path, {'schema': 1, 'max_cny': 1.0,
                             'entries': [{'id': 'a' * 32, 'request_sha256': model_sha,
                                          'reserved_cny': reserved, 'charged_cny': guarded,
                                          'state': 'completed', 'prompt_tokens': 100,
                                          'completion_tokens': 20,
                                          'configured_rate_estimate_cny': configured,
                                          'guarded_usage_cny': guarded}]})
    return model_path, jev_path, ledger_path


class LiveCassetteVerifierTests(unittest.TestCase):
    def test_accepts_exact_live_envelopes_usage_budget_and_report(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-live-audit-test-') as temp:
            directory = Path(temp)
            _fixture(directory)
            report = verify(directory)
            self.assertEqual(report['json_files'], 3)
            self.assertEqual(report['attempts'], 2)
            self.assertEqual((report['model_attempts'], report['free_jev_attempts']), (1, 1))
            self.assertEqual(report['budget']['model_attempts'], 1)
            self.assertEqual(report['budget']['usage_unavailable'], 0)
            expected = directory.parent / (directory.name + '-expected.json')
            try:
                write_json(expected, report)
                run = subprocess.run([sys.executable, '-m', 'oracle.record.verify_live_cassettes',
                                      str(directory), '--expect-report', str(expected)],
                                     cwd=ROOT, capture_output=True, text=True, timeout=10)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertEqual(json.loads(run.stdout), report)
                report['model_attempts'] = 2
                write_json(expected, report)
                rejected = subprocess.run([sys.executable, '-m', 'oracle.record.verify_live_cassettes',
                                           str(directory), '--expect-report', str(expected)],
                                          cwd=ROOT, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn('expected report', rejected.stderr)
            finally:
                expected.unlink(missing_ok=True)

    def test_rejects_changed_model_even_when_digest_and_ledger_are_rewritten(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-live-audit-test-') as temp:
            directory = Path(temp)
            model_path, _, ledger_path = _fixture(directory)
            tape = json.loads(model_path.read_text())
            body = json.loads(tape['request']['body_utf8'])
            body['model'] = 'other-model'
            tape['request']['body_utf8'] = canonical(body)
            new_sha = digest(tape['request'])
            tape['request_sha256'] = new_sha
            model_path.unlink()
            write_json(directory / (new_sha + '.json'), tape)
            ledger = json.loads(ledger_path.read_text())
            ledger['entries'][0]['request_sha256'] = new_sha
            write_json(ledger_path, ledger)
            with self.assertRaisesRegex(ValueError, 'deepseek-flash'):
                verify(directory)

    def test_rejects_keyed_classifier_and_decoded_secret_without_disclosure(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-live-audit-test-') as temp:
            directory = Path(temp)
            model_path, jev_path, _ = _fixture(directory)
            tape = json.loads(jev_path.read_text())
            tape['request']['headers']['authorization'] = 'Bearer ' + FAKE_SECRET
            tape['request_sha256'] = digest(tape['request'])
            jev_path.unlink()
            write_json(directory / (tape['request_sha256'] + '.json'), tape)
            with patch.dict(os.environ, {'NAS_DEFAULT_KEY': FAKE_SECRET}):
                with self.assertRaises(ValueError) as caught:
                    verify(directory)
            self.assertNotIn(FAKE_SECRET, str(caught.exception))
            (directory / (tape['request_sha256'] + '.json')).unlink()
            _, jev_path, _ = _fixture(directory)
            model = json.loads(model_path.read_text())
            model['attempts'][0]['chunks_base64'] = [base64.b64encode(FAKE_SECRET.encode()).decode()]
            write_json(model_path, model)
            with patch.dict(os.environ, {'NAS_DEFAULT_KEY': FAKE_SECRET}):
                with self.assertRaises(ValueError) as caught:
                    verify(directory)
            self.assertNotIn(FAKE_SECRET, str(caught.exception))

    def test_rejects_pending_and_ambiguous_concurrent_attempts(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-live-audit-test-') as temp:
            directory = Path(temp)
            model_path, _, _ = _fixture(directory)
            tape = json.loads(model_path.read_text())
            tape['attempts'][0] = {'kind': 'pending'}
            write_json(model_path, tape)
            with self.assertRaisesRegex(ValueError, 'pending|unfinished'):
                verify(directory)
            _, _, _ = _fixture(directory)
            tape = json.loads(model_path.read_text())
            different = dict(tape['attempts'][0])
            different['chunks_base64'] = [base64.b64encode(b'data: [DONE]\n\n').decode()]
            tape['attempts'].append(different)
            tape['overlap_groups'] = [[0, 1]]
            write_json(model_path, tape)
            with self.assertRaisesRegex(ValueError, 'ambiguous'):
                verify(directory)

    def test_rejects_usage_mismatch_or_a_lowered_cumulative_ceiling(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-live-audit-test-') as temp:
            directory = Path(temp)
            _, _, ledger_path = _fixture(directory)
            original = json.loads(ledger_path.read_text())
            wrong = json.loads(ledger_path.read_text())
            wrong['entries'][0]['prompt_tokens'] += 1
            write_json(ledger_path, wrong)
            with self.assertRaisesRegex(ValueError, 'charge does not match'):
                verify(directory)
            original['max_cny'] = 0.000001
            write_json(ledger_path, original)
            with self.assertRaisesRegex(ValueError, 'cumulative guarded'):
                verify(directory)

    def test_rejects_usage_inserted_after_the_client_stream_ended(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-live-audit-test-') as temp:
            directory = Path(temp)
            model_path, _, _ = _fixture(directory)
            tape = json.loads(model_path.read_text())
            trailing = b'data: {"usage":{"prompt_tokens":1,"completion_tokens":1}}\n\n'
            tape['attempts'][0]['chunks_base64'].append(base64.b64encode(trailing).decode())
            write_json(model_path, tape)
            with self.assertRaisesRegex(ValueError, 'client-visible stream end'):
                verify(directory)

    def test_rejects_orphan_ledger_entry_and_symlink(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-live-audit-test-') as temp:
            directory = Path(temp)
            _, _, ledger_path = _fixture(directory)
            ledger = json.loads(ledger_path.read_text())
            ledger['entries'] = []
            write_json(ledger_path, ledger)
            with self.assertRaisesRegex(ValueError, 'ledger entries do not match'):
                verify(directory)
            _fixture(directory)
            (directory / 'unexpected.json').symlink_to(ledger_path)
            with self.assertRaisesRegex(ValueError, 'symlink'):
                verify(directory)


if __name__ == '__main__':
    unittest.main()
