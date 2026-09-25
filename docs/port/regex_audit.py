#!/usr/bin/env python3
"""Record every Python re call and a reproducible sample for static patterns."""

from __future__ import annotations

import argparse
import ast
from collections import Counter
import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "docs/port/REGEX.json"
REPORT = ROOT / "docs/port/REGEX.md"
MATCH_METHODS = {"match", "fullmatch", "search", "findall", "finditer", "split", "sub", "subn"}
FLAGS = {"I": re.I, "IGNORECASE": re.I, "M": re.M, "MULTILINE": re.M, "S": re.S, "DOTALL": re.S, "X": re.X, "VERBOSE": re.X, "A": re.A, "ASCII": re.A, "U": re.U, "UNICODE": re.U}
SEEDS = (
    "阿Q", "人", "他", "她", "甲", "你好", "阿Q正传", "赵太爷", "先生", "太太", "夫妇", "两人",
    "a", "A", "abc", "John", "Mr. Smith", "the old man", "father", "wife", "1", "12", "123", "12345678",
    "abcdef12", "a_b-9", "foo.bar", "file.jpg", "example.com", "1e-05", "HTTP 401: bad key",
    "第一章", "第二回", "第1章", "一", "序", "序章", "はしがき", "あとがき", "第一章 标题",
    "CHAPTER I", "Chapter 1", "PART TWO", "III.", "Title: Sample", "Author: Name",
    "*** START OF THE PROJECT GUTENBERG EBOOK ***", "*** END OF THE PROJECT GUTENBERG EBOOK ***",
    " 文字 ", " ", "\t", "\n", "a\n\nb", "[1]", "[注1]", "（1）", "†", "“你好”", '"hello"',
    "```json\n{}\n```", "<h1>", "<p>", "<chapter>text</chapter>", "display:none", "</script>",
    "/api/books/abc123", "/chapters/12", "/img/cover.jpg", "yedu=v1.123456.abcdef0123456789abcdef01." + "a" * 64,
    "Markdown", "JSON", "系统提示", "抱歉", "foo,}", "hello。world！", "x=y", "foo bar", "中,", "a" * 64,
)
NEGATIVE_SEEDS = ("☃", "🚫", "", "a", "1", "中", " ", "#", "\x00", "!", "not a match", "ZZZZ")


def source(text: str, node: ast.AST | None) -> str | None:
    return ast.get_source_segment(text, node) if node is not None else None


def dotted(node: ast.AST) -> str | None:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        head = dotted(node.value)
        return f"{head}.{node.attr}" if head else None
    return None


def safe_value(node: ast.AST, env: dict[str, object]) -> object:
    if isinstance(node, ast.Constant) and isinstance(node.value, (str, bytes, int)):
        return node.value
    if isinstance(node, ast.Name) and node.id in env:
        return env[node.id]
    if isinstance(node, ast.Attribute) and isinstance(node.value, ast.Name) and node.value.id == "re" and node.attr in FLAGS:
        return FLAGS[node.attr]
    if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Add, ast.BitOr)):
        a, b = safe_value(node.left, env), safe_value(node.right, env)
        return a + b if isinstance(node.op, ast.Add) else a | b
    if isinstance(node, ast.JoinedStr):
        parts: list[str] = []
        for item in node.values:
            if isinstance(item, ast.FormattedValue):
                value = safe_value(item.value, env)
                if item.format_spec is not None or not isinstance(value, (str, int)):
                    raise ValueError("dynamic f-string")
                parts.append(str(value))
            else:
                value = safe_value(item, env)
                if not isinstance(value, str):
                    raise ValueError("non-string f-string part")
                parts.append(value)
        return "".join(parts)
    if isinstance(node, ast.Dict):
        return {safe_value(k, env): safe_value(v, env) for k, v in zip(node.keys, node.values) if k is not None}
    raise ValueError("dynamic expression")


def constant_env(tree: ast.Module) -> dict[str, object]:
    env: dict[str, object] = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            try:
                env[node.targets[0].id] = safe_value(node.value, env)
            except (ValueError, TypeError, KeyError):
                pass
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name) and node.value is not None:
            try:
                env[node.target.id] = safe_value(node.value, env)
            except (ValueError, TypeError, KeyError):
                pass
    return env


