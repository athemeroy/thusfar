"""Record Python 3.11 float round(value, digits) across exponent limits."""

from __future__ import annotations

import json
import math
import random
import struct
import sys
from pathlib import Path


OUT = Path(__file__).with_name("round_extremes.jsonl")
DIGITS = (-1000, -309, -308, -307, -100, -2, -1, 0, 1, 2, 15,
          100, 307, 308, 309, 323, 324, 1000)
VALUES = (1.2345, -1.2345, 1e308, -1e308, 5e-324, -5e-324,
          2.675, -2.675, 1.7976931348623157e308, -1.7976931348623157e308)


def cases():
    pairs = [(value, digits) for value in VALUES for digits in DIGITS]
    rng = random.Random(20260926)
    while len(pairs) < 700:
        value = struct.unpack("!d", rng.randbytes(8))[0]
        if math.isfinite(value):
            pairs.append((value, rng.choice(DIGITS)))
    for index, (value, digits) in enumerate(pairs):
        row = {"id": index, "value": value, "digits": digits}
        try:
            expected = round(value, digits)
        except OverflowError:
            row["error"] = "OverflowError"
        else:
            row["expected"] = expected
            row["negative_zero"] = expected == 0.0 and math.copysign(1.0, expected) < 0
        yield row


def main() -> None:
    if sys.version_info[:2] != (3, 11):
        raise RuntimeError("Python 3.11 is the frozen Android oracle")
    with OUT.open("w", encoding="utf-8", newline="\n") as output:
        for case in cases():
            output.write(json.dumps(case, separators=(",", ":")) + "\n")
    print(f"Recorded {sum(1 for _ in OUT.open(encoding='utf-8'))} round extremes")


if __name__ == "__main__":
    main()
