"""Capture and replay exact model/JEV wire replies at pipeline.llm's opener boundary.

Recording is opt-in. Replay never opens a socket. Only DeepSeek flash with disabled thinking
and the keyless classifier.dev route can be recorded live; credentials are excluded from both
the digest and cassette, and response bytes are checked before they are written.
"""
from __future__ import annotations

import base64
import fcntl
import io
import json
import threading
import urllib.error
import urllib.parse
import uuid
from contextlib import contextmanager
from email.message import Message
from pathlib import Path

from .common import UnsafeValue, assert_public, canonical, digest, known_secrets, write_json
from pipeline.models import PRICES

_SAFE_HEADERS = ('accept', 'content-type')
_REPLY_HEADERS = ('content-type', 'content-encoding', 'retry-after')
_SECRET_QUERY = ('key', 'token', 'secret', 'password', 'authorization')
_MODEL_PRICE = PRICES['deepseek-flash']['price']


def request_envelope(request, secrets: tuple[str, ...]) -> dict:
    url = urllib.parse.urlsplit(request.full_url)
    if url.username or url.password:
        raise UnsafeValue('URL contains credentials')
    query = urllib.parse.parse_qsl(url.query, keep_blank_values=True)
    if any(any(part in key.lower() for part in _SECRET_QUERY) for key, _ in query):
        raise UnsafeValue('URL has credential query fields')
    clean_url = urllib.parse.urlunsplit((url.scheme, url.netloc, url.path, url.query, ''))
    raw = request.data or b''
    try:
        body = raw.decode('utf-8')
    except UnicodeDecodeError as exc:
        raise UnsafeValue('request body is not UTF-8') from exc
    assert_public(clean_url + body, secrets)
    headers = {key.lower(): value for key, value in request.header_items()
               if key.lower() in _SAFE_HEADERS}
    assert_public(canonical(headers), secrets)
    return {'method': request.get_method(), 'url': clean_url, 'headers': dict(sorted(headers.items())),
            'body_utf8': body}


def live_request_allowed(envelope: dict, request) -> str:
    url = urllib.parse.urlsplit(envelope['url'])
    if url.scheme != 'https':
        raise ValueError('live cassette recording requires HTTPS')
    if url.netloc == 'classifier.dev' and url.path == '/v1/classify':
        if any(key.lower() in ('authorization', 'x-api-key', 'x-goog-api-key')
               for key, _ in request.header_items()):
            raise ValueError('live JEV recording must use the keyless free route')
        return 'jev'
    if url.netloc == 'open.xiaojingai.com' and url.path == '/v1/chat/completions':
        try:
            body = json.loads(envelope['body_utf8'])
        except ValueError as exc:
            raise ValueError('model request body is not JSON') from exc
        if body.get('model') == 'deepseek-flash' and body.get('thinking') == {'type': 'disabled'}:
            return 'model'
    raise ValueError('live cassette recording allows only deepseek-flash+nothink and free JEV')


def reply_headers(headers) -> dict:
    return {key.title(): headers.get(key) for key in _REPLY_HEADERS if headers.get(key) is not None}


def message_headers(values: dict) -> Message:
    message = Message()
    for key, value in values.items():
        message[key] = value
    return message


