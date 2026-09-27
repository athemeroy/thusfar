# Dart runner continuation — 2026-09-26

## Delivered implementation

`core/lib/run.dart` exports the resumable `runBook` API. Its implementation is divided into `run.dart`, `run_loop.dart`, `run_support.dart`, `run_finalize.dart`, `run_lease.dart`, and the frozen generation prompts in `run_prompts.dart`.

The implementation covers both the two-phase extraction/linking pipeline and the classic sequential path, source fingerprint checks, durable extraction and generation caches, bounded passage evidence, relation and critical-fact verification, mention decisions, chronological graph publication, chapter recaps, biographies, story summaries, deduplication, importance and attribute settlement, quality-retry archives, cancellation, and progress callbacks. No Python runtime is invoked by the runner.

The lease uses the same POSIX `flock` primitive as Python. It remains held while accepted background operations settle. Cancellation saves successful in-flight model output and usage, prevents subsequent runner phases from issuing requests, stops queued work in all pools before draining any pool, and finally writes the same accounting snapshot to `status.json` and `work/usage.json` before releasing the lease.

Worker lifecycle and Flutter integration are separate workstreams. The worker resets judge telemetry and uses the current book's judge cache directory for each job; it restores the caller's prior directory afterwards.

## Acceptance evidence

`core/test/run/runner_replay_test.dart` performs three complete offline integration checks through the production model and classifier clients. The shared cassette transport validates stored envelopes and has no network fallback. Environment configuration is replaced with explicit placeholder settings, and local secret-file discovery is disabled by the empty environment.

1. Fresh Aq at concurrency 1: `done`, 9/9 segments, frontier 21733. All 154 normalized artifact hashes exactly match `oracle/goldens/books/aq_deepseek/provenance.json`. Requests: 21 model attempts and 82 judge attempts, with no missing cassette.
2. Fresh Aq at concurrency 12: the same 154 exact artifact hashes and request counts.
3. Paused Aq at 4/9: resumes to completion with all 154 exact hashes from `oracle/goldens/resume/aq_paused_annotated.json`. Requests: 13 model attempts and 46 judge attempts. Every prefix cache and notebook hash covered by the Python receipt remains unchanged.

Normalization is identical to `oracle/record/artifacts.py`: the explicitly listed wall-clock fields and the two scoped judge retry-duration fields are removed. No graph, usage count, model choice, state, content, or frontier difference is normalized away. The historical difference between fresh and resumed judge telemetry is retained and checked against each run's own Python receipt.

`core/test/run/runner_helpers_test.dart` also checks 323 historical captures across nine methods: cast hints (32), relation memory (33), dossiers (9), relation context (31), nearby text (8), scope boundaries (39), chapter names (19), summary verification (23), and support validity (129). These captures include Chinese and English contexts.

`core/test/run_lifecycle` contains independent integration coverage written by the worker agent, including lease conflict, source mismatch, cached replay, cancellation after successful local/classic extraction, cancellation during chapter finalization, and quality-retry archive recovery. See the dated test log for the final count.

## Defects found through integration

- The earlier runner draft assumed relation state and stance were Dart records; the judge module returns JSON lists. That lost relation end-state and changed biography inputs. Reading the actual contract restored exact cassette and artifact parity.
- Python's empty mention-disambiguation raw result is a list. The runner preserves this historical receipt shape even though the existing judge module's public return type uses maps.
- Dedupe probabilities must preserve Python integer zero rather than force `0.0`; the shared Python-compatible round helper now handles that boundary.
- A cancellation after a successful model response previously could continue into a new guard call. Checkpoints now follow durable draft saves and separate subsequent runner phases. Already accepted operations are drained before releasing the book lease.

## Commands

From `core/`:

```sh
dart analyze lib/src/pipeline/run.dart lib/src/pipeline/run_support.dart lib/src/pipeline/run_finalize.dart lib/src/pipeline/run_loop.dart lib/src/pipeline/run_lease.dart test/run
dart test -j 1 test/run test/run_lifecycle --reporter expanded
```

`core/test/run/replay_aq.dart` is a diagnostic entry point that preserves a scratch output directory and emits compact progress plus cassette counts. It uses only recorded requests. It is not an application entry point.

The full-book parity claim is Aq only. Classic processing has implementation, historical replay, and cancellation coverage; a complete fresh classic-book cassette comparison is not claimed here. No live model request, APK build, phone operation, commit, or publish was performed by the runner workstream.
