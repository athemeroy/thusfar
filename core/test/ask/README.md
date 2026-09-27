# Ask port evidence

`generate_reference.py` imports the original Python `server.ask` implementation.
It records prefix retrieval, complete answer prompts and events, guard rejection
and rewrite, Unicode source markers, and exact pronoun selection. Routing, judge,
translation and chat are replaced with local fixtures; no network calls occur.
The fixture includes the SHA-256 of the Python source used for recording.

Run from the repository root:

```sh
python core/test/ask/generate_reference.py
cd core
dart test -j 1 test/ask/ask_test.dart
```

The Dart tests compare the recorded complete model requests and ordered events,
ignoring only elapsed milliseconds. Additional behavioral tests exercise the
actual chat client with an offline SSE transport, source and settings cache
invalidation, rejected-answer auditing, corruption visibility, cancellation,
and retention of concurrency permits while timed-out requests finish.

`AskService` adds a memory-only answer cache to the Python behavior. Its keys use
the exact book, graph and status bytes, reader cutoff, question and model settings;
withheld answers are never cached. Configuration changes during a request prevent
cache insertion. The paragraph index retains Python's four-book / eight-MiB
bounds, using a book content digest in place of file stat identity. No new cache
format is written into a 1.7.x data directory.

`whoIs` also rejects a selected span that crosses the reader cutoff before calling
the judge. This is a deliberate boundary check around the original pronoun logic.

Flutter interaction coverage lives in `app/test/ask_sheet_test.dart`. It checks
explicit submission, stages, repeated-submit prevention, failures and retries,
source navigation, quote prefilling, rewind isolation and disposal cancellation.
