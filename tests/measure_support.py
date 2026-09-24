"""What would happen if every record were checked against its own passage?

usage: python3 tests/measure_support.py BOOK_DIR [--segs 40]

Record-only measurement on a dev book: rebuilds each segment's events/attrs/rels with the names
that segment uses, asks JEV whether the passage supports them, and reports what would be dropped.
"""
import json
import random
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pipeline.extract import seg_text, segments  # noqa: E402
from pipeline.judge import verify_records  # noqa: E402


def main():
    d = Path(sys.argv[1])
    n_segs = int(sys.argv[sys.argv.index('--segs') + 1]) if '--segs' in sys.argv else 40
    book = json.loads((d / 'book.json').read_text())
    segs = segments(book, [i for i, c in enumerate(book['chapters']) if c.get('kind') == 'body'])
    files = sorted((d / 'work' / 'local').glob('*.json'))
    random.seed(11)
    files = sorted(random.sample(files, min(n_segs, len(files))))
    rows, by_kind = [], Counter()
    for f in files:
        rec = json.loads(f.read_text())
        i = rec['seg']
        if i >= len(segs):
            continue
        data = rec['data']
        name = {str(p.get('id')): (p.get('name') or '').lstrip('*') for p in data.get('people', [])}
        items = {}
        for j, e in enumerate(data.get('events', [])):
            if e.get('text'):
                items[f'e{j}'] = ('event', e['text'])
        for j, a in enumerate(data.get('facts', [])):
            if a.get('value'):
                items[f'a{j}'] = ('attr', f"{name.get(str(a.get('who')), '?')}｜{a.get('key')}：{a['value']}")
        for j, r in enumerate(data.get('rels', [])):
            if r.get('b_is'):
                items[f'r{j}'] = ('rel', f"{name.get(str(r.get('b')), '?')} 是 {name.get(str(r.get('a')), '?')} 的{r['b_is']}")
        if not items:
            continue
        got = verify_records(seg_text(book, segs[i]), items)
        for k, v in got.items():
            kind, claim = items[k]
            by_kind[kind] += 1
            rows.append((v['p'], v.get('choice'), kind, i, claim))
    print(f'# 逐条核对（{d.name}，{len(files)} 段，{len(rows)} 条记录）\n')
    print('| 类型 | 条数 | 支持≥0.5 | 支持<0.5 | 判为“原文没有” | 判为“与原文矛盾” |\n|---|---|---|---|---|---|')
    for kind in ('event', 'attr', 'rel'):
        sub = [r for r in rows if r[2] == kind]
        if not sub:
            continue
        hi = sum(1 for r in sub if r[0] >= 0.5)
        print(f"| {kind} | {len(sub)} | {hi}（{hi / len(sub):.0%}） | {len(sub) - hi} | "
              f"{sum(1 for r in sub if r[1] == 'not_in_passage')} | {sum(1 for r in sub if r[1] == 'contradicted')} |")
    for thr in (0.3, 0.5):
        print(f'- 阈值 {thr}：会丢掉 {sum(1 for r in rows if r[0] < thr)} 条（{sum(1 for r in rows if r[0] < thr) / len(rows):.0%}）')
    print('\n最低分的 20 条（用来判断该不该丢）：')
    for p, choice, kind, i, claim in sorted(rows)[:20]:
        print(f'- {p} {choice} [{kind} 第{i}段] {claim[:100]}')
    json.dump([{'p': r[0], 'choice': r[1], 'kind': r[2], 'seg': r[3], 'claim': r[4]} for r in rows],
              open(f'reports/support-{d.name}.json', 'w'), ensure_ascii=False, indent=1)


if __name__ == '__main__':
    main()
