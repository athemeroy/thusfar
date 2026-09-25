"""Record one real /api/settings/test success, then verify it with offline HTTP replays.

Record mode is deliberately opt-in. Replay and verify use the existing keyless cassette
and a loopback-only server; they cannot contact the provider. The live key is read only
from ~/.env's NAS_DEFAULT_KEY and passed through an anonymous temporary SECRETS_FILE.
"""
from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import http.client
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import urllib.request
import uuid
from contextlib import contextmanager, nullcontext
from http.server import ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace
from typing import Callable

from .cassettes import CassetteStore, install, live_request_allowed, request_envelope
from .common import UnsafeValue, assert_public, canonical, digest, known_secrets, require_reference_runtime, write_json, write_jsonl
from .functions import LoopbackOnly
from .http_routes import ROOT, response_record
from .scan import scan
from .verify_live_cassettes import MODEL_URL, verify as verify_live_cassettes

LIVE_CASSETTES = ROOT / 'oracle/cassettes/live'
MODEL = 'deepseek-flash+nothink'
BASE_URL = 'https://open.xiaojingai.com/v1'
PATH = '/api/settings/test'
PROMPT = '只回答两个字：可以'
FIXED_CLOCK = 1_750_000_000.0
_ENV_SET = {
    'WEB_DIR': str(ROOT / 'web'), 'AUTO_PROCESS': '0', 'YEDU_LOCAL_MODE': '1',
    'PASSCODE': '', 'COOKIE_SECURE': '0', 'YEDU_RELEASE_ID': '1.7.5',
    'LLM_BASE_URL': BASE_URL, 'LLM_BASE_URL_OPENAI': BASE_URL,
    'LLM_PROTOCOL': 'openai', 'LLM_PROTOCOL_MAP': 'deepseek-flash=openai',
    'LLM_KEY_NAME': 'LLM_API_KEY', 'LLM_KEY_MAP': 'deepseek-flash=LLM_API_KEY',
    'JEV_ROUTE': 'free-only', 'CLASSIFIER_URL': 'https://classifier.dev/v1/classify',
    'EXTRACT_MODEL': MODEL,
}
_ENV_CLEAR = ('LLM_API_KEY', 'NAS_DEFAULT_KEY', 'ACCESS_LOG')
_SETTINGS = ('LLM_BASE_URL=' + BASE_URL + '\n',
             'EXTRACT_MODEL=' + MODEL + '\n', 'JEV_ROUTE=free-only\n')
_SUCCESS = re.compile(r'^连接成功：deepseek-flash\+nothink 用 0\.0 秒回复了「([\s\S]{1,20})」$')
_INTENT_KEYS = {'schema', 'task_id', 'route', 'model', 'base_url', 'clock_unix_seconds',
                'cassette_directory', 'request_sha256', 'tape_tree_before_sha256',
                'model_attempts_before', 'guarded_charge_before_cny',
                'preflight_reserved_cny', 'max_cny'}


def load_home_key(path: Path) -> str:
    """Read precisely NAS_DEFAULT_KEY from the home env file, ignoring ambient overrides."""
    if path.is_symlink() or not path.is_file():
        raise ValueError('home .env is missing or linked')
    values = []
    for line in path.read_text(encoding='utf-8').splitlines():
        match = re.match(r'^\s*(?:export\s+)?NAS_DEFAULT_KEY\s*=\s*(.*?)\s*$', line)
        if match:
            value = match.group(1)
            if value[:1] in ('"', "'") and value[-1:] == value[:1]:
                value = value[1:-1]
            values.append(value)
    if len(values) != 1 or len(values[0]) < 8 or any(ord(c) < 33 or ord(c) > 126 for c in values[0]):
        raise ValueError('home .env must contain one printable NAS_DEFAULT_KEY')
    return values[0]


