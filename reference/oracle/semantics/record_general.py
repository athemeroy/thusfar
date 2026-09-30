"""Freeze non-JSON Python 3.11 semantics for the Dart compatibility gate."""

from __future__ import annotations

import json
import random
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "oracle" / "semantics" / "general.jsonl"


def evaluate(op: str, args: list):
    if op == "code_point_length":
        return len(args[0])
    if op == "utf16_length":
        return len(args[0].encode("utf-16-le")) // 2
    if op == "utf16_offset":
        return len(args[0][:args[1]].encode("utf-16-le")) // 2
    if op == "utf16_prefix":
        return args[0].encode("utf-16-le")[:args[1] * 2].decode("utf-16-le", errors="ignore")
    if op == "slice":
        return args[0][args[1]:args[2]]
    if op == "strip":
        return args[0].strip(args[1])
    if op == "split":
        return args[0].split(args[1])
    if op == "isdigit":
        return args[0].isdigit()
    if op == "casefold":
        return args[0].casefold()
    if op == "title":
        return args[0].title()
    if op == "floor_div":
        return args[0] // args[1]
    if op == "modulo":
        return args[0] % args[1]
    if op == "truncate":
        return int(args[0])
    if op == "round":
        return round(args[0])
    if op == "round_digits":
        return round(args[0], args[1])
    if op == "compare":
        a, b = args
        return (a > b) - (a < b)
    if op == "stable_sort":
        return sorted(args[0], key=lambda row: tuple(row[0]))
    if op == "ordered_map":
        ordered = {}
        for key, value in args[0]:
            ordered[key] = value
        return [[key, value] for key, value in ordered.items()]
    raise ValueError(f"Unknown operation {op}")


def cases():
    number = 0

    def add(op, *args):
        nonlocal number
        expected = evaluate(op, list(args))
        case = {"id": number, "op": op, "args": args, "expected": expected}
        number += 1
        return case

    for text in ("", "A", "A𠮷😀B", "𠮷😀", "a\u0301", "　A "):
        yield add("code_point_length", text)
        yield add("utf16_length", text)
        for at in range(len(text) + 1):
            yield add("utf16_offset", text, at)
        for units in range(len(text.encode("utf-16-le")) // 2 + 1):
            yield add("utf16_prefix", text, units)
        for start, end in ((None, None), (1, 3), (-3, -1), (-50, 50), (3, 1)):
            yield add("slice", text, start, end)

    for text in (" \t 　𠮷😀　\r\n", "\u200b hi \u200b", "", "a  b\t\nc", "　"):
        yield add("strip", text, None)
        yield add("split", text, None)
    for text, chars in (("abcab", "ab"), ("𠮷x𠮷", "𠮷"), (" a ", ""), (" 书 ", " ")):
        yield add("strip", text, chars)
    for text, separator in (("a,,b", ","), ("", ","), ("a𠮷b𠮷", "𠮷")):
        yield add("split", text, separator)

    for text in ("", "123", "١٢", "²", "𝟠", "四", "Ⅵ", "1²", " 1"):
        yield add("isdigit", text)
    for text in ("Straße", "ΟΣ", "İ", "ẞ", "𐐀", "they're", "ǅIG"):
        yield add("casefold", text)
        yield add("title", text)
    for code in range(sys.maxunicode + 1):
        char = chr(code)
        if char.casefold() != char:
            yield add("casefold", char)
        if char.title() != char:
            yield add("title", char)
        if char.isdigit():
            yield add("isdigit", char)
    rng = random.Random(20260925)
    for _ in range(1500):
        char = chr(rng.randrange(sys.maxunicode + 1))
        if 0xD800 <= ord(char) <= 0xDFFF:
            continue
        yield add("isdigit", char)
        if rng.randrange(5) == 0:
            yield add("title", char + rng.choice("Σaǅ𠮷😀"))
    for text in ("ΟΣ", "ΑΣΣ", "ΑΣΑ", "i\u0307stanbul", "they're", "ßa"):
        yield add("title", text)

    for a, b in ((7, 3), (-7, 3), (7, -3), (-7, -3), (0, -3), (-1, 2)):
        yield add("floor_div", a, b)
        yield add("modulo", a, b)
    for value in (-3.9, -0.9, 0.0, 2.9, 1e12):
        yield add("truncate", value)
    for value in (-3.5, -2.5, -1.5, 0.5, 1.5, 2.5, 3.5, 4.4):
        yield add("round", value)
    for value, digits in ((2.675, 2), (1.005, 2), (-1.225, 2),
                          (12.5, 0), (125.0, -1), (-125.0, -1),
                          (1e-5, 5), (12345.678, -2)):
        yield add("round_digits", value, digits)

    for a, b in ((1, 2), ("𠮷", "\ue000"), ([1, "a"], [1, "b"]),
                 ([2, 0], [1, 100]), (True, 1), ([1], [1, 0])):
        yield add("compare", a, b)
    yield add("stable_sort", [[[2, "b"], "first"], [[1, "c"], "low"],
                              [[2, "b"], "second"], [[1, "a"], "first-key"]])
    yield add("ordered_map", [["b", 1], ["a", 2], ["b", 3], ["𠮷", 4]])


def main() -> None:
    if sys.version_info[:2] != (3, 11):
        raise RuntimeError("Python 3.11 is the frozen Android oracle")
    with OUT.open("w", encoding="utf-8", newline="\n") as output:
        for case in cases():
            output.write(json.dumps(case, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"Recorded {sum(1 for _ in OUT.open(encoding='utf-8'))} general cases")


if __name__ == "__main__":
    main()
