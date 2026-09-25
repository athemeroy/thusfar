# Python 1.7.5 oracle recorders

Use Python 3.11.13, the version embedded by the 1.7.x Android app. The system `python3`
may be Python 3.13 and has different Unicode behavior. All commands below are launched from
the repository root. Recording is an A0 activity; nothing here changes the Python engine.

## Function calls

`functions.py` reads `docs/port/inventory.json`, selects rows categorized `纯函数`, and
matches calls by source path and definition line. This disambiguates the two nested `_toc.walk`
functions. It traces the Python test suite, parser corpus, manually supplied edge cases, and
optional book replays. Inputs are copied at call entry and outputs at return. Non-JSON Python
types carry tags (`$tuple`, `$set`, `$map`, `$bytes`, `$xml`, `$path`). Unsupported values are
counted in `record-report.json`, never silently discarded. Duplicate inputs with different
outputs are reported as non-deterministic and receive no golden file.

The committed ordinary goldens came from two independent Python 3.11.13 runs at frozen
input commit `1f532d942b7c1c2d4a1cdcaed4e8825056749b34`. They used hash seeds 1 and 2
and the checked-in wire tape. Each passed 298 Python tests, replayed all 9 阿Q segments and
the first of 25 French segments offline, and produced a byte-identical output tree. The
complete workload is:

```bash
PY311=/home/dev/.local/share/uv/python/cpython-3.11.13-linux-x86_64-gnu/bin/python3.11
env PYTHONHASHSEED=1 $PY311 -m oracle.record.functions \
  --unittest --corpus oracle/corpus --manual oracle/record/manual.jsonl \
  --replay-book oracle/corpus/snapshots/aq_complete \
  --replay-french-prefix \
  --cassettes oracle/cassettes/live --book-start fresh --concurrency 1 \
  --maximum 200 --out /tmp/thusfar-functions-pass-1
env PYTHONHASHSEED=2 $PY311 -m oracle.record.functions \
  --unittest --corpus oracle/corpus --manual oracle/record/manual.jsonl \
  --replay-book oracle/corpus/snapshots/aq_complete \
  --replay-french-prefix \
  --cassettes oracle/cassettes/live --book-start fresh --concurrency 1 \
  --maximum 200 --out /tmp/thusfar-functions-pass-2
diff -rq /tmp/thusfar-functions-pass-1 /tmp/thusfar-functions-pass-2
```

The corpus includes an intentionally empty TXT. `expected_rejections.json` states its exact
Python exception and text; any other unexpected parser error stops recording. Test workloads
can use loopback fake servers, while the function recorder blocks non-loopback connections.

`verify_function_goldens.py` audits the exact ordinary `pipeline/` and `server/` JSONL file
set against `record-report.json`, every physical sample count (maximum 200), sorted unique
input digests, the 125 selected pure-function IDs in the current inventory, zero conflicts,
and the five unobserved functions' named special fixtures. It checks the report byte hash and
provenance totals. `KG.canon` inputs retain only the visited `merged_into` chain; unrelated
graph mentions cannot change this function's golden. `classify`, `finish`, and
`settle_rewrites` mutate their input objects and have stateful special goldens instead of
ordinary pure-function goldens. The two-pass provenance declares this explicit tree algorithm:
SHA-256 over files sorted by POSIX relative path, feeding each UTF-8 path, one NUL byte, and
the raw 32-byte SHA-256 digest of that file's bytes. The tree includes 120 ordinary function
JSONL files plus `record-report.json`, and excludes special goldens and provenance itself.
The current result is 120 ordinary functions, 4,783 samples, and 44 tagged exception outputs;
both passes produced tree SHA-256
`90cbb0cbe27a2b084f66ae3d0f2b6b5f25f4e974a317f19f1b81a452f3bfd67c`.
Provenance also names the exact 1,601 recording input paths and their SHA-256 content tree,
`b83e6d8daf3497d0e871728cbfe1b055481c1b467a71453eb42f0efb65e5d880`.
That tree includes Python source and tests, inventory, manual cases, corpus, cassettes,
recorder scripts, and other fixtures read by the test suite. It excludes the ordinary
function output tree, Dart files, and STATUS/NOTES. The verifier recalculates both trees
and rejects changed, added, or removed inputs. The source commit records the freeze point;
the content tree is the actual drift check, so later documentation-only commits do not
invalidate the evidence. CI additionally replays the complete workload once with its
network guard and compares the resulting ordinary tree SHA with this committed provenance.
Run `--tree-sha` after both passes match to calculate the value before writing provenance;
the default command checks the declared digest and inventory against the checked-in files.

```bash
$PY311 -m oracle.record.verify_function_goldens --tree-sha
$PY311 -m oracle.record.verify_function_goldens --input-tree > /tmp/thusfar-function-inputs.json
$PY311 -m oracle.record.verify_function_goldens
```

