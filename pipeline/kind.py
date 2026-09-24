"""What kind of book this is, and what that changes.

The spoiler-free machinery (every record carries the position it becomes visible, the reader folds
to the current page) has nothing to do with novels. What differs between kinds of books is which
entities are worth a card and whether knowledge carries across the whole file:

  novel       one story, characters accumulate            → people, relations, events
  biography   real people, same shape as a novel          → people, relations, events
  collection  several separate works in one file          → same, but each work starts fresh
  nonfiction  ideas rather than characters                → terms and concepts (people too, if any)
  reference   dictionary, manual, no reading order        → accumulating cards make little sense

Detected once per book by the judge (title, table of contents, opening lines); the reader can
override it, because only they know what they are reading.
"""
from __future__ import annotations

import os
import re

from .llm import jev

KINDS = {
    'novel': ('小说', 'novel', 'A work of narrative fiction with characters and a plot: a novel, a web novel, a story.'),
    'biography': ('传记 / 纪实', 'biography or history',
                  'Narrative non-fiction about real people and events: a biography, memoir, history or reportage.'),
    'collection': ('合集', 'collection',
                   'Several separate works in one file: a collected works, an anthology, a book of short stories or essays, '
                   'where characters of one piece do not carry over to the next.'),
    'nonfiction': ('非虚构 / 知识类', 'non-fiction',
                   'A book of ideas rather than a story: textbook, science, technology, philosophy, self-help, business — '
                   'read in order, but what accumulates is concepts and terms, not characters.'),
    'reference': ('工具书', 'reference',
                  'A dictionary, manual, cookbook, catalogue or standard: looked things up in, not read from start to end.'),
}
NARRATIVE = ('novel', 'biography', 'collection')


def detect(book: dict) -> tuple[str, float]:
    """(kind, confidence). Falls back to 'novel' if the judge cannot be reached."""
    if os.environ.get('DETECT_KIND', '1') != '1':
        return 'novel', 0.0
    chapters = book.get('chapters') or []
    toc = '、'.join((c.get('title') or '')[:24] for c in chapters[:40])
    head = ' '.join(b['t'] for b in book.get('blocks', [])[:40] if b.get('k') != 'img')[:1500]
    state = {'title': book.get('title', ''), 'author': book.get('author', ''),
             'table_of_contents': toc, 'opening_lines': head,
             'length_in_characters': book.get('len', 0), 'number_of_chapters': len(chapters)}
    q = {'k': {'type': 'choice',
               'instructions': 'What kind of book is this? Judge from its title, table of contents and opening lines.',
               'criteria': {k: v[2] for k, v in KINDS.items()}}}
    try:
        a = (jev(state, q) or {}).get('k') or {}
    except Exception:
        return 'novel', 0.0
    choice = a.get('choice')
    p = (a.get('probabilities') or {}).get(choice, 0)
    return (choice, round(p, 3)) if choice in KINDS else ('novel', 0.0)


CN_NUM = dict(zip('零一二三四五六七八九', range(10)))
ORDINAL = re.compile(r'^\s*(?:第\s*([0-9]+|[零一二三四五六七八九十百千]+)\s*[部章回卷节篇集]|'
                     r'(?:chapter|part|book|volume)\s+([0-9]+|[ivxlcdm]+)|([0-9]{1,3})[.、])', re.I)
OPENER = re.compile(r'^\s*(楔子|序章|序幕|序言|引子|前言|自序|开篇|prologue|preface|foreword)', re.I)


def _cn(s: str) -> int:
    if s.isdigit():
        return int(s)
    v = cur = 0
    for ch in s:
        if ch in CN_NUM:
            cur = CN_NUM[ch]
        elif ch == '十':
            v, cur = v + (cur or 1) * 10, 0
        elif ch == '百':
            v, cur = v + (cur or 1) * 100, 0
        elif ch == '千':
            v, cur = v + (cur or 1) * 1000, 0
    return v + cur


def ordinal(title: str) -> int | None:
    """The chapter number a title carries, in any of the usual shapes."""
    m = ORDINAL.match(title or '')
    if not m:
        return None
    raw = m.group(1) or m.group(2) or m.group(3) or ''
    if raw.isdigit():
        return int(raw)
    if re.fullmatch(r'[ivxlcdm]+', raw, re.I):
        vals = {'i': 1, 'v': 5, 'x': 10, 'l': 50, 'c': 100, 'd': 500, 'm': 1000}
        raw = raw.lower()
        return sum(-vals[a] if i + 1 < len(raw) and vals[a] < vals[raw[i + 1]] else vals[a] for i, a in enumerate(raw))
    return _cn(raw) or None


def works(book: dict, min_chars: int = 20_000) -> list[tuple[int, int]]:
    """For a collection: the (start, end) of each separate work, so one story's cast never leaks
    into the next.

    Two general signals, in order: a table of contents with real parents (each top entry is a work),
    or — the usual case in concatenated files — the chapter numbering starting over ("第十二部" then
    "第一部" again), optionally announced by a 楔子/prologue.
    """
    body = [c for c in book.get('chapters', []) if c.get('kind') == 'body']
    if not body:
        return []
    tops = [c for c in body if not c.get('parent')]
    if any(c.get('parent') for c in body) and len(tops) > 1:
        spans = [(c['o0'], c['o1']) for c in tops if c['o1'] - c['o0'] >= min_chars]
    else:
        starts, prev = [0], None
        for i, c in enumerate(body):
            n = ordinal(c['title'])
            opener = bool(OPENER.match(c['title'] or ''))
            if i and (opener or (n is not None and prev is not None and n <= prev and n <= 2)):
                starts.append(i)
            if n is not None:
                prev = n
            elif opener:
                prev = 0
        spans = []
        for k, i in enumerate(starts):
            j = starts[k + 1] if k + 1 < len(starts) else len(body)
            if body[j - 1]['o1'] - body[i]['o0'] >= min_chars:
                spans.append((body[i]['o0'], body[j - 1]['o1']))
    if len(spans) < 2:
        return []
    merged = [list(spans[0])]
    for s, e in spans[1:]:
        if s <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], e)
        else:
            merged.append([s, e])
    return [tuple(x) for x in merged]
