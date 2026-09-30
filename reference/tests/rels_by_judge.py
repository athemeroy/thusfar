"""Could the judge produce relations instead of the LLM?

usage: python3 tests/rels_by_judge.py BOOK_DIR REF_DIR [--segs 20]

For each sampled segment: code lists the person pairs that appear together, the judge picks what
B is to A from a closed list, and the result is compared with (a) what the LLM wrote for the same
segment and (b) the reference book's relations. Dev books only.
"""
import json
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pipeline.extract import seg_text, segments  # noqa: E402
from pipeline.judge import BATCH  # noqa: E402
from pipeline.llm import jev  # noqa: E402

ROLES = {
    'parent': ('父母', "B is A's father or mother"),
    'child': ('子女', "B is A's son or daughter"),
    'spouse': ('配偶', "B is A's husband or wife"),
    'sibling': ('兄弟姐妹', "B is A's brother or sister"),
    'kin': ('亲戚', "B is another relative of A (in-law, cousin, uncle, grandparent…)"),
    'lover': ('恋人', "B is A's lover, betrothed or suitor"),
    'servant': ('仆人或下属', "B works for A (servant, employee, apprentice, subordinate)"),
    'master': ('主人或上司', "A works for B (B is the master, employer or superior)"),
    'teacher': ('师长', "B teaches or trains A"),
    'student': ('学生', "B is taught or trained by A"),
    'friend': ('朋友', "B is A's friend, companion or ally"),
    'enemy': ('敌对', "B is A's enemy, rival or opponent"),
    'colleague': ('同事或同行', "B and A work together, or are neighbours/townsfolk who deal with each other"),
    'none': ('—', 'This passage does not establish any relationship between them (they may simply appear in the same scene)'),
}
INVERSE = {'parent': 'child', 'child': 'parent', 'spouse': 'spouse', 'sibling': 'sibling', 'kin': 'kin',
           'lover': 'lover', 'servant': 'master', 'master': 'servant', 'teacher': 'student',
           'student': 'teacher', 'friend': 'friend', 'enemy': 'enemy', 'colleague': 'colleague'}


def pairs_of(data: dict, limit: int = 12):
    """People the segment shows together: same event first, then most-mentioned pairs."""
    names = {str(p.get('id')): (p.get('name') or '').lstrip('*') for p in data.get('people', [])}
    seen, out = set(), []
    for e in data.get('events', []):
        who = [w for w in dict.fromkeys(e.get('who') or []) if w in names]
        for i, a in enumerate(who):
            for b in who[i + 1:]:
                k = tuple(sorted((a, b)))
                if k not in seen:
                    seen.add(k)
                    out.append(k)
    return [(a, b) for a, b in out[:limit]], names


def ask(passage: str, prs, names):
    got = {}
    for k0 in range(0, len(prs), BATCH):
        chunk = prs[k0:k0 + BATCH]
        qs = {}
        for n, (a, b) in enumerate(chunk, 1):
            qs[f'r{n}'] = {'type': 'choice',
                           'instructions': f'In this_passage, what is 「{names[b]}」 (B) to 「{names[a]}」 (A)?',
                           'criteria': {k: v[1] for k, v in ROLES.items()}}
        ans = jev({'this_passage': passage[:12000]}, qs)
        for n, (a, b) in enumerate(chunk, 1):
            x = ans.get(f'r{n}') or {}
            p = (x.get('probabilities') or {}).get(x.get('choice'), 0)
            got[(a, b)] = (x.get('choice'), round(p, 3))
    return got


def main():
    d, ref_dir = Path(sys.argv[1]), Path(sys.argv[2])
    n_segs = int(sys.argv[sys.argv.index('--segs') + 1]) if '--segs' in sys.argv else 20
    book = json.loads((d / 'book.json').read_text())
    segs = segments(book, [i for i, c in enumerate(book['chapters']) if c.get('kind') == 'body'])
    ref = json.loads((ref_dir / 'kg.json').read_text())
    ref_names = {}
    for r in ref['log']:
        if r['t'] == 'person':
            ref_names[r['id']] = r['name']
        elif r['t'] == 'alias':
            ref_names.setdefault(r['id'], '')
    ref_pairs = set()
    for r in ref['log']:
        if r['t'] == 'rel':
            ref_pairs.add(tuple(sorted((ref_names.get(r['a'], ''), ref_names.get(r['b'], '')))))
    files = sorted((d / 'work' / 'local').glob('*.json'))
    random.seed(5)
    files = sorted(random.sample(files, min(n_segs, len(files))))
    judged = llm_rels = both = judge_only = llm_only = 0
    judge_in_ref = llm_in_ref = 0
    examples = []
    for f in files:
        rec = json.loads(f.read_text())
        i = rec['seg']
        if i >= len(segs):
            continue
        data = rec['data']
        prs, names = pairs_of(data)
        if not prs:
            continue
        got = ask(seg_text(book, segs[i]), prs, names)
        jrel = {k: v for k, v in got.items() if v[0] not in (None, 'none') and v[1] >= 0.5}
        lrel = {tuple(sorted((str(r.get('a')), str(r.get('b'))))): (r.get('b_is') or '') for r in data.get('rels', [])}
        judged += len(jrel)
        llm_rels += len(lrel)
        for k in jrel:
            kk = tuple(sorted(k))
            (both := both + 1) if kk in lrel else (judge_only := judge_only + 1)
            if tuple(sorted((names.get(k[0], ''), names.get(k[1], '')))) in ref_pairs:
                judge_in_ref += 1
        for k in lrel:
            if k not in {tuple(sorted(x)) for x in jrel}:
                llm_only += 1
            a, b = k
            if tuple(sorted((names.get(a, ''), names.get(b, '')))) in ref_pairs:
                llm_in_ref += 1
        for k, v in list(jrel.items())[:2]:
            kk = tuple(sorted(k))
            examples.append(f"第{i}段 {names[k[0]]} ← {names[k[1]]}：裁判「{ROLES[v[0]][0]}」{v[1]}"
                            f"；LLM「{lrel.get(kk, '（没写）')}」")
    print(f'# 关系：裁判 vs LLM（{len(files)} 段，{d.name}，参照 {ref_dir.name}）\n')
    print(f'- 裁判给出关系 {judged} 条，LLM 给出 {llm_rels} 条；两边都有的人物对 {both}，只有裁判的 {judge_only}，只有 LLM 的 {llm_only}')
    print(f'- 出现在参照（Opus 版）关系表里的：裁判 {judge_in_ref}/{judged}，LLM {llm_in_ref}/{llm_rels}')
    print('\n例子：')
    print('\n'.join('- ' + e for e in examples[:25]))


if __name__ == '__main__':
    main()
