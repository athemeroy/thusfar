"""Can an ordinary chat model take JEV's seat?

usage: python3 tests/judge_agreement.py BOOK_DIR [BOOK_DIR ...] [--n 60] [--models a,b]

Rebuilds real questions from stored segment records (critical facts: "is this death/marriage
narrated as fact?", and alias checks: "is 「老余」 used for 雷泰 in this passage?"), asks JEV and
each chat model the same question, and reports how often they agree and how far the probabilities
are apart. Dev books only — it reads individual records.
"""
import json
import random
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pipeline.extract import seg_text, segments  # noqa: E402
from pipeline.judge import CRITICAL  # noqa: E402
from pipeline.llm import jev, llm_judge  # noqa: E402

CRIT = {'fact': 'The passage narrates it as something that actually happened in the story.',
        'not_real': 'Only a rumour, misreport, suspicion, fear, dream, vision, prophecy, joke, curse, threat, plan, proposal or wish — the passage does not establish that it actually happened.',
        'unsupported': 'The passage does not say this at all, or says the opposite.'}


def build(book_dirs, n):
    out = []
    for d in map(Path, book_dirs):
        book = json.loads((d / 'book.json').read_text())
        segs = segments(book, [i for i, c in enumerate(book['chapters']) if c.get('kind') == 'body'])
        for f in sorted((d / 'work' / 'segs').glob('*.json')):
            rec = json.loads(f.read_text())
            i = rec['seg']
            if i >= len(segs):
                continue
            local = json.loads((d / 'work' / 'local' / f.name).read_text())['data']
            names = {str(p.get('id')): (p.get('name') or '').lstrip('*') for p in local.get('people', [])}
            roles = {str(p.get('id')): p.get('role') or '' for p in local.get('people', [])}
            text = None
            for key, item in (rec.get('guard', {}).get('critical') or {}).items():
                if text is None:
                    text = seg_text(book, segs[i])
                k, idx = key[0], int(key[1:])
                data = rec['data']
                src = {'e': 'events', 'a': 'attrs', 'r': 'rels'}[k]
                if idx >= len(data[src]):
                    continue
                x = data[src][idx]
                if k == 'e':
                    claim = x.get('text', '')
                elif k == 'a':
                    claim = f"{x.get('who', '')}：{x.get('value', '')}"
                else:
                    claim = f"{x.get('b', '')}是{x.get('a', '')}的{x.get('b_is', '')}"
                if not CRITICAL.search(claim):
                    continue
                out.append({'kind': 'critical', 'book': d.name, 'seg': i, 'key': key, 'text': text,
                            'q': {'type': 'choice', 'instructions': f'Does this_passage narrate this as a fact? CLAIM: {claim}', 'criteria': CRIT},
                            'jev_recorded': item.get('fact')})
            for key, p in (rec.get('link', {}).get('verify') or {}).items():
                if not key.startswith('form:'):
                    continue
                _, lid, name = key.split(':', 2)
                if text is None:
                    text = seg_text(book, segs[i])
                who = f"{names.get(lid, '')}（{roles.get(lid, '')}）"
                out.append({'kind': 'alias', 'book': d.name, 'seg': i, 'key': key, 'text': text,
                            'q': {'type': 'choice',
                                  'instructions': f'In this_passage, is the name 「{name}」 used to refer to the character {who}?',
                                  'criteria': {'yes': f'Yes — in this passage 「{name}」 is a name/nickname/title used for this very character.',
                                               'no': f'No — 「{name}」 is someone else (e.g. a person being talked about or addressed), or is not used for this character here.'}},
                            'jev_recorded': p})
    random.seed(7)
    random.shuffle(out)
    keep = [x for x in out if x['kind'] == 'critical'][:n // 2] + [x for x in out if x['kind'] == 'alias'][:n - n // 2]
    return keep


def ask(items, fn, label):
    t0 = time.time()
    got = {}
    for x in items:
        try:
            a = fn({'this_passage': x['text'][:12000]}, {'q': x['q']})
            probs = (a.get('q') or {}).get('probabilities') or {}
            got[id(x)] = probs
        except Exception as e:
            print(f'  {label} failed on {x["book"]}#{x["seg"]}: {type(e).__name__}: {str(e)[:80]}', file=sys.stderr)
            got[id(x)] = {}
    print(f'- {label}: {len(items)} 题，{time.time() - t0:.0f} 秒', file=sys.stderr)
    return got


def main():
    argv = sys.argv[1:]
    n = int(argv[argv.index('--n') + 1]) if '--n' in argv else 60
    models = (argv[argv.index('--models') + 1] if '--models' in argv else 'deepseek-flash+nothink,gpt-5.6-terra').split(',')
    skip = {i for f in ('--n', '--models') if f in argv for i in (argv.index(f), argv.index(f) + 1)}
    args = [a for i, a in enumerate(argv) if i not in skip and not a.startswith('--')]
    items = build(args, n)
    key = lambda x: 'fact' if x['kind'] == 'critical' else 'yes'   # noqa: E731
    runs = {} if '--no-jev' in argv else {'jev': ask(items, lambda s, q: jev(s, q), 'JEV')}
    for m in models:
        runs[m] = ask(items, lambda s, q, m=m: llm_judge(s, q, model=m), m)
    print(f'# 裁判一致性：JEV vs 大模型（{len(items)} 题，来自 {", ".join(Path(a).name for a in args)}）\n')
    print('| 裁判 | 与 JEV 的结论一致 | 与流水线当时的判定一致 | 平均概率差 | 概率>0.5 的比例 |\n|---|---|---|---|---|')
    base = runs.get('jev') or {}
    for name, got in runs.items():
        same = diff = 0
        n_ok = hi = 0
        for x in items:
            p, b = got[id(x)].get(key(x)), (base.get(id(x)) or {}).get(key(x))
            if p is None or b is None:
                continue
            n_ok += 1
            same += (p >= 0.5) == (b >= 0.5)
            diff += abs(p - b)
            hi += p >= 0.5
        rec = sum(1 for x in items if x['jev_recorded'] is not None and got[id(x)].get(key(x)) is not None
                  and (got[id(x)][key(x)] >= 0.5) == (x['jev_recorded'] >= 0.5))
        nrec = sum(1 for x in items if x['jev_recorded'] is not None and got[id(x)].get(key(x)) is not None)
        print(f'| {name} | {same}/{n_ok}（{same / max(1, n_ok):.0%}） | {rec}/{nrec}（{rec / max(1, nrec):.0%}） | {diff / max(1, n_ok):.2f} | {hi / max(1, n_ok):.0%} |')
    print('\n分歧的题（与当时 JEV 的判定相反）：')
    for x in items:
        vals = {k: got[id(x)].get(key(x)) for k, got in runs.items()}
        vals['当时的 JEV'] = x['jev_recorded']
        if any(v is not None for v in vals.values()) and len({(v or 0) >= 0.5 for v in vals.values() if v is not None}) > 1:
            print(f"- {x['book']}#{x['seg']} {x['key']}：" + '；'.join(f'{k} {v}' for k, v in vals.items()))
            print(f"  {x['q']['instructions'][:150]}")


if __name__ == '__main__':
    main()
