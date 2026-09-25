"""Record offline model-settings and refusal HTTP branches through the real handler.

The model and classifier transports are in-memory fixtures. No provider response,
credential, or external network connection is used or represented as observed.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import http.client
import io
import json
import os
import shutil
import sys
import tempfile
import threading
import urllib.error
from http.server import ThreadingHTTPServer
from pathlib import Path

from .common import (canonical, digest, known_secrets, require_reference_runtime,
                     write_json, write_jsonl)
from .http_model_synthetic import (CHAT_URL, FAKE_KEY,
                                   SyntheticModelTransport, _sse_events)
from .http_routes import (ROOT, coverage_report, reset_from_baseline,
                          response_record, run_once, tree_hashes)
from .functions import LoopbackOnly

FUTURE_QUESTION = '后面的阿Q会怎么样？'
GUARD_QUESTION = '读到这里，阿Q穿了什么颜色的衣服？'
UNSUPPORTED_FIRST = '阿Q穿着蓝色的衣服。'
UNSUPPORTED_SECOND = '阿Q穿着绿色的衣服。'
AUTO_COMMENTS = {
    '共情': '赵太爷这一下也太蛮横了，阿Q都没来得及躲。',
    '侦探': '赵太爷跳过去，阿Q想退的动作就更显眼了。',
    '吐槽': '这边还没开口，那边巴掌已经先到了。',
}
# Explicit synthetic graph revision keeps the production marginalia key function's
# output reproducible across filesystems without changing its hash algorithm.
FIXED_KG_REVISION = (1_730_000_000_123_456_789, 481, 73)
SOURCE = ROOT / 'oracle/corpus/snapshots/aq_complete'


def edge_cases(_book: dict) -> list[dict]:
    return [
        {'id': 'settings-test-success-synthetic', 'method': 'POST',
         'path': '/api/settings/test', 'json': {}},
        {'id': 'settings-test-http401-synthetic', 'method': 'POST',
         'path': '/api/settings/test', 'json': {}},
        {'id': 'settings-test-timeout-synthetic', 'method': 'POST',
         'path': '/api/settings/test', 'json': {}},
        {'id': 'settings-put-invalid-url-synthetic', 'method': 'PUT',
         'path': '/api/settings', 'json': {'base_url': 'http://fixture.invalid/v1'}},
        {'id': 'ask-future-refusal-synthetic', 'method': 'POST',
         'path': '/api/books/{bid}/ask', 'json': {'q': FUTURE_QUESTION, 'pos': 900}},
        {'id': 'book-missing-synthetic', 'method': 'GET',
         'path': '/api/books/no_such_fixture_book'},
        {'id': 'chapter-missing-synthetic', 'method': 'GET',
         'path': '/api/books/{bid}/chapters/99999'},
        {'id': 'kg-invalid-range-synthetic', 'method': 'GET',
         'path': '/api/books/{bid}/kg?from=bad&to=900'},
        {'id': 'ask-guard-withheld-synthetic', 'method': 'POST',
         'path': '/api/books/{bid}/ask', 'json': {'q': GUARD_QUESTION, 'pos': 900}},
        {'id': 'marginalia-auto-synthetic', 'method': 'POST',
         'path': '/api/books/{bid}/marginalia',
         'json': {'mode': 'auto', 'pos': 900, 'page_start': 820, 'page_end': 847}},
        {'id': 'marginalia-auto-cached-synthetic', 'method': 'POST',
         'path': '/api/books/{bid}/marginalia',
         'json': {'mode': 'auto', 'pos': 900, 'page_start': 820, 'page_end': 847}},
    ]


class EdgeTransport(SyntheticModelTransport):
    """Fixture settings outcomes and one future-question classifier decision."""

    def __init__(self):
        super().__init__()
        self.settings_attempts = 0
        self._sample = None
        self._signature = None

    def __enter__(self):
        super().__enter__()
        from server import marginalia, storage
        self._sample = marginalia.random.sample
        marginalia.random.sample = lambda population, k: list(population)[:k]
        self._signature = storage.signature
        original = storage.signature
        storage.signature = lambda path: (FIXED_KG_REVISION if Path(path).name == 'kg.json'
                                          else original(path))
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        from server import marginalia, storage
        if self._sample is not None:
            marginalia.random.sample = self._sample
        if self._signature is not None:
            storage.signature = self._signature
        return super().__exit__(exc_type, exc_value, traceback)

    def open(self, request, timeout=None):
        if request.full_url == CHAT_URL and isinstance(request.data, bytes):
            body = json.loads(request.data)
            messages = body.get('messages') or []
            if (body.get('max_tokens') == 16 and
                    messages == [{'role': 'user', 'content': '只回答两个字：可以'}]):
                self.settings_attempts += 1
                if self.settings_attempts in (2, 3):
                    headers = {key.lower(): value for key, value in request.header_items()}
                    if headers.get('authorization') != 'Bearer ' + FAKE_KEY:
                        raise AssertionError('synthetic settings request used an unexpected key')
                    label = ('settings-test-http401' if self.settings_attempts == 2
                             else 'settings-test-timeout')
                    self.calls.append({'kind': label, 'url': request.full_url,
                                       'request_body_sha256': hashlib.sha256(request.data).hexdigest(),
                                       'outcome': 'synthetic HTTP 401' if self.settings_attempts == 2
                                       else 'synthetic timeout'})
                    if self.settings_attempts == 2:
                        detail = b'{"error":{"message":"fixture rejected key"}}'
                        raise urllib.error.HTTPError(request.full_url, 401, 'fixture rejection',
                                                     {}, io.BytesIO(detail))
                    raise TimeoutError('synthetic model timeout')
        return super().open(request, timeout=timeout)

    @staticmethod
    def _chat(body: dict) -> tuple[str, str]:
        if (body.get('model') != 'deepseek-flash' or
                body.get('thinking') != {'type': 'disabled'} or
                body.get('stream') is not True):
            raise AssertionError('synthetic edge chat changed model or thinking mode')
        if (body.get('max_tokens') == 16 and
                body.get('messages') == [{'role': 'user', 'content': '只回答两个字：可以'}]):
            return '可以', 'settings-test-success'
        messages = body.get('messages') or []
        user = '\n'.join(message.get('content', '') for message in messages
                         if message.get('role') == 'user')
        if body.get('max_tokens') == 1200 and GUARD_QUESTION in user:
            if len(messages) >= 4:
                return UNSUPPORTED_SECOND, 'ask-guard-rewrite'
            return UNSUPPORTED_FIRST, 'ask-guard-initial'
        if body.get('max_tokens') == 160 and '【被划线的原句】' in user:
            system = '\n'.join(message.get('content', '') for message in messages
                               if message.get('role') == 'system')
            for persona, comment in AUTO_COMMENTS.items():
                if f'这条从「{persona}」角度写' in system:
                    return comment, 'marginalia-auto-' + persona
            raise AssertionError('synthetic auto marginalia received an unreviewed persona')
        return SyntheticModelTransport._chat(body)

    @staticmethod
    def _classify(body: dict) -> tuple[dict, str]:
        if set(body) == {'items', 'dimensions'} and len(body['items']) == 1:
            dimensions = body['dimensions']
            if set(dimensions) == {'d0', 'd1', 'd2'} and all(
                    set(item['labels']) == {'supported', 'beyond_text', 'contradicted'}
                    for item in dimensions.values()) and all(
                    comment in body['items'][0] for comment in AUTO_COMMENTS.values()):
                answer = {'label': 'supported', 'confidence': 0.96,
                          'scores': {'supported': 0.96, 'beyond_text': 0.02,
                                     'contradicted': 0.02}}
                return {'results': [{'dimensions': {name: answer for name in dimensions}}]}, \
                    'marginalia-auto-guard'
            if set(dimensions) == {'d0'}:
                labels = dimensions['d0']['labels']
                if set(labels) == {'supported', 'beyond_text', 'contradicted'}:
                    state = body['items'][0]
                    if UNSUPPORTED_FIRST in state or UNSUPPORTED_SECOND in state:
                        answer = {'label': 'beyond_text', 'confidence': 0.96,
                                  'scores': {'supported': 0.02, 'beyond_text': 0.96,
                                             'contradicted': 0.02}}
                        label = ('ask-judge-rewrite' if UNSUPPORTED_SECOND in state
                                 else 'ask-judge-initial')
                        return {'results': [{'dimensions': {'d0': answer}}]}, label
                if set(labels) == {'who', 'relation', 'recap', 'why', 'future', 'other'} \
                        and GUARD_QUESTION in body['items'][0]:
                    scores = {name: (0.96 if name == 'other' else 0.008) for name in labels}
                    answer = {'label': 'other', 'confidence': 0.96, 'scores': scores}
                    return {'results': [{'dimensions': {'d0': answer}}]}, 'ask-guard-route'
        if (set(body) == {'items', 'dimensions'} and len(body['items']) == 1 and
                set(body['dimensions']) == {'d0'} and
                FUTURE_QUESTION in body['items'][0]):
            labels = body['dimensions']['d0']['labels']
            if set(labels) != {'who', 'relation', 'recap', 'why', 'future', 'other'}:
                raise AssertionError('future refusal received unexpected classifier labels')
            scores = {name: (0.96 if name == 'future' else 0.008) for name in labels}
            answer = {'label': 'future', 'confidence': 0.96, 'scores': scores}
            return {'results': [{'dimensions': {'d0': answer}}]}, 'ask-future-route'
        return SyntheticModelTransport._classify(body)


def assert_edges(rows: list[dict], calls: list[dict]) -> None:
    if [row['route'] for row in rows] != [case['id'] for case in edge_cases({})]:
        raise ValueError('synthetic edge route order differs from the reviewed cases')
    if sorted(call['kind'] for call in calls) != sorted([
            'settings-test-success', 'settings-test-http401',
            'settings-test-timeout', 'ask-future-route', 'ask-guard-route',
            'ask-guard-initial', 'ask-guard-rewrite',
            'ask-judge-initial', 'ask-judge-rewrite',
            'marginalia-auto-共情', 'marginalia-auto-侦探', 'marginalia-auto-吐槽',
            'marginalia-auto-guard']):
        raise ValueError('synthetic edge transport calls differ from the reviewed cases')
    if [row['response']['status'] for row in rows] != [
            200, 200, 200, 400, 200, 404, 404, 400, 200, 200, 200]:
        raise ValueError('synthetic edge HTTP statuses differ')
    bodies = [row['response'].get('body_json') for row in rows]
    if bodies[0] != {'ok': True,
                     'message': '连接成功：deepseek-flash+nothink 用 0.0 秒回复了「可以」'}:
        raise ValueError('synthetic settings test success differs')
    if bodies[1].get('ok') is not False or 'HTTP 401' not in bodies[1].get('message', ''):
        raise ValueError('synthetic settings rejection differs')
    if bodies[2] != {'ok': False, 'message': '连接失败：模型调用失败：synthetic model timeout'}:
        raise ValueError('synthetic settings timeout differs')
    if bodies[3] != {'error': '模型接口请填写 HTTPS 地址，不要包含账号、参数或片段'}:
        raise ValueError('synthetic invalid settings error differs')
    events = _sse_events(rows[4])
    if (len(events) != 3 or events[-1][0] != 'answer' or
            events[-1][1]['guard'] != {'verdict': 'safe', 'reason': 'future'} or
            events[-1][1]['route'] != 'future' or events[-1][1]['cites'] != []):
        raise ValueError('synthetic future refusal SSE differs')
    if [body['error'] for body in bodies[5:8]] != ['没有这本书', '没有这一章', '位置不对']:
        raise ValueError('synthetic route error bodies differ')
    withheld_events = _sse_events(rows[8])
    withheld = withheld_events[-1][1]
    if (withheld_events[-1][0] != 'answer' or withheld['guard']['verdict'] != 'withheld' or
            withheld['cites'] != [] or
            any(text in canonical(withheld_events) for text in (UNSUPPORTED_FIRST, UNSUPPORTED_SECOND))):
        raise ValueError('synthetic guard failed to withhold unsupported answer text')
    generated, cached = (row['response']['body_json'] for row in rows[9:11])
    if (generated.get('cached') is not False or len(generated.get('items', [])) != 3 or
            [item['persona'] for item in generated['items']] != ['empathy', 'detective', 'wit'] or
            [item['comment'] for item in generated['items']] != list(AUTO_COMMENTS.values()) or
            any(item['guard'] != {'verdict': 'ok', 'p': 0.96}
                for item in generated['items']) or
            cached != {**generated, 'cached': True}):
        raise ValueError('synthetic auto marginalia or cache response differs')


def protocol_once(data: Path, bid: str) -> list[dict]:
    """Exercise real HTTP 429 admission and 408 incomplete-body timeout paths."""
    from server import app

    if app.DATA != data or app.WORKER.is_alive():
        raise RuntimeError('synthetic protocol fixture requires the isolated idle server')
    cases = [
        ('ask-admission-429-synthetic', 'POST', f'/api/books/{bid}/ask',
         {'q': '读到这里发生了什么？', 'pos': 900}, None),
        ('who-admission-429-synthetic', 'POST', f'/api/books/{bid}/who',
         {'pos': 900, 'start': 751, 'end': 753}, None),
        ('marginalia-admission-429-synthetic', 'POST', f'/api/books/{bid}/marginalia',
         {'mode': 'auto', 'pos': 900, 'page_start': 820, 'page_end': 847}, None),
        ('incomplete-body-408-synthetic', 'POST', '/api/login', None, b'{}'),
        ('me-passcode-required-synthetic', 'GET', '/api/me', None, None),
        ('books-unauthorized-401-synthetic', 'GET', '/api/books', None, None),
        ('settings-nonlocal-404-synthetic', 'GET', '/api/settings', None, None),
    ]
    previous_gate, previous_timeout = app._ask_gate, app.READ_TIMEOUT
    previous_passcode, previous_local_mode = app.PASSCODE, app.LOCAL_MODE
    app._ask_gate = threading.BoundedSemaphore(0)
    app.READ_TIMEOUT = 0.15
    server = ThreadingHTTPServer(('127.0.0.1', 0), app.Handler)
    server.daemon_threads = True
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    rows = []
    try:
        with LoopbackOnly():
            conn = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=3)
            prior_socket = None
            connection_number = 0
            try:
                for route_id, method, path, body, raw in cases:
                    app.PASSCODE = ('fixture-only-passcode' if route_id in (
                        'me-passcode-required-synthetic', 'books-unauthorized-401-synthetic')
                        else previous_passcode)
                    app.LOCAL_MODE = (False if route_id == 'settings-nonlocal-404-synthetic'
                                      else previous_local_mode)
                    payload = canonical(body).encode('utf-8') if body is not None else raw
                    headers = {'Content-Type': 'application/json'}
                    if route_id == 'incomplete-body-408-synthetic':
                        headers['Content-Length'] = '20'  # send 2 bytes and let the handler time out
                    conn.request(method, path, body=payload, headers=headers)
                    current_socket = conn.sock
                    reused = current_socket is prior_socket and current_socket is not None
                    if not reused:
                        connection_number += 1
                    prior_socket = current_socket
                    response = conn.getresponse()
                    if response.version != 11:
                        raise RuntimeError('synthetic protocol fixture expected HTTP/1.1')
                    reply = response_record(response, known_secrets(), method, route_id)
                    request = {'method': method, 'path': path, 'headers': headers}
                    if body is not None:
                        request['body_json'] = body
                    else:
                        request['body_base64'] = base64.b64encode(raw or b'').decode('ascii')
                    rows.append({'route': route_id, 'request': request, 'response': reply,
                                 'transport': {'http_version': 'HTTP/1.1',
                                               'connection': connection_number,
                                               'reused_previous': reused}})
            finally:
                conn.close()
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)
        app._ask_gate, app.READ_TIMEOUT = previous_gate, previous_timeout
        app.PASSCODE, app.LOCAL_MODE = previous_passcode, previous_local_mode
    if [row['response']['status'] for row in rows] != [429, 429, 429, 408, 200, 401, 404]:
        raise ValueError('synthetic HTTP admission or body timeout statuses differ')
    if [row['response']['body_json']['error'] for row in rows[:4]] != [
            '正在回答其他问题，请稍后重试', '正在回答其他问题，请稍后重试',
            'AI 正在写另一条批注，请稍后再试', '请求超时']:
        raise ValueError('synthetic HTTP admission or body timeout messages differ')
    if (rows[4]['response']['body_json'] != {'ok': False, 'passcode': True} or
            rows[5]['response']['body_json'] != {'error': '需要口令'} or
            rows[6]['response']['body_json'] != {'error': '没有这个接口'}):
        raise ValueError('synthetic passcode or nonlocal settings response differs')
    return rows


def main() -> None:
    require_reference_runtime()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--repeat', type=int, default=2)
    args = parser.parse_args()
    if args.repeat < 2:
        parser.error('at least two passes are required')
    baseline = args.baseline.resolve()
    if SOURCE.resolve() == baseline or SOURCE.resolve() in baseline.parents or baseline in SOURCE.resolve().parents:
        parser.error('--baseline must be separate from the source book')
    source_hashes = tree_hashes(SOURCE)
    if not baseline.exists():
        baseline.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(SOURCE, baseline, symlinks=False)
    if tree_hashes(baseline) != source_hashes:
        raise ValueError('persistent HTTP baseline differs from source book')
    if 'server.app' in sys.modules or 'server.ask' in sys.modules or 'server.marginalia' in sys.modules:
        raise RuntimeError('synthetic HTTP recorder requires a fresh Python interpreter')
    with tempfile.TemporaryDirectory(prefix='thusfar-http-edges-', dir=baseline.parent) as temp:
        data = Path(temp) / 'data'
        observed = []
        for _ in range(args.repeat):
            reset_from_baseline(baseline, data, SOURCE.name)
            (data / '.model.env').write_text(
                'LLM_BASE_URL=https://oracle-http-model.invalid/v1\n'
                'LLM_API_KEY=fixture-settings-key\n'
                'EXTRACT_MODEL=deepseek-flash+nothink\nJEV_ROUTE=free-only\n',
                encoding='utf-8')
            with EdgeTransport() as transport:
                rows = run_once(data, SOURCE.name, case_builder=edge_cases)
                # Auto comments run concurrently; sort the request receipts, while the
                # actual handler's stable response order remains untouched.
                calls = sorted(transport.calls, key=lambda call: (call['kind'],
                                                                    call['request_body_sha256']))
            assert_edges(rows, calls)
            rows.extend(protocol_once(data, SOURCE.name))
            observed.append((rows, calls))
            if tree_hashes(baseline) != source_hashes:
                raise ValueError('synthetic HTTP route mutated the hard-linked baseline')
    rows, calls = observed[0]
    for index, other in enumerate(observed[1:], 2):
        if canonical((rows, calls)) != canonical(other):
            raise ValueError(f'synthetic edge pass {index} differs')
    write_jsonl(args.out, rows)
    write_json(args.out.with_name(args.out.stem + '-report.json'), {
        'schema': 1, 'source': 'synthetic in-memory model/classifier transport; no live provider responses',
        'routes': len(rows), 'passes': args.repeat, 'model_calls': calls,
        'source_tree_sha256': digest(source_hashes),
        'clock_unix_seconds': 1_750_000_000,
        'recorded_response_sha256': digest([row['response'] for row in rows]),
        'normalizations': [], 'families': coverage_report(rows),
        'synthetic_graph_revision': list(FIXED_KG_REVISION),
        'transport': {'version': 'HTTP/1.1', 'outbound_model_network': False,
                      'synthetic_admission_gate': 'zero slots for ask, who, marginalia',
                      'body_timeout': '2 sent bytes with Content-Length 20; isolated handler timeout 0.15s',
                      'auth_and_mode': 'fixture passcode for two requests; local mode disabled for one request'},
        'acceptance': {'settings_success': True, 'settings_http401': True,
                       'settings_timeout': True, 'future_refusal': True,
                       'ask_guard_withheld': True, 'auto_marginalia_and_cache': True,
                       'admission_429': True, 'incomplete_body_408': True,
                       'passcode_401': True, 'nonlocal_settings_404': True},
    })
    print(f'recorded {len(rows)} synthetic edge HTTP routes; {args.repeat} passes byte-identical')


if __name__ == '__main__':
    main()