def flag_names(value: int) -> list[str]:
    return [name for name, bit in (("I", re.I), ("M", re.M), ("S", re.S), ("X", re.X), ("A", re.A)) if value & bit]


def dart_form(pattern: str, flags: int) -> dict:
    ascii_mode = bool(flags & re.A)
    word_body = r"A-Za-z0-9_" if ascii_mode else r"\p{L}\p{N}_"
    word = f"[{word_body}]"
    boundary = rf"(?:(?<!{word})(?={word})|(?<={word})(?!{word}))"
    space_body = r"\u0009-\u000D\u0020" if ascii_mode else r"\u0009-\u000D\u001C-\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000"
    converted: list[str] = []
    inside_class = False
    i = 0
    while i < len(pattern):
        ch = pattern[i]
        if ch == "\\" and i + 1 < len(pattern):
            code = pattern[i + 1]
            if code == "b" and not inside_class and not ascii_mode:
                converted.append(boundary)
            elif code == "w" and not ascii_mode:
                converted.append(word_body if inside_class else word)
            elif code == "W" and not ascii_mode and not inside_class:
                converted.append(f"[^{word_body}]")
            elif code == "d" and not ascii_mode:
                converted.append(r"\p{Nd}")
            elif code == "D" and not ascii_mode:
                converted.append(r"\P{Nd}")
            elif code == "s":
                converted.append(space_body if inside_class else f"[{space_body}]")
            elif code == "S" and not inside_class:
                converted.append(f"[^{space_body}]")
            elif code == "Z" and not inside_class:
                converted.append(r"(?![\s\S])")
            elif code in {"'", '"'}:
                converted.append(code)
            else:
                converted.append("\\" + code)
            i += 2
            continue
        if ch == "[" and not inside_class:
            inside_class = True
        elif ch == "]" and inside_class:
            inside_class = False
        converted.append(ch)
        i += 1
    translated = "".join(converted).replace("(?P<", "(?<")
    inline = re.match(r"^\(\?([ims]+)\)", translated)
    if inline:
        modes = inline.group(1)
        flags |= sum({"i": re.I, "m": re.M, "s": re.S}[ch] for ch in modes)
        translated = translated[inline.end():]
    return {
        "pattern": translated,
        "case_sensitive": not bool(flags & re.I),
        "multi_line": bool(flags & re.M),
        "dot_all": bool(flags & re.S),
        "unicode": True,
        "translation": [name for name, active in (("named groups", "(?P<" in pattern), ("absolute end", r"\Z" in pattern), ("identity quote escapes", "\\'" in pattern or '\\"' in pattern), ("Python Unicode word class/boundary", not ascii_mode and any(escape in pattern for escape in (r"\w", r"\W", r"\b"))), ("Python decimal digits", not ascii_mode and any(escape in pattern for escape in (r"\d", r"\D"))), ("Python whitespace", any(escape in pattern for escape in (r"\s", r"\S"))), ("inline flags", inline is not None)) if active],
    }


def sample_char(items: list[tuple[object, object]]) -> str:
    import re._constants as c

    if items and items[0][0] == c.NEGATE:
        options = ("q", "Q", "0", "中", " ", "!", "\n")
        body = items[1:]
        for candidate in options:
            if not any((op == c.LITERAL and chr(value) == candidate) or (op == c.RANGE and chr(value[0]) <= candidate <= chr(value[1])) or (op == c.CATEGORY and ((value == c.CATEGORY_DIGIT and candidate.isdigit()) or (value == c.CATEGORY_SPACE and candidate.isspace()) or (value == c.CATEGORY_WORD and (candidate.isalnum() or candidate == "_")))) for op, value in body):
                return candidate
        return "q"
    for op, value in items:
        if op == c.LITERAL:
            return chr(value)
        if op == c.RANGE:
            return chr(value[0])
        if op == c.CATEGORY:
            return category_char(value)
    return "a"


def category_char(value: object) -> str:
    import re._constants as c

    return {c.CATEGORY_DIGIT: "3", c.CATEGORY_NOT_DIGIT: "a", c.CATEGORY_SPACE: " ", c.CATEGORY_NOT_SPACE: "a", c.CATEGORY_WORD: "a", c.CATEGORY_NOT_WORD: "!", c.CATEGORY_LINEBREAK: "\n", c.CATEGORY_NOT_LINEBREAK: "a"}.get(value, "a")


