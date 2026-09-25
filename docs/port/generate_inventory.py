#!/usr/bin/env python3
"""Generate the Python port inventory from syntax trees, without importing app code."""

from __future__ import annotations

import argparse
import ast
from collections import Counter, defaultdict
from dataclasses import dataclass, field
import json
from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parents[2]
OUTPUT_MD = ROOT / "docs/port/INVENTORY.md"
OUTPUT_JSON = ROOT / "docs/port/inventory.json"
FUNCTION_NODES = (ast.FunctionDef, ast.AsyncFunctionDef)
SCOPE_NODES = FUNCTION_NODES + (ast.ClassDef,)
TEXT_NAMES = {"text", "body", "part", "content", "chapter", "line", "word", "sentence", "quote", "snippet", "raw", "source", "s"}
FILE_METHODS = {"open", "read", "read_text", "read_bytes", "write_text", "write_bytes", "mkdir", "unlink", "rmdir", "rename", "replace", "touch", "iterdir", "glob", "rglob", "exists", "is_file", "is_dir", "is_symlink", "stat", "lstat"}
FILE_CALLS = {"open", "ZipFile", "NamedTemporaryFile", "TemporaryDirectory", "mkstemp", "mkdtemp", "copy", "copy2", "copyfile", "rmtree", "move"}
ORCHESTRATION_CALLS = {"ThreadPoolExecutor", "Lock", "RLock", "Event", "Semaphore", "BoundedSemaphore", "Thread", "Process", "Popen", "sleep", "acquire", "release", "submit", "shutdown", "is_set"}
MUTATING_METHODS = {"append", "extend", "insert", "update", "pop", "popitem", "clear", "add", "remove", "discard", "setdefault", "sort", "reverse", "move_to_end", "commit", "merge", "apply", "add_recap"}
MODEL_ENTRYPOINTS = {
    "pipeline.llm.chat", "pipeline.llm.chat_json", "pipeline.llm.llm_judge",
    "pipeline.llm.jev_free", "pipeline.llm.jev_local", "pipeline.llm._jev_uncached", "pipeline.llm.jev",
}
MODEL_CALL_NAMES = {"chat", "chat_json", "llm_judge", "jev", "jev_free", "jev_local", "urlopen"}
STAGE_BY_MODULE = {
    "pipeline.provenance": "A1", "pipeline.lang": "A1", "pipeline.models": "A1", "server.storage": "A1/A6",
    "pipeline.parse": "A2", "pipeline.kind": "A2", "pipeline.classify": "A2/A4",
    "pipeline.llm": "A3", "pipeline.extract": "A4", "pipeline.local": "A4", "pipeline.judge": "A4",
    "pipeline.link": "A4", "pipeline.kg": "A4", "pipeline.run": "A5", "server.jobs": "A5",
    "server.app": "A6", "server.notebook": "A6", "server.reading_list": "A6",
    "server.manual_entities": "A6", "server.temporal": "A6", "server.ask": "A6",
    "server.marginalia": "A6", "server.model_settings": "A6",
    "scripts.export_judge_data": "A0（数据工具）", "scripts.build_release": "C（发布工具）",
}
LEGACY_TEST_FILES = (
    "test_export_exact_context.py", "test_judge_client.py", "test_judge_data.py",
    "test_kg.py", "test_llm.py", "test_manual_entities.py", "test_marginalia.py",
    "test_notebook.py", "test_parse_japanese.py", "test_pipeline_repair.py",
    "test_reading_list.py", "test_release.py", "test_server_repair.py",
    "test_standalone.py", "test_support_cache.py",
)


@dataclass
class Entry:
    module: str
    qualname: str
    path: Path
    node: ast.FunctionDef | ast.AsyncFunctionDef
    class_scope: str | None
    parent_scope: str | None
    id: str = ""
    call_expressions: set[str] = field(default_factory=set)
    internal_calls: set[str] = field(default_factory=set)
    callers: set[str] = field(default_factory=set)
    dangers: set[str] = field(default_factory=set)
    mutates_state: bool = False
    category: str = ""


