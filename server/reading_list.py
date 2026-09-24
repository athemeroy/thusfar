"""User-selected next-reading order, separate from measured reading progress."""
from __future__ import annotations

import re
import time

from server.storage import integer

BOOK_ID = re.compile(r'[A-Za-z0-9_-]{1,160}\Z')
OPERATION = re.compile(r'[A-Za-z0-9_-]{8,80}\Z')
MAX_ITEMS = 200


def empty():
    return {'revision': 0, 'items': [], 'operation': None, 'updated': 0}


def apply(current, payload, visible):
    """Return (snapshot, conflict); caller serializes read/modify/write under its lock."""
    items = payload.get('items')
    if (not isinstance(items, list) or len(items) > MAX_ITEMS or
            any(not isinstance(x, str) or not BOOK_ID.fullmatch(x) for x in items) or
            len(set(items)) != len(items)):
        raise ValueError('书单最多保留 200 本书，书籍编号不可重复')
    operation = payload.get('operation')
    if not isinstance(operation, str) or not OPERATION.fullmatch(operation):
        raise ValueError('书单操作编号无效')
    expected = integer(payload.get('expected_revision'), '书单版本', 0, 10**9)
    if operation == current.get('operation'):
        if items != current['items']:
            raise ValueError('同一个书单操作不能提交不同内容')
        return current, False
    if expected != current['revision']:
        return current, True
    # A removed book remains an explicit unavailable slot until the user removes it.
    # This lets another queue edit preserve intent without resurrecting that book.
    previous = set(current['items'])
    if any(x not in previous and not visible(x) for x in items):
        raise ValueError('有书籍已不在书架，请刷新书架后重新选择')
    return {'revision': expected + 1, 'items': list(items),
            'operation': operation, 'updated': time.time()}, False
