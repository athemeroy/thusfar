"""Record every server.app route against an isolated book and a reusable HTTP/1.1 connection."""
from __future__ import annotations

import argparse
import base64
import hashlib
import http.client
import json
import os
import re
import shutil
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from .common import UnsafeValue, canonical, digest, known_secrets, write_json, write_jsonl
from .functions import LoopbackOnly

ROOT = Path(__file__).resolve().parents[2]
ILLUSTRATED_EPUB = ROOT / 'oracle/corpus/synthetic/footnote_illustration.epub'
_HEADERS = ('content-type', 'cache-control', 'etag', 'content-encoding', 'content-disposition',
            'content-length', 'x-content-type-options', 'x-yedu-release', 'connection',
            'retry-after', 'content-security-policy', 'vary', 'set-cookie')


def route_cases(book: dict) -> list[dict]:
    length = book.get('len') or 0
    manual_name = next((block['t'][:4] for block in book.get('blocks', [])
                        if block.get('k') in ('p', 'h') and len(block.get('t', '').strip()) >= 4), '原文')
    return [
        {'id': 'healthz', 'method': 'GET', 'path': '/healthz'},
        {'id': 'healthz-head', 'method': 'HEAD', 'path': '/healthz'},
        {'id': 'static', 'method': 'GET', 'path': '/icon.svg'},
        {'id': 'static-root', 'method': 'GET', 'path': '/'},
        {'id': 'static-304', 'method': 'GET', 'path': '/', 'etag_from': 'static-root'},
        {'id': 'static-gzip', 'method': 'GET', 'path': '/js/reader.js',
         'headers': {'Accept-Encoding': 'gzip'}},
        {'id': 'static-missing', 'method': 'GET', 'path': '/missing.js'},
        {'id': 'login', 'method': 'POST', 'path': '/api/login', 'json': {'code': ''}},
        {'id': 'me', 'method': 'GET', 'path': '/api/me'},
        {'id': 'cross-origin', 'method': 'POST', 'path': '/api/logout',
         'json': {}, 'headers': {'Origin': 'https://cross-origin.invalid'}},
        {'id': 'logout', 'method': 'POST', 'path': '/api/logout', 'json': {}},
        {'id': 'health', 'method': 'GET', 'path': '/api/health'},
        {'id': 'settings-get', 'method': 'GET', 'path': '/api/settings'},
        {'id': 'settings-test', 'method': 'POST', 'path': '/api/settings/test', 'json': {}},
        {'id': 'settings-put', 'method': 'PUT', 'path': '/api/settings',
         'json': {'base_url': 'https://open.xiaojingai.com', 'model': 'deepseek-flash',
                  'api_key': ''}},
        {'id': 'reading-list-get', 'method': 'GET', 'path': '/api/reading-list'},
        {'id': 'reading-list-put', 'method': 'PUT', 'path': '/api/reading-list',
         'json': {'items': ['{bid}'], 'operation': 'oracleop0001', 'expected_revision': 0}},
        {'id': 'reading-list-after-put', 'method': 'GET', 'path': '/api/reading-list'},
        {'id': 'reading-list-conflict', 'method': 'PUT', 'path': '/api/reading-list',
         'json': {'items': ['{bid}'], 'operation': 'oracleop0002', 'expected_revision': 0}},
        {'id': 'reading-list-invalid', 'method': 'PUT', 'path': '/api/reading-list', 'json': {}},
        {'id': 'unknown-api', 'method': 'GET', 'path': '/api/does-not-exist'},
        {'id': 'books-get', 'method': 'GET', 'path': '/api/books'},
        {'id': 'books-post', 'method': 'POST', 'path': '/api/books', 'raw': b'',
         'headers': {'X-Filename': 'empty.txt'}},
        {'id': 'books-upload-illustrated', 'method': 'POST', 'path': '/api/books',
         'raw_file': ILLUSTRATED_EPUB, 'headers': {'X-Filename': ILLUSTRATED_EPUB.name}},
        {'id': 'book-image-illustrated', 'method': 'GET',
         'path': '/api/books/{upload_bid}/img/{image_src}'},
        {'id': 'book-delete-illustrated', 'method': 'DELETE', 'path': '/api/books/{upload_bid}'},
        {'id': 'books-import', 'method': 'POST', 'path': '/api/books/import', 'json': {}},
        {'id': 'book-get', 'method': 'GET', 'path': '/api/books/{bid}'},
        {'id': 'book-head', 'method': 'HEAD', 'path': '/api/books/{bid}'},
        {'id': 'book-export', 'method': 'GET', 'path': '/api/books/{bid}/export'},
        {'id': 'book-offline-manifest', 'method': 'GET', 'path': '/api/books/{bid}/offline-manifest'},
        {'id': 'book-chapter', 'method': 'GET', 'path': '/api/books/{bid}/chapters/0'},
        {'id': 'book-kg', 'method': 'GET', 'path': f'/api/books/{{bid}}/kg?from=-1&to={length}'},
        {'id': 'book-manual-get', 'method': 'GET', 'path': f'/api/books/{{bid}}/manual-entities?to={length}'},
        {'id': 'book-manual-put', 'method': 'PUT', 'path': '/api/books/{bid}/manual-entities',
         'json': {'id': 'oracleitem01', 'kind': 'concept', 'name': manual_name,
                  'knowledge_cutoff': length, 'note': '标准答案用例', 'operation': 'oracleop0001'}},
        {'id': 'book-manual-after-put', 'method': 'GET', 'path': f'/api/books/{{bid}}/manual-entities?to={length}'},
        {'id': 'book-manual-invalid', 'method': 'PUT', 'path': '/api/books/{bid}/manual-entities', 'json': {}},
        {'id': 'book-notebook-get', 'method': 'GET', 'path': '/api/books/{bid}/notebook'},
        {'id': 'book-notebook-put', 'method': 'PUT', 'path': '/api/books/{bid}/notebook',
         'json': {'id': 'oraclenote01', 'kind': 'bookmark', 'start': 0, 'end': 0,
                  'quote': '', 'text': '', 'knowledge_cutoff': 0, 'operation': 'oracleop0002'}},
        {'id': 'book-notebook-after-put', 'method': 'GET', 'path': '/api/books/{bid}/notebook'},
        {'id': 'book-notebook-invalid', 'method': 'PUT', 'path': '/api/books/{bid}/notebook', 'json': {}},
        {'id': 'book-notebook-md', 'method': 'GET', 'path': '/api/books/{bid}/notebook.md'},
        {'id': 'book-progress', 'method': 'PUT', 'path': '/api/books/{bid}/progress',
         'json': {'pos': 0, 'cutoff': 0}},
        {'id': 'book-progress-post', 'method': 'POST', 'path': '/api/books/{bid}/progress',
         'json': {'pos': 1, 'cutoff': 1}},
        {'id': 'book-progress-conflict', 'method': 'PUT', 'path': '/api/books/{bid}/progress',
         'json': {'pos': 1, 'cutoff': 1, 'expected_t': 0}},
        {'id': 'book-kind', 'method': 'PUT', 'path': '/api/books/{bid}/kind', 'json': {'kind': 'novel'}},
        {'id': 'book-kind-invalid', 'method': 'PUT', 'path': '/api/books/{bid}/kind', 'json': {'kind': 'invalid'}},
        {'id': 'book-process-post', 'method': 'POST', 'path': '/api/books/{bid}/process', 'json': {}},
        {'id': 'book-process-delete', 'method': 'DELETE', 'path': '/api/books/{bid}/process'},
        {'id': 'book-who', 'method': 'POST', 'path': '/api/books/{bid}/who',
         'json': {'pos': -1, 'start': 0, 'end': 1}},
        {'id': 'book-who-no-person', 'method': 'POST', 'path': '/api/books/{bid}/who',
         'json': {'pos': 0, 'start': 0, 'end': 0}},
        {'id': 'book-marginalia', 'method': 'POST', 'path': '/api/books/{bid}/marginalia', 'json': {}},
        {'id': 'book-marginalia-empty-cues', 'method': 'POST',
         'path': '/api/books/{bid}/marginalia',
         'json': {'mode': 'cues', 'pos': 0, 'page_start': 0, 'page_end': 0}},
        {'id': 'book-marginalia-empty-cues-cached', 'method': 'POST',
         'path': '/api/books/{bid}/marginalia',
         'json': {'mode': 'cues', 'pos': 0, 'page_start': 0, 'page_end': 0}},
        {'id': 'book-ask', 'method': 'POST', 'path': '/api/books/{bid}/ask', 'json': {'q': '', 'pos': 0}},
        {'id': 'book-img', 'method': 'GET', 'path': '/api/books/{bid}/img/missing.png'},
        {'id': 'book-delete', 'method': 'DELETE', 'path': '/api/books/{bid}'},
        {'id': 'books-import-success', 'method': 'POST', 'path': '/api/books/import',
         'json_from': 'book-export'},
        {'id': 'books-import-duplicate', 'method': 'POST', 'path': '/api/books/import',
         'json_from': 'book-export'},
        {'id': 'book-delete-imported', 'method': 'DELETE', 'path': '/api/books/{import_bid}'},
    ]


