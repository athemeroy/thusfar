"""Freeze fixture-authored Aq notebook revisions through the real 1.7.5 HTTP routes.

The source is the public-domain aq_complete snapshot. This is generated API evidence,
not a historical person's notebook. Both generation passes block provider sockets.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import http.client as http_client
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from contextlib import ExitStack, contextmanager
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from oracle.record.common import canonical, known_secrets, require_reference_runtime, write_json
from oracle.record.functions import LoopbackOnly
from oracle.record.http_routes import response_record
from oracle.record.scan import scan

from oracle.corpus.annotate_snapshot import BOOK_ID, PINNED_CODE_SHA256, files

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]
SOURCE = ROOT / 'snapshots/aq_complete'
TARGET = ROOT / 'snapshots/aq_notebook_history'
GOLDEN = REPO / 'oracle/goldens/http/aq_notebook_history.json'
STAMPS = (1_790_294_400.0, 1_790_294_460.0, 1_790_294_520.0,
          1_790_294_580.0, 1_790_294_640.0)
CODE_PATHS = (*PINNED_CODE_SHA256, 'oracle/corpus/notebook_history.py',
              'oracle/corpus/annotate_snapshot.py', 'oracle/corpus/build.py',
              'oracle/record/common.py', 'oracle/record/scan.py',
              'oracle/record/http_routes.py', 'oracle/record/functions.py')
VERSION_NORMALIZATION = ('GET /export body_json.version: validated against the actual '
                         'snapshot_version(book) before and after the request, then replaced '
                         'with a 64-hex SHA-256 of the same source files\' relative paths and bytes; '
                         'the wire Content-Length and 64-character type remain unchanged')
SHELF_NORMALIZATION = ('The isolated server creates shelf.json as an inode-stamped read '
                       'cache. Validate its source signature and derived book fields, then '
                       'exclude it from the distributable source-plus-notebook snapshot.')


def sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def file_sha(root: Path) -> dict[str, str]:
    return {name: sha(raw) for name, raw in files(root).items()}


def code_sha() -> dict[str, str]:
    return {name: sha((REPO / name).read_bytes()) for name in CODE_PATHS}


def check_inputs() -> dict[str, bytes]:
    require_reference_runtime()
    if SOURCE.is_symlink() or TARGET.is_symlink() or GOLDEN.is_symlink() or \
            any(p.is_symlink() for p in SOURCE.rglob('*')) or \
            (TARGET.exists() and any(p.is_symlink() for p in TARGET.rglob('*'))):
        raise ValueError('Aq notebook source, target, or receipt is linked')
    for name, expected in PINNED_CODE_SHA256.items():
        if sha((REPO / name).read_bytes()) != expected:
            raise ValueError(f'Python 1.7.5 notebook handler changed: {name}')
    source = files(SOURCE)
    if len(source) != 48 or 'notebook.json' in source or 'book.json' not in source:
        raise ValueError('expected the original 48-file Aq snapshot without personal notes')
    manifest = json.loads((ROOT / 'manifest.json').read_text(encoding='utf-8'))['files']
    for name, raw in source.items():
        if manifest.get('snapshots/aq_complete/' + name) != {'bytes': len(raw), 'sha256': sha(raw)}:
            raise ValueError(f'Aq source differs from its frozen corpus entry: {name}')
    return source


def provenance() -> dict:
    source = check_inputs()
    return {
        'origin': 'public-domain aq_complete copy; fixture-authored notes written and exported/imported by the actual Python 1.7.5 HTTP API',
        'state': 'done with two independent note IDs, latest revisions and one tombstone',
        'rights': 'public-domain source text; historical model output; MIT fixture-authored notes',
        'personal_data': False,
        'history_limit': 'the 1.7.5 notebook stores only each ID\'s latest revision, not all prior text bodies',
        'source_sha256': {name: sha(raw) for name, raw in source.items()},
        'code_sha256': code_sha(),
        'normalizations': [VERSION_NORMALIZATION, SHELF_NORMALIZATION],
    }


def note(book: dict, note_id: str, start: int, end: int, text: str, operation: str,
         expected_revision: int, *, cutoff: int = 900, deleted: bool = False) -> dict:
    from server import notebook
    quote = notebook.source_quote(book, start, end)
    return {'id': note_id, 'kind': 'note', 'start': start, 'end': end,
            'quote': quote, 'text': text, 'knowledge_cutoff': cutoff,
            'operation': operation, 'expected_revision': expected_revision,
            'deleted': deleted}


def stable_export_version(book_root: Path) -> str:
    """Use the same file set as snapshot_version, with stable content instead of inode."""
    paths = [book_root / (name + '.json') for name in ('book', 'kg', 'status')]
    paths += sorted((book_root / 'mentions').glob('*.json'))
    paths += sorted((book_root / 'img').glob('*'))
    h = hashlib.sha256()
    for path in paths:
        if path.is_file():
            h.update(path.relative_to(book_root).as_posix().encode('utf-8') + b'\0')
            h.update(hashlib.sha256(path.read_bytes()).digest())
    return h.hexdigest()


@contextmanager
def server_for(data: Path, stamp: list[float]):
    """Run an isolated local library; no worker or nonloopback sockets are available."""
    if 'server.app' in sys.modules and not hasattr(server_for, '_first_import_done'):
        raise RuntimeError('notebook fixture needs a fresh interpreter for app import')
    with LoopbackOnly(), patch.dict(os.environ, {'DATA_DIR': str(data), 'WEB_DIR': str(data / 'web'),
                              'YEDU_LOCAL_MODE': '1', 'AUTO_PROCESS': '0',
                              'YEDU_WORKER_MODE': 'thread', 'YEDU_RELEASE_ID': '1.7.5',
                              'PASSCODE': '', 'COOKIE_SECURE': '0',
                              'NAS_DEFAULT_KEY': '', 'LLM_API_KEY': ''}):
        from server import app, jobs, notebook, storage
        server_for._first_import_done = True
        if app.RELEASE != '1.7.5':
            raise ValueError('notebook fixture requires Python server 1.7.5')
        (data / 'web').mkdir(exist_ok=True)
        with ExitStack() as stack:
            values = {'DATA': data, 'BOOKS': data / 'books', 'WEB': data / 'web',
                      'PASSCODE': '', 'SECRET_FILE': data / '.cookie-secret',
                      'COOKIE_SECURE': False, '_cache': storage.JsonCache(),
                      '_pos_cache': app.OrderedDict(), '_login_attempts': app.OrderedDict(),
                      'WORKER': jobs.Worker(data / 'books', app.APP, app.cached_json,
                                            app.wjson, enabled=False)}
            for name, value in values.items():
                stack.enter_context(patch.object(app, name, value))
            stack.enter_context(patch.object(app, 'time', SimpleNamespace(time=lambda: stamp[0])))
            stack.enter_context(patch.object(notebook, 'time', SimpleNamespace(time=lambda: stamp[0])))
            server = app.BoundedHTTPServer(('127.0.0.1', 0), app.Handler)
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            try:
                yield app, notebook, server.server_port
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)
                if thread.is_alive():
                    raise RuntimeError('notebook fixture loopback server did not stop')


def http(port: int, route: str, method: str, path: str, body: dict | None = None) -> tuple[dict, dict]:
    conn = http_client.HTTPConnection('127.0.0.1', port, timeout=20)
    payload = None if body is None else canonical(body).encode('utf-8')
    headers = {} if body is None else {'Content-Type': 'application/json'}
    try:
        conn.request(method, path, body=payload, headers=headers)
        response = conn.getresponse()
        if response.version != 11:
            raise ValueError('notebook history route did not use HTTP/1.1')
        if route == 'export':
            raw_read = response.read
            declared_length = response.getheader('Content-Length')

            def checked_read():
                raw = raw_read()
                if declared_length != str(len(raw)):
                    raise ValueError('export wire Content-Length differs from actual response bytes')
                return raw

            response.read = checked_read
        reply = response_record(response, known_secrets(), method, route)
    finally:
        conn.close()
    request = {'method': method, 'path': path}
    if body is not None:
        request['body_json'] = body
    return {'route': route, 'request': request, 'response': reply,
            'transport': {'http_version': 'HTTP/1.1'}}, reply.get('body_json')


def accepted(row: dict, status: int, keys: set[str]) -> dict:
    reply = row['response']
    body = reply.get('body_json')
    if reply['status'] != status or not isinstance(body, dict) or set(body) != keys or \
            reply['headers'].get('content-type') != 'application/json; charset=utf-8' or \
            reply['headers'].get('x-yedu-release') != '1.7.5':
        raise ValueError(f'notebook HTTP contract changed at {row["route"]}')
    return body


def one_pass(snapshot_out: Path, receipt_out: Path) -> None:
    source = check_inputs()
    if snapshot_out.exists() or receipt_out.exists():
        raise FileExistsError('one-pass notebook output exists')
    with tempfile.TemporaryDirectory(prefix='thusfar-aq-notebook-history-') as scratch:
        temp = Path(scratch)
        original_data = temp / 'original'
        book_root = original_data / 'books' / BOOK_ID
        book_root.parent.mkdir(parents=True)
        shutil.copytree(SOURCE, book_root)
        book = json.loads((book_root / 'book.json').read_text(encoding='utf-8'))
        stamps = [STAMPS[0]]
        rows = []
        route = f'/api/books/{BOOK_ID}/notebook'
        with server_for(original_data, stamps) as (app, notebook, port):
            first = note(book, 'fixture-aq-history-note-a', 14, 22, '第一处：重读正传的起笔。',
                         'fixture-aq-history-op-a1', 0)
            second = note(book, 'fixture-aq-history-note-b', 820, 847,
                          '第二处：留意冲突的动作。', 'fixture-aq-history-op-b1', 0)
            if first['quote'] != '我要给阿Q做正传' or \
                    second['quote'] != '阿Q不开口，想往后退了；赵太爷跳过去，给了他一个嘴巴。':
                raise ValueError('Aq UTF-16 note anchors changed')
            row, body = http(port, 'initial-get', 'GET', route)
            if accepted(row, 200, {'items'}) != {'items': []}:
                raise ValueError('fixture source already contains notebook records')
            rows.append(row)
            row, body = http(port, 'put-first', 'PUT', route, first)
            first_item = accepted(row, 200, {'item'})['item']
            if (first_item['revision'], first_item['created'], first_item['updated'],
                    first_item['deleted']) != (1, STAMPS[0], STAMPS[0], False):
                raise ValueError('first note was not created as revision 1')
            rows.append(row)
            first_raw = (book_root / 'notebook.json').read_bytes()
            first_stat = (book_root / 'notebook.json').stat()
            stamps[0] = STAMPS[1]
            row, body = http(port, 'idempotent-retry', 'PUT', route, first)
            if accepted(row, 200, {'item'})['item'] != first_item or \
                    (book_root / 'notebook.json').read_bytes() != first_raw or \
                    (book_root / 'notebook.json').stat().st_mtime_ns != first_stat.st_mtime_ns:
                raise ValueError('same operation rewrote a note or changed its response')
            rows.append(row)
            row, body = http(port, 'put-independent', 'PUT', route, second)
            second_item = accepted(row, 200, {'item'})['item']
            if second_item['revision'] != 1 or second_item['created'] != STAMPS[1]:
                raise ValueError('independent note did not get its own revision 1')
            rows.append(row)
            stamps[0] = STAMPS[2]
            edited = dict(first, operation='fixture-aq-history-op-a2', expected_revision=1,
                          text='第一处：修订后的想法。', knowledge_cutoff=1000)
            row, body = http(port, 'edit-first', 'PUT', route, edited)
            edited_item = accepted(row, 200, {'item'})['item']
            if (edited_item['revision'], edited_item['created'], edited_item['updated'],
                    edited_item['knowledge_cutoff']) != (2, STAMPS[0], STAMPS[2], 1000):
                raise ValueError('first note edit lost revision, creation time or cutoff')
            rows.append(row)
            before_stale = (book_root / 'notebook.json').read_bytes()
            stale = dict(first, operation='fixture-aq-history-op-a-stale',
                         expected_revision=1, text='不得覆盖新修订。')
            row, body = http(port, 'stale-conflict', 'PUT', route, stale)
            if accepted(row, 409, {'error', 'item'}) != {
                    'error': '这条摘记已在其他设备修改', 'item': edited_item} or \
                    (book_root / 'notebook.json').read_bytes() != before_stale:
                raise ValueError('stale revision was not rejected without a write')
            rows.append(row)
            stamps[0] = STAMPS[3]
            tombstone = dict(second, operation='fixture-aq-history-op-b2',
                             expected_revision=1, deleted=True)
            row, body = http(port, 'tombstone-second', 'PUT', route, tombstone)
            tombstone_item = accepted(row, 200, {'item'})['item']
            if (tombstone_item['revision'], tombstone_item['created'],
                    tombstone_item['updated'], tombstone_item['deleted']) != \
                    (2, STAMPS[1], STAMPS[3], True):
                raise ValueError('second note tombstone did not preserve its revision')
            rows.append(row)
            row, body = http(port, 'final-get', 'GET', route)
            final_items = accepted(row, 200, {'items'})['items']
            if final_items != [edited_item, tombstone_item]:
                raise ValueError('final notebook does not retain both independent note IDs')
            rows.append(row)
            row, body = http(port, 'markdown-excludes-tombstone', 'GET',
                             f'/api/books/{BOOK_ID}/notebook.md')
            markdown = base64.b64decode(row['response']['body_base64'], validate=True).decode('utf-8')
            if row['response']['status'] != 200 or edited_item['text'] not in markdown or \
                    tombstone_item['text'] in markdown:
                raise ValueError('Markdown view does not exclude the tombstone')
            rows.append(row)
            stamps[0] = STAMPS[4]
            version_before = app.snapshot_version(book_root)
            row, body = http(port, 'export', 'GET', f'/api/books/{BOOK_ID}/export')
            export = accepted(row, 200, {
                'format', 'exported', 'id', 'book', 'kg', 'meta', 'status',
                'mentions', 'assets', 'progress', 'notebook', 'manual_entities', 'version',
            })
            if export.get('format') != 'yedu-book/2' or export.get('notebook') != final_items or \
                    export.get('version') != version_before or \
                    app.snapshot_version(book_root) != version_before or \
                    export.get('exported') != STAMPS[4]:
                raise ValueError('actual export lost notebook state or source version relation')
            stable_version = stable_export_version(book_root)
            if len(export['version']) != len(stable_version) or len(stable_version) != 64:
                raise ValueError('export version normalization changed the wire token width')
            row['response']['body_json'] = dict(export, version=stable_version)
            rows.append(row)
        imported_data = temp / 'imported'
        (imported_data / 'books').mkdir(parents=True)
        with server_for(imported_data, stamps) as (app, notebook, port):
            row, body = http(port, 'empty-library', 'GET', '/api/books')
            if row['response']['status'] != 200 or body != [] or \
                    any((imported_data / 'books').iterdir()):
                raise ValueError('import target was not genuinely empty')
            rows.append(row)
            row, body = http(port, 'import-into-empty-library', 'POST', '/api/books/import', export)
            # The request is the exact raw export above; record that relationship without
            # duplicating the environment-specific version token in the golden.
            row['request'] = {'method': 'POST', 'path': '/api/books/import',
                              'body_from': 'raw preceding GET /export response'}
            imported = row['response']['body_json']
            summary_keys = {'added', 'author', 'auto', 'chapters', 'cover', 'est',
                            'genre', 'id', 'lang', 'len', 'progress', 'spent',
                            'status', 'thin', 'title'}
            if row['response']['status'] != 200 or not isinstance(imported, dict) or \
                    set(imported) != summary_keys or not isinstance(imported.get('id'), str):
                raise ValueError('empty-library import failed')
            imported_id = imported['id']
            imported_root = imported_data / 'books' / imported_id
            if not (imported_root / 'book.json').is_file() or \
                    json.loads((imported_root / 'notebook.json').read_text()) != final_items:
                raise ValueError('import did not actually create and restore the source notebook')
            rows.append(row)
            row, body = http(port, 'imported-notebook-get', 'GET',
                             f'/api/books/{imported_id}/notebook')
            if accepted(row, 200, {'items'})['items'] != final_items:
                raise ValueError('imported notebook GET lost revisions or tombstone')
            rows.append(row)
            before_retry = (imported_root / 'notebook.json').read_bytes()
            row, body = http(port, 'idempotent-import', 'POST', '/api/books/import', export)
            row['request'] = {'method': 'POST', 'path': '/api/books/import',
                              'body_from': 'same raw preceding GET /export response'}
            if row['response']['status'] != 200 or \
                    set(row['response']['body_json']) != summary_keys or \
                    row['response']['body_json']['id'] != imported_id or \
                    (imported_root / 'notebook.json').read_bytes() != before_retry:
                raise ValueError('duplicate import changed the restored notebook')
            rows.append(row)
        from server import storage
        shelf = book_root / 'shelf.json'
        if shelf.is_file():
            cache = json.loads(shelf.read_text(encoding='utf-8'))
            if cache != {'source': list(storage.signature(book_root / 'book.json')),
                         'book': storage.shelf_fields(book)}:
                raise ValueError('runtime shelf cache is not derived from the unchanged source')
            shelf.unlink()
        expected_source = source | {'notebook.json': (book_root / 'notebook.json').read_bytes()}
        actual_source = files(book_root)
        if actual_source != expected_source:
            changed = sorted(name for name in set(actual_source) | set(expected_source)
                             if actual_source.get(name) != expected_source.get(name))
            raise ValueError(f'notebook HTTP sequence changed original Aq paths: {changed}')
        if json.loads((book_root / 'notebook.json').read_text()) != final_items:
            raise ValueError('persisted notebook differs from final HTTP GET')
        shutil.copytree(book_root, snapshot_out)
        write_json(receipt_out, {
            'schema': 1, 'source': 'fixture-authored Aq notebook via real Python 1.7.5 HTTP API',
            'historical_personal_data': False, 'source_sha256': {name: sha(raw) for name, raw in source.items()},
            'code_sha256': code_sha(),
            'normalizations': [VERSION_NORMALIZATION, SHELF_NORMALIZATION],
            'events': rows, 'final_notebook_sha256': sha((book_root / 'notebook.json').read_bytes()),
            'imported_notebook_sha256': sha((imported_root / 'notebook.json').read_bytes()),
            'source_files_preserved': len(source), 'import_target_initially_empty': True,
            'version_relation_verified': True,
        })
        scan(snapshot_out)
        scan(receipt_out.parent)


def double_generate(root: Path) -> tuple[dict[str, bytes], bytes]:
    outputs = []
    for seed in ('1', '982451653'):
        snapshot = root / ('snapshot-' + seed)
        receipt = root / (seed + '.json')
        result = subprocess.run(
            [sys.executable, '-m', 'oracle.corpus.notebook_history', '--one-pass',
             str(snapshot), str(receipt)], cwd=REPO,
            env={**os.environ, 'PYTHONHASHSEED': seed}, capture_output=True,
            timeout=120, check=False,
        )
        if result.returncode:
            raise RuntimeError(f'notebook history pass {seed} failed; no fixture published')
        outputs.append((files(snapshot), receipt.read_bytes()))
    if outputs[0] != outputs[1]:
        changed = sorted(name for name in set(outputs[0][0]) | set(outputs[1][0])
                         if outputs[0][0].get(name) != outputs[1][0].get(name))
        raise ValueError(f'independent notebook histories differ: snapshot paths={changed}, '
                         f'HTTP receipt equal={outputs[0][1] == outputs[1][1]}')
    return outputs[0]


def verify() -> None:
    check_inputs()
    with tempfile.TemporaryDirectory(prefix='thusfar-aq-notebook-history-verify-') as tmp:
        expected, receipt = double_generate(Path(tmp))
    if files(TARGET) != expected or not GOLDEN.is_file() or GOLDEN.read_bytes() != receipt:
        raise ValueError('committed notebook history differs from two real HTTP generations')
    source = files(SOURCE)
    if len(expected) != len(source) + 1 or any(expected.get(name) != raw for name, raw in source.items()):
        raise ValueError('committed notebook history changed an original Aq source file')
    scan(TARGET)
    scan(GOLDEN.parent)
    print(f'Verified Aq notebook history: {len(expected)} files, 14 HTTP events, two byte-identical API runs')


def write() -> None:
    check_inputs()
    if TARGET.exists() or GOLDEN.exists():
        raise FileExistsError('notebook history fixture already exists; review before replacing')
    with tempfile.TemporaryDirectory(prefix='thusfar-aq-notebook-history-write-') as tmp:
        expected, receipt = double_generate(Path(tmp))
        TARGET.mkdir(parents=True)
        for name, raw in expected.items():
            path = TARGET / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(raw)
        GOLDEN.parent.mkdir(parents=True, exist_ok=True)
        GOLDEN.write_bytes(receipt)
    from . import build
    build.write_manifest()
    verify()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--write', action='store_true')
    group.add_argument('--verify', action='store_true')
    group.add_argument('--one-pass', nargs=2, metavar=('SNAPSHOT', 'RECEIPT'), help=argparse.SUPPRESS)
    args = parser.parse_args()
    require_reference_runtime()
    if args.one_pass:
        one_pass(Path(args.one_pass[0]), Path(args.one_pass[1]))
    elif args.write:
        write()
    else:
        verify()


if __name__ == '__main__':
    main()