@contextmanager
def isolated_settings(key: str, data: Path):
    """Use an anonymous /dev/shm file; no key is written to a named disk path."""
    try:
        fd = os.open('/dev/shm', os.O_TMPFILE | os.O_RDWR, 0o600)
    except (AttributeError, OSError) as exc:
        raise RuntimeError('anonymous temporary SECRETS_FILE is unavailable') from exc
    names = {*_ENV_SET, *_ENV_CLEAR, 'DATA_DIR', 'SECRETS_FILE'}
    previous = {name: os.environ.get(name) for name in names}
    from pipeline import llm
    with llm._env_lock:
        previous_cache = llm._env_cache
        llm._env_cache = None
    try:
        settings = (''.join(_SETTINGS) + 'LLM_API_KEY=' + key + '\n').encode('utf-8')
        if os.write(fd, settings) != len(settings):
            raise RuntimeError('anonymous settings file was not written completely')
        os.lseek(fd, 0, os.SEEK_SET)
        for name in _ENV_CLEAR:
            os.environ.pop(name, None)
        os.environ.update(_ENV_SET, DATA_DIR=str(data), SECRETS_FILE=f'/proc/self/fd/{fd}')
        yield
    finally:
        for name, value in previous.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value
        with llm._env_lock:
            llm._env_cache = previous_cache
        os.close(fd)


def planned_envelope() -> dict:
    """Derive the exact keyless request from the current Python client without opening it."""
    from pipeline import llm
    request = llm._request('openai', 'deepseek-flash',
                           [{'role': 'user', 'content': PROMPT}], 'oracle-placeholder',
                           16, 0, 'nothink')
    envelope = request_envelope(request, known_secrets())
    if envelope['url'] != MODEL_URL or live_request_allowed(envelope, request) != 'model':
        raise ValueError('settings test request differs from the approved DeepSeek route')
    body = json.loads(envelope['body_utf8'])
    if body.get('messages') != [{'role': 'user', 'content': PROMPT}] or body.get('max_tokens') != 16:
        raise ValueError('settings test prompt or token ceiling changed')
    return envelope


def preflight(cassettes: Path, envelope: dict, audit: dict) -> float:
    """Fail before an HTTP request if this digest exists or the shared ¥1 guard is full."""
    path = CassetteStore(cassettes, 'record', max_cny=1.0).path(envelope)
    if path.exists() or path.is_symlink():
        raise FileExistsError('settings request already has a cassette; reconcile its original receipt')
    reserved = CassetteStore._upper_bound(envelope)
    if audit['budget']['guarded_charged_cny'] + reserved > min(1.0, audit['budget']['max_cny']) + 1e-12:
        raise RuntimeError('settings test would exceed the existing shared ¥1 cassette guard')
    return reserved