def function_entries(path: Path, module: str) -> tuple[ast.Module, list[Entry]]:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    entries: list[Entry] = []

    def visit(node: ast.AST, scope: tuple[str, ...], class_scope: str | None) -> None:
        for child in ast.iter_child_nodes(node):
            if isinstance(child, ast.ClassDef):
                new_scope = scope + (child.name,)
                visit(child, new_scope, ".".join(new_scope))
            elif isinstance(child, FUNCTION_NODES):
                new_scope = scope + (child.name,)
                entries.append(Entry(module, ".".join(new_scope), path, child, class_scope, ".".join(scope) or None))
                visit(child, new_scope, class_scope)
            else:
                visit(child, scope, class_scope)

    visit(tree, (), None)
    return tree, entries


def import_binding(node: ast.Import | ast.ImportFrom, module: str) -> dict[str, str]:
    aliases: dict[str, str] = {}
    package = module.split(".")[:-1]
    if isinstance(node, ast.Import):
        for item in node.names:
            aliases[item.asname or item.name.split(".")[0]] = item.name if item.asname else item.name.split(".")[0]
    else:
        if node.level:
            base = package[: len(package) - node.level + 1]
            source = ".".join(base + ([node.module] if node.module else []))
        else:
            source = node.module or ""
        for item in node.names:
            if item.name != "*":
                aliases[item.asname or item.name] = ".".join(x for x in (source, item.name) if x)
    return aliases


def imports_of(tree: ast.Module, module: str) -> dict[str, str]:
    aliases: dict[str, str] = {}
    for node in tree.body:
        if isinstance(node, (ast.Import, ast.ImportFrom)):
            aliases.update(import_binding(node, module))
    return aliases


def call_name(node: ast.AST) -> str:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        return f"{call_name(node.value)}.{node.attr}"
    if isinstance(node, ast.Call):
        return f"{call_name(node.func)}(...)"
    if isinstance(node, ast.Subscript):
        return f"{call_name(node.value)}[...]"
    if isinstance(node, ast.Lambda):
        return "<lambda>"
    return f"<{type(node).__name__}>"


def text_length_candidate(node: ast.AST) -> bool:
    if isinstance(node, ast.Name):
        return any(part in TEXT_NAMES for part in node.id.lower().split("_"))
    if isinstance(node, ast.Subscript):
        if isinstance(node.slice, ast.Constant) and str(node.slice.value).lower() in TEXT_NAMES | {"t"}:
            return True
        return text_length_candidate(node.value)
    if isinstance(node, ast.Attribute):
        return node.attr.lower() in TEXT_NAMES or text_length_candidate(node.value)
    if isinstance(node, (ast.Constant, ast.JoinedStr)):
        return isinstance(getattr(node, "value", ""), str) or isinstance(node, ast.JoinedStr)
    return False


def root_name(node: ast.AST) -> str | None:
    while isinstance(node, (ast.Attribute, ast.Subscript)):
        node = node.value
    return node.id if isinstance(node, ast.Name) else None


def local_names(node: ast.FunctionDef | ast.AsyncFunctionDef) -> set[str]:
    names: set[str] = set()

    class Visitor(ast.NodeVisitor):
        def visit_FunctionDef(self, inner: ast.FunctionDef) -> None:
            names.add(inner.name)

        def visit_AsyncFunctionDef(self, inner: ast.AsyncFunctionDef) -> None:
            names.add(inner.name)

        def visit_ClassDef(self, inner: ast.ClassDef) -> None:
            names.add(inner.name)

        def visit_Name(self, inner: ast.Name) -> None:
            if isinstance(inner.ctx, ast.Store):
                names.add(inner.id)

    visitor = Visitor()
    for statement in node.body:
        visitor.visit(statement)
    return names


