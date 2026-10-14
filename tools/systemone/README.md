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

Independent CUDA backend
------------------------

Pass `--backend-url http://192.168.31.213:47839` to use the independently managed
Windows backend. The adapter stays on MINI with its existing key and result
files. Without that option the adapter still owns its original local backend.
The health endpoint now checks the actual backend instead of a child PID.

`deploy-windows-backend.ps1` installs a startup task on the 4090 machine from
three files already placed in `D:\Decider`: the existing pinned Q8_0 weights,
`llama.zip`, and `cudart.zip`. It verifies their hashes. The two runtime archives
are the official llama.cpp b11418 Windows CUDA 12.4 x64 release and CUDA DLL
package: https://github.com/ggml-org/llama.cpp/releases/tag/b11418 .
The inbound backend port permits MINI only. No Qwen settings change.

Measured on 2026-10-05 using the same synthetic Chinese context and 30 questions:
MINI 57.305 seconds, CUDA 2.693 seconds; both answered 30/30 correctly.
With a concurrent 160-token Qwen request the checks took 5.162 seconds and still
answered 30/30 correctly. Qwen completed normally through the NAS HTTPS endpoint
in 3.970 seconds (earlier standalone sample: 5.647 seconds). These are short
samples, not a comprehensive performance guarantee. Extra GPU memory was about
1.67 GiB, leaving about 3.97 GiB available. Authenticated async POST/GET and
previously stored results were verified after switching the production adapter.

The scheduled task is `Yedu-Decider-4090`; its command and log are
`D:\Decider\start.cmd` and `D:\Decider\runtime.log`. MINI retains its existing
`com.yedu.decider-user` LaunchAgent. To roll back, restore MINI's
`yedu_service.py.before-4090-20261005` and
`com.yedu.decider-user.plist.before-4090-20261005`, unload/reload that LaunchAgent,
then stop and disable the Windows task. Saved results stay in place.

Read-only dashboard and activity records
---------------------------------------

Deploy `monitor.py` and `dashboard.html` alongside the adapter. The optional
`--machine 'RTX 4090'` labels the computing machine. For current GPU readings,
`--hardware-status-url http://192.168.31.213:1236/v1/status` uses the existing
Strata hardware monitor with the adapter's existing key. It reads status only;
it does not submit inference or change Qwen. Only GPU name, memory, utilization
and temperature are retained. GPU memory is for the whole card, including Qwen.

- `/v1/decider/dashboard`: Chinese mobile-friendly page, refreshes every 5 seconds.
- `/v1/decider/dashboard.json`: readiness, active progress, queue, cumulative
  completed checks/items, recent durations/errors, and GPU readings.
- `/v1/decider/logs`: downloads the latest 100 completion/error records.

These read-only paths require no API key and contain no book text, titles,
answers, job tokens, keys, request addresses or error messages. Inference and
saved-answer retrieval retain their existing authentication. The current NAS
proxy forwards `/v1/decider/` to the adapter; its existing exact health route can
stay. The dashboard can be opened at the same hostname as the model endpoint.

Cumulative counts and the latest 100 records persist in `activity-summary.json`
beside the private key. `activity.jsonl` retains timestamped startup/completion/
failure events, rotating at 2 MiB with two backups. Only exception class names
are recorded; the page displays plain Chinese descriptions. Counts begin when
the monitor is deployed, and count actual model checks, not repeated downloads
of saved answers. An active check lost on process failure is not counted as
completed. A failed dashboard refresh keeps the last data visibly marked stale.

Validation: one focused test checked queue/progress accounting, persistence and
private-error-text removal. A 30-item synthetic check passed through the running
adapter, appeared on the page and survived restart. The 390 px layout had no
horizontal overflow. The production NAS HTTPS page, JSON and log download all
returned 200; subsequent real traffic updated the totals. The active adapter was
restarted with SIGTERM and allowed to finish accepted jobs naturally. Reloading
its monitor arguments happened only after observing no active or queued jobs.
