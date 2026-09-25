"""Verify ordinary function goldens, report counts, and explicit tree provenance.

The original A0 provenance used an undocumented tree digest. Verification requires the
documented algorithm below; use --tree-sha only to calculate the digest for a new,
independently double-recorded function tree before publishing its provenance.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

from .common import digest
from .functions import included_functions

ROOT = Path(__file__).resolve().parents[2]
GOLDENS = ROOT / 'oracle/goldens'
INVENTORY = ROOT / 'docs/port/inventory.json'
TREE_ALGORITHM = 'sha256(sorted POSIX relative path UTF-8 + NUL + raw SHA-256 file digest bytes)'
IDENTIFIER = re.compile(r'[A-Za-z_][A-Za-z_0-9]*\Z')
SHA256 = re.compile(r'[0-9a-f]{64}\Z')
MAXIMUM = 200
RECORDING_INPUT_PATTERNS = (
    'pipeline/**/*.py', 'server/**/*.py', 'tests/**/*',
    'oracle/record/*.py', 'oracle/record/manual.jsonl',
    'oracle/record/expected_rejections.json', 'oracle/record/live-a0-audit.json',
    'oracle/corpus/*.py', 'oracle/corpus/manifest.json',
    'oracle/corpus/books/**/*', 'oracle/corpus/synthetic/**/*',
    'oracle/corpus/snapshots/**/*', 'oracle/cassettes/live/**/*.json',
    'oracle/cassettes/synthetic/**/*.json', 'oracle/semantics/**/*',
    'docs/port/inventory.json', 'scripts/*.py', 'web/**/*',
    # These are unittest inputs, not the ordinary function outputs being verified.
    'oracle/goldens/parsed/**/*', 'oracle/goldens/special/**/*',
    'oracle/goldens/http/**/*', 'oracle/goldens/books/**/*',
    'oracle/goldens/fold/**/*', 'oracle/goldens/resume/**/*',
    'oracle/goldens/concurrency/**/*',
)


def _fail(reason: str) -> None:
    raise ValueError('function golden verification failed: ' + reason)


def _file(path: Path) -> bytes:
    if path.is_symlink() or not path.is_file():
        _fail('a required function golden, report, or provenance file is absent or linked')
    return path.read_bytes()


def _json(path: Path):
    try:
        return json.loads(_file(path))
    except (UnicodeError, json.JSONDecodeError):
        _fail('a function report or provenance JSON is malformed')


def _function_path(function: str) -> Path:
    if not isinstance(function, str):
        _fail('function ID is not text')
    parts = function.split('.')
    if len(parts) < 3 or parts[0] not in ('pipeline', 'server') \
            or any(not IDENTIFIER.fullmatch(part) for part in parts):
        _fail('function ID has an unsafe or unreviewed path')
    return Path(*parts[:-1], parts[-1] + '.jsonl')


def _ordinary_file_set(goldens: Path) -> set[Path]:
    found = set()
    for dirname in ('pipeline', 'server'):
        base = goldens / dirname
        if base.is_symlink() or not base.is_dir():
            _fail('ordinary function golden directory is missing or linked')
        for path in base.rglob('*'):
            if path.is_symlink():
                _fail('ordinary function golden tree contains a symlink')
            if path.is_file():
                if path.suffix != '.jsonl':
                    _fail('ordinary function golden tree contains an unreviewed file')
                found.add(path.relative_to(goldens))
            elif not path.is_dir():
                _fail('ordinary function golden tree contains a non-regular entry')
    return found


def tree_sha256(files: dict[Path, bytes]) -> str:
    """Hash relative POSIX path, NUL, then the raw 32-byte SHA-256 of file bytes."""
    outer = hashlib.sha256()
    for relative, content in sorted(files.items(), key=lambda item: item[0].as_posix()):
        name = relative.as_posix()
        if not name or '\\' in name or '\x00' in name or relative.is_absolute() \
                or any(part in ('.', '..') for part in relative.parts):
            _fail('tree digest received an unsafe relative path')
        outer.update(name.encode('utf-8'))
        outer.update(b'\0')
        outer.update(hashlib.sha256(content).digest())
    return outer.hexdigest()


def audit_recording_inputs(root: Path = ROOT) -> dict:
    """Fingerprint the exact local files that can affect the formal workload.

    The selection deliberately omits the ordinary function golden tree, its report,
    its provenance, Dart sources, and documentation. It includes non-function
    goldens because Python unittests read and compare those fixtures.
    """
    if root.is_symlink() or not root.is_dir():
        _fail('recording input root is missing or linked')
    paths: set[Path] = set()
    for pattern in RECORDING_INPUT_PATTERNS:
        for candidate in root.glob(pattern):
            if candidate.is_symlink():
                _fail('recording input contains a symlink')
            if candidate.is_file() and '__pycache__' not in candidate.relative_to(root).parts \
                    and candidate.suffix not in ('.pyc', '.pyo'):
                paths.add(candidate.relative_to(root))
    if not paths:
        _fail('recording input set is empty')
    ordered = sorted(paths, key=lambda path: path.as_posix())
    files = {path: _file(root / path) for path in ordered}
    return {
        'patterns': list(RECORDING_INPUT_PATTERNS),
        'paths': [path.as_posix() for path in ordered],
        'file_count': len(files),
        'tree_algorithm': TREE_ALGORITHM,
        'tree_sha256': tree_sha256(files),
    }


def audit_files(goldens: Path = GOLDENS, inventory: Path | None = None) -> dict:
    """Check the report and exact ordinary tree without trusting provenance metadata."""
    if goldens.is_symlink() or not goldens.is_dir():
        _fail('function golden root is missing or linked')
    report_bytes = _file(goldens / 'record-report.json')
    try:
        report = json.loads(report_bytes)
    except (UnicodeError, json.JSONDecodeError):
        _fail('record-report.json is malformed')
    if not isinstance(report, dict) or set(report) != {'selected', 'unobserved', 'calls',
                                                       'sample_counts', 'skipped',
                                                       'non_deterministic', 'rejected_corpus'}:
        _fail('record-report.json shape changed')
    selected = report['selected']
    counts = report['sample_counts']
    unobserved = report['unobserved']
    calls = report['calls']
    if not isinstance(selected, list) or any(not isinstance(item, str) for item in selected) \
            or selected != sorted(set(selected)) \
            or not isinstance(counts, dict) or not counts \
            or not isinstance(unobserved, list) \
            or any(not isinstance(item, str) for item in unobserved) \
            or unobserved != sorted(set(unobserved)) \
            or not isinstance(calls, dict) or set(calls) != set(counts):
        _fail('selected, observed, or call-count structure is invalid')
    if set(selected) != set(counts) | set(unobserved) or set(counts) & set(unobserved):
        _fail('selected functions do not equal observed plus unobserved')
    if inventory is not None:
        pure, _ = included_functions(None, inventory)
        if set(selected) != pure:
            _fail('selected functions differ from the current pure-function inventory')
    if not isinstance(report['non_deterministic'], list) or report['non_deterministic']:
        _fail('function report contains non-deterministic inputs')
    if not isinstance(report['skipped'], list) or not isinstance(report['rejected_corpus'], list):
        _fail('function report skip/rejection lists are malformed')
    skipped = 0
    for row in report['skipped']:
        if not isinstance(row, dict) or set(row) != {'function', 'reason', 'count'} \
                or row['function'] not in selected or not isinstance(row['reason'], str) \
                or isinstance(row['count'], bool) or not isinstance(row['count'], int) \
                or row['count'] < 1:
            _fail('skipped call has an invalid function, reason, or count')
        skipped += row['count']

    expected = {_function_path(function) for function in counts}
    if len(expected) != len(counts) or _ordinary_file_set(goldens) != expected:
        _fail('ordinary function file set differs from report.sample_counts')
    files = {Path('record-report.json'): report_bytes}
    samples = errors = 0
    for function, count in sorted(counts.items()):
        relative = _function_path(function)
        if isinstance(count, bool) or not isinstance(count, int) or not 1 <= count <= MAXIMUM \
                or isinstance(calls[function], bool) or not isinstance(calls[function], int) \
                or calls[function] < count:
            _fail('function sample or call count is invalid or exceeds max200')
        raw = _file(goldens / relative)
        files[relative] = raw
        try:
            text = raw.decode('utf-8')
            lines = text.splitlines()
            rows = [json.loads(line) for line in lines]
        except (UnicodeError, json.JSONDecodeError):
            _fail('function JSONL has a malformed UTF-8 or JSON line')
        if len(rows) != count or not raw.endswith(b'\n') or any(
                not isinstance(row, dict) or set(row) != {'input', 'output'} for row in rows):
            _fail('function JSONL row count or input/output shape differs from report')
        # Collector.save sorts unique inputs by their canonical SHA-256 key.
        keys = [digest(row['input']) for row in rows]
        if keys != sorted(set(keys)):
            _fail('function JSONL input hashes are duplicate or out of order')
        samples += len(rows)
        errors += sum(isinstance(row['output'], dict) and '$error' in row['output'] for row in rows)
    return {'selected_functions': len(selected), 'observed_functions': len(counts),
            'unobserved_functions': unobserved, 'samples': samples,
            'tagged_error_samples': errors, 'skipped_calls': skipped,
            'non_deterministic_inputs': 0, 'output_file_count': len(files),
            'report_sha256': hashlib.sha256(report_bytes).hexdigest(),
            'output_tree_algorithm': TREE_ALGORITHM,
            'output_tree_sha256': tree_sha256(files)}


def verify(goldens: Path = GOLDENS, inventory: Path | None = INVENTORY,
           input_root: Path = ROOT) -> dict:
    result = audit_files(goldens, inventory)
    provenance = _json(goldens / 'function-provenance.json')
    if not isinstance(provenance, dict) or provenance.get('schema') != 1:
        _fail('function provenance schema is missing')
    if provenance.get('output_tree_algorithm') != TREE_ALGORITHM:
        _fail('function provenance has no recognized explicit tree digest algorithm')
    measured_inputs = audit_recording_inputs(input_root)
    if provenance.get('recording_inputs') != measured_inputs:
        _fail('recording input paths or content tree SHA differs from provenance')
    for field in ('selected_functions', 'observed_functions', 'samples',
                  'tagged_error_samples', 'skipped_calls', 'non_deterministic_inputs',
                  'output_file_count', 'report_sha256', 'output_tree_sha256'):
        if provenance.get(field) != result[field]:
            _fail(f'function provenance {field} differs from the verified tree/report')
    if provenance.get('python') != '3.11.13' or provenance.get('unicode') != '14.0.0' \
            or isinstance(provenance.get('passes'), bool) \
            or not isinstance(provenance.get('passes'), int) or provenance['passes'] < 2:
        _fail('function provenance reference runtime or two-pass gate is invalid')
    special = provenance.get('unobserved_with_special_coverage')
    if not isinstance(special, dict) or set(special) != set(result['unobserved_functions']):
        _fail('unobserved functions lack an exact special-golden mapping')
    for function, name in special.items():
        if not isinstance(name, str) or not name.startswith('oracle/goldens/special/') \
                or not name.endswith('.jsonl') or '/' in name[len('oracle/goldens/special/'):]:
            _fail('special golden mapping has an unsafe path')
        path = goldens / 'special' / name.removeprefix('oracle/goldens/special/')
        raw = _file(path)
        try:
            rows = [json.loads(line) for line in raw.decode('utf-8').splitlines()]
        except (UnicodeError, json.JSONDecodeError):
            _fail('special golden mapping has malformed JSONL')
        if not rows or any(not isinstance(row, dict) or row.get('function') != function
                           for row in rows):
            _fail('special golden mapping does not exercise its named function')
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=GOLDENS,
                        help='function golden root containing report, pipeline/, server/')
    parser.add_argument('--tree-sha', action='store_true',
                        help='calculate a new tree SHA after exact file/report checks; does not verify provenance')
    parser.add_argument('--input-tree', action='store_true',
                        help='calculate the current recording input paths and tree SHA')
    args = parser.parse_args()
    if args.tree_sha and args.input_tree:
        parser.error('choose one of --tree-sha or --input-tree')
    if args.input_tree:
        print(json.dumps(audit_recording_inputs(), ensure_ascii=False, separators=(',', ':')))
    elif args.tree_sha:
        print(audit_files(args.root, INVENTORY)['output_tree_sha256'])
    else:
        result = verify(args.root)
        print(f"{result['observed_functions']} ordinary functions, {result['samples']} samples, "
              f"{len(result['unobserved_functions'])} special-covered; report and tree SHA verified")


if __name__ == '__main__':
    main()