def synthesize(pattern: str, flags: int) -> str:
    import re._constants as c
    import re._parser as parser

    groups: dict[int, str] = {}

    def build(tokens: object, depth: int = 0) -> str:
        if depth > 20:
            return ""
        out = ""
        for op, value in tokens:
            if op == c.LITERAL:
                out += chr(value)
            elif op == c.NOT_LITERAL:
                out += "q" if value != ord("q") else "x"
            elif op == c.ANY:
                out += "x"
            elif op == c.IN:
                out += sample_char(value)
            elif op == c.CATEGORY:
                out += category_char(value)
            elif op == c.SUBPATTERN:
                group, _, _, sub = value
                part = build(sub, depth + 1)
                if group:
                    groups[group] = part
                out += part
            elif op == c.BRANCH:
                _, branches = value
                out += build(branches[0], depth + 1)
            elif op in (c.MAX_REPEAT, c.MIN_REPEAT, c.POSSESSIVE_REPEAT):
                minimum, maximum, sub = value
                count = max(minimum, 1) if maximum else 0
                out += build(sub, depth + 1) * min(count, 4)
            elif op == c.GROUPREF:
                out += groups.get(value, "")
            elif op == c.GROUPREF_EXISTS:
                _, yes, no = value
                out += build(yes or no, depth + 1)
        return out

    return build(parser.parse(pattern, flags))


def matches(pattern: str | bytes, flags: int, mode: str, text: str) -> bool:
    probe = text.encode("latin1") if isinstance(pattern, bytes) else text
    regex = re.compile(pattern, flags)
    fn = regex.fullmatch if mode == "fullmatch" else regex.match if mode == "match" else regex.search
    return fn(probe) is not None


def choose_examples(pattern: str | bytes, flags: int, mode: str) -> dict:
    readable = pattern.decode("latin1") if isinstance(pattern, bytes) else pattern
    choices = (*SEEDS, synthesize(readable, flags))
    positive = next((s for s in choices if (not isinstance(pattern, bytes) or all(ord(ch) < 256 for ch in s)) and matches(pattern, flags, mode, s)), None)
    negative = next((s for s in NEGATIVE_SEEDS if (not isinstance(pattern, bytes) or all(ord(ch) < 256 for ch in s)) and not matches(pattern, flags, mode, s)), None)
    return {"positive": positive, "negative": negative, "mode": mode}


