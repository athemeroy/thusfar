"""Keep one local Qwen completion alive independently of the phone connection.

Only explicit asynchronous requests reach this private relay. Normal streaming
clients continue to use the existing upstream route. No model calls are retried.
"""
import argparse
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
import time
from urllib.error import HTTPError
from urllib.parse import urlsplit, parse_qs
from urllib.request import Request, urlopen
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'systemone'))
from async_jobs import Jobs, Busy

MAX_BYTES = 16 * 1024 * 1024


def make_server(host, port, upstream, key, directory):
    jobs = Jobs(directory, key, 'retained-chat-v1')

    def compute(request):
        started = time.monotonic()
        call = Request(upstream, json.dumps(request['body']).encode(), headers={
            'Authorization': 'Bearer ' + key, 'Content-Type': 'application/json',
        })
        try:
            try:
                response = urlopen(call, timeout=600)
            except HTTPError as error:
                response = error
            with response:
                raw = response.read(MAX_BYTES + 1)
                if len(raw) > MAX_BYTES:
                    raise ValueError('response_too_large')
                result = {'status': response.status,
                          'content_type': response.headers.get('Content-Type', ''),
                          'body': raw.decode('utf-8')}
        except Exception as error:
            # The upstream may have computed: persist the failure, never replay it.
            result = {'status': 502, 'content_type': 'application/json',
                      'body': json.dumps({'error': 'upstream_interrupted',
                                          'type': type(error).__name__})}
        print(json.dumps({'event': 'completion_saved', 'status': result['status'],
                          'bytes': len(result['body'].encode()),
                          'seconds': round(time.monotonic() - started, 3)}), flush=True)
        return result

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, status, value, headers=None):
            raw = json.dumps(value, ensure_ascii=False).encode()
            try:
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(raw)))
                self.send_header('Cache-Control', 'no-store')
                for name, value in (headers or {}).items():
                    self.send_header(name, value)
                self.end_headers()
                self.wfile.write(raw)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def authorized(self):
            if not hmac.compare_digest(self.headers.get('Authorization', ''),
                                       'Bearer ' + key):
                self.reply(401, {'error': 'unauthorized'})
                return False
            return True

        def do_POST(self):
            if urlsplit(self.path).path != '/v1/chat/completions':
                return self.reply(404, {'error': 'unknown_path'})
            if not self.authorized():
                return
            if 'respond-async' not in self.headers.get('Prefer', '').lower():
                return self.reply(400, {'error': 'async_required'})
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 < length <= MAX_BYTES:
                    return self.reply(413, {'error': 'request_size'})
                body = json.loads(self.rfile.read(length))
                if not isinstance(body, dict) or body.get('stream') is not True:
                    return self.reply(400, {'error': 'stream_required'})
                # Every explicit new call has its own job. A result GET never
                # generates, including after service restart or expiration.
                token = jobs.submit({'nonce': uuid.uuid4().hex, 'body': body}, compute)
            except Busy:
                return self.reply(429, {'error': 'busy'})
            except (ValueError, TypeError):
                return self.reply(400, {'error': 'invalid_request'})
            self.reply(202, {'state': 'accepted'}, {
                'Preference-Applied': 'respond-async',
                'Location': '/v1/chat/completions?job=' + token,
            })

        def do_GET(self):
            if self.path == '/health':
                return self.reply(200, {'ready': True})
            parts = urlsplit(self.path)
            if parts.path != '/v1/chat/completions':
                return self.reply(404, {'error': 'unknown_path'})
            if not self.authorized():
                return
            token = parse_qs(parts.query).get('job', [''])[0]
            status, result = jobs.get(token)
            self.reply(status, result)

    server = ThreadingHTTPServer((host, port), Handler)
    server.jobs = jobs
    return server


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--host', default='0.0.0.0')
    parser.add_argument('--port', type=int, default=8080)
    parser.add_argument('--upstream', required=True)
    parser.add_argument('--key-file', type=Path, required=True)
    parser.add_argument('--results', type=Path, required=True)
    args = parser.parse_args()
    key = args.key_file.read_text().strip()
    if not key:
        raise ValueError('missing_key')
    make_server(args.host, args.port, args.upstream, key, args.results).serve_forever()


if __name__ == '__main__':
    main()
