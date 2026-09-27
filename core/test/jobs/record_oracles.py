"""Record server.jobs.Worker state transitions using Python 3.11 and a fake run.

No subprocess or model is called. This records original metadata/status semantics;
the Dart-only queue receipt and isolate scheduling are tested separately.
"""
from __future__ import annotations

import copy
import hashlib
import json
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from pipeline.run import AlreadyRunning, Cancelled
from server.jobs import Worker
from server.storage import write_json

NOW = 5000.0


def read(path):
    return json.loads(path.read_text()) if path.exists() else None


def record(spec):
    with tempfile.TemporaryDirectory(prefix='jobs-oracle-') as temp:
        books = Path(temp)
        root = books / 'fixture'
        root.mkdir()
        write_json(root / 'book.json', {'title': 'offline fixture'})
        for key in ['meta', 'status']:
            write_json(root / f'{key}.json', spec.get(key, {}))
        if 'journal' in spec:
            (root / 'work').mkdir()
            write_json(root / 'work/quality-retry.json', spec['journal'])
        calls = []
        with patch.dict('os.environ', {'YEDU_WORKER_MODE': 'thread', 'EXTRACT_MODEL': 'extract-fixture',
                                       'LOCAL_MODEL': 'local-fixture', 'LOCAL_CONCURRENCY': '3'}), \
             patch('server.jobs.time.time', return_value=NOW):
            worker = Worker(books, books, read, write_json, enabled=False)
            def fake_run(directory, *, cancel_event, **kwargs):
                assert directory == root
                calls.append(kwargs)
                behavior = spec.get('run', 'done')
                if behavior == 'cancel':
                    worker.cancel(root, timeout=0)
                    assert cancel_event.is_set()
                    raise Cancelled()
                if behavior == 'stop':
                    worker.stop()
                    assert cancel_event.is_set()
                    raise Cancelled()
                if behavior == 'busy':
                    raise AlreadyRunning()
                if behavior == 'error':
                    raise RuntimeError('fixture failure')
                if behavior == 'incomplete':
                    return
                if 'write_journal' in spec:
                    write_json(root / 'work/quality-retry.json', spec['write_journal'])
                state = read(root / 'status.json') or {}
                state.update(state='done')
                write_json(root / 'status.json', state)
            with patch('pipeline.run.run_book', side_effect=fake_run), \
                 patch('server.jobs.subprocess.Popen', side_effect=AssertionError('subprocess forbidden')):
                for action in spec.get('actions', ['one']):
                    if action == 'enable':
                        worker.set_auto(root, True)
                    elif action == 'disable':
                        worker.set_auto(root, False)
                    else:
                        worker._one(root)
            return {'case': spec['case'], 'input': copy.deepcopy(spec), 'output': {
                'meta': read(root / 'meta.json'), 'status': read(root / 'status.json'),
                'calls': calls, 'last_error': worker.last_error,
                'current': worker.current, 'journal': read(root / 'work/quality-retry.json'),
            }}


def cases():
    yield {'case': 'disabled_auto_does_not_run', 'meta': {'auto': False}, 'status': {'state': 'idle'}}
    yield {'case': 'finished_quality_pending_does_not_imply_retry', 'meta': {'auto': True},
           'status': {'state': 'done', 'quality': {'state': 'pending', 'pending': ['summary']}}}
    yield {'case': 'explicit_start', 'meta': {'auto': False}, 'status': {'state': 'idle'},
           'actions': ['enable', 'one']}
    yield {'case': 'recent_error_cooldown', 'meta': {'auto': True},
           'status': {'state': 'error', 'updated': 4990, 'error': 'previous'}}
    yield {'case': 'expired_error_can_run', 'meta': {'auto': True},
           'status': {'state': 'error', 'updated': 3000, 'error': 'previous'}}
    yield {'case': 'explicit_resume_clears_cooldown', 'meta': {'auto': True},
           'status': {'state': 'error', 'updated': 4990, 'error': 'previous'}, 'actions': ['enable', 'one']}
    for behavior in ['cancel', 'stop', 'busy', 'error', 'incomplete']:
        yield {'case': 'run_' + behavior, 'meta': {'auto': True}, 'status': {'state': 'queued'}, 'run': behavior}
    base = {'meta': {'auto': True}, 'status': {'state': 'done', 'quality': {'state': 'pending'}},
            'actions': ['enable', 'one']}
    for behavior in ['error', 'busy']:
        yield {**copy.deepcopy(base), 'case': 'retry_survives_' + behavior, 'run': behavior}
    yield {**copy.deepcopy(base), 'case': 'retry_acknowledged_by_changed_journal',
           'write_journal': {'state': 'complete', 'archive': 'work/retry-archive/fixture'}}
    yield {**copy.deepcopy(base), 'case': 'old_complete_journal_does_not_acknowledge',
           'journal': {'state': 'complete', 'archive': 'work/retry-archive/old'}}
    yield {**copy.deepcopy(base), 'case': 'interrupted_rebuild_journal_acknowledges',
           'journal': {'state': 'rebuilding', 'archive': 'work/retry-archive/old'}}
    yield {**copy.deepcopy(base), 'case': 'disable_removes_retry_request', 'actions': ['enable', 'disable', 'one']}


if __name__ == '__main__':
    assert sys.version_info[:2] == (3, 11), 'Use the frozen Python 3.11 oracle'
    payload = {'schema': 1, 'python': '3.11', 'source_sha256': hashlib.sha256((ROOT / 'server/jobs.py').read_bytes()).hexdigest(),
               'cases': [record(spec) for spec in cases()]}
    path = Path(__file__).parent / 'fixtures/worker_oracles.json'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + '\n')
    print(f'Recorded {len(payload["cases"])} worker transitions with no model calls')
