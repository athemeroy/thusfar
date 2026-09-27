# Full UI regression run record

Copy this template to a dated report directory. Do not record mutable run state in the permanent matrix. The specification is [UI-E2E-MATRIX.md](UI-E2E-MATRIX.md), with foldable variants in [FOLDABLE-UI-REGRESSION.md](FOLDABLE-UI-REGRESSION.md). Start from `ui-e2e-results-template.csv` and `foldable-e2e-results-template.csv`; every row is initially NOT_RUN. Add a separate row per required device, posture, theme, protocol, control option, and input boundary variant. Never fill PASS from a unit-test count.

## Identity and environment

- Run ID / tester / start and finish time:
- Source commit / dirty-diff hash:
- APK filename / SHA256 / package / versionName / versionCode / signing fingerprint:
- Upgrade-from version and package (or clean isolated probe):
- Device alias / model / Android version / OS build / screen pixels / density:
- Physical foldable model/posture and observed Flutter display-feature bounds/state, or explicit `SIMULATED` profile:
- System text scale / display scale / keyboard and language / screen-reader mode:
- App theme / paper / font size / font / line spacing / animation / volume-key setting:
- Browser / version / viewport / W or standalone S / server commit (if in scope):
- Device executor lease ID / permitted test-library path / pre-run backup path:
- Fixture manifest paths / exact file SHA256 / source offsets of C0, C1, C2:
- Model protocol / model / redacted endpoint host / deterministic response profile / request-receipt directory:
- Live model use authorized and exercised: yes / no. Never record API keys.
- Scope: full A; full W; full S; or explicitly listed narrower checks. A smoke run is not a full regression.

## Readiness checklist

- [ ] The candidate APK installed and its actual package/version verified; screenshot shows running candidate.
- [ ] Reused test data backed up and isolated from production. Destructive cases use a disposable copy.
- [ ] F0–F9 needed for this run exist and hashes are recorded. Synthetic F5 graph has an independent directional-role/cutoff oracle.
- [ ] F8 server is reachable from this device and records redacted protocol/path/model/request counts. It cannot accidentally relay test failures to a live provider.
- [ ] Phone guide read; all GUI actions use one `phone-exec run` lease; actual screenshot proves usable screen, not merely connected ADB.
- [ ] Source inventory regenerated with `python3 docs/testing/generate-ui-inventory.py` and unassigned changed controls reviewed.
- [ ] All protocol options and required small-screen/dark/large-text variants are present as separate result rows.
- [ ] All 155 Android base cases have separate `@folded`, `@open`, and `@tabletop` rows; FL-001–FL-010 are present. Physical posture checks are not substituted by simulated screenshots.
- [ ] Capture directory ready. Secret entry/reveal uses only dummy test credentials; screenshots redact personal data.

## Practical run order

This order reduces repeated setup without removing test cases. Within each group follow the numbered UI steps in the matrix. A failed P0 is recorded immediately; independent safe groups may continue. Repeat the affected path after a fix on a newly identified build.

