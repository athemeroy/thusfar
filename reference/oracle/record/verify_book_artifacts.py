"""Check committed book artifacts against their recorded SHA-256 provenance."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path, PurePosixPath


BOOKS = Path(__file__).resolve().parents[1] / 'goldens/books'
EXCLUDED = {'provenance.json', 'fold.jsonl'}
SHA256 = re.compile(r'[0-9a-f]{64}\Z')


def _digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(block)
    return digest.hexdigest()


def verify_book(book: Path) -> int:
    if book.is_symlink() or not book.is_dir():
        raise RuntimeError(f'book artifact is not a regular directory: {book}')
    provenance_path = book / 'provenance.json'
    if provenance_path.is_symlink() or not provenance_path.is_file():
        raise RuntimeError(f'missing regular provenance.json: {book}')
    provenance = json.loads(provenance_path.read_text(encoding='utf-8'))
    expected = provenance.get('artifact_sha256')
    if not isinstance(expected, dict) or not expected:
        raise RuntimeError(f'missing artifact_sha256 map: {book}')

    for name, digest in expected.items():
        if (not isinstance(name, str) or not name or '\\' in name or
                PurePosixPath(name).is_absolute() or
                any(part in ('.', '..') for part in name.split('/')) or
                PurePosixPath(name).as_posix() != name or name in EXCLUDED or
                not isinstance(digest, str) or not SHA256.fullmatch(digest)):
            raise RuntimeError(f'invalid artifact_sha256 entry: {book}: {name!r}')

    actual = {}
    for path in book.rglob('*'):
        name = path.relative_to(book).as_posix()
        if path.is_symlink():
            raise RuntimeError(f'symlink in book artifacts: {book}: {name}')
        if path.is_file():
            if name not in EXCLUDED:
                actual[name] = path
        elif not path.is_dir():
            raise RuntimeError(f'non-regular book artifact: {book}: {name}')

    missing = sorted(expected.keys() - actual.keys())
    extra = sorted(actual.keys() - expected.keys())
    if missing or extra:
        raise RuntimeError(f'book artifact file set differs: {book}: '
                           f'missing={missing}, extra={extra}')
    for name, path in sorted(actual.items()):
        if _digest(path) != expected[name]:
            raise RuntimeError(f'book artifact SHA-256 differs: {book}: {name}')
    return len(actual)


def verify(books: Path = BOOKS) -> tuple[int, int]:
    if not books.is_dir():
        raise RuntimeError(f'book golden directory is missing: {books}')
    entries = sorted(books.iterdir())
    if not entries:
        raise RuntimeError(f'no book artifact goldens: {books}')
    count = 0
    for book in entries:
        count += verify_book(book)
    return len(entries), count


def main() -> None:
    books, files = verify()
    print(f'{books} book artifact goldens: {files} SHA-256 hashes and exact file sets verified')


if __name__ == '__main__':
    main()
