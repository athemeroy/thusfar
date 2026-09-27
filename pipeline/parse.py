"""Turn TXT / EPUB / MOBI / AZW3 into a reader-friendly book structure.

Output (book.json):
  blocks:   [{k: 'p'|'h'|'img', t: text, o: global UTF-16 offset, fn: [[offset_in_block, note_id]], src}]
  chapters: [{title, depth, b0, b1, o0, o1, kind}]   kind: front | body | back
  notes:    {note_id: text}
All positions are UTF-16 code-unit offsets into "\n".join(block texts), so the
browser can use them directly.
"""
from __future__ import annotations

import hashlib
import html
import json
import posixpath
import re
import shutil
import sys
import tempfile
import zipfile
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit
from xml.etree import ElementTree as ET

MAX_CHARS = 60_000_000      # a whole collected works; the pipeline is resumable, it just takes hours
MAX_EPUB_MEMBERS = 20_000
MAX_EPUB_MEMBER_BYTES = 32 * 1024 * 1024
MAX_EPUB_EXPANDED_BYTES = 512 * 1024 * 1024
BLOCK_TAGS = {'p', 'div', 'section', 'article', 'li', 'blockquote', 'tr', 'dd', 'dt',
              'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'pre', 'figcaption', 'caption'}
SKIP_TAGS = {'head', 'title', 'script', 'style', 'template', 'noscript', 'iframe', 'object',
             'embed', 'svg', 'rt', 'rp'}
VOID_TAGS = {'br', 'hr', 'img', 'meta', 'link', 'input', 'source', 'wbr', 'area', 'base', 'col',
             'param', 'image'}


def u16(s: str) -> int:
    return len(s.encode('utf-16-le')) // 2


def clean(s: str) -> str:
    s = re.sub(r'[​‌‍﻿]', '', s)
    s = re.sub(r'[ \t\r\n ]+', ' ', s)
    return s.strip(' 　')


def math_text(source: str) -> str:
    """Preserve accessible text or MathML structure without executing markup."""
    try:
        root = ET.fromstring(source)
        accessible = root.get('alttext') or root.get('aria-label')
        if accessible:
            return accessible
        if root.tag.rsplit('}', 1)[-1] == 'svg':
            labels = [clean(''.join(node.itertext())) for node in root.iter()
                      if node.tag.rsplit('}', 1)[-1] in ('title', 'desc', 'text')]
            readable = '；'.join(dict.fromkeys(label for label in labels if label))
            return '［图形：' + readable + '］' if readable else '［图形缺少可读取文本］'
        def render(node):
            tag = node.tag.rsplit('}', 1)[-1]
            children = list(node)
            parts = [render(c) for c in children]
            if tag in ('annotation', 'annotation-xml'):
                return ''
            if tag == 'mfrac' and len(parts) == 2:
                return f'({parts[0]})/({parts[1]})'
            if tag in ('msup', 'msub') and len(parts) == 2:
                return f'({parts[0]})' + ('^' if tag == 'msup' else '_') + f'({parts[1]})'
            if tag == 'msubsup' and len(parts) == 3:
                return f'({parts[0]})_({parts[1]})^({parts[2]})'
            if tag in ('msqrt', 'mroot'):
                return 'sqrt(' + ','.join(parts) + ')'
            return (node.text or '') + ''.join(p + (c.tail or '') for c, p in zip(children, parts))
        return clean(render(root)) or '［公式缺少可读取文本］'
    except ET.ParseError:
        return clean(re.sub(r'<[^>]+>', '', html.unescape(source))) or '［公式格式无法解析］'


# ---------------------------------------------------------------- HTML → blocks
class DocParser(HTMLParser):
    """Collect blocks of one XHTML document, remembering anchors and footnote refs."""

    def __init__(self, doc: str):
        super().__init__(convert_charrefs=True)
        self.doc = doc
        self.blocks: list[dict] = []
        self.cur: dict | None = None
        self.buf: list[str] = []
        self.skip = 0
        self.stack: list[tuple[str, bool]] = []
        self.pending_ids: list[str] = []       # ids seen before a block started
        self.ref: dict | None = None            # an <a href=#x> being read
        self.heading: str | None = None
        self.cls: str | None = None
        self.math_depth = 0
        self.math_parts: list[str] = []

    # block handling --------------------------------------------------------
    def _flush(self):
        if self.cur is None:
            return
        raw = ''.join(self.buf)
        text = clean(raw)
        # keep footnote refs aligned with cleaned text: they were recorded as raw offsets
        fn = []
        if self.cur['fn_raw']:
            lead = len(raw) - len(raw.lstrip(' \t\r\n 　'))
            for off, target in self.cur['fn_raw']:
                prefix = clean(raw[:off]) if off > lead else ''
                fn.append([u16(prefix), target])
        if text or self.cur['ids']:
            self.blocks.append({'k': self.cur['k'], 't': text, 'ids': self.cur['ids'], 'fn': fn,
                                'cls': self.cur['cls']})
        self.cur = None
        self.buf = []

    def _start(self, kind: str, cls: str | None):
        self._flush()
        self.cur = {'k': kind, 'ids': self.pending_ids, 'fn_raw': [], 'cls': cls}
        self.pending_ids = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if self.math_depth or (tag in ('math', 'svg') and not self.skip and a.get('aria-hidden') != 'true'):
            self.math_depth += 1
            self.math_parts.append(self.get_starttag_text())
            return
        hidden = tag in SKIP_TAGS or 'hidden' in a or a.get('aria-hidden') == 'true' or bool(
            re.search(r'display\s*:\s*none', a.get('style') or '', re.I))
        if tag not in VOID_TAGS:
            self.stack.append((tag, hidden))
            self.skip += hidden
        if self.skip:
            return
        if a.get('id'):
            if self.cur is not None:
                self.cur['ids'].append(a['id'])
            else:
                self.pending_ids.append(a['id'])
        if tag in BLOCK_TAGS:
            kind = 'h' if re.fullmatch(r'h[1-6]', tag) else 'p'
            self._start(kind, a.get('class'))
            if kind == 'h':
                self.cur['level'] = int(tag[1])
        elif tag == 'br':
            if self.cur is not None and ''.join(self.buf).strip():
                k, cls = self.cur['k'], self.cur['cls']
                self._start(k, cls)
        elif tag in ('img', 'image'):
            src = a.get('src') or a.get('xlink:href') or a.get('href')
            if src:
                self._flush()
                self.blocks.append({'k': 'img', 't': '', 'src': src, 'alt': a.get('alt') or '',
                                    'ids': self.pending_ids, 'fn': []})
                self.pending_ids = []
        elif tag == 'a' and a.get('href') and '#' in a['href']:
            self.ref = {'href': a['href'], 'text': '', 'raw_at': len(''.join(self.buf))}
        elif tag == 'sup' and self.ref is not None:
            self.ref['sup'] = True

    def handle_endtag(self, tag):
        if self.math_depth:
            self.math_parts.append(f'</{tag}>')
            self.math_depth -= 1
            if self.math_depth == 0:
                value = math_text(''.join(self.math_parts))
                self.math_parts = []
                self.handle_data(' ' + value + ' ')
            return
        for i in range(len(self.stack) - 1, -1, -1):
            if self.stack[i][0] == tag:
                self.skip -= sum(h for _, h in self.stack[i:])
                del self.stack[i:]
                break
        if self.skip:
            return
        if tag == 'a' and self.ref is not None:
            ref, self.ref = self.ref, None
            label = ref['text'].strip()
            is_note = ref.get('sup') or re.fullmatch(r'[\[\(（〔【]?\s*(?:注)?\d{1,3}\s*[\]\)）〕】]?|[*†‡]+', label or '')
            if is_note and self.cur is not None:
                # remove the marker text from the block and remember the reference
                joined = ''.join(self.buf)
                start = ref['raw_at']
                self.buf = [joined[:start]]
                self.cur['fn_raw'].append((start, ref['href']))
            return
        if tag in BLOCK_TAGS:
            self._flush()

    def handle_startendtag(self, tag, attrs):
        if self.math_depth:
            self.math_parts.append(self.get_starttag_text())
        elif tag in ('math', 'svg') and not self.skip and dict(attrs).get('aria-hidden') != 'true':
            self.handle_data(' ' + math_text(self.get_starttag_text()) + ' ')
        else:
            super().handle_startendtag(tag, attrs)

    def handle_data(self, data):
        if self.math_depth:
            self.math_parts.append(html.escape(data))
            return
        if self.skip:
            return
        if self.ref is not None:
            self.ref['text'] += data
        if self.cur is None:
            if not data.strip():
                return
            self._start('p', None)
        self.buf.append(data)

    def close(self):
        super().close()
        if self.math_depth:
            self.math_depth = 0
            self.handle_data('［未闭合公式或图形］' + math_text(''.join(self.math_parts)))
            self.math_parts = []
        self._flush()


# ---------------------------------------------------------------- EPUB
def _xml(raw: bytes):
    raw = re.sub(rb'<!DOCTYPE[^>]*>', b'', raw)
    if b'<!ENTITY' in raw.upper():
        raise ValueError('电子书 XML 含有不允许的实体声明。')
    return ET.fromstring(raw)


def _local(tag: str) -> str:
    return tag.rsplit('}', 1)[-1]


def _ref(base: str, href: str) -> tuple[str, str]:
    parts = urlsplit(href)
    if parts.scheme or parts.netloc:
        return '', ''
    path = posixpath.normpath(posixpath.join(base, unquote(parts.path))) if parts.path else ''
    return path, parts.fragment


def _toc(z: zipfile.ZipFile, opf, opf_dir: str, manifest: dict) -> list[dict]:
    """Return flat TOC entries [{title, depth, doc, frag}] from EPUB3 nav or NCX."""
    out: list[dict] = []
    nav = next((it for it in manifest.values() if 'nav' in (it.get('properties') or '').split()), None)
    if nav is not None:
        path, _ = _ref(opf_dir, nav.get('href'))
        base = posixpath.dirname(path)
        try:
            root = _xml(z.read(path))
            for navel in root.iter():
                if _local(navel.tag) != 'nav':
                    continue
                kind = navel.get('{http://www.idpf.org/2007/ops}type') or navel.get('epub:type') or ''
                if kind and kind != 'toc':
                    continue

                def walk(ol, depth):
                    for li in ol:
                        if _local(li.tag) != 'li':
                            continue
                        a = next((x for x in li if _local(x.tag) in ('a', 'span')), None)
                        if a is not None:
                            title = clean(''.join(a.itertext()))
                            doc, frag = _ref(base, a.get('href') or '')
                            if title and doc:
                                out.append({'title': title, 'depth': depth, 'doc': doc, 'frag': frag})
                        for sub in li:
                            if _local(sub.tag) == 'ol':
                                walk(sub, depth + 1)

                for ol in navel:
                    if _local(ol.tag) == 'ol':
                        walk(ol, 0)
                if out:
                    return out
        except Exception:
            out = []
    spine = next((n for n in opf.iter() if _local(n.tag) == 'spine'), None)
    ncx_id = spine.get('toc') if spine is not None else None
    ncx = manifest.get(ncx_id) if ncx_id else None
    if ncx is None:
        ncx = next((it for it in manifest.values() if (it.get('media-type') or '').endswith('dtbncx+xml')), None)
    if ncx is None:
        return out
    path, _ = _ref(opf_dir, ncx.get('href'))
    base = posixpath.dirname(path)
    root = _xml(z.read(path))

    def walk(node, depth):
        for np in node:
            if _local(np.tag) != 'navPoint':
                continue
            label = next((x for x in np.iter() if _local(x.tag) == 'text'), None)
            content = next((x for x in np if _local(x.tag) == 'content'), None)
            title = clean(label.text or '') if label is not None else ''
            if content is not None and title:
                doc, frag = _ref(base, content.get('src') or '')
                out.append({'title': title, 'depth': depth, 'doc': doc, 'frag': frag})
            walk(np, depth + 1)

    navmap = next((x for x in root.iter() if _local(x.tag) == 'navMap'), None)
    if navmap is not None:
        walk(navmap, 0)
    return out


def parse_epub(path: Path, out_dir: Path) -> dict:
    with zipfile.ZipFile(path) as z:
        entries = z.infolist()
        if (len(entries) > MAX_EPUB_MEMBERS
                or sum(e.file_size for e in entries) > MAX_EPUB_EXPANDED_BYTES
                or any(e.file_size > MAX_EPUB_MEMBER_BYTES for e in entries)):
            raise ValueError('EPUB 解压规模超过限制，请拆分文件后导入。')
        if len({e.filename for e in entries}) != len(entries):
            raise ValueError('EPUB 包含重复文件名，无法可靠解析。')
        names = set(z.namelist())
        if 'META-INF/encryption.xml' in names:
            raise ValueError('此 EPUB 有 DRM 加密，无法读取。')
        container = _xml(z.read('META-INF/container.xml'))
        opf_path = next(n.get('full-path') for n in container.iter() if _local(n.tag) == 'rootfile')
        opf = _xml(z.read(opf_path))
        opf_dir = posixpath.dirname(opf_path)
        meta = {}
        for n in opf.iter():
            t = _local(n.tag)
            if t in ('title', 'creator') and n.text and t not in meta:
                meta[t] = clean(n.text)
        manifest = {n.get('id'): n for n in opf.iter() if _local(n.tag) == 'item'}
        spine = [manifest[n.get('idref')] for n in opf.iter()
                 if _local(n.tag) == 'itemref' and n.get('idref') in manifest]
        toc = _toc(z, opf, opf_dir, manifest)

        img_dir = out_dir / 'img'
        # pass 1: parse every spine document
        docs = []
        parsed_chars = 0
        for item in spine:
            doc, _ = _ref(opf_dir, item.get('href') or '')
            if not doc or doc not in names:
                continue
            media = item.get('media-type') or ''
            if 'html' not in media and not doc.endswith(('.html', '.htm', '.xhtml')):
                continue
            p = DocParser(doc)
            p.feed(z.read(doc).decode('utf-8-sig', errors='replace'))
            p.close()
            parsed_chars += sum(len(b['t']) for b in p.blocks)
            if parsed_chars > MAX_CHARS:
                raise ValueError('EPUB 正文超过字符限制，请拆分后导入。')
            base = posixpath.dirname(doc)
            for b in p.blocks:
                b['fn'] = [(off, _ref(base, href)) for off, href in b['fn']]
                b['fn'] = [(off, (t[0] or doc, t[1])) for off, t in b['fn']]
            docs.append((doc, p.blocks))
        # pass 2: a footnote body is a block whose anchor is referenced from an EARLIER block
        seq = [(doc, b) for doc, bl in docs for b in bl]
        first_ref: dict[tuple[str, str], int] = {}
        for i, (doc, b) in enumerate(seq):
            for _, tgt in b['fn']:
                first_ref.setdefault(tgt, i)
        notes: dict[str, str] = {}
        note_blocks = set()
        for i, (doc, b) in enumerate(seq):
            if b['k'] != 'p':
                continue
            hit = next((x for x in b.get('ids', []) if first_ref.get((doc, x), i) < i), None)
            if hit is not None:
                notes[f'{doc}#{hit}'] = re.sub(r'^[\[\(（〔【]?\d{1,3}[\]\)）〕】]?\s*', '', b['t'])
                note_blocks.add(i)
        blocks: list[dict] = []
        doc_first: dict[str, int] = {}
        anchors: dict[tuple[str, str], int] = {}
        images: dict[str, str] = {}
        for i, (doc, b) in enumerate(seq):
            doc_first.setdefault(doc, len(blocks))
            if i in note_blocks:
                continue
            idx = len(blocks)
            for x in b.pop('ids', []):
                anchors.setdefault((doc, x), idx)
            b['fn'] = [[off, f'{t[0]}#{t[1]}'] for off, t in b['fn'] if f'{t[0]}#{t[1]}' in notes]
            if b['k'] == 'img':
                ipath, _ = _ref(posixpath.dirname(doc), b['src'])
                if ipath in names:
                    if ipath not in images:
                        data = z.read(ipath)
                        if len(data) > 1500:   # skip tiny spacer images
                            img_dir.mkdir(parents=True, exist_ok=True)
                            name = hashlib.sha1(ipath.encode()).hexdigest()[:12] + (Path(ipath).suffix.lower() or '.jpg')
                            (img_dir / name).write_bytes(data)
                            images[ipath] = name
                        else:
                            images[ipath] = ''
                    if images[ipath]:
                        blocks.append({'k': 'img', 't': '', 'src': images[ipath], 'alt': b.get('alt', '')})
                continue
            if not b['t']:
                continue
            blocks.append(b)
        # drop the note bodies' empty anchors from notes keys that were never referenced
        # map TOC → chapter starts
        starts = []
        for e in toc:
            idx = anchors.get((e['doc'], e['frag'])) if e['frag'] else None
            if idx is None:
                idx = doc_first.get(e['doc'])
            if idx is None:
                continue
            starts.append((idx, e['title'], e['depth']))
        cover = _cover(z, opf, opf_dir, manifest, names, out_dir)
    book = finish(blocks, starts, notes, meta.get('title') or path.stem, meta.get('creator') or '')
    sample = []
    remaining = 200000
    for block in blocks:
        if remaining <= 0:
            break
        part = block['t'][:remaining]
        sample.append(part)
        remaining -= len(part)
    book['lang'] = detect_lang(''.join(sample))
    if cover:
        book['cover'] = cover
    return book


def _cover(z, opf, opf_dir, manifest, names, out_dir: Path) -> str | None:
    """Save the EPUB cover image (EPUB2 <meta name=cover> or EPUB3 cover-image) as cover.<ext>."""
    item = None
    for n in opf.iter():
        if _local(n.tag) == 'meta' and n.get('name') == 'cover' and n.get('content') in manifest:
            item = manifest[n.get('content')]
    if item is None:
        item = next((it for it in manifest.values() if 'cover-image' in (it.get('properties') or '').split()), None)
    if item is None or not (item.get('media-type') or '').startswith('image/'):
        return None
    path, _ = _ref(opf_dir, item.get('href') or '')
    if path not in names:
        return None
    data = z.read(path)
    if len(data) > 8_000_000:
        return None
    name = 'cover' + (Path(path).suffix.lower() or '.jpg')
    (out_dir / 'img').mkdir(parents=True, exist_ok=True)
    (out_dir / 'img' / name).write_bytes(data)
    return name


# ---------------------------------------------------------------- TXT
CHAPTER_RE = re.compile(
    r'^\s*(?:[零〇一二三四五六七八九十百]{1,4}[、.．]?|'      # a line that is only a numeral: 一 / 二、
    r'(?:第[零〇一二三四五六七八九十百千万两0-9０-９]+[章回节卷集部篇幕])[^\n]{0,30}|'
    r'(?:序章|序言|序|楔子|引子|尾声|后记|番外[^\n]{0,20}|chapter\s+\d+[^\n]{0,40}|CHAPTER\s+[IVXLC\d]+[^\n]{0,40}))\s*$',
    re.I)


AOZORA_NOTE = re.compile(r'［＃(.*?)］')
AOZORA_HEAD = re.compile(r'「(.+?)」は(大|中|小)見出し')
# Plain Japanese downloads may already have had Aozora's heading annotations removed.
# Keep explicit divisions such as "第一 雪と人生" and "第一の手記"; figure captions
# ("第１図版", "第３図") are not chapter headings.
JA_PART_RE = re.compile(
    r'^(?:第[零〇一二三四五六七八九十百千万0-9０-９]+(?:の手記|[\s　]+\S.{0,29})|'
    r'[上中下][\s　]+\S.{0,29})$')
JA_FRAME_RE = re.compile(r'^(?:はしがき|あとがき|附記(?:[\s　]+.{1,30})?)$')


def is_aozora(text: str) -> bool:
    return '［＃' in text[:4000] and ('《' in text[:4000] or '底本：' in text)


def parse_aozora(text: str, name: str) -> dict:
    """Japanese texts from 青空文庫: ruby in 《》, editor notes in ［＃］, headings marked in those notes."""
    lines = text.replace('\r', '').split('\n')
    # the explanatory block at the top sits between two rows of dashes; the colophon starts at 底本：
    dash = [i for i, ln in enumerate(lines[:40]) if ln.startswith('---')]
    head_lines = lines[:dash[0]] if dash else lines[:2]
    body = lines[dash[1] + 1:] if len(dash) >= 2 else lines
    for i, ln in enumerate(body):
        if ln.startswith('底本：'):
            body = body[:i]
            break
    title = (head_lines[0] if head_lines else name).strip() or name
    author = (head_lines[1].strip() if len(head_lines) > 1 else '')
    blocks, starts = [], []
    for raw in body:
        notes = AOZORA_NOTE.findall(raw)
        level = None
        for n in notes:
            m = AOZORA_HEAD.search(n)
            if m:
                level = {'大': 0, '中': 1, '小': 2}[m.group(2)]
        t = AOZORA_NOTE.sub('', raw)
        t = re.sub(r'[｜|]', '', t)
        t = re.sub(r'《[^》]*》', '', t)          # ruby: keep the word, drop the reading
        t = clean(t)
        if not t:
            continue
        if level is not None and len(t) <= 40:
            starts.append((len(blocks), t, min(level, 1)))
            blocks.append({'k': 'h', 't': t, 'level': 2})
        else:
            blocks.append({'k': 'p', 't': t})
    if not starts or starts[0][0] > 0:
        starts.insert(0, (0, '冒頭', 0))
    book = finish(blocks, starts, {}, title, author)
    book['lang'] = 'ja'
    return book


def decode_txt(raw: bytes) -> str:
    if raw.startswith((b'\xff\xfe', b'\xfe\xff')):
        return raw.decode('utf-16')
    for enc in ('utf-8-sig', 'gb18030', 'big5'):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode('utf-8', errors='replace')


# What a chapter is called, in the languages books actually arrive in. Without the non-English
# words here, a French novel is one chapter and a Russian one is one chapter: 20 of 26 public-domain
# books fetched on 2026-09-21 parsed as a single chapter, which costs the reader every chapter-level
# feature and gives the pipeline nothing to recap between.
HEAD_WORDS = (r'chapter|book|part|stave|letter|volume|section|canto|act|scene|problem'  # English
              r'|chapitre|livre|partie|acte|sc[eè]ne'                                    # French
              r'|kapitel|buch|teil|abschnitt|aufzug|auftritt'                            # German
              r'|cap[ií]tulo|libro|parte|acto|escena|cap[ií]tulo'                        # Spanish / Portuguese
              r'|capitolo|atto'                                                          # Italian
              r'|глава|часть|книга|действие|явление')                                    # Russian
# the ordinal that follows it, spelled or written, in those same languages
HEAD_NUMS = (r'[0-9]+|[ivxlcdm]+|the\s+\w+'
             r'|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve'
             r'|first|second|third|fourth|fifth|last'
             r'|premi[eè]re?|deuxi[eè]me|second[e]?|troisi[eè]me|quatri[eè]me|cinqui[eè]me|derni[eè]re?'
             r'|erste[rsn]?|zweite[rsn]?|dritte[rsn]?|vierte[rsn]?|f[uü]nfte[rsn]?|letzte[rsn]?'
             r'|primer[ao]?|segund[ao]|tercer[ao]?|cuart[ao]|quint[ao]|[úu]ltim[ao]'
             # Russian ordinals decline; match the stem and let any ending follow
             r'|перв\w*|втор\w*|трет\w*|четв\w*|пят\w*|шест\w*|седьм\w*|последн\w*')
# German and Spanish put the ordinal first — "Erstes Kapitel", "Primera parte" — so both
# orders count as a heading.
EN_CHAPTER_RE = re.compile(
    rf"^(?:(?:{HEAD_WORDS})\s*(?:{HEAD_NUMS})\b[.:]?.{{0,60}}"
    rf"|(?:{HEAD_NUMS})\s+(?:{HEAD_WORDS})\b[.:]?.{{0,60}}"
    rf"|[IVXLC]{{1,7}}\.?)$", re.I)
# A heading that is nothing but a number: "II." in a German novella, "一" in a Japanese one, a
# centred roman numeral in a Spanish one. Kept apart from the keyword kinds and ranked below them,
# because on its own a bare numeral is weak evidence.
BARE_HEAD_RE = re.compile(r'^(?:[IVXLCDM]{1,7}\.?|[0-9]{1,3}\.?|'
                          r'[一二三四五六七八九十百]{1,4}|第[一二三四五六七八九十百千0-9]{1,5}[章回節节部篇卷])$', re.I)


def _gutenberg(text: str) -> tuple[str, str, str]:
    """Cut Project Gutenberg's licence header/footer; return (text, title, author)."""
    title = author = ''
    m = re.search(r'^\*\*\*\s*START OF (?:THE|THIS) PROJECT GUTENBERG.*$', text, re.M | re.I)
    if m:
        head = text[:m.start()]
        t = re.search(r'^Title:\s*(.+)$', head, re.M)
        a = re.search(r'^Author:\s*(.+)$', head, re.M)
        title, author = (t.group(1).strip() if t else ''), (a.group(1).strip() if a else '')
        text = text[m.end():]
        e = re.search(r'^\*\*\*\s*END OF (?:THE|THIS) PROJECT GUTENBERG.*$', text, re.M | re.I)
        if e:
            text = text[:e.start()]
    return text, title, author


def parse_latin_txt(text: str, name: str) -> dict:
    """Hard-wrapped Western text: paragraphs are separated by blank lines; headings are
    'Chapter IV.' style lines, or (when there are none) short all-capital lines."""
    text, title, author = _gutenberg(text)
    paras = [re.sub(r'\s+', ' ', p).strip() for p in re.split(r'\n\s*\n', text.replace('\r', ''))]
    paras = [p.replace('_', '') for p in paras if p]

    def caps(t):
        return len(t) <= 60 and re.search(r'[A-Z]{2}', t) and not re.search(r'[a-z]', t) \
            and not t.rstrip('”’"\' ').endswith(('.', ',', '!', '?', ';', ':')) and not t.startswith(('[', '*', '“', '"', '‘', "'"))
    # Books mark their divisions in several ways at once: "CHAPTER I", "ACT II", a bare "III.",
    # or a shouted title. Group the candidates by kind, keep the kind that actually divides the
    # whole book (enough of them, reaching past the middle), and let a second kind be the level
    # below it — acts over scenes, a story title over its numbered sections.
    KEYWORD = re.compile(rf'^({HEAD_WORDS})\b', re.I)
    groups: dict[str, list[int]] = {}
    for i, t in enumerate(paras):
        if len(t) > 80:
            continue
        t = t.strip()          # a centred heading arrives padded; ^ would never match it
        if not t:
            continue
        if EN_CHAPTER_RE.match(t):
            m = KEYWORD.match(t)
            kind = m.group(1).lower() if m else 'numbered'
        elif BARE_HEAD_RE.match(t):
            kind = 'bare'
        elif caps(t):
            kind = 'shouted'
        else:
            continue
        groups.setdefault(kind, []).append(i)

    def divides(idx: list[int]) -> bool:
        return len(idx) >= 3 and idx[-1] >= len(paras) * 0.5

    ranked = sorted((k for k, v in groups.items() if divides(v)),
                    key=lambda k: (k == 'bare', k == 'shouted', -len(groups[k])))
    depth = {}
    if ranked:
        outer = min(ranked, key=lambda k: len(groups[k])) if len(ranked) > 1 else ranked[0]
        chap = list(groups[outer])
        for k in ranked:
            if k != outer and len(groups[k]) > len(groups[outer]):
                depth.update({i: 1 for i in groups[k] if i not in chap})
                chap += [i for i in groups[k] if i not in chap]
        chap.sort()
    else:                      # nothing divides the book: fall back to whatever is most common
        chap = sorted(max(groups.values(), key=len)) if groups else []
    heads = set(chap if len(chap) >= 3 else [])
    # A table of contents is a run of headings with nothing in between, near the front of the book.
    # Further in, two headings close together are a story title followed by its first section.
    order = sorted(heads)
    front = max(10, len(paras) // 10)
    toc = set()
    for a, b in zip(order, order[1:]):
        if a < front and sum(len(paras[k]) for k in range(a + 1, b)) < 120:
            toc.add(a)
    if len(toc) >= 3:
        heads -= toc
    else:
        toc = set()
    # Preserve explicit prose boundaries even when numbered problems/chapters are the main
    # hierarchy. Otherwise a long technical introduction is swallowed by synthetic Front matter.
    heads.update(i for i, t in enumerate(paras)
                 if re.fullmatch(r'(?:PREFACE|INTRODUCTION|CONTENTS|APPENDIX)\.?', t))
    blocks, starts = [], []
    for i, t in enumerate(paras):
        if i in heads:
            t = t.rstrip('.')
            starts.append((len(blocks), t, depth.get(i, 0)))
            blocks.append({'k': 'h', 't': t, 'level': 2})
        else:
            blocks.append({'k': 'p', 't': t})
    if not starts or starts[0][0] > 0:
        starts.insert(0, (0, 'Front matter', 0))
    book = finish(blocks, starts, {}, title or name, author)
    book['lang'] = detect_lang(text)
    return book


def is_latin_text(text: str) -> bool:
    sample = text[:200000]
    latin = len(re.findall(r'[A-Za-z]', sample))
    cjk = len(re.findall(r'[\u3400-\u9fff]', sample))
    return latin > 20 * max(1, cjk) or _cyrillic(sample) > 20 * max(1, cjk)


def _cyrillic(sample: str) -> int:
    return len(re.findall(r'[\u0400-\u04ff]', sample))


# A handful of words that are common in one language and rare in the others. Enough to tell apart
# the scripts' occupants, which is all the pipeline needs: how dense the text is (a page of English
# holds a third of what a page of Chinese does), how long a quotable fragment is, and what to tell
# the extraction model the book is written in.
LANG_WORDS = {
    'en': r'\b(the|and|of|that|with|which|was|his|her)\b',
    'fr': r'\b(le|la|les|des|une|qui|que|dans|pour|elle|était)\b',
    'de': r'\b(der|die|das|und|nicht|sich|ein|den|mit|war)\b',
    'es': r'\b(el|la|los|las|que|con|por|para|una|más)\b',
    'it': r'\b(il|la|che|di|per|con|una|gli|nel)\b',
    'pt': r'\b(o|a|os|as|que|com|para|uma|não|ele)\b',
    'nl': r'\b(de|het|een|van|niet|dat|zijn|met)\b',
    'ru': r'\b(и|в|не|на|что|он|с|как|это|она)\b',
}


def detect_lang(text: str) -> str:
    """Which language a book is written in: a real code, not a script flag.

    `lang == 'en'` used to stand in for "not Chinese", so a Russian novel was 'en' and a French one
    was 'en'. That was harmless while every book was Chinese or English; it stopped being harmless
    the moment the corpus gained French, German, Spanish, Russian and Japanese books, because the
    extraction prompt tells the model how many events to expect per page and how long a quote is,
    and both of those are properties of the script.
    """
    sample = text[:200000]
    cjk = len(re.findall(r'[\u3400-\u9fff]', sample))
    kana = len(re.findall(r'[\u3040-\u30ff]', sample))
    if kana > max(200, cjk * 0.05):
        return 'ja'
    if cjk > 200 and cjk > len(re.findall(r'[A-Za-z]', sample)) / 20:
        return 'zh'
    low = sample.lower()
    scores = {code: len(re.findall(pat, low)) for code, pat in LANG_WORDS.items()}
    best = max(scores, key=scores.get)
    return best if scores[best] >= 20 else ('ru' if _cyrillic(sample) > 200 else 'en')


# How much text one "unit of story" takes, by script: a page of Latin prose says about as much as
# a third of a page of Chinese. Used for how many events to ask for, and for cost estimates.
LATIN_LANGS = frozenset(LANG_WORDS) - {'ru'} | {'ru'}


def is_cjk(lang: str | None) -> bool:
    return lang in ('zh', 'ja', None)


TXT_AUTHOR_RE = re.compile(r'(?:作者|著者|作\s*者)\s*[:：]\s*(\S.{0,19})')
TXT_NAME_RE = re.compile(r'[\u4e00-\u9fff·]{2,6}')
TXT_SENTENCE_RE = re.compile(r'[。，！？；：、,.!?;:]')


def txt_author(lines: list[str], stem: str) -> str:
    """The author of a Chinese TXT: an explicit 作者：X near the top, or a short name right
    under a first line that is the title (故乡 / 鲁迅). Otherwise unknown."""
    head = [t for t in lines if t][:6]
    for t in head:
        m = TXT_AUTHOR_RE.fullmatch(t)
        if m:
            return m.group(1).strip()
    # imports are stored as source.txt, so the first line cannot be matched to the file name:
    # accept a title-like first line instead (short, not a chapter, no sentence punctuation)
    title_like = head and (head[0] == stem or (len(head[0]) <= 20 and not CHAPTER_RE.match(head[0])
                                              and not TXT_SENTENCE_RE.search(head[0])))
    if len(head) > 2 and title_like and TXT_NAME_RE.fullmatch(head[1]) \
            and not CHAPTER_RE.match(head[1]):
        return head[1]
    return ''


def parse_txt(path: Path, out_dir: Path) -> dict:
    text = decode_txt(path.read_bytes())
    if len(text) > MAX_CHARS:
        raise ValueError('这本书超过 6000 万字，拆成几本再传。')
    if is_aozora(text):
        return parse_aozora(text, path.stem)
    if is_latin_text(text):
        return parse_latin_txt(text, path.stem)
    lang = detect_lang(text)
    lines = [clean(line) for line in text.splitlines()]
    blocks, starts = [], []
    for t in lines:
        if not t:
            continue
        major = lang == 'ja' and (JA_PART_RE.fullmatch(t) or JA_FRAME_RE.fullmatch(t))
        if len(t) <= 40 and (major or CHAPTER_RE.match(t)):
            starts.append((len(blocks), t, 0))
            blocks.append({'k': 'h', 't': t, 'level': 2})
        else:
            blocks.append({'k': 'p', 't': t})
    if not starts or starts[0][0] > 0:
        starts.insert(0, (0, '开始', 0))
    book = finish(blocks, starts, {}, path.stem, txt_author(lines, path.stem))
    book['lang'] = lang
    return book


# ---------------------------------------------------------------- MOBI / AZW3
def _html_book(html: str, name: str) -> dict:
    p = DocParser('book.html')
    p.feed(html)
    p.close()
    blocks = [b for b in p.blocks if b['k'] != 'img' and b['t']]
    for b in blocks:
        b.pop('ids', None)
        b['fn'] = []
    starts = [(i, b['t'], 0) for i, b in enumerate(blocks) if b['k'] == 'h' or (
        len(b['t']) <= 40 and CHAPTER_RE.match(b['t']))]
    if not starts or starts[0][0] > 0:
        starts.insert(0, (0, '开始', 0))
    return finish(blocks, starts, {}, name, '')


def parse_mobi(path: Path, out_dir: Path) -> dict:
    raw = path.read_bytes()
    if len(raw) < 94 or raw[60:68] != b'BOOKMOBI':
        raise ValueError('不是有效的 MOBI / AZW3 文件。')
    count = int.from_bytes(raw[76:78], 'big')
    offset = int.from_bytes(raw[78:82], 'big')
    if count > 10000 or offset + 16 > len(raw):
        raise ValueError('MOBI 记录表无效。')
    if int.from_bytes(raw[offset + 12:offset + 14], 'big'):
        raise ValueError('这本书有 DRM 保护，无法读取。')
    vendor = Path(__file__).resolve().parents[2] / 'backend' / 'vendor'
    sys.path.insert(0, str(vendor))
    import contextlib
    import io
    import mobi  # type: ignore
    from mobi.mobi_header import MobiHeader  # type: ignore
    from mobi.mobi_sectioner import Sectionizer  # type: ignore
    with contextlib.redirect_stdout(io.StringIO()):
        header = MobiHeader(Sectionizer(str(path)), 0)
    if header.version < 8:
        # old MOBI: take the raw markup directly (the unpacker's dictionary code crashes on some files)
        html = header.getRawML().decode(header.codec, errors='replace')
        return _html_book(html, path.stem)
    tmp = None
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            tmp, output = mobi.extract(str(path))
        output = Path(output)
        if output.suffix.lower() == '.epub':
            return parse_epub(output, out_dir)
        return _html_book(output.read_text(encoding='utf-8-sig', errors='replace'), path.stem)
    finally:
        if tmp:
            shutil.rmtree(tmp, ignore_errors=True)


# ---------------------------------------------------------------- assemble
FRONT_WORDS = ('书名', '版权', '出版说明', '前言', '序', '译序', '译者', '目录', '献词', '题记', '内容简介',
               '简介', '作者简介', '导读', '推荐', '致谢', '引言', '图书在版', '封面', '扉页', '编者', '说明',
               'Front matter', 'Contents', 'CONTENTS', 'Preface', 'PREFACE', 'Introduction', 'Dedication', 'Copyright')
BACK_WORDS = ('后记', '附录', '书目', '译后记', '年表', '注释', '参考', '版权', '致谢', '跋')


def finish(blocks: list[dict], starts: list[tuple[int, str, int]], notes: dict, title: str, author: str) -> dict:
    # offsets
    o = 0
    for b in blocks:
        b.pop('cls', None)
        b.pop('ids', None)
        if not b.get('fn'):
            b.pop('fn', None)
        b['o'] = o
        o += u16(b['t']) + 1
    total = o
    # chapters: dedupe/sort starts; a chapter spans until the next start
    seen, clean_starts = set(), []
    for idx, t, d in sorted(starts, key=lambda s: s[0]):
        if clean_starts and (idx in seen or (idx - clean_starts[-1][0] <= 1 and d > clean_starts[-1][2])):
            # a title with nothing under it before the next heading: fold it into that heading
            prev = clean_starts[-1]
            clean_starts[-1] = (prev[0], prev[1] + ' · ' + t, max(prev[2], d))
            continue
        seen.add(idx)
        clean_starts.append((idx, t, d))
    if not clean_starts or clean_starts[0][0] != 0:
        clean_starts.insert(0, (0, '封面', 0))
    chapters = []
    parent_title = {}
    for n, (idx, t, d) in enumerate(clean_starts):
        end = clean_starts[n + 1][0] if n + 1 < len(clean_starts) else len(blocks)
        if end <= idx:
            continue
        parent_title[d] = t
        chapters.append({'title': t, 'depth': d, 'parent': parent_title.get(d - 1) if d else None,
                         'b0': idx, 'b1': end, 'o0': blocks[idx]['o'],
                         'o1': blocks[end - 1]['o'] + u16(blocks[end - 1]['t'])})
    classify(chapters, blocks)
    # footnote ids → short ids
    short = {}
    for b in blocks:
        for f in b.get('fn', []):
            if f[1] in notes:
                short.setdefault(f[1], f'n{len(short) + 1}')
                f[1] = short[f[1]]
            else:
                f[1] = None
        if 'fn' in b:
            b['fn'] = [f for f in b['fn'] if f[1]]
            if not b['fn']:
                del b['fn']
    notes = {short[k]: v for k, v in notes.items() if k in short}
    return {'title': title, 'author': author, 'len': total, 'blocks': blocks,
            'chapters': chapters, 'notes': notes}


SECTION_CHARS = 20_000


def split_long_chapters(book: dict, limit: int | None = None, target: int | None = None) -> dict:
    """Some web-novel dumps have no chapter headings at all: 3 million characters in one block.

    Such a chapter is cut into reading-sized sections at paragraph boundaries, so the table of
    contents, the reader (which loads a chapter at a time) and the end-of-chapter summaries all work.
    """
    latin = not is_cjk(book.get('lang'))
    target = target or (SECTION_CHARS * 3 if latin else SECTION_CHARS)
    limit = limit or target * 3
    name = 'Part {n}' if latin else '第 {n} 节'
    blocks, out, n = book['blocks'], [], 0
    for c in book['chapters']:
        if c.get('kind') != 'body' or c['o1'] - c['o0'] <= limit:
            out.append(c)
            continue
        start = c['b0']
        size = 0
        for bi in range(c['b0'], c['b1']):
            size += u16(blocks[bi]['t']) + 1
            last = bi == c['b1'] - 1
            if size >= target or last:
                n += 1
                out.append({**c, 'title': name.format(n=n), 'parent': c['title'] if c['title'] not in ('开始', '封面') else None,
                            'depth': c.get('depth', 0), 'b0': start, 'b1': bi + 1,
                            'o0': blocks[start]['o'], 'o1': blocks[bi]['o'] + u16(blocks[bi]['t'])})
                start, size = bi + 1, 0
    book['chapters'] = out
    book['sectioned'] = n > 0
    return book


def classify(chapters: list[dict], blocks: list[dict]):
    """Heuristic front/body/back split. The LLM may refine this later."""
    body_seen = False
    for c in chapters:
        t = c['title']
        size = c['o1'] - c['o0']
        front = any(w in t for w in FRONT_WORDS) or t in ('封面', '开始') and size < 400
        if not body_seen and (front or size < 300):
            c['kind'] = 'front'
        else:
            body_seen = True
            c['kind'] = 'body'
    # back matter: trailing chapters matching back words
    for c in reversed(chapters):
        if c['kind'] == 'body' and any(w in c['title'] for w in BACK_WORDS):
            c['kind'] = 'back'
        else:
            break


def parse_file(path: Path, out_dir: Path, name: str | None = None) -> dict:
    out_dir.mkdir(parents=True, exist_ok=True)
    ext = Path(name or path.name).suffix.lower()
    if ext == '.epub' or (ext == '' and zipfile.is_zipfile(path)):
        book = parse_epub(path, out_dir)
    elif ext in ('.mobi', '.azw3', '.azw'):
        book = parse_mobi(path, out_dir)
    elif ext in ('.txt', ''):
        book = parse_txt(path, out_dir)
    else:
        raise ValueError('支持 TXT、EPUB、MOBI、AZW3。')
    if not any(b['t'] for b in book['blocks']):
        raise ValueError('没有读到文字内容。')
    return split_long_chapters(book)


if __name__ == '__main__':
    src, out = Path(sys.argv[1]), Path(sys.argv[2])
    book = parse_file(src, out, sys.argv[3] if len(sys.argv) > 3 else None)
    (out / 'book.json').write_text(json.dumps(book, ensure_ascii=False))
    print(book['title'], book['author'], book['len'], len(book['blocks']), 'blocks', len(book['chapters']), 'chapters', len(book['notes']), 'notes')
    for c in book['chapters']:
        print(c['kind'], c['depth'], c['title'], c['o1'] - c['o0'])
