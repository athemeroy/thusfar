# User-interface end-to-end regression matrix

Owner: release tester. Source audit: 2026-09-26. Scope: Flutter Android application, native file handoff, and separately identified legacy web/PWA surfaces.

This is a test specification, **not an execution report**. Every case starts `NOT_RUN`. A source review, a unit/widget pass, a rendered screenshot, a successful HTTP response, an APK build, and an installed APK are different evidence. None alone establishes that the user can complete a workflow. Record an actual device/browser result for each case and each required variant using [UI-E2E-RUN-TEMPLATE.md](UI-E2E-RUN-TEMPLATE.md).

The highest-priority acceptance condition is the interaction the user sees: an action reaches the intended destination, text remains readable, input survives where promised, persisted changes survive reopening, and the UI does not reveal unread knowledge. In particular, **relationship lines must have understandable relationship labels**. A graph containing only names, circles, and unlabeled lines fails release acceptance even if its underlying JSON is correct.

## Execution rules and environments

- `P0`: release gate: loss of user data, unread-content disclosure, misleading model routing, inaccessible primary action, incorrect graph relationships, or a broken main workflow. `P1`: required complete regression before a release. `P2`: extended compatibility/performance checks. Priority is run order, not permission to omit cases.
- `A`: real Android release APK. `W`: current web/PWA browser. `S`: Android standalone legacy web shell when included in an upgrade candidate. Flutter and web have different controls; do not claim W/S coverage from A.
- All cases below are A unless the case starts `W-`. Shared data and spoiler requirements also apply to W; its entry labels differ. Web-only synchronization/login/downloads must not be invented in Flutter.
- Use an isolated probe package/test library and synthetic notes. Never clear production storage to obtain a clean fixture. Back up a reused test library before restore, removal, upgrade, corruption, or interruption scenarios.
- Run phone GUI steps inside the established `phone-exec run -- ...` lease, using `phone-exec call` / screenshots within it. One GUI task per device. Do not replace GUI proof with direct API or file writes. A tester may seed a controlled fixture before a case; the action under test must then be performed through the UI.
- Use the home Mini for builds and heavier browser/Flutter execution. Read the device guide before phone work. Record APK hash/version/package, source commit plus dirty diff hash, device/OS, viewport/text scale, theme, keyboard, fixture hashes, and configured protocol.
- Cases that require a successful/error/slow model reply use an explicitly configured compatible test server with deterministic responses and a request receipt. It must support the protocol actually selected. An in-process mocked widget is supporting evidence only. A live-provider smoke case is separate and only uses the authorized endpoint/account. Never include keys in screenshots, recordings, logs, or fixture exports.
- Each case must record: exact action, visible expected/actual outcome, screenshot or short recording, and relevant durable proof. When private app files cannot be inspected, use UI reopen plus exported backup as the durable proof and mark unavailable fields `UNKNOWN`.
- Wait for an observable state (dialog, label, completed request, stable progress), not an arbitrary long delay. For animation/running progress, capture a bounded interval rather than waiting indefinitely for total UI idleness.
- Expand every enumerated option into a separate result row, for example `T-002/font=楷` and `M-001/protocol=gemini`. A single row marked PASS cannot mean unvisited options passed.
- Every screen and sheet is subject to `X-001` through `X-010`; every input is subject to the input contract below. Run them on the smallest supported phone and normal font scale, plus large system text on at least one phone. Run the full graph set in light and dark modes.
- Because the target phones are foldables, **all 155 Android rows in the base result template must also pass separately in the folded outer-display, open-book, and tabletop profiles**. Add `@folded`, `@open`, and `@tabletop` to each case ID. See [FOLDABLE-UI-REGRESSION.md](FOLDABLE-UI-REGRESSION.md) for viewport definitions, exact posture actions, and the separate NOT_RUN template. A flat phone or a widget-only hinge simulation does not close a physical foldable run.
- A full regression requires all in-scope P0/P1 cases and option variants executed. `BLOCKED`, `UNKNOWN`, `NOT_RUN`, and `NOT_IMPLEMENTED` are never PASS. A missing feature visible in the UI is a failure, not a reason to mark the case N/A.

## Fixture catalog and exact checkpoints

Use copies of existing public-domain/synthetic sources. Record the chosen source hash and generated backup hash in the run. An offset is a source-character boundary; a displayed page number depends on typography, so record both and do not assume page 9 always contains the same sentence.

| Fixture | Preparation and purpose |
|---|---|
| F0 | Empty isolated library; no API key; network recorder observes zero calls. First-run, validation, empty states. |
| F1 | Import `oracle/corpus/books/aq.txt` and `jekyll.txt` through the picker; unprocessed TXT, Chinese/English, multiple chapters. The provenance/rights/hashes are in `oracle/corpus/manifest.json`. |
| F2 | Portable backup of `oracle/goldens/books/aq_deepseek`, with reader position equivalent to the screenshot fixture (`pos=1740`, `cutoff=2400`, 11%). Also retain a copy at first chapter and near the end. Historical model outputs are fixed data, not a new model request. |
| F3 | Copy `oracle/corpus/snapshots/aq_paused_annotated` / `aq_notebook_history`; resume, existing personal note, revision and tombstone checks. Ensure the run's exact snapshot directory exists before selection. |
| F4 | Own synthetic three-chapter text with repeated `Alice`, `Bob`, `Carol`, concept `fox`, emoji, combining characters, CJK punctuation, long paragraphs, and an unread sentinel `LATER_ONLY_秘密`. Choose checkpoint C0 before Bob, C1 after Alice/Bob but before Carol/sentinel, C2 after all text. Keep a printed expected-offset manifest. |
| F5 | Synthetic graph backing F4, loaded by a portable backup: Alice is Bob's `老师`, Bob is Alice's `学生`; Alice/Carol `朋友`; one family relationship, one relationship with distinct descriptions at C1/C2, one `ended` relationship, one long role/description, and a pair with multiple relationships. Use an explicit label oracle containing `a`, `b`, `a_is`, `b_is`, `desc`, start/end cutoff. Make separate 0/1/2-person and >40-person variants. Do not infer role direction from screen positions. |
| F6 | Synthetic EPUB from `oracle/corpus` or a generated EPUB whose creation recipe is saved: cover, nested chapters, image, missing image, footnote, front matter, non-ASCII filename. No purchased/protected text. |
| F7 | File errors: 0-byte TXT; malformed EPUB; arbitrary JSON; malformed backup; same-ID conflicting backup; unsupported PDF/MOBI/AZW3; revoked content URI; 33 shared files; a synthetic >200 MB shared file. Record expected accepted/rejected limits separately for picker versus native share. |
| F8 | Deterministic model server reachable from the device, private ephemeral test key, protocol-correct OpenAI/Gemini/Claude responses. Profiles: success, 401, 429, timeout, >8s reply, malformed JSON, unsafe answer rejected, empty citations, late answer after cancellation. Record each received protocol/path/model/key fingerprint and request count without key contents. |
| F9 | Safe portable backup with synthetic bookmark, excerpt, edited note, deleted-note tombstone, manual person/concept with two revisions, progress, graph and images. Use export output from prior cases as a restore fixture. |

F4/F5/F7/F8 are fixture requirements, not claims that all assets or server profiles already exist. A case stays BLOCKED until the exact fixture/receipt is available. Reuse `app/test/manual_entities_test.dart` and `backup_test.dart` as schema examples; do not substitute those unit tests for GUI execution.

Evidence codes below: `V` = screenshot with relevant text; `R` = recording or ordered before/after screenshots proving taps/gestures; `D` = durable UI reopen and exported-data assertion; `N` = redacted network receipt; `L` = redacted app/crash logs. All cases also use the universal cross-screen contract.

## A. Launch, navigation, shelf, and reading queue

Source: [main.dart](../../app/lib/main.dart), [shelf_screen.dart](../../app/lib/screens/shelf_screen.dart), [sheet_host.dart](../../app/lib/sheets/sheet_host.dart).

