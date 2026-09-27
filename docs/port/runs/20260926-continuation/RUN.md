# Codex continuation after Claude handoff — 2026-09-26

## Objective and acceptance

Continue from Claude's Flutter development commits through `78a0cbb` on
`flutter-2.0`, preserving all existing changes and live oracle receipts.
The user asked Codex to continue after Claude helped. The latest handoff says
to prioritize functional Flutter work, no longer block implementation on full
A0 recording, and perform heavy builds on the home Mini.

This increment covers native grounded questions, the temporal knowledge graph,
character linking, book/chapter policy, and the processing runner and worker
connected to Flutter. The user explicitly requested parallel subagents to speed
up completion. Verify Python request/output parity, cutoff and cache isolation,
errors, cancellation and interrupted processing; build a signed probe package
and inspect its actual UI. The Dart HTTP server and full upgrade acceptance
remain unfinished work. No live model requests are needed for reference tests.

## Preserved state

- Pre-edit tracked source is in Git at `78a0cbb`; existing live cassette changes
  and new files were present before this continuation and are left intact.
- Pre-edit files: `book/backups/20260926-codex-continuation/` and the KG/link
  agents' dated backup directories.
- The full prior status is retained in `STATUS-before.md` alongside this report.
- Home Mini build workspace remains `~/.local/share/thusfar-build/src/`;
  Flutter is pinned to the same SDK as the previous build. Release signing
  stays on NAS. The probe package is `com.yedu.zhupi.v2probe`.

## Implementation at recovery

- Chapter/book policy has exact offline Python request/result fixtures,
  supplementary Unicode truncation, judge batching, and fallback coverage.
- `chatJson` now implements the original single-repair behavior. Its usage
  return intentionally follows the Python oracle (first request only), including
  the existing limitation that repair tokens are not included in that value.
- Fixed a pre-existing compile error in `judge.resolveMentions`: its block
  index now has an explicit `int` type.
- Link module: all 1,932 historical samples and 21 independent request/state
  scenarios pass, including two-segment link → plan → commit integration.
- KG, grounded questions and the processing loop are complete for this increment.
  Final receipts below supersede the intermediate build records.

## Resume rules

Read this record, `STATUS.md`, the actual Git diff and managed task state before
resuming. Do not restart oracle recording, call models, overwrite 1.7.x phone
data or repeat a build/installation based only on a missing terminal message.
Query any submitted managed task by its original ID. No push or release is
authorized by a successful probe build; history publication has an existing
private-fixture restriction documented in the prior status.

## Daemon recovery and execution evidence

The daemon restarted while runner, worker and processing UI agents were active.
Their files survived but the agents did not. Replacement tasks are
`/root/runner_recovery`, `/root/worker_recovery`, and `/root/ui_recovery`.
Runner finalization was still missing at recovery, so successful earlier builds
do not cover the processing integration.

- Mini task `7b4f1cbe-b4e7-4bc1-a319-bbcab3c2b70c` exited 0. Its original ID was
  checked rather than resubmitted. The ask-only snapshot passed screenshot
  rendering and produced a 25,717,318-byte probe APK. It is not the final runner
  build and has not been installed by this continuation.
- The preceding Mini core suite completed successfully and app analysis was
  clean. Four targeted ask widget tests passed after a test-only missing pump
  was corrected. Final counts will come from machine-readable receipts.
- Nine screenshot artifacts and Mini logs are archived under
  `book/reports/20260926-continuation/`; shelf, reader and character card images
  have been visually inspected. These are generated receipts, not baseline
  equality claims or device screenshots.
- `app/lib/data/` was accidentally excluded by the root `data/` ignore rule.
  A narrow exception now makes the application source visible to Git while
  local book data remains ignored. Include these sources in the eventual
  reviewed commit.


## Integrated processing acceptance

- Runner fresh Aq replay at concurrency 1 and 12 matched every one of the 154
  normalized Python artifacts. Each run used 21 recorded model requests and
  82 judge requests, with zero cassette misses and no live network fallback.
- Paused Aq 4/9 resumed to 9/9 and matched all 154 artifacts in its own Python
  resume receipt; 13 model and 46 judge requests were replayed. Existing cached
  prefix and notebook byte hashes were preserved. This does not erase the
  historical difference between fresh and resumed Python usage receipts.
- Worker and real Runner lifecycle checks passed, including lease retention,
  cancellation boundaries, source fingerprint mismatch and cache replay.
- Mini preflight `01550cac-ac98-49c1-baa3-97dfa46a1d1a` saw an in-progress backup
  helper and failed analysis; after the source finished, replacement preflight
  `ade4e027-6df0-4ac6-9662-3c42a7901c4e` exited 0 with app analysis and processing,
  backup, import, ask and settings tests all passing.
