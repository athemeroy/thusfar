# Native services continuation — 2026-09-26

## Objective and acceptance

The user requested continued implementation after commit `8164947`. Complete
the remaining native service paths: standalone Dart HTTP/browser compatibility,
manual reader entities, and generated marginalia. Preserve 1.7.x personal data,
source coordinates, explicit processing authorization, idempotency and errors.
Validate with independent Python fixtures and real loopback HTTP/UI checks;
build on the home Mini and inspect the resulting probe. Do not publish or replace
the production phone package as a side effect of a successful build.

## Parallel ownership

- `/root/worker_recovery`: Dart HTTP service, CLI and HTTP tests.
- `/root/ui_recovery`: manual-entity service, reader overlay and editing UI.
- `/root/runner_recovery`: marginalia service, offline validation and Flutter UI.
- Root: notebook/reading-list/model settings services, integration, registry
  reconciliation where supported, Mini verification, artifact/device delivery.

Shared reader entry points are integrated by root. Agents coordinate reusable
core APIs directly. Backups are in `book/backups/20260926-services/`; receipts
are in `book/reports/20260926-services/`. Existing oracle cassette changes remain
untouched. Python fixtures use `/home/dev/.local/bin/python3.11`; focused Dart
tests may run serially on NAS, while Flutter/Gradle work runs on the home Mini.

## Recovery

Check the actual source and live agents before restarting work. Record managed
task IDs before waiting and reconcile them by original ID after interruption.
The previous signed, installed probe is dev.3/versionCode22, and the prior
continuation report contains its artifact and phone evidence.

## User steering and active acceptance

- The user rejected embedding XiaoJing AI branding or a relay preset. Model
  configuration now targets OpenAI Compatible, Gemini and Claude Compatible with
  explicit protocol, endpoint, model and key. Root owns core/app/web settings.
  Existing user-written settings are preserved; new defaults do not select a
  relay. Protocol/address changes require a newly supplied key or explicit clear.
- The user explicitly requested a dedicated agent for exhaustive UI end-to-end
  cases and steps, covering every input, button and navigation path. Agent
  `/root/ui_e2e_plan` owns this inventory and regression matrix. Widget/unit
  execution is not a substitute for physical/end-to-end UI acceptance.
- User-observed regression: Flutter relation edges had no relationship labels.
  Root confirmed `_Edges.paint` drew only lines and is implementing labels,
  selected-person direction, accessible details, short/long labels, zoom/replay
  and two-person graph checks before final UI acceptance.
- Marginalia agent finished: 30 passing core checks; five Flutter tests authored
  but not yet executed on Mini. Manual service has 117 differential cases and
  three persistence tests; manual UI and root protocol UI tests await Mini.
- Root personal services: 67 Python-derived notebook/reading-list/normalization
  checks passed. Initial eight protocol/settings tests passed; one additional
  Gemini resource/thought parsing test was subsequently added.

## UI audit and managed verification

- Dedicated UI matrix now has 172 base cases, 12 editable field source sites,
  exact procedures and evidence requirements. All initial E2E statuses remain
  NOT_RUN; widget passes do not close actual-device cases.
- Root corrected the book-notes destination, one-tap shelf return, preview and
  search context cutoff, UTF-16 clipping, and settings privacy/version text.
  Saved notes are being connected to edit/delete/undo with optimistic revisions.
  Current-page source footnotes now have an explicit reader footer entry.
- Connection tests use the current form through an explicit per-request LLM
  endpoint; they neither persist the draft nor change active model routing.
  Switching endpoint/protocol cannot reuse the previous key accidentally.
- Mini preflight `d1ad140d-9aeb-4c49-a1a6-256909c42495`: analyzer passed;
  two model tests lacked theme on reopening. Corrected test fixture.
- Preflights `082de784-ed63-473c-947d-3569ab137db3` and
  `e2e1351d-b923-4436-a7ac-066d093a742d` stopped at analysis (new service
  callback override/missing PageSpec argument, then graph tests staged before
  graph source). Both are superseded, not accepted runs.
- Preflight `c26ea351-9ba9-45b1-89bb-99e70b3e6adc` succeeded with reader,
  settings, manual entities, marginalia, backup, processing and Ask widget tests.
- Graph preflight `93b182d5-a4f2-496a-9ea2-b7aec8acade0` succeeded with
  8 graph + 5 reader regression tests and 2 screenshot scenarios. Actual image
  review rejected label readability: default second role/ended status were
  clipped, and long names displaced relationship text at large text scale.
  Graph labels are being corrected before final acceptance.
