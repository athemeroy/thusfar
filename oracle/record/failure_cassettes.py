"""Create clearly labelled synthetic transport cassettes for error and stream edge cases."""
from __future__ import annotations

import argparse
import base64
import json
import os
import urllib.request
from pathlib import Path

from .cassettes import CassetteStore, request_envelope


def b64(data: bytes) -> str:
    return base64.b64encode(data).decode('ascii')


def stream(*events: dict | str) -> bytes:
    return ''.join('data: ' + (event if isinstance(event, str) else json.dumps(event, ensure_ascii=False)) + '\n\n'
                   for event in events).encode('utf-8')


def chat_request(name: str):
    from pipeline import llm
    return llm._request('openai', 'deepseek-flash',
                        [{'role': 'user', 'content': 'oracle fixture: ' + name}],
                        'fixture-placeholder', 16, 0, 'nothink')


def add_chat(store: CassetteStore, name: str, attempt: dict):
    envelope = request_envelope(chat_request(name), store.secrets)
    store.append(envelope, {'source': 'synthetic', **attempt})


def make(directory: Path) -> int:
    if directory.exists() and any(directory.iterdir()):
        raise FileExistsError('synthetic cassette directory must be empty')
    previous = os.environ.get('LLM_BASE_URL')
    os.environ['LLM_BASE_URL'] = 'https://open.xiaojingai.com/v1'
    try:
        store = CassetteStore(directory, 'record', secrets=())
        success = stream({'choices': [{'delta': {'content': '可以'}}]}, '[DONE]')
        # The split lands inside a UTF-8 code point and across SSE lines.
        split = success.index('以'.encode('utf-8')) + 1
        add_chat(store, 'split-stream', {'kind': 'response', 'status': 200,
                 'headers': {'content-type': 'text/event-stream'},
                 'chunks_base64': [b64(success[:split]), b64(success[split:])]})
        thinking = stream({'choices': [{'delta': {'reasoning_content': 'only reasoning'}}]}, '[DONE]')
        add_chat(store, 'thinking-only', {'kind': 'response', 'status': 200,
                 'headers': {'content-type': 'text/event-stream'}, 'chunks_base64': [b64(thinking)]})
        refusal = stream({'choices': [{'delta': {'content': '抱歉，我无法回答这个问题'}}]}, '[DONE]')
        add_chat(store, 'refusal', {'kind': 'response', 'status': 200,
                 'headers': {'content-type': 'text/event-stream'}, 'chunks_base64': [b64(refusal)]})
        add_chat(store, 'html-homepage', {'kind': 'response', 'status': 200,
                 'headers': {'content-type': 'text/html; charset=utf-8'},
                 'chunks_base64': []})
        for code in (400, 401, 402, 403, 404, 422, 503):
            add_chat(store, f'http-{code}', {'kind': 'http_error', 'status': code,
                     'reason': 'fixture', 'headers': {'content-type': 'application/json'},
                     'body_base64': b64(json.dumps({'error': {'message': 'fixture error'}}).encode())})
        add_chat(store, 'open-timeout', {'kind': 'error',
                 'error': {'type': 'TimeoutError', 'message': 'fixture timeout'}})
        add_chat(store, 'stream-timeout', {'kind': 'response', 'status': 200,
                 'headers': {'content-type': 'text/event-stream'},
                 'chunks_base64': [b64(stream({'choices': [{'delta': {'content': 'partial'}}]}))],
                 'read_error': {'type': 'TimeoutError', 'message': 'fixture stream timeout'}})
        from pipeline import llm
        state = {'passage': '𠮷😀 asked a question.'}
        questions = {'q1': {'type': 'choice', 'instructions': 'Is this supported?',
                            'criteria': {'yes': 'Supported', 'no': 'Not supported'}}}
        chunk, dims = llm._classifier_batches(questions)[0]
        body = json.dumps({'items': [llm._state_text(state)], 'dimensions': dims},
                          ensure_ascii=False).encode('utf-8')
        request = urllib.request.Request('https://classifier.dev/v1/classify', data=body,
                                         method='POST', headers={'Content-Type': 'application/json'})
        envelope = request_envelope(request, store.secrets)
        answer = {'results': [{'dimensions': {'d0': {'label': 'yes', 'confidence': 0.9,
                                                   'scores': {'yes': 0.9, 'no': 0.1}}}}]}
        store.append(envelope, {'source': 'synthetic', 'kind': 'response', 'status': 200,
                     'headers': {'content-type': 'application/json'},
                     'chunks_base64': [b64(json.dumps(answer).encode('utf-8'))]})
        return store.count
    finally:
        if previous is None:
            os.environ.pop('LLM_BASE_URL', None)
        else:
            os.environ['LLM_BASE_URL'] = previous


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('out', type=Path)
    args = parser.parse_args()
    count = make(args.out)
    print(f'created {count} synthetic model/JEV cassettes')


if __name__ == '__main__':
    main()