The checked-in tape covers 阿Q's complete book replay and the first French segment.
`--replay-french-prefix` stages the verified public-domain French parser fixture and enforces
a fresh, single-worker, one-segment replay. Jekyll has only 19 of 20 segments recorded;
Japanese and 儒林外史 have no model-backed segment. Use
`--book-start fresh` for a new book and `--book-start resume` for a 1.7.x partial snapshot.

## Model and free JEV cassettes

### Stage a checked-in public-domain book

The five parser-only `book.json` goldens can be turned into fresh source-book directories
without a model or network. `stage_corpus.py` accepts only `aq`, `jekyll`, `french`, `kokoro`,
or `rulin`. It checks the raw source against `corpus/manifest.json`, checks the parser SHA and
case in `goldens/parsed/report.json`, reruns Python 3.11 `parse_file`, and compares the complete
book JSON bytes with the committed golden. A new output directory receives exact `source.txt`
and `book.json` copies plus `.oracle-stage.json` containing source, manifest, parser, report,
and output hashes. It refuses an existing destination and never stages inside frozen inputs.
Use a separate new `--working-book` when starting a live or replay workload; keep its original
path for `--resume-existing`.

```bash
$PY311 -m oracle.record.stage_corpus jekyll --out /tmp/thusfar-corpus-jekyll
$PY311 -m oracle.record.stage_corpus french --out /tmp/thusfar-corpus-french
```

The IDs `kokoro` and `rulin` use the same command. The staged directory is parser-only: it has
no `work/`, `kg.json`, or `status.json` until a separate cassette-backed workload runs.

### Transport recording

`cassettes.py` intercepts only `pipeline.llm._opener`. Each request digest covers method,
URL, nonsecret headers, and the exact UTF-8 request body. It deliberately excludes every
authorization header. Responses preserve status, relevant headers, raw read chunks, HTTP
errors, and socket timeouts. Replaying a missing request fails closed. Synthetic transport
cases are generated separately and labelled `source: synthetic`:

```bash
$PY311 -m oracle.record.failure_cassettes /tmp/thusfar-failure-cassettes
```

The live command requires explicit invocation and a fresh working directory. It accepts only
`deepseek-flash+nothink` at `https://open.xiaojingai.com/v1` and the keyless
`classifier.dev` route. It reads `NAS_DEFAULT_KEY` through the existing Python client without
displaying or saving it. Attempt caps bound the number of requests. Before each model request,
`budget-ledger.json` durably reserves a conservative upper bound from UTF-8 request bytes,
the requested output token ceiling, and **twice** the gateway rates in `pipeline/models.py`
to cover a possible peak tariff. A shared
lock and a cumulative `--max-cny` ceiling of at most ¥1 prevent separate runs from exceeding
the same cassette directory's guarded estimate. A response with token usage settles to a
token-based rate estimate; the actual account bill requires a gateway receipt.
An error or missing usage keeps the full reservation charged. The ledger retains a reservation
if a process dies mid-request. A copied book is used so corpus files remain unchanged.
Concurrent attempts for the same request digest can be replayed only when their replies are
identical. Divergent sequential retries, such as a 503 followed by success, retain their
request order. The scanner rejects ambiguous concurrent replies.

```bash
$PY311 -m oracle.record.workload oracle/corpus/snapshots/<book_id> \
  --mode record --start fresh --working-book /tmp/thusfar-live-book \
  --cassettes oracle/cassettes --max-model-attempts 16 --max-jev-attempts 200 \
  --max-cny 1.0
```

Use `--mode replay` with a different `--working-book` to consume existing cassettes without
network access. Never record a new live run merely to diagnose an uncertain earlier run;
inspect and reconcile its original working directory and cassette request digests.
Use `--resume-existing` with the same source, working directory, cassette directory, and start
mode to continue an interrupted live run. It checks the source hash, receipt, and cassette
ledger before doing paid work. A pending request requires reconciliation first.

### Audit a live tape without replaying or paying

`verify_live_cassettes.py` reads an existing tape and prints one JSON summary containing only
counts, configured-rate estimates, the cumulative guarded charge, and a SHA-256 tree
fingerprint. It accepts only exact `deepseek-flash+nothink` streaming request envelopes at the
approved gateway and keyless `classifier.dev` envelopes. It rejects authentication fields,
known credentials (including decoded response chunks), pending or ambiguous attempts,
unmatched ledger entries, usage/price mismatches, and charges above the stored ceiling of at
most ¥1. It makes no model or network call and changes no tape file. Save its output outside
the cassette directory to compare a later audit with `--expect-report`:

```bash
$PY311 -m oracle.record.verify_live_cassettes /path/to/live-cassettes \
  > /tmp/thusfar-live-audit.json
$PY311 -m oracle.record.verify_live_cassettes /path/to/live-cassettes \
  --expect-report /tmp/thusfar-live-audit.json
```

The configured and guarded prices are local estimates. A provider receipt is required to
confirm the actual account charge, and a structurally valid tape alone cannot prove who
served the original response.
CI audits the checked-in `oracle/cassettes/live` directory against the safe, count-only
`oracle/record/live-a0-audit.json` fingerprint. Neither file contains the model key.

