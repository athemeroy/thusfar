"""Replay one book twice from the same cassettes and publish byte-identical artifacts."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from .cassettes import install
from .common import UnsafeValue, canonical, known_secrets, write_json
from .functions import LoopbackOnly

ROOT = Path(__file__).resolve().parents[2]
_TIME_KEYS = {'updated', 'started', 'finished', 'created', 'exported',
              '_secs', '_ttft', 'seconds', 'timing'}
_TOP = ('book.json', 'kg.json', 'status.json')


def without_times(value):
    if isinstance(value, dict):
        return {key: without_times(item) for key, item in value.items() if key not in _TIME_KEYS}
    if isinstance(value, list):
        return [without_times(item) for item in value]
    return value


def files_for(root: Path):
    for name in _TOP:
        path = root / name
        if path.is_file():
            yield path
    for dirname in ('work', 'mentions'):
        directory = root / dirname
        if directory.is_dir():
            yield from sorted(path for path in directory.rglob('*') if path.is_file())


def snapshot(root: Path, out: Path) -> dict[str, str]:
    secrets = known_secrets()
    hashes = {}
    for source in files_for(root):
        if source.is_symlink():
            raise UnsafeValue(f'symlink in book artifacts: {source.relative_to(root)}')
        rel = source.relative_to(root)
        target = out / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        if source.suffix == '.json':
            obj = without_times(json.loads(source.read_text(encoding='utf-8')))
            data = (canonical(obj) + '\n').encode('utf-8')
        else:
            data = source.read_bytes()
        if any(secret.encode() in data for secret in secrets):
            raise UnsafeValue(f'credential-like data in {rel}')
        target.write_bytes(data)
        hashes[str(rel)] = hashlib.sha256(data).hexdigest()
    required = {'book.json', 'kg.json', 'status.json'}
    if not required.issubset(hashes) or not any(name.startswith('work/') for name in hashes):
        raise ValueError(f'incomplete book replay artifacts: missing {sorted(required - hashes.keys())}')
    return hashes


def stage_book(source: Path, target: Path, start: str) -> None:
    if start == 'resume':
        shutil.copytree(source, target, symlinks=False)
        return
    target.mkdir()
    for name in ('book.json', 'meta.json'):
        path = source / name
        if path.is_file():
            shutil.copy2(path, target / name)
    for path in source.iterdir():
        if path.is_file() and path.name.startswith('source.'):
            shutil.copy2(path, target / path.name)
    for dirname in ('img',):
        path = source / dirname
        if path.is_dir():
            shutil.copytree(path, target / dirname, symlinks=False)


def replay(source: Path, cassette_dir: Path, out: Path, start: str, repeat: int,
           concurrency: int) -> dict[str, str]:
    if repeat < 2:
        raise ValueError('at least two replays are required before publishing')
    if not (source / 'book.json').is_file():
        raise ValueError('source book directory has no book.json')
    runs = []
    with tempfile.TemporaryDirectory(prefix='thusfar-artifacts-') as temp:
        tmp = Path(temp)
        for index in range(repeat):
            book = tmp / f'book-{index}'
            stage_book(source, book, start)
            subprocess.run([sys.executable, '-m', 'oracle.record.artifacts', '--one-pass',
                            str(book), '--cassettes', str(cassette_dir.resolve()),
                            '--concurrency', str(concurrency)], cwd=ROOT, check=True)
            artifact_dir = tmp / f'artifacts-{index}'
            hashes = snapshot(book, artifact_dir)
            runs.append((artifact_dir, hashes))
        reference = runs[0][1]
        for index, (_, hashes) in enumerate(runs[1:], 2):
            if hashes != reference:
                changed = sorted(set(reference) ^ set(hashes) |
                                 {name for name in reference.keys() & hashes.keys()
                                  if reference[name] != hashes[name]})
                raise ValueError(f'book replay {index} differs in: {", ".join(changed)}')
        if out.exists():
            raise FileExistsError(f'output exists: {out}')
        shutil.copytree(runs[0][0], out)
        write_json(out / 'provenance.json', {
            'schema': 1, 'source': 'deepseek-flash+nothink cassette replay',
            'source_snapshot': source.name, 'book_start': start,
            'passes': repeat, 'artifact_sha256': reference})
        return reference


def historical_cache(source: Path, out: Path, repeat: int) -> dict[str, str]:
    """Publish existing 1.7.x results without pretending that model wire cassettes exist."""
    if repeat < 2:
        raise ValueError('at least two baseline captures are required before publishing')
    if out.exists():
        raise FileExistsError(f'output exists: {out}')
    with tempfile.TemporaryDirectory(prefix='thusfar-historical-cache-') as temp:
        outputs = []
        for index in range(repeat):
            target = Path(temp) / str(index)
            hashes = snapshot(source, target)
            outputs.append((target, hashes))
        reference = outputs[0][1]
        if any(other != reference for _, other in outputs[1:]):
            raise ValueError('historical cache changed between captures')
        shutil.copytree(outputs[0][0], out)
    usage = source / 'work/usage.json'
    models = sorted((json.loads(usage.read_text(encoding='utf-8')).get('by_model') or {})) if usage.is_file() else []
    original = {str(path.relative_to(source)): hashlib.sha256(path.read_bytes()).hexdigest()
                for path in files_for(source)}
    write_json(out / 'provenance.json', {
        'schema': 1, 'source': '1.7.x cache', 'source_snapshot': source.name,
        'source_models': models, 'passes': repeat, 'original_sha256': original,
        'artifact_sha256': reference,
        'normalizations': sorted(_TIME_KEYS)})
    return reference


def one_pass(book: Path, cassette_dir: Path, concurrency: int) -> None:
    names = ('LLM_BASE_URL', 'LLM_BASE_URL_OPENAI', 'LLM_PROTOCOL', 'LLM_PROTOCOL_MAP',
             'LLM_KEY_NAME', 'LLM_KEY_MAP', 'ORACLE_REPLAY_KEY', 'JEV_ROUTE',
             'CLASSIFIER_URL', 'JUDGE_LOG_DIR', 'JUDGE_LOG', 'RECAP_MODEL')
    previous = {name: os.environ.get(name) for name in names}
    model = 'deepseek-flash+nothink'
    os.environ.update(LLM_BASE_URL='https://open.xiaojingai.com/v1',
                      LLM_BASE_URL_OPENAI='', LLM_PROTOCOL='openai', LLM_PROTOCOL_MAP='',
                      LLM_KEY_NAME='ORACLE_REPLAY_KEY', LLM_KEY_MAP='',
                      ORACLE_REPLAY_KEY='oracle-placeholder', JEV_ROUTE='free-only',
                      CLASSIFIER_URL='https://classifier.dev/v1/classify',
                      JUDGE_LOG_DIR=str(book / 'work' / 'judge'), JUDGE_LOG='0',
                      RECAP_MODEL=model)
    try:
        from pipeline.run import run_book
        with LoopbackOnly(), install(cassette_dir, 'replay') as tape:
            run_book(book, model=model, local_model=model, concurrency=concurrency)
        if tape.count == 0:
            raise ValueError('cassette replay consumed no model or JEV responses')
    finally:
        for name, value in previous.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == '--one-pass':
        inner = argparse.ArgumentParser(description='internal isolated cassette replay pass')
        inner.add_argument('--one-pass', dest='book', type=Path, required=True)
        inner.add_argument('--cassettes', type=Path, required=True)
        inner.add_argument('--concurrency', type=int, default=12)
        args = inner.parse_args()
        one_pass(args.book, args.cassettes, args.concurrency)
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('book', type=Path)
    parser.add_argument('--mode', choices=('historical-cache', 'cassette-replay'), required=True)
    parser.add_argument('--cassettes', type=Path, default=ROOT / 'oracle/cassettes')
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--start', choices=('fresh', 'resume'), default='fresh')
    parser.add_argument('--repeat', type=int, default=2)
    parser.add_argument('--concurrency', type=int, default=12)
    args = parser.parse_args()
    hashes = (historical_cache(args.book, args.out, args.repeat)
              if args.mode == 'historical-cache' else
              replay(args.book, args.cassettes, args.out, args.start, args.repeat, args.concurrency))
    print(f'{len(hashes)} book artifact files match across {args.repeat} {args.mode} passes')


if __name__ == '__main__':
    main()
