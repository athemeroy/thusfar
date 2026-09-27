"""The real thread worker must finish the queued HTTP operation with all artifacts."""
import copy
import json
import unittest
from contextlib import contextmanager

from oracle.record.http_process_replay import (GOLDEN, REFERENCE, build_receipt,
                                               normalized_response, validate_run,
                                               worker_lifecycle)


class HttpProcessReplayTests(unittest.TestCase):
    def setUp(self):
        self.receipt = json.loads(GOLDEN.read_text())
        self.reference = json.loads((REFERENCE / 'provenance.json').read_text())['artifact_sha256']
        self.status = json.loads((REFERENCE / 'status.json').read_text())

    def test_real_http_worker_matches_two_independent_offline_recordings(self):
        self.assertEqual(build_receipt(), self.receipt)

    def test_completed_delete_must_preserve_all_status_and_usage(self):
        for key, value in (('state', 'paused'), ('frontier', 21732), ('usage', {})):
            changed = copy.deepcopy(self.receipt)
            changed['http'][1]['response']['body_json']['status'][key] = value
            with self.subTest(key=key):
                with self.assertRaisesRegex(ValueError, 'preserve completed status'):
                    validate_run(changed, self.reference, self.status)

    def test_missing_cache_artifact_cannot_pass_as_full_completion(self):
        changed = copy.deepcopy(self.receipt)
        cache = next(name for name in changed['artifact_sha256'] if name.startswith('work/judge/cache/'))
        changed['artifact_sha256'].pop(cache)
        with self.assertRaisesRegex(ValueError, 'complete book golden') as caught:
            validate_run(changed, self.reference, self.status)
        self.assertIn(cache, str(caught.exception))

    def test_http_200_does_not_hide_worker_failure_or_missing_calls(self):
        for field, value in (('worker', {'last_error': 'failed'}),
                             ('request_counts', {'model': 0, 'jev': 0})):
            changed = dict(self.receipt, **{field: value})
            with self.subTest(field=field):
                with self.assertRaises(ValueError):
                    validate_run(changed, self.reference, self.status)

    def test_equal_call_totals_do_not_hide_a_different_prompt_digest(self):
        changed = copy.deepcopy(self.receipt)
        changed['requests'][0]['sha256'] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'request digests differ'):
            validate_run(changed, self.reference, self.status)

    def test_content_length_is_checked_before_timestamp_normalization(self):
        class Response:
            version = 11
            status = 200
            def read(self):
                return b'{"ok":true,"status":{"state":"queued","updated":123,"error":null}}'
            def getheader(self, key):
                return {'content-type': 'application/json; charset=utf-8',
                        'x-yedu-release': '1.7.5', 'content-length': '1'}.get(key)
        with self.assertRaisesRegex(ValueError, 'byte length'):
            normalized_response(Response(), 'queue')

    def test_failure_joins_worker_before_restoring_transport(self):
        events = []
        @contextmanager
        def transport():
            events.append('guard-enter')
            try:
                yield
            finally:
                events.append('guard-exit')
        class Worker:
            ident = 1
            def stop(self):
                events.append('stop')
            def join(self):
                self_active = 'guard-enter' in events and 'guard-exit' not in events
                if not self_active:
                    raise AssertionError('worker escaped the transport guard')
                events.append('joined')
        with self.assertRaisesRegex(RuntimeError, 'client disconnected'):
            with transport(), worker_lifecycle(Worker()):
                raise RuntimeError('client disconnected')
        self.assertEqual(events, ['guard-enter', 'stop', 'joined', 'guard-exit'])


if __name__ == '__main__':
    unittest.main()