| ID | Priority / fixture | Steps through the UI | Expected visible and durable result / evidence |
|---|---|---|---|
| A-001 | P0 F0 | 1. Cold-launch APK. 2. Wait for first-run screen. 3. Leave and reopen. | `把第一本书放进来`, `从手机选择书`, `恢复备份`, `去填写` reachable; no blocked startup/network call or blank screen. V,N,L. |
| A-002 | P1 F0/F2 | 1. Tap bottom `书架`, `摘记`, `设置`, then `书架`. 2. Repeat with keyboard open and a partially scrolled shelf. | Correct selected tab/content; no accidental navigation or overwritten data. Empty notes guidance appears in F0. R. |
| A-003 | P0 F2 | 1. Tap a cover. 2. Return. 3. Tap continue-card `继续`. 4. Return; repeat in `列表` view. | Every entry opens the intended book at saved position; one tap, no wrong title or stale reader. R,D. |
| A-004 | P1 F2 | 1. Long-press a grid cover, list row, continue card. 2. Open each visible book overflow/menu button. | Each opens the correct book drawer; no unintended page advance/open. R. |
| A-005 | P1 mixed unread/in-progress/finished books | Tap `全部`, `在读`, `未读`, `读完` independently; verify counts/content; select empty combination. | Only matching books appear; no missing imported unread book or finished book in continued reading. V,D. |
| A-006 | P1 F1/F2 | 1. Tap shelf `搜索`. 2. Enter full/partial title, author, uppercase English, surrounding spaces, no match. 3. Clear text. 4. Tap `取消`. | Matching results update; no-match state distinct from empty library; cancel restores unfiltered shelf. V. |
| A-007 | P1 ≥3 books | Open sort menu; select each of `最近阅读`, `书名`, `阅读进度`, `最近加入`; reopen menu and restart app for each. | Actual order matches known fixture metadata, selected item checked, choice persists. D,V. |
| A-008 | P1 ≥3 books | Select `封面` then `列表`; scroll far down/up; tap compact/expanded `导入` FAB. | View and scroll usable; all titles/actions readable; both FAB states open picker; view persists. R,D. |
| A-009 | P1 ≥3 books | Book drawer → `加入接下来读`; add two more; close; tap queue covers; reopen drawer and tap `在书单第 N 位` to remove. | Queue adds once, order/rank correct, queue tap opens correct book, remove does not delete book. D,R. |
| A-010 | P1 queued ≥3 books | Shelf queue edit control → drag last item first; remove middle item using minus; dismiss; restart. | Reorder/remove durable, no duplicate/lost shelf book; queue vanishes gracefully when empty. D,R. |
| A-011 | P0 F2 | Open reader; switch to file manager; return through launcher and Recents independently; cold-reopen. | Same library and saved reading progress; no second empty activity. V,D. |
| A-012 | P1 F2 | Open two nested person/preview sheets; use header back, Android Back, scrim, downward drag separately. | One appropriate layer closes at a time; underlying book stays open at original position; no stuck invisible overlay. R. |

## B. Import, backup, removal, and native Android handoff

Source: `main.dart` (`pickAndImport`, `_importBatch`, `exportBook`), `data/backup.dart`, [MainActivity.kt](../../app/android/app/src/main/kotlin/com/yedu/zhupi/MainActivity.kt).

| ID | Priority / fixture | Steps through the UI | Expected visible and durable result / evidence |
|---|---|---|---|
| B-001 | P0 F0/F1 | `从手机选择书` → Android picker → select Aq TXT; wait; open resulting book. | Imported title/text readable without API key/network; success feedback; new book remains after restart. V,D,N. |
| B-002 | P0 F6 | `导入` → select EPUB → open cover, body, nested TOC, image/footnote locations. | EPUB retains source order/text/images, navigation usable; missing resource is explained rather than crash. V,D. |
| B-003 | P1 F1 | Picker → multi-select Chinese TXT, English TXT, EPUB; return. | Per-file results, all successful books readable; no duplicated import or lost filename. V,D. |
| B-004 | P1 F1/F7 | Multi-select one valid and one malformed file. | Bad file has named error; valid file still imports; next batch works. V,D. |
| B-005 | P1 F0 | Open picker via each of first-run import, shelf FAB, first-run restore, settings restore; press Android Back. | Return to invoking screen; no phantom import/error or storage change. R,D. |
| B-006 | P0 F2 | Reimport identical source; read `已在书架上`; tap receipt `打开`. | One book remains; current progress/notes preserved; receipt opens correct book. V,D. |
| B-007 | P1 F7 | Import empty TXT, invalid EPUB, unsupported PDF, MOBI, AZW3, random JSON separately. | Specific understandable failure (`文件是空的`, conversion/support/backup error as applicable), no ghost book/crash. V,D,L. |
| B-008 | P0 F9 | Book drawer → `导出完整备份`; choose test location; inspect file; restore into separate empty test library; open it. | Text, graph, mentions, note history, manual history, progress and images retained; actual content verified, not just filename. V,D. |
| B-009 | P1 F2 | Export → cancel system save dialog; repeat and complete. | `没有导出` on cancel; no false success; completed file reopens/restores. V,D. |
| B-010 | P1 ≥2 books | Settings → `导出全部备份`; complete each save dialog, then repeat cancelling one. | Explicit per-book result; cancel does not falsely claim all books exported; no existing file overwritten unexpectedly. V,D. |
| B-011 | P0 F7 | `恢复备份` → plain TXT; arbitrary JSON; corrupt note/graph backup; same-ID conflicting backup. | Restore rejects unsuitable/corrupt/conflicting data before publication; existing book hashes/progress/notes unchanged. V,D. |
| B-012 | P0 corrupted isolated book | Attempt export with malformed notebook/graph data. | Visible failure; no export silently replacing user's notes/graph with an empty array. V,D. |
| B-013 | P0 F9 | Book drawer → `从这台手机移除`; inspect warning; tap `导出备份`; dismiss drawer without `移除`. | Warning mentions text/knowledge/personal notes; backup works; mere warning/dismiss does not remove book. R,D. |
| B-014 | P0 F9 copy | Confirm `移除`; return to shelf, queue, notes; restart. | Only selected test book and its notes removed; other books unaffected; no dangling reader/queue row. V,D. |
| B-015 | P0 running F3/F8 | While processing, request removal; dismiss drawer during cancellation; wait and reopen. | Removal waits for settled worker/lease; reader closes if removed; no later files reappear from late work. R,D,N. |
| B-016 | P0 F1 | App stopped normally → file manager `用页读打开` TXT; repeat for EPUB and `.yedu.json`. | Correct app/activity opens, original filename/type retained, import succeeds once. R,D. |
| B-017 | P0 F1 | App at shelf, then reader, then nested sheet → external ACTION_VIEW a different book; return through launcher. | Import queued safely into same app; original library never becomes empty/stale; both books remain. R,D. |
| B-018 | P0 F1 | External share ACTION_SEND one file; ACTION_SEND_MULTIPLE several files; repeat exact share. | All supported originals handled once per content identity; repeats preserve existing data; failure isolated per file. R,D. |
| B-019 | P1 F7 | Share unsupported extension, revoked URI, zero-byte file, 33 files, >200 MB file separately. | Native boundary errors readable; oversize/batch limit rejects safely; next valid share still works. V,D,L. |
| B-020 | P0 F1 | Share file; background/recreate receiving activity during copy/import; reopen original app; repeat original share if outcome uncertain. | No lost existing books, duplicated completed content or stuck progress; retry reconciles original content; temporary copies cleaned when inspectable. R,D,L. |
| B-021 | P0 F9 old-version test install | Export safety copy; record old version/progress/notes; install signed upgrade over same test package; launch, open book and all personal data. | In-place test data survives without reimport; production upgrade is separately recorded, never inferred from probe install. V,D,L. |

## C. Model settings and all protocol routes

Source: [model_settings_screen.dart](../../app/lib/screens/model_settings_screen.dart), `data/model_settings.dart`, core settings/protocol adapters. Supported UI choices: **OpenAI Compatible**, **Gemini**, **Claude Compatible**. No relay/reseller brand is a built-in provider. A user-entered endpoint may name their chosen provider; that is not a bundled endorsement.