def response_record(response: http.client.HTTPResponse, secrets: tuple[str, ...], method: str) -> dict:
    raw = response.read()
    if any(secret.encode() in raw for secret in secrets):
        raise UnsafeValue('HTTP body contains a credential')
    headers = {key: response.getheader(key) for key in _HEADERS if response.getheader(key) is not None}
    cookies = [value for key, value in response.getheaders() if key.lower() == 'set-cookie']
    if cookies:
        if len(cookies) != 1:
            raise UnsafeValue('HTTP response has multiple cookies; refusing to record them')
        parts = cookies[0].split(';')
        name, separator, value = parts[0].partition('=')
        if name != 'yedu' or not separator:
            raise UnsafeValue('HTTP response has an unexpected cookie')
        if value:
            parts[0] = 'yedu=<session>'
        headers['set-cookie'] = ';'.join(parts)
    if method != 'HEAD' and 'json' in (headers.get('content-type') or ''):
        body = json.loads(raw)
        if isinstance(body, dict):
            for key in ('pid', 'last_scan'):
                body.pop(key, None)
            if isinstance(body.get('worker'), dict):
                body['worker'].pop('pid', None)
                body['worker'].pop('last_scan', None)
        return {'status': response.status, 'headers': headers, 'body_json': body}
    return {'status': response.status, 'headers': headers,
            'body_base64': base64.b64encode(raw).decode('ascii')}


