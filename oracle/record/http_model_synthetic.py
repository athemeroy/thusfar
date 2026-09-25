"""Record successful model-backed HTTP routes with a fail-closed in-memory model transport.

These are synthetic interface fixtures, not DeepSeek or classifier.dev observations.
The actual Python HTTP handlers, prompt construction, model clients, SSE parser, and
response serialization run; only the outbound model opener is replaced.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import io
import json
import os
import re
import shutil
import sys
import tempfile
from contextlib import AbstractContextManager
from pathlib import Path

from .common import canonical, digest, require_reference_runtime, write_json, write_jsonl
from .http_routes import (ROOT, coverage_report, reset_from_baseline, run_once,
                          tree_hashes)

CHAT_URL = 'https://oracle-http-model.invalid/v1/chat/completions'
CLASSIFIER_URL = 'https://oracle-http-classifier.invalid/v1/classify'
FAKE_KEY = 'oracle-http-transport-fixture-only'
ASK_QUESTION = '读到这里，阿Q经历了什么？'
ASK_ANSWER = '赵太爷打了阿Q一个嘴巴。'
MARGINALIA_COMMENT = '赵太爷这一下也太蛮横了，阿Q都没来得及躲。'
EXPECTED_MODEL_CALLS = ('who-choice', 'ask-route', 'ask-chat', 'ask-guard',
                        'marginalia-chat', 'marginalia-guard')


def model_cases(_book: dict) -> list[dict]:
    """Fixed UTF-16 offsets in the checked-in 阿Q source; no generated prompt is a fixture input."""
    return [
        {'id': 'who-person-synthetic', 'method': 'POST', 'path': '/api/books/{bid}/who',
         'json': {'pos': 900, 'start': 751, 'end': 753}},
        {'id': 'ask-answer-synthetic', 'method': 'POST', 'path': '/api/books/{bid}/ask',
         'json': {'q': ASK_QUESTION, 'pos': 900}},
        {'id': 'marginalia-manual-synthetic', 'method': 'POST',
         'path': '/api/books/{bid}/marginalia',
         'json': {'mode': 'manual', 'pos': 900, 'start': 820, 'end': 847,
                  'persona': 'empathy'}},
        {'id': 'marginalia-manual-cached-synthetic', 'method': 'POST',
         'path': '/api/books/{bid}/marginalia',
         'json': {'mode': 'manual', 'pos': 900, 'start': 820, 'end': 847,
                  'persona': 'empathy'}},
    ]


class _MemoryResponse(io.BytesIO):
    def __init__(self, body: bytes, content_type: str):
        super().__init__(body)
        self.headers = {'Content-Type': content_type}


class SyntheticModelTransport(AbstractContextManager):
    """Allow exactly the reviewed model endpoints and six expected requests.

