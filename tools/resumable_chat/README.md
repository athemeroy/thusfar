# Retained local chat results

This optional personal relay lets an accepted book-processing completion finish
on Qwen even if the phone loses its connection. It accepts authenticated
`POST /v1/chat/completions` with `Prefer: respond-async`, returns 202 with a
same-origin Location, and keeps the full upstream SSE response on private NAS
storage. Authenticated GET returns 202 while running, or a JSON envelope with
`status`, `content_type`, and `body`. A completed upstream error is retained too;
GET never creates another model call. Completed results survive relay restarts;
unfinished jobs return 410 after restart. Only the last 256 results are retained.
Request bodies are not written to disk. Saved results may contain book content.

The app requests this only inside a book-processing request scope. Providers
that return their usual 200 response continue streaming as before. Interactive
chat does not opt in. Polling can recover a lost response body by reading the
same saved result again; the initial inference POST is never automatically
replayed after an uncertain submission. Expired results, lost initial acceptance
and app process death still require the existing manual recovery.

Deployment uses the existing NAS Traefik network without opening another host
port. The gateway sends only explicit async POSTs and result GETs to this relay;
normal requests continue directly to Qwen. Mount the existing private API key
as `/private/api-key`; never include it in source. Run the included compose file
from the runtime directory after copying both `tools/resumable_chat` and
`tools/systemone/async_jobs.py`. The model and Qwen settings remain unchanged.
