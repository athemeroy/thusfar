import tempfile
import threading
import unittest

from async_jobs import Jobs


class JobTests(unittest.TestCase):
    def test_duplicate_disconnected_submit_and_restart_read_same_result(self):
        with tempfile.TemporaryDirectory() as root:
            jobs = Jobs(root, 'test-key', 'test-revision')
            started, release = threading.Event(), threading.Event()
            calls = []

            def compute(request):
                calls.append(request)
                started.set()
                release.wait(3)
                return {'answers': {'q': 'fixture'}}

            request = {'state': 'fixture passage', 'questions': {'q': {}}}
            token = jobs.submit(request, compute)
            self.assertTrue(started.wait(3))
            self.assertEqual(jobs.get(token)[0], 202)
            # Simulate losing the accepting connection then submitting again.
            self.assertEqual(jobs.submit(request, compute), token)
            release.set()
            jobs.executor.shutdown(wait=True)
            self.assertEqual(len(calls), 1)
            self.assertEqual(jobs.get(token), (200, {'answers': {'q': 'fixture'}}))
            restarted = Jobs(root, 'test-key', 'test-revision')
            self.assertEqual(restarted.get(token), jobs.get(token))
            self.assertEqual(restarted.submit(request, compute), token)
            restarted.executor.shutdown()
            self.assertEqual(len(calls), 1)

    def test_missing_or_invalid_job_never_runs_inference(self):
        with tempfile.TemporaryDirectory() as root:
            jobs = Jobs(root, 'test-key', 'test-revision')
            self.assertEqual(jobs.get('../file')[0], 404)
            self.assertEqual(jobs.get('0' * 64)[0], 410)
            jobs.executor.shutdown()


if __name__ == '__main__':
    unittest.main()
