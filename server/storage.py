"""Bounded read caches and validated, portable book snapshots."""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import tempfile
import threading
from collections import OrderedDict
from pathlib import Path

ASSET_LIMIT = 32 * 1024 * 1024
ASSETS_LIMIT = 96 * 1024 * 1024
MAX_RECORDS = 1_000_000
ASSET_NAME = re.compile(r'[A-Za-z0-9_-][A-Za-z0-9_.-]{0,127}\Z')


def signature(path: Path):
    st = path.stat()
    return (st.st_mtime_ns, st.st_size, st.st_ino)


class JsonCache:
    """Budget in serialized bytes; oversized bodies are deliberately not retained."""
    def __init__(self, count=128, budget=None, item_limit=None):
        self.count = count
        self.budget = budget if budget is not None else int(os.environ.get('JSON_CACHE_BYTES', 96 * 1024 * 1024))
        self.item_limit = item_limit if item_limit is not None else int(os.environ.get('JSON_CACHE_ITEM_BYTES', 64 * 1024 * 1024))
        self.entries = OrderedDict()
        self.size = 0
        self.lock = threading.RLock()
        self.loads = [threading.RLock() for _ in range(8)]

    def get(self, path, _attempt=0):
        path = Path(path)
        try:
            stamp = signature(path)
        except FileNotFoundError:
            self.evict(path)
            return None
        key = str(path)
        with self.lock:
            hit = self.entries.get(key)
            if hit and hit[0] == stamp:
                self.entries.move_to_end(key)
                return hit[1]
        # Coalesce concurrent reads of one large book; do not multiply parse allocations.
        with self.loads[hash(key) % len(self.loads)]:
            return self._load(path, key, stamp, _attempt)

    def _load(self, path, key, stamp, _attempt):
        with self.lock:
            hit = self.entries.get(key)
            if hit and hit[0] == stamp:
                self.entries.move_to_end(key)
                return hit[1]
        value = json.loads(path.read_text(encoding='utf-8'))
        if signature(path) != stamp:
            if _attempt >= 2:
                raise ValueError('文件正在更新，请稍后重试')
            return self.get(path, _attempt + 1)
        if stamp[1] <= self.item_limit:
            with self.lock:
                self.evict(path)
                self.entries[key] = (stamp, value)
                self.size += stamp[1]
                while len(self.entries) > self.count or self.size > self.budget:
                    _, (old, _) = self.entries.popitem(last=False)
                    self.size -= old[1]
        return value

    def evict(self, path):
        key = str(path)
        with self.lock:
            for k in list(self.entries):
                if k == key or k.startswith(key + os.sep):
                    stamp, _ = self.entries.pop(k)
                    self.size -= stamp[1]


