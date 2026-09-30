"""Collect every judged decision into one training set, for distilling a model of our own.

usage: python3 scripts/export_judge_data.py OUT.jsonl [--books data/books] [--captured-only]

Two sources:
  work/judge/*.jsonl  — questions exactly as asked, with the judge's full probabilities (new runs)
  work/local, work/segs — decisions recorded before that logging existed, rebuilt from what is stored

Every row: {task, book, genre, lang, passage, instructions, options, choice, probabilities}.
Books are kept apart in the split, so a test book never trains the model that is judged on it.
"""
import hashlib
import json
import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pipeline.extract import seg_text, segments  # noqa: E402


def state_text(state) -> str:
    """The judge's state as the judge sees it.

    This has to match `pipeline.llm._state_text` exactly. Dumping the state as JSON instead would
    train the model on `{"this_passage": "…"}` while serving it `[this_passage]\n…` — a difference
    the model has no way to know is cosmetic, and one that is invisible in every metric until the
    thing is deployed.
    """
    if isinstance(state, str):
        return state
    parts = []
    for k, v in (state or {}).items():
        body = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
        parts.append(f'[{k}]\n{body}')
    return '\n\n'.join(parts)


RUN_LABEL = re.compile(r'[（(].*?[)）]|\s*作者[:：].*$|\s+[-—]\s+[^-—]*$')


def work_of(title: str) -> str:
    """Which book this is, ignoring how the run was labelled.

    Re-runs are stored as separate directories with names like "包法利夫人（关系树 v11）"; for the
    purpose of keeping train and test apart they are all one book.
    """
    return RUN_LABEL.sub('', title or '').strip().lower() or (title or '').strip().lower()


def canonical_work(title: str, aliases: dict | None = None) -> str:
    work = work_of(title)
    seen = set()
    while work in (aliases or {}):
        if work in seen:
            raise ValueError(f'作品别名形成循环：{title}')
        seen.add(work)
        work = work_of(aliases[work])
    return work


def decision_id(instructions: str, passage: str, options: dict) -> str:
    # Prefix-only hashes merged questions whose evidence differs after character 200/400.
    payload = json.dumps([instructions, passage, options], ensure_ascii=False, sort_keys=True)
    return hashlib.sha256(payload.encode()).hexdigest()


def read_log(path: Path):
    """Snapshot append-only logs; only an unfinished final write may be ignored."""
    raw = path.read_bytes()
    lines = raw.splitlines(keepends=True)
    for i, line in enumerate(lines, 1):
        if i == len(lines) and not line.endswith(b'\n'):
            print(f'日志末行尚未写完，本次跳过：{path}', file=sys.stderr)
            break
        try:
            yield json.loads(line)
        except (ValueError, UnicodeError) as e:
            raise ValueError(f'{path}:{i}: 日志损坏') from e


def validate_row(r: dict) -> None:
    if not isinstance(r.get('passage'), str) or not r['passage'].strip():
        raise ValueError(f'判断缺少原文：{r.get("book")} {r.get("task")}')
    opts, probs, choice = r.get('options'), r.get('probabilities'), r.get('choice')
    if not isinstance(opts, dict) or not opts or choice not in opts:
        raise ValueError(f'判断标签不在选项中：{r.get("book")} {choice!r}')
    if not isinstance(probs, dict) or not probs or choice not in probs or not sum(probs.values()) or any(
            k not in opts or type(v) not in (int, float) or not math.isfinite(v) or not 0 <= v <= 1
            for k, v in probs.items()):
        raise ValueError(f'判断概率无效：{r.get("book")} {r.get("task")}')


ANCHOR = re.compile(r'「([^」]{1,40})」|CLAIM:\s*(.{4,160})')


def shared(claim: str, passage: str, least: int = 3) -> list[str]:
    """The longest stretches of the claim that appear verbatim in the passage.

    A claim is written by the extractor in its own words ("泰勒教授指出金钱只不过是一种实现目标的手段"),
    so looking for the whole sentence finds nothing. What does appear are the pieces it was built
    from — the names and the phrases it borrowed — and those are exactly the lines worth keeping.
    """
    out, i, n = [], 0, len(claim)
    while i < n:
        best = 0
        for j in range(i + least, n + 1):
            if passage.find(claim[i:j]) < 0:
                break
            best = j
        if best:
            out.append(claim[i:best])
            i = best
        else:
            i += 1
    return out