class Scanner(ast.NodeVisitor):
    def __init__(self, path: Path, text: str, tree: ast.Module) -> None:
        self.path = path
        self.text = text
        self.env = constant_env(tree)
        self.scope: list[str] = []
        self.calls: list[dict] = []
        self.bindings: dict[tuple[str, str], list[tuple[int, str]]] = {}
        self.assignments: dict[tuple[str, str], list[tuple[int, str]]] = {}
        self.imports: dict[str, str] = {}
        module = ".".join(path.relative_to(ROOT).with_suffix("").parts)
        package = module.split(".")[:-1]
        for node in tree.body:
            if not isinstance(node, ast.ImportFrom):
                continue
            parent = ".".join(package[: len(package) - node.level + 1] + ([node.module] if node.module else [])) if node.level else node.module or ""
            for name in node.names:
                self.imports[name.asname or name.name] = f"{parent}.{name.name}"

    def scope_name(self) -> str:
        return ".".join(self.scope)

    def _remember(self, node: ast.Assign | ast.AnnAssign, target: ast.AST, value: ast.AST) -> None:
        if not isinstance(target, ast.Name):
            return
        name = target.id
        key = (self.scope_name(), name)
        self.assignments.setdefault(key, []).append((node.lineno, source(self.text, value) or ""))
        if isinstance(value, ast.Call) and dotted(value.func) == "re.compile":
            self.bindings.setdefault(key, []).append((node.lineno, self.site_id(value, "compile")))

    def visit_Assign(self, node: ast.Assign) -> None:
        for target in node.targets:
            self._remember(node, target, node.value)
        self.generic_visit(node)

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:
        if node.value is not None:
            self._remember(node, node.target, node.value)
        self.generic_visit(node)

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        self.scope.append(node.name)
        self.generic_visit(node)
        self.scope.pop()

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        self.scope.append(node.name)
        self.generic_visit(node)
        self.scope.pop()

    visit_AsyncFunctionDef = visit_FunctionDef

    def site_id(self, node: ast.Call, op: str) -> str:
        return f"{self.path.relative_to(ROOT).as_posix()}:{node.lineno}:{node.col_offset}:{op}"

    def visit_Call(self, node: ast.Call) -> None:
        name = dotted(node.func)
        if name and name.startswith("re."):
            op = name.split(".", 1)[1]
            pattern_node = node.args[0] if node.args and op in MATCH_METHODS | {"compile"} else None
            flags_node = next((kw.value for kw in node.keywords if kw.arg == "flags"), None)
            if flags_node is None:
                flags_index = {"compile": 1, "match": 2, "fullmatch": 2, "search": 2, "findall": 2, "finditer": 2, "split": 3, "sub": 4, "subn": 4}.get(op)
                if flags_index is not None and len(node.args) > flags_index:
                    flags_node = node.args[flags_index]
            self.calls.append(self.record(node, op, pattern_node, flags_node))
        elif isinstance(node.func, ast.Attribute) and node.func.attr in MATCH_METHODS and isinstance(node.func.value, ast.Name):
            self.calls.append(self.record(node, node.func.attr, None, None, receiver=node.func.value.id))
        self.generic_visit(node)

    def record(self, node: ast.Call, op: str, pattern_node: ast.AST | None, flags_node: ast.AST | None, receiver: str | None = None) -> dict:
        raw_pattern = source(self.text, pattern_node)
        try:
            pattern = safe_value(pattern_node, self.env) if pattern_node is not None else None
        except (ValueError, TypeError, KeyError):
            pattern = None
        try:
            flags = int(safe_value(flags_node, self.env)) if flags_node is not None else 0
        except (ValueError, TypeError, KeyError):
            flags = None
        dependencies = sorted({n.id for n in ast.walk(pattern_node) if isinstance(n, ast.Name) and n.id not in self.env} if pattern_node else [])
        return {
            "id": self.site_id(node, op), "module": ".".join(self.path.relative_to(ROOT).with_suffix("").parts),
            "source": self.path.relative_to(ROOT).as_posix(), "line": node.lineno, "column": node.col_offset,
            "scope": self.scope_name(), "operation": op, "receiver": receiver,
            "expression": source(self.text, node), "pattern_expression": raw_pattern,
            "pattern": pattern.decode("latin1") if isinstance(pattern, bytes) else pattern if isinstance(pattern, str) else None,
            "pattern_encoding": "bytes" if isinstance(pattern, bytes) else "text" if isinstance(pattern, str) else None,
            "flags_expression": source(self.text, flags_node), "flags": flag_names(flags) if flags is not None else None,
            "dependencies": dependencies, "compiled_from": None, "assignment_sources": {},
            "examples": None, "dart": None,
        }

    def resolve_binding(self, call: dict) -> str | None:
        receiver = call["receiver"]
        if receiver is None:
            return None
        pieces = call["scope"].split(".") if call["scope"] else []
        for n in range(len(pieces), -1, -1):
            key = (".".join(pieces[:n]), receiver)
            previous = [pair for pair in self.bindings.get(key, []) if pair[0] <= call["line"]]
            if previous:
                return max(previous)[1]
        return None

    def assignments_for(self, call: dict) -> dict[str, list[str]]:
        pieces = call["scope"].split(".") if call["scope"] else []
        out: dict[str, list[str]] = {}
        for name in call["dependencies"]:
            for n in range(len(pieces), -1, -1):
                key = (".".join(pieces[:n]), name)
                previous = [expr for line, expr in self.assignments.get(key, []) if line <= call["line"]]
                if previous:
                    out[name] = previous[-3:]
                    break
        return out