- Full core suite original task ID: `3b4d19eb-6b19-478c-8d4b-530e1bd615bc`.
  Logs: Mini `receipts/20260926-services-core/`.
- Candidate version is dev.4+23; build/sign/install have NOT completed at this
  checkpoint. Existing probe remains dev.3+22. Phone status is ADB reachable,
  unlocked and screen off; no phone GUI task has begun in this increment.

## Verified source and final interaction corrections

- Core task `3b4d19eb-6b19-478c-8d4b-530e1bd615bc` exited 0: 2,155
  passing tests, 509 explicit skips, zero failures, and clean analysis. The two
  non-JSON diagnostic lines in the reporter stream were retained separately
  during counting; final `done.success` is true.
- App task `daa1a150-fb56-4fc0-afbd-ca6551a822c0` exited 0 with clean
  analysis. Subsequent task `e966ea2d-3d20-4324-820d-459e7bdc9e0e` added
  graph tests, passed 68 functional tests and five screenshot scenarios, and
  built dev.4+23. That build is superseded pending the final corrections below;
  it has NOT been signed or installed.
- Screenshot inspection confirmed role-first labels fix hidden relationship
  wording. It also found label/node overlap at large text and overlapping
  dense Aq relation cards. These are being corrected and must be re-rendered.
- Review found selection could expand a word beyond the visible page and drag
  across paragraphs. `ReaderController.select` now clips to page and original
  textual block, keeping UTF-16 pairs intact; six targeted tests await Mini.
- Notebook paths use strict source validation and optimistic revisions, refresh
  independent records, show save errors, expose editor entries, and make undo
  a new revision. Final reader/Toc undo callbacks also handle reader disposal.
- Phone pre-check confirmed installed dev.3/versionCode22. No installation has
  occurred. A baseline APK pull did not execute because inherited stdin was
  consumed by a subprocess; the device helper now uses DEVNULL for child stdin.
  The first phone lease exited 0 and turned the screen off. Retry the backup
  explicitly and verify its artifact before upgrade; do not infer it succeeded.

## Final graph/source checks and upgrade preparation

- Final graph viewport uses readable relation cards, measured collision-free
  layout, reset-to-visible relationship, and zoom out to 0.3. Eight behavioral
  tests and four real-font screenshot scenarios pass; actual Aq/default/dense
  and narrow large-text PNGs were inspected. The source inventory now records
  173 base cases. Its blank result template remains entirely NOT_RUN.
- Mini delivery task `295b614b-27df-4248-a247-0239ce0b67bf` exited 0, clean
  app analysis, 38 final targeted tests and five screenshot scenarios. Across
  the earlier 68-test suite and this run there are 74 unique functional tests.
  This first dev.4 APK is superseded by the subsequent protocol audit below
  and was NOT installed.
- Upgrade baseline was successfully exported through the installed app to
  `book/backups/20260926-services/before-dev4-Aq.yedu.json`: 149271 bytes,
  SHA-256 `a360ace14b8eda8bc972b8b89123676f084eb60801883fc6297ff8cd355af012`.
  Actual current baseline is one Aq book, 37 people and 28% progress,
  position 5799/cutoff6086; it is not the older 11% run. Installed dev.3 APK
  was pulled and matches the prior artifact hash `74f23087500ab2decab5d355ac6925daa7412743b4009eea997ce368e6cf577c`.
- Independent offline protocol audit reproduced stale HOME .env route/key maps
  overriding saved form settings and a provider error echoing its request key.
  The model agent is correcting both with regressions before rebuilding.
  A phone lease opened for installation was closed without installing;
  screen-off cleanup was confirmed.
- Native HTTP/browser regression has 11 unique actual browser variants passed;
  final W-013 renders 13 relationships with all 13 labels inside the viewport.
  No model or external requests were made. Report lives under
  `book/reports/20260926-continuation/native-browser-20260926-111321/`.

## dev.4 actual-device findings and dev.5 corrections

- Protocol audit is resolved. Final core task
  `1c147e64-0119-4b0a-871d-d9f68c4071af` passed 2,166 core tests,
  509 explicit skips, 74 app functional tests, both analyses clean.