| ID | Priority / fixture | Steps through the UI | Expected visible and durable result / evidence |
|---|---|---|---|
| M-001 | P0 F0/F8, each protocol | Settings → `模型接口` → `接口协议`; choose protocol; enter test `接口地址`, `模型`, `API 密钥`; save; reopen. | Exact three choices available; correct protocol/default endpoint/hints; chosen custom URL/model retained; no XiaoJing branding/preset. V,D. |
| M-002 | P0 F8, each protocol | With valid visible form, tap `测试连接`; capture server receipt. | Tests the visible protocol/endpoint/model/key or explicitly prevents testing unsaved edits with clear guidance; never reports old endpoint's success as current form's success. N,V. |
| M-003 | P0 F0 | Leave key blank; tap `测试连接`, then attempt save with missing URL/model/key individually. | Clear local validation; zero model requests; input retained; no false green configured indicator. V,N,D. |
| M-004 | P1 F8 | Enter leading/trailing spaces in endpoint/model; base URL without version path; complete version path; custom path. Save each. | Documented normalization/hint only; no double `/v1` or `/v1beta`; custom compatible path not silently rerouted. V,D,N. |
| M-005 | P0 F8 | Enter malformed URL, unsupported scheme, URL with user-info/query secret; invalid/empty model. Save/test each. | Validation explicit; no credential leakage or accidental fallback request; correction remains possible. V,N. |
| M-006 | P0 saved key | Tap `更换`; enter new key; toggle eye twice; save. Leave without saving once. | Masking correct; intentional reveal only; successful replacement durable; abandoned edit does not replace saved key. V,D,N. |
| M-007 | P0 saved key | Tap `清除`; cancel by leaving once; repeat and save; reopen. | Clear is only persisted on save; saved key status accurate; subsequent test/processing cannot reuse cleared key. V,D,N. |
| M-008 | P0 saved key | Switch protocol or endpoint with blank replacement key; try save/test; switch back. | No old key sent to a different endpoint/protocol; replacement requirement explained; original settings intact after failed/abandoned save. N,D,V. |
| M-009 | P1 F8 profiles | Test success, >8s slow, 401, 429, timeout, invalid protocol response separately. | `连接成功`/`能用，但很慢`/`连接失败` match actual result; useful redacted error; no hang; retry works. V,N,L. |
| M-010 | P0 delayed F8 | Tap Test twice rapidly, then Save; try switching protocol; navigate back before late success/error. | At most one request in flight, safe disabled states; late callback neither crashes nor overlays another screen; no hidden extra request. R,N,L. |
| M-011 | P1 F8 | Open model settings from first-run `去填写`, settings, processing `去填写`/`去模型设置`, Ask error `模型设置`, marginalia `模型设置`; return each. | Correct back destination; saved config takes effect in originating feature; existing draft/book position retained. R,D. |
| M-012 | P0 each protocol F8 | After connection test, process tiny fixture, ask a question, generate a marginal comment. | All three feature paths use selected protocol/model/endpoint, not only connection test; network receipts prove compatible request shape. N,V,D. |
| M-013 | P1 saved config | Cold-reopen; inspect settings summary and privacy/about text. | Protocol/model/key-set status truthful; no hardcoded reseller label; privacy includes actual explicit network actions (test, processing, ask, marginalia); About version matches the installed package version. V,D. |

## D. Processing controls and visible lifecycle

Source: [book_sheet.dart](../../app/lib/sheets/book_sheet.dart), `data/processing.dart`, `data/library.dart`.

| ID | Priority / fixture | Steps through the UI | Expected visible and durable result / evidence |
|---|---|---|---|
| P-001 | P0 F1 no key | Drawer → `开始整理` → `去填写`; back without saving. | Missing-key guidance, no model request or fake queued status; body remains readable. V,N. |
| P-002 | P0 F1/F8 | `开始整理`; inspect cost/usage notice; tap `取消`; reopen confirmation. | No request before explicit `开始`; cancel preserves idle; estimate does not claim a reseller is required. V,N,D. |
| P-003 | P0 F1/F8 | Confirm `开始`; tap again rapidly; close drawer; watch shelf; open reader while processing. | One job; queued/running progress visible; reading remains responsive; completed people/graph refresh without reopening whole app. R,N,D. |
| P-004 | P0 running F8 | `暂停整理`; immediately attempt resume/start; wait for settled status. | `正在暂停…` remains until real settlement; no overlapping job; paid successful in-flight work retained; `继续整理` only when valid. R,N,D. |
| P-005 | P0 F3 | `继续整理`; verify completion; open people, relations and recap. | Resume advances from existing frontier, preserves notes/cache; status becomes done with actual people count. V,D,N. |
| P-006 | P0 F8 failure | Inject 401/429/timeout/malformed response; open drawer; `重试整理`; optionally `去模型设置` then retry. | Error visible and actionable; retry uses corrected settings and prior work; no silent success/infinite busy. V,D,N. |
| P-007 | P1 quality-pending/refused fixture | Open done drawer; tap `重试待核对部分`; compare normal-done fixture. | Action appears only for eligible quality state; preserved accepted work; refused segment count understandable. V,D,N. |
| P-008 | P0 running F8 | Background app, screen off, reopen; separately recreate process in isolated test. | Distinguish continue/paused/reconciled actual state; no auto-paid restart on cold launch; no claim of background reliability without this evidence. R,D,N,L. |
| P-009 | P1 two books/F8 | Start A then B; inspect both drawers and shelf; pause one. | Each status/usage tied to correct book; queue behavior clear; pause/removal never affects other book. R,D,N. |
| P-010 | P1 partial/corrupt graph | Read beyond processed frontier; open person/graph/recap; later complete job. | Frontier notice accurate; original text available; unavailable/corrupt knowledge not silently presented as complete or empty success. V,D. |

## E. Reader, selection, pagination, return position, and typography

Source: [reader_screen.dart](../../app/lib/reader/reader_screen.dart), [page_body.dart](../../app/lib/reader/page_body.dart), `reader_controller.dart`, `paginator.dart`, [typography_sheet.dart](../../app/lib/sheets/typography_sheet.dart).

| ID | Priority / fixture | Steps through the UI | Expected visible and durable result / evidence |
|---|---|---|---|
| R-001 | P0 F1/F2/F6 | Open each book; compare first, middle, last page against source; traverse paragraph and chapter boundaries. | No missing/duplicated text, cut glyphs, invisible images, bad source order, or false page count; progress matches reading. R,D. |
| R-002 | P0 F1 | Tap left third, right third, center; swipe left/right; repeat for `平移`, `覆盖`, `无`. | Correct prior/next page or toolbar; no double turns; first/last boundary stable. R,D. |
| R-003 | P0 F2 | Reveal toolbar; tap `回书架` once. Reopen; use Android Back with selection, toolbar, then no overlay. | Labelled back returns to shelf as intended; Android Back dismisses selection/toolbar first, then reader; saved position retained. R,D. |
| R-004 | P1 F1 | Enable volume keys; press up/down in reader, then with each sheet/keyboard open; disable and repeat. | Up/down turn once only when enabled and in reader; sheets/input not unexpectedly paged; disabled keys remain system controls. R. |
| R-005 | P0 F2 | Reveal toolbar; drag page slider to beginning/middle/end; inspect preview title before release; use `上一章`/`下一章`. | Target and progress correct; preview hides unread chapter names; boundary buttons disabled; no crash/overshoot. R,D. |
| R-006 | P0 F2 | Jump from search/TOC/person event/ask cite; tap `回到第 N 页`; repeat, dismiss return chip with close icon. | Return restores original source offset; explicit close only removes return affordance; progress reflects actual final reading location. R,D. |
| R-007 | P0 F4 | Long-press Chinese/English/name/emoji at the page edge; drag across a wrapped line and beyond the original paragraph in both directions; tap outside or Back. | Selected range stays within the visible page and original paragraph; no split surrogate, unread suffix, unintended page turn or wrong word; cancel changes no notes. R,D. |
| R-008 | P0 F4 | Long-press sentence → `复制`; paste into a local scratch field outside app. | Exact selected source text, no person label/hidden annotation pollution; `已复制`; selection closes. R. |
| R-009 | P1 F2 | Tap underlined person at left/middle/right of page; tap footer avatars; return. | Correct person/list opens without turning page; cutoff consistent with page; footer overflow/count usable. R. |
| R-010 | P0 F2 | Toolbar `书签` on/off; navigate away and back; cold-reopen; inspect TOC bookmarks. | One bookmark per action/current page; ribbon and icon agree with durable notebook; toggle removes correct item. V,D. |
| R-011 | P1 F6 | Read image/front-matter page; on a footnoted page tap footer `注释 N` → `本页注释`; select/copy note text; scroll long notes; dismiss and reopen. | Images/text ordered correctly; actual footnote text is selectable and complete; missing body displays `这条注释的内容缺失`; not merely a decorative marker. V,R. |
| R-012 | P0 F6 at page boundary | Put footnote anchors immediately before, exactly at, and immediately after the current page end; open `注释 N`; turn forward/back and reopen. | Count/content include only current-page anchors through page end; next-page notes hidden until read; exact-end anchor belongs to just-read text; no duplicate on next page. V,R. |
| T-001 | P1 F2 | Toolbar `排版`; drag font slider to every integer 16–26; dismiss/reopen; settings `默认字号` select every value. | Text reflows immediately without losing source location; both controls agree and persist. R,D. |
| T-002 | P1 F2 | Select each `行距` (`紧`,`中`,`松`), `字体` (`宋`,`楷`,`黑`), paper swatch (`纸`,`米`,`青灰`,`白`,`夜`). | Actual appearance changes; current choice visible, no clipped CJK/emoji; location retained after reflow/restart. V,D. |
| T-003 | P1 F2 | Change `翻页` through all three choices in typography and Settings; toggle volume key switch in both. | Shared preference consistent and durable; actual gestures match chosen animation. R,D. |
| T-004 | P1 F2 | Settings `夜间模式` → `跟随系统`,`总是`,`从不`; switch OS theme; open graph/form/reader; combine with `夜` paper. | Readable consistent contrast, selection/disabled/error states distinguishable; no black-on-black text. V,D. |
| T-005 | P1 F2 | Open typography via toolbar and overflow `阅读设置`; drag sheet/scrim/Back dismiss. | Both entries reach same functional panel; preview page remains visible/reflowed, no extra overlay or hidden touch interception. R. |