def scan() -> tuple[list[dict], list[dict]]:
    rows: list[dict] = []
    unknown_methods: list[dict] = []
    scanners: list[Scanner] = []
    for folder in ("pipeline", "server"):
        for path in sorted((ROOT / folder).rglob("*.py")):
            text = path.read_text(encoding="utf-8")
            tree = ast.parse(text, filename=str(path))
            scanner = Scanner(path, text, tree)
            scanner.visit(tree)
            scanners.append(scanner)
    lookup = {row["id"]: row for scanner in scanners for row in scanner.calls if row["receiver"] is None}
    module_bindings = {}
    for scanner in scanners:
        module = ".".join(scanner.path.relative_to(ROOT).with_suffix("").parts)
        for (scope, name), values in scanner.bindings.items():
            if not scope:
                module_bindings[f"{module}.{name}"] = max(values)[1]
    for scanner in scanners:
            for row in scanner.calls:
                if row["receiver"] is not None:
                    binding = scanner.resolve_binding(row)
                    if binding is None and row["receiver"] in scanner.imports:
                        binding = module_bindings.get(scanner.imports[row["receiver"]])
                    if binding is None:
                        unknown_methods.append(row)
                        continue
                    origin = lookup[binding]
                    row["compiled_from"] = binding
                    row["pattern_expression"] = origin["pattern_expression"]
                    row["pattern"] = origin["pattern"]
                    row["pattern_encoding"] = origin["pattern_encoding"]
                    row["flags_expression"] = origin["flags_expression"]
                    row["flags"] = origin["flags"]
                    row["dependencies"] = origin["dependencies"]
                row["assignment_sources"] = scanner.assignments_for(row)
                if (row["module"] == "pipeline.parse" and row["scope"] == "detect_lang"
                        and row["pattern_expression"] == "pat" and isinstance(scanner.env.get("LANG_WORDS"), dict)):
                    row["dynamic_variants"] = scanner.env["LANG_WORDS"]
                if (row["module"] == "pipeline.run" and row["scope"] == "Runner._recap_job"
                        and row["operation"] == "search"
                        and row["pattern_expression"] in {"f'<{k}>(.*?)</{k}>'", "f'<{k}>(.*)'"}):
                    full_tag = row["pattern_expression"] == "f'<{k}>(.*?)</{k}>'"
                    row["dynamic_variants"] = {k: f"<{k}>(.*?)</{k}>" if full_tag else f"<{k}>(.*)" for k in ("recap", "saga")}
                if row.get("dynamic_variants") and row["flags"] is not None:
                    flags = sum(FLAGS[name] for name in row["flags"])
                    mode = row["operation"] if row["operation"] in {"match", "fullmatch"} else "search"
                    row["variant_examples"] = {
                        name: {"pattern": pattern, "examples": choose_examples(pattern, flags, mode), "dart": dart_form(pattern, flags)}
                        for name, pattern in row["dynamic_variants"].items()
                    }
                if row["pattern"] is not None and row["flags"] is not None:
                    flags = sum(FLAGS[name] for name in row["flags"])
                    pattern = row["pattern"].encode("latin1") if row["pattern_encoding"] == "bytes" else row["pattern"]
                    mode = row["operation"] if row["operation"] in {"match", "fullmatch"} else "search"
                    row["examples"] = choose_examples(pattern, flags, mode)
                    row["dart"] = dart_form(row["pattern"], flags)
                rows.append(row)
    rows.sort(key=lambda r: (r["source"], r["line"], r["column"], r["operation"]))
    unknown_methods.sort(key=lambda r: (r["source"], r["line"], r["column"]))
    return rows, unknown_methods


