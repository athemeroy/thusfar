"""Check the nine translated script-tool contracts against the frozen ledger."""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DOC = ROOT / "docs/port/TEST-PORT-SCOPE.md"
MANIFEST = ROOT / "core/test/ported/manifest.json"
EXPECTED = {
    "tests.test_export_exact_context.ExactTeacherContextTests.test_zero_window_keeps_tail_beyond_old_cap": "scripts.export_judge_data",
    "tests.test_export_exact_context.ExactTeacherContextTests.test_cropped_context_is_explicitly_unverified": "scripts.export_judge_data",
    "tests.test_export_exact_context.ExactTeacherContextTests.test_structured_state_preserves_all_sections_and_order": "scripts.export_judge_data",
    "tests.test_release.ReleaseBoundary.test_verified_snapshot_reused_and_data_credentials_excluded": "scripts.build_release",
    "tests.test_release.ReleaseBoundary.test_changed_source_requires_new_validation": "scripts.build_release",
    "tests.test_release.ReleaseBoundary.test_private_runtime_file_and_symlink_rejected": "scripts.build_release",
    "tests.test_release.ReleaseBoundary.test_tampering_refuses_existing_release_reuse": "scripts.build_release",
    "tests.test_release.ReleaseBoundary.test_root_directory_symlink_is_rejected": "scripts.build_release",
    "tests.test_release.ReleaseBoundary.test_worker_stamp_changes_for_assets_and_logic_not_downloads": "scripts.build_release",
}


def main() -> None:
    rows = json.loads(MANIFEST.read_text(encoding="utf-8"))["tests"]
    exceptions = {row["id"] for row in rows if row["status"] == "scope_exception"}
    if exceptions:
        raise ValueError(f"Untranslated script-test scope exceptions remain: {sorted(exceptions)}")
    by_id = {row["id"]: row for row in rows}
    for test_id, module in EXPECTED.items():
        row = by_id[test_id]
        if row["owner_modules"] != [module] or row["status"] not in {"translated_skipped", "translated"}:
            raise ValueError(f"Script contract owner or translation drifted: {test_id}")
        if not row.get("contract_owners") or row["status"] == "translated_skipped" and not row.get("skip_reason"):
            raise ValueError(f"Script contract closure or skip reason is missing: {test_id}")
    documented = re.findall(
        r"^\| `(?P<id>tests\.test_[^`]+)` \|",
        DOC.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if len(documented) != len(EXPECTED) or set(documented) != set(EXPECTED):
        raise ValueError("Scope document must describe each script contract exactly once")
    print("Verified 9 translated script-tool contracts: 3 teacher-data, 6 self-hosted release")


if __name__ == "__main__":
    main()
