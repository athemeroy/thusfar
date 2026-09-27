"""Freeze the dynamic surface regex built by Python KG.plan for Dart comparison.

The AST audit cannot enumerate names extracted by a model. These synthetic
inputs drive the real production helper, capture its compiled Python pattern,
and record every match in both code-point and UTF-16 coordinates. Dart receives
an explicit equivalent pattern with JavaScript-safe literal escaping. This is
an A0 semantic fixture, not a Dart port of KG.plan.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from unittest.mock import patch

from oracle.record.common import require_reference_runtime
from pipeline import kg as kg_module
from pipeline.parse import u16


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / 'oracle/semantics/surface_regex.jsonl'
JS_META = frozenset(r'\^$.*+?()[]{}|')

CASES = [
    {
        'id': 'cjk_astral_generic',
        'texts': ['😀尼尔遇见黑月。', '尼尔与太太交谈。'],
        'new_people': [('N1', '尼尔'), ('N2', '黑月'), ('N3', '太太')],
        'surfaces': {'N1': ['尼尔'], 'N2': ['黑月'], 'N3': ['*太太']},
    },
    {
        'id': 'latin_ascii_letter_boundaries',
        'texts': ["😀Ann met Anne. Ann's note names XAnn and Ann2."],
        'new_people': [('N1', 'Ann'), ('N2', 'Anne')],
        'surfaces': {'N1': ['Ann'], 'N2': ['Anne']},
    },
    {
        'id': 'overlap_longest_first',
        'texts': ['李四郎、李四和李四郎。'],
        'new_people': [('N1', '李四'), ('N2', '李四郎'), ('N3', '另一位李四')],
        'surfaces': {'N1': ['李四'], 'N2': ['李四郎'], 'N3': ['李四']},
    },
    {
        'id': 'escaped_punctuation_and_space',
        'texts': ['Dr. Q met A+B and 王(叔); Drx Q, AB, 王叔.'],
        'new_people': [('N1', 'Dr. Q'), ('N2', 'A+B'), ('N3', '王(叔)')],
        'surfaces': {'N1': ['Dr. Q'], 'N2': ['A+B'], 'N3': ['王(叔)']},
    },
    {
        'id': 'empty_surfaces',
        'texts': ['没有可匹配的人名。'],
        'new_people': [],
        'surfaces': {},
    },
    {
        'id': 'all_surfaces_filtered',
        'texts': ['他和X。'],
        'new_people': [('N1', '他')],
        'surfaces': {'N1': ['他', 'X', '*  ']},
    },
]


def blocks_of(texts: list[str]) -> list[dict]:
    blocks = []
    offset = 0
    for text in texts:
        blocks.append({'k': 'p', 'o': offset, 't': text})
        offset += u16(text) + 1  # one source newline between blocks
    return blocks


def dart_literal(text: str) -> str:
    """Escape only RegExp constructor metacharacters; JS /u rejects `\\ `."""
    return ''.join('\\' + ch if ch in JS_META else ch for ch in text)


def dart_pattern(surfaces: dict) -> str | None:
    if not surfaces:
        return None
    return '|'.join(
        (r'(?<![A-Za-z])' + dart_literal(name) + r'(?![A-Za-z])')
        if re.match(r'[A-Za-z]', name[-1:] or ' ') else dart_literal(name)
        for name in sorted(surfaces, key=len, reverse=True)
    )


def record() -> list[dict]:
    require_reference_runtime()
    output = []
    for case in CASES:
        blocks = blocks_of(case['texts'])
        book = {'lang': 'zh', 'blocks': blocks,
                'len': blocks[-1]['o'] + u16(blocks[-1]['t'])}
        seg = {'blocks': list(range(len(blocks)))}
        data = {'new_people': [{'ref': ref, 'name': name}
                               for ref, name in case['new_people']],
                'surfaces': case['surfaces']}
        compiled = []
        original_compile = re.compile

        def capture(pattern: str, *args, **kwargs):
            compiled.append(pattern)
            return original_compile(pattern, *args, **kwargs)

        with patch.object(kg_module.re, 'compile', side_effect=capture):
            plan = kg_module.KG(book).plan(seg, data)
        if len(compiled) != bool(plan['surfaces']):
            raise RuntimeError(f"{case['id']}: production pattern capture count changed")
        python_pattern = compiled[0] if compiled else None
        translated = dart_pattern(plan['surfaces'])
        block_matches = []
        expected_occurrences = []
        regex = original_compile(python_pattern) if python_pattern is not None else None
        for bi in seg['blocks']:
            block = blocks[bi]
            matches = []
            for match in regex.finditer(block['t']) if regex else ():
                start, end = match.span()
                text = match.group(0)
                matches.append({
                    'text': text, 'groups': list(match.groups()),
                    'named': match.groupdict(),
                    'span_cp': [start, end],
                    'span_utf16': [u16(block['t'][:start]), u16(block['t'][:end])],
                })
                surface = plan['surfaces'][text]
                global_start = block['o'] + u16(block['t'][:start])
                expected_occurrences.append({
                    'key': str(global_start), 'bi': bi, 'i': start, 'j': end,
                    's': global_start, 'e': global_start + u16(text),
                    'surface': text, 'ids': surface['ids'],
                    'generic': surface['generic'],
                    'ambiguous': len(surface['ids']) > 1 or surface['generic'],
                })
            block_matches.append({'bi': bi, 'text': block['t'], 'matches': matches})
        if expected_occurrences != plan['occs']:
            raise RuntimeError(f"{case['id']}: captured regex differs from KG.plan occurrences")
        output.append({
            'schema': 1, 'id': case['id'], 'source': 'pipeline.kg.KG.plan',
            'book': book, 'segment': seg, 'data': data,
            'filtered_surfaces': plan['surfaces'],
            'python_pattern': python_pattern, 'dart_pattern': translated,
            'blocks': block_matches, 'plan_occurrences': plan['occs'],
        })
    return output


def render() -> str:
    return ''.join(json.dumps(row, ensure_ascii=False, sort_keys=True,
                              separators=(',', ':')) + '\n' for row in record())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--write', action='store_true')
    mode.add_argument('--check', action='store_true')
    args = parser.parse_args()
    expected = render()
    if args.write:
        FIXTURE.write_text(expected, encoding='utf-8')
    elif FIXTURE.read_text(encoding='utf-8') != expected:
        raise RuntimeError('surface regex fixture differs from Python 3.11 KG.plan')
    print(f'verified {len(CASES)} KG surface regex cases against Python 3.11')


if __name__ == '__main__':
    main()
