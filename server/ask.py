"""“问问这本书”: grounded, spoiler-safe answers.

  1. Jev routes the question (who / relation / recap / why / future / other).
  2. Context = the knowledge graph folded at the reader's position + retrieved paragraphs
     that end before that position + the paragraphs just read.
  3. An LLM answers only from that context, citing passages.
  4. Jev checks the answer against the same context; a flagged answer is regenerated once.
"""
from __future__ import annotations

import math
import os
import re
import time
import threading
from collections import Counter, OrderedDict
from pathlib import Path

from pipeline.judge import guard_texts, route_question
from pipeline.llm import chat, jev
from pipeline.parse import u16
from server.temporal import fold

QA_MODEL = __import__('os').environ.get('QA_MODEL', 'deepseek-flash+nothink')
_audit_lock = threading.Lock()
STOP = set('的了是在他她它们我你这那一个也就都而及与和或着过吗呢吧啊呀么什怎为何哪谁说道把被让给从到对向于以之其所有没不很还又再已')

SYSTEM = """你是一位读书伙伴，陪读者读《{title}》。读者现在读到了{where}。
规则（必须遵守）：
1. 只能根据下面【材料】回答。材料只包含读者已经读过的内容。即使你知道这部作品，也绝不能透露材料以外的任何情节、身份、结局或后来的变化。
2. 不要对后面的发展做任何预测、暗示或铺垫（不要说“恐怕”“注定”“后来会”“还会发生”之类的话）。
3. 如果材料不足以回答，就直说“读到这里还看不出来”，再说说目前已知的相关情况。
4. 【前情提要】【人物】【最近发生的事】是整理出的摘要，可以转述，但不要加引号当作原文。只有【原文n】里的句子才能用「」直接引用，并在句末标注 [n]。关键判断尽量给出 [n] 出处。
5. 回答具体、有温度、简洁（一般 80～250 字），用读者提问的语言回答（中文提问就用中文，人名可保留原文拼写），不要使用 Markdown 标题或列表符号。"""


EN_STOP = set('the and that with was were had have has his her him she they them their this there then than what when where which who whom '
              'would could should shall will not but for from into upon about said says say one all any are been being did does '
              'your you our out very some such only own more most much like just over also how why its it\'s'.split())


def _bigrams(s: str) -> set:
    """Chinese: character bigrams; Western text: lower-cased words (both, for mixed text)."""
    words = {w.lower().replace('’', "'") for w in re.findall(r"[A-Za-z][A-Za-z'’]{2,}", s)} - EN_STOP
    s = re.sub(r'[\sA-Za-z0-9]', '', s)
    return words | {s[i:i + 2] for i in range(len(s) - 1) if not (s[i] in STOP and s[i + 1] in STOP)}


_index = OrderedDict()
_index_lock = threading.RLock()


def evict_index(d):
    with _index_lock:
        _index.pop(str(d), None)


def _book_index(d: Path, book: dict):
    key = str(d)
    st = (d / 'book.json').stat()
    mt = (st.st_mtime_ns, st.st_size, st.st_ino)
    with _index_lock:
        hit = _index.get(key)
        if hit and hit[0] == mt:
            _index.move_to_end(key)
            return hit[1]
    body = {i for i, c in enumerate(book['chapters']) if c.get('kind') == 'body'}
    idx = []
    for ci, c in enumerate(book['chapters']):
        if ci not in body:
            continue
        for bi in range(c['b0'], c['b1']):
            b = book['blocks'][bi]
            if b['k'] == 'p' and len(b['t']) >= 8:
                idx.append((b['o'], b['t']))
    # Feature sets can exceed text size substantially. Retain at most four small indexes.
    weight = sum(len(t.encode('utf-8')) + 64 for _, t in idx)
    if weight <= 4 * 1024 * 1024:
        with _index_lock:
            _index[key] = (mt, idx, weight)
            while len(_index) > 4 or sum(x[2] for x in _index.values()) > 8 * 1024 * 1024:
                _index.popitem(last=False)
    return idx


