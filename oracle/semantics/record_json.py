"""Record deterministic Python json.dumps cases for the Dart compatibility gate."""

from __future__ import annotations

import json
import random
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "oracle" / "semantics" / "py_json.jsonl"
SEED = 20260925
COUNT = 10_000
ALPHABET = "abcXYZ09 阿Q𠮷😀\n\t\\\"éΩ"


def string(rng: random.Random) -> str:
    return "".join(rng.choices(ALPHABET, k=rng.randrange(0, 13)))


def finite_double(rng: random.Random) -> float:
    while True:
        value = struct.unpack(">d", rng.getrandbits(64).to_bytes(8, "big"))[0]
        if value == value and abs(value) != float("inf"):
            return value


def value(rng: random.Random, depth: int = 0):
    kind = rng.randrange(8 if depth < 3 else 6)
    if kind == 0:
        return None
    if kind == 1:
        return bool(rng.randrange(2))
    if kind == 2:
        return rng.randrange(-(10**16), 10**16)
    if kind == 3:
        return finite_double(rng)
    if kind == 4:
        return string(rng)
    if kind == 5:
        return rng.choice([0.0, -0.0, 0.1, 1e-5, 1e16, 1e-300, 1e300])
    if kind == 6:
        return [value(rng, depth + 1) for _ in range(rng.randrange(5))]
    return {string(rng): value(rng, depth + 1) for _ in range(rng.randrange(5))}


def records():
    rng = random.Random(SEED)
    for i in range(COUNT):
        item = value(rng)
        options = {
            "ensure_ascii": bool(i & 1),
            "sort_keys": bool(i & 2),
            "compact": bool(i & 4),
        }
        separators = (",", ":") if options["compact"] else None
        expected = json.dumps(
            item,
            ensure_ascii=options["ensure_ascii"],
            sort_keys=options["sort_keys"],
            separators=separators,
        )
        yield {"id": i, "value": item, **options, "expected": expected}


def main() -> None:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8", newline="\n") as output:
        for item in records():
            output.write(json.dumps(item, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"Recorded {COUNT} Python JSON cases at {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
