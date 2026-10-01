# Ported test contracts

`manifest.json` maps each reference Python test to one identically named Dart
test. The generator checks IDs, source hashes, owners, assertions, and skip reasons.
Translated but skipped tests do not establish that their behavior passes in Dart.
See [script-tool contracts](../../../reference/docs/port/TEST-PORT-SCOPE.md) for
those test owners.

From the repository root:

```sh
python3 core/tool/generate_ported_tests.py --check
python3 reference/docs/port/check_test_scope.py
cd core
dart analyze --fatal-infos --fatal-warnings test/ported
dart test test/ported
```

When implementing an adapter, preserve the original setup and assertions,
remove its skip only when executable, and update the manifest status and counts.
The generator’s `--write` creates skeletons; `--force` can discard translations.
