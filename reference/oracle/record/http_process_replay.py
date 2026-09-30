"""Exercise HTTP queue-to-completion with the real thread worker and existing Aq tape."""
from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from collections import Counter
from contextlib import contextmanager
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from .artifacts import snapshot, stage_book, without_times
from .cassettes import CassetteStore, install
from .common import (assert_public, canonical, digest, known_secrets,
                     require_reference_runtime, write_json)
from .concurrency import CASSETTES, REFERENCE, ROOT, SOURCE
from .functions import LoopbackOnly
from .http_model_live import MODEL, isolated_settings
from .http_routes import _HEADERS
from .resume import GOLDEN as RESUME_GOLDEN, file_hashes
from .verify_book_artifacts import verify_book
from .verify_live_cassettes import verify as verify_cassettes

GOLDEN = ROOT / 'oracle/goldens/http/aq_process_replay.json'
BOOK_ID = 'aq_process_fixture'


def code_hashes() -> dict[str, str]:
    paths = sorted([*ROOT.glob('pipeline/*.py'), *ROOT.glob('server/*.py')])
    paths += [ROOT / 'oracle/record' / name for name in (
        'http_process_replay.py', 'http_model_live.py', 'http_routes.py', 'concurrency.py',
        'artifacts.py', 'cassettes.py', 'common.py', 'functions.py', 'resume.py',
        'verify_book_artifacts.py', 'verify_live_cassettes.py')]
    return {path.relative_to(ROOT).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in paths}


@contextmanager
def worker_lifecycle(worker):
    """Keep the cassette/network guards installed until the worker really exits."""
    try:
        yield
    finally:
        worker.stop()
        if worker.ident is not None:
            # An outer isolated-process timeout handles a stuck replay. Restoring
            # the live transport while a worker is still alive would be unsafe.
            worker.join()


def normalized_response(response, route: str) -> dict:
    raw = response.read()
    headers = {key: response.getheader(key) for key in _HEADERS
               if response.getheader(key) is not None}
    if response.version != 11 or response.status != 200 or \
            headers.get('content-type') != 'application/json; charset=utf-8' or \
            headers.get('x-yedu-release') != '1.7.5' or \
            headers.get('content-length') != str(len(raw)):
        raise ValueError('process HTTP response has wrong status, release, transport or byte length')
    body = json.loads(raw)
    if route in ('queue', 'completed-delete'):
        if not isinstance(body, dict) or set(body) != {'ok', 'status'} or body['ok'] is not True:
            raise ValueError('process HTTP response did not accept the operation')
        body['status'] = without_times(body['status'], 'status.json')
    elif route == 'completed-shelf':
        if not isinstance(body, list) or len(body) != 1 or body[0].get('id') != BOOK_ID:
            raise ValueError('completed shelf did not contain the isolated book')
        body[0]['status'] = without_times(body[0]['status'], 'status.json')
    else:
        raise ValueError('unknown process HTTP normalization route')
    # The original Content-Length was checked against the raw response above.
    # Removing volatile status timestamps changes the recorded byte length.
    headers.pop('content-length')
    return {'status': response.status, 'headers': headers, 'body_json': body,
            'wire_content_length_verified': True}


def validate_run(result: dict, reference: dict[str, str], status: dict) -> None:
    if result['artifact_sha256'] != reference:
        actual = result['artifact_sha256']
        changed = sorted(name for name in actual.keys() | reference.keys()
                         if actual.get(name) != reference.get(name))
        raise ValueError('HTTP worker output differs from the complete book golden: '
                         + ', '.join(changed))
    rows = result['http']
    if len(rows) != 3 or [row.get('route') for row in rows] != \
            ['queue', 'completed-delete', 'completed-shelf']:
        raise ValueError('process HTTP lifecycle is incomplete')
    expected_requests = [
        {'method': 'POST', 'path': f'/api/books/{BOOK_ID}/process', 'body_json': {}},
        {'method': 'DELETE', 'path': f'/api/books/{BOOK_ID}/process'},
        {'method': 'GET', 'path': '/api/books'},
    ]
    for row, expected in zip(rows, expected_requests):
        if row['request'] != expected or row['response']['status'] != 200 or \
                row['transport'] != {'http_version': 'HTTP/1.1', 'same_connection': True}:
            raise ValueError('process HTTP request, success status or keepalive changed')
    if rows[0]['response']['body_json'] != {'ok': True, 'status': {'state': 'queued', 'error': None}}:
        raise ValueError('process POST did not queue a fresh book')
    if rows[1]['response']['body_json'] != {'ok': True, 'status': status}:
        raise ValueError('process DELETE did not preserve completed status')
    shelf = rows[2]['response']['body_json'][0]
    if shelf['status'] != status or shelf['auto'] is not False:
        raise ValueError('shelf does not expose the completed, explicitly stopped book')
    if result['request_counts'] != {'model': 21, 'jev': 82}:
        raise ValueError('HTTP worker did not consume the complete reviewed Aq tape')
    expected_requests = json.loads(RESUME_GOLDEN.read_text())['runs']['fresh']['requests']
    if result['requests'] != expected_requests:
        raise ValueError('HTTP worker request digests differ from the fresh book replay')
    if result['worker'] != {'mode': 'thread', 'concurrency': 12,
                             'alive_after_stop': False, 'last_error': None}:
        raise ValueError('HTTP worker did not finish and shut down cleanly')


