# Foldable-device UI regression

This supplement applies to the Flutter Android cases in [UI-E2E-MATRIX.md](UI-E2E-MATRIX.md). It keeps folded, open-book, tabletop, and rotation results separate. A base case passes only after its required posture rows pass; widget tests and simulated viewports do not replace a physical-device result.

## Viewport profiles

Record logical dp size, density, `MediaQuery.displayFeatures`, feature bounds/state, system insets, text scale, theme, and keyboard for every run.

| Profile | Simulated Flutter view | Expected layout |
|---|---|---|
| Folded cover | 360 × 800 dp, no separating display feature | Compact app with bottom navigation; every action stays within the outer display. Include 320 × 740 dp as the smallest-size check. |
| Open book | 840 × 900 dp; vertical hinge `Rect.fromLTWH(410, 0, 20, 900)`, `hinge`, `postureHalfOpened` | Main navigation and the active page occupy different displays. In the reader, the book page stays on one display and reading tools stay on the other. |
| Tabletop | 430 × 900 dp; horizontal hinge `Rect.fromLTWH(0, 430, 430, 20)`, `hinge`, `postureHalfOpened` | Main content stays above the hinge and navigation stays below. In the reader, the page stays above and page/tool controls stay below. |
| Wide landscape | 900 × 440 dp, no separating feature | Side navigation appears; reader text remains in a centered column no wider than 560 dp. |

These are repeatable test profiles, not claims about a specific manufacturer's outer display or hinge. Android supplies display-feature bounds in Flutter view coordinates. On a physical foldable, capture the actual view size, posture, hinge/cutout bounds, insets, density, and Android build rather than substituting the simulated values.

## Posture runs for all Android cases

Create three distinct result rows for every Android case in `ui-e2e-results-template.csv`:

- `CASE@folded`: run the complete case on the compact outer display.
- `CASE@open`: run the complete case with the book-open vertical feature.
- `CASE@tabletop`: run the complete case with the horizontal feature.

This includes every field entry, clear/cancel path, menu option, repeated tap, gesture, back action, modal, error state, persistence check, and expected network receipt from the base row. A control touched only in one posture does not satisfy the other posture rows. Use `foldable-e2e-results-template.csv` for the 465 base variants plus the posture-specific FL rows; FL-009 is split by posture, text scale, and theme, and FL-010 is split by posture. Keep W/S cases in their existing template; they are not Android foldable evidence.

## Foldable-specific cases

Run these cases in addition to the posture variants of the base matrix. All fixture files must be isolated copies; preserve any real user library.

