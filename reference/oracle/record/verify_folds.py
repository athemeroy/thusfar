"""Verify every committed 20-cutoff browser KG golden against its snapshot."""

from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FOLDS = ROOT / 'oracle/goldens/fold'
SNAPSHOTS = ROOT / 'oracle/corpus/snapshots'
RECORDED_BOOKS = ROOT / 'oracle/goldens/books'
RECORDER = ROOT / 'oracle/record/fold.mjs'


def verify() -> int:
    goldens = sorted(FOLDS.glob('*.jsonl'))
    if not goldens:
        raise RuntimeError('no browser fold goldens to verify')
    with tempfile.TemporaryDirectory(prefix='thusfar-fold-verify-') as directory:
        for golden in goldens:
            source = SNAPSHOTS / golden.stem
            if not (source / 'book.json').is_file():
                source = RECORDED_BOOKS / golden.stem
            for name in ('book.json', 'kg.json', 'status.json'):
                if not (source / name).is_file():
                    raise RuntimeError(f'{golden.name} has no snapshot {name}')
            rows = [json.loads(line) for line in golden.read_text(encoding='utf-8').splitlines()]
            if len(rows) != 20:
                raise RuntimeError(f'{golden.name}: expected 20 cutoffs, found {len(rows)}')
            cutoffs = [row['cutoff'] for row in rows]
            length = json.loads((source / 'book.json').read_text(encoding='utf-8'))['len']
            if (cutoffs[0] != 0 or cutoffs[-1] != length or
                    any(not isinstance(value, int) for value in cutoffs) or
                    any(a >= b for a, b in zip(cutoffs, cutoffs[1:]))):
                raise RuntimeError(f'{golden.name}: cutoffs are not 20 increasing book positions')
            regenerated = Path(directory) / golden.name
            subprocess.run(['node', str(RECORDER), str(source), str(regenerated)],
                           cwd=ROOT, check=True, capture_output=True, text=True,
                           timeout=30)
            if regenerated.read_bytes() != golden.read_bytes():
                raise RuntimeError(f'{golden.name}: browser fold differs from recorded bytes')
    return len(goldens)


def main() -> None:
    count = verify()
    print(f'{count} browser fold goldens each contain 20 byte-identical cutoffs')


if __name__ == '__main__':
    main()
