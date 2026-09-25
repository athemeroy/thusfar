"""Compare Aq's single-worker and default-worker Python oracle replays offline."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from .artifacts import one_pass, snapshot, stage_book
from .common import canonical, require_reference_runtime, write_json
from .resume import file_hashes
from .verify_book_artifacts import verify_book

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'oracle/corpus/snapshots/aq_complete'
REFERENCE = ROOT / 'oracle/goldens/books/aq_deepseek'
CASSETTES = ROOT / 'oracle/cassettes/live'
GOLDEN = ROOT / 'oracle/goldens/concurrency/aq.json'
WORKERS = (1, 12)
SEEDS = ('1', '982451653')


def capture(workers: int, output: Path) -> None:
    if workers not in WORKERS:
        raise ValueError('only the baseline and production default are covered')
    with tempfile.TemporaryDirectory(prefix='thusfar-concurrency-pass-') as scratch:
        temporary = Path(scratch)
        book = temporary / 'book'
        stage_book(SOURCE, book, 'fresh')
        one_pass(book, CASSETTES, concurrency=workers)
        normalized = temporary / 'normalized'
        hashes = snapshot(book, normalized)
        state = json.loads((normalized / 'status.json').read_text())
        if tuple(state.get(key) for key in ('state', 'done', 'total', 'frontier')) != \
                ('done', 9, 9, 21733):
            raise ValueError('concurrency replay did not complete Aq')
        write_json(output, {'workers': workers, 'artifact_sha256': hashes})


def validate_runs(runs: list[dict], reference: dict[str, str]) -> None:
    expected = [(seed, workers) for seed in SEEDS for workers in WORKERS]
    if [(run.get('hash_seed'), run.get('workers')) for run in runs] != expected:
        raise ValueError('concurrency receipt must contain all four independent runs')
    for run in runs:
        if set(run) != {'hash_seed', 'workers', 'artifact_sha256'}:
            raise ValueError('unexpected concurrency receipt fields')
        if run['artifact_sha256'] != reference:
            raise ValueError('concurrency replay differs from the full committed artifact set')


def build_receipt() -> dict:
    require_reference_runtime()
    original = file_hashes(SOURCE)
    manifest = json.loads((ROOT / 'oracle/corpus/manifest.json').read_text())['files']
    expected = {name.removeprefix('snapshots/aq_complete/'): entry['sha256']
                for name, entry in manifest.items() if name.startswith('snapshots/aq_complete/')}
    if original != expected:
        raise ValueError('Aq source differs from its corpus manifest')
    verify_book(REFERENCE)
    reference = json.loads((REFERENCE / 'provenance.json').read_text())['artifact_sha256']
    runs = []
    with tempfile.TemporaryDirectory(prefix='thusfar-concurrency-verify-') as scratch:
        for seed in SEEDS:
            for workers in WORKERS:
                output = Path(scratch) / f'{seed}-{workers}.json'
                result = subprocess.run(
                    [sys.executable, '-m', 'oracle.record.concurrency', '--capture', str(workers),
                     '--out', str(output)], cwd=ROOT,
                    env={**os.environ, 'PYTHONHASHSEED': seed},
                    capture_output=True, timeout=120)
                if result.returncode:
                    raise RuntimeError(f'offline Aq replay failed for seed {seed}, workers {workers}')
                runs.append({'hash_seed': seed, **json.loads(output.read_text())})
    validate_runs(runs, reference)
    if file_hashes(SOURCE) != original:
        raise ValueError('concurrency replay changed its source fixture')
    source_paths = sorted([*ROOT.glob('pipeline/*.py'), *ROOT.glob('server/*.py')])
    return {'schema': 1, 'source': 'Python 1.7.5 Aq; offline cassette replay',
            'scope': 'Aq only; no default-concurrency claim for the other four books',
            'source_sha256': original,
            'production_sha256': {path.relative_to(ROOT).as_posix():
                                  hashlib.sha256(path.read_bytes()).hexdigest()
                                  for path in source_paths},
            'artifact_count': len(reference), 'runs': runs}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--write', action='store_true')
    action.add_argument('--verify', action='store_true')
    action.add_argument('--capture', type=int, choices=WORKERS, help=argparse.SUPPRESS)
    parser.add_argument('--out', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    require_reference_runtime()
    if args.capture is not None:
        if args.out is None:
            parser.error('--capture requires --out')
        capture(args.capture, args.out)
        return
    receipt = build_receipt()
    if args.write:
        if GOLDEN.exists():
            raise FileExistsError('concurrency receipt exists; review before replacing it')
        write_json(GOLDEN, receipt)
    elif GOLDEN.read_bytes() != (canonical(receipt) + '\n').encode():
        raise ValueError('committed concurrency receipt differs from independent replay')
    print(f'Aq: {receipt["artifact_count"]} artifacts match at workers 1 and 12, '
          'two independent hash seeds each; other books remain outside this claim')


if __name__ == '__main__':
    main()
