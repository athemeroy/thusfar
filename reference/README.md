# Regression fixtures

These Python/browser sources and recorded fixtures support tests of the Flutter
client and Dart engine. They are not a supported app or deployment target.

- `pipeline/`, `server/`, `web/`, and `scripts/` contain reference behavior used by tests.
- `oracle/` contains source books, synthetic inputs, recorded replies, and verification tools.
- `docs/port/` contains the machine-readable test contracts and their generators.
- `tests/` and `testsets/` exercise the reference behavior.

Do not change source or fixture hashes merely to make a test pass. Preserve
source provenance and the distinction between skipped and executed assertions.
Book sources and redistribution information are in [the corpus guide](oracle/corpus/README.md).

## Offline checks

From the repository root, using Python 3.11 (Unicode 14.0.0) and Node:

```sh
export PYTHONPATH="$PWD/reference:$PWD"
python3 scripts/check_reference_layout.py
python3 core/tool/generate_ported_tests.py --check
python3 reference/docs/port/check_test_scope.py
python3 scripts/generate_book_policy_tables.py --check
python3 -m unittest discover -s reference/tests
(cd reference && python3 -m oracle.record.verify_folds)
```

Replay uses recorded replies; do not enable live recording during routine tests.
See [fixture verification](oracle/record/README.md) for targeted commands and
[build and test](../app/README.md) for current client checks.
