"""Phase 2 of the two-phase pipeline: link local people to the book-wide cast, in order.

For segment k only the cast built from segments < k is used, so nothing leaks backwards.
Most links are decided by code (the same proper name was seen before); only unclear cases
go to JEV as a multiple-choice question ("is this 老太太 the 贾母 we know, or someone new?").

The result is converted into the classic extraction schema (new_people / surfaces /
merges / events / attrs / rels / profiles with P-ids for known people), so KG.plan/commit
and every spoiler rule there are reused unchanged.
"""
from __future__ import annotations

import re

from .judge import BATCH, same_question
from .kg import PRONOUNS, generic_word, is_latin
from .llm import jev


def is_generic(name: str) -> bool:
    return name.startswith('*') or generic_word(name.lstrip('*'))


def strong_names(p: dict) -> set[str]:
    out = set()
    for n in [p.get('name', '')] + list(p.get('names') or []):
        if not isinstance(n, str):
            continue
        n2 = n.lstrip('*').strip()
        if len(n2) >= 2 and n2 not in PRONOUNS and n2.lower() not in PRONOUNS and not is_generic(n):
            out.add(n2)
    return out


def weak_names(p: dict) -> set[str]:
    out = set()
    for n in [p.get('name', '')] + list(p.get('names') or []):
        if isinstance(n, str) and is_generic(n):
            n2 = n.lstrip('*').strip()
            if len(n2) >= 2 and n2 not in PRONOUNS and n2.lower() not in PRONOUNS:
                out.add(n2)
    return out


SUFFIX = re.compile(r'(先生|太太|夫人|小姐|老爹|老头子|老头|嫂子|大妈|大娘|大爷|老爷|少爷|姑娘|女士|博士|医生|律师|师傅|掌柜|老板|公子|奶奶'
                    r'|大师|禅师|法师|道长|真人|长老|方丈|师太|道人|居士|上人|掌门|宗主|城主|门主|帮主|盟主|会长|队长|团长|将军|前辈|老祖'
                    r'|师兄|师姐|师弟|师妹|师父|师尊|大哥|大姐|爷|嫂|娘)$')
KIN1 = re.compile(r'(叔|伯|哥|姐|嫂|婶|爷|总|董|老|兄|弟|妹)$')
EN_TITLE = re.compile(r"^(?:mr|mrs|miss|ms|dr|sir|lady|lord|uncle|aunt|captain|capt|master|mister|madame|madam|monsieur|mademoiselle"
                      r"|father|mother|brother|sister|old|young|little|professor|colonel|major|general|reverend|rev)\.?\s+", re.I)
EN_STOP = {'the', 'of', 'a', 'an', 'and', 'de', 'la', 'le', 'du', 'von', 'van', 'old', 'young', 'little', 'mr', 'mrs', 'miss', 'sir', 'lady', 'lord'}


def core(name: str) -> str:
    """郝麦太太 / 郝麦夫人 → 郝麦, Mr. Pocket → Pocket (title removed); used only to propose candidates."""
    name = name or ''
    if is_latin(name):
        c = name
        while EN_TITLE.match(c):
            c = EN_TITLE.sub('', c, count=1)
        return c if len(c) >= 2 and c != name else ''
    c = SUFFIX.sub('', name)
    return c if len(c) >= 2 and c != name else ''


def _tokens(name: str) -> set[str]:
    return {w.lower() for w in re.findall(r"[A-Za-z][A-Za-z'’\-]+", name)} - EN_STOP


def _stem(name: str) -> str:
    """老余 → 余, 王总 → 王, 圆觉大师 → 圆觉, 阿Q → Q."""
    n = SUFFIX.sub('', name.lstrip('*'))
    n = re.sub(r'^(老|小|阿)', '', n) if len(n) >= 2 else n
    if len(n) >= 2 and KIN1.search(n) and len(n) <= 3:
        n = KIN1.sub('', n)
    return n


