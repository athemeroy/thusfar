"""Compare a cheap-model run of a book against a reference run (e.g. Terra vs Opus).

usage: python tests/compare_models.py REF_DIR CAND_DIR [--jev-sample 40] > report.md

Everything is compared up to the candidate's processed frontier. Metrics:
  - people: how many reference characters the candidate also found (by name/alias overlap)
  - highlights: exact name spans in the text, and whether they link to the same person
  - relations: character pairs related in both graphs
  - time travel: at 10 reading positions, overlap of "people known so far"
  - fact support: JEV judges a sample of each run's events/attributes against the source
    passage around their anchor (absolute accuracy signal, independent of the reference)
  - spoiler audit and model usage
"""
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from server.ask import fold  # noqa: E402
from pipeline.judge import guard_texts  # noqa: E402

GENERIC = set('父亲 母亲 太太 夫人 先生 老爷 小姐 姑娘 医生 校长 老师 神父 堂长 老板 老板娘 仆人 女仆 孩子 学生 病人 大人 老人 女人 男人'.split())


def load(d: Path):
    kg = json.loads((d / 'kg.json').read_text())
    st = json.loads((d / 'status.json').read_text())
    ms = []
    for f in sorted((d / 'mentions').glob('*.json')):
        ms += json.loads(f.read_text())
    if (d / 'work' / 'usage.json').exists():
        usage = json.loads((d / 'work' / 'usage.json').read_text())
    else:   # older runs: add up what each segment record saved (extraction calls only)
        usage = {'by_model': {}}
        for f in (d / 'work' / 'segs').glob('*.json'):
            r = json.loads(f.read_text())
            m = usage['by_model'].setdefault((r.get('model') or '?') + '（仅抽取）', {'calls': 0, 'prompt': 0, 'completion': 0})
            m['calls'] += 1
            m['prompt'] += (r.get('usage') or {}).get('prompt') or 0
            m['completion'] += (r.get('usage') or {}).get('completion') or 0
    return kg, st, ms, usage


def names_of(p):
    return {n for n in [p['name']] + p['aliases'] if len(n) >= 2 and n not in GENERIC}


def match_people(ref_people, cand_people):
    """cand id -> ref id, greedy by name overlap."""
    pairs = []
    for cid, c in cand_people.items():
        cn = names_of(c)
        for rid, r in ref_people.items():
            ov = len(cn & names_of(r)) or (0.5 if c['name'] == r['name'] else 0)
            if ov:
                pairs.append((ov, cid, rid))
    pairs.sort(reverse=True)
    c2r, used = {}, set()
    for ov, cid, rid in pairs:
        if cid in c2r or rid in used:
            continue
        c2r[cid] = rid
        used.add(rid)
    return c2r


def pct(a, b):
    return f'{100 * a / b:.0f}%' if b else '—'


def fact_support(root: Path, kg, frontier, n, seed=7):
    """JEV judges each sampled event/attribute against the text around its own anchor."""
    from concurrent.futures import ThreadPoolExecutor
    book = json.loads((root / 'book.json').read_text())
    full = '\n'.join(b['t'] for b in book['blocks'])
    recs = [r for r in kg['log'] if r['p'] <= frontier and r['t'] in ('event', 'attr') and r.get('s') is not None]
    random.Random(seed).shuffle(recs)
    recs = recs[:n]
    people = {r['id']: r['name'] for r in kg['log'] if r['t'] == 'person'}

    def one(r):
        passage = full[max(0, r['s'] - 900):min(len(full), r['p'] + 200)]
        item = r['text'] if r['t'] == 'event' else f"{people.get(r['id'], r['id'])}的{r['key']}：{r['value']}"
        try:
            return guard_texts(passage, {}, {'x': item})['x'].get('p') or 0, item
        except Exception as e:
            return None, f'{item}（JEV 出错：{str(e)[:60]}）'
    with ThreadPoolExecutor(8) as ex:
        rows = list(ex.map(one, recs))
    judged = [r for r in rows if r[0] is not None]
    ok = sum(1 for p, _ in judged if p >= 0.5)
    return ok, len(judged), [r for r in rows if r[0] is None or r[0] < 0.5]


