"""Phase-1 benchmark: speed, token use, JSON validity and output size of several models on the same segments.

usage: LLM_KEY_MAP=deepseek-=DEEPSEEK_KEY python3 scripts/model_bench.py OUT.md BOOK_DIR:SEG,SEG ... -- MODEL ...

Prices are the gateway's list prices in CNY per million tokens (input, output); edit PRICES when they change.
Only dev books should be used here (the benchmark looks at individual outputs).
"""
import json
import re
import statistics
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pipeline.extract import segments, seg_text  # noqa: E402
from pipeline.local import extract_local  # noqa: E402

from pipeline.models import PRICES as MODEL_PRICES  # noqa: E402

PRICES = {m: v['price'] for m, v in MODEL_PRICES.items()}


def norm(s: str) -> str:
    return re.sub(r'\s+', '', s or '')


def run_one(model, book, segs, i):
    seg = segs[i]
    prev = segs[i - 1] if i else None
    text = norm(seg_text(book, seg))
    t0 = time.time()
    try:
        data, usage = extract_local(book, seg, prev, model=model)
    except Exception as e:  # noqa: BLE001 - record failures as results
        return {'model': model, 'seg': i, 'ok': False, 'err': f'{type(e).__name__}: {str(e)[:120]}', 'secs': time.time() - t0}
    quotes = [x.get('quote', '') for k in ('people', 'events', 'facts', 'rels') for x in data[k]]
    anchored = sum(1 for q in quotes if q and norm(q) in text)
    return {'model': model, 'seg': i, 'ok': True, 'secs': time.time() - t0, 'ttft': usage.get('_ttft'),
            'in': usage.get('prompt_tokens') or 0, 'out': usage.get('completion_tokens') or 0,
            'people': len(data['people']), 'events': len(data['events']), 'rels': len(data['rels']),
            'facts': len(data['facts']), 'quotes': len(quotes), 'anchored': anchored, 'chars': seg['chars']}


def main():
    args = sys.argv[1:]
    out = Path(args.pop(0))
    cut = args.index('--')
    targets, models = args[:cut], args[cut + 1:]
    jobs = []
    for t in targets:
        d, idx = t.split(':')
        book = json.loads((Path(d) / 'book.json').read_text())
        segs = segments(book, [i for i, c in enumerate(book['chapters']) if c.get('kind', 'body') == 'body'])
        for i in map(int, idx.split(',')):
            for m in models:
                jobs.append((m, book, segs, i, Path(d).name))
    with ThreadPoolExecutor(24) as ex:
        results = list(ex.map(lambda j: dict(run_one(*j[:4]), book=j[4]), jobs))
    (out.with_suffix('.json')).write_text(json.dumps(results, ensure_ascii=False, indent=1))
    lines = [f'# 阶段一模型对比（{time.strftime("%Y-%m-%d %H:%M")}）', '',
             f'段落：{", ".join(targets)}（同一提示词、同一段落、同时发出）', '',
             '| 模型 | 成功 | 每段耗时 中位/最长 | 首字 中位 | 每段 入/出 token | 每万字费用（标价） | 人物/事件/关系/档案（每段） | 引文逐字命中 |',
             '|---|---|---|---|---|---|---|---|']
    for m in models:
        rs = [r for r in results if r['model'] == m]
        ok = [r for r in rs if r['ok']]
        if not ok:
            lines.append(f'| {m} | 0/{len(rs)} | — | — | — | — | — | — |')
            continue
        chars = sum(r['chars'] for r in ok)
        tin, tout = sum(r['in'] for r in ok), sum(r['out'] for r in ok)
        pi, po = PRICES.get(m.split('+')[0], (0, 0))
        cost = (tin * pi + tout * po) / 1e6 / chars * 1e4
        avg = lambda k: sum(r[k] for r in ok) / len(ok)  # noqa: E731
        q = sum(r['quotes'] for r in ok)
        lines.append(
            f"| {m} | {len(ok)}/{len(rs)} | {statistics.median(r['secs'] for r in ok):.0f}s / {max(r['secs'] for r in ok):.0f}s"
            f" | {statistics.median(r['ttft'] or 0 for r in ok):.1f}s | {tin / len(ok):.0f} / {tout / len(ok):.0f}"
            f" | ¥{cost:.3f} | {avg('people'):.1f} / {avg('events'):.1f} / {avg('rels'):.1f} / {avg('facts'):.1f}"
            f" | {sum(r['anchored'] for r in ok) / max(1, q):.0%} |")
    errs = [r for r in results if not r['ok']]
    if errs:
        lines += ['', '失败：'] + [f"- {r['model']} {r['book']}#{r['seg']}: {r['err']}" for r in errs]
    out.write_text('\n'.join(lines) + '\n')
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