1. **Launch and empty state:** F0; A-001/A-002; picker cancel B-005; all empty states; M-003; P-001. Record zero network traffic before explicit network actions.
2. **Protocol configuration:** M-001–M-013, separately for OpenAI Compatible/Gemini/Claude Compatible. Save the real request receipts. Test unsaved edits, credential replacement/clear, in-flight double taps and late callbacks.
3. **Bring books in:** F1/F6/F7; B-001–B-007/B-016–B-020. Open every successfully imported book, background/launcher/Recents reopen, and confirm native handoff persistence.
4. **Shelf and queue:** A-003–A-011; every filter/sort/view; add/reorder/remove; every cover/list/menu entry. Use at least three books with distinct progress.
5. **Read and write:** R-001–R-012/T-001–T-005; C-001–C-006/S-001–S-006; N-001–N-010. Test every field and IME, real gestures, clipboard, draft/edit/delete/undo, and cold reopen.
6. **People and graph:** H-001–H-006/U-001–U-010; G-001–G-015. Start with default-label screenshot before selecting anything. Compare Alice/Bob inverse roles and actual ended/temporal relationships against F5 oracle. Test compact and full graph, zoom/replay/details/dark/large text.
7. **AI at the reading boundary:** Q-001–Q-011/J-001–J-008. Include accepted/withheld/failed/slow/cancelled replies; inspect every citation's source context for unread sentinel leaks. Verify each configured protocol via actual transport receipt.
8. **Worker lifecycle:** P-002–P-010 plus B-015. Start/pause/continue/retry, read while running, two-book queue, background/recreation, cancellation settling. Distinguish “session alive” from actual job/business completion.
9. **Preservation and destructive cases:** B-008–B-015/B-021. Export all personal content and restore a separate copy before removal. Confirm existing data across actual candidate upgrade without reimport.
10. **Web/PWA:** W-001–W-018 on the relevant platform. Hosted login/sync/offline tests stay separate from Android standalone config. Check keyboard and multi-client conflicts.
11. **Universal control sweep:** X-001–X-010 for every visited screen. Compare the source inventory to the completed control ledger below; no uncovered field/icon/action is silently omitted.
12. **Foldable posture sweep:** run the 465 posture variants and FL-001–FL-010 on a real foldable, including every field and button from each base case on the outer display, open-book displays, and tabletop. Preserve `@folded`, `@open`, and `@tabletop` evidence independently. Use viewport simulation only for supporting Flutter layout evidence.
13. **Finish:** collect crash logs/request receipts; verify probe library final state; close only task-owned test services and executor leases; turn phone screen off; calculate executed/PASS/FAIL/BLOCKED/NOT_RUN separately.

## Screen-by-screen control sweep

Mark a cell only after actual activation. Attach per-screen recording or before/after sequence. Add any control introduced after the source audit. This checklist checks that a click occurred; individual matrix acceptance and durable assertions are still required.

| Surface | Controls/inputs that must actually be used | Evidence / remaining gap |
|---|---|---|
| First run | `从手机选择书`, `恢复备份`, `去填写`, all three bottom tabs | |
| Shelf | Search field/cancel, four filters, four sorts, grid/list, import expanded/compact FAB, covers/list rows/continue/menu/long press | |
| Queue | Add/rank/remove in drawer, queue card, edit, reorder drag, minus control, empty state | |
| Book drawer | Start/continue reading, `我的摘记`, queue, export, remove warning/export/confirm, processing controls in every state | |
| Model settings | Three protocols; URL/model/key; eye/replacement/clear; Save/Test; keyboard/back; success/slow/error states | |
| Settings | Eleven font sizes; three animations; volume toggle; three night modes; export-all/restore; truthful about/privacy/version | |
| Reader | Left/right/center taps, swipes, selection drag, all five selection actions, Back/bookmark/search/more, four overflow items, five bottom tools, footer `注释 N` and full/copyable footnotes | |
| Reader progress | Previous/next chapter, page slider, return chip and close, first/last boundary, volume keys | |
| Typography | Font slider all values; three spacings/fonts/animations; five paper swatches; volume switch; dismissal paths | |
| TOC | Three tabs, page-number input + IME Go, read/unread chapter/confirm, bookmark tap/delete/undo, notes toggle/export/row | |
| Search/preview | Search field, two scopes/whole-book CTA, result, reveal/close/jump, return; cutoff-edge context | |
| Notes | Search/clear, four filters, row/source/edit/save/delete, swipe/undo, empty state, draft dismissal/reopen | |
| People/person | Four tabs/search, row/name/footer-avatar, first appearance, relations/compact nodes, event order/event preview, ask/graph links | |
| Manual editor | Kind, name, note, save, edit, delete/cancel/confirm, errors, lock/conflict, keyboard/back | |
| Full graph | Default edge label, node select/reselect, relation detail and endpoints, card, pinch/pan/zoom/reset, replay/scrub/pause/resume/current | |
| Recap | Event source, each chapter expand/collapse, empty/partial state | |
| Ask | Three suggestions, field/clear/paste/IME/send, citation, retry/settings, history scroll and closing while pending | |
| Marginalia | Five personas, generate/auto/page cues/cue selection/regenerate, stop/retry/settings, copy/source, pending dismissal | |
| Native dialogs | Picker single/multi/cancel; export save/name/location/cancel; external VIEW/SEND/MULTIPLE; launcher/Recents/back | |
| Web-only | Login/language, workspace links, reading queue sync/conflicts, notebook filters/paging/sync, offline download/update/cancel/remove | |
| Every sheet | Expand/collapse/content scroll, header back, Android Back, scrim, swipe-dismiss, IME visibility, accessible labels | |

