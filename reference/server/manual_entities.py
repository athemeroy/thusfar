"""Reader-authored people and concepts, kept outside the generated graph."""
from __future__ import annotations

import re
import time
import hashlib
import json
from bisect import bisect_left

from server.storage import integer

ID = re.compile(r'[A-Za-z0-9_-]{8,80}\Z')
MAX_ITEMS = 1000


def anchor(book, name, cutoff):
    """Find an exact occurrence in source text before the reader's current cutoff."""
    for block in book['blocks']:
        if block['o'] >= cutoff:
            break
        if block['k'] not in ('p', 'h'):
            continue
        start = block['t'].find(name)
        while start >= 0:
            offset = block['o'] + len(block['t'][:start].encode('utf-16-le')) // 2
            end = offset + len(name.encode('utf-16-le')) // 2
            if end <= cutoff:
                return offset
            start = block['t'].find(name, start + 1)
    raise ValueError('当前已读原文里没有找到这个完整名称，请检查文字或继续阅读')


def _base(item, book):
    if not isinstance(item, dict) or not ID.fullmatch(str(item.get('id', ''))):
        raise ValueError('手动条目编号无效')
    kind = item.get('kind')
    if kind not in ('person', 'concept'):
        raise ValueError('请选择人物或概念')
    name = item.get('name')
    if not isinstance(name, str) or not 1 <= len(name.strip()) <= 80 or '\n' in name:
        raise ValueError('名称须为 1—80 字')
    name = name.strip()
    cutoff = integer(item.get('knowledge_cutoff'), '已读范围', 0, book['len'])
    note = item.get('note', '')
    if not isinstance(note, str) or len(note) > 3000:
        raise ValueError('补充说明最多 3000 字')
    return kind, name, cutoff, note.strip()


def apply(items, payload, book, graph):
    kind, name, cutoff, note = _base(payload, book)
    op = payload.get('operation')
    if not isinstance(op, str) or not ID.fullmatch(op):
        raise ValueError('操作编号无效')
    item_id = payload['id']
    expected = integer(payload.get('expected_revision', 0), '条目版本', 0, 10**9)
    deleted = payload.get('deleted') is True
    operation_hash = hashlib.sha256(json.dumps(
        [item_id, kind, name, cutoff, note, expected, deleted],
        ensure_ascii=False, separators=(',', ':')).encode()).hexdigest()
    old = next((x for x in items if x['id'] == item_id), None)
    if old and old['operation'] == op:
        if old.get('operation_hash') and old['operation_hash'] != operation_hash:
            raise ValueError('上次操作的内容已经变化；请重新打开资料，核对保存结果后再修改')
        return items, old, False
    if expected != (old or {}).get('revision', 0):
        return items, old, True
    if old:
        if kind != old['kind'] or name != old['name']:
            raise ValueError('已有条目的名称和类型不可改；可以删除后重新补充')
        if cutoff < old['knowledge_cutoff']:
            raise ValueError('不能把后来补充的资料移到之前的阅读位置')
        source = old['source_start']
        versions = list(old['versions'])
        if not deleted:
            versions.append({'p': cutoff, 'note': note})
    else:
        if deleted:
            raise ValueError('没有这条可删除的资料')
        if len(items) >= MAX_ITEMS:
            raise ValueError('本书手动条目已达上限')
        source = anchor(book, name, cutoff)
        # Only compare records the reader could have seen. Never disclose future entities.
        for row in graph.get('log', []):
            if row['p'] > cutoff:
                break
            if row['t'] == 'person' and row.get('name', '').casefold() == name.casefold():
                raise ValueError('资料里已有这个名称；请在“全部”中搜索，不要重复创建')
        if any(not x.get('deleted') and x['name'].casefold() == name.casefold() for x in items):
            raise ValueError('已有同名的手动条目')
        versions = [{'p': cutoff, 'note': note}]
    now = time.time()
    clean = {'id': item_id, 'kind': kind, 'name': name, 'source_start': source,
             'knowledge_cutoff': old['knowledge_cutoff'] if deleted and old else cutoff, 'versions': versions, 'deleted': deleted,
             'revision': expected + 1, 'operation': op,
             'operation_hash': operation_hash,
             'created': (old or {}).get('created', now), 'updated': now}
    return [x for x in items if x['id'] != item_id] + [clean], clean, False