def main():
    ref_dir, cand_dir = Path(sys.argv[1]), Path(sys.argv[2])
    nj = int(sys.argv[sys.argv.index('--jev-sample') + 1]) if '--jev-sample' in sys.argv else 40
    rkg, rst, rms, ru = load(ref_dir)
    ckg, cst, cms, cu = load(cand_dir)
    frontier = min(cst.get('frontier', 0), rst.get('frontier', 0))
    rw, cw = fold(rkg['log'], frontier), fold(ckg['log'], frontier)
    rp, cp = rw['people'], cw['people']
    c2r = match_people(rp, cp)
    r_major = {k for k, p in rp.items() if p['n'] >= 5 or p['imp'] >= 2}
    found_major = {c2r[c] for c in c2r} & r_major

    out = []
    w = out.append
    w(f'# 模型对比：{cand_dir.name} vs 参照 {ref_dir.name}\n')
    w(f'比较范围：正文到位置 {frontier}（候选完成 {cst.get("done")}/{cst.get("total")} 段，参照 {rst.get("done")}/{rst.get("total")} 段）\n')
    w('## 用量\n')
    for name, u in (('参照', ru), ('候选', cu)):
        bm = u.get('by_model') or {}
        detail = '；'.join(f"{m}: {x['calls']} 次, 入 {x['prompt']} / 出 {x['completion']} tokens" for m, x in bm.items()) or \
            f"{u.get('llm_calls', '?')} 次, 入 {u.get('prompt', '?')} / 出 {u.get('completion', '?')}（旧统计，重启会清零，不完整）"
        w(f'- {name}：{detail}；JEV {u.get("jev_calls", "?")} 次\n')

    w('\n## 人物\n')
    w(f'- 参照人物 {len(rp)}，候选人物 {len(cp)}，按名字/别称对上 {len(c2r)}\n')
    w(f'- 参照中的重要人物（提及≥5 次或重要度≥2）{len(r_major)}，候选找到 {len(found_major)}（召回 {pct(len(found_major), len(r_major))}）\n')
    missing = [rp[k]['name'] for k in r_major - found_major]
    if missing:
        w(f'- 候选漏掉的重要人物：{"、".join(missing[:20])}\n')
    # wrong merges: one candidate person carrying proper names of two or more reference people
    ref_owner = {}
    for rid, r in rp.items():
        for n in names_of(r):
            ref_owner.setdefault(n, set()).add(rid)
    wrong = []
    for cid, c in cp.items():
        owners = set()
        for n in names_of(c):
            if len(ref_owner.get(n, ())) == 1:
                owners |= ref_owner[n]
        if len(owners) >= 2:
            wrong.append(f"{c['name']}（混入了：{'、'.join(rp[o]['name'] for o in owners)}）")
    dup = {}
    for cid, c in cp.items():
        for n in names_of(c):
            if len(ref_owner.get(n, ())) == 1:
                dup.setdefault(next(iter(ref_owner[n])), set()).add(cid)
    dups = [f"{rp[r]['name']}→{len(cs)} 个" for r, cs in dup.items() if len(cs) >= 2 and r in r_major]
    w(f'- **错误合并**（一个人身上出现了参照中两个以上不同人物的名字）：{len(wrong)} 个{("：" + "；".join(wrong[:8])) if wrong else ""}\n')
    w(f'- 重要人物被拆成多条：{len(dups)} 个{("：" + "、".join(dups[:10])) if dups else ""}\n')
    extra = [cp[k]['name'] for k in cp if k not in c2r]
    if extra:
        w(f'- 候选多出的人物（参照里没有）：{"、".join(extra[:20])}\n')

    w('\n## 正文人名高亮\n')
    rmap = {(m[0], m[1]): m[2] for m in rms if m[1] <= frontier and not (len(m) > 3 and m[3])}
    cmap = {(m[0], m[1]): m[2] for m in cms if m[1] <= frontier and not (len(m) > 3 and m[3])}
    both = set(rmap) & set(cmap)
    same = 0
    for k in both:
        cid, rid = cmap[k], rmap[k]
        if c2r.get(cid) == rid or c2r.get(cid) is not None and rp.get(c2r.get(cid), {}).get('name') == rp.get(rid, {}).get('name'):
            same += 1
    w(f'- 专名高亮：参照 {len(rmap)} 处，候选 {len(cmap)} 处，位置完全相同 {len(both)} 处（召回 {pct(len(both), len(rmap))}，精度 {pct(len(both), len(cmap))}）\n')
    w(f'- 位置相同的高亮里，指向同一人物的 {pct(same, len(both))}（名字对不上的合并记录会拉低这个数，仅作参考）\n')

    w('\n## 关系\n')
    rpairs = {tuple(sorted((r['a'], r['b']))) for r in rw['rels'].values()}
    cpairs = {tuple(sorted((c2r.get(r['a']), c2r.get(r['b'])))) for r in cw['rels'].values() if r['a'] in c2r and r['b'] in c2r}
    w(f'- 参照关系 {len(rpairs)} 对，候选 {len(cw["rels"])} 对，其中双方都能对上的人物之间、两边都有关系的 {len(rpairs & cpairs)} 对（召回 {pct(len(rpairs & cpairs), len(rpairs))}）\n')
    w(f'- 事件条数：参照 {len(rw["events"])}，候选 {len(cw["events"])}\n')

    w('\n## 时间旅行一致性（各阅读位置“已知人物”的重合度）\n')
    body0 = min(r['p'] for r in rkg['log'])
    for k in range(1, 11):
        pos = body0 + (frontier - body0) * k // 10
        a, b = fold(rkg['log'], pos)['people'], fold(ckg['log'], pos)['people']
        ma = match_people(a, b)
        union = len(a) + len(b) - len(ma)
        w(f'- 位置 {pos}：参照已知 {len(a)} 人，候选 {len(b)} 人，对上 {len(ma)}（重合度 {pct(len(ma), union)}）\n')

    w(f'\n## 事实可信度（JEV 按锚点附近原文抽查，每边 {nj} 条，支持概率≥0.5 算站得住）\n')
    for name, d, kg in (('参照', ref_dir, rkg), ('候选', cand_dir, ckg)):
        ok, n, rows = fact_support(d, kg, frontier, nj)
        w(f'- {name}：{ok}/{n}（{pct(ok, n)}）\n')
        for p, t in rows[:6]:
            w(f'  - 未获支持 {p if p is None else round(p, 2)}：{t}\n')

    w('\n## 防剧透审计\n')
    import subprocess
    for name, d in (('参照', ref_dir), ('候选', cand_dir)):
        res = subprocess.run([sys.executable, str(Path(__file__).with_name('spoiler_audit.py')), str(d)], capture_output=True, text=True)
        line = next((l for l in res.stdout.splitlines() if l.startswith('problems')), res.stdout[:200])
        w(f'- {name}：{line}\n')
    print(''.join(out))


if __name__ == '__main__':
    main()
