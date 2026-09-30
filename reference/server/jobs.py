"""Single-book subprocess queue with explicit cancellation and observable health."""
from __future__ import annotations

import contextlib
import fcntl
import os
import signal
import subprocess
import sys
import threading
import time


class BusyBook(RuntimeError):
    pass


@contextlib.contextmanager
def book_lease(root):
    """Exclude a separate pipeline process without trusting persisted status or PID files."""
    work = root / 'work'
    work.mkdir(exist_ok=True)
    with (work / 'run.lock').open('a') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise BusyBook('这本书正在由另一个任务处理，请先停止该任务') from exc
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


class Worker(threading.Thread):
    def __init__(self, books, app, read, write, enabled=True):
        super().__init__(daemon=True, name='yedu-book-worker')
        self.books, self.app, self.read, self.write = books, app, read, write
        self.enabled = enabled
        self.mode = os.environ.get('YEDU_WORKER_MODE', 'process')
        if self.mode not in ('process', 'thread'):
            raise ValueError('Invalid worker mode')
        self.wake = threading.Event()
        self.manual_queue = set()
        self.stopping = threading.Event()
        self.lock = threading.RLock()
        self.current = None
        self.process = None
        self.cancel_event = None
        self.current_done = threading.Event()
        self.current_done.set()
        self.last_error = None
        self.last_scan = 0

    def health(self):
        with self.lock:
            return {'enabled': self.enabled, 'alive': self.is_alive(), 'current': self.current,
                    'mode': self.mode,
                    'pid': self.process.pid if self.process and self.process.poll() is None else None,
                    'last_scan': self.last_scan, 'last_error': self.last_error}

    def set_auto(self, root, enabled):
        with self.lock:
            meta = dict(self.read(root / 'meta.json') or {})
            state = dict(self.read(root / 'status.json') or {})
            quality = state.get('quality') or {}
            retry_quality = (enabled and bool(quality.get('pending') or quality.get('state') == 'pending')
                             and state.get('state') not in ('running', 'finalizing', 'cancelling'))
            meta['auto'] = enabled
            if retry_quality:
                # This is an explicit user action. Startup never infers permission
                # to regenerate completed books from a pending-quality marker.
                meta['retry_quality'] = True
            elif not enabled:
                meta.pop('retry_quality', None)
            self.write(root / 'meta.json', meta)
            if enabled and (retry_quality or state.get('state') not in ('done', 'running', 'finalizing', 'cancelling')):
                state.update(state='queued', updated=time.time(), error=None)
                self.write(root / 'status.json', state)
            if not self.enabled:
                if enabled:
                    self.manual_queue.add(root.name)
                else:
                    self.manual_queue.discard(root.name)
            self.wake.set()

    def cancel(self, root, timeout=15, preserve_auto=False):
        if not preserve_auto:
            self.set_auto(root, False)
        thread_active = False
        with self.lock:
            process = self.process if self.current == root.name else None
            if self.mode == 'thread' and self.current == root.name and self.cancel_event is not None:
                thread_active = True
                self.cancel_event.set()
                state = dict(self.read(root / 'status.json') or {})
                state.update(state='cancelling', updated=time.time())
                self.write(root / 'status.json', state)
            if process and process.poll() is None:
                state = dict(self.read(root / 'status.json') or {})
                state.update(state='cancelling', updated=time.time())
                self.write(root / 'status.json', state)
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        if process:
            try:
                process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=5)
        if thread_active and not self.current_done.wait(timeout):
            # The current model call may still be finishing. Its book lease stays held,
            # and the worker will publish paused/queued when it reaches a boundary.
            return
        # External jobs have no verified ownership: do not kill them by a guessed PID.
        with self.lock, book_lease(root):
            state = dict(self.read(root / 'status.json') or {})
            if state.get('state') != 'done':
                state.update(state='queued' if preserve_auto else 'paused', updated=time.time(), error=None)
                self.write(root / 'status.json', state)

    def _one(self, root):
        with self.lock:
            if not (root / 'book.json').exists():
                return
            meta = self.read(root / 'meta.json') or {}
            state = self.read(root / 'status.json') or {}
            retry_quality = bool(meta.get('retry_quality'))
            if not meta.get('auto') or (state.get('state') == 'done' and not retry_quality):
                return
            if state.get('state') == 'error' and time.time() - state.get('updated', 0) < 1800:
                return
            try:
                with book_lease(root):
                    pass
            except BusyBook:
                return
            retry_journal = root / 'work' / 'quality-retry.json'
            retry_before = self.read(retry_journal) if retry_quality else None
            self.current = root.name
            self.current_done.clear()
            try:
                if self.mode == 'thread':
                    self.cancel_event = threading.Event()
                    log = None
                    process = None
                else:
                    log = (root / 'work.log').open('a')
                    command = [sys.executable, '-u', '-m', 'pipeline.run', str(root)]
                    if retry_quality:
                        command.append('--retry-quality')
                    self.process = subprocess.Popen(
                        command, cwd=self.app,
                        stdout=log, stderr=subprocess.STDOUT, env=dict(os.environ), start_new_session=True)
                    process = self.process
            except Exception:
                self.current = None
                self.process = None
                self.cancel_event = None
                self.current_done.set()
                if 'log' in locals() and log is not None:
                    log.close()
                raise
        try:
            if self.mode == 'thread':
                from pipeline.run import AlreadyRunning, Cancelled, run_book
                try:
                    run_book(root, retry_quality=retry_quality,
                             model=os.environ.get('EXTRACT_MODEL', 'deepseek-flash+nothink'),
                             local_model=os.environ.get('LOCAL_MODEL', 'deepseek-flash+nothink'),
                             concurrency=int(os.environ.get('LOCAL_CONCURRENCY', '4')),
                             cancel_event=self.cancel_event)
                    code = 0
                except (Cancelled, AlreadyRunning):
                    code = 75
                except Exception as exc:
                    code = 1
                    self.last_error = {'book': root.name, 'message': str(exc)[:200], 'at': time.time()}
            else:
                code = process.wait()
            with self.lock:
                if not root.exists():
                    return
                state = dict(self.read(root / 'status.json') or {})
                meta = dict(self.read(root / 'meta.json') or {})
                auto = meta.get('auto')
                if retry_quality and code != 75:
                    retry_after = self.read(retry_journal) or {}
                    acknowledged = (retry_after.get('state') in ('rebuilding', 'complete')
                                    and (retry_after != retry_before
                                         or (retry_before or {}).get('state') == 'rebuilding'))
                    if acknowledged:
                        # Preserve the explicit request across a killed launch;
                        # only the child's durable rebuild journal acknowledges it.
                        meta.pop('retry_quality', None)
                        self.write(root / 'meta.json', meta)
                if auto and self.stopping.is_set() and code != 0:
                    state.update(state='queued', updated=time.time(), error=None)
                    self.write(root / 'status.json', state)
                elif not auto:
                    if state.get('state') != 'done':
                        state.update(state='paused', updated=time.time(), error=None)
                        self.write(root / 'status.json', state)
                elif code != 75 and (code != 0 or state.get('state') != 'done'):
                    state.update(state='error', updated=time.time(),
                                 error=state.get('error') or f'处理进程未完成（退出码 {code}）')
                    self.write(root / 'status.json', state)
                    self.last_error = {'book': root.name, 'message': state['error'], 'at': time.time()}
        finally:
            if log is not None:
                log.close()
            with self.lock:
                self.current = None
                self.process = None
                self.cancel_event = None
                self.current_done.set()

    def run(self):
        while not self.stopping.is_set():
            self.wake.wait(30)
            self.wake.clear()
            self.last_scan = time.time()
            try:
                if self.enabled:
                    roots = sorted((p.parent for p in self.books.glob('*/meta.json')
                                    if not p.parent.name.startswith('.')), key=lambda p: p.name)
                else:
                    with self.lock:
                        roots = [self.books / bid for bid in sorted(self.manual_queue)]
                        self.manual_queue.clear()
                for root in roots:
                    if self.stopping.is_set():
                        break
                    try:
                        self._one(root)
                    except Exception as exc:
                        self.last_error = {'book': root.name, 'message': str(exc)[:200], 'at': time.time()}
                        if root.exists():
                            try:
                                state = dict(self.read(root / 'status.json') or {})
                                state.update(state='error', error='后台处理失败，请查看服务日志', updated=time.time())
                                self.write(root / 'status.json', state)
                            except Exception:
                                pass
            except Exception as exc:
                self.last_error = {'message': str(exc)[:200], 'at': time.time()}

    def stop(self):
        self.stopping.set()
        if self.cancel_event is not None:
            self.cancel_event.set()
        self.wake.set()