class CassetteStore:
    def __init__(self, directory: Path, mode: str, secrets: tuple[str, ...] | None = None,
                 max_model_attempts: int | None = None, max_jev_attempts: int | None = None,
                 max_cny: float = 1.0):
        if mode not in ('record', 'replay'):
            raise ValueError('mode must be record or replay')
        if not 0 < max_cny <= 1.0:
            raise ValueError('live cassette budget must be within ¥1')
        self.directory = directory
        self.mode = mode
        self.max_cny = max_cny
        self.secrets = known_secrets() if secrets is None else secrets
        self.lock = threading.Lock()
        self.offsets: dict[str, int] = {}
        self.count = 0
        self.attempts = {'model': 0, 'jev': 0}
        self.limits = {'model': max_model_attempts, 'jev': max_jev_attempts}

    @contextmanager
    def _ledger(self):
        self.directory.mkdir(parents=True, exist_ok=True)
        with (self.directory / '.budget.lock').open('a') as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            try:
                path = self.directory / 'budget-ledger.json'
                ledger = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {
                    'schema': 1, 'max_cny': self.max_cny, 'entries': []}
                if ledger.get('schema') != 1 or not isinstance(ledger.get('entries'), list):
                    raise ValueError('invalid cassette budget ledger')
                ledger['max_cny'] = min(float(ledger['max_cny']), self.max_cny)
                yield ledger
                write_json(path, ledger)
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)

    @staticmethod
    def _upper_bound(envelope: dict) -> float:
        body = json.loads(envelope['body_utf8'])
        cap = body.get('max_tokens')
        if not isinstance(cap, int) or isinstance(cap, bool) or cap < 1:
            raise ValueError('model request has no positive max_tokens budget')
        # A token cannot represent less than one UTF-8 byte. The extra 2048 tokens cover
        # gateway chat framing; the 10% margin covers small accounting differences.
        prompt_upper = len(envelope['body_utf8'].encode('utf-8')) + 2048
        return round((prompt_upper * _MODEL_PRICE[0] + cap * _MODEL_PRICE[1]) / 1_000_000 * 1.1, 9)

    def reserve_live(self, kind: str, envelope: dict) -> str | None:
        with self.lock:
            limit = self.limits[kind]
            if limit is not None and self.attempts[kind] >= limit:
                raise RuntimeError(f'{kind} cassette attempt cap reached')
            reservation = None
            if kind == 'model':
                upper = self._upper_bound(envelope)
                with self._ledger() as ledger:
                    spent = sum(float(entry['charged_cny']) for entry in ledger['entries'])
                    if spent + upper > ledger['max_cny'] + 1e-12:
                        raise RuntimeError('live cassette ¥1 cumulative preflight budget reached')
                    reservation = uuid.uuid4().hex
                    ledger['entries'].append({'id': reservation,
                                              'request_sha256': digest(envelope),
                                              'reserved_cny': upper,
                                              'charged_cny': upper,
                                              'state': 'reserved'})
            self.attempts[kind] += 1
            return reservation

    @staticmethod
    def _stream_usage(attempt: dict) -> tuple[int, int] | None:
        if attempt.get('kind') != 'response':
            return None
        raw = b''.join(base64.b64decode(chunk, validate=True)
                       for chunk in attempt.get('chunks_base64', []))
        usage = None
        for line in raw.decode('utf-8', 'replace').splitlines():
            if not line.startswith('data:'):
                continue
            try:
                event = json.loads(line[5:].strip())
            except ValueError:
                continue
            candidate = event.get('usage') if isinstance(event, dict) else None
            if isinstance(candidate, dict):
                prompt, completion = candidate.get('prompt_tokens'), candidate.get('completion_tokens')
                if all(isinstance(value, int) and not isinstance(value, bool) and value >= 0
                       for value in (prompt, completion)):
                    usage = (prompt, completion)
        return usage

    def settle_live(self, reservation: str | None, attempt: dict) -> None:
        if reservation is None:
            return
        usage = self._stream_usage(attempt)
        overrun = False
        with self._ledger() as ledger:
            entry = next((row for row in ledger['entries'] if row['id'] == reservation), None)
            if entry is None:
                raise ValueError('cassette budget reservation missing')
            if usage is None:
                entry['state'] = 'usage_unavailable'
                return
            prompt, completion = usage
            actual = round((prompt * _MODEL_PRICE[0] + completion * _MODEL_PRICE[1]) / 1_000_000, 9)
            entry.update(state='completed', prompt_tokens=prompt,
                         completion_tokens=completion, actual_cny=actual,
                         charged_cny=max(actual, 0.0))
            if actual > entry['reserved_cny']:
                entry['state'] = 'over_upper_bound'
                overrun = True
        if overrun:
            raise RuntimeError('model bill exceeded cassette preflight reservation')

    def budget_summary(self) -> dict:
        path = self.directory / 'budget-ledger.json'
        if not path.exists():
            return {'actual_cny': 0.0, 'charged_cny': 0.0, 'model_attempts': 0,
                    'usage_unavailable': 0}
        ledger = json.loads(path.read_text(encoding='utf-8'))
        entries = ledger['entries']
        return {'actual_cny': round(sum(row.get('actual_cny', 0) for row in entries), 9),
                'charged_cny': round(sum(row['charged_cny'] for row in entries), 9),
                'model_attempts': len(entries),
                'usage_unavailable': sum(row['state'] != 'completed' for row in entries)}

    def path(self, envelope: dict) -> Path:
        return self.directory / (digest(envelope) + '.json')

    def append(self, envelope: dict, attempt: dict) -> None:
        # Search the full serialized record, including raw response chunks, for known secrets.
        assert_public(canonical(attempt), self.secrets)
        if 'chunks_base64' in attempt:
            raw = b''.join(base64.b64decode(chunk, validate=True) for chunk in attempt['chunks_base64'])
            assert_public(raw.decode('utf-8', 'replace'), self.secrets)
        if 'body_base64' in attempt:
            raw = base64.b64decode(attempt['body_base64'], validate=True)
            assert_public(raw.decode('utf-8', 'replace'), self.secrets)
        path = self.path(envelope)
        with self.lock:
            tape = json.loads(path.read_text(encoding='utf-8')) if path.exists() else {
                'schema': 1, 'request_sha256': path.stem, 'request': envelope, 'attempts': []}
            if tape['request'] != envelope:
                raise ValueError('cassette digest collision or changed request')
            tape['attempts'].append(attempt)
            write_json(path, tape)
            self.count += 1

    def next(self, envelope: dict) -> dict:
        path = self.path(envelope)
        if not path.exists():
            raise FileNotFoundError(f'no cassette for request sha256={path.stem}')
        tape = json.loads(path.read_text(encoding='utf-8'))
        if tape.get('request') != envelope or tape.get('request_sha256') != path.stem:
            raise ValueError(f'cassette integrity check failed: {path.name}')
        with self.lock:
            index = self.offsets.get(path.stem, 0)
            if index >= len(tape['attempts']):
                raise RuntimeError(f'cassette exhausted: sha256={path.stem}, attempts={index}')
            self.offsets[path.stem] = index + 1
            self.count += 1
        return tape['attempts'][index]


