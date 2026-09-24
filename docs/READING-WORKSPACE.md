# Reading workspace — 1.3

## Product decision

The reading loop is: resume a book, keep a thought, find the original passage, inspect it without losing your place, then continue. The home emphasizes the reader's activity. Generated cast, relationships and recaps remain available under reading material. Normal reading, bookmarks, personal notes, literal search and source previews require no model call.

## Delivered modules and removal boundaries

| Module | Files | Contract and dependencies |
| --- | --- | --- |
| Reading home | `web/js/shelf.js`, `library.js`, `web/css/library.css` | Uses existing book/progress/import endpoints. Dirty local positions win for continuation. All/reading/unread/finished/downloaded filters are derived from saved progress, not inferred preference. Import receipts persist; active requests belong to the shelf route. |
| Passage navigation | `web/js/search.js`, `views.js:tocView`, `web/css/search.css` | Literal search of one book, UTF-16 source anchors. Defaults to the current page cutoff; explicit whole-book scope permits spoilers. Bounded windows resume without retaining the entire text. |
| Personal notebook | `server/notebook.py`, notebook routes in `server/app.py`, `web/js/notebook.js`, API methods | Additive `notebook.json` per book. Local durable edits, per-item revisions, operation receipts, deletion tombstones and explicit conflicts. Export/import carries notes and rejects different existing personal records. |
| Source preview | `web/js/source-preview.js`, `web/css/source-preview.css` | `ctx.goSource(start,end)` previews; `ctx.jumpSource(start,end)` commits navigation. Previews fetch one chapter and never write progress. |
| Reader organization | `readerview.js`, `companion.js`, `panes.js`, `reading-workspace.css` | Dock: contents, excerpt, notebook, material, questions, typography. Management moved into material. Persistent menu affordance, selection mode and native Back cooperate with pane history. |
| Android 1.3.0 | Android policy/activity/build files | Same signer; version code 4. Adds strictly same-origin Markdown notebook saving. Existing 1.2 users can copy notes and are directed to update for native notebook download. |

The feature commits retain their implementation boundaries. They are building blocks of the integrated release, not independently deployed or separately accepted products. The final integration commit registers modules, styles and service-worker assets. To remove a UI feature, remove its entry/registration and assets while preserving its stored data. Reverting notebook persistence alone underneath the notebook UI would break that contract. Existing correctness repairs are a separate baseline and must not be undone incidentally.

## Personal data semantics

- A note uses a source start/end and an exact quotation from a single text block. The server validates UTF-16 positions and quote equality; it does not guess a new attachment after source changes.
- A bookmark is a point anchor. Page numbers are display values and may change with typography. Each note has a `knowledge_cutoff`: later thoughts attached to an earlier paragraph remain hidden after rewinding. Unsaved drafts carry the same boundary. Deliberately enabling later notes or opening a later draft can reveal the user's own later thoughts.
- The local store writes before reporting success. Quota failure leaves the editor open. Web Locks serialize same-origin notebook mutations where supported; older engines without Web Locks serialize callers in one page only. Modern Chromium/WebView is the validated target.
- Server synchronization uses a per-note expected revision. Uncertain acknowledged requests reuse their operation ID. Concurrent changes offer the other version or both versions; later responses cannot regress an acknowledged revision. Different note IDs merge independently.
- In-reader notebook text is current-cutoff scoped by default. Markdown export explicitly contains all personal notes, including later ones. Unsynchronized local notes are included by the copy action; server file download and whole-book backup contain synchronized notes. Drafts remain device-local.
- A complete new offline download includes a notebook snapshot. Later edits merge from the device store and synchronize on reconnection. Old downloaded books retain their old package until refreshed. Clearing browser storage can remove unsynchronized notes/drafts; this is not represented as server-backed data.
- Deleting a book preserves its server directory, including notebook, in recoverable trash. Restoring the same book with a different notebook refuses overwrite. No user annotation is automatically made a model training label.

## Navigation and scope

Search defaults to the active reading cutoff, not the furthest-ever position. It bounds each batch by 30 results, 12 chapters, 256 Ki UTF-16 units and a time slice. A partial scan or unavailable offline chapter is distinct from an empty complete result. Whole-book search requires an explicit scope switch.

Source inspection opens a bounded preview before committing a jump. The original page and progress stay unchanged. A requested future source hides its text and title and offers an explicit later-position jump. Committing a jump retains the return chip; pressing it returns to the earlier source anchor. Selection mode temporarily disables page gestures, accepts text or element DOM boundaries, and excludes footnote markers from quote offsets.

Layout changes distinguish themselves from reading navigation so a software-keyboard resize does not replace an active note editor. Pending scoped-pane refreshes survive superseding pagination callbacks. This behavior is browser-tested.

## Validation and retained versions

The release gate runs the Python suite, JavaScript parsing, Node suites and four browser suites: original reading regressions, library journeys, isolated source preview, and integrated reading workspace. All use synthetic data or read-only actual production probes. No provider model or GPU job is required for these features.

The Android artifact is separately built offline, checked for version/signature, and tested with host-JVM navigation/download policy checks.

## Deliberate next scope

The next-reading queue, cross-book personal notes and offline inventory are implemented in the following [library workspace increment](LIBRARY-WORKSPACE.md). Reading re-entry from bounded original excerpts and genre-specific lookup remain separate opportunities. A saved reading percentage is not evidence of comprehension or a user-selected finished status. No classifier accuracy or local-model rollout acceptance follows from these interaction changes.
