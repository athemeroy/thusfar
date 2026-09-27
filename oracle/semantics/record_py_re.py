"""Record Python 3.11 regex behaviour for the runtime Dart translator `pyRe`.

Every static pattern in docs/port/REGEX.json is run over its own examples and a
shared probe list. Spans are recorded in UTF-16 code units, the unit Dart uses.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROBES = [
    '', ' ', '\n', 'a\n', '阿Q', 'Mr. Smith', 'the old man', '赵太爷', '第一章 开端', 'Chapter IV\n',
    'CHAPTER 12. The End', '  序章  ', 'x -作者 : y ', '书名_作者：某某.com', 'example.com',
    '“你好”，他说。', 'Hello, world! Hello again.', "Jekyll's friend and family", '𠮷野家 🙂 emoji',
    'tab\tsep　full nbsp\x1cfs\x85nel', 'line1\r\nline2\rline3 x', '12.3、四', '1998年3月',
    '<recap>前情</recap>', '<saga>长篇', '```json\n{"a": 1}\n```', '{"k": [1, 2]}', 'ÉCOLE élève naïve',
    'Ⅳ ⅳ ２３ ٣', 'a_b-c.d', '[注1] 脚注', 'MR. HYDE', 'dies died dying dead', '死了 嫁人', "'s", 'x' * 3,
    '—— 破折号 …… 省略', '(括号) （全角）', 'AbCdEf', 'end.\n', '\n\nmulti\n\nline\n',
]


def u16(text: str, index: int) -> int:
    return len(text[:index].encode('utf-16-le')) // 2


def flags_of(names):
    value = 0
    for name in names:
        value |= getattr(re, name)
    return value


def main() -> None:
    data = json.loads((ROOT / 'docs/port/REGEX.json').read_text(encoding='utf-8'))
    seen = set()
    out = []
    for row in data['calls']:
        variants = []
        if row.get('examples') is not None and row.get('pattern') is not None:
            variants.append((row['pattern'], row['flags'], row['examples']))
        for detail in (row.get('variant_examples') or {}).values():
            variants.append((detail['pattern'], detail.get('flags', row['flags']), detail['examples']))
        for pattern, flag_names, examples in variants:
            key = (pattern, tuple(flag_names))
            if key in seen:
                continue
            seen.add(key)
            compiled = re.compile(pattern, flags_of(flag_names))
            probes = [examples['positive'], examples['negative']] + PROBES
            cases = []
            for text in dict.fromkeys(probes):
                matches = [[u16(text, m.start()), u16(text, m.end()),
                            [None if g is None else g for g in m.groups()]]
                           for m in compiled.finditer(text)]
                head = compiled.match(text)
                full = compiled.fullmatch(text)
                cases.append({'text': text, 'finditer': matches,
                              'match': None if head is None else [u16(text, head.start()), u16(text, head.end())],
                              'fullmatch': full is not None,
                              'split': compiled.split(text)})
            out.append({'pattern': pattern, 'flags': flag_names, 'cases': cases})
    target = ROOT / 'oracle/semantics/py_re.jsonl'
    target.write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in out), encoding='utf-8')
    print(f'{len(out)} patterns, {sum(len(r["cases"]) for r in out)} cases', file=sys.stderr)


if __name__ == '__main__':
    main()
