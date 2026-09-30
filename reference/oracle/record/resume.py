"""Record the 1.7.5 paused Aq fixture's offline continuation and cache reuse.

The receipt retains the exact JEV telemetry difference between a fresh run and
a resumed run. It does not erase that difference to claim byte equality.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
from collections import Counter
from pathlib import Path
from unittest.mock import patch

from .artifacts import one_pass, snapshot, stage_book
from .cassettes import CassetteStore
from .common import canonical, digest, require_reference_runtime, write_json
from .verify_book_artifacts import verify_book
from .verify_live_cassettes import verify as verify_cassettes

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'oracle/corpus/snapshots/aq_paused_annotated'
FRESH = ROOT / 'oracle/corpus/snapshots/aq_complete'
REFERENCE = ROOT / 'oracle/goldens/books/aq_deepseek'
CASSETTES = ROOT / 'oracle/cassettes/live'
GOLDEN = ROOT / 'oracle/goldens/resume/aq_paused_annotated.json'


def file_hashes(root: Path) -> dict[str, str]:
    if root.is_symlink() or any(path.is_symlink() for path in root.rglob('*')):
        raise ValueError('resume source contains a symlink')
    return {path.relative_to(root).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(root.rglob('*')) if path.is_file()}


def validate_outputs(fresh: dict, resumed: dict, changed: dict) -> None:
    """Allow only observed free-JEV accounting changes, preserving their values."""
    if fresh.keys() != resumed.keys():
        raise ValueError('resume changed the artifact file set')
    different = {name for name in fresh if fresh[name] != resumed[name]}
    if different != {'status.json', 'work/usage.json'} or set(changed) != different:
        raise ValueError('resume changed content outside the observed usage files')
    for name, pair in changed.items():
        before, after = (json.loads(canonical(pair[key])) for key in ('fresh', 'resumed'))
        if name == 'status.json':
            before, after = before['usage'], after['usage']
            # Check the surrounding status separately; no state or frontier exemption.
            left, right = (dict(pair[key]) for key in ('fresh', 'resumed'))
            left.pop('usage')
            right.pop('usage')
            if left != right:
                raise ValueError('resume changed status outside usage')
        if 'jev' not in before or 'jev' not in after or before['jev'] == after['jev']:
            raise ValueError('resume is missing the observed JEV accounting difference')
        before.pop('jev')
        after.pop('jev')
        if before != after:
            raise ValueError('resume changed paid-model accounting')


def validate_requests(runs: dict) -> dict:
    if set(runs) != {'fresh', 'prefix', 'resume'}:
        raise ValueError('request receipt must contain fresh, prefix and resume')
    counts = {}
    for name, run in runs.items():
        count = Counter()
        for row in run['requests']:
            if not isinstance(row, dict) or set(row) != {'sha256', 'kind', 'count'} \
                    or not isinstance(row['sha256'], str) \
                    or not re.fullmatch(r'[0-9a-f]{64}', row['sha256']) \
                    or row['kind'] not in ('model', 'jev') \
                    or type(row['count']) is not int or row['count'] < 1:
                raise ValueError('request receipt has an invalid row')
            key = (row['sha256'], row['kind'])
            if key in count:
                raise ValueError('request receipt has a duplicate digest/kind')
            count[key] = row['count']
        counts[name] = count
    if counts['fresh'] != counts['prefix'] + counts['resume']:
        raise ValueError('prefix and resume do not partition the fresh requests')
    if any(kind == 'model' for _, kind in counts['prefix'] & counts['resume']):
        raise ValueError('resume repeated a paid-model request from the cached prefix')
    return {name: {kind: sum(n for (_, k), n in count.items() if k == kind)
                   for kind in ('model', 'jev')} for name, count in counts.items()}


def validate_prefix(prefix: dict, source: dict, state: dict) -> None:
    if tuple(state.get(key) for key in ('state', 'done', 'total', 'frontier')) != \
            ('paused', 4, 9, 8835):
        raise ValueError('resume source is not the expected paused 4/9 frontier')
    expected = prefix['artifact_sha256']
    if set(expected) - set(source) != {'work/run.lock'} or set(source) - set(expected):
        raise ValueError('paused source differs from prefix artifact membership')
    if any(source[name] != expected[name] for name in source if name != 'status.json'):
        raise ValueError('paused source cache differs from the fresh prefix')
    running = dict(state, state='running')
    if running != prefix['usage_artifacts']['status.json']:
        raise ValueError('paused source differs from prefix status outside its state')


def capture(label: str, out: Path) -> None:
    if label not in ('fresh', 'prefix', 'resume'):
        raise ValueError('unknown resume recording pass')
    with tempfile.TemporaryDirectory(prefix='thusfar-resume-pass-') as scratch:
        temp = Path(scratch)
        book = temp / 'book'
        source = SOURCE if label == 'resume' else FRESH
        stage_book(source, book, 'resume' if label == 'resume' else 'fresh')
        before = file_hashes(book)
        requests = Counter()
        lock = threading.Lock()
        original = CassetteStore.next

        def traced(store, envelope):
            kind = 'jev' if envelope['url'] == 'https://classifier.dev/v1/classify' else 'model'
            with lock:
                requests[(digest(envelope), kind)] += 1
            return original(store, envelope)

        with patch.object(CassetteStore, 'next', traced):
            one_pass(book, CASSETTES, concurrency=1, limit=4 if label == 'prefix' else None)
        artifacts = temp / 'artifacts'
        hashes = snapshot(book, artifacts)
        after = file_hashes(book)
        preserved = {}
        if label == 'resume':
            for name in ('notebook.json', 'source.txt'):
                if before[name] != after[name]:
                    raise ValueError(f'resume changed {name}')
                preserved[name] = after[name]
        state = json.loads((artifacts / 'status.json').read_text())
        expected = ('running', 4, 9) if label == 'prefix' else ('done', 9, 9)
        if tuple(state.get(key) for key in ('state', 'done', 'total')) != expected:
            raise ValueError('resume recording did not reach its expected segment boundary')
        write_json(out, {
            'artifact_sha256': hashes,
            'requests': [{'sha256': sha, 'kind': kind, 'count': count}
                         for (sha, kind), count in sorted(requests.items())],
            'preserved_sha256': preserved,
            'usage_artifacts': {name: json.loads((artifacts / name).read_text())
                                for name in ('status.json', 'work/usage.json')},
        })


def build_receipt() -> dict:
    require_reference_runtime()
    original = file_hashes(SOURCE)
    manifest = json.loads((ROOT / 'oracle/corpus/manifest.json').read_text())['files']
    expected = {name.removeprefix('snapshots/aq_paused_annotated/'): entry['sha256']
                for name, entry in manifest.items() if name.startswith('snapshots/aq_paused_annotated/')}
    if original != expected or len(original) != 67:
        raise ValueError('paused Aq source differs from its corpus manifest')
    audit_path = ROOT / 'oracle/record/live-a0-audit.json'
    audit = json.loads(audit_path.read_text())
    if verify_cassettes(CASSETTES) != audit:
        raise ValueError('live cassette contents differ from the reviewed audit')
    verify_book(REFERENCE)
    reference = json.loads((REFERENCE / 'provenance.json').read_text())['artifact_sha256']
    pairs = []
    with tempfile.TemporaryDirectory(prefix='thusfar-resume-verify-') as scratch:
        source_artifacts = Path(scratch) / 'source'
        source_hashes = snapshot(SOURCE, source_artifacts)
        source_state = json.loads((source_artifacts / 'status.json').read_text())
        for seed in ('1', '982451653'):
            runs = {}
            for label in ('fresh', 'prefix', 'resume'):
                output = Path(scratch) / f'{seed}-{label}.json'
                result = subprocess.run(
                    [sys.executable, '-m', 'oracle.record.resume', '--capture', label, '--out', str(output)],
                    cwd=ROOT, env={**os.environ, 'PYTHONHASHSEED': seed},
                    capture_output=True, text=True, timeout=120)
                if result.returncode != 0:
                    raise RuntimeError(f'{label} resume pass failed; receipt not published')
                runs[label] = json.loads(output.read_text())
            if runs['fresh']['artifact_sha256'] != reference:
                raise ValueError('fresh replay differs from its committed book golden')
            validate_prefix(runs['prefix'], source_hashes, source_state)
            resumed = runs['resume']['artifact_sha256']
            changed = {name: {'fresh': runs['fresh']['usage_artifacts'][name],
                              'resumed': runs['resume']['usage_artifacts'][name]}
                       for name in reference if reference[name] != resumed.get(name)}
            validate_outputs(reference, resumed, changed)
            counts = validate_requests(runs)
            pairs.append({'runs': runs, 'request_counts': counts, 'changed_artifacts': changed})
    if canonical(pairs[0]) != canonical(pairs[1]):
        raise ValueError('independent resume recordings differ')
    if file_hashes(SOURCE) != original:
        raise ValueError('recording changed the input fixture')
    return {'schema': 1, 'source': 'Python 1.7.5 paused fixture; offline cassette replay',
            'concurrency': 1, 'independent_passes': 2, 'source_sha256': original,
            'cassette_audit_sha256': hashlib.sha256(audit_path.read_bytes()).hexdigest(),
            **pairs[0]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    choices = parser.add_mutually_exclusive_group(required=True)
    choices.add_argument('--write', action='store_true')
    choices.add_argument('--verify', action='store_true')
    choices.add_argument('--capture', choices=('fresh', 'prefix', 'resume'), help=argparse.SUPPRESS)
    parser.add_argument('--out', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    require_reference_runtime()
    if args.capture:
        if args.out is None:
            parser.error('--capture requires --out')
        capture(args.capture, args.out)
        return
    result = build_receipt()
    if args.write:
        if GOLDEN.exists():
            raise FileExistsError('resume receipt exists; review before replacing it')
        write_json(GOLDEN, result)
    elif GOLDEN.read_bytes() != (canonical(result) + '\n').encode('utf-8'):
        raise ValueError('committed resume receipt differs from independent replay')
    print('Verified paused Aq 4/9 to 9/9 twice: 152 identical artifacts, notebook preserved, '
          '8 cached model requests not repeated; exact JEV usage differences retained')


if __name__ == '__main__':
    main()
