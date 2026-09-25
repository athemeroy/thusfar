"""Regression checks for the A0 translated-but-skipped contract ledger."""

from __future__ import annotations

import copy
import json
import unittest

from core.tool import generate_ported_tests as port


class PortedContractGuardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.rows = json.loads(port.MANIFEST.read_text(encoding="utf-8"))["tests"]
        cls.inventory = json.loads(port.INVENTORY.read_text(encoding="utf-8"))["functions"]
        cls.row = next(row for row in cls.rows if row["id"].endswith("test_valid_json_untouched"))
        cls.source = (port.ROOT / cls.row["dart_file"]).read_text(encoding="utf-8")

    def test_empty_and_constant_callbacks_are_not_translations(self) -> None:
        for callback in (
            ', () {}, skip: "pending", );',
            ', () => expect(true, isTrue), skip: "pending", );',
            ', () { /* expect(callPorted("pipeline.llm.parse_json", {}), isNull); */ }, '
            'skip: "pending", );',
        ):
            with self.subTest(callback=callback), self.assertRaisesRegex(
                ValueError, "no executable assertion|never invokes"
            ):
                port.check_contract(self.row, self.source, callback, self.inventory)

    def test_owner_must_resolve_and_be_bound_to_callback(self) -> None:
        callback = (
            ', () => expect(callPorted("pipeline.llm.parse_json", {}), isNull), '
            'skip: "pending", );'
        )
        for owner, message in (
            ("pipeline.llm.no_such_function", "not an inventory"),
            ("pipeline.llm.chat", "Primary owner is not bound"),
        ):
            row = copy.deepcopy(self.row)
            row["contract_owners"] = [owner]
            with self.subTest(owner=owner), self.assertRaisesRegex(ValueError, message):
                port.check_contract(row, self.source, callback, self.inventory)

    def test_removed_fixture_binding_is_rejected(self) -> None:
        row = next(row for row in self.rows if row["id"].endswith(
            "test_zero_window_keeps_tail_beyond_old_cap"))
        source = (port.ROOT / row["dart_file"]).read_text(encoding="utf-8")
        broken = source.replace("callPorted('scripts.export_judge_data.from_logs'",
                                "unboundCall('scripts.export_judge_data.from_logs'", 1)
        self.assertNotEqual(source, broken)
        callback = ', () { final result = _export("text", 0); expect(result, isNotNull); }, '
        with self.assertRaisesRegex(ValueError, "no longer reaches callPorted"):
            port.check_contract(row, broken, callback + 'skip: "pending", );', self.inventory)

    def test_assertion_helper_cannot_become_silent(self) -> None:
        row = next(row for row in self.rows if row["id"].endswith(
            "test_malformed_or_missing_free_dimensions_are_rejected"))
        source = (port.ROOT / row["dart_file"]).read_text(encoding="utf-8")
        broken = source.replace("expect(object(run['error'])['type'], 'pipeline.llm.LLMError');",
                                "final ignored = run['error'];", 1)
        self.assertNotEqual(source, broken)
        callback = (', () { final run = scripted(\'pipeline.llm.jev_free\'); '
                    'expectClientError(run); }, skip: "pending", );')
        with self.assertRaisesRegex(ValueError, "no executable assertion"):
            port.check_contract(row, broken, callback, self.inventory)


if __name__ == "__main__":
    unittest.main()
