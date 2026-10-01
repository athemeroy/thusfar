# Verify recorded fixtures

Use Python 3.11.13 and run these commands from `reference/`:

```sh
python3 -m oracle.record.verify_book_artifacts
python3 -m oracle.record.verify_folds
python3 -m oracle.record.concurrency --verify
python3 -m oracle.record.resume --verify
python3 -m oracle.record.http_process_replay --verify
python3 -m oracle.record.verify_live_cassettes oracle/cassettes/live
```

These checks use committed data and recorded replies. Do not enable live
recording or provide API credentials during routine verification.

Function-golden provenance is pinned to its recorded source commit. Run
`python3 -m oracle.record.verify_function_goldens` against that source tree;
do not replace hashes to make a different tree look like the recorded input.
Regenerating a fixture requires reviewing its source, complete output, and any
changes to its privacy or redistribution status.