def rank_by_judge(q: str, passages: list[dict], keep: int = 6) -> list[dict]:
    """Word overlap finds candidates; the judge says which of them actually answer the question.

    Cross-language recall is supplied by query expansion and coverage candidates below;
    a reranker cannot recover paragraphs absent from its candidate pool.
    """
    if len(passages) <= 2 or os.environ.get('JUDGE_RETRIEVAL', '1') != '1':
        return passages[:keep]
    qs = {f'p{i}': {'type': 'choice',
                    'instructions': f'Reader asks: {q}\nDoes this passage from the book help answer that?\nPASSAGE: {x["t"][:1200]}',
                    'criteria': {'answers': 'Yes — it contains part of the answer, or the fact being asked about.',
                                 'related': 'Same topic or people, but it does not answer the question.',
                                 'unrelated': 'No.'}}
          for i, x in enumerate(passages)}
    try:
        ans = jev({'note': 'Judge each passage on its own.'}, qs)
    except Exception:
        return passages[:keep]
    scored = []
    for i, x in enumerate(passages):
        probs = (ans.get(f'p{i}') or {}).get('probabilities') or {}
        scored.append((probs.get('answers', 0) + 0.3 * probs.get('related', 0), x))
    scored.sort(key=lambda t: -t[0])
    picked = [x for sc, x in scored if sc >= 0.3][:keep] or [x for _sc, x in scored[:2]]
    return sorted(picked, key=lambda x: x['o'])


def retrieve(d: Path, book: dict, q: str, names: list[str], pos: int, k: int = 14) -> list[dict]:
    idx = _book_index(d, book)
    qg = _bigrams(q)
    for n in names:
        qg |= _bigrams(n)
    readable = []
    for o, t in idx:
        if o >= pos:
            continue
        if o + u16(t) > pos:
            t = t.encode('utf-16-le')[:(pos - o) * 2].decode('utf-16-le', errors='ignore')
        # Retain query hits, not every token of a potentially multi-million-word book.
        readable.append((o, t, _bigrams(t) & qg))
    if not readable:
        return []
    df = Counter()
    for _, _, g in readable:
        for x in qg & g:
            df[x] += 1
    N = len(readable)
    weight = {x: math.log(1 + N / (1 + df[x])) for x in qg}
    for n in names:
        for x in _bigrams(n):
            weight[x] = weight.get(x, 0) * 1.5
    scored = []
    for o, t, g in readable:
        hit = qg & g
        if not hit:
            continue
        # Float addition depends on order. A set's hash-seed order can change
        # the boundary passage and therefore the later judge/answer prompt.
        s = sum(weight[x] for x in sorted(hit)) / (1 + 0.002 * len(t))
        scored.append((s, o, t))
    scored.sort(reverse=True)
    # Empty overlap should not silently reduce an older-evidence question to the last page.
    # A bounded stratified fallback reaches earlier chapters; translation improves ranking.
    if len(scored) < k:
        seen = {o for _, o, _ in scored}
        slots = k - min(k, len(scored))
        candidates = [readable[round(i * (len(readable) - 1) / max(1, slots - 1))]
                      for i in range(min(slots, len(readable)))]
        scored += [(0, o, t) for o, t, _ in candidates if o not in seen]
    top = sorted(scored[:k], key=lambda x: x[1])
    out = []
    for _, o, t in top:
        if o + u16(t) > pos:     # the paragraph continues past the reader's page: cut it
            cut = pos - o
            t = t.encode('utf-16-le')[:cut * 2].decode('utf-16-le', errors='ignore')
        out.append({'o': o, 't': t})
    return out


def retrieval_query(question, book):
    """Translate search terms only, on an explicit reader request; never publish the result."""
    lang = book.get('lang') or 'zh'
    cjk_query = bool(re.search(r'[\u3040-\u30ff\u3400-\u9fff]', question))
    if (lang in ('zh', 'ja')) == cjk_query or os.environ.get('QUERY_TRANSLATION', '1') != '1':
        return question
    try:
        translated, _ = chat(QA_MODEL, [
            {'role': 'system', 'content': f'Translate the reader query into {lang} for lexical search. Return only the translated query. Do not answer it, add facts, or guess identities.'},
            {'role': 'user', 'content': question}], max_tokens=150, temperature=0,
            timeout=20, retries=0)
        return question + ' ' + translated.strip()[:600]
    except Exception:
        return question


PRONOUN = re.compile(r'^(他|她|它|他们|她们|它们|这人|那人|此人|对方|两人|二人|自己|'
                     r'he|him|his|she|her|they|them|it)$', re.I)