def rows(items):
    result = []
    for item in items:
        if item.get('deleted'):
            continue
        p = item['versions'][0]['p']
        result.append({'t': 'person', 'id': 'U' + item['id'], 'name': item['name'], 'p': p,
                       's': item['source_start'], 'intro': '', 'imp': 1,
                       'manual': True, 'entity_kind': item['kind']})
        for version in item['versions']:
            result.append({'t': 'profile', 'id': 'U' + item['id'], 'p': version['p'],
                           's': item['source_start'], 'bio': version['note'], 'manual': True})
    return sorted(result, key=lambda row: row['p'])


def mentions(blocks, items, existing):
    """Overlay source-exact manual names without replacing generated annotations."""
    active = [(item['name'], 'U' + item['id']) for item in items if not item.get('deleted')]
    if not active:
        return existing
    occupied = sorted((row[0], row[1]) for row in existing)
    starts = [start for start, _ in occupied]
    candidates = []
    for block in blocks:
        if block['k'] not in ('p', 'h'):
            continue
        source = block['t']
        found = []
        for name, item_id in active:
            at = source.find(name)
            while at >= 0:
                found.append((at, at + len(name), item_id))
                at = source.find(name, at + 1)
        if not found:
            continue
        prefix = [0]
        for char in source:
            prefix.append(prefix[-1] + (2 if ord(char) > 0xFFFF else 1))
        for first, last, item_id in found:
            candidates.append((block['o'] + prefix[first], block['o'] + prefix[last], item_id))
    # At a shared start, the longest name wins. Existing AI mentions always win overlaps.
    result = list(existing)
    for start, end, item_id in sorted(candidates, key=lambda row: (row[0], -(row[1] - row[0]))):
        i = bisect_left(starts, start)
        if i and occupied[i - 1][1] > start or i < len(occupied) and occupied[i][0] < end:
            continue
        occupied.insert(i, (start, end))
        starts.insert(i, start)
        result.append([start, end, item_id])
    return sorted(result, key=lambda row: (row[0], row[1]))


def restore(items, book):
    if not isinstance(items, list) or len(items) > MAX_ITEMS:
        raise ValueError('手动条目备份无效')
    result, seen = [], set()
    for item in items:
        kind, name, cutoff, _ = _base(item, book)
        if item['id'] in seen:
            raise ValueError('手动条目编号重复')
        seen.add(item['id'])
        versions = item.get('versions')
        if not isinstance(versions, list) or not versions or len(versions) > 1000:
            raise ValueError('手动条目版本无效')
        prev = -1
        clean_versions = []
        for v in versions:
            p = integer(v.get('p'), '补充位置', 0, book['len'])
            note = v.get('note')
            if p < prev or not isinstance(note, str) or len(note) > 3000:
                raise ValueError('手动条目版本无效')
            prev = p
            clean_versions.append({'p': p, 'note': note})
        if cutoff != prev:
            raise ValueError('手动条目已读范围无效')
        source = anchor(book, name, versions[0]['p'])
        if source != item.get('source_start'):
            raise ValueError('手动条目原文位置无效')
        revision = integer(item.get('revision'), '条目版本', 1, 10**9)
        op = item.get('operation')
        if not isinstance(op, str) or not ID.fullmatch(op):
            raise ValueError('手动条目操作编号无效')
        operation_hash = item.get('operation_hash')
        if operation_hash is not None and (not isinstance(operation_hash, str) or not re.fullmatch(r'[a-f0-9]{64}', operation_hash)):
            raise ValueError('手动条目操作摘要无效')
        result.append({'id': item['id'], 'kind': kind, 'name': name, 'source_start': source,
                       'knowledge_cutoff': cutoff, 'versions': clean_versions,
                       'deleted': item.get('deleted') is True, 'revision': revision,
                       'operation': op, 'created': item.get('created', 0), 'updated': item.get('updated', 0),
                       **({'operation_hash': operation_hash} if operation_hash else {})})
    return result
