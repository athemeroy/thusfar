"""Spoiler probes v3 (language-neutral): facts that only become known in chapter N must not be
readable anywhere before N.

usage: python tests/spoiler_probes_v3.py BOOK_DIR PROBES_JSON

Each probe gives an explicit claim and the people whose cards to read. The graph is folded exactly
like the reader does, at
  * before : the first character of chapter N  → nothing may state the claim (a hit is a spoiler)
  * after  : the end of chapter N+2 (or the last chapter) → something should state it (sensitivity)
Every text a reader could see is checked: those people's taglines, biographies, attributes, events,
relation labels, plus every chapter recap and the story-so-far visible at that point. Each text is
put to JEV as a yes/no question ("does this text state or clearly imply: <claim>?"); yes ≥ 0.5 counts.
No keyword rules, so it works for any language the cards are written in.
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pipeline.llm import jev  # noqa: E402
from server.ask import fold  # noqa: E402

ROMAN = {'I': 1, 'V': 5, 'X': 10, 'L': 50, 'C': 100, 'D': 500, 'M': 1000}
CN = dict(zip('零一二三四五六七八九', range(10)))


def chapter_number(title: str) -> int | None:
    m = re.match(r'\s*(?:chapter|stave|book|part)\s+([0-9]+|[IVXLCDM]+)\b', title, re.I)
    if m:
        s = m.group(1).upper()
        if s.isdigit():
            return int(s)
        total = 0
        for a, b in zip(s, s[1:] + ' '):
            v = ROMAN[a]
            total += -v if b != ' ' and ROMAN.get(b, 0) > v else v
        return total
    m = re.match(r'第([零一二三四五六七八九十百]+)[回章]', title)
    if not m:
        return None
    v = cur = 0
    for ch in ('一' + m.group(1)) if m.group(1).startswith('百') else m.group(1):
        if ch in CN:
            cur = CN[ch]
        elif ch == '十':
            v, cur = v + (cur or 1) * 10, 0
        elif ch == '百':
            v, cur = v + (cur or 1) * 100, 0
    return v + cur


def find(world, names):
    low = [n.lower() for n in names]
    best = None
    for p in world['people'].values():
        allnames = [x.lower() for x in [p['name']] + p['aliases']]
        score = sum(1 for n in low if n in allnames)
        if score and (best is None or score > best[0] or (score == best[0] and p['n'] > best[1]['n'])):
            best = (score, p)
    return best[1] if best else None


def texts_for(world, people):
    out = []
    for p in people:
        tag = p['name']
        out += [(f'{tag}·tagline', p.get('tagline') or ''), (f'{tag}·bio', p.get('bio') or '')]
        out += [(f'{tag}·attr·{k}', v) for k, v in p['attrs'].items()]
        out += [(f'{tag}·event', e['text']) for e in p['events']]
        for r in world['rels'].values():
            if p['id'] in (r['a'], r['b']):
                other = world['people'].get(r['b'] if r['a'] == p['id'] else r['a'], {})
                role = r['b_is'] if r['a'] == p['id'] else r['a_is']
                out.append((f'{tag}·relation', f"{other.get('name', '')}: {role}; {r.get('desc', '')}"))
    out += [('recap', r['text']) for r in world.get('recaps', []) if r.get('text')]
    if world.get('saga'):
        out.append(('story-so-far', world['saga']))
    seen, uniq = set(), []
    for k, t in out:
        if t and t not in seen:
            seen.add(t)
            uniq.append((k, t))
    return uniq


def judge(claim, items):
    hits = []
    for k0 in range(0, len(items), 16):
        chunk = items[k0:k0 + 16]
        qs = {f'q{i}': {'type': 'choice',
                        'instructions': f'Does this text state, or clearly imply, that: {claim}\nTEXT: {t[:1500]}',
                        'criteria': {'yes': 'Yes — the text says this (in any language or wording).',
                                     'no': 'No — it is not stated, is only a guess/rumour/plan by a character, or is about something else.'}}
              for i, (_, t) in enumerate(chunk)}
        ans = jev({'note': 'Judge only the given text; do not use any knowledge of the novel.'}, qs)
        for i, (k, t) in enumerate(chunk):
            p = ((ans.get(f'q{i}') or {}).get('probabilities') or {}).get('yes', 0)
            if p >= 0.5:
                hits.append((k, t, round(p, 2)))
    return hits


def main():
    book_dir, probes_path = Path(sys.argv[1]), Path(sys.argv[2])
    P = json.loads(probes_path.read_text())
    book = json.loads((book_dir / 'book.json').read_text())
    kg = json.loads((book_dir / 'kg.json').read_text())
    frontier = json.loads((book_dir / 'status.json').read_text()).get('frontier', 0)
    chapters = {}
    for c in book['chapters']:
        n = chapter_number(c['title'])
        if n and n not in chapters:
            chapters[n] = c
    last = max(chapters)
    rows, spoilers, sensitive, checked = [], [], 0, 0
    for pr in P['probes']:
        n = pr['chapter']
        if n not in chapters or chapters[n]['o0'] > frontier:
            rows.append(f"| {pr['id']} | {n} | not processed | | |")
            continue
        checked += 1
        w = fold(kg['log'], chapters[n]['o0'] - 1)
        people = [p for p in (find(w, names) for names in pr['cards']) if p]
        before = judge(pr['claim'], texts_for(w, people))
        after_ch = chapters.get(min(last, n + 2)) or chapters[n]
        w2 = fold(kg['log'], min(after_ch['o1'], frontier))
        people2 = [p for p in (find(w2, names) for names in pr['cards']) if p]
        after = judge(pr['claim'], texts_for(w2, people2))
        sensitive += bool(after)
        if before:
            spoilers.append((pr, before))
        rows.append(f"| {pr['id']} | {n} | {'**LEAK**' if before else 'ok'} ({', '.join(p['name'] for p in people) or 'no card yet'})"
                    f" | {'seen' if after else 'not seen'} | {len(texts_for(w, people))} |")
    print(f'# Spoiler probes v3: {book_dir.name}\n')
    print(f'- probes checked: {checked}/{len(P["probes"])}')
    print(f'- **leaks (claim readable before its chapter): {len(spoilers)}**')
    print(f'- sensitivity (claim readable two chapters later): {sensitive}/{checked}\n')
    print('| probe | chapter | before | after | texts checked before |\n|---|---|---|---|---|')
    print('\n'.join(rows))
    for pr, hits in spoilers:
        print(f"\n## {pr['id']} (chapter {pr['chapter']}): {pr['claim']}")
        for k, t, p in hits[:4]:
            print(f'- {k} ({p}): {t[:200]}')


if __name__ == '__main__':
    main()