def who_is(book: dict, log: list, pos: int, start: int, end: int) -> dict:
    """Who a pronoun (or any word) in the text refers to, at this point in the book.

    Called when the reader taps a word, so it costs one judge call and only what they asked about.
    Candidates are the people the text has already introduced and used nearby — never anyone later.
    """
    world = fold(log, pos)
    people = world['people']
    if not people:
        return {'ok': False, 'why': 'nobody yet'}
    window = []
    left, right = max(0, start - 1500), min(pos, end + 200)
    for b in book['blocks']:
        if b['o'] + u16(b['t']) < left or b['o'] >= right:
            continue
        raw = b['t'].encode('utf-16-le')
        lo, hi = max(0, left - b['o']), min(len(raw) // 2, right - b['o'])
        if b['o'] <= start < end <= b['o'] + len(raw) // 2:
            a, z = start - b['o'], end - b['o']
            t = (raw[lo * 2:a * 2].decode('utf-16-le', errors='ignore') + '<selected>' +
                 raw[a * 2:z * 2].decode('utf-16-le', errors='ignore') + '</selected>' +
                 raw[z * 2:hi * 2].decode('utf-16-le', errors='ignore'))
        else:
            t = raw[lo * 2:hi * 2].decode('utf-16-le', errors='ignore')
        if t:
            window.append(t)
    passage = '\n'.join(window)
    word = ''
    for b in book['blocks']:
        if b['o'] <= start and b['o'] + u16(b['t']) >= end:
            raw = b['t'].encode('utf-16-le')
            word = raw[(start - b['o']) * 2:(end - b['o']) * 2].decode('utf-16-le', errors='ignore')
            break
    if not word or '<selected>' not in passage:
        return {'ok': False, 'why': '选中位置无效'}
    # who has the passage been talking about: the last people mentioned before this point
    def relevance(person):
        offsets = [passage.rfind(n) for n in [person['name']] + person['aliases'] if len(n) >= 2]
        local = max(offsets, default=-1)
        return (local >= 0, local, person['n'] + 40 * (person.get('imp', 1) >= 3))
    near = sorted(people.values(), key=relevance, reverse=True)
    cands = near[:12]
    if not cands:
        return {'ok': False, 'why': 'nobody yet'}
    crit = {p['id']: f"{p['name']}（{p.get('tagline') or p.get('bio', '')[:40]}）" for p in cands}
    crit['unknown'] = 'Someone the reader has not been introduced to yet, or not a person at all.'
    q = {'w': {'type': 'choice',
               'instructions': (f'In this_passage, who does 「{word}」 refer to at the exact occurrence marked <selected>...</selected>?'
                                if word else 'Who is the passage talking about at the end?'),
               'criteria': crit}}
    try:
        a = (jev({'this_passage': passage}, q) or {}).get('w') or {}
    except Exception as e:
        return {'ok': False, 'why': str(e)[:120]}
    choice = a.get('choice')
    p = round((a.get('probabilities') or {}).get(choice, 0), 3)
    if choice in people and p >= 0.45:
        return {'ok': True, 'id': choice, 'name': people[choice]['name'], 'p': p, 'word': word}
    return {'ok': False, 'why': 'unsure', 'p': p, 'word': word}


def recent_text(book: dict, pos: int, chars: int = 900) -> list[dict]:
    out, total = [], 0
    for b in reversed(book['blocks']):
        if b['o'] >= pos or b['k'] != 'p':
            continue
        t = b['t']
        if b['o'] + u16(t) > pos:
            t = t.encode('utf-16-le')[:(pos - b['o']) * 2].decode('utf-16-le', errors='ignore')
        out.append({'o': b['o'], 't': t})
        total += len(t)
        if total >= chars:
            break
    return list(reversed(out))


def answer(d: Path, q: str, pos: int, emit, cached_json):
    t0 = time.time()
    book = cached_json(d / 'book.json')
    kg = cached_json(d / 'kg.json') or {'log': []}
    st = cached_json(d / 'status.json') or {}
    frontier = st.get('frontier', 0)
    emit('stage', {'text': '理解你的问题'})
    try:
        route, probs = route_question(q)
    except Exception:
        route, probs = 'other', {}
    future = route == 'future' and probs.get('future', 0) >= 0.5
    emit('route', {'route': route, 'p': round(probs.get(route, 0), 2)})
    if future:
        text = ('后面的内容要继续读下去才知道；我现在不会透露或预测后续情节。' if
                re.search(r'[\u3400-\u9fff]', q) else
                'That concerns later pages. I will not reveal or predict events beyond your current position.')
        emit('answer', {'text': text, 'cites': [], 'route': route, 'guard': {'verdict': 'safe', 'reason': 'future'},
                        'people': [], 'position': pos, 'ms': int((time.time() - t0) * 1000)})
        return

    emit('stage', {'text': '翻阅你读过的部分'})
    world = fold(kg['log'], min(pos, frontier) if frontier else pos)
    people = world['people']
    # people named in the question (longest names first)
    named = []
    for p in sorted(people.values(), key=lambda p: -max(len(n) for n in [p['name']] + p['aliases'])):
        for n in [p['name']] + p['aliases']:
            if len(n) >= 2 and n in q and p not in named:
                named.append(p)
                break
    # graph expansion: "查理的第一任妻子" → follow 查理's edges whose role matches words in the question
    qgrams = _bigrams(q)
    for p in list(named):
        for r in world['rels'].values():
            if p['id'] not in (r['a'], r['b']):
                continue
            other_id = r['b'] if r['a'] == p['id'] else r['a']
            role = r['b_is'] if r['a'] == p['id'] else r['a_is']
            other = people.get(other_id)
            if other and other not in named and role and (_bigrams(role) & qgrams or role in q):
                named.append(other)
    if not named:
        named = sorted(people.values(), key=lambda p: -p['n'])[:3] if route in ('who', 'relation', 'recap') else []
    names = [n for p in named for n in [p['name']] + p['aliases']]
    search_query = retrieval_query(q, book)
    passages = rank_by_judge(q, retrieve(d, book, search_query, names, pos))
    recent = recent_text(book, pos)
    seen = {p['o'] for p in passages}
    passages += [r for r in recent if r['o'] not in seen]
    passages.sort(key=lambda x: x['o'])

    # ---- material
    parts = []
    if world['saga']:
        parts.append('【前情提要】\n' + world['saga'])
    for p in named[:5]:
        rel_lines = []
        for r in world['rels'].values():
            if p['id'] in (r['a'], r['b']):
                other = people[r['b'] if r['a'] == p['id'] else r['a']]
                role = r['b_is'] if r['a'] == p['id'] else r['a_is']
                status = r.get('status')
                timing = '过去的关系，已结束' if status == 'ended' else ('关系已经变化，以下是当前记录' if status == 'changed' else '截至已读位置')
                rel_lines.append(f"{other['name']}（{role}；{timing}）：{r.get('desc', '')}")
        evs = '；'.join(e['text'] for e in p['events'][-8:])
        attrs = '；'.join(f'{k}：{v}' for k, v in p['attrs'].items())
        parts.append(f"【人物：{p['name']}】又称：{'、'.join(dict.fromkeys(p['aliases'])) or '无'}\n{p['tagline']}。{p['bio']}\n"
                     f"档案：{attrs or '无'}\n关系：{'；'.join(rel_lines) or '无'}\n经历：{evs or '无'}")
    recent_events = [e['text'] for e in world['events'][-12:]]
    if recent_events:
        parts.append('【最近发生的事】\n' + '\n'.join('- ' + e for e in recent_events))
    cites = []
    for i, p in enumerate(passages, 1):
        parts.append(f'【原文{i}】{p["t"]}')
        cites.append({'n': i, 'o': p['o'], 'text': p['t'][:80]})
    material = '\n\n'.join(parts)
    ch = next((c for c in book['chapters'] if c['o0'] <= pos <= c['o1']), None)
    # Unread chapter titles can themselves state a future death or revelation.
    where = (f'第 {book["chapters"].index(ch) + 1} 章的当前位置' if ch else '当前位置')
    sys_prompt = SYSTEM.format(title=book['title'], where=where)
    user = f'【材料】\n{material}\n\n【读者的问题】{q}'
    if future:
        user += '\n\n（注意：读者在问还没读到的内容。先温和地说明这要读下去才知道，绝不做任何预测或暗示；再简要说说截至目前与此相关的已知情况。）'
    if frontier and pos > frontier:
        user += f'\n\n（说明：人物资料目前只整理到读者位置之前的一部分，原文材料是完整的。）'

    emit('stage', {'text': '组织回答'})
    msgs = [{'role': 'system', 'content': sys_prompt}, {'role': 'user', 'content': user}]
    text, _ = chat(QA_MODEL, msgs, max_tokens=1200, temperature=0.3, timeout=90, retries=0)
    text = text.strip()

    emit('stage', {'text': '检查有没有剧透'})
    guard = {}
    rejected = []

    def accepted(verdict):
        probability = verdict.get('p')
        return verdict.get('verdict') == 'ok' and isinstance(probability, (int, float)) and 0.4 <= probability <= 1

    try:
        v = guard_texts(material, {}, {'a': text}).get('a', {})
        guard = {'p': v.get('p'), 'verdict': v.get('verdict')}
        if not accepted(v):
            rejected.append({'text': text, 'guard': v})
            emit('stage', {'text': '发现可能超出已读内容的说法，正在重写'})
            msgs2 = msgs + [{'role': 'assistant', 'content': text},
                            {'role': 'user', 'content': '自动校验发现上面的回答里有材料没有提供的内容（可能是编造或后文剧透）。请严格只用材料重写回答，材料里没有的一律不说。'}]
            text2, _ = chat(QA_MODEL, msgs2, max_tokens=1200, temperature=0.2, timeout=90, retries=0)
            v2 = guard_texts(material, {}, {'a': text2}).get('a', {})
            guard = {'p': v2.get('p'), 'verdict': 'rewritten' if accepted(v2) else 'withheld',
                     'first': v.get('p')}
            if accepted(v2):
                text = text2.strip()
            else:
                rejected.append({'text': text2, 'guard': v2})
    except BrokenPipeError:
        raise
    except Exception:
        rejected.append({'text': text, 'guard': {'reason': 'verification_unavailable'}})
        guard = {'verdict': 'withheld', 'reason': 'verification_unavailable'}
    if guard.get('verdict') == 'withheld':
        text = ('这次回答未能通过已读原文核对，我暂时不展示它，以免透露后文或说错。你可以稍后重试，或回到相关原文查看。'
                if re.search(r'[\u3400-\u9fff]', q) else
                'I could not verify this answer against the pages you have read, so I have withheld it. Please retry later or check the relevant passage.')
        cites = []
    if rejected:
        # Local bounded audit; rejected prose never reaches the reader response.
        try:
            with _audit_lock:
                target = d.parent.parent / 'qa-audit' / (d.name + '.jsonl')
                target.parent.mkdir(parents=True, exist_ok=True)
                if target.exists() and target.stat().st_size > 1_000_000:
                    target.replace(target.with_suffix('.previous.jsonl'))
                import json
                with target.open('a', encoding='utf-8') as f:
                    f.write(json.dumps({'at': time.time(), 'position': pos, 'question': q,
                                        'rejected': rejected}, ensure_ascii=False) + '\n')
        except OSError:
            pass
    # house style: 「」 for quotes, only numeric source markers
    text = re.sub(r'"([^"\n]{1,80})"', r'「\1」', text)
    text = re.sub(r'“([^”\n]{1,80})”', r'「\1」', text)
    text = re.sub(r'\s*\[(?!\d+\])[^\]]{1,12}\]', '', text)
    # a 「quote」 must be verbatim from the passage it cites; otherwise it is a paraphrase
    src = {c['n']: re.sub(r'[\s，。、；：？！“”‘’「」…—]', '', passages[c['n'] - 1]['t']) for c in cites}

    def verify(m):
        body, n = m.group(1), m.group(2)
        plain = re.sub(r'[\s，。、；：？！“”‘’「」…—]', '', body)
        pool = src.get(int(n)) if n else ''.join(src.values())
        return (f'「{body}」' if plain and plain in (pool or '') else body) + (f'[{n}]' if n else '')
    text = re.sub(r'「([^」]{1,80})」\s*(?:\[(\d+)\])?', verify, text)
    used = sorted({int(n) for n in re.findall(r'\[(\d+)\]', text)})
    emit('answer', {'text': text, 'cites': [c for c in cites if c['n'] in used], 'route': route,
                    'guard': guard, 'people': [p['id'] for p in named[:5]], 'position': pos,
                    'ms': int((time.time() - t0) * 1000)})