def route_family(path: str) -> str:
    """Group route cases by endpoint without hiding the HTTP method in the report."""
    path = urlsplit(path).path
    if path == '/healthz':
        return path
    if not path.startswith('/api/'):
        return 'static'
    if path in ('/api/books', '/api/books/import'):
        return path
    path = re.sub(r'^/api/books/[^/]+', '/api/books/{book}', path)
    path = re.sub(r'/chapters/\d+$', '/chapters/{chapter}', path)
    path = re.sub(r'/img/[^/]+$', '/img/{image}', path)
    return path


def substitute(text: str, references: dict[str, str]) -> str:
    for name, value in references.items():
        text = text.replace('{' + name + '}', value)
    unresolved = re.search(r'\{(?:bid|upload_bid|image_src|import_bid)\}', text)
    if unresolved:
        raise ValueError(f'route reference is unresolved: {unresolved.group()}')
    return text


def run_once(data: Path, bid: str) -> list[dict]:
    books = data / 'books'
    previous = dict(os.environ)
    os.environ.update(DATA_DIR=str(data), WEB_DIR=str(ROOT / 'web'), AUTO_PROCESS='0',
                      YEDU_LOCAL_MODE='1', SECRETS_FILE=str(data / '.model.env'), PASSCODE='',
                      COOKIE_SECURE='0')
    server = None
    original_time, original_time_ns = time.time, time.time_ns
    time.time = lambda: 1_750_000_000.0
    time.time_ns = lambda: 1_750_000_000_000_000_000
    try:
        from server import app
        # This CLI runs once per interpreter; refusing an already-imported server prevents it
        # from silently targeting a different DATA_DIR.
        if app.DATA != data:
            raise RuntimeError('server.app was imported before the isolated DATA_DIR was set')
        from server import jobs, storage
        app._cache = storage.JsonCache()
        app._login_attempts.clear()
        app._pos_cache.clear()
        app._static_cache.clear()
        app.WORKER = jobs.Worker(app.BOOKS, app.APP, app.cached_json, app.wjson, False)
        server = ThreadingHTTPServer(('127.0.0.1', 0), app.Handler)
        server.daemon_threads = True
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        book = json.loads((books / bid / 'book.json').read_text(encoding='utf-8'))
        rows = []
        references = {'bid': bid}
        prior_socket = None
        connection_number = 0
        secrets = known_secrets()
        with LoopbackOnly():
            conn = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=30)
            try:
                for case in route_cases(book):
                    if case['id'] == 'book-process-post':
                        # A fixed fake key makes this route exercise the successful body-discard
                        # path. The worker thread is never started, and the key is not recorded.
                        if app.WORKER.is_alive():
                            raise RuntimeError('HTTP oracle model worker unexpectedly started')
                        settings_file = data / '.model.env'
                        old_settings = settings_file.read_text(encoding='utf-8')
                        marker = 'LLM_API_KEY=\n'
                        if old_settings.count(marker) != 1:
                            raise RuntimeError('isolated model settings were unexpectedly changed')
                        settings_file.write_text(old_settings.replace(marker,
                                                                      'LLM_API_KEY=oracle-fixture-key\n'),
                                                 encoding='utf-8')
                    url = substitute(case['path'], references)
                    if 'json_from' in case:
                        source = next(row for row in rows if row['route'] == case['json_from'])
                        case_json = source['response']['body_json']
                    elif 'json' in case:
                        case_json = json.loads(substitute(canonical(case['json']), references))
                    else:
                        case_json = None
                    if case_json is not None:
                        payload = canonical(case_json).encode('utf-8')
                    elif 'raw_file' in case:
                        payload = case['raw_file'].read_bytes()
                    else:
                        payload = case.get('raw')
                    headers = {'Content-Type': 'application/json'} if case_json is not None else {}
                    headers.update(case.get('headers', {}))
                    if case.get('etag_from'):
                        source = next(row for row in rows if row['route'] == case['etag_from'])
                        headers['If-None-Match'] = source['response']['headers']['etag']
                    conn.request(case['method'], url, body=payload, headers=headers)
                    current_socket = conn.sock
                    reused = current_socket is prior_socket and current_socket is not None
                    if not reused:
                        connection_number += 1
                    prior_socket = current_socket
                    response = conn.getresponse()
                    if response.version != 11:
                        raise RuntimeError('HTTP oracle expected an HTTP/1.1 response')
                    reply = response_record(response, secrets, case['method'])
                    rows.append({'route': case['id'], 'request': {'method': case['method'], 'path': url,
                                 'headers': headers,
                                 'body_json': case_json} if case_json is not None else
                                 {'method': case['method'], 'path': url, 'headers': headers,
                                  'body_base64': base64.b64encode(payload or b'').decode('ascii')},
                                 'response': reply,
                                 'transport': {'http_version': 'HTTP/1.1',
                                               'connection': connection_number,
                                               'reused_previous': reused}})
                    if case['id'] == 'books-upload-illustrated':
                        uploaded = reply.get('body_json') or {}
                        expected_id = hashlib.sha1(payload).hexdigest()[:16]
                        if reply['status'] != 200 or uploaded.get('id') != expected_id:
                            raise ValueError('synthetic EPUB upload did not produce the expected book')
                        references['upload_bid'] = expected_id
                        uploaded_book = json.loads((books / expected_id / 'book.json').read_text(encoding='utf-8'))
                        images = [block['src'] for block in uploaded_book['blocks'] if block['k'] == 'img']
                        if not images or not (books / expected_id / 'img' / images[0]).is_file():
                            raise ValueError('synthetic EPUB upload produced no image file')
                        references['image_src'] = images[0]
                    if case['id'] == 'books-import-success':
                        imported = reply.get('body_json') or {}
                        if reply['status'] != 200 or not imported.get('id'):
                            raise ValueError('exported book could not be imported')
                        references['import_bid'] = imported['id']
                    if case['id'] == 'books-import-duplicate':
                        imported = reply.get('body_json') or {}
                        if reply['status'] != 200 or imported.get('id') != references['import_bid']:
                            raise ValueError('duplicate import did not identify the restored book')
            finally:
                conn.close()
        return rows
    finally:
        if server is not None:
            server.shutdown()
            server.server_close()
        os.environ.clear()
        os.environ.update(previous)
        time.time = original_time
        time.time_ns = original_time_ns


