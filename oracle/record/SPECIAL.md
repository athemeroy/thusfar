# Special Python function goldens

The ordinary tracer writes a function's Python arguments and return value. Three
helpers need an explicit adapter because those values do not describe their behavior:

- `Runner._describe_factory` returns a closure. Its golden records the runner's
  people, the extraction data and plan, then calls the returned function for one
  existing and one newly introduced person. The two resulting descriptions are
  the observable output.
- `attr_facts` takes a `who_of` callback. Its golden replaces that executable
  argument with the callback's complete lookup map and retains the actual
  Python result, including tuple values and skipped empty attributes.
- `Runner.earlier_saga` reads the live KG log while holding an `RLock`. Its
  golden records the log, lock kind, cutoff arguments and returned strings.
  The lock's memory address and internal state have no value-level Dart analog.

Six more helpers are deterministic when their inputs are fixed, but the HTTP
integration tests give them timestamps and filesystem revision tuples that
change between runs. Their dedicated files retain those inputs rather than
erasing their effect:

- `manual_base.jsonl`, `manual_mentions.jsonl`, `manual_restore.jsonl`, and
  `manual_rows.jsonl` record `server.manual_entities` behavior with fixed
  `created`/`updated` values. The cases cover UTF-16 positions, profile
  versions, deleted entries, and exact validation rejections where applicable.
- `marginalia_key.jsonl` records `server.marginalia._key` with a fixed
  `(mtime_ns, size, inode)` `graph_revision` tuple. It preserves the **actual
  32-character SHA-256 key** for manual and cues modes, plus the changed-inode
  key. This field must never be normalized away because it is part of the
  cache identity.
- `notebook_validate.jsonl` records source-exact UTF-16 anchors after an
  emoji, plus the mismatched-quote and surrogate-split rejections, with fixed
  metadata timestamps in the input.

`special.py` runs each synthetic, network-free fixture in two separate Python
3.11 interpreters and publishes the files only when their bytes agree. The
adjacent `provenance.json` records the exact Python/Unicode versions and source
and golden hashes. Verification regenerates both passes and compares every byte:

```bash
PY311=/home/dev/.local/share/uv/python/cpython-3.11.13-linux-x86_64-gnu/bin/python3.11
$PY311 -m oracle.record.special --verify
```

These are value-level goldens. The concurrency guarantee of the lock and the
full behavior of arbitrary callbacks need their own Dart tests during the port.
