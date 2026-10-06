"""Small read-only service monitor; never records inputs, keys, or job tokens."""
from collections import deque
import json
import logging
from logging.handlers import RotatingFileHandler
from pathlib import Path
import threading
import time
import urllib.request


class Monitor:
    def __init__(self, directory, model, machine, health, hardware_url=None, key=''):
        self.directory = Path(directory)
        self.path = self.directory / 'activity-summary.json'
        self.lock = threading.RLock()
        self.model, self.machine = model, machine
        self.started = time.time()
        self.totals = {'since': self.started, 'checks': 0, 'questions': 0,
                       'failures': 0, 'seconds': 0.0}
        self.history = deque(maxlen=100)
        if self.path.exists():
            try:
                saved = json.loads(self.path.read_text())
                self.totals.update(saved['totals'])
                self.history.extend(saved['history'])
            except (OSError, ValueError, KeyError):
                pass
        self.current = None
        self.sync_waiting = 0
        self.hardware = None
        self.hardware_at = None
        self.ready = False
        self.checked_at = None
        handler = RotatingFileHandler(self.directory / 'activity.jsonl',
                                      maxBytes=2 * 1024 * 1024, backupCount=2,
                                      encoding='utf-8')
        handler.setFormatter(logging.Formatter('%(message)s'))
        self.logger = logging.getLogger('decider.activity')
        self.logger.setLevel(logging.INFO)
        self.logger.propagate = False
        self.logger.addHandler(handler)
        self._log({'event': 'started', 'at': self.started, 'model': model,
                   'machine': machine})
        def sample():
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            while True:
                try:
                    ready = health()
                except OSError:
                    ready = False
                hardware = None
                if hardware_url:
                    try:
                        req = urllib.request.Request(hardware_url,
                            headers={'Authorization': 'Bearer ' + key})
                        with opener.open(req, timeout=3) as response:
                            gpu = json.load(response).get('machine', {}).get('gpu')
                        if gpu:
                            hardware = {k: gpu.get(k) for k in
                                        ('name', 'used_mib', 'total_mib', 'util_pct', 'temp_c')}
                    except (OSError, ValueError):
                        pass
                with self.lock:
                    self.ready, self.checked_at = ready, time.time()
                    if hardware:
                        self.hardware, self.hardware_at = hardware, time.time()
                time.sleep(5)
        threading.Thread(target=sample, daemon=True, name='decider-monitor').start()

    def _log(self, event):
        self.logger.info(json.dumps(event, ensure_ascii=False, separators=(',', ':')))

    def queued(self, asynchronous):
        if not asynchronous:
            with self.lock:
                self.sync_waiting += 1

    def begin(self, questions, asynchronous):
        with self.lock:
            if not asynchronous:
                self.sync_waiting -= 1
            self.current = {'started': time.time(), 'questions': questions,
                            'done': 0, 'asynchronous': asynchronous}

    def step(self):
        with self.lock:
            self.current['done'] += 1

    def finish(self, error=None):
        with self.lock:
            current = self.current
            elapsed = round(time.time() - current['started'], 3)
            event = {'event': 'failed' if error else 'completed', 'at': time.time(),
                     'questions': current['questions'], 'done': current['done'],
                     'seconds': elapsed}
            if error:
                event['error_type'] = type(error).__name__
                self.totals['failures'] += 1
            else:
                self.totals['checks'] += 1
            self.totals['questions'] += current['done']
            self.totals['seconds'] += elapsed
            self.history.appendleft(event)
            self.current = None
            self._log(event)
            temporary = self.path.with_suffix('.tmp')
            try:
                temporary.write_text(json.dumps({'totals': self.totals,
                                                'history': list(self.history)}, ensure_ascii=False))
                temporary.chmod(0o600)
                temporary.replace(self.path)
            except OSError:
                self._log({'event': 'log_save_failed', 'at': time.time()})

    def snapshot(self, pending):
        with self.lock:
            current = dict(self.current) if self.current else None
            if current:
                current['seconds'] = round(time.time() - current['started'], 1)
            return {'model': self.model, 'machine': self.machine,
                    'ready': self.ready, 'checked_at': self.checked_at,
                    'started': self.started, 'now': time.time(),
                    'current': current,
                    'queued': max(0, pending - int(bool(current and current['asynchronous']))) + self.sync_waiting,
                    'totals': dict(self.totals), 'history': list(self.history),
                    'hardware': self.hardware, 'hardware_at': self.hardware_at}
