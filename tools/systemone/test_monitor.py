import json
from pathlib import Path
import tempfile
import unittest
from monitor import Monitor


class MonitorTest(unittest.TestCase):
    def test_completed_counts_survive_restart_and_error_text_stays_private(self):
        with tempfile.TemporaryDirectory() as root:
            m = Monitor(root, 'decider-0.8b', 'RTX 4090', lambda: True)
            m.queued(False)
            self.assertEqual(m.snapshot(0)['queued'], 1)
            m.begin(2, False)
            m.step()
            self.assertEqual(m.snapshot(0)['current']['done'], 1)
            m.step()
            m.finish()
            m.begin(1, True)
            self.assertEqual(m.snapshot(2)['queued'], 1)
            m.finish(ValueError('private-book-content SECRET_KEY job=private-token'))
            saved = (Path(root) / 'activity-summary.json').read_text()
            log = (Path(root) / 'activity.jsonl').read_text()
            for marker in ('private-book-content', 'SECRET_KEY', 'private-token'):
                self.assertNotIn(marker, saved + log)
            restored = Monitor(root, 'decider-0.8b', 'RTX 4090', lambda: True)
            result = restored.snapshot(0)
            self.assertEqual(result['totals']['checks'], 1)
            self.assertEqual(result['totals']['questions'], 2)
            self.assertEqual(result['totals']['failures'], 1)
            self.assertEqual(result['history'][0]['error_type'], 'ValueError')
            self.assertIsNone(result['current'])


if __name__ == '__main__':
    unittest.main()