| ID | Priority | Exact steps | Expected result and evidence |
|---|---|---|---|
| FL-001 | P0 | Cold-launch at 360 × 800 dp with no feature. Tap `书架`, `摘记`, `设置`, then return to `书架`; open search, enter text, clear it, and cancel. | Compact bottom navigation remains reachable; state changes only on the intended tab; search text and cancel behavior match A-002/A-006. Capture each screen and record input result. |
| FL-002 | P0 | Open a book on the outer display. Record visible chapter and source offset. Unfold into the vertical profile, turn a page, rotate to 900 × 440 dp, return to the open-book profile, then fold back. | No orientation lock, blank route, lost reader, duplicated page turn, unread leak, or lost note draft. Record source offset before/after each posture change and capture all four states. |
| FL-003 | P0 | On the open-book profile, tap each left-screen navigation destination. On the right screen use shelf filters, sort/view menu, search, a book cover, continue card, overflow, and `+ 导入`; open and cancel the file picker. | Navigation targets, labels, touch targets, scroll, and modal remain entirely on visible screens; the book and controls do not cross the hinge. Record every interaction separately. |
| FL-004 | P0 | Open a book. Tap `上一页`, `下一页`, each right-screen action `目录与书签`, `人物与关系`, `本章前情`, `问这本书`, `阅读排版`; open a relationship/person detail and return. Toggle the toolbar and bookmark. | Text remains confined to the left display; action panel and sheets remain on a usable display; cutoff/page state and back-stack order remain correct. Capture default reader, each destination, and return. |
| FL-005 | P0 | On tabletop, scroll the shelf so a partly visible cover, title, and progress move into view. Tap filters, search, sort, book, and import. Switch each bottom navigation tab from the lower display. | Upper screen scrolls independently above the hinge; bottom navigation remains reachable below; no action is hidden behind the hinge. Record the touch/scroll sequence. |
| FL-006 | P0 | On tabletop, turn pages using the lower `上一页`/`下一页` controls; open `工具栏`, `目录`, `人物`, and `问书`; close each with Back. Tap the upper page and bookmark. | Page content stays above the hinge; controls and bottom-sheet anchor stay below it; each Back closes one layer; no control straddles the hinge. Capture every destination and return. |
| FL-007 | P0 | Repeat all editable-field rows in the base matrix on each posture: shelf search, page jump, model settings, Ask, note editor, manual person/concept, and any other current field. Enter Chinese, English, emoji, newline where allowed, invalid input, and clear/cancel. | Keyboard opens in the active display without covering the field's save/cancel action or moving the book to an unread position. Record visible text before/after the IME and after closing/reopening the relevant screen. |
| FL-008 | P0 | While an editor, confirmation, person card, relationship graph, or drawer is open, change from folded to open, open to tabletop, rotate to landscape, then return. Repeat once with the keyboard visible. | Same workflow and draft remain active; no duplicate request/save; focused input and accessible Back order remain correct. Record each transition and durable result. |
| FL-009 | P1 | Repeat shelf, notes, settings, reader, all five reader side-panel actions, graph, and one form at system text scale 1.5 and 1.8 in folded, open, and tabletop profiles; repeat in light and night mode. | No clipped label, unreachable action, hinge-crossing control, relationship card loss, or text overlap. Every graph relation required by G-001–G-015 remains legible by panning/zooming. Capture worst case per screen. |
| FL-010 | P0 | In each posture, use Back through: keyboard → popup/sheet → pushed sheet page → reader toolbar → reader → main screen. Repeat with TalkBack or the platform screen reader; traverse navigation and all primary actions. | One Back closes exactly one layer; focus returns to the opener; labels identify controls; tap targets remain at least 44 × 44 dp; hinge pixels are not treated as touchable content. Save accessibility tree or recording and screenshots. |

## Automated support and limit

`app/test/foldable_screens_test.dart` renders home and reader screenshots for vertical/open and tabletop profiles. `app/test/reader_regression_test.dart` checks that reader text/tools remain on opposite sides of vertical and horizontal hinges. The screenshot tests are supporting layout evidence only. There is no physical foldable connected to this run, so actual OEM posture reporting, hinge bounds, outer-screen dimensions, keyboard placement, system gesture areas, and TalkBack on a foldable remain `NOT_RUN` until exercised on one.

## 2026-09-26 dev9 simulated-layout evidence

The Mini run for dev9 executed `app/test/foldable_screens_test.dart`: all three
tests passed. It exercised the open vertical-hinge profile, tabletop profile,
and wide landscape profile; four reviewed screenshots are retained in
`app/test/shots/foldable-*.png`. They provide repeatable simulated layout
evidence only. The attached Xiaomi is a flat Redmi Note 8 Pro, so the physical
folded/open/tabletop rows remain `NOT_RUN`.

The same build's graph checks passed `graph_view_test.dart` 12/12 and the new
real-drawer vertical-pan integration case 1/1. A combined run of
`graph_view_test.dart` and `graph_screens_test.dart` had four missing
`graph-*.png` screenshot baselines. They were generated on the NAS using the
pinned Flutter 3.47.5 SDK, visually reviewed, and the complete graph screen
suite then passed 5/5 in a normal NAS run. The eleven graph images are now
allowed through `app/.gitignore`. The Mini screenshot suite has not been rerun
against these NAS-produced graph goldens.

The Mini-generated foldable goldens were separately compared on NAS. All four
vertical-open/tabletop screenshots had pixel differences (1.29%, 7.12%, 1.88%,
and 4.57%); only the wide-landscape widget case passed on NAS. The layouts and
content look equivalent on visual review. The comparison images are retained
under `../../../../reports/20260926-ui-redesign/dev9/artifacts/foldable-platform-diff/`.
The Noto Sans test font hash matches between executors; rasterization differences
between macOS and Linux are the likely cause, but this remains an inference. Do
not replace the Mini goldens with NAS output. A new Mini stage was refused
because its free space was 20.0 GiB, under the strict 20 GiB reserve. No
existing task or project data was removed.
