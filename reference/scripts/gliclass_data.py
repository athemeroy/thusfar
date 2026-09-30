"""Turn the judged decisions into GLiClass training data.

usage: python3 scripts/gliclass_data.py judge.jsonl OUT_DIR [--max-chars 1500] [--tasks a,b]

GLiClass trains on {text, prompt, all_labels, true_labels}. Two things make it a good fit for what
we have:

  * `true_labels` may be a dict of scores rather than a list of names, so the model learns Jev's
    whole probability distribution instead of only its argmax. Our thresholds (0.35/0.5/0.7/0.9)
    are calibrated on those numbers, so a model that copies only the winner could not take Jev's
    seat even at 100% agreement.
  * labels are free text, so our option descriptions can be the labels themselves.

Measured in our judge experiments: wording the options as natural English sentences
separates the classes three times better than our code identifiers, and Chinese labels do worse
than English ones even on Chinese text — so the label a model sees is the English description, not
the key our pipeline uses. `labels.json` keeps the way back.
"""
from __future__ import annotations

import argparse
import json
import random
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from export_judge_data import focus  # noqa: E402  (one windowing rule, used in both places)

# Options our code names but does not describe in a sentence. Everything else uses its own
# description, which is already an English sentence written for the judge.
PHRASES = {
    'supported': 'the passage supports this',
    'not_in_passage': 'the passage does not mention this',
    'contradicted': 'the passage says the opposite',
    'yes': 'yes',
    'no': 'no',
    'none': 'none of these',
    'other': 'something else',
    'unknown': 'there is no way to tell',
}
WORDS = re.compile(r'\s+')


def phrase_of(key: str, desc: str, words: int = 16) -> str:
    """The label as the model should see it: a short English sentence."""
    if key in PHRASES:
        return PHRASES[key]
    desc = (desc or '').strip().rstrip('.')
    if desc:
        parts = WORDS.split(desc)
        if len(parts) > words:
            desc = ' '.join(parts[:words])
        # a description that opens with an example list is clearer cut at the bracket
        return desc.split(' (')[0][:160]
    return key.replace('_', ' ').replace('-', ' ')


def labels_of(options: dict) -> tuple[list[str], dict]:
    """(labels as the model sees them, label -> our key). Collisions keep the key visible so two
    options never collapse into one."""
    seen, out, back = Counter(), [], {}
    for k, v in options.items():
        p = phrase_of(k, v)
        seen[p] += 1
        if seen[p] > 1 or p in back:
            p = f'{k.replace("_", " ")}: {p}'[:160]
        out.append(p)
        back[p] = k
    return out, back


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('data', type=Path)
    ap.add_argument('out', type=Path)
    ap.add_argument('--max-chars', type=int, default=1500)
    ap.add_argument('--tasks', default=None, help='comma-separated; default: every task')
    ap.add_argument('--min-options', type=int, default=2)
    ap.add_argument('--cap-per-task', type=int, default=0,
                    help='at most N training rows per task (0 = no cap). Our data is 76%% '
                         'record-support, which is the cheapest task to ask Jev and the easiest '
                         'to learn; capping it spends the training budget where the cost is.')
    ap.add_argument('--max-per-class', type=int, default=0,
                    help='at most N training rows per (task, answer). This is the one that matters: '
                         '94%% of record-support answers are "supported", so a model that always '
                         'says "supported" scores 94%% and has learned nothing — which is exactly '
                         'what the first run did (docs/LOCAL-JUDGE.md).')
    ap.add_argument('--grey-boost', type=int, default=1,
                    help='repeat rows where Jev itself was unsure (top probability 0.3-0.7) this '
                         'many times. They are the rows worth having a judge for at all, and the '
                         'first model scored 33%% on them against 91%% where Jev was sure.')
    ap.add_argument('--seed', type=int, default=7)
    a = ap.parse_args()
    keep = set(a.tasks.split(',')) if a.tasks else None

    a.out.mkdir(parents=True, exist_ok=True)
    buckets: dict[str, list] = {'train': [], 'dev': [], 'test': []}
    vocab: dict[str, str] = {}
    tasks, dropped = Counter(), Counter()
    for line in a.data.open():
        try:
            r = json.loads(line)
        except Exception:
            continue
        opts, probs = r.get('options') or {}, r.get('probabilities') or {}
        if keep and r.get('task') not in keep:
            continue
        if len(opts) < a.min_options or not probs or not r.get('passage'):
            dropped[r.get('task', '?')] += 1
            continue
        labels, back = labels_of(opts)
        vocab.update(back)
        # Jev's full distribution, not just its pick. Options it never scored are zeros, which is
        # what it meant: it was asked about them and did not choose them.
        true = {lab: round(float(probs.get(key, 0.0)), 4) for lab, key in back.items()}
        if max(true.values(), default=0) <= 0:
            dropped[r.get('task', '?')] += 1
            continue
        buckets[r.get('split', 'train')].append({
            # cut around what the question is about, never from the start: a head-truncated
            # passage can leave the people being asked about outside the text entirely
            'text': focus(r['passage'], r['instructions'], a.max_chars // 2, cap=a.max_chars),
            'prompt': r['instructions'],
            'all_labels': labels,
            'true_labels': true,
            'task': r.get('task'),
            'book': r.get('book'),
            # kept for balancing, stripped before writing: GLiClass ignores extra keys, but these
            # are ours and should not look like part of its format
            'answer': r.get('choice'),
            'grey': 0.3 <= max(true.values()) <= 0.7,
        })
        tasks[r.get('task', '?')] += 1

    # Everything below reshapes the TRAINING split only. dev and test keep the natural mix, or the
    # score would be measured on a distribution the product never sees.
    rng = random.Random(a.seed)
    if a.max_per_class or a.cap_per_task or a.grey_boost > 1:
        rng.shuffle(buckets['train'])

    if a.max_per_class:
        seen, kept = Counter(), []
        for r in buckets['train']:
            key = (r['task'], r['answer'])
            if seen[key] >= a.max_per_class:
                continue
            seen[key] += 1
            kept.append(r)
        print(f'  按(任务,答案)封顶 {a.max_per_class}: train {len(buckets["train"])} → {len(kept)}')
        buckets['train'] = kept

    if a.grey_boost > 1:
        extra = [r for r in buckets['train'] if r['grey'] for _ in range(a.grey_boost - 1)]
        print(f'  灰区加权 x{a.grey_boost}: +{len(extra)} 条')
        buckets['train'] += extra
        rng.shuffle(buckets['train'])

    if a.cap_per_task:
        seen, kept = Counter(), []
        for r in buckets['train']:
            if seen[r['task']] >= a.cap_per_task:
                continue
            seen[r['task']] += 1
            kept.append(r)
        print(f'  按任务封顶 {a.cap_per_task}: train {len(buckets["train"])} → {len(kept)}')
        buckets['train'] = kept

    for name, rows in buckets.items():
        clean = [{k: v for k, v in r.items() if k not in ('answer', 'grey')} for r in rows]
        (a.out / f'{name}.json').write_text(json.dumps(clean, ensure_ascii=False))
    (a.out / 'labels.json').write_text(json.dumps(vocab, ensure_ascii=False, indent=1))
    print(f'{sum(len(v) for v in buckets.values())} 条 → {a.out}')
    print('  ' + '  '.join(f'{k}={len(v)}' for k, v in buckets.items()))
    print('  按任务:', dict(tasks.most_common(8)))
    if dropped:
        print('  跳过（选项不足 / 没有概率）:', dict(dropped.most_common(5)))
    print(f'  标签词表 {len(vocab)} 个 → {a.out / "labels.json"}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
