"""Offline Python reference for chapter and book-kind routing.

Capture exact requests, including Unicode code-point truncation, batches,
fallbacks and missing judge results. No network or credentials are used.
"""
from __future__ import annotations

import copy
import json
import os
from pathlib import Path
from unittest.mock import patch

from pipeline import classify, kind

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'oracle/goldens/special/book-policy.json'


def book(titles):
    chapters, blocks = [], []
    offset = 0
    for i, title in enumerate(titles):
        text = ('𠮷🙂前言正文' if i == 0 else 'Chapter prose ') * 40
        end = offset + len(text.encode('utf-16-le')) // 2
        chapters.append(dict(title=title, kind='front' if i == 0 else 'body',
                             b0=i, b1=i + 1, o0=offset, o1=end,
                             **({'parent': '第一部'} if i == 1 else {})))
        blocks.append(dict(k='p', t=text, o=offset))
        offset = end + 1
    return dict(title='𠮷の物語', author='Test Author', len=offset,
                chapters=chapters, blocks=blocks)


def capture(operation, source, *, replies=None, chat=None, env=None):
    requests = []
    answers = iter(replies or [])

    def judge(state, questions):
        requests.append(dict(type='judge', state=copy.deepcopy(state),
                             questions=copy.deepcopy(questions)))
        value = next(answers)
        if value == '__error__':
            raise RuntimeError('offline judge failure')
        return value

    def generation(model, messages, **kwargs):
        requests.append(dict(type='chat', model=model, messages=messages, kwargs=kwargs))
        if chat == '__error__':
            raise RuntimeError('offline chat failure')
        return chat, {}

    environment = {'DETECT_KIND': '1', 'CLASSIFY_BY_JUDGE': '1', **(env or {})}
    with patch.dict(os.environ, environment, clear=True), \
         patch.object(kind, 'jev', judge), patch.object(classify, 'jev', judge), \
         patch.object(classify, 'chat_json', generation):
        result = {'detect': kind.detect, 'classify': classify.classify_chapters,
                  'judge': classify.classify_by_judge}[operation](copy.deepcopy(source))
    return dict(operation=operation, book=source, replies=replies or [], chat=chat,
                env=environment, expected=result, requests=requests)


def build():
    short = book(['序言', 'Chapter I', 'Chapter II', '附录'])
    rows = [
        capture('detect', short, replies=[{'k': {'choice': 'collection', 'probabilities': {'collection': .8125}}}]),
        capture('detect', short, replies=['__error__']),
        capture('detect', short, replies=[{'k': {'choice': 'unknown', 'probabilities': {'unknown': 1.0}}}]),
        capture('detect', short, env={'DETECT_KIND': '0'}),
        capture('judge', short, replies=[{'q0': {'choice': 'front'}, 'q1': {'choice': 'body'},
                                         'q2': {'choice': 'body'}, 'q3': {'choice': 'back'}}]),
        capture('classify', short, replies=[{'q0': {'choice': 'front'}}],
                chat={'kinds': {'1': 'body', '2': 'invalid', '3': 'back'}}),
        capture('classify', short, replies=['__error__'], chat='__error__'),
        capture('classify', short, env={'CLASSIFY_BY_JUDGE': '0', 'CLASSIFY_MODEL': 'test-model'},
                chat={'kinds': {'0': 'front', '1': 'body', '2': 'front', '3': 'body'}}),
        capture('judge', book([f'Chapter {i}' for i in range(classify.BATCH + 2)]),
                replies=[{f'q{i}': {'choice': 'body'} for i in range(classify.BATCH)},
                         {f'q{i}': {'choice': 'body'} for i in range(classify.BATCH, classify.BATCH + 2)}]),
    ]
    return {'schema': 1, 'source': ['pipeline/classify.py', 'pipeline/kind.py'], 'cases': rows,
            'ordinals': [[t, kind.ordinal(t)] for t in [None, '', 'Chapter IX', '第十二章', '第二百三十部',
                         '第零章', '  Volume xiv', '123、foo', '序言', '𠮷第一章', 'Part IV', '12. Foo']],
            'works': [dict(book=b, min_chars=n, expected=kind.works(b, n)) for b, n in [
                (short, 0), (book(['Chapter I', 'Chapter II', '序章', 'Chapter I', 'Chapter II']), 0),
                (book(['Chapter I', 'Chapter II', '序章', 'Chapter I', 'Chapter II']), 20000),
            ]]}


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    raw = json.dumps(build(), ensure_ascii=False, indent=2) + '\n'
    if args.check:
        assert OUTPUT.read_text() == raw, 'book-policy oracle differs from Python'
        print('章节与书籍类型参考结果一致')
    else:
        OUTPUT.write_text(raw)
        print('章节与书籍类型参考结果已录制（离线）')
