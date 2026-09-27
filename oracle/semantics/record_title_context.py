"""Freeze Python 3.11 Unicode Final_Sigma behavior in str.title()."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


OUT = Path(__file__).with_name("title_context.jsonl")
PREFIXES = ("", "Α", "İ", "\u0345", "A\u0345", "A\u0301", "A!")
SIGMAS = ("Σ", "ΣΣ")
SEPARATORS = ("", "\u0301", "\u0345", "\u2019", "\u200d", "!", "\u200b")
SUFFIXES = ("", "Α", "a", "\u0345")


def cases():
    seen = set()
    for prefix in PREFIXES:
        for sigmas in SIGMAS:
            for separator in SEPARATORS:
                for suffix in SUFFIXES:
                    source = prefix + sigmas + separator + suffix
                    if source not in seen:
                        seen.add(source)
                        yield {"id": len(seen) - 1, "source": source,
                               "expected": source.title()}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if sys.version_info[:2] != (3, 11):
        raise RuntimeError("Python 3.11 is the frozen Android oracle")
    data = "".join(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n"
                   for row in cases())
    if args.check:
        if OUT.read_text(encoding="utf-8") != data:
            raise RuntimeError("title context fixture drifted")
    else:
        OUT.write_text(data, encoding="utf-8", newline="\n")
    print(f"{len(list(cases()))} Python title context cases")


if __name__ == "__main__":
    main()
