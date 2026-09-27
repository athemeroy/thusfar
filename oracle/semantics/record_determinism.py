"""Record retry timing under injected Python time and random sources."""

from __future__ import annotations

import json
from email.utils import formatdate
from pathlib import Path
from unittest.mock import patch

from pipeline import llm


ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "oracle" / "semantics" / "determinism.jsonl"
NOW = 1_750_000_000
CASES = (
    {"id": "numeric-hint", "header": "2", "attempt": 0, "cap": 10.0,
     "jitter": 0.25},
    {"id": "blind-backoff", "header": None, "attempt": 2, "cap": 10.0,
     "jitter": 0.25},
    {"id": "http-date", "header": formatdate(NOW + 5, usegmt=True),
     "attempt": 0, "cap": 10.0, "jitter": 0.25},
    {"id": "over-cap", "header": "3600", "attempt": 0, "cap": 10.0,
     "jitter": 0.25},
)


def evaluate(case: dict):
    headers = {"Retry-After": case["header"]} if case["header"] else {}
    with patch.object(llm.time, "time", return_value=NOW), \
            patch.object(llm.random, "random", return_value=case["jitter"]), \
            patch.dict(llm.os.environ, {"JEV_BLIND_WAIT": "8"}):
        return llm._retry_after(headers, case["attempt"], cap=case["cap"])


def main() -> None:
    with OUT.open("w", encoding="utf-8", newline="\n") as output:
        for case in CASES:
            output.write(json.dumps({**case, "now": NOW, "expected": evaluate(case)},
                                    ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"Recorded {len(CASES)} injected retry cases")


if __name__ == "__main__":
    main()
