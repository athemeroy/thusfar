"""Start the existing standard-library server inside the Android process."""
import os
import json
import secrets
import threading
import time
from pathlib import Path

_server = None
_thread = None
_lock = threading.Lock()


def start(data_dir):
    """Return the loopback port and an HttpOnly session value for this launch."""
    global _server, _thread
    with _lock:
        if _server is None:
            private = Path(data_dir)
            private.mkdir(parents=True, exist_ok=True)
            os.environ['DATA_DIR'] = data_dir
            os.environ['AUTO_PROCESS'] = '0'
            os.environ['COOKIE_SECURE'] = '0'
            os.environ['YEDU_WORKER_MODE'] = 'thread'
            os.environ['YEDU_LOCAL_MODE'] = '1'
            os.environ['PASSCODE'] = secrets.token_urlsafe(32)
            os.environ['SECRETS_FILE'] = str(private / '.model.env')
            from server import model_settings
            model_settings.apply_environment()
            from server import app
            app.BOOKS.mkdir(parents=True, exist_ok=True)
            app.secret()
            # A previous app process may have been killed while a job was running.
            # Leave its source journal intact and wait for an explicit resume tap.
            for status_file in app.BOOKS.glob('*/status.json'):
                try:
                    state = json.loads(status_file.read_text())
                    if state.get('state') in ('running', 'finalizing', 'cancelling', 'queued'):
                        state.update(state='paused', updated=time.time(), error=None)
                        app.wjson(status_file, state)
                except (OSError, ValueError):
                    pass
            # WebView storage is scoped to the full origin, including its port. Reuse
            # the first random port so drafts survive an app process restart.
            port_file = private / '.loopback-port'
            try:
                port = int(port_file.read_text()) if port_file.exists() else 0
            except (OSError, ValueError):
                port = 0
            if not 1024 <= port <= 65535:
                port = 0
            try:
                _server = app.BoundedHTTPServer(('127.0.0.1', port), app.Handler)
            except OSError:
                if not port:
                    raise
                # A stale port may have been claimed by another local app.
                _server = app.BoundedHTTPServer(('127.0.0.1', 0), app.Handler)
            if _server.server_port != port:
                temporary = port_file.with_suffix('.tmp')
                fd = os.open(temporary, os.O_CREAT | os.O_TRUNC | os.O_WRONLY, 0o600)
                with os.fdopen(fd, 'w') as handle:
                    handle.write(str(_server.server_port))
                os.replace(temporary, port_file)
            app.WORKER.start()
            _thread = threading.Thread(target=_server.serve_forever, daemon=True,
                                       name='yedu-loopback-server')
            _thread.start()
        from server import app
        return f'{_server.server_port}\n{app.token()}'


def processing_status():
    from server import app
    worker = app.WORKER.health()
    current = worker['current']
    if current:
        directory = app.BOOKS / current
        state = app.cached_json(directory / 'status.json') or {}
        book = app.cached_json(directory / 'book.json') or {}
        return json.dumps({'active': True, 'title': book.get('title') or '这本书',
                           'done': state.get('done') or 0, 'total': state.get('total') or 0,
                           'state': state.get('state') or 'running'}, ensure_ascii=False)
    for status_file in app.BOOKS.glob('*/status.json'):
        state = app.cached_json(status_file) or {}
        if state.get('state') == 'queued':
            book = app.cached_json(status_file.parent / 'book.json') or {}
            return json.dumps({'active': True, 'title': book.get('title') or '这本书',
                               'done': state.get('done') or 0, 'total': state.get('total') or 0,
                               'state': 'queued'}, ensure_ascii=False)
    return '{"active":false}'


def request_processing_stop():
    """Android is ending foreground execution; stop at the next safe checkpoint."""
    from server import app
    with app.WORKER.lock:
        if app.WORKER.cancel_event is not None:
            app.WORKER.cancel_event.set()
