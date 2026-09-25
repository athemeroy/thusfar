"""Fail before committing an oracle tree that contains a known credential or auth header."""
from __future__ import annotations

import argparse
import base64
import json
from pathlib import Path

from .common import UnsafeValue, assert_public, known_secrets


def inspect_value(value, secrets: tuple[str, ...], path: Path) -> None:
    if isinstance(value, dict):
        if 'request_sha256' in value and isinstance(value.get('attempts'), list):
            attempts = value['attempts']
            if any(isinstance(attempt, dict) and attempt.get('kind') == 'pending'
                   for attempt in attempts):
                raise UnsafeValue(f'unfinished cassette request in {path}')
            if len(attempts) > 1 and any(attempt != attempts[0] for attempt in attempts[1:]):
                raise UnsafeValue(f'ambiguous repeated cassette request in {path}')
        for key, item in value.items():
            if key.lower() in ('authorization', 'proxy-authorization', 'x-api-key', 'x-goog-api-key'):
                raise UnsafeValue(f'authentication header in {path}')
            if key == 'chunks_base64':
                raw = b''.join(base64.b64decode(chunk, validate=True) for chunk in item)
                assert_public(raw.decode('utf-8', 'replace'), secrets)
            elif key.endswith('_base64') or key == '$bytes':
                raw = base64.b64decode(item, validate=True)
                assert_public(raw.decode('utf-8', 'replace'), secrets)
            else:
                inspect_value(item, secrets, path)
    elif isinstance(value, list):
        for item in value:
            inspect_value(item, secrets, path)
    elif isinstance(value, str):
        assert_public(value, secrets)


def scan(root: Path) -> int:
    secrets = known_secrets()
    count = 0
    for path in sorted(root.rglob('*')):
        if not path.is_file() or path.suffix not in ('.json', '.jsonl'):
            continue
        try:
            if path.suffix == '.json':
                inspect_value(json.loads(path.read_text(encoding='utf-8')), secrets, path)
            else:
                for line in path.read_text(encoding='utf-8').split('\n'):
                    if line:
                        inspect_value(json.loads(line), secrets, path)
        except (UnsafeValue, ValueError) as exc:
            raise UnsafeValue(f'oracle scan rejected {path.relative_to(root)}: {type(exc).__name__}') from exc
        count += 1
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('roots', type=Path, nargs='+')
    args = parser.parse_args()
    count = sum(scan(root) for root in args.roots)
    print(f'scanned {count} JSON/JSONL oracle files; no known credentials found')


if __name__ == '__main__':
    main()