## Book artifacts, HTTP routes, and browser fold

`artifacts.py --mode historical-cache` freezes the surviving historical 1.7.x 阿Q cached
snapshot directly, with its original model name in `provenance.json`. The rights-unverified
Bovary translation and its derived goldens were removed from the tracked tree. The recorder
never presents cached Gemini 2.5 Flash Lite output as DeepSeek wire replies. Once actual
DeepSeek cassettes exist, `--mode cassette-replay`
copies a source book and runs each pass in a separate Python interpreter so global JEV counts,
rate state, and circuit breakers start clean. Both modes publish `book.json`, `work/**`,
`kg.json`, `mentions/**`, and `status.json` only if every normalized file is byte-identical.
The normalizer removes fields that represent elapsed or wall clock time (`updated`, `started`,
`finished`, `created`, `exported`, `_secs`, `_ttft`, `seconds`, `timing`) and the runtime retry
duration at precisely `status.json:usage.jev.retry_wait_seconds` and
`work/usage.json:jev.retry_wait_seconds`. It retains same-named fields elsewhere. All other
fields, list order, and file presence remain part of the comparison.

```bash
$PY311 -m oracle.record.artifacts oracle/corpus/snapshots/aq_complete \
  --mode historical-cache --out oracle/goldens/books/aq_complete
$PY311 -m oracle.record.artifacts oracle/corpus/snapshots/<book_id> \
  --mode cassette-replay --start fresh --cassettes oracle/cassettes \
  --out oracle/goldens/books/<book_id>-deepseek
```

`http_routes.py` exercises every route family in `server.app.Handler.route` with an isolated copy
of a corpus book over a reused HTTP/1.1 connection. It includes successful writes and
validation failures. Each pass hard-links the same baseline files so inode-based revision
values stay stable. It freezes the server clock, keeps the original response version and
time fields, and replaces only the random session cookie value with `<session>`; cookie
attributes remain. The companion `-report.json` records that normalization. Routes that
require a real model are represented in this baseline by validation/error responses. A
separate synthetic interface fixture exercises successful `/who`, `/ask`, and `/marginalia`
responses without claiming that its generated text came from DeepSeek or classifier.dev.
Reuse one persistent `--baseline` path across separate invocations; moving it to another
filesystem can change inode-derived revision values.

```bash
$PY311 -m oracle.record.http_routes oracle/corpus/snapshots/aq_complete \
  --baseline /tmp/thusfar-http-aq-baseline \
  --out oracle/goldens/http/aq_complete.jsonl
$PY311 -m oracle.record.http_model_synthetic oracle/corpus/snapshots/aq_complete \
  --baseline /tmp/thusfar-http-model-synthetic-baseline \
  --out oracle/goldens/http/aq_model_synthetic.jsonl
node oracle/record/fold.mjs oracle/corpus/snapshots/aq_complete \
  oracle/goldens/books/aq_complete/fold.jsonl
```

`http_model_synthetic.py` passes each HTTP request through the real Python route handler and
real model client serialization/parsing. Its only substitution is the outbound opener: exact
`.invalid` model and classifier URLs return labeled in-memory responses. The client key loader
accepts only an in-memory fixture key and cannot read an ambient secret; the classifier path
has no Authorization header. Unknown prompts, URLs, models, thinking modes, or extra model
calls fail closed. The fixture records one successful person resolution, one complete SSE
answer with a supported guard verdict, and a manual generated comment plus its cached reply.
It freezes the clock, reuses the same persistent hard-linked source baseline, verifies exact
HTTP status/body contracts, and compares both HTTP bytes and sanitized model request hashes
twice. Its report says `source: synthetic in-memory transport`; it is not a live model
cassette or proof of model answer quality. Genuine model-backed route responses remain pending
until matching live wire cassettes cover these calls.

`http_edges_synthetic.py` adds 18 explicitly synthetic HTTP branch cases to the 60 route
baseline and four model-success cases: a successful settings probe plus 401/timeout replies,
future-question refusal, a guard-withheld answer, automatic marginalia and its cache hit,
validation and missing-resource errors, admission 429s, an incomplete-body 408, passcode
rejection, and nonlocal settings access. Its transport accepts only reviewed `.invalid`
requests and in-memory replies; the 429 and 408 cases exercise the real loopback handler.
`tests/test_http_edges_synthetic.py` re-records in two separate Python 3.11 processes and
compares exact bytes with `oracle/goldens/http/aq_edges_synthetic.jsonl` and its report.
The total is 82 cases across 27 reported route families, but live provider-backed success
answers and long-running worker success remain outside this synthetic evidence.

The Node command imports the actual `web/js/kg.js`, calls `KG.world(cutoff)` at 20 evenly
spaced cutoffs, and records people, relations, events, recaps, canonical identities, ranking,
and per-person relations.

Before committing any cassette or golden tree, scan decoded response chunks as well as JSON:

```bash
$PY311 -m oracle.record.scan oracle/cassettes oracle/goldens
```
