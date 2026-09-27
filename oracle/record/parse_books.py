"""Record Python 3.11 parse_file outputs for the frozen A0 corpus."""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
CORPUS = REPO / 'oracle/corpus'
EXPECTED = REPO / 'oracle/record/expected_rejections.json'
PARSER = REPO / 'pipeline/parse.py'


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def files(root: Path) -> dict[str, bytes]:
    return {str(path.relative_to(root)): path.read_bytes()
            for path in sorted(root.rglob('*')) if path.is_file()}


def single(out: Path) -> None:
    if sys.version_info[:2] != (3, 11):
        raise RuntimeError('Python 3.11 oracle required')
    sys.path.insert(0, str(REPO))
    from pipeline.parse import parse_file
    manifest = json.loads((CORPUS / 'manifest.json').read_text(encoding='utf-8'))
    expected = json.loads(EXPECTED.read_text(encoding='utf-8'))
    report = {'schema': 1, 'source': 'Python 1.7.5 parse_file, parser-only; no model',
              'python': sys.version.split()[0], 'parser_sha256': sha(PARSER),
              'cases': []}
    for source in sorted(list((CORPUS / 'books').glob('*')) + list((CORPUS / 'synthetic').glob('*'))):
        if not source.is_file() or source.suffix.lower() not in ('.txt', '.epub'):
            continue
        rel = str(source.relative_to(CORPUS))
        if rel not in manifest['files'] or sha(source) != manifest['files'][rel]['sha256']:
            raise RuntimeError(f'corpus manifest mismatch: {rel}')
        case_id = rel.replace('/', '__')
        case_dir = out / case_id
        case_dir.mkdir(parents=True)
        entry = {'input': rel, 'sha256': sha(source), 'output': case_id}
        try:
            book = parse_file(source, case_dir)
        except Exception as exc:
            want = expected.get(rel)
            if not want or type(exc).__name__ != want.get('type') or str(exc) != want.get('message'):
                raise RuntimeError(f'unexpected parser rejection for {rel}: {type(exc).__name__}: {exc}') from exc
            error = {'type': type(exc).__name__, 'message': str(exc)}
            (case_dir / 'error.json').write_text(json.dumps(error, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
            entry['outcome'] = 'expected_rejection'
        else:
            if rel in expected:
                raise RuntimeError(f'{rel} should reject')
            (case_dir / 'book.json').write_text(json.dumps(book, ensure_ascii=False, separators=(',', ':')) + '\n', encoding='utf-8')
            entry['outcome'] = 'parsed'
            entry['blocks'] = len(book['blocks'])
            entry['chapters'] = len(book['chapters'])
            entry['notes'] = len(book['notes'])
            entry['utf16_length'] = book['len']
        report['cases'].append(entry)
    (out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--single', type=Path)
    parser.add_argument('--out', type=Path, default=REPO / 'oracle/goldens/parsed')
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    if args.single:
        single(args.single)
        return
    with tempfile.TemporaryDirectory(prefix='thusfar-parse-record-') as tmp:
        pass1, pass2 = Path(tmp) / 'one', Path(tmp) / 'two'
        for path in (pass1, pass2):
            subprocess.run([sys.executable, __file__, '--single', str(path)], check=True,
                           cwd=REPO)
        actual = files(pass1)
        if actual != files(pass2):
            raise RuntimeError('two independent parser recordings differ byte-for-byte')
        if args.out.exists():
            if actual != files(args.out):
                raise RuntimeError('existing parser goldens differ; inspect before replacing')
        elif args.verify:
            raise RuntimeError('parser goldens do not exist')
        else:
            shutil.copytree(pass1, args.out)
        print(f'{len(json.loads(actual["report.json"])["cases"])} corpus inputs, '
              f'{len(actual)} files, two byte-identical Python 3.11 recordings')


if __name__ == '__main__':
    main()