def anchors(instructions: str, passage: str = '') -> list[str]:
    """The pieces of text a question is actually about: the names it quotes, and whatever of the
    claim can be found in the passage."""
    out = []
    for quoted, claim in ANCHOR.findall(instructions or ''):
        if quoted:
            out.append(quoted)
        if claim:
            out.extend(shared(claim.strip(), passage) if passage else [claim])
    return [t for t in out if len(t) >= 2]


def focus(passage: str, instructions: str, radius: int, cap: int = 12000) -> str:
    """The passage narrowed to what the question is about.

    A judge asked "are A and B kin?" needs the lines where A and B appear, not four thousand
    characters of scenery. Trimming does not save much money — the label tree, not the passage,
    is most of what we send — but a model we train ourselves has to fit the passage in memory,
    so the training set is where the narrowing belongs. Windows are merged and kept in order, and
    a question whose anchors appear nowhere keeps the head of the passage rather than nothing.
    """
    if radius <= 0 or len(passage) <= radius * 2:
        return passage[:cap]
    spans = []
    for term in anchors(instructions, passage):
        start = 0
        while True:
            i = passage.find(term, start)
            if i < 0:
                break
            spans.append((max(0, i - radius), min(len(passage), i + len(term) + radius)))
            start = i + len(term)
            if len(spans) > 200:
                break
    if not spans:
        # nothing to narrow around: keep the whole passage rather than an arbitrary opening slice —
        # a truncated passage silently turns a supported claim into an unsupported one
        return passage[:cap]
    spans.sort()
    merged = [list(spans[0])]
    for a, b in spans[1:]:
        if a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    parts = [passage[a:b] for a, b in merged]
    text = '……'.join(parts)
    if len(text) > cap and radius > 40:
        # Two people mentioned far apart make two windows that together overflow the budget, and
        # cutting the tail drops the second person entirely — the question then asks about someone
        # who is not in the text. Narrow every window instead, so each anchor keeps its share.
        return focus(passage, instructions, radius // 2, cap)
    return text[:cap]


def task_of(instructions: str) -> str:
    t = instructions.lower()
    for needle, name in (('what kind of tie', 'relation-family'), ('what kind of link', 'relation-family'),
                         ('judge the note', 'note-support'),
                         ('which character does the marked mention', 'mention'),
                         ('how is this presented', 'critical'),
                         ('what exactly is b to a', 'relation-role'), ('how do', 'relation-stance'),
                         ('still hold', 'relation-state'), ('claim:', 'record-support'),
                         ('the same person', 'identity'), ('is the name', 'alias'),
                         ('which already-known character', 'link'), ('narrate this as a fact', 'critical'),
                         ('give away', 'title-spoiler'), ('how much does this', 'importance'),
                         ('does this passage help answer', 'retrieval'), ('who does', 'pronoun'),
                         ('what kind of book', 'book-kind'), ('which part of the book', 'chapter-kind'),
                         ('describes the situation as it stands now', 'attr-current'),
                         ('same character recorded twice', 'dedupe')):
        if needle in t:
            return name
    return 'other'


def from_logs(d: Path, meta: dict, rows: list, radius: int = 0) -> int:
    logs = d / 'work' / 'judge'
    if not (logs / 'questions.jsonl').exists():
        return 0
    # Questions first: states for this snapshot were written before their questions.
    questions = list(read_log(logs / 'questions.jsonl'))
    states = {x['h']: state_text(x['state']) for x in read_log(logs / 'states.jsonl')}
    n = 0
    for q in questions:
        if not q.get('probabilities'):
            continue
        if q['state'] not in states:
            raise ValueError(f'{logs}: 问题引用了不存在的原文 {q["state"]}')
        original = states[q['state']]
        # Labels belong to this complete captured request. A zero-radius export
        # must not inherit focus()'s historical 12,000-character cap.
        passage = original if radius <= 0 else focus(original, q['instructions'], radius)
        row = {**meta, 'task': task_of(q['instructions']),
                     'passage': passage,
                     'instructions': q['instructions'], 'options': q['criteria'],
                     'choice': q['choice'], 'probabilities': q['probabilities'], 'source': 'log',
                     'teacher_model': q.get('model'), 'state_hash': q['state'],
                     'context_exact': passage == original,
                     'original_passage_sha256': hashlib.sha256(original.encode()).hexdigest(),
                     'teacher_input_sha256': decision_id(q['instructions'], original, q['criteria'])}
        validate_row(row)
        rows.append(row)
        n += 1
    return n


def from_records(d: Path, meta: dict, rows: list, radius: int = 0) -> int:
    """Rebuild the questions from what older runs stored (answers only, one probability each)."""
    book_path = d / 'book.json'
    if not book_path.exists():
        return 0
    book = json.loads(book_path.read_text())
    segs = segments(book, [i for i, c in enumerate(book['chapters']) if c.get('kind') == 'body'])
    n = 0
    incomplete = 0
    for f in sorted((d / 'work' / 'local').glob('*.json')):
        try:
            rec = json.loads(f.read_text())
        except Exception:
            continue
        i = rec.get('seg')
        if i is None or i >= len(segs) or not (rec.get('support') or rec.get('judge_rels')):
            continue
        passage = seg_text(book, segs[i])[:12000]
        data = rec.get('data') or {}
        names = {str(p.get('id')): (p.get('name') or '').lstrip('*') for p in data.get('people', [])}
        for k, v in (rec.get('support') or {}).items():
            kind = {'e': 'event', 'a': 'attr', 'r': 'rel'}.get(k[0])
            idx = int(k[1:]) if k[1:].isdigit() else None
            src = {'event': 'events', 'attr': 'facts', 'rel': 'rels'}.get(kind)
            if idx is None or not src or idx >= len(data.get(src, [])):
                continue
            x = data[src][idx]
            claim = (x.get('text') if kind == 'event' else
                     f"{names.get(str(x.get('who')), '?')}｜{x.get('key')}：{x.get('value')}" if kind == 'attr' else
                     f"{names.get(str(x.get('b')), '?')} 是 {names.get(str(x.get('a')), '?')} 的{x.get('b_is')}")
            probs = v.get('probs') or {'supported': v.get('p', 0)}
            if v.get('choice') not in probs or not sum(probs.values()):
                # Early caches saved only P(supported), even when another label won.
                # Such a partial distribution cannot reconstruct the teacher's answer.
                incomplete += 1
                continue
            ask = f'Judging only this_passage: is this supported? CLAIM: {claim}'
            rows.append({**meta, 'task': 'record-support', 'passage': focus(passage, ask, radius),
                         'instructions': ask,
                         'options': {'supported': '', 'not_in_passage': '', 'contradicted': ''},
                         'choice': v.get('choice'), 'probabilities': probs, 'source': 'record'})
            n += 1
        for pair, v in (rec.get('judge_rels') or {}).items():
            a, b = pair.split('|', 1)
            if isinstance(v, (list, tuple)):        # the first shape: (role, probability)
                v = {'ties': [{'family': '?', 'role': v[0], 'p': v[1]}]} if len(v) == 2 else {'ties': []}
            for t in v.get('ties', []):
                if not t.get('p'):
                    incomplete += 1
                    continue
                ask = (f"In this_passage, what is 「{names.get(b, b)}」 to 「{names.get(a, a)}」? "
                       f"(tie family: {t['family']})")
                rows.append({**meta, 'task': 'relation-role', 'passage': focus(passage, ask, radius),
                             'instructions': ask,
                             'options': {t['role']: ''}, 'choice': t['role'],
                             'probabilities': {t['role']: t['p']}, 'source': 'record'})
                n += 1
    if incomplete:
        print(f'{d.name}：跳过 {incomplete} 条旧缓存不完整的概率记录', file=sys.stderr)
    return n


def main():
    out = Path(sys.argv[1])
    books = Path(sys.argv[sys.argv.index('--books') + 1] if '--books' in sys.argv else 'data/books')
    # --window N keeps N characters either side of what each question is about (0 = whole passage)
    radius = int(sys.argv[sys.argv.index('--window') + 1]) if '--window' in sys.argv else 0
    captured_only = '--captured-only' in sys.argv
    rows: list = []
    per_book, titles = {}, {}
    for d in sorted(books.glob('*/')):
        if not (d / 'book.json').exists():
            continue
        book = json.loads((d / 'book.json').read_text())
        meta = {'book': d.name, 'title': book.get('title', ''), 'genre': book.get('genre', 'novel'),
                'lang': book.get('lang', 'zh')}
        n = from_logs(d, meta, rows, radius)
        if not captured_only:
            n += from_records(d, meta, rows, radius)
        if n:
            per_book[d.name] = n
            titles[d.name] = book.get('title', '') or d.name
    # Split by work, not by directory. The same book is re-run under a new directory every time the
    # pipeline changes, so splitting on the directory puts 包法利夫人 v9 in test and v8/v10/v11 in
    # train — the same passages on both sides, and an evaluation that measures memorisation.
    split_path = out.parent / 'splits.json'
    held = json.loads(split_path.read_text())  # A missing split contract must never train on everything.
    aliases = held.get('aliases', {})
    work = {b: canonical_work(t, aliases) for b, t in titles.items()}
    named = {}
    for sp in ('test', 'dev'):
        for title in held.get(sp, []):
            w = canonical_work(title, aliases)
            if w in named and named[w] != sp:
                raise ValueError(f'作品同时位于 dev/test：{title}')
            named[w] = sp
    for r in rows:
        r['split'] = named.get(work.get(r['book'], ''), 'train')
        r['work'] = work[r['book']]
    unplaced = sorted({work[b] for b in work if work[b] not in named})
    if unplaced:
        print('未列入 splits.json，按 train 处理:', '、'.join(t[:20] for t in unplaced))

    # The same book re-run under a new pipeline asks the same questions again; keep one row per
    # question so a book that happens to have been re-run five times does not weigh five times more.
    seen, kept = set(), []
    # Prefer held-out copies if identical full inputs were stored under different titles.
    rows.sort(key=lambda r: {'test': 0, 'dev': 1, 'train': 2}[r['split']])
    for r in rows:
        validate_row(r)
        k = decision_id(r['instructions'], r['passage'], r['options'])
        if k in seen:
            continue
        seen.add(k)
        kept.append(r)
    if len(kept) < len(rows):
        print(f'去重：{len(rows)} → {len(kept)} 条（重跑产生的同一问题只留一条）')
    rows[:] = kept
    tmp = out.with_suffix(out.suffix + '.tmp')
    with tmp.open('w') as f:
        for r in rows:
            r['id'] = decision_id(r['instructions'], r['passage'], r['options'])
            f.write(json.dumps(r, ensure_ascii=False) + '\n')
    tmp.replace(out)
    from collections import Counter
    tasks, splits, grey = Counter(), Counter(), 0
    for r in rows:
        tasks[r['task']] += 1
        splits[r['split']] += 1
        top = max(r['probabilities'].values()) if r['probabilities'] else 1
        grey += 0.3 <= top <= 0.7
    print(f'{len(rows)} 条 → {out}')
    print('按任务:', dict(tasks.most_common()))
    print('按划分:', dict(splits))
    print(f'灰区（最高概率 0.3–0.7）: {grey}（{grey / max(1, len(rows)) * 100:.0f}%）')
    print('按书:', dict(sorted(per_book.items(), key=lambda x: -x[1])[:8]))
    composition = {sp: {
        'records': sum(r['split'] == sp for r in rows),
        'languages': dict(Counter(r['lang'] for r in rows if r['split'] == sp)),
        'works': dict(Counter(r['work'] for r in rows if r['split'] == sp)),
        'tasks': dict(Counter(r['task'] for r in rows if r['split'] == sp)),
    } for sp in ('train', 'dev', 'test')}
    out.with_suffix('.summary.json').write_text(json.dumps({
        'split_sha256': hashlib.sha256(split_path.read_bytes()).hexdigest(),
        'composition': composition, 'records': len(rows),
        'captured_only': captured_only, 'export_window': radius,
        'exact_context_rows': sum(r.get('context_exact') is True for r in rows),
    }, ensure_ascii=False, indent=2) + '\n')
    for sp, comp in composition.items():
        print(f'{sp}：{comp["records"]} 条，{len(comp["works"])} 部作品，语言 {comp["languages"]}')


if __name__ == '__main__':
    main()
