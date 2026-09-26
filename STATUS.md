# Thusfar 2.0 development status

Updated 2026-09-26 on `flutter-2.0`. The current objective is a native Flutter
reader with a pure Dart engine and compatible 1.7.x data. The user changed the
execution order: prioritize working Flutter features, allow implementation while
reference recording remains incomplete, and build on the home Mini. The former
A0-only gate and ¥1 recording cap are superseded.

## Verified implementation

| Area | Current evidence |
| --- | --- |
| Foundation and parsing | Claude's prior handoff records provenance/language/models/storage ports, Python-compatible regex and JSON, TXT/EPUB parsing, 16 parsed goldens, and 40 local EPUB comparisons. These earlier claims are preserved in the historical status. |
| Graph folding | The existing Dart fold has 6 books × 20 cutoffs compared with the JavaScript oracle. |
| Model clients and extraction | Existing streaming chat/JEV/extract/local/judge modules are retained. This continuation fixes a judge block-index compile error and adds exact single-repair `chatJson` behavior. |
| Character linking | 36 dedicated tests cover 1,932 captured helper rows and 21 independent Python request/state scenarios, including two-segment link → plan → commit integration. |
| Knowledge graph | 71 dedicated tests cover 1,815 historical method rows, 48 captured commits plus 4 synthetic states, and 28 complete-input Anchor cases. Historical Anchor captures missing block context are not counted as complete calls. |
| Book/chapter policy | Python-recorded request/result fixtures, fallback and Unicode decimal/large-ordinal cases exercise classification and work boundaries. |
| Grounded questions | Native ask/temporal logic covers retrieval, routing, verification/rewrite, citations, cutoff enforcement, cache invalidation, timeout and cancellation. The Flutter ask sheet has four passing interaction tests on Mini. |
| Model settings | OpenAI Compatible, Gemini and Claude Compatible, custom endpoints, protected private storage, and stateless current-form probes. Core and Flutter protocol/routing/regression tests pass. |
| Reader | Existing shelf, import, pagination, character cards, graph, TOC, notes, search, recaps and typography UI remains. Ten screenshot receipts were generated; shelf, reader, character card and grounded-question UI were inspected. |

## Native services and UI continuation

The latest continuation implements the standalone Dart HTTP service, validated
manual-entity overlays, source-grounded marginalia, notebook/reading-list parity,
and three generic provider protocols. The full Mini core run passes **2,166 tests
with 509 explicit skips and zero failures**. Twelve personal-service contracts
were reconciled with the golden registry; remaining skips are still unexecuted.

A dedicated UI agent authored [173 base end-to-end cases](docs/testing/UI-E2E-MATRIX.md),
[an execution template](docs/testing/UI-E2E-RUN-TEMPLATE.md), a blank results CSV,
and a generated source-control inventory. Option/theme/device variants require
separate results. Cases begin NOT_RUN; successful widgets, APIs and screenshots
cannot establish physical interaction acceptance.

The continuation corrects unlabeled graph edges, missing note-edit entries,
book-note navigation, reader back behavior, unsaved-settings probes, source/search
preview cutoff, selection cutoff/UTF-16 boundaries, and current-page footnote
access. Graph role direction, ended state, replay, zoom and large-text/dense layout
have focused functional and screenshot checks. Physical dev.4 tests exposed
default graph drawer clipping, an accessible replay-page mismatch, and keyboard
animation rewinding the reader after note save. These are corrected in dev.5+24,
whose full app suite passes 77 tests with clean analysis. The same probe package
was updated to dev.5+24 on the Xiaomi at 12:14:52; the initial shelf and reader
retained one Aq book, 37 people, 28% progress and page23 without reimport.
Physical dev.5 retests passed: default graph entry shows a complete father/son
relationship card, its detail opens correctly, the accessible replay label agrees
with visible page23, and a multiline note save keeps page23. Exported data
retains pos5799/cutoff6086/pct28.002, the prior note at revision2, and exactly one
new note at revision1. The full 173-case matrix remains pending; these are
scoped device variants. Whole-paragraph/offscreen reader accessibility spans
remain a separate known acceptance gap. See
[the active run record](docs/port/runs/20260926-services/RUN.md).

## Earlier integrated processing and validation

