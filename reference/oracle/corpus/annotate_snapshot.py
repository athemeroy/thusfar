"""Create a reproducible annotated 阿Q data directory through the 1.7.5 HTTP API.

The note text is fixture-authored. Its notebook.json is written by the real
server.app.Handler PUT route against a temporary copy of aq_complete. The
clock is fixed to make the byte-level fixture reproducible. No model runs.
"""

from __future__ import annotations

import argparse
import hashlib
import http.client
import json
import os
import shutil
import sys
import tempfile
import threading
from contextlib import ExitStack
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]
SOURCE = ROOT / "snapshots/aq_complete"
TARGET = ROOT / "snapshots/aq_annotated"
BOOK_ID = "e3f53d01f830aedf"
STAMP = 1_790_294_400.0  # 2026-09-25 00:00:00 UTC
PINNED_CODE_SHA256 = {
    "server/app.py": "5b72f432a8de6ed331ce92566e14ce5f08b681cd7102776fa24cc5581b72725f",
    "server/notebook.py": "749746c0ff8f59e6a9fabe14bfe9e9a0085ef47a2e64040f1854ba03dd18210b",
    "server/storage.py": "92bc6248771fdeb69195bd05ec549862df06a3476f4c212154c8b12f34644283",
    "server/jobs.py": "0f51c97fd0b3303c801937a5ada77c7c5de4481e3c570b361867e2cae24b4671",
}


def files(directory: Path) -> dict[str, bytes]:
    return {
        str(path.relative_to(directory)): path.read_bytes()
        for path in sorted(directory.rglob("*")) if path.is_file()
    }


def request(port: int, method: str, path: str, body: dict | None = None) -> tuple[int, dict]:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    payload = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
    headers = {} if body is None else {"Content-Type": "application/json; charset=utf-8"}
    try:
        conn.request(method, path, body=payload, headers=headers)
        response = conn.getresponse()
        raw = response.read()
        return response.status, json.loads(raw)
    finally:
        conn.close()


def generate(temp: Path) -> Path:
    for name, expected in PINNED_CODE_SHA256.items():
        actual = hashlib.sha256((REPO / name).read_bytes()).hexdigest()
        if actual != expected:
            raise ValueError(f"The pinned Python 1.7.5 API code changed: {name}")
    if not (SOURCE / "book.json").is_file() or (SOURCE / "notebook.json").exists():
        raise ValueError("The public-domain base snapshot is missing or contains private notes")
    book_root = temp / "books" / BOOK_ID
    shutil.copytree(SOURCE, book_root)
    book = json.loads((book_root / "book.json").read_text(encoding="utf-8"))
    block = next(b for b in book["blocks"] if b["k"] == "p" and "阿Q" in b["t"] and len(b["t"]) > 30)
    quote = block["t"][:18]
    start = block["o"]
    end = start + len(quote.encode("utf-16-le")) // 2
    note = {
        "id": "fixture-aq-api-note-0001", "kind": "note", "start": start,
        "end": end, "quote": quote, "text": "重读时留意这一句。",
        "knowledge_cutoff": end, "operation": "fixture-aq-api-op-0001",
        "expected_revision": 0,
    }

    sys.path.insert(0, str(REPO))
    from server import app, jobs, notebook, storage

    if app.RELEASE != "1.7.5":
        raise ValueError(f"Expected Python 1.7.5 API, found {app.RELEASE}")
    web = temp / "web"
    web.mkdir()
    values = {
        "DATA": temp, "BOOKS": temp / "books", "WEB": web, "PASSCODE": "",
        "SECRET_FILE": temp / ".cookie-secret", "COOKIE_SECURE": False,
        "_cache": storage.JsonCache(), "_pos_cache": app.OrderedDict(),
        "_login_attempts": app.OrderedDict(),
        "WORKER": jobs.Worker(temp / "books", app.APP, app.cached_json, app.wjson, enabled=False),
    }
    with ExitStack() as stack:
        for name, value in values.items():
            stack.enter_context(patch.object(app, name, value))
        stack.enter_context(patch.object(notebook, "time", SimpleNamespace(time=lambda: STAMP)))
        server = app.BoundedHTTPServer(("127.0.0.1", 0), app.Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            route = f"/api/books/{BOOK_ID}/notebook"
            health_code, health = request(server.server_port, "GET", "/healthz")
            if health_code != 200 or health.get("release") != "1.7.5":
                raise ValueError("The isolated 1.7.5 API did not start cleanly")
            status, reply = request(server.server_port, "PUT", route, note)
            if status != 200:
                raise ValueError(f"1.7.5 notebook PUT failed: HTTP {status}, {reply}")
            status, reread = request(server.server_port, "GET", route)
            if status != 200 or reread != {"items": [reply["item"]]}:
                raise ValueError("1.7.5 notebook GET differs from the accepted write")
            if reply["item"]["quote"] != notebook.source_quote(book, start, end):
                raise ValueError("The API note lost its source-exact UTF-16 anchor")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

    saved = json.loads((book_root / "notebook.json").read_text(encoding="utf-8"))
    if saved != reread["items"] or saved[0]["created"] != STAMP:
        raise ValueError("The API did not persist the deterministic note")
    if set(files(book_root)) != set(files(SOURCE)) | {"notebook.json"}:
        raise ValueError("The annotated snapshot has unexpected files")
    for name, raw in files(SOURCE).items():
        if (book_root / name).read_bytes() != raw:
            raise ValueError(f"The 1.7.x base snapshot changed: {name}")
    return book_root


def verify() -> None:
    with tempfile.TemporaryDirectory(prefix="thusfar-aq-api-note-") as scratch:
        expected = files(generate(Path(scratch)))
    actual = files(TARGET)
    if expected != actual:
        missing = sorted(expected.keys() - actual.keys())
        extra = sorted(actual.keys() - expected.keys())
        changed = sorted(k for k in expected.keys() & actual.keys() if expected[k] != actual[k])
        raise ValueError(f"Annotated snapshot differs from 1.7.5 API: missing={missing}, extra={extra}, changed={changed}")
    print(f"Verified annotated 阿Q snapshot: {len(actual)} files, 1 API-written note")


def write(*, force: bool = False) -> None:
    with tempfile.TemporaryDirectory(prefix="thusfar-aq-api-note-") as scratch:
        generated = generate(Path(scratch))
        if TARGET.exists():
            if files(generated) == files(TARGET):
                return
            if not force:
                raise ValueError("Annotated fixture changed; review then use --force to replace it")
        with tempfile.TemporaryDirectory(prefix=".thusfar-annotated-stage-", dir=ROOT.parent) as stage_root:
            staged = Path(stage_root) / "snapshot"
            backup = Path(stage_root) / "backup"
            shutil.copytree(generated, staged)
            had_target = TARGET.exists()
            if had_target:
                os.replace(TARGET, backup)
            try:
                os.replace(staged, TARGET)
                if files(TARGET) != files(generated):
                    raise ValueError("Annotated snapshot changed during publication")
            except Exception:
                if TARGET.exists():
                    shutil.rmtree(TARGET)
                if had_target:
                    os.replace(backup, TARGET)
                raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify", action="store_true", help="replay the local 1.7.5 API and compare every byte")
    parser.add_argument("--write", action="store_true", help="create the API-generated snapshot")
    parser.add_argument("--force", action="store_true", help="replace a changed snapshot after review")
    args = parser.parse_args()
    if args.verify == args.write:
        parser.error("choose exactly one of --verify or --write")
    if args.verify:
        verify()
    else:
        write(force=args.force)
        verify()


if __name__ == "__main__":
    main()
