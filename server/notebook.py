"""Personal source-anchored notes; independent of generated knowledge graphs."""
from __future__ import annotations

import re
import time

from server.storage import integer

ID = re.compile(r'[A-Za-z0-9_-]{8,80}\Z')
MAX_ITEMS = 5000


def source_quote(book, start, end):
    """Annotations cover one text block, in the reader's UTF-16 coordinate system."""
    if start == end:
        return ''
    for block in book['blocks']:
        if block['o'] > start:
            break
        raw = block['t'].encode('utf-16-le')
        if block['k'] in ('p', 'h') and block['o'] <= start < end <= block['o'] + len(raw) // 2:
            try:
                return raw[(start - block['o']) * 2:(end - block['o']) * 2].decode('utf-16-le')
            except UnicodeError:
                break
    raise ValueError('摘录位置已变化，请重新选择原文')


def validate(item, book):
    if not isinstance(item, dict) or not ID.fullmatch(str(item.get('id', ''))):
        raise ValueError('摘记编号无效')
    kind = item.get('kind')
    if kind not in ('bookmark', 'note'):
        raise ValueError('摘记类型无效')
    start = integer(item.get('start'), '摘记位置', 0, book['len'])
    end = integer(item.get('end'), '摘录终点', start, book['len'])
    quote, text = item.get('quote', ''), item.get('text', '')
    if not isinstance(quote, str) or not isinstance(text, str) or len(quote) > 4000 or len(text) > 10000:
        raise ValueError('摘录限 4000 字，想法限 10000 字')
    if source_quote(book, start, end) != quote:
        raise ValueError('摘录与原文不一致，未保存到错误位置')
    if kind == 'note' and not quote.strip() and not text.strip():
        raise ValueError('请先写下想法或选择原文')
    return {k: item[k] for k in ('id', 'kind', 'start', 'end')} | {
        'quote': quote, 'text': text, 'deleted': item.get('deleted') is True,
        'knowledge_cutoff': integer(item.get('knowledge_cutoff', end), '摘记已读范围', end, book['len'])}


def apply(items, item, book):
    """Optimistic per-item writes with replay receipts; independent notes never conflict."""
    clean = validate(item, book)
    op = item.get('operation')
    if not isinstance(op, str) or not ID.fullmatch(op):
        raise ValueError('摘记操作编号无效')
    old = next((x for x in items if x['id'] == clean['id']), None)
    if old and old.get('operation') == op:
        # An uncertain successful request can be retried without a second revision.
        return items, old, False
    expected = integer(item.get('expected_revision', 0), '摘记版本', 0, 10**9)
    if expected != (old or {}).get('revision', 0):
        return items, old, True
    if old is None and len(items) >= MAX_ITEMS:
        raise ValueError('本书摘记已达上限，请先导出留存')
    now = time.time()
    clean.update(revision=expected + 1, operation=op, created=(old or {}).get('created', now), updated=now)
    return [x for x in items if x['id'] != clean['id']] + [clean], clean, False


def restore(items, book):
    if not isinstance(items, list) or len(items) > MAX_ITEMS:
        raise ValueError('摘记备份无效')
    result, seen = [], set()
    for item in items:
        clean = validate(item, book)
        if clean['id'] in seen:
            raise ValueError('摘记编号重复')
        seen.add(clean['id'])
        clean['revision'] = integer(item.get('revision', 1), '摘记版本', 1, 10**9)
        clean['operation'] = str(item.get('operation', clean['id']))[:80]
        for key in ('created', 'updated'):
            value = item.get(key, time.time())
            if isinstance(value, bool) or not isinstance(value, (float, int)) or not 0 <= value <= 10**12:
                raise ValueError('摘记时间无效')
            clean[key] = value
        result.append(clean)
    return result