## F. Table of contents, search, source previews, and spoiler boundary

Source: [toc_sheet.dart](../../app/lib/sheets/toc_sheet.dart), [search_sheet.dart](../../app/lib/sheets/search_sheet.dart), [preview_sheet.dart](../../app/lib/sheets/preview_sheet.dart).

| ID | Priority / fixture | Steps through the UI | Expected visible and durable result / evidence |
|---|---|---|---|
| C-001 | P0 F4 at C1 | Toolbar `目录`; inspect current/read/unread chapter rows; tap read chapter. | Current marked, read titles visible, unread titles reduced to safe number; jump exact and return chip works. V,D. |
| C-002 | P0 F4 at C1 | Tap unread chapter; inspect warning; tap same row to collapse; reopen → `跳过去`. | No unread title/plot before explicit choice; cancel leaves position; explicit jump updates position. R,D. |
| C-003 | P1 F1 | TOC page input: blank, 1, valid middle, final, 0, 999999, letters, signed/decimal pasted string; press IME Go each. | Numeric-only/clear validation or documented boundary clamp; no crash or silent unrelated jump; valid input reaches exact page. R,D. |
| C-004 | P1 F9 | TOC → `书签`; tap item; reopen and swipe delete; tap `撤销`; restart. | Source jump correct; delete/undo restored item persisted; empty bookmark guidance meaningful. R,D. |
| C-005 | P0 F9 at early checkpoint | TOC → `摘记`; compare `也显示后面的` off/on; tap note → preview; turn off again. | Default hides later notes; explicit reveal only affects chosen view; personal quotes not silently fed to current AI beyond cutoff. V,D,N. |
| C-006 | P1 F9 | TOC notes `导出`; reader overflow `导出摘记`; paste both into local scratch editor. | Correct Markdown title, quotes, note text/bookmarks; deleted notes excluded; full-book scope disclosed. V,D. |
| S-001 | P0 F4 C1 | Reader Search → enter `Alice`, mixed case, Chinese, punctuation/emoji, spaces, empty, no match. | Correct snippets/highlights/count, no crash; default `读到这里` returns only read matches. V. |
| S-002 | P0 F4 C1 | Search `LATER_ONLY_秘密` under `读到这里`; tap `搜全书` or `全书`; return to `读到这里`. | No default match or trailing unread snippet; explicit full-book choice warns about later content; reverting restores boundary. V. |
| S-003 | P1 repeated text fixture | Search common character producing >500 matches; scroll top/bottom; change query rapidly. | Bounded result/count (`500+` where applicable), responsive updates; correct final query results and taps. R. |
| S-004 | P0 F4 C1 | Tap read hit within 1–10 characters of cutoff; inspect entire source preview, including 300-character context. | All automatically visible context stays within current allowed boundary; unread sentinel absent. V. |
| S-005 | P0 F4 C1 | Full-book search → future hit; inspect preview; tap `关闭`; reopen and explicitly reveal/jump using visible controls. | Future chapter/text hidden until clear consent; button wording matches reveal versus navigation; close leaves position unchanged. R,D. |
| S-006 | P0 F2 | Preview from search, first appearance, event, recap, note and ask citation separately; `跳到这里`; return chip. | Highlight matches source range for every entry; AI source/personal note colors distinguishable; exact return position retained. R,D. |

## G. Notes, excerpts, drafts, and notebook hub

Source: [note_editor.dart](../../app/lib/sheets/note_editor.dart), [notes_screen.dart](../../app/lib/screens/notes_screen.dart), reader selection/overflow, book drawer `我的摘记`.

| ID | Priority / fixture | Steps through the UI | Expected visible and durable result / evidence |
|---|---|---|---|
| N-001 | P0 F4 | Select exact sentence → `摘录`; verify `已摘录`; open TOC notes/global `摘记`; restart. | Correct quote/range, one excerpt, no note text invented; highlight/list and durable notebook agree. V,D. |
| N-002 | P0 F4 | Create excerpt → immediately `撤销`; navigate/restart. | Excerpt removed/tombstoned, no stale highlight/list row. R,D. |
| N-003 | P0 F4 | Select → `笔记`; type multiline CJK/emoji/punctuation; `保存`; reopen from every notes entry. | Exact trimmed text with correct quote; keyboard does not cover Save; saved once; proper edit/preview entry. V,D. |
| N-004 | P0 F4 | Type draft; dismiss by Back, drag and scrim in separate runs; select identical range again; cold-reopen. | `草稿已保留` where promised; draft restored for same range only; another range/book cannot inherit it. R,D. |
| N-005 | P1 F4 | Note field empty/whitespace, 10,000 characters, paste beyond limit, emoji at boundary; save/cancel. | No crash or broken Unicode; empty note has defined excerpt behavior; limits enforced and text not unexpectedly lost. V,D. |
| N-006 | P0 F9 | Open an existing saved note through TOC/global notes/book `我的摘记`; choose edit; modify and save; reopen. | A reachable edit action exists; original note ID/range retained, revision advances, no duplicate instead of edit. R,D. |
| N-007 | P0 F9 | Existing-note editor → `删除`; separately global note row swipe left → `撤销`. | Delete and undo affect only selected item; persistent state and highlights agree; no data loss in neighboring notes. R,D. |
| N-008 | P1 F9 | Global `摘记`: select `全部`,`摘录`,`笔记`,`书签`; search quote fragment/note fragment/no match; close search. | Correct kind filtering/group counts, search covers both quote and note; clear restores list; empty state correct. V. |
| N-009 | P0 F9 | Global note/bookmark row → reader; BookSheet `我的摘记` → notes collection. | Row opens exact original range with return affordance; `我的摘记` opens that book's notes, not only generic reader. R,D. |
| N-010 | P0 F9 | Create, edit, delete and undo notes; export full backup; restore separate copy; reopen notes and source. | Revisions/tombstones/quotes and progress survive; duplicates not resurrected; markdown excludes deleted data. D,V. |

## H. People and manual people/concepts

Source: [people_sheet.dart](../../app/lib/sheets/people_sheet.dart), [person_sheet.dart](../../app/lib/sheets/person_sheet.dart), [manual_entity_editor.dart](../../app/lib/sheets/manual_entity_editor.dart).

