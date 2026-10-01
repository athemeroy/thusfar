# Reader-comment fixtures

`record_oracles.py` records reference responses, prompts, guard calls, writes,
and text-similarity cases using Python 3.11 without network requests. The output
pins the reference source hash. Review fixture changes before committing.

From the repository root:

```sh
python3 core/test/marginalia/record_oracles.py
cd core
dart test -j 1 test/marginalia/marginalia_test.dart
```

Flutter interaction checks are in `app/test/marginalia_sheet_test.dart`.
