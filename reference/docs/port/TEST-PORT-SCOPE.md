# Script-tool test contracts

These nine entries in `core/test/ported/manifest.json` have translated Dart
assertion bodies but remain skipped until their test adapters have implementations.
Keep the original IDs, protected assertions, and explicit skip reasons intact.
The Python reference tests exercise the original tools.

| Original test ID | Protected assertion | Reference tool |
| --- | --- | --- |
| `tests.test_export_exact_context.ExactTeacherContextTests.test_zero_window_keeps_tail_beyond_old_cap` | Zero-radius export retains evidence beyond 12,000 characters; `original_passage_sha256` and `teacher_input_sha256` use the complete input. | `scripts/export_judge_data.py` |
| `tests.test_export_exact_context.ExactTeacherContextTests.test_cropped_context_is_explicitly_unverified` | A 300-character window differs from the judged original, is marked `context_exact=false`, and cannot claim the cropped input has the original teacher hash. | `scripts/export_judge_data.py` |
| `tests.test_export_exact_context.ExactTeacherContextTests.test_structured_state_preserves_all_sections_and_order` | A structured state becomes ordered `[section]` text, including `this_passage`, before exact-context marking. | `scripts/export_judge_data.py` |
| `tests.test_release.ReleaseBoundary.test_verified_snapshot_reused_and_data_credentials_excluded` | Reuse a validated content snapshot; exclude `.env` and private book data from the packaged source; retain an empty data mount. | `scripts/build_release.py` |
| `tests.test_release.ReleaseBoundary.test_changed_source_requires_new_validation` | A changed source file invalidates the old validation receipt. | `scripts/build_release.py` |
| `tests.test_release.ReleaseBoundary.test_private_runtime_file_and_symlink_rejected` | Reject a private file or symlink inside the release source. | `scripts/build_release.py` |
| `tests.test_release.ReleaseBoundary.test_tampering_refuses_existing_release_reuse` | Refuse to reuse an existing artifact whose contents changed after creation. | `scripts/build_release.py` |
| `tests.test_release.ReleaseBoundary.test_root_directory_symlink_is_rejected` | Reject a symlink used as a release root directory. | `scripts/build_release.py` |
| `tests.test_release.ReleaseBoundary.test_worker_stamp_changes_for_assets_and_logic_not_downloads` | Web service-worker stamp changes for shell assets or worker logic, stays stable for download artifacts. | `scripts/build_release.py` |

From the repository root:

```sh
python3 reference/docs/port/check_test_scope.py
python3 core/tool/generate_ported_tests.py --check
```

These checks validate the ledger; skipped assertions are not passing behavior tests.
