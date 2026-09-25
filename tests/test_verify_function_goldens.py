"""Function integrity checks reject count-preserving and provenance tampering."""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from oracle.record.common import digest, write_json, write_jsonl
from oracle.record.verify_function_goldens import (TREE_ALGORITHM, audit_files,
                                                   audit_recording_inputs, verify)


def _fixture(root: Path) -> tuple[Path, Path, Path]:
    input_root = root / 'inputs'
    (input_root / 'pipeline').mkdir(parents=True)
    (input_root / 'tests').mkdir()
    (input_root / 'oracle/corpus').mkdir(parents=True)
    (input_root / 'oracle/record').mkdir(parents=True)
    (input_root / 'oracle/cassettes/live').mkdir(parents=True)
    (input_root / 'pipeline/example.py').write_text('def example(): return 1\n')
    (input_root / 'tests/test_example.py').write_text('def test_example(): pass\n')
    write_json(input_root / 'oracle/corpus/manifest.json', {'fixture': True})
    (input_root / 'oracle/record/manual.jsonl').write_text('{}\n')
    write_json(input_root / 'oracle/cassettes/live/fixture.json', {'receipt': 'fake'})
    (root / 'pipeline/kg').mkdir(parents=True)
    (root / 'server').mkdir()
    (root / 'special').mkdir()
    ordinary = root / 'pipeline/kg/demo.jsonl'
    rows = [
        {'input': {'value': 'alpha'}, 'output': True},
        {'input': {'value': 'beta'},
         'output': {'$error': {'type': 'ValueError', 'message': 'expected edge'}}},
    ]
    write_jsonl(ordinary, sorted(rows, key=lambda row: digest(row['input'])))
    report_path = root / 'record-report.json'
    write_json(report_path, {
        'selected': ['pipeline.kg.demo', 'server.ask.closure'],
        'unobserved': ['server.ask.closure'],
        'calls': {'pipeline.kg.demo': 3},
        'sample_counts': {'pipeline.kg.demo': 2},
        'skipped': [{'function': 'pipeline.kg.demo', 'reason': 'fixture skip', 'count': 1}],
        'non_deterministic': [], 'rejected_corpus': [],
    })
    write_jsonl(root / 'special/closure.jsonl', [
        {'schema': 1, 'function': 'server.ask.closure', 'case': 'fixture',
         'input': {}, 'output': {'kind': 'closure'}},
    ])
    measured = audit_files(root)
    provenance_path = root / 'function-provenance.json'
    write_json(provenance_path, {
        'schema': 1, 'python': '3.11.13', 'unicode': '14.0.0', 'passes': 2,
        **{key: value for key, value in measured.items() if key != 'unobserved_functions'},
        'recording_inputs': audit_recording_inputs(input_root),
        'unobserved_with_special_coverage': {
            'server.ask.closure': 'oracle/goldens/special/closure.jsonl'},
    })
    return ordinary, report_path, provenance_path


def _verify(root: Path, inventory: Path | None = None) -> dict:
    return verify(root, inventory=inventory, input_root=root / 'inputs')