@contextmanager
def exclusive_live_lock(cassettes: Path):
    """Serialize all live HTTP recorders without adding a tape-directory file.

    Other HTTP recorders should import this context and hold it across their entire
    preflight, provider calls, and committed observation.
    """
    name = hashlib.sha256(str(cassettes.resolve()).encode('utf-8')).hexdigest()[:24]
    path = Path(tempfile.gettempdir()) / ('thusfar-oracle-live-' + name + '.lock')
    flags = os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    try:
        stat = os.fstat(fd)
        if stat.st_uid != os.getuid() or stat.st_mode & 0o077:
            raise ValueError('HTTP recorder lock has unsafe ownership or permissions')
        fcntl.flock(fd, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
    finally:
        os.close(fd)


class ExactOpener:
    """Check the actual server request before the cassette store reserves a paid slot."""

    def __init__(self, underlying, expected: str, secrets: tuple[str, ...],
                 tape_path: Path, mode: str, seen: list[str]):
        self.underlying, self.expected, self.secrets = underlying, expected, secrets
        self.tape_path, self.mode, self.seen = tape_path, mode, seen

    def open(self, request, timeout=None):
        envelope = request_envelope(request, self.secrets)
        if digest(envelope) != self.expected or live_request_allowed(envelope, request) != 'model':
            raise ValueError('HTTP settings route attempted an unreviewed model request')
        if self.seen:
            raise RuntimeError('HTTP settings route attempted more than one model request')
        if self.mode == 'record' and (self.tape_path.exists() or self.tape_path.is_symlink()):
            raise FileExistsError('settings request was already recorded; reconcile before retry')
        self.seen.append(self.expected)
        return self.underlying.open(request, timeout=timeout)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Keep a gateway 30x from forwarding Authorization to an unreviewed host."""

    def redirect_request(self, *_args, **_kwargs):
        return None


@contextmanager
def no_redirect_transport():
    from pipeline import llm
    original = llm._opener
    llm._opener = (lambda: urllib.request.build_opener(
        urllib.request.ProxyHandler({}), NoRedirect)) if os.environ.get('LLM_BYPASS_PROXY') else (
        lambda: urllib.request.build_opener(NoRedirect))
    try:
        yield
    finally:
        llm._opener = original


def assert_success(row: dict, secrets: tuple[str, ...]) -> None:
    if row.get('route') != 'settings-test-live' or row.get('request') != {
            'method': 'POST', 'path': PATH, 'headers': {'Content-Type': 'application/json'},
            'body_json': {}} or row.get('transport') != {'http_version': 'HTTP/1.1'}:
        raise ValueError('settings test HTTP request or transport differed')
    reply = row.get('response') or {}
    body = reply.get('body_json')
    if (reply.get('status') != 200 or not isinstance(body, dict) or set(body) != {'ok', 'message'}
            or body['ok'] is not True or not isinstance(body['message'], str)
            or not _SUCCESS.fullmatch(body['message']) or
            reply.get('headers', {}).get('content-type') != 'application/json; charset=utf-8'
            or reply['headers'].get('x-yedu-release') != '1.7.5'):
        raise ValueError('settings test did not return an approved real-model HTTP success')
    if any(secret[-4:] in body['message'] for secret in secrets if len(secret) >= 8):
        raise ValueError('settings test reply includes a credential suffix')
    assert_public(canonical(row), secrets)


def assert_no_key_suffix(value: str | bytes, key: str) -> None:
    """Keep a gateway's masked-key tail out of public HTTP receipts and raw tape."""
    suffix = key[-4:].encode('utf-8') if isinstance(value, bytes) else key[-4:]
    if suffix in value:
        raise UnsafeValue('credential suffix was rejected from the HTTP recording')


def assert_tape_no_key_suffix(path: Path, key: str) -> None:
    if path.is_symlink():
        raise ValueError('settings cassette unexpectedly became a symlink')
    if not path.is_file():
        return
    tape = json.loads(path.read_text(encoding='utf-8'))
    for attempt in tape.get('attempts', []):
        encoded = list(attempt.get('chunks_base64', []))
        if 'body_base64' in attempt:
            encoded.append(attempt['body_base64'])
        for chunk in encoded:
            assert_no_key_suffix(base64.b64decode(chunk, validate=True), key)


def exercise(mode: str, cassettes: Path, key: str, expected_sha: str,
             on_observation: Callable[[dict, tuple[str, ...]], None] | None = None) -> tuple[dict, int]:
    """Exercise one real handler request with a live or offline cassette transport."""
    if mode not in ('record', 'replay'):
        raise ValueError('mode must be record or replay')
    with tempfile.TemporaryDirectory(prefix='thusfar-settings-http-') as temporary:
        data = Path(temporary) / 'data'
        data.mkdir()
        with isolated_settings(key, data):
            envelope = planned_envelope()
            if digest(envelope) != expected_sha:
                raise ValueError('settings test request changed since the original intent')
            from pipeline import llm
            from server import app, model_settings
            if app.DATA != data or app.LOCAL_MODE is not True or app.AUTO is not False or app.PASSCODE:
                raise RuntimeError('server.app was imported outside the isolated settings environment')
            settings = model_settings.read()
            if (settings['base_url'] != BASE_URL or settings['model'] != MODEL
                    or settings['jev_route'] != 'free-only' or settings['api_key'] != key):
                raise RuntimeError('isolated model settings differ from the reviewed request')
            clock = model_settings.time
            model_settings.time = SimpleNamespace(time=lambda: FIXED_CLOCK)
            server = ThreadingHTTPServer(('127.0.0.1', 0), app.Handler)
            server.daemon_threads = True
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            seen: list[str] = []
            try:
                with no_redirect_transport(), install(cassettes, mode, max_model_attempts=1,
                                                      max_jev_attempts=0, max_cny=1.0) as tape, \
                        (LoopbackOnly() if mode == 'replay' else nullcontext()):
                    cassette_factory = llm._opener
                    tape_path = tape.path(envelope)
                    route_secrets = (*tape.secrets, key)
                    llm._opener = lambda: ExactOpener(cassette_factory(), expected_sha,
                                                      route_secrets, tape_path, mode, seen)
                    try:
                        connection = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=40)
                        try:
                            connection.request('POST', PATH, body=b'{}',
                                               headers={'Content-Type': 'application/json'})
                            response = connection.getresponse()
                            if response.version != 11:
                                raise ValueError('settings test did not use HTTP/1.1')
                            reply = response_record(response, route_secrets, 'POST', 'settings-test-live')
                        finally:
                            connection.close()
                    finally:
                        llm._opener = cassette_factory
                    row = {'route': 'settings-test-live',
                           'request': {'method': 'POST', 'path': PATH,
                                       'headers': {'Content-Type': 'application/json'}, 'body_json': {}},
                           'response': reply, 'transport': {'http_version': 'HTTP/1.1'}}
                    if on_observation is not None:
                        on_observation(row, route_secrets)
                    assert_success(row, route_secrets)
                    if seen != [expected_sha] or tape.count != 1:
                        raise ValueError('settings test did not consume exactly one approved model reply')
                    return row, tape.count
            finally:
                server.shutdown()
                server.server_close()
                worker.join(timeout=3)
                model_settings.time = clock