## Per-case result record

Use one row per case/variant, or the CSV. Allowed states: `NOT_RUN`, `PASS`, `FAIL`, `BLOCKED`, `NOT_IMPLEMENTED`, `N/A`. N/A requires a concrete platform/scope reason; “not enough time” means NOT_RUN. Supporting automated checks have their own evidence column.

| Case / variant | Build / fixture / initial source position | Exact performed steps | Expected | Actual | Status | Visual/interaction evidence | Durable/network evidence | Defect / retest |
|---|---|---|---|---|---|---|---|---|---|
| G-001 / A / light / normal text | | | Default edges show roles without selection | | NOT_RUN | | | |
| G-002 / A / inverse role / compact | | | Bob=Alice's student; Alice=Bob's teacher | | NOT_RUN | | | |
| M-002 / A / Gemini / edited visible endpoint | | | Request matches visible config or explicit unsaved-state block | | NOT_RUN | | | |
| S-004 / A / cutoff-edge citation | | | No unread sentinel in context | | NOT_RUN | | | |
| N-006 / A / edit saved note | | | Existing ID preserved with changed text | | NOT_RUN | | | |

## Required evidence naming and assertions

Suggested names: `<case>__<platform>__<variant>__<step>.<png|mp4|json|txt>`. Keep a manifest mapping filenames to case IDs and SHA256. Example graph evidence:

- `G-001__A__light__default.png`: whole screen before selecting a node; enough resolution to read relation labels.
- `G-002__A__teacher-student__alice.png` and `...__bob.png`: selected endpoints with exact inverse labels.
- `G-003__A__long-role__detail.png`: full directional roles, explanation and ended state.
- `G-007__A__C1.png`, `...__C2.png`, `...__rewind-C1.png`: temporal label/visibility comparison against offset manifest.
- `G-009__A__play-pause-scrub.mp4` and `G-011__A__zoom-reset.mp4`: actual interaction sequence, not separate static renders.
- `M-012__A__gemini__requests.json`: redacted protocol/path/model/status/request count; no API key.
- `N-010__A__restored-backup.json`: test-data-only export with exact note/manual/history assertions; avoid production journals.

For a failing case, save evidence before attempting a fix. Include initial state, exact interaction sequence, actual visible text, expected text/behavior, reproduction frequency, and whether restart changes it. An unexpected empty view must be investigated against data state; do not call it “no data” without checking.

## Release decision

- Planned cases / expanded variants:
- Actually executed:
- PASS / FAIL / BLOCKED / NOT_IMPLEMENTED / NOT_RUN / N/A counts:
- P0 unresolved IDs:
- P1 unresolved IDs:
- Every text field and visible control activated: yes / no, missing IDs:
- Default graph relation labels visually verified: yes / no; evidence:
- Direction/ended/cutoff/zoom/replay graph gates verified: yes / no; evidence:
- Local data retention / backup restore / actual upgrade verified separately: yes / no:
- Automated tests (separate count/link; not added to E2E PASS):
- Actual live-model acceptance, if included (provider/model/receipt; no secret):
- Known platform gaps / untested device or protocol:
- Outcome: full regression accepted / failed / partial only. Reason:
- Final probe state and phone screen-off proof:

A successful limited smoke run may be delivered as a smoke run. It must not be described as “all UI passed.” No graph label acceptance can be established from an implementation assertion alone; the user-visible label and actual interaction must be reviewed.
