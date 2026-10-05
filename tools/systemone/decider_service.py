"""Serve the existing pinned Decider adapter for 页读; never call a provider."""
import argparse
import hashlib
import hmac
import json
import signal
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import threading
import time
from urllib.parse import urlsplit, parse_qs

import backends
from async_jobs import Jobs, Busy

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', default='192.168.31.38')
    parser.add_argument('--port', type=int, default=47838)
    parser.add_argument('--backend-port', type=int, default=47839)
    parser.add_argument('--key-file', type=Path, required=True)
    args = parser.parse_args()
    key = args.key_file.read_text().strip()
    if not key:
        raise ValueError('Missing service key')
    model = next(m for m in json.loads((ROOT / 'models.json').read_text())
                 if m['name'] == 'decider-0.8b')
    weights = ROOT / 'models' / model['name'] / model['file']
    with weights.open('rb') as model_file:
        if hashlib.file_digest(model_file, 'sha256').hexdigest() != model['sha256']:
            raise ValueError('Pinned model checksum mismatch')
    def stop(signum, frame):
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    backends.BASE = f'http://127.0.0.1:{args.backend_port}'
    backend = subprocess.Popen([
        str(ROOT / 'runtime/build/bin/llama-server'), '-m', str(weights),
        '--host', '127.0.0.1', '--port', str(args.backend_port),
        '-ngl', '99', '-c', '32768', '-b', '8192', '-ub', '512',
        '-t', '4', '-np', '1', '--no-webui',
    ])
    try:
        for _ in range(120):
            if backend.poll() is not None:
                raise RuntimeError('Decider backend stopped')
            try:
                props = backends.post('/props', timeout=2)
                if Path(props['model_path']).resolve() != weights.resolve():
                    raise RuntimeError('Unexpected backend model')
                break
            except OSError:
                time.sleep(0.5)
        else:
            raise RuntimeError('Decider backend did not become ready')
        engine = backends.Engine(model, context_budget=32768, cache_prompt=True)
        lock = threading.Lock()
        jobs = Jobs(args.key_file.parent / 'results', key, model['revision'])

        def compute(request):
            began = time.monotonic()
            with lock:
                answers = {name: engine.answer(request['state'], question)['answer']
                           for name, question in request['questions'].items()}
            print(json.dumps({'event': 'judged', 'questions': len(answers),
                              'at': time.time(),
                              'seconds': round(time.monotonic() - began, 3)}), flush=True)
            return {'model': model['name'], 'revision': model['revision'],
                    'answers': answers}

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, format, *values):
                pass

            def reply(self, status, value, headers=None):
                body = json.dumps(value, ensure_ascii=False).encode()
                self.send_response(status)
                self.send_header('Content-Type', 'application/json; charset=utf-8')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Cache-Control', 'no-store')
                for name, value in (headers or {}).items():
                    self.send_header(name, value)
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def do_GET(self):
                parts = urlsplit(self.path)
                if parts.path == '/v1/systemone':
                    if not self.authorized():
                        return
                    token = parse_qs(parts.query).get('job', [''])[0]
                    status, value = jobs.get(token)
                    self.reply(status, value)
                elif self.path == '/v1/decider/health':
                    self.reply(200 if backend.poll() is None else 503,
                               {'model': model['name'], 'revision': model['revision'],
                                'ready': backend.poll() is None})
                else:
                    self.reply(404, {'error': 'unknown_path'})

            def authorized(self):
                if not hmac.compare_digest(self.headers.get('Authorization', ''), 'Bearer ' + key):
                    self.reply(401, {'error': 'unauthorized'})
                    return False
                return True

            def do_POST(self):
                if self.path != '/v1/systemone':
                    self.reply(404, {'error': 'unknown_path'})
                    return
                if not self.authorized():
                    return
                try:
                    size = int(self.headers.get('Content-Length', '0'))
                    if not 0 < size <= 4 * 1024 * 1024:
                        raise ValueError('Invalid body size')
                    request = json.loads(self.rfile.read(size))
                    state, questions = request['state'], request['questions']
                    if request.get('model') not in (None, '', model['name']):
                        raise ValueError('Requested model is not served by this endpoint')
                    if not isinstance(questions, dict) or not 0 < len(questions) <= 100:
                        raise ValueError('Invalid question batch')
                    if self.headers.get('Prefer') == 'respond-async':
                        token = jobs.submit(request, compute)
                        self.reply(202, {'state': 'accepted'}, {
                            'Preference-Applied': 'respond-async',
                            'Location': '/v1/systemone?job=' + token,
                        })
                    else:
                        self.reply(200, compute(request))
                except Busy:
                    self.reply(429, {'error': 'queue_full'})
                except Exception as error:
                    print(json.dumps({'event': 'failed', 'error_type': type(error).__name__}), flush=True)
                    self.reply(422, {'error': 'decision_failed', 'error_type': type(error).__name__})

        server = ThreadingHTTPServer((args.host, args.port), Handler)
        server.daemon_threads = True
        print('DECIDER_READY', flush=True)
        server.serve_forever()
    finally:
        backend.terminate()
        try:
            backend.wait(timeout=10)
        except subprocess.TimeoutExpired:
            backend.kill()
            backend.wait()


if __name__ == '__main__':
    main()
