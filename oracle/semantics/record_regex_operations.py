"""Record operation-level Python 3.11 regex answers for paired Dart tests.

The Dart patterns are explicit, reviewed translations for these cases. This
fixture is deliberately smaller than the full regex call-site audit: it covers
operation semantics that simple positive/negative match examples cannot show.
It does not promise a universal pattern translator or exhaustive Unicode
equivalence. The paired Dart file implements only the listed split and
replacement forms; Python bytes patterns, locale/ASCII flags, nested verbose
syntax, and replacement octal escapes are outside this fixture.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / "oracle/semantics/regex_operations.jsonl"
FLAGS = {"S": re.S, "M": re.M, "X": re.X}

# Keep every input, replacement, and translated pattern visible in source
# review. An empty flags list means the default Python re behavior.
CASES = [
    dict(id="named_chinese", topic="named_captures", operation="search",
         python_pattern=r"(?P<title>阿Q)(?P<suffix>正传)", dart_pattern=r"(?<title>阿Q)(?<suffix>正传)",
         input="《阿Q正传》", flags=[]),
    dict(id="named_optional_unmatched", topic="named_captures", operation="search",
         python_pattern=r"(?P<first>A)(?P<second>B)?", dart_pattern=r"(?<first>A)(?<second>B)?",
         input="A", flags=[]),
    dict(id="named_no_match", topic="named_captures", operation="search",
         python_pattern=r"(?P<first>A)(?P<second>B)?", dart_pattern=r"(?<first>A)(?<second>B)?",
         input="Z", flags=[]),
    dict(id="match_prefix", topic="match_vs_search", operation="match",
         python_pattern=r"阿Q", dart_pattern=r"阿Q",
         input="阿Q正传", flags=[]),
    dict(id="match_reject_later_occurrence", topic="match_vs_search", operation="match",
         python_pattern=r"阿Q", dart_pattern=r"阿Q",
         input="读阿Q", flags=[]),
    dict(id="unicode_word_astral_han", topic="unicode_word_boundary", operation="search",
         python_pattern=r"\b(?P<word>\w+)\b",
         dart_pattern=r"(?<![\p{L}\p{N}_])(?<word>[\p{L}\p{N}_]+)(?![\p{L}\p{N}_])",
         input="𠮷阿Q 😀", flags=[], unicode=True),
    dict(id="unicode_word_boundary_reject_inside_han", topic="unicode_word_boundary", operation="search",
         python_pattern=r"\bQ\b",
         dart_pattern=r"(?<![\p{L}\p{N}_])Q(?![\p{L}\p{N}_])",
         input="阿Q", flags=[], unicode=True),
    dict(id="unicode_decimal_digits", topic="unicode_classes", operation="search",
         python_pattern=r"(?P<number>\d+)", dart_pattern=r"(?<number>\p{Nd}+)",
         input="编号٣٤ and 12", flags=[], unicode=True),
    dict(id="unicode_decimal_reject_superscript", topic="unicode_classes", operation="search",
         python_pattern=r"\d", dart_pattern=r"\p{Nd}",
         input="²", flags=[], unicode=True),
    dict(id="unicode_word_accept_superscript", topic="unicode_classes", operation="search",
         python_pattern=r"\w", dart_pattern=r"[\p{L}\p{N}_]",
         input="²", flags=[], unicode=True),
    dict(id="unicode_whitespace", topic="unicode_classes", operation="search",
         python_pattern=r"A(?P<gap>\s+)B", dart_pattern=r"A(?<gap>\s+)B",
         input="A\u00a0\u3000B", flags=[], unicode=True),
    dict(id="dotall_s", topic="flags_S_M_X", operation="search",
         python_pattern=r"前(?P<middle>.*)后", dart_pattern=r"前(?<middle>.*)后",
         input="前\n阿Q\n后", flags=["S"]),
    dict(id="multiline_m", topic="flags_S_M_X", operation="search",
         python_pattern=r"^(?P<heading>第二章)$", dart_pattern=r"^(?<heading>第二章)$",
         input="序\n第二章\n正文", flags=["M"]),
    dict(id="verbose_x", topic="flags_S_M_X", operation="search",
         python_pattern="第 [ ]? (?P<n>[0-9]+) 章  # heading",
         dart_pattern=r"第[ ]?(?<n>[0-9]+)章",
         input="第 12章", flags=["X"]),
    dict(id="fullmatch_success", topic="fullmatch", operation="fullmatch",
         python_pattern=r"(?:a|ab)", dart_pattern=r"(?:a|ab)",
         input="ab", flags=[]),
    dict(id="fullmatch_trailing_newline", topic="fullmatch", operation="fullmatch",
         python_pattern=r"abc", dart_pattern=r"abc",
         input="abc\n", flags=[]),
    dict(id="fullmatch_prefix_only", topic="fullmatch", operation="fullmatch",
         python_pattern=r"abc", dart_pattern=r"abc",
         input="abcd", flags=[]),
    dict(id="split_captured_delimiters", topic="split_captured_groups", operation="split",
         python_pattern=r"([,;])", dart_pattern=r"([,;])",
         input="a,b;c", flags=[], maxsplit=0),
    dict(id="split_optional_group_null", topic="split_captured_groups", operation="split",
         python_pattern=r"([,;])(\s+)?", dart_pattern=r"([,;])(\s+)?",
         input="a,b; c", flags=[], maxsplit=0),
    dict(id="split_maxsplit", topic="split_captured_groups", operation="split",
         python_pattern=r"([,;])", dart_pattern=r"([,;])",
         input="a,b;c", flags=[], maxsplit=1),
    dict(id="split_zero_width", topic="split_captured_groups", operation="split",
         python_pattern=r"(?=,)", dart_pattern=r"(?=,)",
         input="a,b,c", flags=[], maxsplit=0),
    dict(id="sub_named_expansion", topic="sub_replacement", operation="sub",
         python_pattern=r"(?P<last>[A-Za-z]+), (?P<first>[A-Za-z]+)",
         dart_pattern=r"(?<last>[A-Za-z]+), (?<first>[A-Za-z]+)",
         input="Doe, Jane; Li, Wei", flags=[],
         replacement=r"\g<first> \g<last>", count=0),
    dict(id="sub_numbered_expansion_count", topic="sub_replacement", operation="sub",
         python_pattern=r"([A-Z])-([0-9])", dart_pattern=r"([A-Z])-([0-9])",
         input="A-1 B-2", flags=[], replacement=r"\2:\1", count=1),
    dict(id="sub_whole_match_escape_newline", topic="sub_replacement", operation="sub",
         python_pattern=r"([A-Za-z]+)", dart_pattern=r"([A-Za-z]+)",
         input="abc", flags=[], replacement=r"[\g<0>]\n\\", count=0),
    dict(id="span_astral_prefix", topic="span_codepoint_utf16", operation="search",
         python_pattern=r"(?P<han>阿)", dart_pattern=r"(?<han>阿)",
         input="𠮷😀阿Q", flags=[], unicode=True),
    dict(id="span_astral_match", topic="span_codepoint_utf16", operation="search",
         python_pattern=r"(?P<emoji>😀)", dart_pattern=r"(?<emoji>😀)",
         input="阿😀Q", flags=[], unicode=True),
]


def encode_match(match: re.Match[str] | None, source: str) -> dict:
    if match is None:
        return {"matched": False}
    start, end = match.span()
    utf16 = lambda text: len(text.encode("utf-16-le")) // 2
    return {
        "matched": True,
        "text": match.group(0),
        "groups": list(match.groups()),
        "named": match.groupdict(),
        "span_cp": [start, end],
        "span_utf16": [utf16(source[:start]), utf16(source[:end])],
    }


def record() -> list[dict]:
    if sys.version_info[:2] != (3, 11):
        raise RuntimeError("This frozen oracle must be recorded and checked with Python 3.11")
    if len(CASES) != len({case["id"] for case in CASES}):
        raise ValueError("Duplicate regex operation case ID")
    rows = []
    for case in CASES:
        flags = sum(FLAGS[name] for name in case["flags"])
        compiled = re.compile(case["python_pattern"], flags)
        operation = case["operation"]
        if operation in {"search", "match", "fullmatch"}:
            expected = encode_match(getattr(compiled, operation)(case["input"]), case["input"])
        elif operation == "split":
            expected = {"parts": compiled.split(case["input"], maxsplit=case["maxsplit"])}
        elif operation == "sub":
            output, count = compiled.subn(case["replacement"], case["input"], count=case["count"])
            expected = {"output": output, "replacements": count}
        else:
            raise ValueError(f"Unknown operation: {operation}")
        rows.append({"schema": 1, **case, "expected": expected})
    return rows


def render() -> str:
    return "".join(json.dumps(row, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n"
                   for row in record())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="record the pinned JSONL fixture")
    mode.add_argument("--check", action="store_true", help="compare the fixture to Python 3.11")
    args = parser.parse_args()
    expected = render()
    if args.write:
        FIXTURE.write_text(expected, encoding="utf-8")
    elif FIXTURE.read_text(encoding="utf-8") != expected:
        raise ValueError("Regex operation fixture differs from the Python 3.11 oracle")
    print(f"Verified {len(CASES)} operation-level regex cases against Python 3.11")


if __name__ == "__main__":
    main()
