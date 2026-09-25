# Offline HTTP processing lifecycle

`python -m oracle.record.http_process_replay --verify` records the actual
Python 1.7.5 handler and thread worker in two fresh Python 3.11 processes with
hash seeds 1 and 982451653. All model and free JEV traffic consumes the existing
reviewed Aq cassette; nonloopback network connections are blocked.

Each pass stages a fresh Aq book and uses one HTTP/1.1 connection for:

1. `POST /api/books/aq_process_fixture/process`: the actual worker receives its
   manual queue entry and the HTTP response exposes `queued`.
2. Start the actual thread worker at configured concurrency 12 and wait for its
   completed state and completion event. The worker consumes 21 model and 82
   free JEV attempts and must finish all 9 segments.
3. `DELETE /api/books/aq_process_fixture/process`: explicitly stop automatic
   processing, preserving the completed status and every usage field.
4. `GET /api/books`: the shelf exposes the same complete status and `auto: false`.

The worker starts after the queued response has arrived. This controls scheduling
at a real lifecycle boundary; the handler, queue, worker, and pipeline functions
are not replaced. It permits an exact queued response without a race against the
worker's first status update. The worker must stop and join without errors.
On failure it also joins before cassette and network guards are removed; the
parent process has a 120-second bound on each isolated replay.

All 154 normalized book files must match `aq_deepseek`, including the full JEV
cache file set. Source bytes are checked against the corpus manifest before and
after replay. Parent and children audit the cassette tree before and after their
work; the two runs require the same tree. The controlling production and recorder
code hashes must also remain stable. The receipt preserves full HTTP JSON bodies,
request digest/count rows, worker result, and artifact hashes. It is compared byte
for byte with `oracle/goldens/http/aq_process_replay.json`.

Only the shared book recorder's time fields inside status are removed. Every
original HTTP Content-Length is checked against its raw body before normalization,
then omitted because removing times changes that length. Date and Server are
omitted using the existing response-header policy. Other allowed headers, states,
text, lists, usage counts, and file membership remain part of the comparison.

This receipt covers the thread worker used by the Android runtime. It does not
claim subprocess-worker acceptance, other-book coverage, Dart equivalence, or A0
completion. It is an offline replay of real model replies, not an additional live
provider run.