def report(data: dict) -> str:
    rows = data["calls"]
    direct = [r for r in rows if r["receiver"] is None]
    static = [r for r in rows if r["pattern"] is not None and r["flags"] is not None]
    dynamic = [r for r in rows if r["operation"] in MATCH_METHODS | {"compile"} and (r["pattern"] is None or r["flags"] is None)]
    by_module = Counter(r["module"] for r in direct)
    out = [
        "# Python regular expression audit",
        "",
        "Generated by `python3 docs/port/regex_audit.py`; verify with `--check`. `REGEX.json` is the machine-readable call ledger and case set.",
        "",
        f"Direct `re.*` call sites: **{len(direct)}**; `pipeline.parse` contributes **{by_module['pipeline.parse']}** (PLAN says 34). Resolved compiled-pattern method calls: **{len(rows)-len(direct)}**. Static pattern call sites: **{len(static)}**; dynamic pattern call sites: **{len(dynamic)}**.",
        "",
        "Each static call has positive and negative input in `REGEX.json`. `oracle/semantics/regex_python.py` and `core/test/semantics/regex_test.dart` execute the same cases. The generated Dart form rewrites named captures, `\\Z`, leading inline flags, and Python's Unicode `\\w`, `\\b`, `\\d`, and `\\s` classes. The two dynamic `KG.plan` sites additionally have six paired cases in `oracle/semantics/surface_regex.jsonl`, generated through the production helper and checked in Python/Dart. These examples establish matching for the listed inputs; ported callers still need their full function goldens.",
        "",
        "## Direct calls by module",
        "",
        "| Module | Calls |",
        "|---|---:|",
    ]
    out.extend(f"| `{name}` | {count} |" for name, count in sorted(by_module.items()))
    out.extend(["", "## Dynamic patterns", "", "| Site | Operation | Expression | Inputs and validation |", "|---|---|---|---|"])
    for row in dynamic:
        source_link = f"../../{row['source']}#L{row['line']}"
        deps = ", ".join(f"`{x}`" for x in row["dependencies"]) or "compiled pattern binding"
        assignments = "; ".join(f"`{k}` ← `{v[-1].replace('|','&#124;')}`" for k, v in row["assignment_sources"].items())
        strategy = "Use captured production inputs from the corpus; compare Python and Dart match spans, groups, substitutions, and Unicode offsets for this call."
        if row["compiled_from"]:
            strategy += f" Compiled at `{row['compiled_from']}`."
        if row.get("dynamic_variants"):
            strategy += f" Static variants: {', '.join(row['dynamic_variants'])}; their cases are executable in both engines."
        if row["module"] == "pipeline.kg" and row["scope"] == "KG.plan" and "surf" in row["dependencies"]:
            strategy += " `surf` is built from filtered `data['surfaces']` model output. `surface_regex.jsonl` drives actual `KG.plan` for CJK, Latin boundaries, overlap, punctuation, empty, and filtered-empty cases; Python/Dart compare all match groups and code-point/UTF-16 spans. Full model-generated surface variety remains for A4 function goldens."
        elif row["module"] == "pipeline.parse" and row["scope"] == "detect_lang" and row["pattern_expression"] == "pat":
            strategy += " `pat` is drawn from the eight constant `LANG_WORDS` entries."
        elif row["module"] == "pipeline.run" and row["scope"] == "Runner._recap_job":
            strategy += " `k` is limited by the literal tuple `('recap', 'saga')`."
        out.append(f"| [`{row['id']}`]({source_link}) | `{row['operation']}` | `{(row['pattern_expression'] or '').replace('|','&#124;')}` | {deps}. {assignments} {strategy} |")
    out.extend(["", "## Static patterns requiring translation", "", "| Site | Operation | Python pattern | Flags | Dart changes | Positive / negative |", "|---|---|---|---|---|---|"])
    for row in static:
        source_link = f"../../{row['source']}#L{row['line']}"
        example = row["examples"] or {}
        fmt = lambda x: json.dumps(x, ensure_ascii=False) if x is not None else "∅"
        out.append(f"| [`{row['id']}`]({source_link}) | `{row['operation']}` | `{row['pattern'].replace('|','&#124;').replace('`','&#96;')}` | `{','.join(row['flags'] or [])}` | {', '.join(row['dart']['translation']) or '—'} | `{fmt(example.get('positive'))}` / `{fmt(example.get('negative'))}` |")
    out.append("")
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="check generated files without writing")
    args = parser.parse_args()
    rows, unknown = scan()
    data = {"schema": 1, "scope": ["pipeline/**/*.py", "server/**/*.py"], "count": len(rows), "calls": rows,
            "unresolved_method_candidates": [{"id": x["id"], "receiver": x["receiver"], "expression": x["expression"]} for x in unknown]}
    products = {OUTPUT: json.dumps(data, ensure_ascii=False, indent=2) + "\n", REPORT: report(data)}
    if args.check:
        stale = [str(p.relative_to(ROOT)) for p, content in products.items() if not p.exists() or p.read_text(encoding="utf-8") != content]
        if stale:
            print("Stale regex audit: " + ", ".join(stale), file=sys.stderr)
            return 1
    else:
        for path, content in products.items():
            path.write_text(content, encoding="utf-8")
    print(f"{len(rows)} regex sites; {sum(r['pattern'] is not None for r in rows)} static patterns; {sum(r['examples'] is not None and None in r['examples'].values() for r in rows)} incomplete case pairs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