def _read_intent(receipt: Path, cassettes: Path, *, allow_relocation: bool = False) -> dict:
    intent_path = receipt / 'intent.json'
    if receipt.is_symlink() or intent_path.is_symlink() or not intent_path.is_file():
        raise ValueError('original HTTP intent is missing or linked')
    intent = json.loads(intent_path.read_text(encoding='utf-8'))
    if (not isinstance(intent, dict) or set(intent) != _INTENT_KEYS or intent['schema'] != 1
            or not isinstance(intent['task_id'], str)
            or not re.fullmatch(r'[0-9a-f]{32}', intent['task_id'])
            or not isinstance(intent['request_sha256'], str)
            or not re.fullmatch(r'[0-9a-f]{64}', intent['request_sha256'])
            or intent['route'] != 'settings-test-live' or intent['model'] != MODEL
            or intent['base_url'] != BASE_URL or intent['clock_unix_seconds'] != FIXED_CLOCK
            or (not allow_relocation and intent['cassette_directory'] != str(cassettes.resolve()))
            or intent['max_cny'] != 1.0):
        raise ValueError('HTTP intent differs from the reviewed paid request')
    assert_public(canonical(intent), known_secrets())
    with tempfile.TemporaryDirectory(prefix='thusfar-settings-intent-check-') as temporary:
        with isolated_settings('oracle-placeholder', Path(temporary)):
            expected = digest(planned_envelope())
    if intent['request_sha256'] != expected:
        raise ValueError('HTTP intent request digest differs from the current Python client')
    return intent


def _read_receipt(receipt: Path, cassettes: Path, *, allow_relocation: bool = False) -> tuple[dict, dict]:
    intent_path, observation_path = receipt / 'intent.json', receipt / 'observation.json'
    live_path = receipt / 'live-http.jsonl'
    if any(path.is_symlink() or not path.is_file()
           for path in (intent_path, observation_path, live_path)):
        raise ValueError('original HTTP intent or successful observation is missing')
    intent = _read_intent(receipt, cassettes, allow_relocation=allow_relocation)
    observation = json.loads(observation_path.read_text(encoding='utf-8'))
    if (observation.get('intent_sha256') != hashlib.sha256(intent_path.read_bytes()).hexdigest()
            or observation.get('live_http_sha256') != hashlib.sha256(live_path.read_bytes()).hexdigest()
            or not isinstance(observation.get('tape_sha256'), str)
            or not re.fullmatch(r'[0-9a-f]{64}', observation['tape_sha256'])):
        raise ValueError('HTTP live receipt differs from this cassette and source configuration')
    attempt_path = receipt / 'attempt-http.jsonl'
    if attempt_path.is_symlink() or (attempt_path.exists() and attempt_path.read_bytes() != live_path.read_bytes()):
        raise ValueError('original HTTP attempt differs from the successful live observation')
    return intent, observation


