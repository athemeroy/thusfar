"""Stable cache inputs and durable, conservative paid-request reservations."""
from __future__ import annotations

import hashlib
import json
import os
import threading
from pathlib import Path

SCHEMA = 2
_budget_lock = threading.Lock()


def digest(value) -> str:
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True,
                                     separators=(',', ':')).encode()).hexdigest()


def source_fingerprint(book: dict, segs: list) -> str:
    return digest({'blocks': book['blocks'], 'chapters': [
        {k: c.get(k) for k in ('title', 'parent', 'b0', 'b1', 'o0', 'o1', 'kind')}
        for c in book['chapters']], 'lang': book.get('lang'), 'genre': book.get('genre'),
        'segments': segs})


def reserve_paid(chars: int, questions: int) -> dict:
    """Reserve before sending, including retries; concurrent processes share a ledger.

    A failed/ambiguous request is deliberately not refunded. Explicit route and
    caps are policy inputs, never credentials. Limits persist across restarts.
    """
    calls_limit = int(os.environ.get('JEV_PAID_MAX_CALLS', '1000'))
    chars_limit = int(os.environ.get('JEV_PAID_MAX_CHARS', '5000000'))
    if calls_limit < 0 or chars_limit < 0:
        raise ValueError('付费裁判预算必须是非负整数')
    directory = os.environ.get('JUDGE_LOG_DIR')
    configured = os.environ.get('JEV_BUDGET_FILE')
    path = (Path(configured) if configured else Path(directory) / 'paid-budget.json' if directory
            else Path(os.environ.get('DATA_DIR', str(Path(__file__).resolve().parents[1] / 'data'))) / 'paid-budget.json')

    def update(value):
        if value.get('calls', 0) + 1 > calls_limit or value.get('chars', 0) + chars > chars_limit:
            raise RuntimeError('付费裁判预算已达上限；已保留缓存，可调整显式预算后继续')
        return {'version': 1, 'calls': value.get('calls', 0) + 1,
                'chars': value.get('chars', 0) + chars, 'questions': value.get('questions', 0) + questions,
                'max_calls': calls_limit, 'max_chars': chars_limit}

    with _budget_lock:
        import fcntl
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.with_suffix(path.suffix + '.lock').open('a+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            value = update(json.loads(path.read_text()) if path.exists() else {})
            tmp = path.with_suffix(path.suffix + f'.{os.getpid()}.tmp')
            with tmp.open('w') as f:
                json.dump(value, f)
                f.flush()
                os.fsync(f.fileno())
            tmp.replace(path)
            return value