- Final Mini verification/build submitted as
  `c024f48e-e58b-43a9-adf6-0d6b2cdbc408`. Query this original ID after interruption.
  Logs are under `~/.local/share/thusfar-build/receipts/20260926-final-processing/`.
- Android release was missing INTERNET permission (confirmed with aapt on the
  actual installed dev.1 APK), now corrected in the main manifest. Native VIEW
  and SEND imports and the Dart queue have been added, with cold/warm tests.
- Existing dev.1 probe (versionCode 20) was pulled to the dated backup directory
  before installation. Its signing certificate SHA-256 is
  `2228582f6dfcccc2988ad53b8026b7be3d652fe661dd06ac95b119a318a29acc`.
  The baseline device screenshot showed the empty-library onboarding screen.
  Lease cleanup was confirmed with interactive=false. No production package or
  library was replaced.


## Device regression and corrected build

The dev.2 probe was installed (versionCode21, INTERNET granted). Native file
manager VIEW import of the public-domain Aq backup showed 37 people and preserved
reading progress. Reader, character card and cutoff-labelled ask screenshots
were captured. Returning through the launcher later showed the original empty
shelf. The symptom is consistent with an old Activity model remaining alive;
disk persistence was not independently established at that point.

The main Activity now uses singleTask, and HomeShell rescans durable library
data after resumed, following completion of its own import queue. The regression
test publishes a book through a second Library, verifies that the original UI is
stale, resumes it and checks both refreshed visibility and unchanged running
status bytes. Initial Mini check `09af02b9-c692-4187-b1ce-81463d98ccf7` failed
only because pumpAndSettle waited for the intentional running-book animation;
the test now uses bounded pumps with the original assertions preserved.

The corrected build is dev.3 / versionCode22. Managed task
`c5dca0bd-84d4-4f99-b442-c7517159dbac` exited 0: clean analysis, all four shared-import
tests passed and release build succeeded. Final device evidence is appended below. File manager sort was restored to
its original filename order. Phone lease cleanup was confirmed after dev.2 checks.


## Final automated validation and artifact

The full Mini task `c024f48e-e58b-43a9-adf6-0d6b2cdbc408` exited 0. Full core:
1,779 pass / 521 explicit skips / 0 fail. The subsequent 20 helper/lifecycle tests
contain 12 unique additional cases and 8 reruns: **1,791 unique passing core tests**.
App suite: 25 pass; final shared-import suite adds one unique resume test for
**26 unique passing functional tests**. Screenshot suite: one test, ten outputs;
these are review images, not unchanged-baseline comparisons. No offline test
fell back to live model requests. Saved machine-readable receipts are under
`book/reports/20260926-continuation/`.

The final signed artifact is
`book/reports/20260926-continuation/artifacts/yedu-2.0.0-dev.3-probe.apk`.
It is 26,642,601 bytes, package `com.yedu.zhupi.v2probe`, versionCode 22,
versionName `2.0.0-dev.3`, arm64. SHA-256:
`74f23087500ab2decab5d355ac6925daa7412743b4009eea997ce368e6cf577c`.
APK signature v2/v3 verification passed, certificate matches the backed-up
probe, and INTERNET permission exists in the actual release manifest.

An independent final read-only review resolved all 76 reachable app/core Dart
files in the Git index, both font assets and essential fixtures. The 101 exact
Aq cassette dependencies are indexed and byte-identical to the worktree; the new
whole-book tests do not depend on untracked cassette additions. Existing unrelated
live recordings remain unstaged. No push or release was performed.


## Final device outcome

At 2026-09-26 10:30:53 Asia/Shanghai, MIUI updated the existing probe from dev.2
to dev.3. `dumpsys package` confirms versionCode 22 / 2.0.0-dev.3, original
firstInstallTime retained, and INTERNET granted. No production package was
updated. Installation stayed inside the exclusive phone-exec GUI lease.

Before any new import, the updated app displayed the original Aq book, 37 people
and 11% reading progress. A reader → shelf → file manager → app round trip again
displayed one Aq book with the same progress and people count. This establishes
that the earlier dev.2 empty shelf did not reflect deletion of this saved book;
the singleTask/resume-refresh correction passes this device regression.
Screenshots and UI trees: `device/dev3-first-open`, `device/dev3-reopen-retained`,
with package receipt `device/dev3-package.txt`, under the dated report root.

Live model processing, complete 1.7.x in-place migration, Android background
survival, broader book parity and second-device acceptance remain release work.


The final reader screenshot shows the retained chapter/page 9 of approximately 84
and linked character mentions. The phone session exited 0, then `phone-exec status`
reported `interactive=false`; the screen is off. Final validation report:
`book/reports/20260926-continuation/FINAL-VALIDATION.md`.