class BodyAnalyzer(ast.NodeVisitor):
    """Visit one function body; a nested definition belongs to its own row."""

    def __init__(self, module: str, parameters: set[str], locals_: set[str], imports: set[str]) -> None:
        self.module = module
        self.parameters = parameters
        self.locals = locals_
        self.import_names = imports
        self.calls: list[tuple[str, int]] = []
        self.dangers: set[str] = set()
        self.local_imports: dict[str, str] = {}
        self.mutates_state = False

    def _is_state_root(self, name: str | None) -> bool:
        return name is not None and (name in self.parameters or name not in self.locals | self.import_names | set(self.local_imports))

    def _check_target(self, node: ast.AST) -> None:
        if isinstance(node, (ast.Tuple, ast.List)):
            for part in node.elts:
                self._check_target(part)
        elif isinstance(node, (ast.Attribute, ast.Subscript)) and self._is_state_root(root_name(node)):
            self.mutates_state = True

    def visit_Assign(self, node: ast.Assign) -> None:
        for target in node.targets:
            self._check_target(target)
        self.generic_visit(node)

    def visit_AugAssign(self, node: ast.AugAssign) -> None:
        self._check_target(node.target)
        self.generic_visit(node)

    def visit_AnnAssign(self, node: ast.AnnAssign) -> None:
        self._check_target(node.target)
        self.generic_visit(node)

    def visit_Delete(self, node: ast.Delete) -> None:
        for target in node.targets:
            self._check_target(target)
        self.generic_visit(node)

    def visit_Import(self, node: ast.Import) -> None:
        self.local_imports.update(import_binding(node, self.module))

    def visit_ImportFrom(self, node: ast.ImportFrom) -> None:
        self.local_imports.update(import_binding(node, self.module))

    def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
        return

    def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
        return

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        return

    def visit_Call(self, node: ast.Call) -> None:
        name = call_name(node.func)
        self.calls.append((name, node.lineno))
        base = name.split(".")[-1]
        if isinstance(node.func, ast.Attribute) and base in MUTATING_METHODS and self._is_state_root(root_name(node.func.value)):
            self.mutates_state = True
        if name.startswith("re.") or base in {"finditer", "findall", "fullmatch"} or (base in {"match", "search", "sub"} and "RE" in name):
            self.dangers.add("正则")
        if name in {"json.dumps", "json.dump"} or name.endswith(".json.dumps"):
            self.dangers.add("JSON 序列化")
        if name in {"json.loads", "json.load"} or name.endswith(".json.loads"):
            self.dangers.add("JSON 解析")
        if name.startswith("hashlib.") or base in {"sha256", "sha1", "hexdigest", "digest", "hash"}:
            self.dangers.add("哈希")
        if base == "len":
            self.dangers.add("len")
            if node.args and text_length_candidate(node.args[0]):
                self.dangers.add("正文长度疑似")
        if base in {"sorted", "sort"}:
            self.dangers.add("排序")
        if base in {"dict", "OrderedDict", "items", "keys", "values"}:
            self.dangers.add("dict 顺序")
        if name.startswith(("time.", "datetime.", "date.")) or base in {"time", "monotonic", "perf_counter", "sleep", "strftime", "utcnow", "now"}:
            self.dangers.add("时间")
        if name.startswith(("random.", "secrets.", "uuid.")) or base in {"randint", "random", "uniform", "choice"}:
            self.dangers.add("随机数")
        if base in {"strip", "lstrip", "rstrip", "split", "rsplit", "isdigit", "casefold", "title"}:
            self.dangers.add(f"str.{base}")
        if base in {"encode", "decode", "u16"} or name.startswith("unicodedata."):
            self.dangers.add("Unicode 编码")
        if base in {"float", "round"}:
            self.dangers.add("浮点")
        if base == "int":
            self.dangers.add("int 转换")
        self.generic_visit(node)

    def visit_Constant(self, node: ast.Constant) -> None:
        if isinstance(node.value, float):
            self.dangers.add("浮点")

    def visit_Subscript(self, node: ast.Subscript) -> None:
        if isinstance(node.slice, ast.Slice) or (isinstance(node.slice, ast.Tuple) and any(isinstance(x, ast.Slice) for x in node.slice.elts)):
            self.dangers.add("切片")
        self.generic_visit(node)

    def visit_BinOp(self, node: ast.BinOp) -> None:
        if isinstance(node.op, ast.FloorDiv):
            self.dangers.add("//")
        elif isinstance(node.op, ast.Mod):
            self.dangers.add("%")
        self.generic_visit(node)


