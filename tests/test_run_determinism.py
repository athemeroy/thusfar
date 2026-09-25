"""Reproduce completion-order effects at the finalization boundary."""

import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

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


if __name__ == '__main__':
    unittest.main()
