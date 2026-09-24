"""Serve our own fine-tuned judge over the same HTTP shape the pipeline already speaks.

    python3 scripts/judge_server.py --model ~/judge/bal-out/final_model [--port 8008]

Then point the pipeline at it and change nothing else:

    CLASSIFIER_URL=http://127.0.0.1:8008/v1/classify JEV_ROUTE=free scripts/run_all.sh …

`pipeline/llm.py` already has a client for the classifier.dev protocol (`jev_free`), so speaking
that protocol means the local judge slots in with no change to the pipeline, no new route to keep
working, and the circuit breaker, retry and accounting all still apply. Answering the same shape as
the service it replaces is the whole trick.

Why a server rather than importing the model into the pipeline: the model wants a GPU that lives on
a different machine from the one parsing books, loading it costs seconds, and a book runs sixteen
extraction workers at once. One process holds the weights; everyone else asks over the LAN.

The wire format, both directions:

    POST /v1/classify
    {"items": ["<the passage>"],
     "dimensions": {"d0": {"labels": ["supported", "not_in_passage", …],
                           "instructions": "<the question>\\nChoose one label:\\n- supported: …"}}}

    {"results": [{"dimensions": {"d0": {"label": "supported", "confidence": 0.91,
                                        "scores": {"supported": 0.91, …}}}}]}

GET /health reports the model, device and how many questions it has answered.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gliclass_data import labels_of  # noqa: E402  (one source of truth for how labels are worded)

# `jev_free` folds each option's description into the instructions as "- key: description"; the
# model was trained on those descriptions, not on our code identifiers, so they are read back out.
OPTION_LINE = re.compile(r'^\s*[-*]\s*([^:：]{1,64})\s*[:：]\s*(.+?)\s*$')
STATS = {'calls': 0, 'questions': 0, 'seconds': 0.0, 'started': time.time()}
_lock = threading.Lock()


def criteria_of(labels: list[str], instructions: str) -> tuple[dict, str]:
    """({option key: description}, the question without the option list).

    Falls back to empty descriptions for any label the instructions do not describe, which is what
    a caller that sends bare labels gets — the model then sees the key as the label, the way it
    would have during training for options our exporter had no description for.
    """
    desc, keep = {}, []
    for line in (instructions or '').splitlines():
        m = OPTION_LINE.match(line)
        if m and m.group(1).strip() in labels:
            desc[m.group(1).strip()] = m.group(2).strip()
        elif line.strip() and not line.strip().lower().startswith('choose one label'):
            keep.append(line)
    return {k: desc.get(k, '') for k in labels}, '\n'.join(keep).strip()


class Judge:
    def __init__(self, model_name: str, device: str | None, max_chars: int):
        import torch
        from gliclass import GLiClassModel, ZeroShotClassificationPipeline
        from transformers import AutoTokenizer

        name = device or ('mps' if torch.backends.mps.is_available()
                          else 'cuda:0' if torch.cuda.is_available() else 'cpu')
        # GLiClass's pipeline only honours CUDA *strings* and silently drops everything else to the
        # CPU (pipeline.py:203). A torch.device object is passed through, which is how Metal is
        # used at all — it was worth 7x when this was first missed.
        self.device = torch.device(name)
        self.model = GLiClassModel.from_pretrained(model_name)
        tok = AutoTokenizer.from_pretrained(model_name)
        self.pipe = ZeroShotClassificationPipeline(
            self.model, tok, classification_type='multi-label', device=self.device,
            progress_bar=False)
        self.name = model_name
        self.max_chars = max_chars
        # one GPU, one question at a time: batching measured slower than one-by-one, because a
        # batch pads every text to the longest in it
        self.gate = threading.Lock()

    def answer(self, text: str, labels: list[str], instructions: str) -> dict:
        options, question = criteria_of(labels, instructions)
        shown, back = labels_of(options)
        with self.gate:
            got = self.pipe(text[:self.max_chars], shown, prompt=question, threshold=0.0)[0]
        scores = {back.get(g['label'], g['label']): round(float(g['score']), 4) for g in got}
        for k in labels:                      # never answer with a label we were not offered
            scores.setdefault(k, 0.0)
        scores = {k: scores[k] for k in labels}
        pick = max(scores, key=scores.get)
        return {'label': pick, 'confidence': scores[pick], 'scores': scores}


class Handler(BaseHTTPRequestHandler):
    judge: Judge = None                       # set in main()
    protocol_version = 'HTTP/1.1'

    def _send(self, code: int, body: dict) -> None:
        raw = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):                         # noqa: N802
        if self.path.rstrip('/') in ('/health', ''):
            up = time.time() - STATS['started']
            rate = STATS['questions'] / up * 60 if up else 0
            self._send(200, {'model': self.judge.name, 'device': str(self.judge.device),
                             'calls': STATS['calls'], 'questions': STATS['questions'],
                             'seconds_in_model': round(STATS['seconds'], 1),
                             'questions_per_minute': round(rate, 1),
                             'uptime_seconds': round(up)})
        else:
            self._send(404, {'error': 'only /v1/classify and /health'})

    def do_POST(self):                        # noqa: N802
        if self.path.rstrip('/') != '/v1/classify':
            return self._send(404, {'error': 'only /v1/classify'})
        try:
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length') or 0)))
        except Exception as e:
            return self._send(400, {'error': f'bad JSON: {e}'})
        items = body.get('items') or ['']
        dims = body.get('dimensions') or {}
        t0 = time.time()
        results = []
        try:
            for text in items:
                out = {}
                for key, d in dims.items():
                    labels = [str(x) for x in (d.get('labels') or [])]
                    if len(labels) < 2:
                        out[key] = {'label': labels[0] if labels else None, 'confidence': 1.0,
                                    'scores': {labels[0]: 1.0} if labels else {}}
                        continue
                    out[key] = self.judge.answer(str(text), labels, d.get('instructions') or '')
                results.append({'dimensions': out})
        except Exception as e:
            return self._send(500, {'error': f'{type(e).__name__}: {e}'})
        with _lock:
            STATS['calls'] += 1
            STATS['questions'] += len(dims) * len(items)
            STATS['seconds'] += time.time() - t0
        self._send(200, {'results': results})

    def log_message(self, *a):                # the pipeline's own log is the one worth reading
        pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--model', required=True, help='a fine-tuned GLiClass directory, or a Hub name')
    ap.add_argument('--port', type=int, default=8008)
    ap.add_argument('--host', default='0.0.0.0')
    ap.add_argument('--device', default=None, help='mps / cuda:0 / cpu (default: best available)')
    ap.add_argument('--max-chars', type=int, default=800,
                    help='passages are cut to this, matching what the model was trained on')
    a = ap.parse_args()

    t0 = time.time()
    Handler.judge = Judge(a.model, a.device, a.max_chars)
    print(f'{a.model} 载入 {time.time() - t0:.1f}s，device={Handler.judge.device}', flush=True)
    srv = ThreadingHTTPServer((a.host, a.port), Handler)
    print(f'裁判服务已启动: http://{a.host}:{a.port}/v1/classify  （健康检查 /health）', flush=True)
    print(f'用法: CLASSIFIER_URL=http://<本机>:{a.port}/v1/classify JEV_ROUTE=free '
          f'scripts/run_all.sh …', flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print('\n停止', flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