def related(new: str, known: str) -> bool:
    """Could `new` be another form of the name `known` (shared surname/given name/word)?

    Asymmetric on purpose: a surname + title form (老余, 王叔) may attach to a full name that starts
    with that surname (余擎苍, 王木), but a known surname + title form vouches for nothing else —
    王木 being called 王叔 says nothing about 王母."""
    a, b = new.lstrip('*'), known.lstrip('*')
    if not a or not b:
        return False
    if a == b or (len(a) >= 2 and len(b) >= 2 and (a in b or b in a)):
        return True
    if is_latin(a) or is_latin(b):
        return bool(_tokens(a) & _tokens(b))
    sa, sb = _stem(a), _stem(b)
    if len(sa) >= 2 and len(sb) >= 2:
        return sa in sb or sb in sa or sa in b or sb in a
    if len(sa) == 1 and len(sb) >= 2:
        return b.startswith(sa) or sb.startswith(sa) or sb.endswith(sa)
    if len(sa) == 1 and len(sb) == 1:
        return sa == sb           # 老王 / 王叔: both only say "a Wang"
    return False


def proper_name(p: dict) -> str:
    """The name to use when asking about a person: a real name if they have one (not 老和尚)."""
    if not is_generic(p['name']):
        return p['name']
    named = sorted((n for n in p['aliases'] if not is_generic(n) and n not in PRONOUNS),
                   key=lambda n: (-len(n), n))
    return named[0] if named else p['name']


def names_of(p: dict) -> set[str]:
    return set(p['aliases']) | {p['name']} | set(p.get('weak', ()))


def short_forms(name: str) -> set[str]:
    """Given names without surname, and parts of foreign names: 贾宝玉→宝玉, 查理·包法利→查理/包法利, Herbert Pocket→Herbert/Pocket."""
    out = set()
    if is_latin(name):
        c = core(name) or name
        parts = [w for w in re.split(r'\s+', c) if len(w) >= 3 and w.lower() not in EN_STOP]
        return set(parts) if len(parts) > 1 else set()
    if SUFFIX.search(name):          # 无觉大师 is not 无 + 觉大师
        return out
    if '·' in name:
        out |= {x for x in name.split('·') if len(x) >= 2}
    elif 3 <= len(name) <= 4:
        out.add(name[1:])
    return out