| ID | Priority / fixture | Steps through the UI | Expected visible and durable result / evidence |
|---|---|---|---|
| H-001 | P1 F0/F1 | Unprocessed book → `人物`; tap `开始整理`; back; tap `补充人物或概念`. | Empty guidance leads to actual processing confirmation or local editor; neither requires invisible gesture. R,N. |
| H-002 | P0 F2 | Open `人物`; switch `本页`,`本章`,`全部`; compare known source mentions and counts. | Each scope correct, no unseen/future person/alias/tagline; `新` and manual badges truthful. V. |
| H-003 | P1 F2 | `全部` → `搜名字、称呼、身份`; test name, alias, identity, mixed case, whitespace, no match; clear and switch tabs. | Correct filtering and state; no filtered results with an apparently blank field after return. R. |
| H-004 | P0 F2 | Person card → first appearance, relation rows, compact graph nodes, event rows; sort `最新在上`/`最早在上`. | Correct person/source each time; breadcrumb/back stack correct; event order toggles with accurate labels. R. |
| H-005 | P0 F4/F5 | At C1 inspect bio, aliases, attributes/history, relations/events; move C2 then back to C1 and reopen. | Data rewinds with cutoff; later changes/sentinel absent; processing frontier notice doesn't imply knowledge of unread pages. V. |
| H-006 | P1 F2 | Person card `问问这个人`; inspect editable prefill; back; `在关系图里看`. | Correct person name prefilled without auto-submit; graph focus correct; back path usable. R,N. |
| U-001 | P0 F4 C1 | `人物` → `补充人物或概念`; select `人物`; enter exact read name `Alice` and note; `保存补充`. | Local manual card with `手动` badge; source mention clickable; no model request; durable source/cutoff. V,D,N. |
| U-002 | P0 F4 C1 | Repeat with `概念` and read word `fox`; leave explanation blank. | Concept badge and empty-note fallback correct; searchable/visible from appropriate page; no automatic invented relation. V,D,N. |
| U-003 | P0 F4 C1 | Enter empty/space name, nonexistent name, future-only `Carol`/sentinel, full/partial name, duplicate existing name; Save each. | Explicit validation; future-only content cannot be manually introduced before read; typed note retained on failure; duplicates handled explicitly. V,D. |
| U-004 | P1 F4 | Name 80/81 chars and note 3000/3001 chars; multiline/emoji/combining chars; paste; Save. | UI limits/validation consistent with actual saved text; no broken Unicode or hidden truncation. V,D. |
| U-005 | P0 saved manual entry | Card `编辑或删除`; verify name/type read-only; edit explanation → `保存修改`; reopen. | Same entity/revision history, no rename/reclassify accidentally; later note appears only from new cutoff. V,D. |
| U-006 | P0 saved manual entry | `删除这条补充` → `取消`; repeat → `确认删除`; restart. | Cancel keeps entry; confirmed deletion returns sensible people list and removes only manual entry; AI person/source untouched. R,D. |
| U-007 | P0 two-version manual entry | Rewind before creation, then between revisions; open card/editor; attempt save/delete. | Invisible before creation; earlier visible note without later leakage; locked later-edited record cannot be overwritten from past. V,D. |
| U-008 | P0 isolated conflict/corruption | Open editor; another controlled writer updates same entry; Save. Separately seed corrupt manual data or unavailable ID. | Conflict/corruption visible; no silent overwrite/new accidental entity; user's typed explanation retained. V,D. |
| U-009 | P1 F4 | Type manual draft; Back/drag close; reopen; compare with promised UI behavior. | Unsaved form behavior explicit; never a false saved message. Manual editor currently has no promised note-style draft persistence; record UX if discarded. R,D. |
| U-010 | P0 F9 | Export/restore manual history; read before/between/after revisions; edit restored entry. | Source, kind, IDs, revisions, deletion/lock semantics retained; restored entry editable only at valid cutoff. V,D. |

## I. Relationship graph — mandatory visual and interaction gate

Source: [graph_view.dart](../../app/lib/sheets/graph_view.dart), person compact graph, core projected relationships. Run every case on full graph and compact person graph where a control is present. Compare visible labels to F5's role oracle, not to a guessed family relationship. The canonical meanings are: `a_is` is what A is to B; `b_is` is what B is to A. If implementation uses a different stored convention, establish it with an explicit known example before acceptance.

| ID | Priority / fixture | Steps through the UI | Expected visible and durable result / evidence |
|---|---|---|---|
| G-001 | P0 F5 C1 | Reader → `人物` in the default 45% drawer → `关系图`; do not manually expand or select a node; inspect the physical phone screen, then pan across every displayed edge. Repeat with real Aq at early/full cutoff. | Drawer expands for the graph. **The actual visible screen contains at least one complete, legible relationship card** and zoom controls, not only bare lines or a card below the screen. Every rendered relationship has text connected to its correct pair, accessible by pan/zoom; inspect every card. Full default screenshot required. A full-screen GraphPage scaffold alone cannot pass this case. V. |
| G-002 | P0 F5 teacher/student | Select Alice then Bob; inspect changed labels/details; compare compact graph in each card. | Direction remains correct: Bob is Alice's student, Alice is Bob's teacher. Selection cannot reverse roles. Names+roles clear even if layout flips. V,R. |
| G-003 | P0 F5 | Tap an edge label/available relation details affordance; inspect full details; use back; tap each endpoint node in the graph. | Full two names, directional roles, complete description/status accessible; endpoint selection and explicit card action reach the correct card; no tiny untappable decorative label only. R,V. |
| G-004 | P0 F5 long label | Open default/selected graph at minimum phone width and large text; tap long relation details. | Labels legible without concealing node names; truncation gives access to complete meaning; description wraps/scrolls; no overflow. V,R. |
| G-005 | P0 0/1/2-person F5 | Open each variant, including two people with one relation. | True empty state for no relations; **two-person relation is rendered and labelled**, not replaced by “too few people.” V. |
| G-006 | P0 F5 multi-edge | Inspect pair with two relationships, family/nonfamily links, active/ended links. | No dropped/overlaid ambiguous roles; family styling doesn't replace text; ended status visible as ended, not silently current. V. |
| G-007 | P0 F5 C1→C2→C1 | Open graph at each reader checkpoint; compare role/description/status counts; cold-reopen early position. | Future people/relations/updated descriptions absent before cutoff; history rewinds; no graph cache at later position leaks earlier. V,D. |
| G-008 | P0 F5 | Drag replay slider beginning/middle/end; inspect displayed replay page and all labels/details at each boundary. | Nodes/edges/roles/status reflect selected replay time, never beyond reading cutoff. Any card showing current-page rather than replay-time data is explicitly labelled, not mistaken for historical detail. R,V. |
| G-009 | P0 F5 | Tap `播放回放`; tap `暂停回放`; wait; resume; rapidly press twice; drag slider while playing; dismiss midway and reopen. | One controllable playback, pause really stops, manual scrub not overwritten, no late update/crash after close; cutoff stable. R,L. |
| G-010 | P0 F5 | After historical replay, use `回到当前页`; reopen graph from person card. | Graph/slider/page/labels return together to current reader cutoff; reader progress itself never changed by replay. R,D. |
| G-011 | P0 F5 | Pinch zoom, pan; use `放大关系图`,`缩小关系图`,`重置视图` where supplied; hit scale limits; select nodes after transform. On real Aq, repeatedly shrink below the initial size, pan to remaining cards, then reset. | Labels/details stay aligned, readable and tappable; shrinking below 1× reaches an overview (current minimum .3×); reset restores readable 1× with a complete relationship card in view, including connected nodes when they fit. No page turn under graph. R,V. |
| G-012 | P0 F5 | Select node once, tap again, use `打开人物卡`; navigate back; tap background/deselect where supplied. | Correct selected state and incident relations; repeated selection stays stable, and the explicit card action opens the intended person; back returns usable graph; dimming never conceals selected relationship meaning. R. |
| G-013 | P0 >40-person F5 | Open graph; select/focus a low-ranked person via its card; pan/zoom and open details. | Important focus included despite display limit; truncation not falsely described as complete graph; interactions responsive. R,V. |
| G-014 | P0 F5 | Repeat G-001–G-012 in dark theme and compact card; inspect crossing lines, high-degree hub, long Chinese names; inspect real Aq at early and full cutoff for every label/node overlap, not only a two-person fixture. | Relation labels visible against all papers/themes; no clipped labels/illegible opacity; compact graph conveys meaning. V. |
| G-015 | P0 F5 | With screen reader/semantic tree, navigate node/relationship/zoom/replay controls; activate labels; compare announced slider page to visible header/footer at start, an intermediate page and exact current cutoff. | Relationships and actions have meaningful accessible names; Canvas text is not the only path to relationship meaning. Announced replay page equals the visible page, including exact end-of-page boundaries. Tree+R. |

