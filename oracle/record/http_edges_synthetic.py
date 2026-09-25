"""Record offline model-settings and refusal HTTP branches through the real handler.

The model and classifier transports are in-memory fixtures. No provider response,
credential, or external network connection is used or represented as observed.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import shutil
import sys
import tempfile
import urllib.error
from pathlib import Path

from .common import canonical, digest, require_reference_runtime, write_json, write_jsonl
from .http_model_synthetic import (CHAT_URL, CLASSIFIER_URL, FAKE_KEY,
                                   SyntheticModelTransport, _sse_events)
from .http_routes import ROOT, coverage_report, reset_from_baseline, run_once, tree_hashes

FUTURE_QUESTION = '后面的阿Q会怎么样？'
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
    ]


class EdgeTransport(SyntheticModelTransport):
    """Fixture settings outcomes and one future-question classifier decision."""

    def __init__(self):
        super().__init__()
        self.settings_attempts = 0

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
        if (body.get('max_tokens') == 16 and
                body.get('messages') == [{'role': 'user', 'content': '只回答两个字：可以'}]):
            return '可以', 'settings-test-success'
        return SyntheticModelTransport._chat(body)

    @staticmethod
    def _classify(body: dict) -> tuple[dict, str]:
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
    if [call['kind'] for call in calls] != [
            'settings-test-success', 'settings-test-http401',
            'settings-test-timeout', 'ask-future-route']:
        raise ValueError('synthetic edge transport calls differ from the reviewed cases')
    if [row['response']['status'] for row in rows] != [200, 200, 200, 400, 200, 404, 404, 400]:
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
    if [body['error'] for body in bodies[5:]] != ['没有这本书', '没有这一章', '位置不对']:
        raise ValueError('synthetic route error bodies differ')


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
                calls = transport.calls
            assert_edges(rows, calls)
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
        'transport': {'version': 'HTTP/1.1', 'outbound_model_network': False},
        'acceptance': {'settings_success': True, 'settings_http401': True,
                       'settings_timeout': True, 'future_refusal': True},
    })
    print(f'recorded {len(rows)} synthetic edge HTTP routes; {args.repeat} passes byte-identical')


if __name__ == '__main__':
    main()