def link_segment(kg, seg: dict, local: dict, context_text: str, scope_start: int = 0) -> tuple[dict, dict]:
    """Return (data in classic schema, link record for the segment file).

    scope_start: in a collection, where the current work begins — people from earlier works are not
    candidates, so one story never inherits the cast of the story before it."""
    people = local.get('people') or []
    cast = {pid: p for pid, p in kg.people.items()
            if not p.get('merged_into') and p.get('first', 0) >= scope_start}
    # index of the cast by names (only what is known before this segment)
    by_name: dict[str, set] = {}
    weak_idx: dict[str, set] = {}
    all_names: list[tuple[str, str]] = []
    for pid, p in cast.items():
        for n in sorted(p['aliases'] | {p['name']}):
            by_name.setdefault(n, set()).add(pid)
            all_names.append((n, pid))
            for s in sorted(short_forms(n)):
                by_name.setdefault('~' + s, set()).add(pid)
        for n in p.get('weak', ()):
            weak_idx.setdefault(n, set()).add(pid)
            all_names.append((n, pid))

    def contains(names):
        # 管土谷祠的老头子 ~ 老头子, 赵秀才 ~ 秀才: one name inside the other
        out = set()
        for n in names:
            for g, pid in all_names:
                if len(g) >= 2 and len(n) >= 2 and g != n and (g in n or n in g):
                    out.add(pid)
        return out

    people = [q for q in people if not re.search(r'夫妇|夫妻|们$|一家|众人|全家|大伙', q.get('name') or '')]
    # "the other party", "someone": not a person the reader could look up
    people = [q for q in people if strong_names(q) or (q.get('name') or '').lstrip('*').strip().lower() not in PRONOUNS]
    decisions, questions = {}, []
    # a person known only by a title (老爷/太太) is often someone named elsewhere in this segment
    named_here = [q for q in people if strong_names(q)]
    for lp in people:
        lid = str(lp.get('id'))
        strong, weak = strong_names(lp), weak_names(lp)
        exact = set().union(*(by_name.get(n, set()) for n in strong)) if strong else set()
        fuzzy = set().union(*(by_name.get('~' + n, set()) for n in strong)) if strong else set()
        for n in strong:
            for s in short_forms(n):
                fuzzy |= by_name.get(s, set())
        weak_c = set().union(*(by_name.get(n, set()) | weak_idx.get(n, set()) for n in weak)) if weak else set()
        weak_c |= set().union(*(weak_idx.get(n, set()) for n in strong)) if strong else set()
        near = contains(strong | weak)
        local_c = [f"L:{q['id']}" for q in named_here if q is not lp and not _gender_clash(lp, q)] if not strong else []
        hint = _resolve_hint(kg, lp, by_name)
        hint = hint if hint in cast and not _gender_clash(lp, cast[hint]) else None
        mine = strong | weak
        # a distinctive name belongs to exactly one known person and is not a title
        distinct = {next(iter(by_name[n])) for n in strong if len(by_name.get(n, ())) == 1}
        distinct = {pid for pid in distinct if not _gender_clash(lp, cast[pid])}
        cores = {core(n) for n in mine} - {''}
        same_core = {pid for pid, p in cast.items() if cores & ({core(n) for n in names_of(p)} - {''})
                     and not _gender_clash(lp, p)} if cores else set()
        if len(distinct) == 1:
            # the safest evidence there is: a name only one person has ever been called
            decisions[lid] = {'to': next(iter(distinct)), 'how': 'name' if not hint or hint in distinct else 'name-over-hint'}
        elif len(distinct) > 1 or hint or exact or fuzzy or weak_c or near or same_core or local_c:
            # shared names, titles, hints without a distinctive name: never merge blindly — JEV decides, "new" allowed
            pool = distinct | exact | fuzzy | weak_c | near | same_core
            cands = list(dict.fromkeys(([hint] if hint else []) +
                                           sorted(pool, key=lambda x: (-cast[x].get('mentions', 0), x))))[:6]
            questions.append((lid, lp, cands + local_c[:4]))
        else:
            decisions[lid] = {'to': None, 'how': 'new'}

    raw = {}
    if questions:
        locals_by_id = {str(q['id']): q for q in people}
        raw = _ask_jev(questions, cast, context_text, locals_by_id)
        for lid, lp, cands in questions:
            r = raw.get(lid) or {}
            if r.get('choice') in cands and r.get('p', 0) >= 0.6 and str(r['choice']).startswith('L:'):
                decisions[lid] = {'same_as_local': r['choice'][2:], 'how': 'jev-local', 'p': r['p']}
            elif r.get('choice') in cands and r.get('p', 0) >= 0.6:
                decisions[lid] = {'to': r['choice'], 'how': 'jev', 'p': r['p']}
            elif r.get('choice') == 'new' and r.get('p', 0) >= 0.6:
                decisions[lid] = {'to': None, 'how': 'jev-new', 'p': r['p']}
            else:
                # JEV unsure: an exact proper-name match wins, otherwise treat as a new person
                exact = [c for c in cands if c in cast and strong_names(lp) & (cast[c]['aliases'] | {cast[c]['name']})]
                decisions[lid] = {'to': exact[0], 'how': 'fallback-name'} if exact else {'to': None, 'how': 'fallback-new'}
    drop, checked = verify_names(cast, people, decisions, context_text)
    # "same as another local entry" takes over that entry's decision — after verification, so a
    # rejected identity claim (圆觉大师 is not 无觉大师) is not copied onto its "老和尚"
    for lid, d in decisions.items():
        if 'same_as_local' in d:
            tgt = decisions.get(d['same_as_local']) or {}
            d['to'] = tgt.get('to')
            d['local'] = d['same_as_local']
    return to_classic(local, decisions, drop, getattr(kg, 'k', 1)), {'decisions': decisions, 'jev': raw, 'verify': checked}


def _resolve_hint(kg, lp: dict, by_name: dict) -> str | None:
    """The phase-1 model's "this is P21" hint. known_name (the name shown next to the id) wins
    over the id, so a replay with different numbering cannot point at the wrong person."""
    kid, kn = lp.get('known'), lp.get('known_name')
    if kid in kg.people:
        pid = kg.canon(kid)
        if not kn or kn in names_of(kg.people[pid]):
            return pid
    if kn and len(by_name.get(kn, ())) == 1:
        return next(iter(by_name[kn]))
    return None


