"""HTTP server for the spoiler-free reader (stdlib only).

The browser never receives knowledge-graph records beyond the position it asks for, and
it only asks for the end of the page the reader is on — so even devtools cannot spoil.

Env:
  DATA_DIR      data root (default: <app>/data)
  PASSCODE      if set, the API requires logging in with this passcode
  AUTO_PROCESS  1 = automatically run the AI pipeline for uploaded books (default 1)
  SECRETS_FILE  env-style file with model keys (read by pipeline.llm)
"""
from __future__ import annotations

import gzip
import hashlib
import hmac
import json
import mimetypes
import os
import re
import secrets
import shutil
import socket
import signal
import sys
import tempfile
import threading
import time
import traceback
import urllib.parse
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from collections import OrderedDict

APP = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(APP))

from pipeline.parse import parse_file  # noqa: E402
from server import ask as ask_mod  # noqa: E402
from server import storage, notebook, manual_entities, reading_list, marginalia, model_settings  # noqa: E402
from server.jobs import BusyBook, Worker, book_lease  # noqa: E402

DATA = Path(os.environ.get('DATA_DIR') or APP / 'data')
BOOKS = DATA / 'books'
WEB = Path(os.environ.get('WEB_DIR') or APP / 'web')
PASSCODE = os.environ.get('PASSCODE', '')
AUTO = os.environ.get('AUTO_PROCESS', '1') == '1'
LOCAL_MODE = os.environ.get('YEDU_LOCAL_MODE') == '1'
MAX_UPLOAD = 200 * 1024 * 1024
SECRET_FILE = DATA / '.cookie-secret'
RELEASE = os.environ.get('YEDU_RELEASE_ID') or os.environ.get('RELEASE_ID') or '1.7.1'
READ_TIMEOUT = float(os.environ.get('HTTP_READ_TIMEOUT', '30'))
COOKIE_SECURE = os.environ.get('COOKIE_SECURE', '1') == '1'
_ask_gate = threading.BoundedSemaphore(int(os.environ.get('ASK_CONCURRENCY', '2')))
_import_gate = threading.BoundedSemaphore(2)

_lock = threading.RLock()
_cache = storage.JsonCache()
_login_attempts = OrderedDict()


