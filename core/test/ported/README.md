# Python 1.7.5 test port ledger

`manifest.json` maps each of the **171** named Python tests in the original
15-file 1.7.5 suite to exactly one identically named Dart test in this folder.
`core/tool/generate_ported_tests.py` derives the set from the Python AST and
`docs/port/inventory.json`; `--check` rejects missing or duplicate mappings,
changed Python sources, mismatched Dart names, missing owner modules or reasons,
and stale status counts.

Current status: **0 translated**, **162 pending Dart production modules**, and
**9 Python-only tooling scope exceptions**. Every Dart callback currently fails
if enabled. Each has an explicit skip and a manifest reason naming the relevant
module, stage and behavior. A successful `dart test test/ported` therefore
means only that the test skeleton loads; it is not evidence that the 171 Python
assertions have passed in Dart. The separate A0 semantic tests live in
`core/test/semantics/` and are outside this frozen count.

The nine exceptions are the three `test_export_exact_context.py` assertions
for the offline teacher-data exporter and the six `test_release.py` assertions
for the old Python/Web release builder. Their exact assertions, replacement
owners, and closure checks are recorded in
[`docs/port/TEST-PORT-SCOPE.md`](../../../docs/port/TEST-PORT-SCOPE.md).
These assignments do not count as translated or passing Dart assertions.
`PLAN.md` A0.6 still requires a stage decision for all nine; no automatic
exception has been granted. Do not relabel their skips as translated tests.

When an owner module is ported, replace the failing Dart callback with the
Python test's actual setup and assertions, backed by deterministic fixtures or
recorded network replies. Remove `skip:` and change that test's manifest status
to `translated`; clear its skip reason and update `counts`. Run `--check` and
the targeted Dart test. The generator's `--write` creates the initial skeleton
only. It refuses to overwrite an existing mapping without `--force`, which
would discard manual translations.

From the repository root:

```sh
python3 core/tool/generate_ported_tests.py --check
python3 docs/port/check_test_scope.py
cd core
dart analyze --fatal-infos --fatal-warnings test/ported
dart test test/ported
```

The initial check found all 171 Python IDs and Dart names. Static analysis
reported no issues, and the targeted Dart run exited successfully with exactly
171 skipped tests and no executed Python-port assertions.
