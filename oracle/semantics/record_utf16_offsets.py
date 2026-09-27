#!/usr/bin/env python3
"""Freeze Python 1.7.5's mixed-unit context window around supplementary text."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from types import SimpleNamespace

from pipeline.run import Runner


OUTPUT = Path(__file__).with_name('utf16_offsets.json')
CASES = (
    ('bmp-control', '甲乙丙丁', 1, 2),
    ('emoji-at-start', '😀ABC', 2, 2),
    ('astral-han-at-start', '𠮷甲乙丙', 2, 2),
    ('emoji-after-ascii', 'A😀BC', 3, 2),
)


def render() -> str:
    rows = []
    for ident, text, position, width in CASES:
        block = {'o': 0, 't': text}
        frozen = Runner._text_around(SimpleNamespace(book={'blocks': [block]}), position, width)
        codepoint_position = len(text.encode('utf-16-le')[:position * 2].decode('utf-16-le'))
        centered = text[max(0, codepoint_position - width // 2):codepoint_position + width // 2]
        rows.append({'id': ident, 'text': text, 'position_utf16': position,
                     'width_codepoints': width, 'frozen_175': frozen,
                     'codepoint_centered': centered})
    return json.dumps({'schema': 1, 'cases': rows}, ensure_ascii=False, indent=2) + '\n'


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    expected = render()
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text(encoding='utf-8') != expected:
            raise SystemExit('stale UTF-16 offset oracle')
    else:
        OUTPUT.write_text(expected, encoding='utf-8')