The client receives a fixture key only in memory. The original key loader is also
replaced so ambient ~/.env, CLASSIFIER_KEY, and gateway credentials cannot enter a
synthetic request even when the host environment contains them.
    """

    def __init__(self):
        self.calls: list[dict] = []
        self._saved = None
        self._choice = None

    def __enter__(self):
        from pipeline import llm
        self._saved = (dict(os.environ), llm._opener, llm._env, llm.CLASSIFIER_URL)
        os.environ.update(QA_MODEL='deepseek-flash+nothink',
                          MARGINALIA_MODEL='deepseek-flash+nothink',
                          MARGINALIA_AUTO_MODEL='deepseek-flash+nothink',
                          JEV_ROUTE='free-only', JUDGE_RETRIEVAL='0',
                          QUERY_TRANSLATION='0', LLM_RETRIES='0', JEV_FREE_RETRIES='0')
        allowed = {'LLM_KEY_MAP': 'deepseek-=ORACLE_HTTP_FAKE_KEY',
                   'ORACLE_HTTP_FAKE_KEY': FAKE_KEY,
                   'LLM_BASE_URL': 'https://oracle-http-model.invalid/v1',
                   'LLM_PROTOCOL': 'openai'}
        llm._env = allowed.get
        llm._opener = lambda: self
        llm.CLASSIFIER_URL = CLASSIFIER_URL
        # Manual marginalia chooses a wording hint with random.choice while building
        # its prompt. Keep the prompt itself stable so request hashes verify too.
        from server import marginalia
        self._choice = marginalia.random.choice
        marginalia.random.choice = lambda items: items[0]
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        from pipeline import llm
        if self._saved is not None:
            if self._choice is not None:
                from server import marginalia
                marginalia.random.choice = self._choice
            previous, llm._opener, llm._env, llm.CLASSIFIER_URL = self._saved
            os.environ.clear()
            os.environ.update(previous)
        return False

    def open(self, request, timeout=None):
        if request.get_method() != 'POST' or not isinstance(request.data, bytes):
            raise AssertionError('synthetic model transport expected a POST with bytes')
        headers = {k.lower(): v for k, v in request.header_items()}
        if request.full_url == CLASSIFIER_URL:
            if 'authorization' in headers:
                raise AssertionError('synthetic classifier request unexpectedly has an API key')
            body, label = self._classify(json.loads(request.data))
            reply = canonical(body).encode('utf-8')
            content_type = 'application/json'
        elif request.full_url == CHAT_URL:
            if headers.get('authorization') != 'Bearer ' + FAKE_KEY:
                raise AssertionError('synthetic chat request used an unexpected key')
            body, label = self._chat(json.loads(request.data))
            reply = (b'data: ' + canonical({'choices': [{'delta': {'content': body}}]}).encode('utf-8')
                     + b'\n\ndata: ' + canonical({'choices': [], 'usage': {
                         'prompt_tokens': 30, 'completion_tokens': 15}}).encode('utf-8')
                     + b'\n\ndata: [DONE]\n\n')
            content_type = 'text/event-stream'
        else:
            raise AssertionError('synthetic model transport refused an unreviewed endpoint')
        self.calls.append({'kind': label, 'url': request.full_url,
                           'request_body_sha256': hashlib.sha256(request.data).hexdigest(),
                           'response_body_sha256': hashlib.sha256(reply).hexdigest()})
        return _MemoryResponse(reply, content_type)

    @staticmethod
    def _classify(body: dict) -> tuple[dict, str]:
        if set(body) != {'items', 'dimensions'} or len(body['items']) != 1 \
                or set(body['dimensions']) != {'d0'}:
            raise AssertionError('synthetic classifier received an unreviewed envelope')
        labels = body['dimensions']['d0']['labels']
        state = body['items'][0]
        if {'P2', 'unknown'} <= set(labels) and '<selected>阿Q</selected>' in state:
            choice, kind = 'P2', 'who-choice'
        elif set(labels) == {'who', 'relation', 'recap', 'why', 'future', 'other'} \
                and ASK_QUESTION in state:
            choice, kind = 'recap', 'ask-route'
        elif set(labels) == {'supported', 'beyond_text', 'contradicted'}:
            if ASK_ANSWER in state:
                choice, kind = 'supported', 'ask-guard'
            elif MARGINALIA_COMMENT in state:
                choice, kind = 'supported', 'marginalia-guard'
            else:
                raise AssertionError('synthetic guard received an unreviewed answer')
        else:
            raise AssertionError('synthetic classifier received unreviewed labels or state')
        alternatives = [label for label in labels if label != choice]
        share, remainder = divmod(40, len(alternatives))
        scores = {choice: 0.96}
        scores.update({label: (share + (index < remainder)) / 1000
                       for index, label in enumerate(alternatives)})
        # Scores need only be offered, finite labels according to jev_free; the exact
        # selected probability (0.96) is the public route contract recorded below.
        answer = {'label': choice, 'confidence': 0.96, 'scores': scores}
        return {'results': [{'dimensions': {'d0': answer}}]}, kind

    @staticmethod
    def _chat(body: dict) -> tuple[str, str]:
        if body.get('model') != 'deepseek-flash' or body.get('thinking') != {'type': 'disabled'} \
                or body.get('stream') is not True:
            raise AssertionError('synthetic chat received a different model or thinking mode')
        messages = body.get('messages') or []
        user = '\n'.join(m.get('content', '') for m in messages if m.get('role') == 'user')
        if '【读者的问题】' + ASK_QUESTION in user and body.get('max_tokens') == 1200:
            return ASK_ANSWER, 'ask-chat'
        if '【被划线的原句】' in user and body.get('max_tokens') == 160:
            return MARGINALIA_COMMENT, 'marginalia-chat'
        raise AssertionError('synthetic chat received an unreviewed prompt')


def _sse_events(row: dict) -> list[tuple[str, dict]]:
    body = base64.b64decode(row['response']['body_base64'], validate=True).decode('utf-8')
    out = []
    for block in body.strip().split('\n\n'):
        lines = block.splitlines()
        if len(lines) != 2 or not lines[0].startswith('event: ') or not lines[1].startswith('data: '):
            raise ValueError('synthetic ask response contains a malformed SSE event')
        out.append((lines[0][7:], json.loads(lines[1][6:])))
    return out


def assert_model_acceptance(rows: list[dict], calls: list[dict]) -> list[dict]:
    expected_ids = [case['id'] for case in model_cases({})]
    if [row['route'] for row in rows] != expected_ids:
        raise ValueError('synthetic HTTP route IDs differ from the reviewed acceptance contract')
    if [call['kind'] for call in calls] != list(EXPECTED_MODEL_CALLS):
        raise ValueError('synthetic model transport request order or count changed')
    if any(row['response']['status'] != 200 for row in rows):
        raise ValueError('a synthetic model-backed route did not return HTTP 200')
    who = rows[0]['response']['body_json']
    if who != {'ok': True, 'id': 'P2', 'name': '阿Q', 'p': 0.96, 'word': '阿Q'}:
        raise ValueError('synthetic who route did not resolve the selected person')
    if rows[1]['response']['headers'].get('content-type') != 'text/event-stream; charset=utf-8':
        raise ValueError('synthetic ask route did not return SSE content')
    events = _sse_events(rows[1])
    if events != [
        ('stage', {'text': '理解你的问题'}),
        ('route', {'route': 'recap', 'p': 0.96}),
        ('stage', {'text': '翻阅你读过的部分'}),
        ('stage', {'text': '组织回答'}),
        ('stage', {'text': '检查有没有剧透'}),
        ('answer', {'text': ASK_ANSWER, 'cites': [], 'route': 'recap',
                    'guard': {'p': 0.96, 'verdict': 'ok'}, 'people': ['P2'],
                    'position': 900, 'ms': 0}),
    ]:
        raise ValueError('synthetic ask SSE stages, answer, or spoiler guard changed')
    note = rows[2]['response']['body_json']
    if set(note) != {'key', 'comment', 'start', 'end', 'quote', 'persona', 'kind',
                     'score', 'guard', 'position', 'knowledge_cutoff', 'created', 'cached'} \
            or not isinstance(note['key'], str) or not re.fullmatch(r'[0-9a-f]{32}', note['key']) \
            or note['comment'] != MARGINALIA_COMMENT \
            or note['guard'] != {'verdict': 'ok', 'p': 0.96} \
            or note['start'] != 820 or note['end'] != 847 \
            or note['quote'] != '阿Q不开口，想往后退了；赵太爷跳过去，给了他一个嘴巴。' \
            or note['persona'] != 'empathy' or note['kind'] != 'manual' or note['score'] != 1.0 \
            or note['position'] != 900 or note['knowledge_cutoff'] != 847 \
            or note['created'] != 1_750_000_000.0 or note['cached'] is not False:
        raise ValueError('synthetic marginalia did not publish a guarded manual comment')
    if rows[3]['response']['body_json'] != {**note, 'cached': True}:
        raise ValueError('synthetic marginalia cache did not return the original comment')
    if not rows[3]['transport']['reused_previous'] or \
            rows[3]['transport']['connection'] != rows[2]['transport']['connection']:
        raise ValueError('synthetic marginalia HTTP/1.1 connection was not reused')
    return events


def main() -> None:
    require_reference_runtime()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('book', type=Path, help='checked-in aq_complete snapshot directory')
    parser.add_argument('--baseline', type=Path, required=True,
                        help='persistent private snapshot reused across independent runs')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--repeat', type=int, default=2)
    args = parser.parse_args()
    source = args.book.resolve()
    if source != (ROOT / 'oracle/corpus/snapshots/aq_complete').resolve():
        parser.error('synthetic model HTTP cases are defined only for checked-in aq_complete')
    if args.repeat < 2:
        parser.error('at least two passes are required before publishing route goldens')
    baseline = args.baseline.resolve()
    if source == baseline or source in baseline.parents or baseline in source.parents:
        parser.error('--baseline must be separate from the source book')
    source_hashes = tree_hashes(source)
    if not baseline.exists():
        baseline.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source, baseline, symlinks=False)
    if tree_hashes(baseline) != source_hashes:
        raise ValueError('persistent HTTP baseline differs from source book')
    if 'server.app' in sys.modules or 'server.ask' in sys.modules \
            or 'server.marginalia' in sys.modules:
        raise RuntimeError('synthetic HTTP recorder requires a fresh Python interpreter')
    with tempfile.TemporaryDirectory(prefix='thusfar-http-model-synthetic-', dir=baseline.parent) as temp:
        data = Path(temp) / 'data'
        observations = []
        for _ in range(args.repeat):
            reset_from_baseline(baseline, data, source.name)
            with SyntheticModelTransport() as transport:
                rows = run_once(data, source.name, case_builder=model_cases)
                calls = transport.calls
            events = assert_model_acceptance(rows, calls)
            observations.append((rows, calls, events))
            if tree_hashes(baseline) != source_hashes:
                raise ValueError('synthetic HTTP route mutated a hard-linked baseline file')
    rows, calls, events = observations[0]
    for pass_index, other in enumerate(observations[1:], 2):
        if canonical((rows, calls, events)) != canonical(other):
            raise ValueError(f'synthetic HTTP pass {pass_index} differs')
    write_jsonl(args.out, rows)
    write_json(args.out.with_name(args.out.stem + '-report.json'), {
        'schema': 1, 'source': 'synthetic in-memory transport; no live model or JEV response',
        'model': 'deepseek-flash+nothink request shape only; generated text is synthetic',
        'routes': len(rows), 'passes': args.repeat, 'model_calls': calls,
        'source_tree_sha256': digest(source_hashes),
        'source_text_sha256': source_hashes['source.txt'],
        'source_book_sha256': source_hashes['book.json'],
        'source_kg_sha256': source_hashes['kg.json'],
        'source_status_sha256': source_hashes['status.json'],
        'clock_unix_seconds': 1_750_000_000,
        'recorded_response_sha256': digest([row['response'] for row in rows]),
        'source_inode_policy': 'Independent invocations and passes hard-link the same persistent baseline files',
        'normalizations': [],
        'families': coverage_report(rows),
        'transport': {'version': 'HTTP/1.1', 'outbound_model_network': False,
                      'fixture_calls': len(calls),
                      'marginalia_cache_reused_connection': True},
        'acceptance': {'who_resolves_person': True, 'ask_sse_guarded_answer': True,
                       'marginalia_guarded_comment_and_cached_reply': True},
        'remaining_model_success_gaps': ['actual DeepSeek and classifier.dev output provenance',
                                         'auto marginalia generation',
                                         'model settings connectivity test success'],
    })
    print(f'recorded {len(rows)} synthetic model-backed HTTP routes; '
          f'{args.repeat} passes byte-identical; {len(calls)} in-memory model calls')


if __name__ == '__main__':
    main()
