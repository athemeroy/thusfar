"""Function integrity checks reject count-preserving and provenance tampering."""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from oracle.record.common import digest, write_json, write_jsonl
from oracle.record.verify_function_goldens import (GOLDENS, INVENTORY, TREE_ALGORITHM,
                                                   audit_files, verify)


def _fixture(root: Path) -> tuple[Path, Path, Path]:
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
        'unobserved_with_special_coverage': {
            'server.ask.closure': 'oracle/goldens/special/closure.jsonl'},
    })
    return ordinary, report_path, provenance_path


class FunctionGoldenVerifierTests(unittest.TestCase):
    def test_current_ordinary_tree_has_exact_inventory_and_report_file_set(self):
        result = audit_files(GOLDENS, INVENTORY)
        self.assertEqual(result['selected_functions'], 128)
        self.assertEqual(result['observed_functions'], 123)
        self.assertEqual(result['output_file_count'], result['observed_functions'] + 1)
        self.assertEqual(result['non_deterministic_inputs'], 0)

    def test_fixture_report_tree_and_special_mapping_verify(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-function-audit-') as temp:
            root = Path(temp)
            _fixture(root)
            result = verify(root, inventory=None)
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
                verify(root, inventory=None)

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
                verify(root, inventory=None)
            provenance['output_tree_algorithm'] = TREE_ALGORITHM
            write_json(provenance_path, provenance)
            write_jsonl(root / 'special/closure.jsonl', [
                {'function': 'server.ask.other', 'input': {}, 'output': {}},
            ])
            with self.assertRaisesRegex(ValueError, 'named function'):
                verify(root, inventory=None)

    def test_report_edit_without_provenance_breaks_report_sha(self):
        with tempfile.TemporaryDirectory(prefix='thusfar-function-audit-') as temp:
            root = Path(temp)
            _, report_path, _ = _fixture(root)
            report = json.loads(report_path.read_text())
            report['calls']['pipeline.kg.demo'] = 4
            write_json(report_path, report)
            with self.assertRaisesRegex(ValueError, 'report_sha256'):
                verify(root, inventory=None)


if __name__ == '__main__':
    unittest.main()
