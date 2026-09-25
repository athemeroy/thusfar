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