def secret() -> bytes:
    with _lock:
        DATA.mkdir(parents=True, exist_ok=True)
        if not SECRET_FILE.exists():
            fd = os.open(SECRET_FILE, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(fd, 'w') as f:
                f.write(secrets.token_hex(32))
        return SECRET_FILE.read_text().strip().encode()


def token() -> str:
    payload = f'v1.{int(time.time())}.{secrets.token_hex(12)}'
    signature = hmac.new(secret(), (payload + ':' + PASSCODE).encode(), hashlib.sha256).hexdigest()
    return payload + '.' + signature


def cached_json(path: Path):
    return _cache.get(path)


def wjson(path: Path, data):
    storage.write_json(path, data)
    _cache.evict(path)


def book_dir(bid: str) -> Path | None:
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', bid or ''):
        return None
    d = BOOKS / bid
    return d if (d / 'book.json').exists() else None


def progress_all() -> dict:
    return cached_json(DATA / 'progress.json') or {}


def book_summary(bid: str, d: Path) -> dict:
    b = storage.shelf_metadata(d, _cache)
    st = cached_json(d / 'status.json') or {}
    meta = cached_json(d / 'meta.json') or {}
    from pipeline.models import cost_of, estimate
    done = st.get('state') == 'done'
    title, author = storage.display_title(b.get('title'), b.get('author'))
    return {'id': bid, 'title': title, 'author': author, 'len': b.get('len'),
            'cover': b.get('cover') or meta.get('cover'), 'added': meta.get('added', 0), 'status': st,
            'chapters': b['chapters'], 'auto': bool(meta.get('auto')),
            'lang': b.get('lang') or 'zh', 'genre': b.get('genre') or 'novel',
            # a file that is mostly blurb (a sample, a failed download) is worth saying out loud
            'thin': b['thin'],
            'est': estimate(b.get('len') or 0, lang=b.get('lang') or 'zh'),
            'spent': cost_of(st.get('usage') or {}) if done or st.get('done') else None,
            'progress': progress_all().get(bid)}


WORKER = Worker(BOOKS, APP, cached_json, wjson, AUTO)


# ------------------------------------------------------------------ HTTP
class Handler(BaseHTTPRequestHandler):
    server_version = 'Yedu/2'
    protocol_version = 'HTTP/1.1'

    def setup(self):
        super().setup()
        self.connection.settimeout(READ_TIMEOUT)

    def log_message(self, fmt, *args):
        if os.environ.get('ACCESS_LOG'):
            super().log_message(fmt, *args)

    # helpers -------------------------------------------------------------
    def send(self, code: int, body: bytes, ctype: str, headers: dict | None = None):
        headers = dict(headers or {})
        if 'Content-Encoding' not in headers and len(body) > 2048 and ('json' in ctype or ctype.startswith('text/') or 'javascript' in ctype) \
                and 'gzip' in (self.headers.get('Accept-Encoding') or ''):
            body = gzip.compress(body, 5)
            headers['Content-Encoding'] = 'gzip'
            headers['Vary'] = 'Accept-Encoding'
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('X-Yedu-Release', RELEASE)
        for k, v in headers.items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def json(self, data, code: int = 200, headers: dict | None = None):
        body = json.dumps(data, ensure_ascii=False, separators=(',', ':')).encode()
        h = {'Cache-Control': 'no-store'}
        h.update(headers or {})
        self.send(code, body, 'application/json; charset=utf-8', h)

    def err(self, code: int, msg: str):
        self.close_connection = True
        self.json({'error': msg}, code)

    def body_json(self):
        data = json.loads(self.body() or b'{}')
        if not isinstance(data, dict):
            raise ValueError('请求必须是 JSON 对象')
        return data

    def body(self, limit: int = 1 << 20) -> bytes:
        lengths = self.headers.get_all('Content-Length', [])
        if self.headers.get('Transfer-Encoding') or len(lengths) > 1:
            self.close_connection = True
            raise ValueError('请求长度格式无效')
        raw = lengths[0] if lengths else '0'
        if not re.fullmatch(r'[0-9]+', raw.strip()):
            self.close_connection = True
            raise ValueError('请求长度格式无效')
        n = int(raw)
        if n > limit:
            self.close_connection = True
            raise ValueError('请求太大')
        result = self.rfile.read(n) if n else b''
        if len(result) != n:
            self.close_connection = True
            raise ValueError('请求没有完整传输')
        return result

    def authed(self) -> bool:
        if not PASSCODE:
            return True
        c = self.headers.get('Cookie') or ''
        m = re.search(r'(?:^|;\s*)yedu=(v1\.([0-9]+)\.[a-f0-9]{24})\.([a-f0-9]{64})(?:;|$)', c)
        if not m or not 0 <= time.time() - int(m.group(2)) <= 7 * 86400:
            return False
        expected = hmac.new(secret(), (m.group(1) + ':' + PASSCODE).encode(), hashlib.sha256).hexdigest()
        return hmac.compare_digest(m.group(3), expected)

    # routing -------------------------------------------------------------
    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        try:
            self.route('GET')
        except BrokenPipeError:
            pass
        except (ValueError, BusyBook) as e:
            self.err(400 if isinstance(e, ValueError) else 409, str(e))
        except Exception:
            traceback.print_exc()
            self.err(500, '服务器出错了')

    def _write(self, method: str):
        try:
            self.route(method)
        except BrokenPipeError:
            pass
        except (TimeoutError, socket.timeout):
            self.close_connection = True
            self.err(408, '请求超时')
        except BusyBook as e:
            self.err(409, str(e))
        except ValueError as e:
            self.err(400, str(e))
        except Exception:
            traceback.print_exc()
            self.err(500, '服务器出错了')

    def do_POST(self):
        self._write('POST')

    def do_PUT(self):
        self._write('PUT')

    def do_DELETE(self):
        self._write('DELETE')

    def route(self, method: str):
        url = urllib.parse.urlsplit(self.path)
        path = url.path
        q = dict(urllib.parse.parse_qsl(url.query))
        if path == '/healthz' and method == 'GET':
            state = WORKER.health()
            healthy = not state['enabled'] or state['alive']
            return self.json({'ok': healthy, 'release': RELEASE}, 200 if healthy else 503)
        if not path.startswith('/api/'):
            return self.static(path)
        if method in ('POST', 'PUT', 'DELETE'):
            origin = self.headers.get('Origin')
            if origin and urllib.parse.urlsplit(origin).netloc != self.headers.get('Host'):
                return self.err(403, '只接受本站请求')
        if path == '/api/login' and method == 'POST':
            data = self.body_json()
            now = time.monotonic()
            with _lock:
                key = self.client_address[0]
                attempts = [t for t in _login_attempts.get(key, []) if now - t < 60]
                if len(attempts) >= 10:
                    return self.json({'error': '尝试次数过多，请一分钟后重试'}, 429,
                                     {'Retry-After': '60'})
                _login_attempts[key] = attempts + [now]
                _login_attempts.move_to_end(key)
                while len(_login_attempts) > 256:
                    _login_attempts.popitem(last=False)
            if PASSCODE and not hmac.compare_digest(str(data.get('code', '')), PASSCODE):
                time.sleep(1)
                return self.err(401, '口令不对')
            return self.json({'ok': True}, headers={
                'Set-Cookie': f'yedu={token()}; Path=/; Max-Age=604800; HttpOnly; SameSite=Lax' +
                              ('; Secure' if COOKIE_SECURE else '')})
        if path == '/api/me':
            return self.json({'ok': self.authed(), 'passcode': bool(PASSCODE)})
        if not self.authed():
            return self.err(401, '需要口令')
        if path == '/api/logout' and method == 'POST':
            return self.json({'ok': True}, headers={'Set-Cookie': 'yedu=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax' + ('; Secure' if COOKIE_SECURE else '')})
        if path == '/api/health' and method == 'GET':
            return self.json({'release': RELEASE, 'worker': WORKER.health(),
                              'cache': {'entries': len(_cache.entries), 'serialized_bytes': _cache.size}})
        if path == '/api/settings' and LOCAL_MODE and method in ('GET', 'PUT'):
            if method == 'GET':
                return self.json(model_settings.public())
            payload = self.body_json()
            with WORKER.lock:
                if WORKER.current is not None:
                    return self.err(409, '正在整理书籍，请完成或暂停后再修改模型设置')
                return self.json(model_settings.save(payload))
        if path == '/api/reading-list' and method in ('GET', 'PUT'):
            payload = self.body_json() if method == 'PUT' else None
            with _lock:
                target = DATA / 'reading-list.json'
                current = cached_json(target) or reading_list.empty()
                if method == 'GET':
                    return self.json(current)
                def visible(book_id):
                    directory = book_dir(book_id)
                    return directory is not None and not (cached_json(directory / 'meta.json') or {}).get('hidden')
                updated, conflict = reading_list.apply(current, payload, visible)
                if conflict:
                    return self.json({'error': '另一台设备更新了书单，请选择要保留的顺序', 'list': current}, 409)
                if updated is not current:
                    wjson(target, updated)
                return self.json(updated)
        if path == '/api/books' and method == 'GET':
            out = []
            for d in BOOKS.glob('*/book.json'):
                if d.parent.name.startswith('.'):
                    continue
                # internal comparison copies (meta.hidden) stay reachable by link but off the shelf
                if (cached_json(d.parent / 'meta.json') or {}).get('hidden'):
                    continue
                out.append(book_summary(d.parent.name, d.parent))
            out.sort(key=lambda b: -max((b.get('progress') or {}).get('t', 0), b.get('added', 0)))
            return self.json(out)
        if path == '/api/books' and method == 'POST':
            return self.import_request(self.upload)
        if path == '/api/books/import' and method == 'POST':
            return self.import_request(self.restore)
        m = re.fullmatch(r'/api/books/([A-Za-z0-9_-]+)(/.*)?', path)
        if not m:
            return self.err(404, '没有这个接口')
        bid, rest = m.group(1), m.group(2) or ''
        d = book_dir(bid)
        if not d:
            return self.err(404, '没有这本书')
        if rest == '' and method == 'GET':
            b = cached_json(d / 'book.json')
            from pipeline.lang import book_lang
            chapters = [{k: c.get(k) for k in ('title', 'depth', 'parent', 'o0', 'o1', 'kind', 'spoil')} for c in b['chapters']]
            title, author = storage.display_title(b['title'], b['author'])
            return self.json({'id': bid, 'title': title, 'author': author, 'len': b['len'],
                              'version': book_revision(d),
                              'lang': book_lang(b), 'genre': b.get('genre') or 'novel',
            # a file that is mostly blurb (a sample, a failed download) is worth saying out loud
            'thin': (b.get('len') or 0) < 30000 or sum(1 for c in (b.get('chapters') or []) if c.get('kind') == 'body') < 2, 'chapters': chapters, 'status': cached_json(d / 'status.json') or {},
                              'progress': progress_all().get(bid)})
        if rest == '' and method == 'DELETE':
            WORKER.cancel(d)
            with WORKER.lock, _lock, book_lease(d):
                # Preserve a recoverable copy; never recursively erase an active book.
                trash = DATA / 'trash'
                trash.mkdir(exist_ok=True)
                dest = trash / f'{bid}-{time.time_ns()}'
                d.rename(dest)
                allp = dict(progress_all())
                old_progress = allp.pop(bid, None)
                if old_progress:
                    wjson(dest / 'reading-progress.json', old_progress)
                wjson(DATA / 'progress.json', allp)
                _cache.evict(d)
                _pos_cache.pop(str(d), None)
                ask_mod.evict_index(d)
            return self.json({'ok': True})
        if rest == '/export' and method == 'GET':
            return self.export(bid, d)
        if rest == '/offline-manifest' and method == 'GET':
            return self.offline_manifest(bid, d)
        m2 = re.fullmatch(r'/chapters/(\d+)', rest)
        if m2 and method == 'GET':
            return self.chapter(d, int(m2.group(1)))
        if rest == '/kg' and method == 'GET':
            return self.kg(d, q)
        if rest == '/manual-entities' and method in ('GET', 'PUT'):
            payload = self.body_json() if method == 'PUT' else None
            with _lock:
                items = cached_json(d / 'manual-entities.json') or []
                if method == 'GET':
                    book = cached_json(d / 'book.json')
                    try:
                        cutoff = storage.integer(int(q.get('to', 0)), '已读范围', 0, book['len'])
                    except (TypeError, ValueError):
                        raise ValueError('已读范围无效')
                    return self.json({'items': [dict(x, versions=[v for v in x['versions'] if v['p'] <= cutoff],
                                                      locked=x['knowledge_cutoff'] > cutoff)
                                                for x in items if not x.get('deleted') and x['versions'][0]['p'] <= cutoff]})
                updated, item, conflict = manual_entities.apply(
                    items, payload, cached_json(d / 'book.json'), cached_json(d / 'kg.json') or {'log': []})
                if conflict:
                    return self.json({'error': '这条资料已在其他设备修改', 'item': item}, 409)
                if updated is not items:
                    wjson(d / 'manual-entities.json', updated)
                return self.json({'item': item})
        if rest == '/notebook' and method in ('GET', 'PUT'):
            # Notebook writes do not acquire the model worker lease or start inference.
            payload = self.body_json() if method == 'PUT' else None
            with _lock:
                if not (d / 'book.json').is_file():
                    return self.err(404, '没有这本书')
                items = cached_json(d / 'notebook.json') or []
                if method == 'GET':
                    return self.json({'items': items})
                updated, item, conflict = notebook.apply(items, payload, cached_json(d / 'book.json'))
                if conflict:
                    return self.json({'error': '这条摘记已在其他设备修改', 'item': item}, 409)
                if updated is not items:
                    wjson(d / 'notebook.json', updated)
                return self.json({'item': item})
        if rest == '/notebook.md' and method == 'GET':
            title = storage.shelf_metadata(d, _cache).get('title') or bid
            lines = ['# ' + title, '', '个人摘记（包含全书已保存的摘记）', '']
            for item in sorted(cached_json(d / 'notebook.json') or [], key=lambda x: x['start']):
                if item.get('deleted'):
                    continue
                lines += ['## ' + ('书签' if item['kind'] == 'bookmark' else '摘记') + f" · 原文位置 {item['start']}", '']
                lines += ['> ' + line for line in item['quote'].splitlines()]
                lines += ['', item['text'], '', f"[回到书中](/#/read/{bid}?at={item['start']})", '']
            return self.send(200, '\n'.join(lines).encode(), 'text/markdown; charset=utf-8',
                             {'Content-Disposition': f'attachment; filename="{bid}-notes.md"', 'Cache-Control': 'no-store'})
        if rest == '/progress' and method in ('POST', 'PUT'):
            data = self.body_json()
            length = storage.shelf_metadata(d, _cache)['len']
            pos = storage.integer(data.get('pos', 0), '阅读位置', 0, length)
            cutoff = storage.integer(data.get('cutoff', pos), '已读范围', pos, length)
            with _lock:
                allp = dict(progress_all())
                current = allp.get(bid)
                if 'expected_t' in data and data['expected_t'] != (current or {}).get('t'):
                    return self.json({'error': '阅读进度已在其他设备更新', 'progress': current}, 409)
                allp[bid] = {'pos': pos, 'cutoff': cutoff, 't': time.time(),
                             'pct': round(cutoff / max(1, length) * 100, 3)}
                wjson(DATA / 'progress.json', allp)
            return self.json({'ok': True, 'progress': allp[bid]})
        if rest == '/kind' and method == 'PUT':
            # only the reader knows what they are reading: they can correct the judge
            kind = self.body_json().get('kind')
            if not isinstance(kind, str):
                raise ValueError('书籍类型无效')
            kind = kind.strip()
            from pipeline.kind import KINDS
            if kind not in KINDS:
                return self.err(400, '不认识这个类型')
            with WORKER.lock, _lock, book_lease(d):
                b = dict(cached_json(d / 'book.json') or {})
                b['genre'], b['genre_p'], b['genre_provisional'] = kind, 1.0, False
                wjson(d / 'book.json', b)
            return self.json({'ok': True, 'genre': kind})
        if rest == '/process' and method in ('POST', 'DELETE'):
            if method == 'POST':
                WORKER.set_auto(d, True)
            else:
                WORKER.cancel(d)
            return self.json({'ok': True, 'status': cached_json(d / 'status.json')})
        if rest == '/who' and method == 'POST':
            # the reader tapped a word ("他"): who is that, as of the page they are on
            data = self.body_json()
            b = cached_json(d / 'book.json')
            kg = cached_json(d / 'kg.json') or {'log': []}
            pos = storage.integer(data.get('pos', 0), '阅读位置', 0, b['len'])
            start = storage.integer(data.get('start', pos), '选中位置', 0, pos)
            end = storage.integer(data.get('end', start + 1), '选中终点', start, pos)
            from server.ask import who_is
            from pipeline.llm import request_budget
            if not _ask_gate.acquire(blocking=False):
                return self.err(429, '正在回答其他问题，请稍后重试')
            try:
                with request_budget(float(os.environ.get('ANSWER_TIMEOUT', '180'))):
                    return self.json(who_is(b, kg['log'], pos, start, end))
            finally:
                _ask_gate.release()
        if rest == '/marginalia' and method == 'POST':
            if not _ask_gate.acquire(blocking=False):
                return self.err(429, 'AI 正在写另一条批注，请稍后再试')
            try:
                from pipeline.llm import request_budget
                with request_budget(float(os.environ.get('ANSWER_TIMEOUT', '180'))):
                    return self.json(marginalia.respond(d, self.body_json(), cached_json, wjson))
            finally:
                _ask_gate.release()
        if rest == '/ask' and method == 'POST':
            return self.ask(d, self.body_json())
        m3 = re.fullmatch(r'/img/([A-Za-z0-9_.-]+)', rest)
        if m3 and method == 'GET':
            f = d / 'img' / m3.group(1)
            if not f.is_file() or f.is_symlink():
                return self.err(404, '没有这张图')
            return self.send(200, f.read_bytes(), mimetypes.guess_type(f.name)[0] or 'image/jpeg',
                             {'Cache-Control': 'private, max-age=31536000, immutable',
                              'Content-Security-Policy': "default-src 'none'; sandbox"})
        return self.err(404, '没有这个接口')

    # endpoints -----------------------------------------------------------
    def import_request(self, action):
        if not _import_gate.acquire(blocking=False):
            self.close_connection = True
            return self.err(429, '正在导入其他书籍，请稍后重试')
        try:
            return action()
        finally:
            _import_gate.release()

    def publish_import(self, tmp, bid):
        destination = BOOKS / bid
        with _lock:
            if not (destination / 'book.json').exists():
                if destination.exists():
                    raise ValueError('书籍目录不完整，请先检查已有文件')
                tmp.rename(destination)
        return destination

    def matching_snapshot(self, root, book, graph, mentions, assets, personal=None, manual=None):
        if personal is not None and (cached_json(root / 'notebook.json') or []) != personal:
            return False
        if manual is not None and (cached_json(root / 'manual-entities.json') or []) != manual:
            return False
        if cached_json(root / 'book.json') != book or (cached_json(root / 'kg.json') or {'log': []}) != graph:
            return False
        actual = {str(int(p.stem)): cached_json(p) for p in (root / 'mentions').glob('*.json')}
        if actual != {str(int(k)): v for k, v in mentions.items()}:
            return False
        for name, raw in assets.items():
            path = root / 'img' / name
            if not path.is_file() or path.is_symlink() or path.stat().st_size != len(raw):
                return False
            if hashlib.sha256(path.read_bytes()).digest() != hashlib.sha256(raw).digest():
                return False
        return True

    def static(self, path: str):
        path = urllib.parse.unquote(path)
        if path in ('/', '') or not Path(path).suffix:
            path = '/index.html'
        if path == '/favicon.ico':
            path = '/icon.svg'
        f = (WEB / path.lstrip('/')).resolve()
        if not f.is_relative_to(WEB.resolve()) or not f.is_file():
            return self.send(404, b'not found', 'text/plain')
        ctype = mimetypes.guess_type(f.name)[0] or 'application/octet-stream'
        if ctype.startswith('text/') or ctype in ('application/javascript', 'application/json'):
            ctype += '; charset=utf-8'
        cache = 'no-cache' if f.suffix in ('.html', '.js', '.css', '.webmanifest') else 'public, max-age=2592000'
        # no-cache files are revalidated on every load and service-worker install: answer 304
        # when unchanged, and compress each file once per version instead of once per request
        stamp = storage.signature(f)
        etag = '"%x-%x"' % (stamp[0], stamp[1])
        headers = {'Cache-Control': cache, 'ETag': etag}
        if etag in (self.headers.get('If-None-Match') or '').replace('W/', '').split(', '):
            self.send_response(304)
            for k, v in headers.items():
                self.send_header(k, v)
            self.send_header('X-Yedu-Release', RELEASE)
            self.end_headers()
            return
        body = _static_body(f, stamp)
        if 'gzip' in (self.headers.get('Accept-Encoding') or '') and len(body) > 2048 \
                and (ctype.startswith('text/') or 'javascript' in ctype or 'json' in ctype or f.suffix == '.svg'):
            body = _static_body(f, stamp, gz=True)
            headers.update({'Content-Encoding': 'gzip', 'Vary': 'Accept-Encoding'})
        return self.send(200, body, ctype, headers)

    def chapter(self, d: Path, n: int):
        b = cached_json(d / 'book.json')
        if not 0 <= n < len(b['chapters']):
            return self.err(404, '没有这一章')
        c = b['chapters'][n]
        blocks = b['blocks'][c['b0']:c['b1']]
        st = cached_json(d / 'status.json') or {}
        frontier = st.get('frontier', 0)
        mentions = [m for m in (cached_json(d / 'mentions' / f'{n:04d}.json') or []) if m[1] <= frontier]
        manual = cached_json(d / 'manual-entities.json') or []
        if manual:
            mentions = manual_entities.mentions(blocks, manual, mentions)
        notes = {}
        for bl in blocks:
            for off, nid in bl.get('fn', []):
                notes[nid] = b['notes'].get(nid, '')
        return self.json({'n': n, 'title': c['title'], 'parent': c.get('parent'), 'kind': c.get('kind'),
                          'o0': c['o0'], 'o1': c['o1'], 'blocks': blocks, 'mentions': mentions, 'notes': notes},
                         headers={'Cache-Control': 'private, no-cache'})

    def kg(self, d: Path, q: dict):
        """Records with lo < p <= hi. The client asks for hi = end of its current page."""
        kg = cached_json(d / 'kg.json') or {'log': []}
        try:
            hi = int(q.get('to', 0))
            lo = int(q.get('from', -1))
        except ValueError:
            return self.err(400, '位置不对')
        manual = cached_json(d / 'manual-entities.json') or []
        log = sorted([*kg['log'], *manual_entities.rows(manual)], key=lambda row: row['p']) if manual else kg['log']
        # binary search on p (log is sorted)
        import bisect
        ps = [r['p'] for r in log] if manual else _positions(d, log)
        i = bisect.bisect_right(ps, lo)
        j = bisect.bisect_right(ps, hi)
        st = cached_json(d / 'status.json') or {}
        # 'before' lets the client notice records inserted behind what it already holds
        # (chapter biographies are written in the background after the frontier has moved on)
        return self.json({'from': lo, 'to': hi, 'frontier': st.get('frontier', 0), 'state': st.get('state'),
                          'before': i, 'records': log[i:j]})

    def upload(self):
        name = urllib.parse.unquote(self.headers.get('X-Filename') or 'book.txt')
        name = Path(name).name[:120] or 'book.txt'
        ext = Path(name).suffix.lower()
        if LOCAL_MODE and ext in ('.mobi', '.azw3', '.azw'):
            return self.err(400, '手机版暂不支持 MOBI/AZW3，请先转成 EPUB')
        if ext not in ('.txt', '.epub', '.mobi', '.azw3', '.azw'):
            return self.err(400, '支持 TXT、EPUB、MOBI、AZW3')
        raw = self.body(MAX_UPLOAD)
        if not raw:
            return self.err(400, '文件是空的')
        bid = hashlib.sha1(raw).hexdigest()[:16]
        d = BOOKS / bid
        if (d / 'book.json').exists():
            return self.json(book_summary(bid, d))
        tmp = Path(tempfile.mkdtemp(prefix=f'.{bid}.', suffix='.tmp', dir=BOOKS))
        src = tmp / ('source' + ext)
        src.write_bytes(raw)
        try:
            book = parse_file(src, tmp, name)
            if book.get('title') in (None, '', 'source'):
                book['title'] = Path(name).stem
            book.update(genre='novel', genre_p=0.0, genre_provisional=True)
            storage.validate_book(book)
            wjson(tmp / 'book.json', book)
            # No model or remote classification before the explicit process action.
            wjson(tmp / 'meta.json', {'added': time.time(), 'filename': name, 'auto': False})
            wjson(tmp / 'status.json', {'state': 'idle', 'done': 0, 'total': 0, 'frontier': 0})
            d = self.publish_import(tmp, bid)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        return self.json(book_summary(bid, d))

    # a book and everything read out of it, as one file ----------------------
    # Worth having for three reasons: moving a book between machines without paying to read it
    # again, keeping a copy before re-running a changed pipeline, and handing someone a finished
    # graph to test against. The text travels with it, so the file is as shareable as the book is.
    EXPORT_FORMAT = 'yedu-book/2'
    EXPORT_PARTS = ('book', 'kg', 'meta', 'status')

    def export(self, bid: str, d: Path):
        before = snapshot_version(d)
        personal_before = cached_json(d / 'notebook.json') or []
        manual_before = cached_json(d / 'manual-entities.json') or []
        out = {'format': self.EXPORT_FORMAT, 'exported': time.time(), 'id': bid}
        for part in self.EXPORT_PARTS:
            out[part] = cached_json(d / f'{part}.json') or {}
        # the per-chapter mention index is derived, but it is small and regenerating it costs a
        # pass over the whole book, so it rides along
        out['mentions'] = {f.stem: json.loads(f.read_text()) for f in sorted((d / 'mentions').glob('*.json'))} \
            if (d / 'mentions').is_dir() else {}
        out['assets'] = storage.encode_assets(d, out['book'])
        out['progress'] = progress_all().get(bid)
        out['notebook'] = personal_before
        out['manual_entities'] = manual_before
        out['version'] = before
        if snapshot_version(d) != before or (cached_json(d / 'notebook.json') or []) != personal_before or (cached_json(d / 'manual-entities.json') or []) != manual_before:
            return self.err(409, '这本书正在更新，请稍后重新导出')
        # HTTP headers are latin-1, and most of our titles are not — so the readable name goes in
        # the RFC 5987 form and an ASCII one is left for clients that ignore it
        title = re.sub(r'[^\w\u4e00-\u9fff-]+', '_', (out['book'].get('title') or bid))[:60] or bid
        quoted = urllib.parse.quote(f'{title}.yedu.json')
        return self.json(out, headers={
            'Content-Disposition': f'attachment; filename="{bid}.yedu.json"; filename*=UTF-8\'\'{quoted}'})

    def restore(self):
        raw = self.body(MAX_UPLOAD)
        try:
            data = json.loads(raw)
        except Exception as e:
            return self.err(400, f'这个文件不是导出的书：{e}')
        if not isinstance(data, dict):
            return self.err(400, '导出文件必须是书籍对象')
        if data.get('format') not in ('yedu-book/1', self.EXPORT_FORMAT):
            return self.err(400, f'认不出的格式：{data.get("format")!r}')
        book = storage.validate_book(data.get('book'))
        graph = storage.validate_graph(data.get('kg') or {'log': []}, book['len'])
        personal = notebook.restore(data.get('notebook', []), book)
        manual = manual_entities.restore(data.get('manual_entities', []), book)
        if data['format'] == 'yedu-book/1' and storage.referenced_assets(book):
            raise ValueError('旧版导出没有包含图片，请从原设备重新导出完整书籍')
        assets = storage.decode_assets(data.get('assets') or {}, book)
        mentions = data.get('mentions') or {}
        if not isinstance(mentions, dict) or len(mentions) > len(book['chapters']):
            raise ValueError('人名索引无效')
        known = {r['id'] for r in graph.get('log', []) if r['t'] == 'person'}
        for name, rows in mentions.items():
            if not re.fullmatch(r'[0-9]{1,6}', name) or int(name) >= len(book['chapters']) or not isinstance(rows, list):
                raise ValueError('人名章节索引无效')
            for row in rows:
                if not isinstance(row, list) or len(row) < 3 or not isinstance(row[2], str) or row[2] not in known:
                    raise ValueError('人名索引字段无效')
                start = storage.integer(row[0], '人名起点', 0, book['len'])
                storage.integer(row[1], '人名终点', start, book['len'])
        progress = data.get('progress')
        if progress is not None:
            if not isinstance(progress, dict):
                raise ValueError('阅读进度无效')
            pos = storage.integer(progress.get('pos'), '阅读进度', 0, book['len'])
            cutoff = storage.integer(progress.get('cutoff', pos), '已读范围', pos, book['len'])
            progress = {'pos': pos, 'cutoff': cutoff, 't': time.time(),
                        'pct': round(cutoff / max(1, book['len']) * 100, 3)}
        # keyed by content, like an upload: importing the same file twice is not two books
        bid = hashlib.sha1(json.dumps(book, ensure_ascii=False, sort_keys=True).encode()).hexdigest()[:16]
        d = BOOKS / bid
        if (d / 'book.json').exists():
            if not self.matching_snapshot(d, book, graph, mentions, assets, personal, manual):
                return self.err(409, '已有这本书的不同资料，未覆盖；请先保存现有版本后再处理')
            return self.json(book_summary(bid, d))
        tmp = Path(tempfile.mkdtemp(prefix=f'.{bid}.', suffix='.tmp', dir=BOOKS))
        try:
            meta = dict(data.get('meta') or {})
            meta.update(added=time.time(), auto=False, imported=True, hidden=False)
            state = dict(data.get('status') or {})
            storage.integer(state.get('frontier', 0), '整理进度', 0, book['len'])
            if state.get('state') != 'done':
                state.update(state='paused', error=None, updated=time.time())
            for part, value in [('book', book), ('kg', graph), ('meta', meta), ('status', state), ('notebook', personal), ('manual-entities', manual)]:
                wjson(tmp / f'{part}.json', value)
            for name, rows in mentions.items():
                wjson(tmp / 'mentions' / f'{int(name):04d}.json', rows)
            if assets:
                (tmp / 'img').mkdir()
                for name, raw in assets.items():
                    (tmp / 'img' / name).write_bytes(raw)
            with _lock:
                existing = (d / 'book.json').exists()
                if existing and not self.matching_snapshot(d, book, graph, mentions, assets, personal, manual):
                    raise BusyBook('另一份不同的书籍快照刚刚导入，未覆盖已有资料')
                d = self.publish_import(tmp, bid)
                if progress and not existing:
                    allp = dict(progress_all())
                    allp[bid] = progress
                    wjson(DATA / 'progress.json', allp)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        return self.json(book_summary(bid, d))

    def offline_manifest(self, bid, d):
        book = cached_json(d / 'book.json')
        state = cached_json(d / 'status.json') or {}
        base = f'/api/books/{bid}'
        chapters = []
        for n, chapter in enumerate(book['chapters']):
            images = [base + '/img/' + b['src'] for b in book['blocks'][chapter['b0']:chapter['b1']] if b['k'] == 'img']
            chapters.append({'n': n, 'url': base + f'/chapters/{n}', 'images': images})
        metadata = {k: book.get(k) for k in ('title', 'author', 'len', 'lang', 'genre', 'chapters', 'cover')}
        metadata.update(id=bid, status=state, progress=progress_all().get(bid), version=book_revision(d))
        personal_stamp = storage.signature(d / 'notebook.json') if (d / 'notebook.json').exists() else None
        manual_stamp = storage.signature(d / 'manual-entities.json') if (d / 'manual-entities.json').exists() else None
        offline_version = hashlib.sha256(json.dumps([snapshot_version(d), personal_stamp, manual_stamp]).encode()).hexdigest()
        return self.json({'version': offline_version, 'book': metadata, 'chapters': chapters,
                          'notebook': {'url': base + '/notebook'},
                          'assets': [base + '/img/' + x for x in sorted(storage.referenced_assets(book))],
                          'graph': {'url': base + f'/kg?from=-1&to={book["len"]}', 'to': book['len']},
                          'frontier': state.get('frontier', 0), 'state': state.get('state')})

    def ask(self, d: Path, data: dict):
        if not _ask_gate.acquire(blocking=False):
            return self.err(429, '正在回答其他问题，请稍后重试')
        try:
            from pipeline.llm import request_budget
            with request_budget(float(os.environ.get('ANSWER_TIMEOUT', '180'))):
                return self.answer_stream(d, data)
        finally:
            _ask_gate.release()

    def answer_stream(self, d: Path, data: dict):
        if not isinstance(data.get('q'), str):
            raise ValueError('问题必须是文字')
        q = data['q'].strip()[:500]
        pos = storage.integer(data.get('pos', 0), '阅读位置', 0, storage.shelf_metadata(d, _cache)['len'])
        if not q:
            return self.err(400, '问题是空的')
        # server-sent events so the page can show each stage
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.close_connection = True

        def emit(kind, payload):
            try:
                self.wfile.write(f'event: {kind}\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n'.encode())
                self.wfile.flush()
            except OSError as exc:
                raise BrokenPipeError('reader disconnected') from exc
        try:
            ask_mod.answer(d, q, pos, emit, cached_json)
        except BrokenPipeError:
            raise
        except Exception as e:
            traceback.print_exc()
            emit('error', {'message': f'出错了：{str(e)[:120]}'})


_pos_cache = OrderedDict()
_static_cache = OrderedDict()


def _static_body(f: Path, stamp, gz: bool = False) -> bytes:
    key = (str(f), gz)
    with _lock:
        hit = _static_cache.get(key)
        if hit and hit[0] == stamp:
            _static_cache.move_to_end(key)
            return hit[1]
    body = f.read_bytes()
    if gz:
        body = gzip.compress(body, 9)
    if len(body) <= 2 * 1024 * 1024:   # shell text files; large fonts/images are read per request
        with _lock:
            _static_cache[key] = (stamp, body)
            while len(_static_cache) > 256:
                _static_cache.popitem(last=False)
    return body


def _positions(d: Path, log: list) -> list:
    with _lock:
        key = str(d)
        hit = _pos_cache.get(key)
        if hit and hit[0] is log:
            _pos_cache.move_to_end(key)
            return hit[1]
        ps = [r['p'] for r in log]
        _pos_cache[key] = (log, ps)
        while len(_pos_cache) > 4:
            _pos_cache.popitem(last=False)
        return ps


def snapshot_version(root):
    paths = [root / (x + '.json') for x in ('book', 'kg', 'status')]
    paths += sorted((root / 'mentions').glob('*.json'))
    paths += sorted((root / 'img').glob('*'))
    stamps = [(str(p.relative_to(root)), storage.signature(p)) for p in paths if p.is_file()]
    return hashlib.sha256(json.dumps(stamps).encode()).hexdigest()


def book_revision(root):
    return hashlib.sha256(json.dumps(storage.signature(root / 'book.json')).encode()).hexdigest()


class BoundedHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False

    def __init__(self, *args, **kwargs):
        self.slots = threading.BoundedSemaphore(int(os.environ.get('HTTP_CONCURRENCY', '32')))
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            try:
                request.settimeout(1)
                request.sendall(b'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\nRetry-After: 5\r\n\r\n')
            finally:
                self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default='0.0.0.0')
    ap.add_argument('--port', type=int, default=18770)
    a = ap.parse_args()
    BOOKS.mkdir(parents=True, exist_ok=True)
    secret()
    srv = BoundedHTTPServer((a.host, a.port), Handler)
    WORKER.start()
    WORKER.wake.set()
    srv.daemon_threads = True
    print(f'serving on {a.host}:{a.port}, data={DATA}', flush=True)
    stopping = threading.Event()
    cleanup = []

    def shutdown(_signum, _frame):
        if stopping.is_set():
            return
        stopping.set()

        def finish():
            WORKER.stop()
            try:
                with WORKER.lock:
                    current = WORKER.current if WORKER.process else None
                if current:
                    WORKER.cancel(BOOKS / current, preserve_auto=True)
            finally:
                srv.shutdown()
        thread = threading.Thread(target=finish, name='yedu-shutdown')
        cleanup.append(thread)
        thread.start()

    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, shutdown)
    try:
        srv.serve_forever()
    finally:
        WORKER.stop()
        srv.server_close()
        for thread in cleanup:
            thread.join(timeout=25)


if __name__ == '__main__':
    main()
