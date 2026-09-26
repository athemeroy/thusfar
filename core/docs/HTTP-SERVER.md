# Native Dart HTTP service

`core/bin/server.dart` runs the existing browser reader in `web/` against the
native Dart core. It does not launch Python or require Python packages at runtime.
The reusable embedding API is `package:thusfar_core/http_server.dart`:
construct `YeduHttpServer(data: ..., web: ...)`, await `start()`, then await
`close()` during shutdown.

## Run

From the repository's `core/` directory, with a Dart SDK available:

```sh
dart pub get
YEDU_LOCAL_MODE=1 COOKIE_SECURE=0 dart run bin/server.dart \
  --host 127.0.0.1 --port 18770 \
  --data /absolute/path/to/reader-data --web /absolute/path/to/repository/web
```

Open `http://127.0.0.1:18770`. `YEDU_LOCAL_MODE=1` enables browser model settings.
The HTML shell advertises local settings with a non-sensitive capability marker;
normal desktop browsers can configure the service without an Android user agent.
Choose OpenAI Compatible, Gemini, or Claude Compatible and supply the endpoint,
model and API key. There is no embedded relay preset. A new configuration has an
official OpenAI endpoint and an empty model; it requires explicit configuration
before model use. Existing saved settings remain readable.

The default listener is **127.0.0.1**, and `AUTO_PROCESS` defaults to **0**.
Starting the service can reconcile interrupted jobs to paused state; it does not
start model processing. The reader's explicit processing action starts a job.
`AUTO_PROCESS=1` opts into the persisted automatic queue. `--host 0.0.0.0` is an
explicit choice to listen on other interfaces.

For an externally reachable deployment, set a `PASSCODE`, terminate HTTPS at the
existing reverse proxy, and retain the default `COOKIE_SECURE=1`. Plain HTTP
local use requires `COOKIE_SECURE=0` when a passcode is enabled. The server keeps
its cookie signing identity in the selected data directory, including across
restarts; POSIX secrets are mode 0600 before their contents are written.

A native executable can be built on the normal build executor:

```sh
dart compile exe bin/server.dart -o /absolute/path/to/yedu-server
```

Distribute the executable with `web/` next to it, or pass an explicit `--web`.
Always select the intended persistent `--data` directory. A compiled binary
without adjacent `web/` uses the current directory for default data/web paths.
SIGINT/SIGTERM closes the server, cancels worker activity and waits for owned
worker tasks to settle. Existing book caches remain available for later resume.

Environment options are `DATA_DIR`, `WEB_DIR`, `PASSCODE`, `YEDU_LOCAL_MODE`,
`AUTO_PROCESS`, `COOKIE_SECURE`, `HTTP_READ_TIMEOUT` (seconds, default 30),
`ANSWER_TIMEOUT` (seconds, default 180), `HTTP_CONCURRENCY` (default 32),
`ASK_CONCURRENCY` (default 2), and `YEDU_RELEASE_ID`/`RELEASE_ID`.

## Browser/API coverage

| Surface | Native behavior |
| --- | --- |
| Browser shell, assets, HEAD, ETag/304, gzip | Serves the existing `web/` files and SPA navigation routes |
| `/healthz`, `/api/health`, login/me/logout | Worker health, signed seven-day cookies, same-origin writes, persistent login throttling |
| Settings, test connection | Local mode only; shared protocol-aware `ModelSettings` |
| Book shelf, book metadata, chapter, images | Existing response schema and content offsets |
| Graph, manual entities, notebook and Markdown export | Core implementations, optimistic conflict handling and prefix visibility |
| Reading list and progress | Persistent updates, revisions and expected timestamp conflicts |
| Processing and deletion | Explicit Worker start/pause, cancellation/lease wait before trash rename |
| Raw book upload | TXT and EPUB parsing, content deduplication, assets, temporary-directory publication |
| Backup export/import | `yedu-book/1` and `/2`, graphs, mentions, notes, manual entities, images and progress; conflicting snapshots return 409 |
| Offline manifest | Stable content-based revision identifiers for browser invalidation |
| Ask SSE and selected-word identity | Native source retrieval/judge/guard pipeline; staged SSE output and bounded admission |
| Manual/automatic/cue marginalia | Native source-anchored service and persistent verified cache |

The shared AI gate stays owned until the underlying call settles, including when
HTTP or a core service times out first. SSE timeout/disconnect cancels subsequent
publication. Marginalia timeout cancels later guard work/cache publication.
Partial HTTP request bodies return 408; unused bodies are drained so later
requests can safely reuse the same connection. Requests have a 1 MiB normal-body
limit and a 200 MiB upload/backup limit.

## Deliberate differences and remaining limits

- MOBI, AZW and AZW3 upload has **no native parser**. The service returns 400 and
  asks the reader to convert to EPUB. TXT/EPUB import and backup restore are real
  implementations; there is no hidden Python/Calibre subprocess fallback.
- Model settings expose the new `protocol` field and the generic configuration
  described above. The old relay-specific default settings body is intentionally
  not reproduced. Changing an endpoint/protocol with a saved key requires the
  key to be resupplied or cleared.
- Book/offline cache versions use content hashes. They are opaque browser cache
  identifiers, so they differ from Python's inode/mtime-derived strings.
- Duplicate normalized mention chapter keys in a backup are rejected rather than
  silently overwriting one chapter's data. Native invalid-body diagnostics can
  differ from Python parser exception text.
- HTTP acceptance tests use recorded responses or injected model backends. They
  do not establish online provider connectivity, proxy deployment, browser GUI
  acceptance, or an independently packaged executable on every OS.

## Verification

From `core/`:

```sh
dart analyze lib/src/server/http_server.dart lib/src/server/http_books.dart \
  lib/src/server/http_transfer.dart lib/src/server/ask.dart \
  lib/src/server/marginalia.dart bin/server.dart test/http/http_server_test.dart
dart test -j1 test/http/http_server_test.dart test/ask/ask_test.dart \
  test/marginalia/marginalia_test.dart
```

The HTTP integration suite binds real ephemeral loopback ports. It replays all
60 cases in `oracle/goldens/http/aq_complete.jsonl`, compares stable JSON and
response headers, and documents the intentional settings/version differences.
The suite contains 15 HTTP tests. Additional tests exercise actual Ask retrieval/guard/cache integration, native
Marginalia cancellation, sustained login throttling, cookie persistence/expiry,
POSIX secret permissions, connection reuse, partial-body deadlines, default
worker reconciliation without model calls, and non-destructive backup conflicts.
The test transport rejects every attempted live model request.

`node tests/model_settings_form.test.mjs` checks browser controller behavior with
a small DOM seam: local-settings capability, unsaved probe payload, shared form
admission, and suppression of replies after navigation abort.
`node tests/api_process.test.mjs` verifies the existing process reconciliation
behavior. These tests do not replace full browser layout/pointer acceptance.