def resolve_call(name: str, line: int, entry: Entry, aliases: dict[str, str], by_name: dict[str, list[Entry]], class_names: set[str]) -> str | None:
    candidates: list[str] = []
    if name.startswith(("self.", "cls.")) and entry.class_scope:
        candidates.append(f"{entry.module}.{entry.class_scope}.{name.split('.', 1)[1]}")
    elif name.startswith("super()."):
        return None
    else:
        parts = name.split(".")
        if parts[0] in aliases:
            candidates.append(".".join([aliases[parts[0]], *parts[1:]]))
        if len(parts) == 1:
            scope = entry.qualname.split(".")[:-1]
            for n in range(len(scope), -1, -1):
                candidates.append(".".join([entry.module, *scope[:n], name]))
        else:
            candidates.append(f"{entry.module}.{name}")
            candidates.append(name)
    for symbol in candidates:
        if symbol in class_names:
            symbol += ".__init__"
        matches = by_name.get(symbol, [])
        if not matches:
            continue
        if len(matches) == 1:
            return matches[0].id
        if entry in matches:
            return entry.id
        preceding = [m for m in matches if m.node.lineno <= line]
        return max(preceding or matches, key=lambda m: m.node.lineno).id
    return None


def category_for(entry: Entry, resolved: set[str]) -> str:
    names = entry.call_expressions
    bases = {name.split(".")[-1] for name in names}
    if entry.module == "server.app" and entry.class_scope == "Handler":
        return "HTTP 路由"
    if entry.module == "server.jobs" or (entry.module == "pipeline.run" and entry.qualname.split(".")[-1] in {"run", "run2", "process", "_local_job", "run_book", "main", "start", "stop", "cancel", "queue_final", "resume_final_jobs"}):
        return "并发与编排"
    if entry.id in MODEL_ENTRYPOINTS or resolved & MODEL_ENTRYPOINTS or bases & MODEL_CALL_NAMES or any(name.startswith(("urllib.request.urlopen", "_opener(...).open")) for name in names):
        return "模型调用"
    if entry.mutates_state:
        return "并发与编排"
    if bases & ORCHESTRATION_CALLS or any(name.startswith(("threading.", "concurrent.futures.", "subprocess.")) for name in names):
        return "并发与编排"
    if (bases & FILE_METHODS or bases & FILE_CALLS or any(name.startswith(("shutil.", "tempfile.", "os.replace", "os.rename", "os.remove", "os.unlink", "os.makedirs", "os.mkdir")) for name in names)
            or any(name.startswith(("_cache.get", "_cache.evict", "cache.get")) for name in names)):
        return "文件读写"
    return "纯函数"


def markdown_cell(value: str) -> str:
    return value.replace("|", "&#124;").replace("\n", " ")


def md_code_list(items: list[str]) -> str:
    return ", ".join(f"`{markdown_cell(x)}`" for x in items) if items else "—"


def analyze_functions(trees: dict[str, ast.Module], entries: list[Entry]) -> None:
    by_name: dict[str, list[Entry]] = defaultdict(list)
    for e in entries:
        by_name[f"{e.module}.{e.qualname}"].append(e)
    for matches in by_name.values():
        for e in matches:
            e.id = f"{e.module}.{e.qualname}" + (f"@L{e.node.lineno}" if len(matches) > 1 else "")
    class_names = {f"{module}.{n.name}" for module, tree in trees.items() for n in ast.walk(tree) if isinstance(n, ast.ClassDef)}
    imports = {module: imports_of(tree, module) for module, tree in trees.items()}
    by_id = {e.id: e for e in entries}
    for e in entries:
        visitor = BodyAnalyzer(e.module, {arg.arg for arg in (*e.node.args.posonlyargs, *e.node.args.args, *e.node.args.kwonlyargs)}, local_names(e.node), set(imports[e.module]))
        for stmt in e.node.body:
            visitor.visit(stmt)
        e.call_expressions = {name for name, _ in visitor.calls}
        e.dangers = visitor.dangers
        e.mutates_state = visitor.mutates_state
        if e.mutates_state:
            e.dangers.add("可见状态原位修改")
        for name, line in visitor.calls:
            target = resolve_call(name, line, e, {**imports[e.module], **visitor.local_imports}, by_name, class_names)
            if target:
                e.internal_calls.add(target)
                by_id[target].callers.add(e.id)
        e.category = category_for(e, e.internal_calls)
    priority = {"纯函数": 0, "文件读写": 1, "模型调用": 2, "并发与编排": 3, "HTTP 路由": 4}
    changed = True
    while changed:
        changed = False
        for e in entries:
            if e.category not in {"纯函数", "文件读写"}:
                continue
            for target in e.internal_calls:
                target_category = by_id[target].category
                if priority[target_category] > priority[e.category]:
                    e.category = target_category
                    changed = True