def reconcile(receipt: Path, cassettes: Path) -> dict:
    """Classify an interrupted original attempt without changing it or opening a socket."""
    intent = _read_intent(receipt, cassettes)
    sha = intent['request_sha256']
    tape_path = cassettes / (sha + '.json')
    ledger_path = cassettes / 'budget-ledger.json'
    if tape_path.is_symlink() or ledger_path.is_symlink() or not ledger_path.is_file():
        raise ValueError('original cassette or budget ledger is linked or missing')
    ledger = json.loads(ledger_path.read_text(encoding='utf-8'))
    entries = [entry for entry in ledger['entries'] if entry.get('request_sha256') == sha]
    if len(entries) > 1:
        raise ValueError('original request has multiple paid ledger entries; do not retry')
    attempts = []
    if tape_path.exists():
        tape = json.loads(tape_path.read_text(encoding='utf-8'))
        if tape.get('request_sha256') != sha or digest(tape.get('request')) != sha:
            raise ValueError('original cassette does not match the intent digest')
        attempts = tape.get('attempts')
        if not isinstance(attempts, list) or len(attempts) > 1:
            raise ValueError('original settings request has an unexpected attempt count')
    kinds = [attempt.get('kind') for attempt in attempts]
    states = [entry.get('state') for entry in entries]
    attempt_path, live_path = receipt / 'attempt-http.jsonl', receipt / 'live-http.jsonl'
    if attempt_path.is_symlink() or live_path.is_symlink():
        raise ValueError('observed HTTP attempt is linked')
    if (receipt / 'observation.json').exists():
        _read_receipt(receipt, cassettes)
        state = 'observed_live_http'
    elif live_path.is_file():
        rows = [json.loads(line) for line in live_path.read_text(encoding='utf-8').splitlines() if line]
        if len(rows) != 1 or (attempt_path.is_file()
                             and attempt_path.read_bytes() != live_path.read_bytes()):
            raise ValueError('original successful HTTP response has an invalid row count or mismatch')
        assert_success(rows[0], known_secrets())
        if kinds == ['response'] and states == ['completed']:
            verify_live_cassettes(cassettes)
            state = 'observed_live_http_without_observation'
        else:
            state = 'observed_live_http_without_complete_wire_receipt'
    elif attempt_path.is_file():
        rows = [json.loads(line) for line in attempt_path.read_text(encoding='utf-8').splitlines() if line]
        if len(rows) != 1 or rows[0].get('route') != 'settings-test-live':
            raise ValueError('original observed HTTP attempt has an invalid route or row count')
        assert_public(canonical(rows[0]), known_secrets())
        state = 'observed_http_without_success_receipt'
    elif len(attempts) == 1 and kinds == ['response'] and states == ['completed']:
        verify_live_cassettes(cassettes)
        state = 'settled_wire_original_http_missing'
    elif 'pending' in kinds or 'reserved' in states:
        state = 'pending_original_attempt'
    elif not attempts and not entries:
        state = 'intent_without_recorded_attempt'
    else:
        state = 'failed_or_usage_unavailable_original_attempt'
    report = {'schema': 1, 'task_id': intent['task_id'], 'request_sha256': sha,
              'state': state, 'tape_attempts': len(attempts),
              'attempt_kinds': kinds, 'ledger_states': states,
              'original_live_http_present': state in ('observed_live_http',
                                                      'observed_live_http_without_observation',
                                                      'observed_live_http_without_complete_wire_receipt',
                                                      'observed_http_without_success_receipt'),
              'next_action': ('Use the original receipt and cassette for offline verification; '
                              'never issue this paid request again' if state == 'observed_live_http' else
                              'Keep the original receipt and cassette. Do not issue another paid request. '
                              'If attempt-http.jsonl exists, inspect that original HTTP response. '
                              'Otherwise a settled wire reply can support only a separately labeled '
                              'offline reconstruction; it cannot recover an unobserved live response.')}
    assert_public(canonical(report), known_secrets())
    return report


def record(cassettes: Path, receipt: Path) -> None:
    if cassettes.is_symlink() or cassettes.absolute() != LIVE_CASSETTES.absolute():
        raise ValueError('live HTTP recording must share oracle/cassettes/live')
    if receipt.resolve(strict=False).is_relative_to(cassettes.resolve()):
        raise ValueError('HTTP receipt must be outside the live cassette directory')
    with exclusive_live_lock(cassettes):
        _record_locked(cassettes, receipt)