class RecordingResponse:
    def __init__(self, actual, store: CassetteStore, envelope: dict, reservation: str | None):
        self.actual, self.store, self.envelope = actual, store, envelope
        self.reservation = reservation
        self.headers = actual.headers
        self.status = getattr(actual, 'status', None)
        self.attempt = {'kind': 'response', 'status': self.status, 'headers': reply_headers(actual.headers),
                        'chunks_base64': []}

    def __enter__(self):
        self.actual.__enter__()
        return self

    def __exit__(self, exc_type, exc, tb):
        try:
            self.actual.__exit__(exc_type, exc, tb)
        finally:
            self.store.append(self.envelope, self.attempt)
            self.store.settle_live(self.reservation, self.attempt)

    def _read(self, method: str, size: int = -1):
        try:
            source = getattr(self.actual, method, self.actual.read)
            chunk = source(size)
        except (TimeoutError, OSError, urllib.error.URLError) as exc:
            self.attempt['read_error'] = {'type': type(exc).__name__, 'message': str(exc)}
            raise
        assert_public(chunk.decode('utf-8', 'replace'), self.store.secrets)
        self.attempt['chunks_base64'].append(base64.b64encode(chunk).decode('ascii'))
        return chunk

    def read(self, size: int = -1):
        return self._read('read', size)

    def read1(self, size: int = -1):
        return self._read('read1', size)

    def __getattr__(self, name):
        return getattr(self.actual, name)


class ReplayResponse:
    def __init__(self, attempt: dict):
        self.attempt = attempt
        self.headers = message_headers(attempt['headers'])
        self.status = attempt['status']
        self.index = 0
        self.raised = False

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self, size: int = -1):
        chunks = self.attempt['chunks_base64']
        if self.index < len(chunks):
            raw = base64.b64decode(chunks[self.index], validate=True)
            self.index += 1
            if size >= 0 and len(raw) > size:
                raise ValueError('recorded chunk exceeds requested read size')
            return raw
        if self.attempt.get('read_error') and not self.raised:
            self.raised = True
            raise_replayed(self.attempt['read_error'])
        return b''

    def read1(self, size: int = -1):
        return self.read(size)


def raise_replayed(error: dict):
    kind, message = error['type'], error['message']
    if kind in ('TimeoutError', 'socket.timeout'):
        raise TimeoutError(message)
    if kind == 'URLError':
        raise urllib.error.URLError(message)
    if kind in ('ConnectionError', 'ConnectionResetError', 'BrokenPipeError'):
        raise ConnectionError(message)
    if kind == 'OSError':
        raise OSError(message)
    raise RuntimeError(f'unsupported cassette error type {kind}')


class CassetteOpener:
    def __init__(self, store: CassetteStore, actual_factory):
        self.store, self.actual_factory = store, actual_factory

    def open(self, request, timeout=None):
        envelope = request_envelope(request, self.store.secrets)
        if self.store.mode == 'replay':
            attempt = self.store.next(envelope)
            if attempt['kind'] == 'response':
                return ReplayResponse(attempt)
            if attempt['kind'] == 'http_error':
                body = base64.b64decode(attempt['body_base64'], validate=True)
                raise urllib.error.HTTPError(envelope['url'], attempt['status'], attempt['reason'],
                                             message_headers(attempt['headers']), io.BytesIO(body))
            raise_replayed(attempt['error'])
        kind = live_request_allowed(envelope, request)
        reservation = self.store.reserve_live(kind, envelope)
        try:
            actual = self.actual_factory().open(request, timeout=timeout)
        except urllib.error.HTTPError as exc:
            body = exc.read()
            assert_public(body.decode('utf-8', 'replace'), self.store.secrets)
            attempt = {'kind': 'http_error', 'status': exc.code, 'reason': str(exc.reason),
                       'headers': reply_headers(exc.headers),
                       'body_base64': base64.b64encode(body).decode('ascii')}
            self.store.append(envelope, attempt)
            self.store.settle_live(reservation, attempt)
            raise urllib.error.HTTPError(envelope['url'], exc.code, exc.reason, exc.headers,
                                         io.BytesIO(body)) from None
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as exc:
            attempt = {'kind': 'error', 'error': {'type': type(exc).__name__, 'message': str(exc)}}
            self.store.append(envelope, attempt)
            self.store.settle_live(reservation, attempt)
            raise
        return RecordingResponse(actual, self.store, envelope, reservation)


@contextmanager
def install(directory: Path, mode: str, *, max_model_attempts: int | None = None,
            max_jev_attempts: int | None = None, max_cny: float = 1.0):
    """Patch only the Python reference client's transport for one recording workload."""
    from pipeline import llm
    store = CassetteStore(directory, mode, max_model_attempts=max_model_attempts,
                          max_jev_attempts=max_jev_attempts, max_cny=max_cny)
    original = llm._opener
    llm._opener = lambda: CassetteOpener(store, original)
    try:
        yield store
    finally:
        llm._opener = original