def test_entries(function_by_name: dict[str, list[Entry]], class_names: set[str]) -> list[dict]:
    rows: list[dict] = []
    for name in LEGACY_TEST_FILES:
        path = ROOT / "tests" / name
        module = ".".join(path.relative_to(ROOT).with_suffix("").parts)
        tree, functions = function_entries(path, module)
        aliases = imports_of(tree, module)
        imported_modules = {".".join(value.split(".")[:2]) for value in aliases.values() if value.startswith(("pipeline.", "server.", "scripts.")) and len(value.split(".")) >= 2}
        for match in re.finditer(r"scripts/([A-Za-z_][A-Za-z_0-9]*)\.py", path.read_text(encoding="utf-8")):
            imported_modules.add(f"scripts.{match.group(1)}")
        for e in functions:
            if not e.node.name.startswith("test_"):
                continue
            visitor = BodyAnalyzer(e.module, {arg.arg for arg in (*e.node.args.posonlyargs, *e.node.args.args, *e.node.args.kwonlyargs)}, local_names(e.node), set(aliases))
            for stmt in e.node.body:
                visitor.visit(stmt)
            targets: set[str] = set()
            for name, line in visitor.calls:
                target = resolve_call(name, line, e, {**aliases, **visitor.local_imports}, function_by_name, class_names)
                if target:
                    targets.add(target)
            explicit_modules = sorted({".".join(x.split(".")[:2]) for x in targets})
            candidate_modules = sorted(set(explicit_modules) | imported_modules)
            stages = sorted({STAGE_BY_MODULE.get(m, "待核对") for m in candidate_modules})
            rows.append({
                "id": f"{module}.{e.qualname}",
                "source": path.relative_to(ROOT).as_posix(),
                "line": e.node.lineno,
                "direct_targets": sorted(targets),
                "candidate_modules": candidate_modules,
                "candidate_stages": stages,
                "status": "待翻译",
                "reason": "对应业务阶段尚未移植",
            })
    return rows


def payload(entries: list[Entry], tests: list[dict]) -> dict:
    return {
        "schema": 1,
        "scope": ["pipeline/**/*.py", "server/**/*.py"],
        "count": len(entries),
        "functions": [
            {
                "id": e.id,
                "module": e.module,
                "qualified_name": e.qualname,
                "source": e.path.relative_to(ROOT).as_posix(),
                "line": e.node.lineno,
                "line_count": e.node.end_lineno - e.node.lineno + 1,
                "scope_kind": "method" if e.class_scope and e.parent_scope == e.class_scope else "nested" if e.parent_scope else "module",
                "parameters": [arg.arg for arg in (*e.node.args.posonlyargs, *e.node.args.args, *e.node.args.kwonlyargs)],
                "category": e.category,
                "calls": sorted(e.call_expressions),
                "internal_calls": sorted(e.internal_calls),
                "callers": sorted(e.callers),
                "danger_semantics": sorted(e.dangers),
                "mutates_state": e.mutates_state,
                "status": "未开始",
            }
            for e in entries
        ],
        "test_scope": "Python 1.7.5 原有 15 个 tests/test_*.py 文件中名称以 test_ 开头的 FunctionDef/AsyncFunctionDef（含类方法）；新增 A0 语义测试单独计数",
        "test_files": list(LEGACY_TEST_FILES),
        "test_count": len(tests),
        "tests": tests,
    }