def _record_locked(cassettes: Path, receipt: Path) -> None:
    audit_before = verify_live_cassettes(cassettes)
    key = load_home_key(Path.home() / '.env')
    with tempfile.TemporaryDirectory(prefix='thusfar-settings-preflight-') as temporary:
        with isolated_settings(key, Path(temporary)):
            envelope = planned_envelope()
    expected_sha = digest(envelope)
    reserved = preflight(cassettes, envelope, audit_before)
    receipt.mkdir(mode=0o700, parents=False, exist_ok=False)
    intent_path = receipt / 'intent.json'
    write_json(intent_path, {'schema': 1, 'task_id': uuid.uuid4().hex,
                             'route': 'settings-test-live', 'model': MODEL,
                             'base_url': BASE_URL, 'clock_unix_seconds': FIXED_CLOCK,
                             'cassette_directory': str(cassettes.resolve()),
                             'request_sha256': expected_sha,
                             'tape_tree_before_sha256': audit_before['tape_tree_sha256'],
                             'model_attempts_before': audit_before['model_attempts'],
                             'guarded_charge_before_cny': audit_before['budget']['guarded_charged_cny'],
                             'preflight_reserved_cny': reserved, 'max_cny': 1.0})
    def save_attempt(row: dict, secrets: tuple[str, ...]) -> None:
        assert_public(canonical(row), secrets)
        assert_no_key_suffix(canonical(row), key)
        write_jsonl(receipt / 'attempt-http.jsonl', [row])

    tape_path = cassettes / (expected_sha + '.json')
    try:
        row, _ = exercise('record', cassettes, key, expected_sha, save_attempt)
    finally:
        # Even on an application error, retain the paid wire receipt but refuse to
        # publish it if a gateway echoed a masked key tail in its raw response.
        assert_tape_no_key_suffix(tape_path, key)
    audit_after = verify_live_cassettes(cassettes)
    tape = json.loads(tape_path.read_text(encoding='utf-8'))
    entries = [entry for entry in json.loads((cassettes / 'budget-ledger.json').read_text())['entries']
               if entry['request_sha256'] == expected_sha]
    if (audit_after['model_attempts'] != audit_before['model_attempts'] + 1
            or audit_after['free_jev_attempts'] != audit_before['free_jev_attempts']
            or audit_after['budget']['usage_unavailable'] != audit_before['budget']['usage_unavailable']
            or len(tape['attempts']) != 1 or tape['attempts'][0].get('kind') != 'response'
            or len(entries) != 1 or entries[0].get('state') != 'completed'):
        raise ValueError('live settings success lacks one complete, usage-backed model receipt')
    live_path = receipt / 'live-http.jsonl'
    write_jsonl(live_path, [row])
    write_json(receipt / 'observation.json', {
        'schema': 1, 'intent_sha256': hashlib.sha256(intent_path.read_bytes()).hexdigest(),
        'live_http_sha256': hashlib.sha256(live_path.read_bytes()).hexdigest(),
        'tape_sha256': hashlib.sha256(tape_path.read_bytes()).hexdigest(),
        'model_prompt_tokens': entries[0]['prompt_tokens'],
        'model_completion_tokens': entries[0]['completion_tokens'],
        'configured_rate_estimate_cny': entries[0]['configured_rate_estimate_cny'],
        'guarded_charge_after_cny': audit_after['budget']['guarded_charged_cny'],
        'clock_controlled': True, 'actual_provider_bill': 'unknown without gateway receipt',
    })
    scan(receipt)
    print(f'HTTP settings success recorded; receipt={receipt}; request_sha256={expected_sha}; '
          f'guarded_charge=¥{audit_after["budget"]["guarded_charged_cny"]:.9f}; '
          'actual gateway bill unknown')


