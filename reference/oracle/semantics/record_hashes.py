"""Freeze Python source-dependent and serialized-value hashes."""

from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "oracle" / "semantics" / "hashes.jsonl"


def cases():
    for i, value in enumerate(("", "hello", "𠮷😀", "阿Q\n第二章", "\x00\xff")):
        raw = value.encode("utf-8")
        yield {"id": f"utf8-{i}", "value": value,
               "sha256": hashlib.sha256(raw).hexdigest()}
    values = [
        {"z": 1, "a": "𠮷😀"},
        ["阿Q", 1e-5, 1e16],
        {"nested": {"one": True, "two": None}},
    ]
    for i, value in enumerate(values):
        for compact in (False, True):
            serialized = json.dumps(value, ensure_ascii=False, sort_keys=True,
                                    separators=(",", ":") if compact else None)
            yield {"id": f"json-{i}-{int(compact)}", "value": value,
                   "compact": compact, "serialized": serialized,
                   "sha256": hashlib.sha256(serialized.encode("utf-8")).hexdigest()}
    source = (ROOT / "pipeline" / "local.py").read_bytes()
    yield {"id": "extractor-revision", "source": "pipeline/local.py",
           "sha256": hashlib.sha256(source).hexdigest()}


def main() -> None:
    if sys.version_info[:2] != (3, 11):
        raise RuntimeError("Python 3.11 is the frozen Android oracle")
    with OUT.open("w", encoding="utf-8", newline="\n") as output:
        for case in cases():
            output.write(json.dumps(case, ensure_ascii=False,
                                    separators=(",", ":")) + "\n")
    print(f"Recorded {sum(1 for _ in OUT.open(encoding='utf-8'))} hash cases")


if __name__ == "__main__":
    main()
