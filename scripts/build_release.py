"""Create a content-addressed, credential-free runtime snapshot after validation.

This command never changes a running container, source checkout, or book directory.
The operator switches only the Yedu service to the returned immutable path.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
from datetime import datetime, timezone

PARTS = ('pipeline', 'server', 'web', 'scripts', 'requirements.txt', '.env.example', 'LICENSE')
IGNORED = {'__pycache__', '.pytest_cache', '.DS_Store'}


def inventory(source: Path) -> list[dict]:
    source = source.resolve()
    files = []
    for name in PARTS:
        root = source / name
        if root.is_symlink():
            raise ValueError(f'Runtime symlinks are not allowed: {name}')
        if not root.exists():
            if name in ('pipeline', 'server', 'web'):
                raise ValueError(f'Missing runtime directory: {name}')
            continue
        for path in ([root] if root.is_file() else sorted(root.rglob('*'))):
            rel = path.relative_to(source)
            if any(p in IGNORED for p in rel.parts) or path.suffix in ('.pyc', '.tmp'):
                continue
            if path.is_symlink():
                raise ValueError(f'Runtime symlinks are not allowed: {rel}')
            if not path.is_file():
                continue
            if path.name in ('.env', 'secrets.env') or path.suffix in ('.key', '.jks'):
                raise ValueError(f'Unexpected private file in runtime: {rel}')
            data = path.read_bytes()
            files.append({'path': rel.as_posix(), 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
    return sorted(files, key=lambda x: x['path'])


def fingerprint(files: list[dict]) -> str:
    return hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def stamp_shell(source: Path) -> str:
    """Make every web asset change install a new worker, without discarding books."""
    source = source.resolve()
    files = [dict(row) for row in inventory(source)
             if row['path'].startswith('web/') and not row['path'].startswith('web/download/')]
    worker = source / 'web/sw.js'
    text = worker.read_text()
    pattern = re.compile(r"^const SHELL = (['\"])yedu-shell-[^'\"]+\1;$", re.MULTILINE)
    normalized, count = pattern.subn("const SHELL = 'yedu-shell-CONTENT';", text)
    if count != 1:
        raise ValueError('Expected one service-worker shell identity')
    for row in files:
        if row['path'] == 'web/sw.js':
            content = normalized.encode()
            row.update(bytes=len(content), sha256=hashlib.sha256(content).hexdigest())
    shell = 'yedu-shell-' + fingerprint(files)[:20]
    stamped = pattern.sub(f"const SHELL = '{shell}';", text)
    if stamped != text:
        temporary = worker.with_suffix('.stamp.tmp')
        temporary.write_text(stamped)
        temporary.chmod(worker.stat().st_mode & 0o777)
        temporary.replace(worker)
    return shell


def verify_release(release: Path) -> dict:
    manifest = json.loads((release / 'release.json').read_text())
    if manifest.get('format') != 'yedu-release/1':
        raise ValueError('Unsupported release manifest')
    if inventory(release) != manifest['files'] or fingerprint(manifest['files']) != manifest['source_sha256']:
        raise ValueError('Release content does not match its manifest')
    mountpoint = release / 'data'
    if mountpoint.is_symlink() or not mountpoint.is_dir() or any(mountpoint.iterdir()):
        raise ValueError('Release requires an empty data mountpoint, without user data')
    return manifest


def build(source: Path, releases: Path, validation: Path) -> tuple[Path, bool]:
    files = inventory(source)
    digest = fingerprint(files)
    proof = json.loads(validation.read_text())
    if proof.get('ok') is not True or proof.get('source_sha256') != digest:
        raise ValueError('Passing validation for this exact runtime source is required')
    release_id = 'yedu-' + digest[:16]
    releases.mkdir(parents=True, exist_ok=True)
    target = releases / release_id
    if target.exists():
        manifest = verify_release(target)
        if manifest['source_sha256'] != digest:
            raise ValueError('Conflicting release identifier')
        return target, False
    temporary = Path(tempfile.mkdtemp(prefix='.release-', dir=releases))
    try:
        for entry in files:
            src = source / entry['path']
            dst = temporary / entry['path']
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            if hashlib.sha256(dst.read_bytes()).hexdigest() != entry['sha256']:
                raise ValueError('Source changed while copying: ' + entry['path'])
        if inventory(source) != files:
            raise ValueError('Runtime source changed after validation')
        manifest = {'format': 'yedu-release/1', 'id': release_id, 'source_sha256': digest,
                    'created_at': datetime.now(timezone.utc).isoformat(), 'files': files,
                    'validation_sha256': hashlib.sha256(validation.read_bytes()).hexdigest()}
        (temporary / 'release.json').write_text(json.dumps(manifest, indent=2) + '\n')
        # The nested data bind must exist before /app is mounted read-only.
        # Docker cannot create /app/data through a read-only parent bind.
        (temporary / 'data').mkdir()
        verify_release(temporary)
        # Do not permit later edits to a live bind-mounted release by accident.
        for p in temporary.rglob('*'):
            if p.is_file():
                p.chmod(0o555 if os.access(p, os.X_OK) else 0o444)
        for p in sorted(temporary.rglob('*'), reverse=True):
            if p.is_dir():
                p.chmod(0o555)
        temporary.chmod(0o555)
        temporary.rename(target)
        return target, True
    finally:
        if temporary.exists():
            temporary.chmod(0o755)
            for p in temporary.rglob('*'):
                if p.is_dir():
                    p.chmod(0o755)
            shutil.rmtree(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--releases', type=Path, required=True)
    parser.add_argument('--validation', type=Path, required=True)
    args = parser.parse_args()
    path, created = build(args.source.resolve(), args.releases.resolve(), args.validation.resolve())
    print(json.dumps({'release': str(path), 'created': created, 'id': path.name}, ensure_ascii=False))


if __name__ == '__main__':
    main()