- Signed dev.4+23 is 27,035,817 bytes, SHA-256
  `5d3d9698abcb9766fba5f0e47118281edf7e7187e09fcb84b35b8fef65c74716`.
  ADB install was explicitly rejected by MIUI; dumpsys confirmed version22
  remained. The known File Manager/system-installer path successfully updated
  the same probe package to version23 at 11:49:04. Its initial shelf, before
  reimport, retained one Aq book, 37 people and 28% progress.
- Physical default People -> Graph FAILED: the drawer remained at 45% and
  clipped the graph's relationship card below the screen. Manual expansion
  proved relation details, zoom, rewind, play/pause and current-page restoration
  work. The graph agent fixed actual drawer expansion and an accessibility
  replay-page off-by-one, and fixed narrow/large-font People tab overflow.
  New actual-modal tests reproduce the original failure and now pass.
- Phone settings exposed exactly three protocols/default URLs. Missing-key and
  invalid-HTTP draft connection tests showed local validation; reopening
  restored the original unconfigured OpenAI form. About displays dev.4(23).
  No live-provider validation or phone packet trace is claimed.
- Visual page23 ends at UTF16 offset6086 ('拍拍'); page24 begins exactly at
  6086 ('的响了之后...'). Continuity is correct. Whole-paragraph/offscreen
  accessibility spans remain a separate recorded full-regression gap.
- One synthetic note was created through long-press -> 笔记 with CJK, newline
  and emoji, then edited through global notes. The UI shows one item with
  original source offset5800 and exact edited text. However note-modal IME
  open/close rewound the underlying reader from page23 to19: a second real
  regression, now being fixed by keeping reader geometry stable beneath IME.
  Tapping the actual global note restored reader page23 before cleanup.
- Graph-only dev.5 candidate task `e2d80c51-f265-4720-b93d-294324d67a85`
  passed and built but is superseded before signing/install by the IME finding.
  Candidate stays dev.5+24 until a corrected artifact is built and verified.
  Phone lease exited0; screen-off cleanup is checked separately.

## Final dev.5 artifact and physical retest

- IME regression was reproduced before the fix (expected source5633, actual4384).
  Stable reader geometry beneath the keyboard passed all23 focused reader,
  selection and note tests. Actual modal graph-entry tests now cover normal
  phone size and 320-wide/1.8 text. Mini final task
  `6247201d-eb6f-4311-b091-b921616fa96a` exited0 with **77 app functional tests**
  and clean analysis; core remains **2166 PASS / 509 SKIP / 0 FAIL**.
- Final dev.5+24 signed APK: 27,035,817 bytes, SHA-256
  `b6374bdaaad87e5bd821346de29588412ee60dff086d1a5f0f76b95ec8c364da`.
  v2/v3 signature verified. File Manager/system installer updated the isolated
  probe to version24 at12:14:52. Installed base.apk SHA matches exactly.
- First launch retained one Aq book,37 people,28% progress and reader page23.
  Default People45% -> Graph automatically expands and shows a complete readable
  father/son relationship card. Its detail shows both directions and description.
  Header, visible replay label and semantic SeekBar all agree on page23.
- Actual long-press -> NoteEditor -> CJK/newline/emoji -> Save now returns to
  page23. Global notes show the retained edited note plus exactly one new note.
  UI export verifies original pos5799/cutoff6086/pct28.002; old note revision2,
  new revision1, distinct IDs, correct quote/range5800:5814. Book/graph/metadata/
  mentions/assets/manual-entity payloads equal the original backup.
- Post-test portable backup is `book/backups/20260926-services/after-dev5-Aq.yedu.json`,
  150000 bytes, SHA-256 `8b03ed80a37cae4bde768bc5bc22ff6a6e42a7288f1713b393adc9eb4bc0d86d`.
  These two synthetic notes remain in the probe for inspection. About reports
  dev.5(24). The phone lease exited0 and status confirmed screen off.
- Independent identity audit verified all583 NAS manifest entries. NAS/Mini
  differ only in Gradle heap2g/4g and pub mirror URLs; all46 dependency versions,
  hashes and constraints match after URL normalization.
- Full acceptance is still pending:173 base cases plus required variants, model
  success/error/slow fixtures, other themes/devices, whole-reader accessibility,
  production upgrade and live processing. Do not replace NOT_RUN rows with PASS
  based on this partial retest. Detailed final evidence is in
  `book/reports/20260926-services/FINAL-VALIDATION.md` and device receipts.
