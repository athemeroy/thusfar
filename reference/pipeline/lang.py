"""Book language and card language.

The pipeline was built on Chinese books; for Western books the model still gets the same
(Chinese) instructions plus a language note, quotes stay verbatim in the original, and every
length limit in characters is scaled (an English word is ~5 characters, a Chinese word ~1.5).

CARD_LANG=zh on an English book gives Chinese notes on an English text (names stay as printed).
"""
from __future__ import annotations

import os
import re


def book_lang(book: dict) -> str:
    if book.get('lang'):
        return book['lang']
    sample = ''.join(b['t'] for b in book.get('blocks', [])[:400])[:40000]
    latin = len(re.findall(r'[A-Za-z]', sample))
    cjk = len(re.findall(r'[㐀-鿿]', sample))
    return 'en' if latin > 20 * max(1, cjk) else 'zh'


def card_lang(book: dict) -> str:
    return os.environ.get('CARD_LANG') or book.get('card_lang') or book_lang(book)


def scale(book: dict) -> int:
    """Multiplier for character limits on generated text."""
    return 3 if card_lang(book) == 'en' else 1


def seg_chars(book: dict) -> int:
    # about the same number of tokens per segment in both scripts
    return 9000 if book_lang(book) == 'en' else 3200


def local_note(book: dict) -> str:
    """Appended to the phase-1 instructions."""
    if book_lang(book) != 'en':
        return ''
    out = ('\n\n【语言】这本书是英文原著。quote 必须逐字复制英文原文（5～25 个英文单词）；names 按原文写法'
           '（如 Mr. Utterson、Dr. Jekyll、Poole），泛称和称谓（the lawyer、the maid、Sir、the old gentleman、his friend）前加 *。')
    if card_lang(book) == 'en':
        out += ('所有要写的文字（role、text、value、desc、b_is、a_is、why）一律用英文写；字数要求按英文单词计。'
                'facts 的 key 用：identity|occupation|residence|age|appearance|personality|situation|alive。')
    else:
        out += '所有要写的文字用中文写，人名保留原文拼写。'
    return out


def out_note(book: dict) -> str:
    """Appended to recap / story-so-far / biography prompts."""
    if card_lang(book) == 'en':
        return '\n\n【输出语言】用英文写，字数要求按英文单词计（一句话身份 ≤12 个词）。'
    if book_lang(book) == 'en':
        return '\n\n【输出语言】用中文写，人名保留原文拼写。'
    return ''


LIFE_KEYS = ('生死', '婚恋', 'alive', 'life', 'death', 'marriage', 'married')