def capture(out: Path) -> None:
    if 'server.app' in sys.modules:
        raise RuntimeError('HTTP process capture requires a fresh interpreter')
    audit = verify_cassettes(CASSETTES)
    with tempfile.TemporaryDirectory(prefix='thusfar-http-process-') as scratch:
        data = Path(scratch) / 'data'
        books = data / 'books'
        books.mkdir(parents=True)
        book = books / BOOK_ID
        stage_book(SOURCE, book, 'fresh')
        environment = {'YEDU_WORKER_MODE': 'thread', 'LOCAL_CONCURRENCY': '12',
                       'LOCAL_MODEL': MODEL, 'RECAP_MODEL': MODEL, 'JUDGE_MODEL': MODEL,
                       'CLASSIFY_MODEL': MODEL, 'JUDGE_LOG': '0',
                       'JUDGE_LOG_DIR': str(book / 'work/judge'), 'JUDGE_CACHE': '1'}
        with isolated_settings('oracle-placeholder', data), patch.dict(os.environ, environment):
            from server import app
            if app.DATA != data or app.WORKER.mode != 'thread' or app.WORKER.enabled:
                raise RuntimeError('HTTP worker imported outside its isolated environment')
            server = ThreadingHTTPServer(('127.0.0.1', 0), app.Handler)
            server.daemon_threads = True
            serving = threading.Thread(target=server.serve_forever, daemon=True)
            serving.start()
            connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=20)
            requests = Counter()
            counter_lock = threading.Lock()
            original_next = CassetteStore.next

            def traced(store, envelope):
                kind = 'jev' if envelope['url'] == 'https://classifier.dev/v1/classify' else 'model'
                with counter_lock:
                    requests[(digest(envelope), kind)] += 1
                return original_next(store, envelope)

            rows = []
            first_socket = None

            def request(route, method, path, body=None):
                nonlocal first_socket
                headers = {'Content-Type': 'application/json'} if body is not None else {}
                payload = canonical(body).encode() if body is not None else None
                connection.request(method, path, body=payload, headers=headers)
                current_socket = connection.sock
                if first_socket is None:
                    first_socket = current_socket
                reply = normalized_response(connection.getresponse(), route)
                if current_socket is None or current_socket is not first_socket:
                    raise ValueError('HTTP process lifecycle did not reuse one connection')
                description = {'method': method, 'path': path}
                if body is not None:
                    description['body_json'] = body
                rows.append({'route': route, 'request': description, 'response': reply,
                             'transport': {'http_version': 'HTTP/1.1', 'same_connection': True}})

            try:
                with LoopbackOnly(), install(CASSETTES, 'replay') as tape, \
                        patch.object(CassetteStore, 'next', traced), \
                        worker_lifecycle(app.WORKER):
                    # Queue through the production handler before starting its actual
                    # worker, so the observable queued response is not a timing race.
                    request('queue', 'POST', f'/api/books/{BOOK_ID}/process', {})
                    if app.WORKER.manual_queue != {BOOK_ID}:
                        raise ValueError('process POST did not reach the actual worker queue')
                    app.WORKER.start()
                    deadline = time.monotonic() + 90
                    while time.monotonic() < deadline:
                        state = app.cached_json(book / 'status.json') or {}
                        if app.WORKER.last_error or state.get('state') == 'error':
                            raise RuntimeError('cassette-backed HTTP worker failed')
                        if state.get('state') == 'done' and app.WORKER.current_done.is_set():
                            break
                        time.sleep(0.01)
                    else:
                        raise RuntimeError('cassette-backed HTTP worker did not finish in 90 seconds')
                    if tape.count != 103:
                        raise ValueError('HTTP worker did not consume all 103 recorded attempts')
                    request('completed-delete', 'DELETE', f'/api/books/{BOOK_ID}/process')
                    request('completed-shelf', 'GET', '/api/books')
            finally:
                connection.close()
                server.shutdown()
                server.server_close()
                serving.join(timeout=3)
            artifacts = snapshot(book, Path(scratch) / 'artifacts')
            if verify_cassettes(CASSETTES) != audit:
                raise ValueError('cassette tree changed during HTTP worker replay')
            counts = {kind: sum(n for (_, k), n in requests.items() if k == kind)
                      for kind in ('model', 'jev')}
            result = {'http': rows, 'artifact_sha256': artifacts,
                             'cassette_tree_sha256': audit['tape_tree_sha256'],
                             'request_counts': counts,
                             'requests': [{'sha256': sha, 'kind': kind, 'count': count}
                                          for (sha, kind), count in sorted(requests.items())],
                             'worker': {'mode': app.WORKER.mode, 'concurrency': 12,
                                        'alive_after_stop': app.WORKER.is_alive(),
                                        'last_error': app.WORKER.last_error}}
            assert_public(canonical(result), known_secrets())
            write_json(out, result)