def markdown(data: dict) -> str:
    functions = data["functions"]
    tests = data["tests"]
    modules = Counter(f["module"] for f in functions)
    kinds = Counter(f["category"] for f in functions)
    out = [
        "# Python → Dart function inventory",
        "",
        "Generated by `python3 docs/port/generate_inventory.py` from Python AST. Do not edit rows by hand.",
        "Run `python3 docs/port/generate_inventory.py --check` to verify regeneration. Machine-readable data is in `docs/port/inventory.json`.",
        "",
        "## Scope and counting",
        "",
        f"- Production: **{len(functions)}** `FunctionDef`/`AsyncFunctionDef` nodes in `pipeline/` and `server/` (including methods and nested functions). PLAN target: 378; difference: **{len(functions) - 378:+d}**.",
        f"- Python tests: **{len(tests)}** named `test_*` in the 15 frozen Python 1.7.5 test files (including methods). PLAN target: 171; difference: **{len(tests) - 171:+d}**. New A0 semantics tests, helper scripts, and Node/browser tests are outside this baseline number.",
        "- `@L<line>` distinguishes repeated lexical names. Calls are static AST call expressions; `internal_calls`/callers resolve direct names, imports, and `self`/`cls` methods. Dynamic dispatch and callbacks require separate review.",
        "- Categories are static triage, with direct HTTP routes and explicit orchestration/model entrypoints taking precedence. Pure/file candidates inherit effects from resolved internal calls. `纯函数` means no listed side effect was found; it is a review candidate, not a proof of purity. Danger tags are conservative syntax flags; `正文长度疑似` needs manual confirmation.",
        "- All statuses start as `未开始`. After a Dart counterpart and golden exist, record progress in `MANIFEST.yaml`; regeneration should never silently mark a function complete.",
        "",
        "| Category | Count |",
        "|---|---:|",
    ]
    out.extend(f"| {name} | {kinds[name]} |" for name in ("纯函数", "文件读写", "模型调用", "并发与编排", "HTTP 路由"))
    out.extend(["", "## Functions", ""])
    for module in sorted(modules):
        out.extend([f"### `{module}` ({modules[module]})", "", "| ID | Lines | Category | Calls (AST expressions) | Internal callers | Danger semantics | Status |", "|---|---:|---|---|---|---|---|"])
        for f in functions:
            if f["module"] != module:
                continue
            src = f"../../{f['source']}#L{f['line']}"
            calls = md_code_list(f["calls"])
            callers = md_code_list(f["callers"])
            dangers = md_code_list(f["danger_semantics"])
            out.append(f"| [`{markdown_cell(f['id'])}`]({src}) | {f['line_count']} | {f['category']} | {calls} | {callers} | {dangers} | {f['status']} |")
        out.append("")
    out.extend([
        "## Python test function register",
        "",
        "Each row is one test function to translate. Direct targets are statically resolved calls; candidate modules/stages are routing hints for the port work. The per-test status and reason are initial A0 state.",
        "",
        "| Test ID | Candidate modules | Candidate stages | Direct targets | Status | Reason |",
        "|---|---|---|---|---|---|",
    ])
    for t in tests:
        src = f"../../{t['source']}#L{t['line']}"
        out.append(f"| [`{markdown_cell(t['id'])}`]({src}) | {md_code_list(t['candidate_modules'])} | {md_code_list(t['candidate_stages'])} | {md_code_list(t['direct_targets'])} | {t['status']} | {t['reason']} |")
    out.append("")
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify generated files without writing")
    args = parser.parse_args()
    trees: dict[str, ast.Module] = {}
    entries: list[Entry] = []
    for dirname in ("pipeline", "server"):
        for path in sorted((ROOT / dirname).rglob("*.py")):
            module = ".".join(path.relative_to(ROOT).with_suffix("").parts)
            tree, found = function_entries(path, module)
            trees[module] = tree
            entries.extend(found)
    entries.sort(key=lambda e: (e.module, e.node.lineno, e.qualname))
    analyze_functions(trees, entries)
    by_name: dict[str, list[Entry]] = defaultdict(list)
    for e in entries:
        by_name[f"{e.module}.{e.qualname}"].append(e)
    class_names = {f"{module}.{n.name}" for module, tree in trees.items() for n in ast.walk(tree) if isinstance(n, ast.ClassDef)}
    tests = test_entries(by_name, class_names)
    data = payload(entries, tests)
    products = {
        OUTPUT_JSON: json.dumps(data, ensure_ascii=False, indent=2, sort_keys=False) + "\n",
        OUTPUT_MD: markdown(data),
    }
    if args.check:
        stale = [str(path.relative_to(ROOT)) for path, value in products.items() if not path.exists() or path.read_text(encoding="utf-8") != value]
        if stale:
            print("Stale inventory: " + ", ".join(stale), file=sys.stderr)
            return 1
    else:
        for path, value in products.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(value, encoding="utf-8")
    print(f"{len(entries)} Python functions; {len(tests)} Python test functions")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