Graph labels above reflect the implementation available during this audit (`播放回放`, `暂停回放`, `回到当前页`, `放大关系图`, `缩小关系图`, `重置视图`). The run must record the actual shipped labels if implementation wording changes; missing promised zoom/detail/replay control is NOT_IMPLEMENTED, not an implicit pass through pinch/drag only.

## J. Recap, Ask, and marginalia

Source: [recap_sheet.dart](../../app/lib/sheets/recap_sheet.dart), [ask_sheet.dart](../../app/lib/sheets/ask_sheet.dart), [marginalia_sheet.dart](../../app/lib/sheets/marginalia_sheet.dart).

| ID | Priority / fixture | Steps through the UI | Expected visible and durable result / evidence |
|---|---|---|---|
| Q-001 | P0 F2 | Toolbar `前情`; read saga/current events; tap event; expand/collapse each chapter recap. | Correct source preview, only known chapter summaries, current cutoff visible; empty/partial state understandable. R,V. |
| Q-002 | P0 F4 C1/C2 | Open recap at C2, rewind C1 and reopen. | Later event/saga/chapter text absent; expanding cannot reveal later title/content. V. |
| Q-003 | P1 F2 | Toolbar `问书`; tap each suggestion (`刚才发生了什么？`,`这里有哪些人物？`,`这段话是什么意思？`); edit before sending. | Suggestion fills editable input without hidden request; title/cutoff clear; keyboard/send accessible. R,N. |
| Q-004 | P0 F8 | Ask field blank/whitespace; type valid question; send via arrow and IME Send in separate runs. | Empty disabled/no request; valid sends once, field/busy state truthful, answer appears; no duplicate send on rapid tap. V,N. |
| Q-005 | P1 F8 | Enter 500/501 characters, multiline, CJK/emoji at boundary; submit selected-text question and person prefill. | Limits safe, displayed question matches actual question; selected quote/person prefix preserved without broken Unicode. V,N. |
| Q-006 | P0 F8/F4 C1 | Ask a relation/plot question; inspect answer and every citation; tap cite → source → return. | Grounded answer limited to read prefix; numeric citations match correct quote/range; source preview respects cutoff. V,R,N. |
| Q-007 | P0 F8 withheld profile | Request future answer/unsupported fact; inject failed guard/verification. | Unsafe draft never flashes or persists as accepted answer; withholding/error understandable; `重试` usable. V,N,D. |
| Q-008 | P0 F0/F8 | Ask with no key, 401, timeout, malformed reply; tap `模型设置`, return, tap `重试`. | Error visible without losing original question; retry correct exchange/config; no false blank success. R,N. |
| Q-009 | P0 delayed F8 | Submit then dismiss sheet; separately change reader cutoff while request pending using controlled lifecycle; reopen Ask. | Request cancelled/suppressed; old reply cannot appear at new cutoff; no crash or further guard requests after cancellation. R,N,L. |
| Q-010 | P1 F8 | Ask same question at same cutoff twice, then different cutoff or changed settings/data. | Saved-answer indicator only for valid same-context cache; different context cannot reuse stale answer. V,N,D. |
| Q-011 | P1 F8 | Submit multiple sequential questions; scroll full history with keyboard shown/hidden; close/reopen. | All current-session exchanges usable; input doesn't cover last answer; history lifetime explicitly observed (currently session-local). R. |
| J-001 | P0 F4 | Select quote → `批注`; inspect quote/cutoff; choose each `共情`,`侦探`,`冷眼`,`学者`,`吐槽`. | Correct selected quote and persona; no request merely opening/changing persona. V,N. |
| J-002 | P0 F8 | Tap `生成批注`; after result tap `查看这个角度`; choose `看看不同角度`. | Verified comment only; persona and `已核对原文` truthful; distinct intended modes/request counts; no double requests. V,N,D. |
| J-003 | P0 F8 | Reader overflow `本页批注` → `找出可讨论的句子`; tap one cue; then `重新查看本页句子`. | Only current-page cues; tapped exact quote/persona produces comment; empty cue result shows friendly message, not error. R,N. |
| J-004 | P0 delayed F8 | Generate → `停止`; change persona/retry; dismiss sheet while pending; reopen. | Stop enables controls and rejects late output; only latest valid request result shown; no background stale comment. R,N,L. |
| J-005 | P0 F8 failure | Cause missing key/verification failure/timeout; tap `重试`, `模型设置`; return and retry original mode/cue. | Original intended mode and quote preserved; no unverified draft; useful error without lost context. R,N. |
| J-006 | P0 F4/F8 | Generate at C2, rewind to C1 while pending/displayed; inspect. | Prior result clears; stale message `阅读位置已改变，请回到原文重新选择。`; no controls can publish future comment. V,N. |
| J-007 | P1 F8 | Comment → `复制批注`, paste scratch; `回到原句`; return chip. | Exact comment copied with feedback, correct quote highlighted and return position; no note silently created. R,D. |
| J-008 | P0 F8/F9 | Generate/reopen same context; export/restore relevant saved data; inspect notebook. | Cache/persistence matches documented scope; AI comments remain distinct from personal notes; no accepted failed/unsafe response stored. D,V,N. |

## K. Every input and control coverage ledger

All **12 Flutter editable text fields** are listed. The source inventory is regenerated before each regression; any new field/callback must gain a case ID before release. For every text field run: focus, type, select-all, replace, paste, clear, IME composition, emoji/combining text, keyboard show/hide, scroll while focused, Back, and reopen. For short-limit fields run limit−1/limit/limit+1. For fields without an explicit limit use 2,000 characters to expose overflow and record any server limit; do not invent a limit.

| Input/control | Actual label/locator | Required cases |
|---|---|---|
| Shelf search | `书名或作者` | A-006,X-002 |
| Global notes search | `搜索摘记` | N-008,X-002 |
| Endpoint field | `接口地址` | M-001–M-010 |
| Model field | `模型` | M-001–M-010 |
| Secret field | `API 密钥`; eye icon, `更换`, `清除` | M-003,M-006–M-010,X-002; use dummy secret for visible screenshots |
| Page number | `跳到第 __ 页…`; IME Go | C-003 |
| Source search | `搜索书里的一句话` | S-001–S-003 |
| People search | `搜名字、称呼、身份` | H-003 |
| Note text | `写下你的想法` (10,000) | N-003–N-007 |
| Manual name | `原文中的完整名称`, `manual-name` (80) | U-001–U-005 |
| Manual description | `你知道的内容`, `manual-note` (3000) | U-001–U-009 |
| Ask input | `问问已经读过的内容…`, `ask-input` (500), IME Send | Q-003–Q-005,Q-011 |
| Protocol selector | `接口协议`; all three entries | M-001,M-008,M-012 |
| Shelf filters/sort/view | Four filters, four sorts, two views | A-005,A-007,A-008 |
| Reading queue | Add/remove/rank, reorder drag, minus button | A-009,A-010 |
| System file dialogs | Picker multi-select, Back, save filename/location/overwrite/cancel | B-001–B-011,B-016–B-020 |
| Reader gestures/actions | Left/right/center, swipe, long-press/drag, five selection actions | R-002,R-007,R-008,N-001,N-003,Q-005,J-001 |
| Reader toolbar | Back, bookmark, search, overflow 4 entries, 5 bottom tools | R-003,R-010,S-001,N-010,T-005,J-003,C-001,H-002,Q-001,Q-003 |
| Reader progress | Slider, chapter previous/next, return chip and close | R-005,R-006 |
| TOC tabs/toggle | `目录`,`书签`,`摘记`,`也显示后面的` | C-001–C-006 |
| Search scope | `读到这里`,`全书`,`搜全书` | S-002 |
| People tabs | `本页`,`本章`,`全部`,`关系图` | H-002,H-003,G-001 |
| Manual kind/save/delete | `人物`,`概念`,`保存补充`,`保存修改`,`删除这条补充`,`取消`,`确认删除` | U-001–U-008 |
| Graph controls | Nodes, edge/detail, card, replay slider/play/pause/current, zoom/reset | G-001–G-015 |
| Note actions | `保存`,`删除`, swipes, `撤销`, edit/source actions | N-001–N-010,C-004 |
| Marginalia | All five personas, generate/auto/cues/retry/settings/stop/copy/source | J-001–J-008 |
| Ask | Three suggestions, send, retry, settings, citations | Q-003–Q-011 |
| Settings choices | 11 font sizes; 3 animations; volume switch; 3 night modes | T-001,T-003,T-004 |
| Typography | Font slider; 3 spacings; 3 fonts; 5 papers; 3 animations; volume switch | T-001–T-005 |
| Backup/removal | Export-one/all, restore, remove-warning, export-before-remove, confirm | B-008–B-015 |
| All sheet surfaces | Drag handle, content scroll, nested back, scrim, Android Back | A-012,X-001–X-010 |

