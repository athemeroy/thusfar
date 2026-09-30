"""Check that retiring the old distribution keeps current regression inputs intact."""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = ROOT / 'reference'
RETIRED = (
    'Dockerfile', 'docker-compose.yml', '.dockerignore', '.env.example',
    'requirements.txt', 'android', 'android_bootstrap.py', 'pipeline', 'server',
    'web', 'oracle', 'tests', 'testsets', 'NOTES.md', 'STATUS.md', 'docs/port',
)


def check() -> None:
    for name in RETIRED:
        if (ROOT / name).exists():
            raise ValueError(f'Retired distribution path returned: {name}')
    # Literal fixture paths are relative to the package test working directory.
    checked = 0
    for package in ('app', 'core'):
        for source in (ROOT / package / 'test').rglob('*.dart'):
            text = source.read_text()
            for match in re.finditer(r"['\"]\.\./(oracle|pipeline|server|tests|docs/port|web)(?:/|['\"])", text):
                raise ValueError(f'Old reference locator in {source.relative_to(ROOT)}: {match[0]}')
            for match in re.finditer(r"['\"](\.\./reference/[^'\"]+)['\"]", text):
                name = match[1]
                # Dynamic suffixes select fixture cases; their existing parent
                # directory must still be present after the move.
                if '$' in name:
                    name = name.split('$', 1)[0].rsplit('/', 1)[0]
                if not (ROOT / package / name).exists():
                    raise ValueError(f'Missing test input {name} in {source.relative_to(ROOT)}')
                checked += 1
    for fixture, source in (
        ('core/test/jobs/fixtures/worker_oracles.json', 'server/jobs.py'),
        ('core/test/link/fixtures/oracles.json', 'pipeline/link.py'),
        ('core/test/ask/fixtures/python_ask.json', 'server/ask.py'),
        ('core/test/marginalia/fixtures/oracles.json', 'server/marginalia.py'),
    ):
        proof = json.loads((ROOT / fixture).read_text())
        observed = hashlib.sha256((REFERENCE / source).read_bytes()).hexdigest()
        if proof['source_sha256'] != observed:
            raise ValueError(f'Frozen source bytes changed: {source}')
    for name in ('app/lib/main_web.dart', 'app/web/prepare_offline.py',
                 'app/android/app/build.gradle.kts', 'core/pubspec.yaml'):
        if not (ROOT / name).is_file():
            raise ValueError(f'Current client input is missing: {name}')
    print(f'Reference layout verified: {checked} Dart fixture locators, four source hashes, current client inputs')


if __name__ == '__main__':
    check()
