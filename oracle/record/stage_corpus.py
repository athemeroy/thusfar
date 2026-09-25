"""Stage one verified public-domain parser fixture as a fresh pipeline source book.

The source and parse golden are checked-in A0 inputs. This command performs no model
or network calls and refuses an existing destination.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path

from .common import require_reference_runtime, write_json

ROOT = Path(__file__).resolve().parents[2]
CORPUS = ROOT / 'oracle/corpus'
PARSED = ROOT / 'oracle/goldens/parsed'
PARSER = ROOT / 'pipeline/parse.py'
BOOKS = {
    'aq': 'books/aq.txt',
    'jekyll': 'books/jekyll.txt',
    'french': 'books/un_coeur_simple.txt',
    'kokoro': 'books/kokoro_aozora.txt',
    'rulin': 'books/rulin_first_200k.txt',
}


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def checked_file(path: Path) -> bytes:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'fixture is absent or is a symlink: {path.name}')
    return path.read_bytes()


def stage_public_book(book_id: str, out: Path, *, corpus: Path = CORPUS,
                      parsed: Path = PARSED) -> dict:
    require_reference_runtime()
    if book_id not in BOOKS:
        raise ValueError(f'unknown public-domain book: {book_id}')
    if out.exists() or out.is_symlink():
        raise FileExistsError(f'staged book already exists: {out}')
    out = out.resolve(strict=False)
    if out.exists() or out.is_symlink():
        raise FileExistsError(f'staged book already exists: {out}')
    if out.is_relative_to(corpus.resolve()) or out.is_relative_to(parsed.resolve()):
        raise ValueError('staging inside the frozen oracle inputs is forbidden')

    source_rel = BOOKS[book_id]
    source_bytes = checked_file(corpus / source_rel)
    manifest_bytes = checked_file(corpus / 'manifest.json')
    manifest = json.loads(manifest_bytes)
    source_row = manifest['files'].get(source_rel)
    if manifest['sources'][book_id]['output'] != source_rel or source_row != {
            'bytes': len(source_bytes), 'sha256': sha(source_bytes)}:
        raise ValueError(f'corpus manifest mismatch for {source_rel}')

    case_id = source_rel.replace('/', '__')
    parsed_bytes = checked_file(parsed / case_id / 'book.json')
    report_bytes = checked_file(parsed / 'report.json')
    report = json.loads(report_bytes)
    cases = [row for row in report['cases'] if row['input'] == source_rel]
    if (len(cases) != 1 or cases[0]['output'] != case_id or
            cases[0]['outcome'] != 'parsed' or cases[0]['sha256'] != sha(source_bytes) or
            report['parser_sha256'] != sha(checked_file(PARSER))):
        raise ValueError(f'parser golden provenance mismatch for {source_rel}')

    from pipeline.parse import parse_file
    with tempfile.TemporaryDirectory(prefix='thusfar-stage-parse-') as temp:
        actual = parse_file(corpus / source_rel, Path(temp) / 'book')
    regenerated = (json.dumps(actual, ensure_ascii=False, separators=(',', ':')) + '\n').encode('utf-8')
    if regenerated != parsed_bytes:
        raise ValueError(f'parser golden bytes differ from current Python parser for {source_rel}')
    case = cases[0]
    if (case['blocks'], case['chapters'], case['notes'], case['utf16_length']) != (
            len(actual['blocks']), len(actual['chapters']), len(actual['notes']), actual['len']):
        raise ValueError(f'parser golden counts differ from report for {source_rel}')

    provenance = {
        'schema': 1, 'source': 'checked-in public-domain corpus and Python 3.11 parser golden',
        'book_id': book_id, 'corpus_path': f'oracle/corpus/{source_rel}',
        'corpus_manifest_sha256': sha(manifest_bytes),
        'source_sha256': sha(source_bytes), 'source_bytes': len(source_bytes),
        'parsed_report_sha256': sha(report_bytes), 'parser_sha256': report['parser_sha256'],
        'book_json_sha256': sha(parsed_bytes), 'parsed_case': case_id,
        'model_calls': 0, 'network_calls': 0,
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.thusfar-stage-', dir=out.parent) as temp:
        staged = Path(temp) / 'book'
        staged.mkdir()
        (staged / 'source.txt').write_bytes(source_bytes)
        (staged / 'book.json').write_bytes(parsed_bytes)
        write_json(staged / '.oracle-stage.json', provenance)
        if sha((staged / 'source.txt').read_bytes()) != provenance['source_sha256'] or \
                sha((staged / 'book.json').read_bytes()) != provenance['book_json_sha256']:
            raise RuntimeError('staged bytes changed before publication')
        if out.exists() or out.is_symlink():
            raise FileExistsError(f'staged book appeared during verification: {out}')
        os.rename(staged, out)
    return provenance


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('book', choices=sorted(BOOKS))
    parser.add_argument('--out', type=Path, required=True, help='new source-book directory')
    args = parser.parse_args()
    proof = stage_public_book(args.book, args.out)
    print(f'staged {proof["book_id"]}: {proof["source_bytes"]} source bytes; '
          f'book.json SHA-256 {proof["book_json_sha256"]}; no model or network calls')


if __name__ == '__main__':
    main()
