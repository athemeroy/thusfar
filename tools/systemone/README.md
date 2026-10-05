Personal System One service
===========================

`decider_service.py` is deployed as `yedu_service.py` next to the existing Laya
`backends.py`, `models.json`, model weights and llama-server runtime. Deploy
`async_jobs.py` alongside it. The existing service command and key file apply.
No provider credentials or model weights are included here.

Normal POST `/v1/systemone` remains synchronous. A POST with
`Prefer: respond-async` returns 202 immediately with `Preference-Applied` and a
relative `Location`. Authenticated GET of that location returns 202 while working,
200 with the normal result when complete, 422 for a failed check, or 410 if the
result is unavailable. GET never creates work. Eight pending jobs and the latest
256 completed results are retained; result files reside beside the private key
under `results/`. A running job interrupted by service restart is unavailable,
while already completed results survive. Job identifiers are keyed input hashes;
input text and keys are not stored in result files or printed in logs.

Test without loading a model:

    python3 -m unittest discover -s tools/systemone -p 'test_*.py'
