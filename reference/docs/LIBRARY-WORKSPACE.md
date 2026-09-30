# Personal library workspace — 1.4

## Product behavior

The non-reader workspace has four destinations: the existing reading home, an explicitly ordered next-reading list, personal notes across visible books, and this device's offline inventory. Mobile navigation stays at the bottom; desktop navigation stays above the page. Opening a book still goes directly to its saved reading position.

The queue records intent. It does not infer a preferred book from completion percentage, automatically remove books when opened, or mark comprehension. A reader chooses books, moves them up or down, removes them and can undo the last removal. Unavailable books remain named placeholders until explicitly removed. Reading progress and queue order are separate records.

The notebook hub searches loaded personal quotations and thoughts across books, with book, note type and synchronization filters. Its scope explicitly includes later personal thoughts; the in-reader notebook retains its existing current-cutoff scope. A source preview verifies a stored quote against the current chapter before offering an explicit reader jump. Browsing and previewing do not commit navigation. Failed or partial loads are visible and can be retried.

The offline inventory lists actual packages on this device, supports download, pause, retry, explicit update checking and removal of the local copy. It distinguishes a complete published package from staged content and unverified legacy details. A successful update replaces the previous package only after all resources and the manifest version have been checked. Removing a local package preserves server books and personal local records.

## Ownership and removal boundaries

| Component | Main files | Storage and dependencies |
| --- | --- | --- |
| Workspace navigation | `main.js`, `workspace-nav.js`, `workspace-nav.css` | Hash routes `#/`, `#/next`, `#/notes`, `#/offline`; never mounted in the reader. |
| Next-reading queue | `server/reading_list.py`, `/api/reading-list` routes, `reading-list.js`, `reading-list.css` | Shared `data/reading-list.json`; durable browser state `reading-list-v1`; bounded visible-book metadata cache. |
| Cross-book notebook | `notebook-hub.js`, `notebook-hub.css` | Read-only projection of existing per-book notebook APIs and local notebooks. No new personal data format. |
| Offline inventory | `offline-library.js`, `offline-library.css`, worker inventory/removal messages | Existing offline index and cache packages. Personal notebook snapshots survive local-copy removal. |
| Android package | Gradle version and application user agent | Version 1.4.0, code 5, same signing identity as 1.3. Existing clients receive the web workspace through the normal shell update. |

To remove a destination, remove its navigation/route, entry points and precached assets together. Preserve durable queue/notebook records. Reverting a new UI alone is safe only if no remaining entry points import it. The service worker has shared offline correctness fixes; do not incidentally undo those when removing the inventory page. The queue API is additive and an older runtime can ignore its data file during rollback.

## Persistence and concurrency

The server uses one whole-list revision and an operation receipt. A write must match the expected revision. Replaying the same last operation with the same order returns the same receipt; reusing its operation ID for different content is rejected. Concurrent ordering changes produce a conflict with the current server snapshot. Only new additions must still be visible in the library; already unavailable slots can be retained or removed. Requests cannot add hidden comparison copies.

The client persists desired order before reporting success, serializes same-origin edits through Web Locks where supported, and preserves the original uncertain in-flight operation separately from later local edits. A conflict displays both orders and requires an explicit choice. A server acknowledgement means other devices can retrieve that version; it is not proof that another device has already loaded it.

Notebook aggregation never writes its projection back to the durable store. It loads at most three books concurrently, caps each book's projection and total retained content, and renders bounded pages. Local dirty records take precedence over fetched snapshots. Hidden or unlisted local book IDs are not enumerated into the hub. Search covers the loaded projection and reports missing or partial books.

Offline-copy removal uses a separate worker operation from server-book deletion. Downloads and removals exclude each other for the same book. Cancellation is checked again before publishing the completed snapshot. Network response caching must respect removal boundaries so an older response cannot silently recreate a removed package.

## Acceptance

Tests use synthetic books with a disabled processing worker and no external provider calls. Coverage includes API idempotency and concurrent ordering, browser offline reload and cross-device conflict choice, bounded note aggregation, source verification without progress changes, cache cancellation/removal, responsive routes, direct-route authentication and existing reading regressions. Release proof binds the exact runtime source fingerprint.
