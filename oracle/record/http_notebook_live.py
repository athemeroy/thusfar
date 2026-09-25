"""Opt-in real HTTP receipts for Aq who, manual marginalia, and ask.

The production HTTP handlers and model client run unchanged. Record uses only the
reviewed DeepSeek and keyless classifier routes. Replay and verify are offline.
An intent and an fsynced outbound journal survive an interrupted original call.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import http.client
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import uuid
from contextlib import contextmanager, nullcontext
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from typing import Callable

from .cassettes import CassetteStore, install, live_request_allowed, request_envelope
from .common import assert_public, canonical, digest, known_secrets, require_reference_runtime, write_json, write_jsonl
from .functions import LoopbackOnly
from .http_model_live import (BASE_URL, LIVE_CASSETTES, MODEL, assert_no_key_suffix,
                              assert_tape_no_key_suffix, exclusive_live_lock,
                              isolated_settings, load_home_key, no_redirect_transport)
from .http_routes import ROOT, response_record, tree_hashes
from .scan import scan
from .verify_live_cassettes import verify as verify_live_cassettes

SOURCE = ROOT / 'oracle/corpus/snapshots/aq_complete'
BOOK_ID = SOURCE.name
FREE_URL = 'https://classifier.dev/v1/classify'
MODEL_URL = BASE_URL + '/chat/completions'
FIXED_CLOCK = 1_750_000_000.0
FIXED_KG_REVISION = (1_730_000_000_123_456_789, 481, 73)
FIXED_BOOK_MTIME_NS = 1_730_000_000_987_654_321
FIXED_BOOK_INODE = 73
ASK_QUESTION = '读到这里，阿Q经历了什么？'
QUOTE = '阿Q不开口，想往后退了；赵太爷跳过去，给了他一个嘴巴。'
REJECTED_MARGINALIA_TASK_ID = 'd2f9bc10e6104a8ab8a344425653bac7'
REJECTED_MARGINALIA_ERROR = '这条批注没有通过已读内容核对，已替你隐藏'
REJECTED_MARGINALIA_ATTEMPT_SHA256 = '96e3fad858c56505cb1a88467ee06c026ca037dd8060e68ce483ebd2b9076a86'
CASES = {
    'who': {'id': 'who-person-live', 'path': f'/api/books/{BOOK_ID}/who',
            'body': {'pos': 900, 'start': 751, 'end': 753}, 'model_cap': 0, 'jev_cap': 2},
    'marginalia': {'id': 'marginalia-manual-live',
                   'path': f'/api/books/{BOOK_ID}/marginalia',
                   'body': {'mode': 'manual', 'pos': 900, 'start': 820, 'end': 847,
                            'persona': 'empathy'}, 'model_cap': 2, 'jev_cap': 4},
    'ask': {'id': 'ask-answer-live', 'path': f'/api/books/{BOOK_ID}/ask',
            'body': {'q': ASK_QUESTION, 'pos': 900}, 'model_cap': 2, 'jev_cap': 8},
}
_PRIVATE_ENV = {'QA_MODEL': MODEL, 'MARGINALIA_MODEL': MODEL,
                'MARGINALIA_AUTO_MODEL': MODEL, 'JUDGE_CACHE': '0',
                'JUDGE_RETRIEVAL': '1', 'QUERY_TRANSLATION': '1',
                'JEV_FREE_RETRIES': '1'}


def source_hashes() -> dict[str, str]:
    """Match the complete fixed source snapshot, including its absence of note cache."""
    actual = tree_hashes(SOURCE)
    manifest = json.loads((ROOT / 'oracle/corpus/manifest.json').read_text())['files']
    expected = {name.removeprefix('snapshots/aq_complete/'): row['sha256']
                for name, row in manifest.items() if name.startswith('snapshots/aq_complete/')}
    if actual != expected or 'marginalia.json' in actual:
        raise ValueError('Aq HTTP source differs from its checked-in corpus manifest')
    return actual


def _assert_request(route: str, row: dict) -> None:
    case = CASES[route]
    if row.get('route') != case['id'] or row.get('request') != {
            'method': 'POST', 'path': case['path'],
            'headers': {'Content-Type': 'application/json'}, 'body_json': case['body']}:
        raise ValueError('live notebook HTTP request differs from the reviewed case')
    if row.get('transport') != {'http_version': 'HTTP/1.1'}:
        raise ValueError('live notebook HTTP transport is not HTTP/1.1')


def _assert_case(route: str, row: dict) -> None:
    _assert_request(route, row)
    response = row.get('response') or {}
    if response.get('status') != 200 or (route != 'ask' and
            response.get('headers', {}).get('x-yedu-release') != '1.7.5'):
        raise ValueError('live notebook HTTP route did not return a 1.7.5 HTTP 200')


def _sse_events(row: dict) -> list[tuple[str, dict]]:
    response = row['response']
    if response['headers'].get('content-type') != 'text/event-stream; charset=utf-8':
        raise ValueError('ask route did not return an SSE response')
    raw = base64.b64decode(response['body_base64'], validate=True).decode('utf-8')
    events = []
    for chunk in raw.strip().split('\n\n'):
        lines = chunk.splitlines()
        if len(lines) != 2 or not lines[0].startswith('event: ') or not lines[1].startswith('data: '):
            raise ValueError('ask route emitted a malformed SSE event')
        payload = json.loads(lines[1][6:])
        if not isinstance(payload, dict):
            raise ValueError('ask SSE payload is not an object')
        events.append((lines[0][7:], payload))
    return events


def assert_success(route: str, rows: list[dict], outbound: list[dict],
                   first_count: int, tape_count: int, secrets: tuple[str, ...]) -> None:
    """Require observed provider-backed behavior; never infer success from HTTP 200 alone."""
    case = CASES[route]
    ids = [case['id']] + ([case['id'] + '-cached'] if route == 'marginalia' else [])
    if [row.get('route') for row in rows] != ids:
        raise ValueError('live notebook route sequence differs')
    for row in rows:
        _assert_case(route, row) if row['route'] == case['id'] else _assert_case(
            route, {**row, 'route': case['id']})
    kinds = [entry['kind'] for entry in outbound]
    if (not 1 <= kinds.count('jev') <= case['jev_cap']
            or kinds.count('model') > case['model_cap']
            or tape_count != len(outbound)):
        raise ValueError('live notebook provider call count differs from route bounds')
    if route != 'who' and not 1 <= kinds.count('model') <= case['model_cap']:
        raise ValueError('live notebook route consumed no paid model response')
    if route == 'marginalia' and first_count != tape_count:
        raise ValueError('cached marginalia request unexpectedly called a provider')
    if route == 'who':
        body = rows[0]['response'].get('body_json')
        if (rows[0]['response']['headers'].get('content-type') != 'application/json; charset=utf-8'
                or not isinstance(body, dict) or set(body) != {'ok', 'id', 'name', 'p', 'word'}
                or body['ok'] is not True or body['id'] != 'P2' or body['name'] != '阿Q'
                or body['word'] != '阿Q' or type(body['p']) not in (float, int)
                or not math.isfinite(body['p']) or body['p'] < .45):
            raise ValueError('who route did not resolve the selected Aq identity')
    elif route == 'marginalia':
        first, cached = (row['response'].get('body_json') for row in rows)
        from server.marginalia import _clean
        if (any(row['response']['headers'].get('content-type') != 'application/json; charset=utf-8'
                for row in rows) or not isinstance(first, dict) or not isinstance(cached, dict)
                or set(first) != {'key', 'comment', 'start', 'end', 'quote', 'persona', 'kind',
                                  'score', 'guard', 'position', 'knowledge_cutoff', 'created', 'cached'}
                or not re.fullmatch(r'[0-9a-f]{32}', str(first['key']))
                or first['start'] != 820 or first['end'] != 847 or first['quote'] != QUOTE
                or first['position'] != 900 or first['knowledge_cutoff'] != 847
                or first['persona'] != 'empathy' or first['kind'] != 'manual'
                or first['score'] != 1.0 or first['created'] != FIXED_CLOCK
                or first['cached'] is not False or cached != {**first, 'cached': True}
                or not isinstance(first['comment'], str) or not first['comment'].strip()
                or _clean(first['comment']) != first['comment']
                or not isinstance(first['guard'], dict)
                or first['guard'].get('verdict') not in ('ok', 'rewritten')
                or type(first['guard'].get('p')) not in (float, int)
                or not math.isfinite(first['guard']['p'])
                or not .4 <= first['guard']['p'] <= 1):
            raise ValueError('marginalia did not publish and reuse a guarded real comment')
    else:
        events = _sse_events(rows[0])
        answers = [payload for kind, payload in events if kind == 'answer']
        routes = [payload for kind, payload in events if kind == 'route']
        if (any(kind == 'error' for kind, _ in events) or len(answers) != 1 or len(routes) != 1
                or routes[0].get('route') not in ('who', 'relation', 'recap', 'why', 'other')
                or not isinstance(answers[0].get('text'), str)
                or not answers[0]['text'].strip() or answers[0].get('position') != 900
                or answers[0].get('route') != routes[0].get('route')
                or not isinstance(answers[0].get('cites'), list)
                or not isinstance(answers[0].get('people'), list)
                or not isinstance(answers[0].get('guard'), dict)
                or answers[0]['guard'].get('verdict') not in ('ok', 'rewritten')
                or type(answers[0]['guard'].get('p')) not in (float, int)
                or not math.isfinite(answers[0]['guard']['p'])
                or not .4 <= answers[0]['guard']['p'] <= 1
                or answers[0].get('ms') != 0):
            raise ValueError('ask route did not return a supported real SSE answer')
    assert_public(canonical(rows), secrets)


class ReviewedOpener:
    """Refuse an unexpected prompt, route, or already recorded digest before transport."""

    def __init__(self, underlying, store: CassetteStore, mode: str, route: str,
                 seen: list[dict], journal: Path | None, secrets: tuple[str, ...], lock: threading.Lock):
        self.underlying, self.store, self.mode, self.route = underlying, store, mode, route
        self.seen, self.journal, self.secrets, self.lock = seen, journal, secrets, lock

    def open(self, request, timeout=None):
        envelope = request_envelope(request, self.secrets)
        kind = live_request_allowed(envelope, request)
        body = json.loads(envelope['body_utf8'])
        case = CASES[self.route]
        if kind == 'model':
            marker = ASK_QUESTION if self.route == 'ask' else QUOTE
            cap = 1200 if self.route == 'ask' else 160
            messages = body.get('messages') or []
            if (self.route == 'who' or envelope['url'] != MODEL_URL
                    or body.get('max_tokens') != cap or body.get('stream') is not True
                    or body.get('thinking') != {'type': 'disabled'}
                    or not isinstance(messages, list) or not any(
                        isinstance(message, dict) and message.get('role') == 'user'
                        and marker in str(message.get('content', '')) for message in messages)):
                raise ValueError('live notebook route attempted an unreviewed model prompt')
        elif (envelope['url'] != FREE_URL or not isinstance(body.get('items'), list)
              or not isinstance(body.get('dimensions'), dict)):
            raise ValueError('live notebook route attempted an unreviewed JEV prompt')
        sha = digest(envelope)
        with self.lock:
            if sum(row['kind'] == kind for row in self.seen) >= case[kind + '_cap']:
                raise RuntimeError('live notebook route reached its provider attempt cap')
            if self.mode == 'record' and kind == 'model' and any(
                    row['sha256'] == sha for row in self.seen):
                raise FileExistsError('paid notebook request repeated within route; reconcile original')
            if self.mode == 'record' and self.store.path(envelope).exists() and not any(
                    row['sha256'] == sha for row in self.seen):
                raise FileExistsError('request already has a cassette; reconcile rather than repeat')
            row = {'sha256': sha, 'kind': kind}
            self.seen.append(row)
            if self.journal is not None:
                with self.journal.open('a', encoding='utf-8') as stream:
                    stream.write(canonical(row) + '\n')
                    stream.flush()
                    os.fsync(stream.fileno())
        return self.underlying.open(request, timeout=timeout)


@contextmanager
def notebook_environment(key: str, data: Path):
    """Pin route options without letting an ambient judge cache or key hide a call."""
    previous = {name: os.environ.get(name) for name in _PRIVATE_ENV}
    with isolated_settings(key, data):
        os.environ.update(_PRIVATE_ENV)
        from pipeline import llm
        previous_env, previous_classifier = llm._env, llm.CLASSIFIER_URL
        llm.CLASSIFIER_URL = FREE_URL
        llm._env = lambda name: None if name == 'CLASSIFIER_KEY' else previous_env(name)
        try:
            yield
        finally:
            llm._env, llm.CLASSIFIER_URL = previous_env, previous_classifier
            for name, value in previous.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value


@contextmanager
def controlled_notebook_modules(route: str):
    """Control response clocks, manual wording, and copied-file inode inputs."""
    from server import ask, marginalia, storage
    old_ask_time, old_note_time = ask.time, marginalia.time
    old_choice, old_signature = marginalia.random.choice, storage.signature
    ask.time = SimpleNamespace(time=lambda: FIXED_CLOCK)
    marginalia.time = SimpleNamespace(time=lambda: FIXED_CLOCK)
    def stable_signature(path):
        name = Path(path).name
        if name == 'book.json':
            _mtime, size, _inode = old_signature(path)
            return FIXED_BOOK_MTIME_NS, size, FIXED_BOOK_INODE
        if route == 'marginalia' and name == 'kg.json':
            return FIXED_KG_REVISION
        return old_signature(path)

    storage.signature = stable_signature
    if route == 'marginalia':
        marginalia.random.choice = lambda items: (items[0] if items is marginalia.COMMENT_STYLES
                                                 else old_choice(items))
    try:
        yield
    finally:
        ask.time, marginalia.time = old_ask_time, old_note_time
        marginalia.random.choice, storage.signature = old_choice, old_signature


def _send(connection: http.client.HTTPConnection, case: dict, case_id: str,
          secrets: tuple[str, ...]) -> dict:
    connection.request('POST', case['path'], body=canonical(case['body']).encode('utf-8'),
                       headers={'Content-Type': 'application/json'})
    response = connection.getresponse()
    if response.version != 11:
        raise ValueError('notebook route did not use HTTP/1.1')
    return {'route': case_id,
            'request': {'method': 'POST', 'path': case['path'],
                        'headers': {'Content-Type': 'application/json'}, 'body_json': case['body']},
            'response': response_record(response, secrets, 'POST', case_id),
            'transport': {'http_version': 'HTTP/1.1'}}


def _assert_no_key_tail_in_row(row: dict, key: str) -> None:
    """Inspect decoded SSE too, since its base64 text may conceal a masked key tail."""
    assert_no_key_suffix(canonical(row), key)
    encoded = row.get('response', {}).get('body_base64')
    if encoded is not None:
        assert_no_key_suffix(base64.b64decode(encoded, validate=True), key)


def exercise(route: str, mode: str, cassettes: Path, key: str, work: Path,
             journal: Path | None = None,
             on_observation: Callable[[dict], None] | None = None,
             ) -> tuple[list[dict], list[dict], int, int, dict[str, str]]:
    """Run exactly one source-backed route in a fresh interpreter and working copy."""
    if route not in CASES or mode not in ('record', 'replay'):
        raise ValueError('unknown notebook route or cassette mode')
    if 'server.app' in sys.modules or 'server.ask' in sys.modules or 'server.marginalia' in sys.modules:
        raise RuntimeError('notebook HTTP exercise requires a fresh Python interpreter')
    if work.exists() or work.is_symlink():
        raise FileExistsError('notebook HTTP working directory already exists')
    source_before = source_hashes()
    data = work / 'data'
    books = data / 'books'
    books.mkdir(parents=True)
    shutil.copytree(SOURCE, books / BOOK_ID, symlinks=False)
    if tree_hashes(books / BOOK_ID) != source_before:
        raise ValueError('notebook working source copy differs from checked-in Aq')
    if (books / BOOK_ID / 'marginalia.json').exists():
        raise ValueError('notebook source already contains a marginalia cache')
    with notebook_environment(key, data):
        from pipeline import llm
        from server import app, storage
        if (app.DATA != data or app.LOCAL_MODE is not True or app.AUTO is not False
                or app.PASSCODE or app.BOOKS != books):
            raise RuntimeError('notebook server was imported outside the isolated data directory')
        app._cache = storage.JsonCache()
        app._pos_cache.clear()
        app._static_cache.clear()
        seen: list[dict] = []
        gate_lock = threading.Lock()
        case = CASES[route]
        with controlled_notebook_modules(route), no_redirect_transport(), \
                install(cassettes, mode, max_model_attempts=case['model_cap'],
                        max_jev_attempts=case['jev_cap'], max_cny=1.0) as tape, \
                (LoopbackOnly() if mode == 'replay' else nullcontext()):
            cassette_factory = llm._opener
            route_secrets = (*tape.secrets, key)
            llm._opener = lambda: ReviewedOpener(cassette_factory(), tape, mode, route,
                                                 seen, journal, route_secrets, gate_lock)
            server = None
            worker = None
            started = False
            try:
                server = ThreadingHTTPServer(('127.0.0.1', 0), app.Handler)
                # The server must join every in-flight route handler before the reviewed
                # opener, cassette store, isolated settings, and loopback guard unwind.
                server.daemon_threads = False
                worker = threading.Thread(target=server.serve_forever, daemon=False)
                worker.start()
                started = True
                connection = http.client.HTTPConnection('127.0.0.1', server.server_port,
                                                        timeout=210)
                try:
                    first = _send(connection, case, case['id'], route_secrets)
                    if on_observation is not None:
                        on_observation(first)
                    rows = [first]
                    first_count = tape.count
                    if route == 'marginalia' and first['response']['status'] == 200:
                        cached = _send(connection, case, case['id'] + '-cached', route_secrets)
                        if on_observation is not None:
                            on_observation(cached)
                        rows.append(cached)
                finally:
                    connection.close()
            finally:
                if server is not None:
                    if started:
                        server.shutdown()
                    server.server_close()
                if worker is not None and started:
                    worker.join()
                llm._opener = cassette_factory
            tape_count = tape.count
    if source_hashes() != source_before:
        raise ValueError('notebook HTTP recording changed its checked-in Aq input')
    return rows, seen, first_count, tape_count, tree_hashes(work)


def _read_intent(receipt: Path, cassettes: Path) -> dict:
    path = receipt / 'intent.json'
    if receipt.is_symlink() or path.is_symlink() or not path.is_file():
        raise ValueError('original notebook HTTP intent is missing or linked')
    intent = json.loads(path.read_text(encoding='utf-8'))
    if (not isinstance(intent, dict) or intent.get('schema') != 1
            or intent.get('route') not in CASES or intent.get('model') != MODEL
            or intent.get('base_url') != BASE_URL or intent.get('clock_unix_seconds') != FIXED_CLOCK
            or intent.get('case') != CASES[intent['route']]
            or intent.get('source_tree_sha256') != digest(source_hashes())
            or intent.get('cassette_tree_before_sha256') is None
            or intent.get('max_cny') != 1.0
            or not re.fullmatch(r'[0-9a-f]{32}', str(intent.get('task_id', '')))
            or not re.fullmatch(r'[0-9a-f]{64}', str(intent.get('source_tree_sha256', '')))):
        raise ValueError('notebook HTTP intent differs from its reviewed Aq route')
    if intent.get('cassette_logical') != 'oracle/cassettes/live':
        raise ValueError('notebook HTTP intent has the wrong shared cassette identity')
    assert_public(canonical(intent), known_secrets())
    return intent


def _outbound_rows(receipt: Path) -> list[dict]:
    path = receipt / 'outbound.jsonl'
    if path.is_symlink():
        raise ValueError('notebook outbound journal is linked')
    if not path.exists():
        return []
    rows = [json.loads(line) for line in path.read_text(encoding='utf-8').splitlines()]
    if any(not isinstance(row, dict) or set(row) != {'sha256', 'kind'}
           or not re.fullmatch(r'[0-9a-f]{64}', str(row.get('sha256', '')))
           or row.get('kind') not in ('model', 'jev') for row in rows):
        raise ValueError('notebook outbound journal has an invalid request')
    return rows


def _durable_json(path: Path, value: dict) -> None:
    write_json(path, value)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def _tape_hashes(cassettes: Path, outbound: list[dict]) -> dict[str, str]:
    hashes = {}
    for sha in sorted({row['sha256'] for row in outbound}):
        path = cassettes / (sha + '.json')
        if path.is_symlink() or not path.is_file():
            raise ValueError('observed notebook provider request has no regular cassette')
        hashes[sha] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


def _check_live_delta(cassettes: Path, before: dict, after: dict,
                      outbound: list[dict]) -> None:
    kinds = [row['kind'] for row in outbound]
    if (after['model_attempts'] != before['model_attempts'] + kinds.count('model')
            or after['free_jev_attempts'] != before['free_jev_attempts'] + kinds.count('jev')
            or after['budget']['guarded_charged_cny'] > 1.0
            or after['budget']['usage_unavailable'] != before['budget']['usage_unavailable']):
        raise ValueError('notebook live tape count, paid usage or shared ¥1 ledger changed unexpectedly')
    ledger = json.loads((cassettes / 'budget-ledger.json').read_text(encoding='utf-8'))
    for sha in {row['sha256'] for row in outbound if row['kind'] == 'model'}:
        entries = [row for row in ledger['entries'] if row.get('request_sha256') == sha]
        if (len(entries) != sum(row['sha256'] == sha and row['kind'] == 'model'
                               for row in outbound)
                or any(entry.get('state') != 'completed'
                       or type(entry.get('prompt_tokens')) is not int
                       or type(entry.get('completion_tokens')) is not int for entry in entries)):
            raise ValueError('notebook model success lacks completed token usage')


def _failure(receipt: Path, exc: Exception, key: str) -> None:
    message = str(exc)
    try:
        assert_public(message, known_secrets())
        assert_no_key_suffix(message, key)
    except Exception:
        message = '<redacted>'
    write_json(receipt / 'failure.json', {'schema': 1, 'state': 'original_attempt_not_published',
                                          'error_type': type(exc).__name__, 'message': message,
                                          'outbound_attempts': len(_outbound_rows(receipt))})


def record(route: str, cassettes: Path, receipt: Path) -> None:
    """Create one durable intent, then make at most one real HTTP route attempt."""
    if route not in CASES:
        raise ValueError('unknown notebook route')
    if cassettes.is_symlink() or cassettes.absolute() != LIVE_CASSETTES.absolute():
        raise ValueError('live notebook recording must share oracle/cassettes/live')
    if (receipt.exists() or receipt.is_symlink() or receipt.resolve(strict=False).is_relative_to(
            cassettes.resolve()) or receipt.resolve(strict=False).is_relative_to(SOURCE.resolve())):
        raise ValueError('notebook receipt must be new and outside cassette/source directories')
    with exclusive_live_lock(cassettes):
        before = verify_live_cassettes(cassettes)
        source = source_hashes()
        key = load_home_key(Path.home() / '.env')
        receipt.mkdir(mode=0o700, parents=False, exist_ok=False)
        intent = {'schema': 1, 'task_id': uuid.uuid4().hex, 'route': route,
                  'case': CASES[route], 'model': MODEL, 'base_url': BASE_URL,
                  'clock_unix_seconds': FIXED_CLOCK, 'source_tree_sha256': digest(source),
                  'cassette_logical': 'oracle/cassettes/live',
                  'cassette_origin': str(cassettes.resolve()),
                  'cassette_tree_before_sha256': before['tape_tree_sha256'],
                  'model_attempts_before': before['model_attempts'],
                  'free_jev_attempts_before': before['free_jev_attempts'],
                  'guarded_charge_before_cny': before['budget']['guarded_charged_cny'],
                  'max_cny': 1.0}
        _durable_json(receipt / 'intent.json', intent)
        journal = receipt / 'outbound.jsonl'
        attempt_path = receipt / 'attempt-http.jsonl'
        def save_attempt(row: dict) -> None:
            serialized = canonical(row)
            assert_public(serialized, (*known_secrets(), key))
            _assert_no_key_tail_in_row(row, key)
            with attempt_path.open('a', encoding='utf-8') as stream:
                stream.write(serialized + '\n')
                stream.flush()
                os.fsync(stream.fileno())

        try:
            rows, outbound, first_count, count, work_hashes = exercise(
                route, 'record', cassettes, key, receipt / 'work', journal, save_attempt)
            if _outbound_rows(receipt) != outbound:
                raise ValueError('durable outbound journal differs from observed cassette calls')
            assert_success(route, rows, outbound, first_count, count, (*known_secrets(), key))
            for sha in {row['sha256'] for row in outbound}:
                assert_tape_no_key_suffix(cassettes / (sha + '.json'), key)
            after = verify_live_cassettes(cassettes)
            _check_live_delta(cassettes, before, after, outbound)
            tapes = _tape_hashes(cassettes, outbound)
            live_path = receipt / 'live-http.jsonl'
            write_jsonl(live_path, rows)
            if live_path.read_bytes() != attempt_path.read_bytes():
                raise ValueError('accepted notebook HTTP rows differ from fsynced original attempts')
            scan(receipt)
            observation = {
                'schema': 1,
                'intent_sha256': hashlib.sha256((receipt / 'intent.json').read_bytes()).hexdigest(),
                'live_http_sha256': hashlib.sha256(live_path.read_bytes()).hexdigest(),
                'outbound_sha256': hashlib.sha256(journal.read_bytes()).hexdigest(),
                'outbound': outbound, 'tape_sha256': tapes,
                'work_file_sha256': work_hashes,
                'guarded_charge_after_cny': after['budget']['guarded_charged_cny'],
                'actual_provider_bill': 'unknown without gateway receipt',
            }
            assert_public(canonical(observation), (*known_secrets(), key))
            _durable_json(receipt / 'observation.json', observation)
        except Exception as exc:
            tape_failure = None
            for row in _outbound_rows(receipt):
                try:
                    assert_tape_no_key_suffix(cassettes / (row['sha256'] + '.json'), key)
                except Exception as unsafe:
                    tape_failure = tape_failure or unsafe
            _failure(receipt, tape_failure or exc, key)
            if tape_failure is not None:
                raise tape_failure from exc
            raise
    print(f'notebook HTTP {route} recorded; receipt={receipt}; '
          f'guarded_charge=¥{after["budget"]["guarded_charged_cny"]:.9f}; '
          'actual gateway bill unknown')


def _read_observation(receipt: Path, cassettes: Path) -> tuple[dict, dict, bytes]:
    intent = _read_intent(receipt, cassettes)
    paths = [receipt / name for name in ('observation.json', 'live-http.jsonl', 'outbound.jsonl')]
    if any(path.is_symlink() or not path.is_file() for path in paths):
        raise ValueError('successful notebook HTTP observation is missing or linked')
    observation = json.loads(paths[0].read_text(encoding='utf-8'))
    original = paths[1].read_bytes()
    attempt_path = receipt / 'attempt-http.jsonl'
    if attempt_path.is_symlink() or not attempt_path.is_file() or attempt_path.read_bytes() != original:
        raise ValueError('accepted notebook HTTP response differs from original attempt journal')
    if (observation.get('intent_sha256') != hashlib.sha256((receipt / 'intent.json').read_bytes()).hexdigest()
            or observation.get('live_http_sha256') != hashlib.sha256(original).hexdigest()
            or observation.get('outbound_sha256') != hashlib.sha256(paths[2].read_bytes()).hexdigest()
            or observation.get('outbound') != _outbound_rows(receipt)
            or observation.get('tape_sha256') != _tape_hashes(cassettes, observation['outbound'])
            or observation.get('work_file_sha256') != tree_hashes(receipt / 'work')):
        raise ValueError('notebook HTTP observation differs from its original source or cassette')
    assert_public(original.decode('utf-8'), known_secrets())
    return intent, observation, original


def _assert_first_marginalia_rejection(row: dict) -> None:
    _assert_request('marginalia', row)
    response = row.get('response') or {}
    if (response.get('status') != 400
            or response.get('headers', {}).get('content-type') != 'application/json; charset=utf-8'
            or response.get('headers', {}).get('x-yedu-release') != '1.7.5'
            or response.get('body_json') != {'error': REJECTED_MARGINALIA_ERROR}):
        raise ValueError('original marginalia first request is not the observed guard rejection')


def _read_rejected_marginalia(receipt: Path, cassettes: Path) -> tuple[dict, bytes, list[dict], dict[str, str]]:
    """Bind this proof to the original rejected task, including its erroneous follow-up."""
    intent = _read_intent(receipt, cassettes)
    if intent['route'] != 'marginalia' or intent['task_id'] != REJECTED_MARGINALIA_TASK_ID:
        raise ValueError('failure proof requires the original rejected marginalia task')
    if (receipt / 'observation.json').exists() or (receipt / 'live-http.jsonl').exists():
        raise ValueError('rejected marginalia receipt was incorrectly marked as success')
    attempt_path, failure_path, work = (receipt / 'attempt-http.jsonl',
                                        receipt / 'failure.json', receipt / 'work')
    if (any(path.is_symlink() or not path.is_file() for path in (attempt_path, failure_path))
            or work.is_symlink() or not work.is_dir()):
        raise ValueError('original marginalia failure receipt is incomplete or linked')
    raw = attempt_path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != REJECTED_MARGINALIA_ATTEMPT_SHA256:
        raise ValueError('marginalia failure attempt bytes differ from the original receipt')
    lines = raw.splitlines(keepends=True)
    if len(lines) != 2 or any(not line.endswith(b'\n') for line in lines):
        raise ValueError('original failure receipt must contain exactly two observed HTTP rows')
    first, second = (json.loads(line) for line in lines)
    if lines[0] != (canonical(first) + '\n').encode('utf-8') or lines[1] != (
            canonical(second) + '\n').encode('utf-8'):
        raise ValueError('original rejected HTTP rows lost canonical byte identity')
    _assert_first_marginalia_rejection(first)
    _assert_request('marginalia', {**second, 'route': CASES['marginalia']['id']})
    if (second.get('route') != CASES['marginalia']['id'] + '-cached'
            or second.get('response', {}).get('status') != 500
            or second['response'].get('body_json') != {'error': '服务器出错了'}):
        raise ValueError('original failed cached probe differs from the recorded harness consequence')
    outbound = _outbound_rows(receipt)
    failure = json.loads(failure_path.read_text(encoding='utf-8'))
    if (failure.get('state') != 'original_attempt_not_published'
            or failure.get('outbound_attempts') != 4
            or [row['kind'] for row in outbound] != ['model', 'jev', 'model', 'jev']):
        raise ValueError('original marginalia failure provider journal differs')
    work_hashes = tree_hashes(work)
    assert_public(raw.decode('utf-8'), known_secrets())
    return intent, lines[0], outbound, work_hashes


def reconcile(receipt: Path, cassettes: Path) -> dict:
    """Inspect the original attempt without retrying, modifying, or opening a socket."""
    intent = _read_intent(receipt, cassettes)
    if intent['cassette_origin'] != str(cassettes.resolve()):
        raise ValueError('reconcile must use the original cassette directory')
    outbound = _outbound_rows(receipt)
    ledger_path = cassettes / 'budget-ledger.json'
    if ledger_path.is_symlink() or not ledger_path.is_file():
        raise ValueError('original shared ledger is missing or linked')
    ledger = json.loads(ledger_path.read_text(encoding='utf-8'))
    details = []
    for row in outbound:
        sha = row['sha256']
        path = cassettes / (sha + '.json')
        if path.is_symlink():
            raise ValueError('original notebook cassette is linked')
        tape = json.loads(path.read_text(encoding='utf-8')) if path.is_file() else {}
        entries = [entry for entry in ledger['entries'] if entry.get('request_sha256') == sha]
        details.append({'sha256': sha, 'kind': row['kind'],
                        'attempt_kinds': [attempt.get('kind') for attempt in tape.get('attempts', [])],
                        'ledger_states': [entry.get('state') for entry in entries]})
    if (receipt / 'observation.json').exists():
        _read_observation(receipt, cassettes)
        state = 'observed_success'
    elif (receipt / 'attempt-http.jsonl').is_file():
        state = 'observed_http_not_accepted'
    elif any('pending' in row['attempt_kinds'] or 'reserved' in row['ledger_states']
             for row in details):
        state = 'pending_original_attempt'
    elif details:
        state = 'original_wire_attempt_without_http_observation'
    else:
        state = 'intent_without_provider_attempt'
    result = {'schema': 1, 'task_id': intent['task_id'], 'route': intent['route'],
              'state': state, 'requests': details,
              'next_action': 'Inspect original receipt and cassette; never blindly resubmit this route live.'}
    assert_public(canonical(result), known_secrets())
    return result


def replay(route: str, cassettes: Path, receipt: Path, out: Path) -> None:
    if out.exists() or out.is_symlink() or out.resolve(strict=False).is_relative_to(cassettes.resolve()):
        raise ValueError('offline notebook replay output must be new and outside cassettes')
    intent, observation, original = _read_observation(receipt, cassettes)
    if route != intent['route']:
        raise ValueError('offline notebook replay route differs from original intent')
    verify_live_cassettes(cassettes)
    with tempfile.TemporaryDirectory(prefix='thusfar-notebook-http-replay-') as temp:
        rows, outbound, first_count, count, work_hashes = exercise(
            route, 'replay', cassettes, 'oracle-placeholder', Path(temp) / 'work')
        assert_success(route, rows, outbound, first_count, count, (*known_secrets(), 'oracle-placeholder'))
        if outbound != observation['outbound'] or work_hashes != observation['work_file_sha256']:
            raise ValueError('offline notebook replay changed provider request or persisted state')
        data = ''.join(canonical(row) + '\n' for row in rows).encode('utf-8')
        if data != original:
            raise ValueError('offline notebook HTTP response differs from real observed response')
    write_jsonl(out, rows)


def replay_failure(route: str, cassettes: Path, receipt: Path, out: Path) -> None:
    """Replay only the original request; the old cached probe followed an HTTP 400."""
    if route != 'marginalia' or out.exists() or out.is_symlink() or out.resolve(
            strict=False).is_relative_to(cassettes.resolve()):
        raise ValueError('failure replay requires marginalia and a new output outside cassettes')
    _intent, original_first, original_outbound, original_work = _read_rejected_marginalia(
        receipt, cassettes)
    verify_live_cassettes(cassettes)
    with tempfile.TemporaryDirectory(prefix='thusfar-notebook-rejected-replay-') as temp:
        rows, outbound, first_count, count, work_hashes = exercise(
            'marginalia', 'replay', cassettes, 'oracle-placeholder', Path(temp) / 'work')
        if len(rows) != 1:
            raise ValueError('rejected marginalia replay sent the old cached follow-up')
        _assert_first_marginalia_rejection(rows[0])
        if (outbound != original_outbound or first_count != count or count != len(original_outbound)
                or work_hashes != original_work
                or (canonical(rows[0]) + '\n').encode('utf-8') != original_first):
            raise ValueError('rejected marginalia replay differs from original first HTTP or state')
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(original_first)


def verify_failure(route: str, cassettes: Path, receipt: Path, out: Path) -> None:
    """Publish the observed first 400 only after two exact, offline replays."""
    if route != 'marginalia' or out.exists() or out.is_symlink() or out.resolve(
            strict=False).is_relative_to(cassettes.resolve()):
        raise ValueError('failure verification requires marginalia and a new output outside cassettes')
    intent, original_first, outbound, work_hashes = _read_rejected_marginalia(receipt, cassettes)
    tapes_before = _tape_hashes(cassettes, outbound)
    with tempfile.TemporaryDirectory(prefix='thusfar-notebook-rejected-dual-') as temp:
        outputs = []
        for seed in ('1', '2'):
            path = Path(temp) / (seed + '.jsonl')
            result = subprocess.run(
                [sys.executable, '-m', 'oracle.record.http_notebook_live', 'replay-failure',
                 '--route', 'marginalia', '--cassettes', str(cassettes.resolve()),
                 '--receipt', str(receipt.resolve()), '--out', str(path)],
                cwd=ROOT, env={**os.environ, 'PYTHONHASHSEED': seed},
                capture_output=True, text=True, timeout=240, check=False)
            if result.returncode:
                raise RuntimeError(f'offline original marginalia rejection replay {seed} failed')
            outputs.append(path.read_bytes())
        if outputs != [original_first, original_first] or _tape_hashes(cassettes, outbound) != tapes_before:
            raise ValueError('original marginalia rejection and two independent replays differ')
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(original_first)
    write_json(out.with_name(out.stem + '-report.json'), {
        'schema': 1, 'source': 'observed real DeepSeek and free JEV marginalia application rejection',
        'classification': 'application_rejection_not_success', 'route': 'marginalia',
        'original_task_id': intent['task_id'], 'original_response_ordinal': 1,
        'original_http_status': 400,
        'original_attempt_http_sha256': REJECTED_MARGINALIA_ATTEMPT_SHA256,
        'original_first_response_sha256': hashlib.sha256(original_first).hexdigest(),
        'original_outbound': outbound, 'tape_sha256': tapes_before,
        'original_work_file_sha256': work_hashes,
        'excluded_original_followup': {
            'ordinal': 2, 'http_status': 500,
            'reason': 'old recorder sent a cached probe after the first 400; model attempt cap blocked it',
        },
        'passes': 2, 'hash_seeds': ['1', '2'],
        'new_provider_attempts': 0,
    })


def verify(route: str, cassettes: Path, receipt: Path, out: Path) -> None:
    if out.exists() or out.is_symlink() or out.resolve(strict=False).is_relative_to(cassettes.resolve()):
        raise ValueError('verified notebook HTTP golden output must be new and outside cassettes')
    intent, observation, original = _read_observation(receipt, cassettes)
    if route != intent['route']:
        raise ValueError('verified notebook route differs from original intent')
    with tempfile.TemporaryDirectory(prefix='thusfar-notebook-http-dual-') as temp:
        outputs = []
        for seed in ('1', '2'):
            path = Path(temp) / (seed + '.jsonl')
            result = subprocess.run(
                [sys.executable, '-m', 'oracle.record.http_notebook_live', 'replay',
                 '--route', route, '--cassettes', str(cassettes.resolve()),
                 '--receipt', str(receipt.resolve()), '--out', str(path)],
                cwd=ROOT, env={**os.environ, 'PYTHONHASHSEED': seed},
                capture_output=True, text=True, timeout=240, check=False)
            if result.returncode:
                raise RuntimeError(f'offline notebook HTTP replay pass {seed} failed; no golden written')
            outputs.append(path.read_bytes())
        if outputs[0] != outputs[1] or outputs[0] != original:
            raise ValueError('real notebook HTTP and two independent replays differ')
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(original)
    write_json(out.with_name(out.stem + '-report.json'), {
        'schema': 1,
        'source': ('real keyless free JEV cassette via Python 1.7.5 HTTP route' if route == 'who'
                   else 'real DeepSeek and keyless free JEV cassettes via Python 1.7.5 HTTP route'),
        'route': route, 'model': MODEL, 'source_snapshot': BOOK_ID,
        'source_tree_sha256': intent['source_tree_sha256'],
        'live_http_sha256': observation['live_http_sha256'],
        'tape_sha256': observation['tape_sha256'],
        'outbound': observation['outbound'], 'passes': 2, 'hash_seeds': ['1', '2'],
        'normalizations': ['HTTP Date and Server headers omitted by response allowlist',
                           'copied book.json mtime/inode use fixed test values in shelf cache']
                          + (['ask answer.ms uses the fixed route clock'] if route == 'ask' else [])
                          + (['marginalia created uses the fixed route clock',
                              'manual marginalia style uses the first existing COMMENT_STYLES item',
                              'marginalia KG signature input uses a fixed test revision']
                             if route == 'marginalia' else []),
        'actual_provider_bill': 'unknown without gateway receipt',
    })


def main() -> None:
    require_reference_runtime()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('record', 'replay', 'verify', 'reconcile',
                                         'replay-failure', 'verify-failure'))
    parser.add_argument('--route', choices=sorted(CASES), required=True)
    parser.add_argument('--cassettes', type=Path, default=LIVE_CASSETTES)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    if args.mode in ('record', 'reconcile') and args.out is not None:
        parser.error('record and reconcile write no explicit --out')
    if args.mode in ('replay', 'verify', 'replay-failure', 'verify-failure') and args.out is None:
        parser.error('replay and verify modes require --out')
    if args.mode == 'record':
        record(args.route, args.cassettes, args.receipt)
    elif args.mode == 'reconcile':
        result = reconcile(args.receipt, args.cassettes)
        if result['route'] != args.route:
            raise ValueError('reconcile route differs from original intent')
        print(canonical(result))
    elif args.mode == 'replay':
        replay(args.route, args.cassettes, args.receipt, args.out)
    elif args.mode == 'replay-failure':
        replay_failure(args.route, args.cassettes, args.receipt, args.out)
    elif args.mode == 'verify-failure':
        verify_failure(args.route, args.cassettes, args.receipt, args.out)
    else:
        verify(args.route, args.cassettes, args.receipt, args.out)


if __name__ == '__main__':
    main()