## L. Cross-screen interaction and visual contract

Apply each row to every in-scope screen/sheet from the ledger; record one row per screen/variant. These are real interaction checks, not a demand for snapshot files alone.

| ID | Priority | Steps | Acceptance / evidence |
|---|---|---|---|
| X-001 | P0 | Enter screen through each documented entry; activate each visible button/link/icon once; Back once; reopen. | No dead/wrong-target action; no interaction depends on invisible overlay; state/data preserved. R. |
| X-002 | P0 | Focus each text field; show IME; type/edit/paste/clear; scroll to primary action; submit; Back. | Focus/caret visible; field/action not obscured; IME action matches label; no accidental dismissal/data loss. R. |
| X-003 | P1 | Scroll top/bottom, drag sheet from 20%/45%/92%, drag content, tap scrim, nested Back. | Header/pinned tabs/footer don't overlap; scroll versus sheet drag predictable; all content/actions reachable. R. |
| X-004 | P1 | Repeat at small viewport, large system font, display scaling, light/dark, reduced animation. | No RenderFlex/red/yellow overflow, clipped Chinese, unreadable contrast, phantom characters; gesture outcome unchanged. V,L. |
| X-005 | P0 | Tap primary action twice rapidly; leave during async action; return after delayed completion/error. | No duplicate durable mutation/request, stale navigation, crash or falsely enabled conflicting action. R,D,N,L. |
| X-006 | P0 | Save/change state; close book; background/reopen; cold-reopen app. | Promised saved settings/progress/note/entity persist; transient selection/confirmation doesn't mutate on reopen. D. |
| X-007 | P1 | Reach empty, loading, valid, validation-error, remote-error, retry, cancelled states for feature. | Distinct useful messages and recovery; no endless spinner or empty success disguising error. V. |
| X-008 | P1 | Inspect semantic tree; screen-reader navigate text, unlabeled icons, swatches, canvas labels, slider values; activate. | Meaningful role/name/state and reading order; relationship meaning accessible; no critical action requires guessing coordinates. Tree,R. |
| X-009 | P1 | Lock/unlock screen, switch apps, open notifications, return; rotate physical device. | Portrait lock respected; keyboard/overlays recover; no lost input beyond documented draft policy or unexpected paid restart. R,D,N. |
| X-010 | P0 | Before any deliberate full-book reveal, inspect screenshots/tree of all text around current cutoff. | No hidden accessibility text, snippets, descriptions, source context or cached answers exposes `LATER_ONLY_秘密`. V,Tree. |

## M. Web / PWA surfaces that require separate end-to-end execution

The Flutter matrix is exhaustive for the audited Flutter controls. The web below retains additional features. Run its shared reader/graph/model/manual/marginalia behavior against the same oracle, plus every web-specific action below. A server/API test is not web end-to-end evidence. In web settings, model form appears only in `standalone`; hosted mode includes language settings, not an editable server secret.

| ID | Priority / platform | UI steps / specific controls | Expected result / evidence |
|---|---|---|---|
| W-001 | P0 W hosted | Login `书房口令`: empty, wrong, valid, Enter and `进入书房`; Back/reload/expired session. | Clear validation/auth result, no secret exposure; intended route restored or explicit gate, no stale private content after auth failure. R,N. |
| W-002 | P1 W/S | Workspace links `书架`,`接下来读`,`个人摘记`/notes, `离线书架`, `设置`; browser Back/Forward; direct reader URL with `at`/`panel`. | Route correct; old async route can't replace new one; dialog Back and focus restored. R. |
| W-003 | P1 W/S | Shelf search/clear, all filters/sorts/view modes, card/menu/continue links, `查看全部书籍`; rerender while focused. | Correct results and durable preferences; polling doesn't steal keyboard focus. R,D. |
| W-004 | P0 W/S | Import file input/multiselect; inspect receipt, retry failed/interrupted original, clear records; begin/pause/retry processing; export/restore/remove. | Actual controls all work, original operation reconciled, data retained; no Flutter behavior assumed. R,D,N. |
| W-005 | P0 W | `接下来读`: expand `从书架加入`; search; add; `显示更多书籍`; move up/down; remove; `撤销刚才的移除`; `立即同步`. | Order correct, durable and accessible by keyboard; hidden/unknown book not silently dropped; sync errors retained. R,D,N. |
| W-006 | P0 W two controlled clients | Edit queue concurrently; choose each shown local/remote conflict-resolution action in separate run; reconnect after uncertain response. | No silent overwrite; original receipt reconciled; final order matches selected choice. R,D,N. |
| W-007 | P1 W | Notebook hub search `搜索全部个人摘记`; each book/type/sync filter; pause/resume loading; previous/next page; failed book retry; reload shelf. | Correct counts/partial-state disclosures; no loss of unsynced notes; filters/search keyboard usable. R,D,N. |
| W-008 | P0 W | Hub `查看原文`; close icon/Escape/scrim; `重试预览`; jump reader; note edit/delete/sync conflict workflows. | Exact source, focus returns opener, cutoff safe; note revision/unsynced state preserved. R,D,N. |
| W-009 | P0 W | Offline library search/tabs; `刷新本机状态`; `选择书籍下载`; download/update/check/cancel; offline reopen; remove local copy. | Completeness versus partial download truthful; cached reader usable offline; local removal doesn't delete server book/personal notes. R,D,N. |
| W-010 | P1 W/S | Language dropdown: auto and every offered locale; reload; inspect long translations, inputs, reader text. | UI language changes; source book and user's notes unchanged; no missing keys/overflow; choice persists. V,D. |
| W-011 | P0 S | Model protocol/address/model/key/clear checkbox; save/test; run M-001–M-013 semantics, including unsaved-form mismatch. | Exact three protocol options, selected route used everywhere; no relay branding/default dependency. R,N,D. |
| W-012 | P0 W/S | Reader menu/Back/bookmark/pagination/keyboard; selection `记一笔`,`AI 批一句`,`完成摘录`; footnote `注`; source preview. | Correct offsets/quotes, no footnote markup in extracted text, accessible selection on touch/desktop. R,D. |
| W-013 | P0 W/S | People/full/compact graph, node select/reselect/background deselect; time slider, `回放关系的形成`; read textual edge description. | Run graph role/cutoff/readability gate: default labels visible without selection, full endpoint roles accessible, textual relationship list matches replay cutoff. The recorded Aq browser variants support only their executed coverage, not all themes/dense/F5 variants. V,R. |
| W-014 | P0 W/S | Ask textarea Enter, Shift+Enter, IME composition, `发送`, suggestions, `取消回答`, citations; leave while streaming. | No premature IME submit, cancel prevents stale answer, citations/cutoff correct. R,N. |
| W-015 | P0 W/S | Manual kind/name/note/save/edit/`取消编辑`/delete dialog; perform U cases with connected/disconnected state. | Server receipt/lock/conflict meaningful; disconnected save cannot falsely succeed; no future manual data. R,D,N. |
| W-016 | P0 W/S | Marginalia selection/page cue/persona/generate/change voice/copy/source/cancel/retry controls; inject failed verification. | Same J gates; no unverified draft/late output shown. R,N. |
| W-017 | P0 W | Progress conflict banner `保留本机位置` / `使用云端位置`; offline reading, reconnect, two clients. | Chosen position wins explicitly; no silent jump or lost reader state. R,D,N. |
| W-018 | P1 W/S | Every browser input with Tab/Shift+Tab, Enter/Escape, screen reader; narrow touch viewport and desktop; reload during action. | No keyboard trap, inaccessible graph-only content, stale dialogs, duplicate request or missing tap target. R,Tree,N. |