def verify_names(cast: dict, people: list, decisions: dict, passage: str) -> tuple[dict, dict]:
    """Two checks before anything is written, in one JEV call:

    * a link that gives someone a name unrelated to every name they had (圆觉大师 → 无觉大师)
      is an identity claim; the passage must establish it, otherwise the person is new;
    * a name the phase-1 model listed for someone (雷泰: 老余) that is unrelated to their other
      names, or already belongs to another person, must be used for them in this passage.
    Returns ({local id: names to drop}, record)."""
    claims, forms = {}, {}
    for lp in people:
        lid = str(lp.get('id'))
        d = decisions.get(lid) or {}
        strong = strong_names(lp)
        tgt = d.get('to') if d.get('to') in cast else None
        if tgt:
            t = cast[tgt]
            base = {n for n in t['aliases'] | {t['name']} if not is_generic(n)} or {t['name']}
            who = f"{proper_name(t)}（{t.get('tagline') or t.get('intro') or ''}）"
            if (d.get('how', '').startswith('jev') or d.get('how') == 'fallback-name') and strong \
                    and not any(related(a, b) for a in sorted(strong) for b in sorted(base)):
                claims[lid] = (lp.get('name', '').lstrip('*') or sorted(strong)[0], proper_name(t),
                               lp.get('role') or '', t.get('tagline') or t.get('intro') or '')
        else:
            main = (lp.get('name') or '').lstrip('*')
            base = {main} if main in strong else set(sorted(strong)[:1])
            who = f"{main}（{lp.get('role', '')}）"
        for f in sorted(strong - base):
            taken = any(pid != tgt and f in (p['aliases'] | {p['name']}) for pid, p in cast.items())
            if taken or not any(related(f, b) for b in sorted(base)):
                forms[(lid, f)] = who
    if not claims and not forms:
        return {}, {}
    qs, keys = {}, {}
    for lid, pr in claims.items():
        k = f'c{len(qs) + 1}'
        keys[k] = ('claim', lid)
        qs[k] = {'type': 'choice', 'instructions': same_question(*pr),
                 'criteria': {'same': 'The passage makes clear these two names refer to one and the same person.',
                              'different': 'They are different people (relatives, colleagues, two people with similar titles or names).',
                              'unclear': 'The passage does not establish it.'}}
    for (lid, f), who in forms.items():
        k = f'a{len(qs) + 1}'
        keys[k] = ('form', lid, f)
        qs[k] = {'type': 'choice', 'instructions': f'In this_passage, is the name 「{f}」 used to refer to the character {who}?',
                 'criteria': {'yes': f'Yes — in this passage 「{f}」 is a name/nickname/title used for this very character.',
                              'no': f'No — 「{f}」 is someone else (e.g. a person being talked about or addressed), or is not used for this character here.'}}
    ans = {}
    items = list(qs.items())
    for k0 in range(0, len(items), BATCH):
        ans.update(jev({'this_passage': passage[:12000]}, dict(items[k0:k0 + BATCH])))
    drop, record = {}, {}
    for k, key in keys.items():
        probs = (ans.get(k) or {}).get('probabilities') or {}
        if key[0] == 'claim':
            p = round(probs.get('same', 0), 3)
            record[f'claim:{key[1]}'] = p
            if p < 0.7:
                d = decisions[key[1]]
                decisions[key[1]] = {'to': None, 'how': 'unconfirmed-new', 'was': d.get('to'), 'p': p}
        else:
            p = round(probs.get('yes', 0), 3)
            record[f'form:{key[1]}:{key[2]}'] = p
            if p < 0.5:
                drop.setdefault(key[1], set()).add(key[2])
    return drop, record


def _gender_clash(lp, gp) -> bool:
    a, b = lp.get('gender'), gp.get('gender')
    return a in ('男', '女') and b in ('男', '女') and a != b


