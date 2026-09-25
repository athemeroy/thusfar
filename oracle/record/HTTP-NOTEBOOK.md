# Aq notebook HTTP success receipts

`http_notebook_live.py` exercises the Python 1.7.5 HTTP handlers for three fixed
requests against the checked-in `aq_complete` snapshot. Recording is opt-in and
must be run once per route under the shared `oracle/cassettes/live` ¥1 ledger.
The recorder holds the same exclusive live lock as `http_model_live.py`. It reads
`NAS_DEFAULT_KEY` from `~/.env`, supplies it through an anonymous settings file,
and permits only `deepseek-flash+nothink` plus keyless free JEV. No key or
authorization header is written to a receipt or cassette. It checks decoded
response bodies and raw cassette attempts for a masked key suffix as well.

The fixed requests are:

| Route | Request | Allowed provider attempts | Required HTTP result |
| --- | --- | --- | --- |
| `who` | `POST /api/books/aq_complete/who`, `{pos:900,start:751,end:753}` | 0 model, at most 2 JEV | Resolved `P2` / `阿Q` with confidence at least 0.45 |
| `marginalia` | `POST /api/books/aq_complete/marginalia`, manual empathy, `pos:900,start:820,end:847`; repeat unchanged | At most 2 model, 4 JEV | Nonempty guarded comment, then the same comment with `cached:true` and no further provider call |
| `ask` | `POST /api/books/aq_complete/ask`, `pos:900`, `读到这里，阿Q经历了什么？` | At most 2 model, 8 JEV | SSE supported answer with an observed nonfuture production route |

The source tree is byte checked against `oracle/corpus/manifest.json` before and
after each exercise, and each run copies it into a new private working directory.
`JUDGE_CACHE=0` prevents an old free classifier cache from masking the provider
path. The first paid model request, when applicable, must use the production
route's reviewed prompt marker and existing token cap (160 for marginalia, 1200
for ask). Every outbound request is journaled and fsynced before transport.
The cassette store applies the same total ¥1 guard, its per-route attempt caps,
and the shared ledger; these commands do not raise any production token cap.

## Running and reconciling

Run each command only when its exact route and available budget have been
reviewed. Use a new receipt path for each route; never reuse one after an
interrupted or rejected attempt. For example:

```bash
python3.11 -m oracle.record.http_notebook_live record --route who --receipt /tmp/thusfar-who-receipt
python3.11 -m oracle.record.http_notebook_live reconcile --route who --receipt /tmp/thusfar-who-receipt
python3.11 -m oracle.record.http_notebook_live verify --route who --receipt /tmp/thusfar-who-receipt --out oracle/goldens/http/aq_who_live.jsonl
```

Substitute `marginalia` or `ask` and a separate receipt/output path for the
other routes. The `record` command creates a durable `intent.json` before the
HTTP request, then stores `outbound.jsonl` and each observed HTTP row in
`attempt-http.jsonl`. Rejected application responses are retained there and
in `failure.json`; only accepted success gets `live-http.jsonl` and
`observation.json`. `reconcile` is read only and reports the original tape and
ledger state without resubmitting. A paid request already present in the
cassette directory is refused. If the original attempt is incomplete, inspect
that receipt and cassette before deciding any further action.

`verify` first replays the original live response through the production HTTP
handler with no external sockets. It checks exact outbound digests, the entire
working tree's file hashes, and exact response bytes against the observed
receipt. It then runs two new Python processes under hash seeds 1 and 2 and
writes the golden only if both replay bytes equal the genuine live bytes. A
source or generated-state mismatch remains a failure, not an adjusted golden.
The companion report records tape hashes and the normalization list. The
provider's final invoice is unknown unless the gateway supplies a billing
receipt; guarded ledger charge is a conservative upper bound.

The narrow deterministic controls are: omit HTTP `Date`/`Server` through the
existing response header allowlist; use a fixed response clock for `ask.ms`
and marginalia `created`; choose the first existing manual comment style; use a
fixed test revision for marginalia's copied `kg.json` cache key; and fix only
the mtime/inode components of the copied `book.json` shelf cache signature.
The actual copied `book.json` size and all source bytes remain checked. These
controls apply equally to record and both replays, including on a fresh Git
checkout with different file mtimes or inode numbers.

The offline test fixture exercises all three actual handlers with synthetic
provider replies under loopback-only transport. Those fixture replies establish
recorder behavior only; they are never presented as real provider goldens.