Three parallel agents completed Runner, Worker and Flutter integration after the
daemon recovery. The Runner supports two-phase/classic processing, source and
cache validation, bounded concurrency, cooperative cancellation, usage accounting,
quality retry and finalization. The Worker supplies explicit start/pause/resume/
retry and startup reconciliation without automatically issuing paid requests.
Flutter uses a dedicated isolate and refreshes progress and open-book graph data.

Fresh Aq at concurrency 1 and 12 each matched all **154 normalized Python
artifacts**, with 21 model and 82 judge cassette calls per run. Paused Aq 4/9
resumed to 9/9 and matched all 154 artifacts in its own Python resume receipt,
with prior prefix caches unchanged. All three were offline with zero cassette
misses. Complete-book parity is established for Aq; classic full fresh-book
parity and other complete books are not claimed.

Final saved receipts establish **1,791 unique passing core tests, 521 explicit
skips and zero failures** (1,779 in the full suite plus 12 additional lifecycle/
helper tests). The app has **26 unique passing functional/widget tests** and one
screen suite rendering ten images. Core and app analysis are clean. The remaining
skipped port contracts are not successful tests; the registry still needs
reconciliation with implemented source.

Backup imports validate before publication and reject conflicting books; damaged
personal data cannot be silently exported as empty data. Native Android VIEW/SEND
and the in-app picker share a serialized queue. The main Activity uses singleTask,
and resume refreshes the durable library without restarting paid processing.

## Build and device evidence

The existing pinned SDK is Flutter 3.47.5 / Dart 3.13.4, revision
`6a19cca56475dbfba1478ee68d7bd0c2ef891da1`, on both NAS and the home Mini.
Python reference generation uses `/home/dev/.local/bin/python3.11` (Unicode 14).

Mini verification/build `c024f48e-e58b-43a9-adf6-0d6b2cdbc408` completed the full
suite and processing APK. A device-observed stale shelf after external import
led to the Activity/resume fix. Follow-up
`c5dca0bd-84d4-4f99-b442-c7517159dbac` passed all four shared-import tests and
built **2.0.0-dev.3 / versionCode 22**. Its signed probe APK is 26,642,601 bytes:

- SHA-256: `74f23087500ab2decab5d355ac6925daa7412743b4009eea997ce368e6cf577c`
- Package: `com.yedu.zhupi.v2probe`; verified v2/v3 signing with the existing key.
- INTERNET is present in the actual release APK, correcting the earlier probe.
- Saved validation receipts: `book/reports/20260926-continuation/`.

The dev.2 device check verified a native public-domain Aq backup import, 37
people, reading progress, reader/character card and cutoff-labelled ask UI.
The dev.3 probe was installed and verified as versionCode 22. Without reimport,
the existing Aq book, 37 people and 11% progress survived the update and a
reader → file manager → app round trip. The stale-shelf regression passed. The production `com.yedu.zhupi` and its data were not
replaced. This is a development probe, not full production upgrade acceptance.

`app/lib/data/` was unintentionally excluded by the root `data/` ignore pattern.
A narrow exception now exposes this essential source to version control while
local book libraries remain ignored. Include it in the reviewed source commit.

## Remaining release gates

- Broaden whole-book parity beyond Aq, including classic fresh-book processing;
  complete real model processing/background acceptance on devices.
- Execute the complete UI regression matrix and required variants on actual devices/browser, including deterministic model-success/error scenarios. Native manual entities, marginalia and HTTP services are implemented; full user-workflow acceptance remains separate from core/widget evidence.
- Verify full 1.7.x in-place upgrade and data retention, on-device processing and
  background behavior, performance requirements and the second-device checks.
- Reconcile the manifest and skipped contracts, establish required coverage,
  and complete outstanding oracle evidence without presenting partial recordings
  as whole-book acceptance.
- Only after all acceptance gates: archive the Python oracle, remove the legacy
  runtime/shell, update self-hosting delivery, and publish 2.0.

No push or release has been performed. Existing live cassette changes and receipts
predate this continuation and are preserved. No live model request was made by the
offline checks described here. The early branch history still contains a withdrawn
literary fixture; publication requires resolving that recorded history restriction.
See [the preserved historical status](docs/port/runs/20260926-continuation/STATUS-before.md)
for provenance, archival hashes, partial-corpus limitations and previous evidence.
