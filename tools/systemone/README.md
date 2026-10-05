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
