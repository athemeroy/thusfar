"""Replay the committed Aq HTTP oracles without a provider or stable filesystem inodes."""
from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from oracle.record.common import canonical, digest


ROOT = Path(__file__).resolve().parents[1]
GOLDENS = ROOT / 'oracle/goldens/http'
SOURCE = 'oracle/corpus/snapshots/aq_complete'
HEX_64 = re.compile(r'[0-9a-f]{64}\Z')
HEX_32 = re.compile(r'[0-9a-f]{32}\Z')

# The source tree is copied to a new baseline on CI. Its inode enters these
# revisions and their derived marginalia cache keys. Every other value must
# match the committed oracle exactly, including the rest of the import request.
BASELINE_DYNAMIC = {
    'book-get': (('response', 'body_json', 'version'),),
    'book-export': (('response', 'body_json', 'version'),),
    'book-offline-manifest': (
        ('response', 'body_json', 'version'),
        ('response', 'body_json', 'book', 'version'),
    ),
    'book-marginalia-empty-cues': (('response', 'body_json', 'key'),),
    'book-marginalia-empty-cues-cached': (('response', 'body_json', 'key'),),
    'books-import-success': (('request', 'body_json', 'version'),),
    'books-import-duplicate': (('request', 'body_json', 'version'),),
}
MODEL_DYNAMIC = {
    'marginalia-manual-synthetic': (('response', 'body_json', 'key'),),
    'marginalia-manual-cached-synthetic': (('response', 'body_json', 'key'),),
}
COMMITTED_DYNAMIC_VALUES = {
    'aq_complete': {
        'book-get': ('f8c614cc8f90520c89099823c26dd6e8214f02821b60727849bde148519044af',),
        'book-export': ('e39f6e8a7df015addaf59db952e42a994c4cf0957e64bc059b0c6338ab2a0f60',),
        'book-offline-manifest': (
            'f523ab76756a8ec9544f06c78a4778bb8ded7038f1ea2947c2e5b446f1f6e9af',
            'f8c614cc8f90520c89099823c26dd6e8214f02821b60727849bde148519044af',
        ),
        'book-marginalia-empty-cues': ('a4b8e019033cff06b5cf736669b2155b',),
        'book-marginalia-empty-cues-cached': ('a4b8e019033cff06b5cf736669b2155b',),
        'books-import-success': ('e39f6e8a7df015addaf59db952e42a994c4cf0957e64bc059b0c6338ab2a0f60',),
        'books-import-duplicate': ('e39f6e8a7df015addaf59db952e42a994c4cf0957e64bc059b0c6338ab2a0f60',),
    },
    'aq_model_synthetic': {
        'marginalia-manual-synthetic': ('4faffc57e3ac3ada1b8f00d0fec73800',),
        'marginalia-manual-cached-synthetic': ('4faffc57e3ac3ada1b8f00d0fec73800',),
    },
}


def _sha256_json(value: object) -> str:
    return hashlib.sha256(json.dumps(value).encode()).hexdigest()


def _signature(path: Path) -> tuple[int, int, int]:
    stamp = path.stat()
    return stamp.st_mtime_ns, stamp.st_size, stamp.st_ino


def _snapshot_version(root: Path) -> str:
    paths = [root / f'{part}.json' for part in ('book', 'kg', 'status')]
    paths += sorted((root / 'mentions').glob('*.json'))
    paths += sorted((root / 'img').glob('*'))
    return _sha256_json([(str(path.relative_to(root)), _signature(path))
                         for path in paths if path.is_file()])


def _marginalia_key(root: Path, row: dict) -> str:
    request = row['request']['body_json']
    mode, pos = request['mode'], request['pos']
    frontier = json.loads((root / 'status.json').read_text(encoding='utf-8'))['frontier']
    payload = {'mode': mode, 'pos': pos, 'persona': request.get('persona', 'auto'),
               'knowledge_frontier': min(pos, frontier),
               'graph_revision': _signature(root / 'kg.json')}
    if mode == 'manual':
        payload.update(start=request['start'], end=request['end'],
                       quote=row['response']['body_json']['quote'])
    else:
        payload.update(page_start=request['page_start'], page_end=request['page_end'])
    version = 5 if mode == 'cues' else 7
    raw = json.dumps({'v': version, **payload}, ensure_ascii=False,
                     sort_keys=True, separators=(',', ':'))
    return hashlib.sha256(raw.encode()).hexdigest()[:32]