def build_receipt() -> dict:
    require_reference_runtime()
    original = file_hashes(SOURCE)
    original_code = code_hashes()
    manifest = json.loads((ROOT / 'oracle/corpus/manifest.json').read_text())['files']
    expected = {name.removeprefix('snapshots/aq_complete/'): entry['sha256']
                for name, entry in manifest.items() if name.startswith('snapshots/aq_complete/')}
    if original != expected:
        raise ValueError('HTTP worker source differs from its corpus manifest')
    verify_book(REFERENCE)
    audit = verify_cassettes(CASSETTES)
    reference = json.loads((REFERENCE / 'provenance.json').read_text())['artifact_sha256']
    status = json.loads((REFERENCE / 'status.json').read_text())
    runs = []
    with tempfile.TemporaryDirectory(prefix='thusfar-http-process-pair-') as scratch:
        for seed in ('1', '982451653'):
            output = Path(scratch) / (seed + '.json')
            process = subprocess.run(
                [sys.executable, '-m', 'oracle.record.http_process_replay', '--capture',
                 '--out', str(output)], cwd=ROOT, env={**os.environ, 'PYTHONHASHSEED': seed},
                capture_output=True, timeout=120)
            if process.returncode:
                raise RuntimeError(f'HTTP worker replay failed for seed {seed}: '
                                   + process.stderr.decode(errors='replace')[-3000:])
            run = json.loads(output.read_text())
            if run['cassette_tree_sha256'] != audit['tape_tree_sha256']:
                raise ValueError('HTTP worker runs used different cassette trees')
            validate_run(run, reference, status)
            runs.append(run)
    if canonical(runs[0]) != canonical(runs[1]):
        raise ValueError('independent HTTP process lifecycle recordings differ')
    if file_hashes(SOURCE) != original:
        raise ValueError('HTTP worker replay changed its source fixture')
    if verify_cassettes(CASSETTES) != audit:
        raise ValueError('cassette tree changed between HTTP worker replays')
    if code_hashes() != original_code:
        raise ValueError('controlling code changed between HTTP worker replays')
    return {'schema': 1, 'source': 'actual Python HTTP handler and thread worker; offline live-tape replay',
            'scope': 'Aq only; subprocess worker and other books are outside this receipt',
            'passes': 2, 'hash_seeds': ['1', '982451653'], 'source_sha256': original,
            'code_sha256': original_code,
            'normalizations': ['Date and Server headers omitted; Content-Length checked on raw bytes then omitted',
                               'status only: shared book artifact time-field normalization'],
            **runs[0]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--write', action='store_true')
    action.add_argument('--verify', action='store_true')
    action.add_argument('--capture', action='store_true', help=argparse.SUPPRESS)
    parser.add_argument('--out', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    require_reference_runtime()
    if args.capture:
        if args.out is None:
            parser.error('--capture requires --out')
        capture(args.out)
        return
    receipt = build_receipt()
    if args.write:
        if GOLDEN.exists():
            raise FileExistsError('HTTP process receipt exists; review before replacing it')
        write_json(GOLDEN, receipt)
    elif GOLDEN.read_bytes() != (canonical(receipt) + '\n').encode():
        raise ValueError('HTTP process receipt differs from independent replay')
    print('HTTP process: queued to done through real thread worker; 154 artifact hashes and '
          'three HTTP responses match in two independent offline processes')


if __name__ == '__main__':
    main()
