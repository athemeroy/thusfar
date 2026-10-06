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
from monitor import Monitor

ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', default='192.168.31.38')
    parser.add_argument('--port', type=int, default=47838)
    parser.add_argument('--backend-port', type=int, default=47839)
    parser.add_argument('--backend-url', help='Use an independently managed llama-server')
    parser.add_argument('--key-file', type=Path, required=True)
    parser.add_argument('--machine', default='MINI')
    parser.add_argument('--hardware-status-url')
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
    backends.BASE = args.backend_url or f'http://127.0.0.1:{args.backend_port}'
    backend = None if args.backend_url else subprocess.Popen([
        str(ROOT / 'runtime/build/bin/llama-server'), '-m', str(weights),
        '--host', '127.0.0.1', '--port', str(args.backend_port),
        '-ngl', '99', '-c', '32768', '-b', '8192', '-ub', '512',
        '-t', '4', '-np', '1', '--no-webui',
    ])
    try:
        for _ in range(120):
            if backend is not None and backend.poll() is not None:
                raise RuntimeError('Decider backend stopped')
            try:
                props = backends.post('/props', timeout=2)
                remote_name = str(props['model_path']).replace('\\', '/').split('/')[-1]
                matches = (remote_name == weights.name if args.backend_url else
                           Path(props['model_path']).resolve() == weights.resolve())
                if not matches:
                    raise RuntimeError('Unexpected backend model')
                break
            except OSError:
                time.sleep(0.5)
        else:
            raise RuntimeError('Decider backend did not become ready')
        engine = backends.Engine(model, context_budget=32768, cache_prompt=True)
        lock = threading.Lock()
        jobs = Jobs(args.key_file.parent / 'results', key, model['revision'])

        monitor = Monitor(args.key_file.parent, model['name'], args.machine,
                          lambda: backends.post('/health', timeout=2).get('status') == 'ok',
                          args.hardware_status_url, key)

        def compute(request, asynchronous=False):
            began = time.monotonic()
            monitor.queued(asynchronous)
            with lock:
                monitor.begin(len(request['questions']), asynchronous)
                try:
                    answers = {}
                    for name, question in request['questions'].items():
                        answers[name] = engine.answer(request['state'], question)['answer']
                        monitor.step()
                except Exception as error:
                    monitor.finish(error)
                    raise
                monitor.finish()
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

            def raw_reply(self, status, body, content_type, headers=None):
                self.send_response(status)
                self.send_header('Content-Type', content_type)
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
                if parts.path in ('/v1/decider/dashboard', '/v1/decider/dashboard/'):
                    self.raw_reply(200, (ROOT / 'dashboard.html').read_bytes(),
                                   'text/html; charset=utf-8')
                elif parts.path == '/v1/decider/dashboard.json':
                    with jobs.lock:
                        pending = len(jobs.active)
                    self.reply(200, monitor.snapshot(pending))
                elif parts.path == '/v1/decider/logs':
                    rows = monitor.snapshot(0)['history']
                    body = '\n'.join(json.dumps(row, ensure_ascii=False) for row in rows).encode()
                    self.raw_reply(200, body, 'application/x-ndjson; charset=utf-8',
                                   {'Content-Disposition': 'attachment; filename=decider-log.jsonl'})
                elif parts.path == '/v1/systemone':
                    if not self.authorized():
                        return
                    token = parse_qs(parts.query).get('job', [''])[0]
                    status, value = jobs.get(token)
                    self.reply(status, value)
                elif self.path == '/v1/decider/health':
                    try:
                        ready = backends.post('/health', timeout=2).get('status') == 'ok'
                    except OSError:
                        ready = False
                    self.reply(200 if ready else 503,
                               {'model': model['name'], 'revision': model['revision'],
                                'ready': ready})
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
                        token = jobs.submit(request, lambda value: compute(value, True))
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
        if backend is not None:
            backend.terminate()
            try:
                backend.wait(timeout=10)
            except subprocess.TimeoutExpired:
                backend.kill()
                backend.wait()


if __name__ == '__main__':
    main()