## N. Source audit findings and how to close them

These were found by reading source at the start of this audit; parallel implementation is addressing the notes entry/edit path, visible-form connection tests, reader Back, source preview/search clipping, privacy text, and graph controls. Their E2E status remains NOT_RUN until a candidate is exercised on device. **A code change does not close the corresponding E2E case.** Use the IDs and fresh evidence, and retain the original finding in the run's issue log.

1. `BookSheet` `我的摘记` called `onRead`, opening ordinary reading instead of the book's notes (N-009).
2. `NoteEditor` supported `existing`, but no user entry supplied an existing note: saved-note editing/deletion was unreachable (N-006/N-007).
3. `测试连接` used saved settings while editable protocol/URL/model/key could differ; Save automatically tested (M-002/M-010). The test result must correspond to what the user sees.
4. Reader toolbar `回书架` called `maybePop` while `PopScope.canPop` was false with toolbar open; first tap could only hide toolbar (R-003).
5. Source preview included 300 characters after a read citation without clamping at cutoff; a near-boundary quote could expose unread text. `仍然跳过去` only revealed text while a separate jump remained enabled (S-004/S-005).
6. Graph painter originally drew bare lines; full graph hid two-person relationships; replay lacked pause/current/reset controls (G-001–G-015). Web also originally labelled only selected edges. Its subsequent isolated Chromium Aq run verified 13 default labels for 13 edges; broader W-013 variants remain separate acceptance work.
7. Model privacy text only mentioned processing/Ask, omitting connection tests/marginalia; Settings version was hardcoded instead of exact installed build; it now reads native `appVersion` (development-only fallback `开发预览`). M-013 remains awaiting device execution.
8. Several custom controls (paper swatches, sheet back, queue minus, compact graph) lacked explicit semantic labels. Labels have been added for the swatches (`纸色：…`), `返回上一层`, `编辑接下来读`, and per-book queue removal; actual device accessibility remains unexecuted. Inspect with real accessibility tree, not source assumptions (X-008/G-015).
9. Page body originally had no visible footnote activation handler comparable to web `注`. A footer `注释 N` now opens `本页注释`, with source-bounded notes and missing-text feedback; R-011/R-012 remain awaiting device execution.
10. Source search originally clipped the match at cutoff but took trailing snippet text from the rest of the same block, potentially exposing unread text even before opening preview (S-001/S-002).
11. The all-people query state survived tab switching while its uncontrolled input could reappear blank; a persistent controller and focused regression now address that mismatch (H-003), awaiting device execution.
12. Word expansion and selection dragging originally could extend past the visible page cutoff; source-bound clipping and whole-emoji handling now have targeted tests. Real selection/clipboard/note/Ask checks remain required (R-007/R-008/N-003/Q-005).
13. Graph replay shows a historical projected graph while a newly opened person card uses the current reader cutoff. The explicit action is now `回到当前页看人物卡`, which resets replay before opening the current card; historical relationship details retain their matching `截至第 N 页` (G-008), awaiting device execution.
14. Dev4 physical testing found GraphPage still inherited the People drawer's 45% height, leaving its relationship card below the phone despite passing standalone graph screenshots. GraphPage now requests drawer expansion after the page transition; tests enter through actual `openSheet` → People → Graph and intersect label bounds with the physical screen. The same route exposed a fixed-height People tab header overflow at 320-wide/1.8 text; its height now follows measured wrapped text. Device retest remains required (G-001/H-002/X-007).
15. Dev4's replay slider announced one page beyond the visible page at an exact cutoff. Its semantic formatter now uses the same last-visible-character boundary as the header/footer; device tree retest remains required (G-015).

## O. Supporting automated tests versus real E2E evidence

| Existing test source | What it can support | What it cannot establish |
|---|---|---|
| `app/test/screens_test.dart`, `graph_screens_test.dart` | Real Flutter layout with fonts and fixed books; screenshot artifact comparison. | All buttons, IME, gestures, native dialogs, persistence on device, or graph role truth. |
| `app/test/model_settings_test.dart` | Missing-key, single-flight, late callbacks, protocol routing in widget transport. | Actual Android network route, soft keyboard, saved key UI across upgrade. |
| `app/test/processing_test.dart` | Controller/isolate lifecycle and selected drawer actions. | Background survival, responsive real reader, native process recreation. |
| `app/test/shared_import_test.dart`, `import_test.dart` | Simulated bridge/picker data handling and parser outcomes. | Content-provider permissions, Android intent/task behavior, actual chooser. |
| `app/test/backup_test.dart` | Serialization, validation, conflict/preservation. | User can export/restore through system picker and find correct file. |
| `app/test/ask_sheet_test.dart` | Retry, citation widget, cancellation/cutoff events. | Full real gesture→request→answer→source workflow. |
| `app/test/people_search_test.dart` | Returning to the all-people tab keeps the active filter visible; clearing restores results. | Real keyboard/tab gestures, saved person content or device accessibility. |
| `app/test/manual_entities_test.dart` | Revision/cutoff locks, editor validation and selected widget flows. | Every add/edit/delete input and history interaction on device. |
| `app/test/marginalia_sheet_test.dart` | Verified result/error/cancellation selected states. | All personas/page cues/clipboard/IME/back lifecycle on device. |
| Core replay/API/contract suites | Algorithm/data/HTTP correctness and deterministic baselines. | User-visible completeness; these never turn an unexecuted case above into PASS. |

Exact widget/callback occurrence counts are in [UI-CONTROL-INVENTORY.md](UI-CONTROL-INVENTORY.md). Counts include constructors used inside loops and helper widgets, so they are not a claim that every runtime state or action has been executed. The exhaustive target comes from the explicit screen/field/control/option audit, and the run still has to exercise each one.

A screenshot review after the first graph implementation found that a passing text-data assertion still allowed long names to consume all three lines, hiding both roles and `已结束`. The revised graph uses independent role-first/name/status slots; its widget checks inspect rendered role bounds, role-versus-node overlap at large text, and every label/label and label/node intersection in real Aq fixtures. A subsequent screenshot exposed another failure: collision-free labels existed outside the initial viewport. Default/reset now centers a high-priority relationship card and connected nodes when they fit, with an explicit complete-card-in-viewport assertion and shrink controls down to .3×. `graph_screens_test.dart` renders real Aq current/full/overview views as well as narrow/large-text synthetic examples. These are supporting visual artifacts, not a substitute for G-001–G-015 device execution.

Use the generated [ui-interaction-inventory.json](ui-interaction-inventory.json) to review source callbacks/fields added after this audit. It is a source locator inventory and coverage pointer, not an executable E2E suite. The run template includes a mandatory control sweep; graph label screenshots and all input submissions must be attached before regression is declared complete.

## Dated physical correction receipt — 2026-09-26 dev.5

The isolated Xiaomi probe dev.5+24 retest now verifies the three dev.4 failures
on Aq at reader page23: default People -> Graph expands and visibly contains a
complete father/son role card; its replay SeekBar announces the same page23 as
the header; and actual long-press -> multiline note -> IME -> Save preserves
page23. Exported progress remains pos5799/cutoff6086/pct28.002 and the new note
is present once at revision1. Relationship detail and prior-note retention also
passed. Receipts are retained in `book/reports/20260926-services/DEVICE-UI-E2E-DEV5.md`.
These are specific physical variants, not acceptance of complete G-001, G-015
or N-003 across all required fixtures, cutoffs, entry paths and devices. Keep
the blank template NOT_RUN. Whole-paragraph/offscreen reader accessibility
spans are a known separate gap in the current build.
