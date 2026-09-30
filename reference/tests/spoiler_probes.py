"""Spoiler probes: facts that only become true in chapter N must not appear on a person's card before N.

usage: python tests/spoiler_probes.py BOOK_DIR PROBES_JSON [--at-chapter-end K]

For every probe the knowledge graph is folded (same fold as the reader) at:
  * before : the first character of chapter N  → the fact must NOT appear (a hit is a spoiler)
  * after  : the end of chapter N+2            → the fact SHOULD appear (sensitivity)
The person is found by name/alias; the checked text is that person's tagline, biography,
attributes, events they take part in, and relation labels/descriptions.
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from server.ask import fold  # noqa: E402

CN = dict(zip('零一二三四五六七八九', range(10)))


def cn_num(s: str) -> int | None:
    m = re.match(r'第([零一二三四五六七八九十百]+)[回章]', s)
    if not m:
        return None
    s = m.group(1)
    if s.startswith('百'):
        s = '一' + s
    v = cur = 0
    for ch in s:
        if ch in CN:
            cur = CN[ch]
        elif ch == '十':
            v += (cur or 1) * 10
            cur = 0
        elif ch == '百':
            v += (cur or 1) * 100
            cur = 0
    return v + cur


def find_person(world, names):
    best = None
    for p in world['people'].values():
        allnames = [p['name']] + p['aliases']
        score = sum(1 for n in names if n in allnames)
        if score and (best is None or score > best[0] or (score == best[0] and p['n'] > best[1]['n'])):
            best = (score, p)
    return best[1] if best else None


def card_text(world, p, other_names=None):
    """Everything the reader could see about p, as (field, text) pairs."""
    out = [('身份', p.get('tagline') or ''), ('小传', p.get('bio') or '')]
    out += [(f'档案·{k}', v) for k, v in p['attrs'].items()]
    out += [('经历', e['text']) for e in p['events']]
    for r in world['rels'].values():
        if p['id'] in (r['a'], r['b']):
            other = world['people'].get(r['b'] if r['a'] == p['id'] else r['a'], {})
            role = r['b_is'] if r['a'] == p['id'] else r['a_is']
            out.append(('关系', f"{other.get('name', '')}：{role}；{r.get('desc', '')}"))
    return out


IDIOM = re.compile(r'寻死|宁死|死活|死心|该死|死罪|要死|将死|快死|死不|假死|诈死|拼死|死命|死死|吓死|笑死|急死|气死|恨死|死鬼|死后|咒.{0,6}死')
OTHERS = re.compile(r'的|之|业师|老师|父|母|妻|夫|儿|女|兄|弟|姐|妹|师|丫|仆|叔|伯|舅|姑|姨|嫂|侄|孙|公公|婆')
FUNERAL = re.compile(r'丧事|丧礼|丧葬|治丧|吊丧|丧仪|穿孝|守孝|吊祭|灵柩|停灵|出殡|送殡|发引|入殓')
DEATH_AFTER_NAME = r'(?:已|于|在|竟|终|也)?.{0,4}?(死了|死去|去世|身亡|病逝|病故|亡故|过世|殁|薨|夭亡|夭逝|自尽|自刎|投井|上吊|吞金|咽气|气绝|归天|殒命|一命)'


def hits(probe, P, world, p):
    names = [n for n in probe['person'] + ([p['name']] if p else []) if n]
    kind = probe['kind']
    found = []
    for field, text in card_text(world, p):
        if not text:
            continue
        if kind == 'death':
            t = IDIOM.sub('', text)
            if field in ('身份', '档案·生死'):
                if re.search(P['death_words'], t) and not FUNERAL.search(t):
                    found.append((field, text))
                continue
            for n in names:
                for m in re.finditer(re.escape(n) + DEATH_AFTER_NAME, t):
                    between = t[m.start() + len(n):m.start(1)]
                    if not OTHERS.search(between) and not FUNERAL.search(t[m.start():m.end() + 4]):
                        found.append((field, text))
                        break
        elif kind == 'marriage':
            others = '|'.join(map(re.escape, probe['other']))
            if re.search(others, text) and re.search(r'成亲|成婚|完婚|拜堂|过门|娶了|嫁给了|嫁了|已娶|已嫁|结为夫妻|圆房|夫妻|妻子|丈夫|之妻|之夫|二房|姨娘|妾', text) \
                    and not re.search(r'拟|筹划|打算|商议|提亲|说媒|谋|想|要娶|欲|议亲|撮合|定亲|订婚', text):
                found.append((field, text))
        else:
            if re.search(probe['words'], text):
                found.append((field, text))
    return found


def confirm(probe, person_name, found):
    """Ask JEV whether each matched text really states the fact (keeps the rule-based list honest)."""
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from pipeline.llm import jev
    if probe['kind'] == 'death':
        claim = f'{person_name}已经死了'
    elif probe['kind'] == 'marriage':
        claim = f"{person_name}已经和{probe['other'][0]}成婚"
    else:
        claim = f"{person_name}：{probe['words']}"
    qs = {f'q{i}': {'type': 'choice',
                    'instructions': f'Does this text state, as having actually happened, that: {claim}? TEXT: {t}',
                    'criteria': {'yes': 'Yes, the text states it as a fact.', 'no': 'No — it is about someone else, a plan, a rumour, a figure of speech, or not stated.'}}
          for i, (_, t) in enumerate(found)}
    try:
        ans = jev({'note': 'Judge only the given text.'}, qs)
    except Exception:
        return found
    return [f for i, f in enumerate(found) if (ans.get(f'q{i}') or {}).get('probabilities', {}).get('yes', 0) >= 0.5]


def main():
    book_dir, probes_path = Path(sys.argv[1]), Path(sys.argv[2])
    P = json.loads(probes_path.read_text())
    book = json.loads((book_dir / 'book.json').read_text())
    kg = json.loads((book_dir / 'kg.json').read_text())
    st = json.loads((book_dir / 'status.json').read_text())
    frontier = st.get('frontier', 0)
    chapters = {}
    for c in book['chapters']:
        n = cn_num(c['title'])
        if n and n not in chapters:
            chapters[n] = c
    spoilers, sensitive, checked, skipped, rule_hits = [], 0, 0, [], 0
    for pr in P['probes']:
        n = pr['chapter']
        if n not in chapters or chapters[n]['o0'] > frontier:
            skipped.append(pr['id'])
            continue
        before = chapters[n]['o0'] - 1
        w = fold(kg['log'], before)
        p = find_person(w, pr['person'])
        checked += 1
        if p:
            h = hits(pr, P, w, p)
            if h:
                rule_hits += 1
                h = confirm(pr, p['name'], h)
            if h:
                spoilers.append((pr['id'], n, p['name'], h[:3]))
        after_ch = chapters.get(n + 2) or chapters.get(n + 1) or chapters[n]
        if after_ch['o1'] <= frontier:
            w2 = fold(kg['log'], after_ch['o1'])
            p2 = find_person(w2, pr['person'])
            if p2 and hits(pr, P, w2, p2):
                sensitive += 1
    print(f'# 剧透探针：{book_dir.name}\n')
    print(f'- 可检查的探针 {checked} 条（未处理到的 {len(skipped)} 条：{"、".join(skipped) or "无"}）')
    print(f'- 规则命中 {rule_hits} 条，经 JEV 复核确认的**提前泄露（剧透）：{len(spoilers)} 条**')
    print(f'- 事后能看到（敏感度）：{sensitive}/{checked}')
    for pid, n, name, h in spoilers:
        print(f'\n## 剧透 {pid}（第 {n} 回才发生）— {name}')
        for field, text in h:
            print(f'- {field}：{text[:120]}')


if __name__ == '__main__':
    main()