class FunctionGoldenVerifierTests(unittest.TestCase):
    def test_inventory_selection_and_report_file_set(self):
        # A checked-in golden can temporarily lag the inventory while a new formal
        # double recording is in progress. CI runs verify() on that actual tree.
        with tempfile.TemporaryDirectory(prefix='thusfar-function-audit-') as temp:
            root = Path(temp)
            _fixture(root)
            inventory = root / 'inventory.json'
            rows = [
                {'source': 'pipeline/kg.py', 'line': 1,
                 'id': 'pipeline.kg.demo', 'category': '纯函数'},
                {'source': 'server/ask.py', 'line': 2,
                 'id': 'server.ask.closure', 'category': '纯函数'},
            ]
            write_json(inventory, {'functions': rows})
            result = _verify(root, inventory=inventory)
            self.assertEqual(result['selected_functions'], 2)
            self.assertEqual(result['observed_functions'], 1)
            self.assertEqual(result['output_file_count'], 2)
            rows[1]['category'] = '有原位状态修改'
            write_json(inventory, {'functions': rows})
            with self.assertRaisesRegex(ValueError, 'current pure-function inventory'):
                _verify(root, inventory=inventory)

    def test_fixture_report_tree_and_special_mapping_verify(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-function-audit-') as temp:
            root = Path(temp)
            _fixture(root)
            result = _verify(root)
            self.assertEqual(result['samples'], 2)
            self.assertEqual(result['tagged_error_samples'], 1)
            self.assertEqual(result['skipped_calls'], 1)
            self.assertEqual(result['output_tree_algorithm'], TREE_ALGORITHM)

    def test_count_preserving_row_edit_still_breaks_the_tree_digest(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-function-audit-') as temp:
            root = Path(temp)
            ordinary, _, _ = _fixture(root)
            rows = [json.loads(line) for line in ordinary.read_text().splitlines()]
            rows[0]['output'] = {'changed': True}
            write_jsonl(ordinary, rows)
            with self.assertRaisesRegex(ValueError, 'output_tree_sha256'):
                _verify(root)

    def test_missing_extra_duplicate_or_over_cap_samples_fail(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-function-audit-') as temp:
            root = Path(temp)
            ordinary, report_path, _ = _fixture(root)
            original_rows = [json.loads(line) for line in ordinary.read_text().splitlines()]
            write_jsonl(ordinary, original_rows[:1])
            with self.assertRaisesRegex(ValueError, 'row count'):
                audit_files(root)
            write_jsonl(ordinary, original_rows)
            write_jsonl(root / 'pipeline/kg/extra.jsonl', original_rows[:1])
            with self.assertRaisesRegex(ValueError, 'file set'):
                audit_files(root)
            (root / 'pipeline/kg/extra.jsonl').unlink()
            write_jsonl(ordinary, [original_rows[0], original_rows[0]])
            with self.assertRaisesRegex(ValueError, 'duplicate or out of order'):
                audit_files(root)
            rows = [{'input': {'n': n}, 'output': n} for n in range(201)]
            write_jsonl(ordinary, rows)
            report = json.loads(report_path.read_text())
            report['sample_counts']['pipeline.kg.demo'] = 201
            report['calls']['pipeline.kg.demo'] = 201
            write_json(report_path, report)
            with self.assertRaisesRegex(ValueError, 'max200'):
                audit_files(root)

    def test_unknown_legacy_tree_algorithm_and_wrong_special_function_fail(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-function-audit-') as temp:
            root = Path(temp)
            _, _, provenance_path = _fixture(root)
            provenance = json.loads(provenance_path.read_text())
            provenance.pop('output_tree_algorithm')
            write_json(provenance_path, provenance)
            with self.assertRaisesRegex(ValueError, 'explicit tree digest algorithm'):
                _verify(root)
            provenance['output_tree_algorithm'] = TREE_ALGORITHM
            write_json(provenance_path, provenance)
            write_jsonl(root / 'special/closure.jsonl', [
                {'function': 'server.ask.other', 'input': {}, 'output': {}},
            ])
            with self.assertRaisesRegex(ValueError, 'named function'):
                _verify(root)

    def test_report_edit_without_provenance_breaks_report_sha(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-function-audit-') as temp:
            root = Path(temp)
            _, report_path, _ = _fixture(root)
            report = json.loads(report_path.read_text())
            report['calls']['pipeline.kg.demo'] = 4
            write_json(report_path, report)
            with self.assertRaisesRegex(ValueError, 'report_sha256'):
                _verify(root)

    def test_changed_or_added_recording_input_breaks_strict_provenance(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-function-audit-') as temp:
            root = Path(temp)
            _fixture(root)
            for relative in ('pipeline/example.py', 'oracle/corpus/manifest.json',
                             'oracle/cassettes/live/fixture.json'):
                source = root / 'inputs' / relative
                original = source.read_bytes()
                with self.subTest(relative=relative):
                    source.write_bytes(original + b'!')
                    with self.assertRaisesRegex(ValueError, 'recording input paths or content tree SHA'):
                        _verify(root)
                    source.write_bytes(original)
            extra = root / 'inputs/tests/test_extra.py'
            extra.write_text('def test_extra(): pass\n')
            with self.assertRaisesRegex(ValueError, 'recording input paths or content tree SHA'):
                _verify(root)


if __name__ == '__main__':
    unittest.main()
