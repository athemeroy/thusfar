"""Retain local judgment results independently of the requesting connection."""
import hashlib
import hmac
import json
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import re
import threading


class Busy(Exception):
    pass


class Jobs:
    def __init__(self, directory, key, revision):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.key = key.encode()
        self.revision = revision
        self.lock = threading.RLock()
        self.active = set()
        self.executor = ThreadPoolExecutor(max_workers=1)

    def submit(self, request, compute):
        payload = json.dumps([self.revision, request], sort_keys=True,
                             ensure_ascii=False, separators=(',', ':')).encode()
        token = hmac.new(self.key, payload, hashlib.sha256).hexdigest()
        with self.lock:
            if (self.directory / (token + '.json')).exists() or token in self.active:
                return token
            if len(self.active) >= 8:
                raise Busy()
            self.active.add(token)
            self.executor.submit(self._run, token, request, compute)
        return token

    def _run(self, token, request, compute):
        try:
            try:
                result = {'status': 200, 'body': compute(request)}
            except Exception as error:
                result = {'status': 422, 'body': {'error': 'decision_failed',
                                                'error_type': type(error).__name__}}
            with self.lock:
                target = self.directory / (token + '.json')
                temporary = target.with_suffix('.tmp')
                temporary.write_text(json.dumps(result, ensure_ascii=False))
                temporary.chmod(0o600)
                temporary.replace(target)
                completed = sorted(self.directory.glob('*.json'),
                                   key=lambda p: p.stat().st_mtime)
                for old in completed[:-256]:
                    old.unlink()
        finally:
            with self.lock:
                self.active.discard(token)

    def get(self, token):
        if not re.fullmatch('[0-9a-f]{64}', token):
            return 404, {'error': 'unknown_job'}
        with self.lock:
            path = self.directory / (token + '.json')
            if path.exists():
                result = json.loads(path.read_text())
                return result['status'], result['body']
            if token in self.active:
                return 202, {'state': 'running'}
            # Restarted/expired jobs are never silently recreated by a GET.
            return 410, {'error': 'result_unavailable'}