def _baseline_dynamic_values(name: str, root: Path, rows: list[dict]) -> dict[str, tuple[str, ...]]:
    by_route = {row['route']: row for row in rows}
    if name == 'aq_model_synthetic':
        return {route: (_marginalia_key(root, by_route[route]),)
                for route in MODEL_DYNAMIC}
    book_version = _sha256_json(_signature(root / 'book.json'))
    snapshot_version = _snapshot_version(root)
    notebook = root / 'notebook.json'
    manual = root / 'manual-entities.json'
    offline_version = _sha256_json([
        snapshot_version, _signature(notebook) if notebook.exists() else None,
        _signature(manual) if manual.exists() else None,
    ])
    cues_key = _marginalia_key(root, by_route['book-marginalia-empty-cues'])
    return {
        'book-get': (book_version,),
        'book-export': (snapshot_version,),
        'book-offline-manifest': (offline_version, book_version),
        'book-marginalia-empty-cues': (cues_key,),
        'book-marginalia-empty-cues-cached': (cues_key,),
        'books-import-success': (snapshot_version,),
        'books-import-duplicate': (snapshot_version,),
    }


class CommittedHTTPReplayTests(unittest.TestCase):
    def _replay(self, module: str, name: str) -> tuple[list[bytes], dict, dict]:
        with tempfile.TemporaryDirectory(prefix='thusfar-http-committed-') as temp:
            workspace = Path(temp)
            baseline = workspace / 'baseline'
            outputs = [workspace / 'first.jsonl', workspace / 'second.jsonl']
            # The HTTP server uses loopback only; the synthetic model transport
            # rejects every URL outside its explicit .invalid fixture endpoints.
            env = dict(os.environ, HTTPS_PROXY='http://127.0.0.1:1',
                       HTTP_PROXY='http://127.0.0.1:1', ALL_PROXY='http://127.0.0.1:1')
            for output in outputs:
                result = subprocess.run([
                    sys.executable, '-m', module, SOURCE, '--baseline', str(baseline),
                    '--out', str(output),
                ], cwd=ROOT, env=env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(outputs[0].read_bytes(), outputs[1].read_bytes())
            reports = [path.with_name(path.stem + '-report.json') for path in outputs]
            self.assertEqual(reports[0].read_bytes(), reports[1].read_bytes())
            lines = outputs[0].read_bytes().splitlines(keepends=True)
            report = json.loads(reports[0].read_bytes())
            values = self._compare_committed(name, lines, report, baseline)
        return lines, report, values

    def _assert_dynamic_values(self, rows: list[dict], paths: dict,
                               values: dict[str, tuple[str, ...]]) -> None:
        self.assertEqual(set(paths), set(values))
        by_route = {row['route']: row for row in rows}
        for route, route_paths in paths.items():
            self.assertEqual(len(route_paths), len(values[route]), route)
            for path, expected in zip(route_paths, values[route]):
                field = by_route[route]
                for part in path:
                    field = field[part]
                self.assertEqual(field, expected, route)

    def _compare_committed(self, name: str, lines: list[bytes], report: dict,
                           baseline: Path) -> dict[str, tuple[str, ...]]:
        expected_lines = (GOLDENS / f'{name}.jsonl').read_bytes().splitlines(keepends=True)
        expected_report = json.loads((GOLDENS / f'{name}-report.json').read_bytes())
        dynamic = BASELINE_DYNAMIC if name == 'aq_complete' else MODEL_DYNAMIC
        self.assertEqual(len(lines), len(expected_lines))
        actual_rows = [json.loads(line) for line in lines]
        expected_rows = [json.loads(line) for line in expected_lines]
        self.assertEqual([row['route'] for row in actual_rows],
                         [row['route'] for row in expected_rows])
        self.assertEqual(len({row['route'] for row in actual_rows}), len(lines))
        actual_dynamic_values = _baseline_dynamic_values(name, baseline, actual_rows)
        self._assert_dynamic_values(actual_rows, dynamic, actual_dynamic_values)
        self._assert_dynamic_values(expected_rows, dynamic, COMMITTED_DYNAMIC_VALUES[name])
        if name == 'aq_complete':
            for candidate in (actual_rows, expected_rows):
                by_route = {row['route']: row for row in candidate}
                self.assertEqual(
                    by_route['book-marginalia-empty-cues']['response']['body_json']['key'],
                    by_route['book-marginalia-empty-cues-cached']['response']['body_json']['key'])
                self.assertEqual(
                    by_route['books-import-success']['request']['body_json']['version'],
                    by_route['books-import-duplicate']['request']['body_json']['version'])
        for line, expected_line, actual, expected in zip(
                lines, expected_lines, actual_rows, expected_rows):
            route = actual['route']
            if route not in dynamic:
                self.assertEqual(line, expected_line, route)
                continue
            actual_copy, expected_copy = copy.deepcopy(actual), copy.deepcopy(expected)
            for path in dynamic[route]:
                for row in (actual_copy, expected_copy):
                    field = row
                    for part in path[:-1]:
                        field = field[part]
                    value = field[path[-1]]
                    pattern = HEX_32 if path[-1] == 'key' else HEX_64
                    self.assertIsInstance(value, str, route)
                    self.assertRegex(value, pattern, route)
                    field[path[-1]] = '<inode-derived>'
            self.assertEqual(canonical(actual_copy), canonical(expected_copy), route)

        # The report digest changes only because the checked inode-derived
        # response fields change. Verify each digest before excluding it.
        for candidate, rows in ((report, actual_rows), (expected_report, expected_rows)):
            self.assertEqual(candidate['recorded_response_sha256'],
                             digest([row['response'] for row in rows]))
        actual_copy, expected_copy = copy.deepcopy(report), copy.deepcopy(expected_report)
        actual_copy['recorded_response_sha256'] = '<checked-derived-digest>'
        expected_copy['recorded_response_sha256'] = '<checked-derived-digest>'
        self.assertEqual(canonical(actual_copy), canonical(expected_copy))
        return actual_dynamic_values

    def _assert_tamper_rejected(self, lines: list[bytes], dynamic: dict,
                                values: dict, routes: tuple[str, ...],
                                path: tuple[str, ...], replacement: str) -> None:
        rows = [json.loads(line) for line in lines]
        by_route = {row['route']: row for row in rows}
        for route in routes:
            field = by_route[route]
            for part in path[:-1]:
                field = field[part]
            field[path[-1]] = replacement
        with self.assertRaises(AssertionError):
            self._assert_dynamic_values(rows, dynamic, values)

    def test_complete_aq_routes_match_committed_oracle(self):
        lines, report, values = self._replay('oracle.record.http_routes', 'aq_complete')
        self.assertEqual((len(lines), report['routes'], report['passes']), (60, 60, 2))
        self._assert_tamper_rejected(lines, BASELINE_DYNAMIC, values, ('book-get',),
                                     ('response', 'body_json', 'version'), '0' * 64)
        self._assert_tamper_rejected(
            lines, BASELINE_DYNAMIC, values,
            ('book-marginalia-empty-cues', 'book-marginalia-empty-cues-cached'),
            ('response', 'body_json', 'key'), '0' * 32)
        self._assert_tamper_rejected(
            lines, BASELINE_DYNAMIC, values,
            ('books-import-success', 'books-import-duplicate'),
            ('request', 'body_json', 'version'), '0' * 64)

    def test_synthetic_model_routes_match_committed_oracle(self):
        lines, report, values = self._replay('oracle.record.http_model_synthetic',
                                             'aq_model_synthetic')
        self.assertEqual((len(lines), report['routes'], report['passes']), (4, 4, 2))
        self.assertFalse(report['transport']['outbound_model_network'])
        self.assertIn('synthetic in-memory transport', report['source'])
        self._assert_tamper_rejected(
            lines, MODEL_DYNAMIC, values,
            ('marginalia-manual-synthetic', 'marginalia-manual-cached-synthetic'),
            ('response', 'body_json', 'key'), '0' * 32)


if __name__ == '__main__':
    unittest.main()
