# Reader comments: port and verification

`core/lib/marginalia.dart` exports `MarginaliaService`, `MarginaliaBackend`, `MarginaliaCancellation`, the pure helpers, persona tables, and shared top-level `respond(root, data)`.

`MarginaliaService` accepts synchronous `readJson(File)`, `writeJson(File, Object?)`, optional `graphRevision(File)`, a backend and timeout. `respond(Directory, Object?, {cancellation, onEvent})` supports the original `manual`, `auto`, and `cues` request bodies. HTTP should reuse one service rather than allocate a new gate set for every request. The default top-level function already uses a shared service.

The service reproduces selection, UTF-16 anchoring, prefix material, persona prompts, one manual rewrite, automatic multi-angle deduplication via Python-compatible SequenceMatcher, judge acceptance, 2,000-record persistence, per-key coalescing, and model/prefetch/comment gate sizes 3/2/4. Cancellation and timeout hide late output; gates remain held until pending requests settle. User notebook files are never written by this feature.

Intentional native changes:

- Default cache identity hashes source/graph content and routing/model settings, instead of the Python inode/mtime tuple. The original key algorithm remains available and the historical revision can be injected for exact oracle comparison. Existing cache rows are retained. Same-timestamp graph changes and changed endpoints invalidate native cache entries.
- Cached comments must have a supported guard and a matching source anchor before display. Corrupt cache structure raises an error and preserves the file rather than silently replacing it.
- Source/graph/settings changes during a request prevent stale output publication and persistence.

`record_oracles.py` must run with Python 3.11. It records 12 independent Python response scenarios, complete prompts/judge calls/writes, and 8 SequenceMatcher comparisons. It makes no network request. Historical helper/key captures are reused from `oracle/goldens`.

Validation completed on 2026-09-26:

- `dart test -j 1 test/marginalia/marginalia_test.dart --reporter expanded`: 30 passed.
- Targeted Dart analysis of core, sheet and widget test sources: no issues.
- Five Flutter widget tests are authored in `app/test/marginalia_sheet_test.dart`; execution is pending the root agent's Mini batch. They cover captured selection/persona/cutoff, verification failure/retry, rewind cancellation, cues to multi-angle comments and return to the full-page range, and disposal before late failure.

The Flutter sheet is `app/lib/sheets/marginalia_sheet.dart`. `MarginaliaPage(link, start, end)` handles manual selection; `pageMode: true` first selects cues from the captured page. Root has inserted the reader selection and toolbar hooks. The service reads configured model and protocol dynamically. No relay provider is embedded in this sheet or service. No live model call, phone operation, heavy NAS Flutter build, staging, or commit was performed by this workstream.