def reset_from_baseline(baseline: Path, data: Path, bid: str) -> None:
    if data.exists():
        shutil.rmtree(data)
    books = data / 'books'
    books.mkdir(parents=True)
    # Hard links keep every baseline file's inode stable through all passes. Route writes use
    # atomic replacement, so the baseline links remain untouched and can be reused.
    shutil.copytree(baseline, books / bid, copy_function=os.link, symlinks=False)


def tree_hashes(root: Path) -> dict[str, str]:
    hashes = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            raise UnsafeValue(f'HTTP source contains a symlink: {path.relative_to(root)}')
        if path.is_file():
            hashes[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


def coverage_report(rows: list[dict]) -> dict:
    families = {}
    for row in rows:
        request = row['request']
        family = route_family(request['path'])
        entry = families.setdefault(family, {'methods': set(), 'success': [], 'error': []})
        entry['methods'].add(request['method'])
        outcome = 'success' if row['response']['status'] < 400 else 'error'
        result = {'case': row['route'], 'status': row['response']['status']}
        body = row['response'].get('body_json')
        if isinstance(body, dict) and isinstance(body.get('ok'), bool):
            result['application_ok'] = body['ok']
        entry[outcome].append(result)
    return {name: {'methods': sorted(entry['methods']),
                   'success': entry['success'], 'error': entry['error']}
            for name, entry in sorted(families.items())}


def assert_route_acceptance(rows: list[dict]) -> list[dict]:
    by_id = {row['route']: row for row in rows}
    positions = {row['route']: index for index, row in enumerate(rows)}
    if len(by_id) != len(rows):
        raise ValueError('HTTP route case IDs are not unique')
    required_success = ('books-upload-illustrated', 'book-image-illustrated',
                        'book-export', 'books-import-success', 'books-import-duplicate',
                        'book-process-post', 'book-process-delete', 'book-who-no-person',
                        'book-marginalia-empty-cues', 'book-marginalia-empty-cues-cached')
    for route_id in required_success:
        if by_id[route_id]['response']['status'] != 200:
            raise ValueError(f'HTTP success case failed: {route_id}')
    no_person = by_id['book-who-no-person']['response']['body_json']
    if no_person != {'ok': False, 'why': 'nobody yet'}:
        raise ValueError('who route unexpectedly contacted a model for the empty world')
    cues = by_id['book-marginalia-empty-cues']['response']['body_json']
    cached_cues = by_id['book-marginalia-empty-cues-cached']['response']['body_json']
    if cues.get('items') != [] or cues.get('cached') is not False or \
            cached_cues != {**cues, 'cached': True}:
        raise ValueError('empty marginalia cues did not use the deterministic cache path')
    pairs = [('books-upload-illustrated', 'book-image-illustrated'),
             ('book-process-post', 'book-process-delete'),
             ('book-marginalia-empty-cues', 'book-marginalia-empty-cues-cached'),
             ('books-import-success', 'books-import-duplicate')]
    proof = []
    for first, second in pairs:
        left, right = by_id[first], by_id[second]
        if positions[second] != positions[first] + 1:
            raise ValueError(f'HTTP keepalive pair is not consecutive: {first}, {second}')
        if not right['transport']['reused_previous'] or \
                left['transport']['connection'] != right['transport']['connection']:
            raise ValueError(f'HTTP/1.1 connection was not reused: {first}, {second}')
        proof.append({'first': first, 'second': second,
                      'connection': right['transport']['connection']})
    return proof


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('book', type=Path, help='isolated corpus book directory, named by book id')
    parser.add_argument('--baseline', type=Path, required=True,
                        help='persistent private snapshot reused across independent recorder invocations')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--repeat', type=int, default=2)
    args = parser.parse_args()
    if not (args.book / 'book.json').is_file():
        parser.error('book directory must contain book.json')
    if args.repeat < 2:
        parser.error('at least two passes are required before publishing route goldens')
    source = args.book.resolve()
    baseline = args.baseline.resolve()
    if source == baseline or source in baseline.parents or baseline in source.parents:
        parser.error('--baseline must be separate from the source book')
    source_hashes = tree_hashes(source)
    if not baseline.exists():
        baseline.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source, baseline, symlinks=False)
    if tree_hashes(baseline) != source_hashes:
        raise ValueError('persistent HTTP baseline differs from source book; keep the original for repeat recordings')
    with tempfile.TemporaryDirectory(prefix='thusfar-http-oracle-', dir=baseline.parent) as temp:
        workspace = Path(temp)
        data = workspace / 'data'
        observed = []
        for _ in range(args.repeat):
            reset_from_baseline(baseline, data, args.book.name)
            observed.append(run_once(data, args.book.name))
            if tree_hashes(baseline) != source_hashes:
                raise ValueError('HTTP route mutated a hard-linked baseline file in place')
        rows = observed[0]
        for index, other in enumerate(observed[1:], 2):
            if rows != other:
                changed = [first['route'] for first, second in zip(rows, other) if first != second]
                raise ValueError(f'HTTP pass {index} differs in: {", ".join(changed)}')
        keepalive_proof = assert_route_acceptance(rows)
    write_jsonl(args.out, rows)
    write_json(args.out.with_name(args.out.stem + '-report.json'), {
        'schema': 2, 'routes': len(rows), 'passes': args.repeat,
        'clock_unix_seconds': 1_750_000_000,
        'recorded_response_sha256': digest([row['response'] for row in rows]),
        'normalizations': ['Nonempty yedu session cookie value is replaced with <session>; attributes are retained',
                           'volatile worker pid and last_scan fields are omitted from health JSON'],
        'source_inode_policy': 'Independent invocations and passes hard-link the same persistent baseline files',
        'synthetic_epub_sha256': hashlib.sha256(ILLUSTRATED_EPUB.read_bytes()).hexdigest(),
        'fixture_state': ['A fixed fake model key is written only to the isolated settings file '
                          'immediately before process POST; no model worker is started'],
        'families': coverage_report(rows),
        'transport': {'version': 'HTTP/1.1',
                      'connections': max(row['transport']['connection'] for row in rows),
                      'reused_requests': sum(row['transport']['reused_previous'] for row in rows),
                      'asserted_same_connection_pairs': keepalive_proof},
        'known_success_gaps': ['POST /api/settings/test has HTTP 200 but application ok=false; '
                               'model success needs a cassette',
                               'POST /api/books/{book}/who model-selected identity needs a JEV cassette',
                               'POST /api/books/{book}/marginalia generated comments need model/JEV cassettes',
                               'POST /api/books/{book}/ask needs cassette-backed SSE success'],
        'other_unrecorded_branches': ['passcode-protected login and 401 responses',
                                      'nonlocal mode hides model settings routes',
                                      'concurrent 429 responses and timeout 408 responses',
                                      'successful model worker execution',
                                      'additional malformed request bodies and image asset variants'],
    })
    print(f'recorded {len(rows)} HTTP route responses; {args.repeat} passes byte-identical')


if __name__ == '__main__':
    main()
