# Regression reference only

The supported Thusfar product is the Flutter client in [`../app/`](../app/README.md)
and the Dart engine in `../core/`. The browser build is `app/lib/main_web.dart`
and is published from `app/build/web`. Nothing in this directory is shipped by
those builds or the current GitHub Pages workflow.

This directory preserves the frozen Python 1.7.5/browser behavior needed to check
the Dart port. It is not a maintained app, a self-hosting option, or a second
Android client. The old Docker configuration, environment example, Java/Chaquopy
Android wrapper, and operational launch/check scripts have been removed. Old
versions can still be recovered from Git history; no history was rewritten.

## Why these files remain

- `pipeline/` and `server/`: Python reference algorithms. The current Dart tests
  verify the recorded worker/link source hashes and compare their behavior.
- `oracle/`: public-domain/synthetic books, no-spoiler cutoff goldens, recorded
  model replies, and replay/verification tools. Flutter screenshot/import tests
  and Dart processing/parse/semantics tests consume these fixtures.
- `web/` and `tests/`: browser/Python behavioral checks. In particular,
  `oracle/record/fold.mjs` imports the old browser graph implementation to verify
  its 20-cutoff no-spoiler fixtures, so deleting the web code would remove a
  reproducible comparison, not merely a deployment surface.
- The optional Dart HTTP comparison harness is `../core/tool/reference_server.dart`;
  it serves `reference/web/` only when explicitly run for development.
- `scripts/`: offline reference tools still named by recorded contracts. The
  `build_release.py` snapshot functions remain only because the frozen port
  ledger includes six tests of their data/credential exclusion behavior.
- `docs/` and `testsets/`: historical design and port evidence.
  Paths and version claims in historical records are relative to this reference
  root unless explicitly identified as current Flutter paths. Obsolete operational
  notes and dated build/run status logs are removed from the current tree and
  remain recoverable in Git history.

All moved fixture bytes and reference algorithms are unchanged. Their stored
provenance remains historical evidence, not a claim that a new recording happened
when the files were relocated. Full strict input-provenance verification belongs
at the recorded `source_commit`; do not replace its hashes to make a newer source
tree appear to be that original run.

## Offline checks

From the repository root, with Python 3.11 (Unicode 14.0.0) and Node available:

```sh
export PYTHONPATH="$PWD/reference:$PWD"
python3 scripts/check_reference_layout.py
python3 core/tool/generate_ported_tests.py --check
python3 reference/docs/port/check_test_scope.py
python3 scripts/generate_book_policy_tables.py --check
python3 -m unittest discover -s reference/tests
(cd reference && python3 -m oracle.record.verify_folds)
```

Fixture-recording tools under `core/test/` resolve this directory explicitly.
Run the reference tools from this directory when their historical command uses
`python -m oracle...`. Replay uses recorded replies; never invoke a tool's live
record mode as part of routine regression checks.

Current client tests still run from `app/` and `core/` as described in the client
and contributor guides. Existing skips in the historical Dart port ledger remain
skips, not passing assertions. See [`docs/port/TEST-PORT-SCOPE.md`](docs/port/TEST-PORT-SCOPE.md).

## Historical audit status

The optional full Dart audit preserves every existing assertion and reports its
raw outcome and complete log. It is separate from the required client/recovery
and browser checks: the original source tree already fails six expectations
(three historical model-name suffix expectations and three replays whose newer
biography request has no recorded cassette). No model requests are made to fill
those gaps during cleanup. The full Python baseline likewise already has eight
failures and seven errors across 351 tests. Neither audit is described as green
merely because its existing failures are non-blocking.
