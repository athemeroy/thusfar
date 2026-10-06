import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from server import make_server


class RelayTest(unittest.TestCase):
    def test_disconnected_reader_and_restart_reuse_one_completed_inference(self):
        calls = []
        gate = threading.Event()
        body = b'data: {"choices":[{"delta":{"content":"fixture"}}]}\n\ndata: [DONE]\n\n'

        class Upstream(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                calls.append(self.rfile.read(int(self.headers['Content-Length'])))
                gate.wait(5)
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        upstream = ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        threading.Thread(target=upstream.serve_forever, daemon=True).start()
        with tempfile.TemporaryDirectory() as directory:
            server = make_server('127.0.0.1', 0,
                f'http://127.0.0.1:{upstream.server_port}/v1/chat/completions',
                'fixture-key', directory)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            base = f'http://127.0.0.1:{server.server_port}'
            headers = {'Authorization': 'Bearer fixture-key', 'Prefer': 'respond-async'}
            request = Request(base + '/v1/chat/completions',
                json.dumps({'stream': True, 'messages': []}).encode(), headers=headers)
            try:
                with urlopen(request, timeout=3) as response:
                    self.assertEqual(response.status, 202)
                    location = response.headers['Location']
                # The original phone connection is gone while upstream is busy.
                gate.set()
                result_request = Request(base + location, headers=headers)
                for _ in range(100):
                    with urlopen(result_request, timeout=3) as response:
                        if response.status == 200:
                            response.read(1)  # Simulate an interrupted result download.
                            break
                    time.sleep(.01)
                with urlopen(result_request, timeout=3) as response:
                    result = json.load(response)
                    self.assertEqual(result['body'], body.decode())
                self.assertEqual(len(calls), 1)
                with self.assertRaises(HTTPError) as denied:
                    urlopen(base + location, timeout=3)
                self.assertEqual(denied.exception.code, 401)
                denied.exception.close()
                self.assertEqual(len(calls), 1)
                from async_jobs import Jobs
                recovered = Jobs(directory, 'fixture-key', 'retained-chat-v1')
                self.assertEqual(recovered.get(location.split('job=')[1])[1], result)
                recovered.executor.shutdown()
                self.assertEqual(len(calls), 1)
                self.assertNotIn('messages', ''.join(p.read_text() for p in Path(directory).glob('*.json')))
            finally:
                gate.set()
                server.shutdown()
                server.server_close()
                server.jobs.executor.shutdown()
                upstream.shutdown()
                upstream.server_close()


if __name__ == '__main__':
    unittest.main()
