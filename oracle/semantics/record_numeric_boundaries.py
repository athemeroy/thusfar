"""Freeze Python 3.11 integer-width and non-total float comparisons."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


OUT = Path(__file__).with_name("numeric_boundaries.jsonl")


def value(kind: str, text: str):
    return float(text) if kind == "float" else int(text)


def cases():
    rows = []
    for operation in ("round", "truncate"):
        for raw in ("0.5", "1.5", "2.5", "-0.5", "-1.5", "-2.5",
                    "1e20", "-1e20", "1e308", "-1e308",
                    "9.223372036854776e18", "-9.223372036854776e18",
                    "5e-324", "NaN", "Infinity", "-Infinity"):
            rows.append({"op": operation, "value": raw})
    for left, right in (("-0.0", "0.0"), ("0.0", "-0.0"),
                        ("NaN", "1.0"), ("1.0", "NaN"),
                        ("Infinity", "1.0"), ("-Infinity", "1.0")):
        rows.append({"op": "compare", "left": ["float", left],
                     "right": ["float", right]})
    for left, right in (("9223372036854775807", "9.223372036854776e18"),
                        ("-9223372036854775808", "-9.223372036854776e18"),
                        ("100000000000000000000", "1e20"),
                        ("100000000000000000001", "1e20")):
        rows.append({"op": "compare", "left": ["int", left],
                     "right": ["float", right]})
        rows.append({"op": "compare", "left": ["float", right],
                     "right": ["int", left]})
    for operation in ("floor_div", "modulo"):
        for left, right in (("-9223372036854775808", "-1"),
                            ("-9223372036854775808", "3"),
                            ("9223372036854775807", "-3"),
                            ("9223372036854775808", "3"),
                            ("100000000000000000000", "9223372036854775808")):
            rows.append({"op": operation, "left": left, "right": right})
    rows.append({"op": "round_floor_div", "value": "1e20", "right": "3"})
    for raw in ("9223372036854775808", "-9223372036854775809",
                "100000000000000000000"):
        rows.append({"op": "json_int", "value": raw})
    rows.append({"op": "json_bool_keys"})
    rows.append({"op": "sort_signed_zero"})
    for number, row in enumerate(rows):
        row["id"] = number
        operation = row["op"]
        try:
            if operation in ("round", "truncate"):
                actual = round(float(row["value"])) if operation == "round" else int(float(row["value"]))
                row["expected"] = str(actual)
            elif operation == "compare":
                left = value(*row["left"])
                right = value(*row["right"])
                row["expected"] = (left > right) - (left < right)
            elif operation == "floor_div":
                row["expected"] = str(int(row["left"]) // int(row["right"]))
            elif operation == "modulo":
                row["expected"] = str(int(row["left"]) % int(row["right"]))
            elif operation == "round_floor_div":
                row["expected"] = str(round(float(row["value"])) // int(row["right"]))
            elif operation == "json_int":
                row["expected"] = json.dumps(int(row["value"]))
            elif operation == "json_bool_keys":
                row["expected"] = json.dumps({True: "yes", False: "no"}, sort_keys=True)
            else:
                sorted_values = sorted([0.0, -0.0])
                row["expected"] = ["-0" if str(x).startswith("-") else "+0"
                                   for x in sorted_values]
        except (ValueError, OverflowError) as exc:
            row["error"] = type(exc).__name__
        yield row


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
            raise RuntimeError("numeric boundary fixture drifted")
    else:
        OUT.write_text(data, encoding="utf-8", newline="\n")
    print(f"{len(list(cases()))} Python numeric boundary cases")


if __name__ == "__main__":
    main()