def write_json(path: Path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name + '.', suffix='.tmp', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(value, f, ensure_ascii=False, separators=(',', ':'))
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


_BYLINE = re.compile(r'^(?P<title>.*?)\s*[-_—\s]*作者\s*[:：]\s*(?P<author>.*?)\s*$')
_SITE = re.compile(r'(?i)^[\w.-]+\.(com|net|org|cn|cc)$')


def display_title(title, author):
    """TXT file names often carry the byline ("书名 作者：某某"); show it as title + author.
    Display only: stored book data (and the ids derived from it) stay unchanged."""
    title, author = (title or '').strip(), (author or '').strip()
    m = _BYLINE.match(title)
    if m and m.group('title'):
        title = m.group('title')
        found = m.group('author').strip()
        if not author and found and not _SITE.match(found):
            author = found
    return title, author


def shelf_fields(book):
    chapters = book.get('chapters') or []
    out = {k: book.get(k) for k in ('title', 'author', 'len', 'cover', 'lang', 'genre')}
    if not out['lang']:
        from pipeline.lang import book_lang
        out['lang'] = book_lang(book)
    out.update(chapters=len(chapters), thin=(book.get('len') or 0) < 30000 or
               sum(c.get('kind') == 'body' for c in chapters) < 2)
    return out


def shelf_metadata(root, cache):
    # Cold shelf requests should not simultaneously parse the same large legacy body.
    with cache.loads[hash(str(root / 'book.json')) % len(cache.loads)]:
        return _shelf_metadata(root, cache)


def _shelf_metadata(root, cache):
    source = root / 'book.json'
    stamp = list(signature(source))
    target = root / 'shelf.json'
    stored = cache.get(target)
    if stored and stored.get('source') == stamp and stored.get('book', {}).get('lang'):
        return stored['book']
    # One sequential rebuild for legacy books; large text is not put in the read cache.
    book = json.loads(source.read_text(encoding='utf-8'))
    if list(signature(source)) != stamp:
        return shelf_metadata(root, cache)
    fields = shelf_fields(book)
    write_json(target, {'source': stamp, 'book': fields})
    return fields


def integer(value, label, low=0, high=120_000_000):
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise ValueError(f'{label}无效')
    return value


def asset_name(name):
    if not isinstance(name, str) or not ASSET_NAME.fullmatch(name):
        raise ValueError('图片文件名无效')
    return name


def validate_book(book):
    if not isinstance(book, dict) or not isinstance(book.get('title'), str):
        raise ValueError('书籍信息无效')
    length = integer(book.get('len'), '正文长度')
    blocks, chapters = book.get('blocks'), book.get('chapters')
    if not isinstance(blocks, list) or not blocks or len(blocks) > MAX_RECORDS:
        raise ValueError('正文段落无效')
    if not isinstance(chapters, list) or not chapters or len(chapters) > 100_000:
        raise ValueError('章节无效')
    previous = -1
    for block in blocks:
        if not isinstance(block, dict) or block.get('k') not in ('p', 'h', 'img') or not isinstance(block.get('t'), str):
            raise ValueError('正文段落格式无效')
        pos = integer(block.get('o'), '段落位置', 0, length)
        if pos < previous or pos + len(block['t'].encode('utf-16-le')) // 2 > length:
            raise ValueError('段落位置超出正文')
        previous = pos
        if block['k'] == 'img':
            asset_name(block.get('src'))
        for item in block.get('fn', []):
            if not isinstance(item, list) or len(item) != 2 or not isinstance(item[1], str):
                raise ValueError('脚注索引无效')
            integer(item[0], '脚注位置', 0, len(block['t'].encode('utf-16-le')) // 2)
    previous = -1
    for chapter in chapters:
        if not isinstance(chapter, dict) or not isinstance(chapter.get('title'), str):
            raise ValueError('章节格式无效')
        a = integer(chapter.get('b0'), '章节起点', 0, len(blocks))
        b = integer(chapter.get('b1'), '章节终点', a, len(blocks))
        p = integer(chapter.get('o0'), '章节位置', 0, length)
        integer(chapter.get('o1'), '章节终点', p, length)
        if a == b or p < previous:
            raise ValueError('章节顺序无效')
        previous = p
    if not isinstance(book.get('notes', {}), dict):
        raise ValueError('脚注格式无效')
    if not all(isinstance(k, str) and isinstance(v, str) for k, v in book.get('notes', {}).items()):
        raise ValueError('脚注内容无效')
    if book.get('cover'):
        asset_name(book['cover'])
    return book


def validate_graph(kg, length):
    if not isinstance(kg, dict) or not isinstance(kg.get('log', []), list):
        raise ValueError('人物图谱格式无效')
    log = kg.get('log', [])
    if len(log) > MAX_RECORDS:
        raise ValueError('人物图谱太大')
    fields = {'person': ('id', 'name'), 'name': ('id', 'name'), 'alias': ('id', 'alias'),
              'merge': ('from', 'into'), 'profile': ('id',), 'attr': ('id', 'key', 'value'),
              'rel': ('a', 'b'), 'event': ('text',), 'imp': ('id',), 'cnt': (),
              'recap': ('text',), 'saga': ('text',)}
    previous = -1
    for row in log:
        if not isinstance(row, dict) or row.get('t') not in fields:
            raise ValueError('人物记录类型无效')
        pos = integer(row.get('p'), '人物记录位置', 0, length)
        if pos < previous:
            raise ValueError('人物记录没有按位置排序')
        previous = pos
        for key in fields[row['t']]:
            if not isinstance(row.get(key), str):
                raise ValueError('人物记录字段无效')
        for key in ('intro', 'tagline', 'bio', 'family', 'a_is', 'b_is', 'desc', 'status', 'reason'):
            if key in row and row[key] is not None and not isinstance(row[key], str):
                raise ValueError('人物记录文本无效')
        if 's' in row:
            integer(row['s'], '原文位置', 0, length)
        if 'imp' in row:
            integer(row['imp'], '人物重要度', 0, 100)
        if 'chapter' in row:
            integer(row['chapter'], '章节编号', 0, 100_000)
        if row['t'] == 'event' and (not isinstance(row.get('who'), list) or
                                   not all(isinstance(x, str) for x in row['who'])):
            raise ValueError('事件人物无效')
        if row['t'] == 'cnt' and (not isinstance(row.get('c'), dict) or
                                 not all(isinstance(k, str) and isinstance(v, int) and v >= 0 for k, v in row['c'].items())):
            raise ValueError('人物计数无效')
    return kg


def referenced_assets(book):
    names = {b['src'] for b in book['blocks'] if b['k'] == 'img'}
    if book.get('cover'):
        names.add(book['cover'])
    return names


def encode_assets(root, book):
    assets, total = {}, 0
    for name in sorted(referenced_assets(book)):
        asset_name(name)
        path = root / 'img' / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('这本书缺少图片，请先修复后再导出')
        size = path.stat().st_size
        total += size
        if size > ASSET_LIMIT or total > ASSETS_LIMIT:
            raise ValueError('图片超过导出限制')
        raw = path.read_bytes()
        assets[name] = {'size': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(),
                        'base64': base64.b64encode(raw).decode('ascii')}
    return assets


def decode_assets(assets, book):
    if not isinstance(assets, dict) or set(assets) != referenced_assets(book):
        raise ValueError('图片清单与正文不一致')
    out, total = {}, 0
    for name, item in assets.items():
        asset_name(name)
        if not isinstance(item, dict):
            raise ValueError('图片格式无效')
        size = integer(item.get('size'), '图片长度', 0, ASSET_LIMIT)
        total += size
        if total > ASSETS_LIMIT:
            raise ValueError('图片总量太大')
        encoded = item.get('base64')
        if not isinstance(encoded, str) or len(encoded) > ((size + 2) // 3) * 4:
            raise ValueError('图片编码长度无效')
        try:
            raw = base64.b64decode(encoded, validate=True)
        except Exception as exc:
            raise ValueError('图片编码无效') from exc
        if len(raw) != size or hashlib.sha256(raw).hexdigest() != item.get('sha256'):
            raise ValueError('图片校验失败')
        out[name] = raw
    return out
