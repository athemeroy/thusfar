# Original test scope: data export and release tooling

The 171-test baseline in `core/test/ported/manifest.json` includes nine tests
whose direct targets are `scripts/`, outside the 378 production functions in
`pipeline/` and `server/`. This ledger gives each test a concrete owner and a
closure check. It does not change any test's current `scope_exception` status:
none of these nine Python assertions has been translated or passed in Dart.

`PLAN.md` A0.6 says to translate all 171 original tests before leaving A0,
allowing a translated test to be skipped with a recorded reason. Its production
function exception rule does not automatically waive tests. The nine entries
below therefore remain an **A0.6 gate decision**, even though the prospective
owners are now identified. A phase decision must either translate each contract
into an executable Dart test or explicitly approve a narrower test scope with
the reason recorded in the test manifest and `STATUS.md`. A skipped placeholder
is not a translation.

## Three teacher-data export tests

`scripts/export_judge_data.py` is an offline training-data utility, not part of
the planned Dart app, core engine, or HTTP service. Its three tests protect the
link between a teacher label and the exact input judged. The Python oracle
continues running these tests while that tool exists. At C, the tool and tests
can be stored with the tagged Python reference; keeping a runnable data exporter
in the active branch would need its own declared tool owner and tests. The
runtime-facing portions of the contract also belong to A4's Dart judge request
serialization and cassette comparison. In particular, a cropped training
passage must never be presented as the exact teacher input.

| Original test ID | Protected assertion | Contract owner and closure check |
|---|---|---|
| `tests.test_export_exact_context.ExactTeacherContextTests.test_zero_window_keeps_tail_beyond_old_cap` | Zero-radius export retains evidence beyond 12,000 characters; `original_passage_sha256` and `teacher_input_sha256` use the complete input. | A0 Python oracle data export; A4 Dart judge-request/cassette test must preserve the complete state and input hash. If an active data exporter remains at C, its exact-context test must follow it. |
| `tests.test_export_exact_context.ExactTeacherContextTests.test_cropped_context_is_explicitly_unverified` | A 300-character window differs from the judged original, is marked `context_exact=false`, and cannot claim the cropped input has the original teacher hash. | A0 Python oracle data export; C may archive the offline exporter. Any replacement exporter must test that a cropped row is explicitly unverified and retains provenance of the original input. No runtime Dart behavior is asserted by this test today. |
| `tests.test_export_exact_context.ExactTeacherContextTests.test_structured_state_preserves_all_sections_and_order` | A structured state becomes ordered `[section]` text, including `this_passage`, before exact-context marking. | A0 Python oracle data export; A4 Dart judge-request/cassette test must compare ordered state serialization. An active replacement exporter at C also needs its own ordering test. |

## Six Python/Web release-boundary tests

`scripts/build_release.py` assembles the old Python-and-Web self-hosted release.
Its six tests are release safety contracts, not tests of a `pipeline/` or
`server/` function. `PLAN.md` C replaces the self-hosted service with a compiled
Dart executable and keeps `web/`, so **C self-hosted packaging and its offline
release validation** own these contracts. B6's Android APK checks are separate:
the old tests neither build nor sign an APK. The C replacement can use Dart
tooling or CI scripts, but it must run without a Python runtime in the shipped
service. The old Python release tests stay in the oracle until the replacement
checks pass; the old builder is then removed from the active branch at C.

| Original test ID | Protected assertion | Contract owner and closure check |
|---|---|---|
| `tests.test_release.ReleaseBoundary.test_verified_snapshot_reused_and_data_credentials_excluded` | Reuse a validated content snapshot; exclude `.env` and private book data from the packaged source; retain an empty data mount. | C self-hosted package test: build twice from one validated source, verify identical digest and no secrets/user data in the artifact. |
| `tests.test_release.ReleaseBoundary.test_changed_source_requires_new_validation` | A changed source file invalidates the old validation receipt. | C self-hosted package test: mutate a source fixture after validation and require package creation to fail. |
| `tests.test_release.ReleaseBoundary.test_private_runtime_file_and_symlink_rejected` | Reject a private file or symlink inside the release source. | C self-hosted package test: reject both fixtures before building. |
| `tests.test_release.ReleaseBoundary.test_tampering_refuses_existing_release_reuse` | Refuse to reuse an existing artifact whose contents changed after creation. | C self-hosted package test: alter a previously built artifact and require digest verification to fail. |
| `tests.test_release.ReleaseBoundary.test_root_directory_symlink_is_rejected` | Reject a symlink used as a release root directory. | C self-hosted package test: reject an external directory reached through a symlink. |
| `tests.test_release.ReleaseBoundary.test_worker_stamp_changes_for_assets_and_logic_not_downloads` | Web service-worker stamp changes for shell assets or worker logic, stays stable for download artifacts. | C self-hosted Web package test: verify these three stamp cases for the retained `web/` frontend. Flutter does not use a service worker. |

The C package checks must exercise the replacement release process, not merely
re-run `scripts/build_release.py`. Only after they pass may the six tests be
marked translated or be closed by an explicit scope decision. A0 retains the
nine named skipped slots so the original test count cannot silently shrink.

Run `python3 docs/port/check_test_scope.py` to verify this ledger against the
frozen test manifest. The existing `core/tool/generate_ported_tests.py --check`
also verifies the complete 171-test name and skip inventory.
