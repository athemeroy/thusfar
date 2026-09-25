"""Freeze a public-domain 阿Q partial replay paused and annotated by the 1.7.5 API.

The four-segment work directory comes only from the checked-in DeepSeek/JEV cassette.
The real Python server then handles DELETE /process and PUT /notebook on an isolated
loopback copy. Each published file is compared across two separate interpreters.
This is a replay/API-generated compatibility fixture, not a historical user's notes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from contextlib import ExitStack
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from oracle.record.artifacts import one_pass, snapshot, stage_book
from oracle.record.common import require_reference_runtime
from oracle.record.functions import LoopbackOnly
from oracle.record.scan import scan
from oracle.record.verify_live_cassettes import verify as verify_cassettes

if __package__:
    from .annotate_snapshot import (BOOK_ID, PINNED_CODE_SHA256, SOURCE, STAMP,
                                    files, request)
else:
    from annotate_snapshot import (BOOK_ID, PINNED_CODE_SHA256, SOURCE, STAMP,
                                   files, request)


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]
TARGET = ROOT / 'snapshots/aq_paused_annotated'
CASSETTES = REPO / 'oracle/cassettes/live'
CASSETTE_AUDIT = REPO / 'oracle/record/live-a0-audit.json'
LIMIT = 4
PINNED_REPLAY_SHA256 = {
    'pipeline/run.py': '24a8ac0bb5268dcfadbdcff9fbcd398b54c1634feaa51fe7eae7b5963358857f',
    'pipeline/llm.py': 'fbfe37508d962af7c36d503983ba52aa7d6fc840d79cfa70b008c7983b9b9675',
    'pipeline/link.py': '672378817e72934f756f85d88deabddb698b95cd1815641727c5c2f7cc1622b3',
    'pipeline/kg.py': '64a971a252aabceb85ef801964e86302811b81e023d3209032c50f03581c2994',
    'oracle/record/artifacts.py': '71be6e82dc81f9a9f1ab5bcbbaeee8c2d8aa0ae2024108aed3cf942303f54815',
    'oracle/record/cassettes.py': 'bd832be47df60f8cc54d9b7ead14dd670eed796deba2390887cfd20a07560b4b',
}


def _sha(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def _check_inputs() -> None:
    require_reference_runtime()
    if SOURCE.is_symlink() or TARGET.is_symlink() or any(path.is_symlink() for path in SOURCE.rglob('*')) \
            or (TARGET.exists() and any(path.is_symlink() for path in TARGET.rglob('*'))):
        raise ValueError('Aq corpus source or target contains a symlink')
    for name, expected in {**PINNED_CODE_SHA256, **PINNED_REPLAY_SHA256}.items():
        if _sha((REPO / name).read_bytes()) != expected:
            raise ValueError(f'pinned 1.7.5 replay/API code changed: {name}')
    manifest = json.loads((ROOT / 'manifest.json').read_text(encoding='utf-8'))
    for name in ('book.json', 'source.txt'):
        relative = 'snapshots/aq_complete/' + name
        raw = (SOURCE / name).read_bytes()
        if manifest['files'][relative] != {'bytes': len(raw), 'sha256': _sha(raw)}:
            raise ValueError(f'public-domain Aq source differs from corpus manifest: {name}')
    if (SOURCE / 'notebook.json').exists():
        raise ValueError('Aq source has personal annotations')
    expected_audit = json.loads(CASSETTE_AUDIT.read_text(encoding='utf-8'))
    if verify_cassettes(CASSETTES) != expected_audit:
        raise ValueError('reviewed live cassette receipt differs from current tape')


def _allowed(name: str) -> bool:
    if name in {'book.json', 'kg.json', 'status.json', 'source.txt', 'notebook.json'}:
        return True
    return name.endswith('.json') and (name.startswith('work/') or name.startswith('mentions/'))


def _api_pause_and_note(book_root: Path, temp: Path) -> None:
    # server.app constructs its default Worker at import time. Pin its import
    # environment before loading it, even when the caller has hostile settings.
    with patch.dict(os.environ, {'DATA_DIR': str(temp), 'WEB_DIR': str(temp / 'web'),
                                'AUTO_PROCESS': '0', 'YEDU_WORKER_MODE': 'process',
                                'YEDU_RELEASE_ID': '1.7.5', 'PASSCODE': '',
                                'COOKIE_SECURE': '0'}):
        from server import app, jobs, notebook, storage

    if app.RELEASE != '1.7.5':
        raise ValueError('paused snapshot requires the Python 1.7.5 HTTP API')
    book = json.loads((book_root / 'book.json').read_text(encoding='utf-8'))
    before = json.loads((book_root / 'status.json').read_text(encoding='utf-8'))
    if (before.get('state'), before.get('done'), before.get('total')) != ('running', LIMIT, 9):
        raise ValueError('partial cassette replay did not stop after four of nine segments')
    block = next(b for b in book['blocks'] if b['k'] == 'p' and '阿Q' in b['t'] and len(b['t']) > 30)
    quote = block['t'][:18]
    start = block['o']
    end = start + len(quote.encode('utf-16-le')) // 2
    if end > before['frontier']:
        raise ValueError('fixture note is beyond the replayed reading frontier')
    note = {
        'id': 'fixture-aq-paused-note-0001', 'kind': 'note', 'start': start,
        'end': end, 'quote': quote, 'text': '暂停后重读这一句。',
        'knowledge_cutoff': end, 'operation': 'fixture-aq-paused-op-0001',
        'expected_revision': 0,
    }
    web = temp / 'web'
    web.mkdir()
    with ExitStack() as stack:
        stack.enter_context(patch.dict(os.environ, {'YEDU_WORKER_MODE': 'process'}))
        values = {
            'DATA': temp, 'BOOKS': temp / 'books', 'WEB': web, 'PASSCODE': '',
            'SECRET_FILE': temp / '.cookie-secret', 'COOKIE_SECURE': False,
            '_cache': storage.JsonCache(), '_pos_cache': app.OrderedDict(),
            '_login_attempts': app.OrderedDict(),
            'WORKER': jobs.Worker(temp / 'books', app.APP, app.cached_json, app.wjson,
                                  enabled=False),
        }
        for name, value in values.items():
            stack.enter_context(patch.object(app, name, value))
        stack.enter_context(patch.object(jobs, 'time', SimpleNamespace(time=lambda: STAMP)))
        stack.enter_context(patch.object(notebook, 'time', SimpleNamespace(time=lambda: STAMP)))
        server = app.BoundedHTTPServer(('127.0.0.1', 0), app.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f'/api/books/{BOOK_ID}'
            with LoopbackOnly():
                code, reply = request(server.server_port, 'DELETE', base + '/process')
                if code != 200 or reply.get('status', {}).get('state') != 'paused':
                    raise ValueError('Python 1.7.5 process DELETE did not pause the replayed book')
                code, accepted = request(server.server_port, 'PUT', base + '/notebook', note)
                if code != 200 or accepted.get('item', {}).get('revision') != 1:
                    raise ValueError('Python 1.7.5 notebook PUT did not create revision 1')
                code, reread = request(server.server_port, 'GET', base + '/notebook')
                if code != 200 or reread != {'items': [accepted['item']]}:
                    raise ValueError('Python 1.7.5 notebook GET differs from the accepted write')
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)
    after = json.loads((book_root / 'status.json').read_text(encoding='utf-8'))
    saved = json.loads((book_root / 'notebook.json').read_text(encoding='utf-8'))
    if (after['state'], after['done'], after['total'], after['frontier']) != \
            ('paused', LIMIT, 9, before['frontier']):
        raise ValueError('pause changed the completed segment frontier')
    if saved != reread['items'] or saved[0]['created'] != STAMP or \
            saved[0]['quote'] != notebook.source_quote(book, start, end):
        raise ValueError('paused note lost its deterministic source anchor')


def one_snapshot(out: Path) -> None:
    _check_inputs()
    if out.exists():
        raise FileExistsError(f'one-pass output exists: {out}')
    with tempfile.TemporaryDirectory(prefix='thusfar-aq-paused-replay-') as scratch:
        temp = Path(scratch)
        working = temp / 'replay'
        stage_book(SOURCE, working, 'fresh')
        one_pass(working, CASSETTES, concurrency=1, limit=LIMIT)
        book_root = temp / 'books' / BOOK_ID
        snapshot(working, book_root)
        shutil.copy2(working / 'source.txt', book_root / 'source.txt')
        _api_pause_and_note(book_root, temp)
        source_files = files(book_root)
        selected = {name: raw for name, raw in source_files.items() if _allowed(name)}
        required = {'book.json', 'kg.json', 'status.json', 'source.txt', 'notebook.json'} | \
            {f'work/segs/{index:04d}.json' for index in range(LIMIT)}
        if not required <= set(selected) or \
                any(name.startswith('work/segs/') and name not in required for name in selected):
            raise ValueError('paused snapshot has a missing or extra segment file')
        out.mkdir(parents=True)
        for name, raw in selected.items():
            target = out / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
        scan(out)


def double_snapshot(temp: Path) -> dict[str, bytes]:
    outputs = []
    for index in range(2):
        output = temp / f'pass-{index}'
        result = subprocess.run([sys.executable, '-m', 'oracle.corpus.paused_annotated_snapshot',
                                 '--one-pass', str(output)], cwd=REPO, capture_output=True,
                                text=True, timeout=120)
        if result.returncode != 0:
            raise RuntimeError(f'paused Aq cassette/API pass {index + 1} failed; no fixture published')
        outputs.append(files(output))
    if outputs[0] != outputs[1]:
        names = sorted(set(outputs[0]) | set(outputs[1]))
        changed = [name for name in names if outputs[0].get(name) != outputs[1].get(name)]
        raise ValueError(f'paused Aq independent passes differ: {changed}')
    return outputs[0]


def verify() -> None:
    with tempfile.TemporaryDirectory(prefix='thusfar-aq-paused-verify-') as scratch:
        expected = double_snapshot(Path(scratch))
    actual = files(TARGET)
    if expected != actual:
        names = sorted(set(expected) | set(actual))
        changed = [name for name in names if expected.get(name) != actual.get(name)]
        raise ValueError(f'committed paused Aq fixture differs from replay/API output: {changed}')
    scan(TARGET)
    print(f'Verified paused+annotated Aq: {len(actual)} files, 4/9 cassette segments, two byte-identical independent replays')


def write() -> None:
    with tempfile.TemporaryDirectory(prefix='thusfar-aq-paused-write-') as scratch:
        expected = double_snapshot(Path(scratch))
    if TARGET.exists():
        if files(TARGET) == expected:
            return
        raise FileExistsError('paused Aq fixture changed; review before replacing it')
    with tempfile.TemporaryDirectory(prefix='.thusfar-aq-paused-stage-', dir=ROOT / 'snapshots') as scratch:
        staged = Path(scratch) / 'snapshot'
        staged.mkdir()
        for name, raw in expected.items():
            path = staged / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(raw)
        scan(staged)
        os.replace(staged, TARGET)
    verify()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    choices = parser.add_mutually_exclusive_group(required=True)
    choices.add_argument('--one-pass', type=Path, help=argparse.SUPPRESS)
    choices.add_argument('--verify', action='store_true')
    choices.add_argument('--write', action='store_true')
    args = parser.parse_args()
    if args.one_pass is not None:
        one_snapshot(args.one_pass)
    elif args.write:
        write()
    else:
        verify()


if __name__ == '__main__':
    main()