def replay(cassettes: Path, receipt: Path, out: Path) -> None:
    if out.exists() or out.is_symlink():
        raise FileExistsError('offline replay output already exists')
    if out.resolve(strict=False).is_relative_to(cassettes.resolve()):
        raise ValueError('HTTP replay output must be outside the cassette directory')
    intent, observation = _read_receipt(receipt, cassettes, allow_relocation=True)
    audit = verify_live_cassettes(cassettes)
    tape_path = cassettes / (intent['request_sha256'] + '.json')
    if (audit['budget']['guarded_charged_cny'] > 1.0 or tape_path.is_symlink()
            or not tape_path.is_file()
            or hashlib.sha256(tape_path.read_bytes()).hexdigest() != observation['tape_sha256']):
        raise ValueError('original successful settings cassette changed or is absent')
    row, _ = exercise('replay', cassettes, 'oracle-placeholder', intent['request_sha256'])
    write_jsonl(out, [row])


def verify(receipt: Path, cassettes: Path, out: Path) -> None:
    if out.exists() or out.is_symlink():
        raise FileExistsError('verified HTTP golden output already exists')
    if out.resolve(strict=False).is_relative_to(cassettes.resolve()):
        raise ValueError('HTTP golden output must be outside the cassette directory')
    _, observation = _read_receipt(receipt, cassettes, allow_relocation=True)
    original = receipt / 'live-http.jsonl'
    if (original.is_symlink() or not original.is_file()
            or hashlib.sha256(original.read_bytes()).hexdigest() != observation['live_http_sha256']):
        raise ValueError('original observed live HTTP response is absent or changed')
    with tempfile.TemporaryDirectory(prefix='thusfar-settings-dual-replay-') as temporary:
        outputs = []
        for seed in ('1', '2'):
            path = Path(temporary) / (seed + '.jsonl')
            result = subprocess.run(
                [sys.executable, '-m', 'oracle.record.http_model_live', 'replay',
                 '--cassettes', str(cassettes.resolve()),
                 '--receipt', str(receipt.resolve()), '--out', str(path)],
                cwd=ROOT, env={**os.environ, 'PYTHONHASHSEED': seed},
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
            )
            if result.returncode:
                raise RuntimeError(f'offline HTTP replay pass {seed} failed; no golden was written')
            outputs.append(path.read_bytes())
        if outputs[0] != outputs[1] or outputs[0] != original.read_bytes():
            raise ValueError('live HTTP response and two independent offline replays differ')
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(outputs[0])
    write_json(out.with_name(out.stem + '-report.json'), {
        'schema': 1, 'route': 'POST ' + PATH, 'status': 200,
        'source': 'observed gateway wire cassette requesting deepseek-flash+nothink via Python 1.7.5 HTTP route',
        'model': MODEL, 'request_sha256': json.loads((receipt / 'intent.json').read_text())['request_sha256'],
        'live_http_sha256': hashlib.sha256(original.read_bytes()).hexdigest(),
        'verified_http_sha256': hashlib.sha256(out.read_bytes()).hexdigest(),
        'passes': 2, 'hash_seeds': ['1', '2'],
        'normalizations': ['HTTP Date and Server headers are omitted by the existing response allowlist'],
        'fixture_clock': 'model_settings.time.time is fixed at 1750000000.0 in live and replay; '
                         'the reported 0.0 seconds is controlled, not provider latency',
        'actual_provider_bill': 'unknown without gateway receipt',
    })
    print(f'offline HTTP settings success verified twice; sha256={hashlib.sha256(out.read_bytes()).hexdigest()}')


def main() -> None:
    require_reference_runtime()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('record', 'replay', 'verify', 'reconcile'))
    parser.add_argument('--cassettes', type=Path, default=LIVE_CASSETTES)
    parser.add_argument('--receipt', type=Path, required=True)
    parser.add_argument('--out', type=Path, help='replay JSONL or verified golden JSONL')
    args = parser.parse_args()
    if args.mode == 'reconcile':
        if args.out is not None:
            parser.error('reconcile is read-only and does not accept --out')
        print(canonical(reconcile(args.receipt, args.cassettes)))
    elif args.mode == 'record':
        if args.out is not None:
            parser.error('record writes only its new receipt directory')
        record(args.cassettes, args.receipt)
    else:
        if args.out is None:
            parser.error('replay and verify require --out')
        if args.mode == 'replay':
            replay(args.cassettes, args.receipt, args.out)
        else:
            verify(args.receipt, args.cassettes, args.out)


if __name__ == '__main__':
    main()
