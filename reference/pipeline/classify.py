"""Decide which chapters are story text (body) versus front/back matter.

Front matter (prefaces, translator notes, blurbs) often summarises the whole plot, so it
must never feed the knowledge graph.
"""
from __future__ import annotations

import os

from .judge import BATCH
from .llm import chat_json, jev

PROMPT = """下面是一本书的目录，每行是：编号｜章节标题｜字数｜开头几句。
请判断每一章属于哪一类：
- front：正文之前的辅文（书名页、版权页、出版说明、作者介绍、前言、序、译序、导读、目录、献词等）
- body：小说正文（包括“第一部”这类分部标题页、楔子、引子、尾声、番外）
- back：正文之后的辅文（后记、译后记、附录、年表、丛书书目、广告等）

注意：前言、序、导读通常会概述全书情节，一定要标为 front。
只输出 JSON：{"kinds": {"编号": "front|body|back", ...}}

书名：《{title}》

{rows}"""


def _contiguous(kinds: list[str]) -> list[str]:
    """The story is one run: anything between the first and last body chapter is body."""
    idx = [i for i, k in enumerate(kinds) if k == 'body']
    if idx:
        for i in range(idx[0], idx[-1] + 1):
            kinds[i] = 'body'
    return kinds


CRITERIA = {
    'front': 'Front matter that comes before the story: title page, copyright, publisher\'s note, about the author, preface, foreword, introduction, translator\'s note, table of contents, dedication. Prefaces and introductions usually summarise the whole plot.',
    'body': 'The story itself, including part titles ("Part One"), prologue, epilogue and extra chapters written as story.',
    'back': 'Matter after the story: afterword, appendix, chronology, notes, catalogue of other books, advertisements.',
}


def classify_by_judge(book: dict) -> list[str] | None:
    """The judge picks front/body/back for each chapter — a pure multiple choice, so no LLM needed."""
    rows = []
    for i, c in enumerate(book['chapters']):
        head = ''.join(b['t'] for b in book['blocks'][c['b0']:c['b1']] if b['k'] != 'img')[:120]
        rows.append((i, f"{(c.get('parent') + ' · ') if c.get('parent') else ''}{c['title']}", c['o1'] - c['o0'], head))
    out: dict[int, str] = {}
    try:
        for k0 in range(0, len(rows), BATCH):
            chunk = rows[k0:k0 + BATCH]
            state = {'book_title': book.get('title', ''),
                     'chapters': {f'c{i}': {'title': t, 'length': n, 'begins': head} for i, t, n, head in chunk}}
            qs = {f'q{i}': {'type': 'choice', 'instructions': f'Which part of the book is chapters.c{i} ("{t}")?',
                            'criteria': CRITERIA} for i, t, _, _ in chunk}
            ans = jev(state, qs)
            for i, _, _, _ in chunk:
                a = ans.get(f'q{i}') or {}
                if a.get('choice') in CRITERIA:
                    out[i] = a['choice']
    except Exception:
        return None
    return [out.get(i, 'body') for i in range(len(rows))] if len(out) == len(rows) else None


def classify_chapters(book: dict, model: str | None = None) -> list[str]:
    model = model or os.environ.get('CLASSIFY_MODEL', 'deepseek-flash+nothink')
    if os.environ.get('CLASSIFY_BY_JUDGE', '1') == '1':
        kinds = classify_by_judge(book)
        if kinds:
            return kinds
    rows = []
    for i, c in enumerate(book['chapters']):
        head = ''.join(b['t'] for b in book['blocks'][c['b0']:c['b1']] if b['k'] != 'img')[:60]
        rows.append(f"{i}｜{(c.get('parent') + ' · ') if c.get('parent') else ''}{c['title']}｜{c['o1'] - c['o0']}｜{head}")
    try:
        data, _ = chat_json(model, [{'role': 'user', 'content': PROMPT.replace('{title}', book['title']).replace('{rows}', '\n'.join(rows))}],
                            max_tokens=4000, temperature=0)
        kinds = data.get('kinds') or {}
        out = []
        for i, c in enumerate(book['chapters']):
            k = kinds.get(str(i)) or c.get('kind') or 'body'
            out.append(k if k in ('front', 'body', 'back') else 'body')
        # Collections may contain front/back matter between separate works.
        return out
    except Exception:
        return [c.get('kind') or 'body' for c in book['chapters']]
