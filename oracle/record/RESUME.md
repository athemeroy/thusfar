# Paused 1.7.5 continuation evidence

Run with the reference Python 3.11.13 interpreter:

```sh
python -m oracle.record.resume --verify
```

The recorder copies the checked-in `aq_paused_annotated` fixture into temporary
directories. It replays the existing DeepSeek/JEV cassette offline, starting at
four of nine completed segments. It also runs a fresh full book and the same
four-segment prefix. All three runs are repeated in separate processes with
two different hash seeds. It never edits the fixture or makes a live request.

`oracle/goldens/resume/aq_paused_annotated.json` records:

- SHA-256 of all 67 input files, checked against the corpus manifest;
- the reviewed live-cassette audit hash;
- all 154 normalized output artifact hashes for each run;
- each consumed request digest, kind and attempt count;
- the unchanged raw `notebook.json` and `source.txt` hashes;
- the exact fresh and resumed status/usage objects.

The fresh run must match the existing `aq_deepseek` book golden. The request
multisets must satisfy `fresh = prefix + resume`, with no model request digest
shared by prefix and resume. Request rows require unique digest/kind pairs and
positive integer counts. The source must be paused at 4/9 with frontier 8835;
its cached artifacts must match the new prefix replay, except for the paused
state and the absent transient run lock. Current counts are:

| Run | Model attempts | Free JEV attempts |
|---|---:|---:|
| Fresh full book | 21 | 82 |
| Four-segment prefix | 8 | 36 |
| Continuation from the paused fixture | 13 | 46 |

The resumed book reaches `done=9`, `total=9`, `frontier=21733`. Its notebook is
byte-identical to the input. Of the 154 artifacts, 152 match the fresh run
exactly after the existing timestamp normalization. `status.json` and
`work/usage.json` differ only in their JEV usage fields: cache hits avoid free
requests that the fresh run executes. Paid-model accounting is unchanged.
The receipt preserves these values; they are not normalized away. The literal
fresh/continuation equality gate in A5 is therefore not established for usage
telemetry. This records the existing Python behavior without relaxing that
gate or changing production code. It establishes no default-concurrency or
Dart compatibility claim: the runs use concurrency 1 and the Python oracle.

The fixture was created by the actual Python 1.7.5 pause/notebook HTTP handlers
after an offline partial replay. It is not a historical user's notebook.
`tests/test_resume_receipt.py` checks the independent replay and rejects altered
frontiers, paid usage, artifact membership, and repeated cached model calls.