def _ask_jev(questions, cast, context_text: str, locals_by_id: dict | None = None) -> dict:
    out = {}
    locals_by_id = locals_by_id or {}

    def desc(c):
        if str(c).startswith('L:'):
            q = locals_by_id.get(c[2:], {})
            return f"本段中的「{q.get('name', '')}」：{q.get('role', '')}（same person as this one）"
        p = cast[c]
        return f"{p['name']}（又称：{'、'.join(sorted((p['aliases'] | p.get('weak', set())) - {p['name']})[:8]) or '无'}）：{p.get('tagline') or p.get('intro') or ''}"
    for k0 in range(0, len(questions), BATCH):
        chunk = questions[k0:k0 + BATCH]
        state = {'this_passage': context_text[:12000],
                 'known_characters': {c: desc(c) for _, _, cands in chunk for c in cands}}
        qs = {}
        for n, (lid, lp, cands) in enumerate(chunk, 1):
            names = '、'.join(sorted(strong_names(lp) | weak_names(lp))) or lp.get('name', '')
            crit = {pid: state['known_characters'][pid] for pid in cands}
            crit['new'] = 'Someone else: a character not among these (new to the story, or a different person who shares a title/name).'
            qs[f'q{n}'] = {
                'type': 'choice',
                'instructions': (f'In this_passage a character is called 「{names}」 (described in the passage as: {lp.get("role", "")}). '
                                 'Which already-known character is this, if any? Decide from this_passage and the known characters only.'),
                'criteria': crit,
            }
        ans = jev(state, qs)
        for n, (lid, lp, cands) in enumerate(chunk, 1):
            a = ans.get(f'q{n}') or {}
            probs = a.get('probabilities') or {}
            out[lid] = {'choice': a.get('choice'), 'p': round(probs.get(a.get('choice'), 0), 3)}
    return out


def to_classic(local: dict, decisions: dict, drop: dict | None = None, k: int = 1) -> dict:
    """Local extraction + link decisions → the schema KG.plan/commit understand (k scales text limits)."""
    drop = drop or {}
    ref = {}
    new_people, surfaces, profiles = [], {}, []
    order = sorted(local.get('people') or [], key=lambda q: 'local' in (decisions.get(str(q.get('id'))) or {}))
    for lp in order:
        lid = str(lp.get('id'))
        d = decisions.get(lid) or {'to': None}
        if d.get('to'):
            ref[lid] = d['to']
        elif d.get('local') and d['local'] in ref:
            ref[lid] = ref[d['local']]
        else:
            ref[lid] = f'N{lid}'
            strong = strong_names(lp)
            fallback = next((n.lstrip('*').strip() for n in lp.get('names') or []
                             if isinstance(n, str) and n.lstrip('*').strip() in strong), '无名氏')
            new_people.append({'ref': ref[lid], 'name': (lp.get('name') or fallback).lstrip('*'),
                               'gender': lp.get('gender'), 'importance': 2, 'para': lp.get('para'),
                               'quote': lp.get('quote'), 'intro': lp.get('role') or ''})
            if lp.get('role'):
                profiles.append({'who': ref[lid], 'tagline': lp['role'][:24 * k], 'bio': '',
                                 'para': lp.get('para'), 'evidence_scope': 'segment'})
        forms = []
        for n in [lp.get('name', '')] + list(lp.get('names') or []):
            if isinstance(n, str) and n.strip('*') and n.lstrip('*').strip() not in drop.get(lid, ()):
                forms.append(('*' if is_generic(n) else '') + n.lstrip('*'))
        surfaces.setdefault(ref[lid], [])
        surfaces[ref[lid]] += [f for f in forms if f not in surfaces[ref[lid]]]
    # two local entries revealed to be one person
    merges = []
    for s in local.get('same') or []:
        a, b = ref.get(str(s.get('a'))), ref.get(str(s.get('b')))
        if a and b and a != b:
            merges.append({'from': a, 'into': b, 'para': s.get('para'), 'quote': s.get('quote'), 'reason': s.get('why', '')})
    m = lambda x: ref.get(str(x))  # noqa: E731
    events = [dict(e, who=[m(w) for w in (e.get('who') or []) if m(w)], importance=e.get('imp', 1)) for e in local.get('events') or []]
    attrs = [dict(f, who=m(f.get('who'))) for f in local.get('facts') or [] if m(f.get('who'))]
    rels = [dict(r, a=m(r.get('a')), b=m(r.get('b')),
                 status=r.get('status') if r.get('status') in ('new', 'changed', 'ended') else 'new')
            for r in local.get('rels') or [] if m(r.get('a')) and m(r.get('b'))]
    return {'new_people': new_people, 'surfaces': surfaces, 'aliases': [], 'merges': merges,
            'events': events, 'attrs': attrs, 'rels': rels, 'profiles': profiles}
