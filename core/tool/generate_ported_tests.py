"""Index the frozen Python 1.7.5 tests and scaffold their Dart counterparts.

The initial generated callbacks are failing placeholders under explicit skips.
Translation adds the original assertions and a reviewed adapter binding while
keeping the skip until the Dart owner exists; activation removes the skip.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import re
from collections import defaultdict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
INVENTORY = ROOT / "docs/port/inventory.json"
OUT = ROOT / "core/test/ported"
MANIFEST = OUT / "manifest.json"
PYTHON_ONLY = {"scripts.export_judge_data", "scripts.build_release"}
TEST_CALL = re.compile(r'\btest\s*\(\s*"([^"]+)"', re.M)
ASSERTION_CALL = re.compile(r'\b(?:expect|expectLater)\s*\(')
CONTRACT_CALL = re.compile(r'\bcallPorted\s*\(')
DART_TRIVIA = re.compile(
    r"//[^\n]*|/\*[\s\S]*?\*/|r?'''[\s\S]*?'''|r?\"\"\"[\s\S]*?\"\"\"|"
    r"r?'(?:\\.|[^'\\])*'|r?\"(?:\\.|[^\"\\])*\""
)
TOP_LEVEL_FUNCTION = re.compile(r'(?m)^[A-Za-z_][^\n]*\b[A-Za-z_]\w*\s*\(')

# These are explicitly reviewed test-only entry points, never production Dart APIs.
TEST_ONLY_CONTRACTS = {
    "tests.test_kg.generic_reveal_merge_setup",
    "tests.test_kg.reveal_setup",
    *(f"tests.test_pipeline_repair.{name}_scenario" for name in
      ("budget", "classify", "judge", "kg", "llm", "parse", "runner")),
}
SCRIPTED_CONTRACTS = {
    "server.app.Handler#scripted_http",
    "server.ask.answer#scripted",
    "server.ask.retrieval_query#scripted",
    "server.ask.retrieve#scripted",
    "server.ask.who_is#scripted",
    "server.jobs.Worker#scripted",
    "server.marginalia#scripted_http",
    "server.storage.JsonCache#scripted",
}
# The value is the call a helper must make. A test must call a listed helper or
# callPorted directly, and must contain an executable assertion.
CONTRACT_BINDINGS = {
    "test_export_exact_context_ported_test.dart": {"_export": "callPorted", "_decisionId": "callPorted"},
    "test_judge_client_ported_test.dart": {"scripted": "callPorted", "classifierBatches": "callPorted"},
    "test_judge_data_ported_test.dart": {"dataCall": "callPorted"},
    "test_kg_ported_test.dart": {"_revealSetup": "callPorted"},
    "test_llm_ported_test.dart": {},
    "test_manual_entities_ported_test.dart": {"_apply": "callPorted", "_rows": "callPorted"},
    "test_marginalia_ported_test.dart": {"marginaliaRun": "callPorted", "_u16": "callPorted"},
    "test_notebook_ported_test.dart": {"_run": "callPorted"},
    "test_parse_japanese_ported_test.dart": {"_parse": "callPorted"},
    "test_pipeline_repair_ported_test.dart": {
        "_scenario": "callPorted", "_runner": "_scenario", "_quarantine": "callPorted"},
    "test_reading_list_ported_test.dart": {"_run": "callPorted"},
    "test_release_ported_test.dart": {"_run": "callPorted"},
    "test_server_repair_ported_test.dart": {
        "httpRun": "callPorted", "answerRun": "callPorted", "stateRun": "callPorted"},
    "test_standalone_ported_test.dart": {"_scenario": "callPorted"},
    "test_support_cache_ported_test.dart": {"_run": "callPorted", "_tuple": "callPorted"},
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def dart_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=False).replace("$", "\\$")


def ast_ids(path: Path) -> list[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    module = "tests." + path.stem
    ids = []
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name.startswith("test_"):
            ids.append(f"{module}.{node.name}")
        elif isinstance(node, ast.ClassDef):
            for member in node.body:
                if isinstance(member, (ast.FunctionDef, ast.AsyncFunctionDef)) and member.name.startswith("test_"):
                    ids.append(f"{module}.{node.name}.{member.name}")
    return ids


def contract_owner_module(owner: str, row: dict, inventory: list[dict]) -> str | None:
    """Resolve an explicit production, old tool, or reviewed test-only owner."""
    if not isinstance(owner, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9.]*?(?:#scripted(?:_http)?)?", owner):
        raise ValueError(f"Invalid contract owner ID for {row['id']}: {owner!r}")
    if owner.startswith("tests."):
        if owner not in TEST_ONLY_CONTRACTS or owner.split(".")[1] != Path(row["python_source"]).stem:
            raise ValueError(f"Unreviewed test-only contract owner for {row['id']}: {owner}")
        return None
    if owner.startswith("scripts."):
        parts = owner.split(".")
        if len(parts) != 3:
            raise ValueError(f"Script-tool owner must name a function: {owner}")
        path = ROOT / "scripts" / f"{parts[1]}.py"
        if not path.is_file() or parts[2] not in {
            node.name for node in ast.parse(path.read_text(encoding="utf-8")).body
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        }:
            raise ValueError(f"Script-tool contract owner is absent: {owner}")
        module = ".".join(parts[:2])
        if module not in row["owner_modules"] and row["python_source"] != "tests/test_judge_data.py":
            raise ValueError(f"Script-tool owner is unrelated to {row['id']}: {owner}")
        return module
    if "#" in owner and owner not in SCRIPTED_CONTRACTS:
        raise ValueError(f"Unreviewed scripted adapter ID for {row['id']}: {owner}")
    base = owner.split("#", 1)[0]
    matches = [entry for entry in inventory
               if entry["id"] == base or entry["id"].startswith(base + ".")]
    modules = {entry["module"] for entry in matches}
    if len(modules) != 1:
        raise ValueError(f"Contract owner is not an inventory function/module/class: {owner}")
    module = modules.pop()
    manual_http = row["id"] == (
        "tests.test_manual_entities.ManualHTTP."
        "test_manual_endpoint_cutoff_retry_export_and_delete")
    if module not in row["owner_modules"] and not (manual_http and owner == "server.app.Handler.route"):
        raise ValueError(f"Contract owner module is unrelated to {row['id']}: {owner}")
    return module


def helper_source(source: str, name: str) -> str:
    """Return one reviewed top-level Dart fixture helper, excluding the next one."""
    prefix = source.split("void main()", 1)[0]
    functions = list(TOP_LEVEL_FUNCTION.finditer(prefix))
    found = [index for index, match in enumerate(functions)
             if re.search(rf"\b{re.escape(name)}\s*\(", match.group())]
    if len(found) != 1:
        raise ValueError(f"Contract fixture helper {name} is missing or ambiguous")
    index = found[0]
    return prefix[functions[index].start():
                  functions[index + 1].start() if index + 1 < len(functions) else len(prefix)]


def check_contract(row: dict, source: str, body: str, inventory: list[dict]) -> None:
    owners = row.get("contract_owners")
    if not isinstance(owners, list) or not owners or len(owners) != len(set(owners)):
        raise ValueError(f"Translated contract has no unique explicit owner IDs: {row['id']}")
    for owner in owners:
        contract_owner_module(owner, row, inventory)

    # TEST_CALL splits at the next test. A real skip label is outside literals.
    cleaned = DART_TRIVIA.sub(lambda match: " " * len(match.group()), body)
    skips = list(re.finditer(r"\bskip\s*:", cleaned))
    callback = body[:skips[-1].start()] if skips else body
    executable = DART_TRIVIA.sub(" ", callback)
    direct_assertion = ASSERTION_CALL.search(executable)
    delegated_assertion = bool(re.search(r"\bexpectClientError\s*\(", executable))
    if delegated_assertion:
        assertion_helper = DART_TRIVIA.sub(" ", helper_source(source, "expectClientError"))
        delegated_assertion = bool(ASSERTION_CALL.search(assertion_helper))
    if not direct_assertion and not delegated_assertion:
        raise ValueError(f"Translated callback has no executable assertion: {row['id']}")
    helpers = CONTRACT_BINDINGS.get(Path(row["dart_file"]).name)
    if helpers is None:
        raise ValueError(f"Translated callback has no reviewed binding list: {row['id']}")
    reached = [callback] if CONTRACT_CALL.search(executable) else []
    for name, target in helpers.items():
        code = helper_source(source, name)
        if not re.search(rf"\b{re.escape(target)}\s*\(", DART_TRIVIA.sub(" ", code)):
            raise ValueError(f"Contract helper {name} no longer reaches {target}")
        if re.search(rf"\b{re.escape(name)}\s*\(", executable):
            reached.append(code)
            if target != "callPorted":
                reached.append(helper_source(source, target))
    if not reached:
        raise ValueError(f"Translated callback never invokes a reviewed contract adapter: {row['id']}")
    primary = owners[0]
    evidence = "\n".join([callback, *reached])
    if primary.startswith("tests.test_pipeline_repair."):
        scenario = primary.rsplit(".", 1)[-1]
        if scenario == "runner_scenario":
            bound = ("_runner(" in executable and "'runner_scenario'" in evidence or
                     "_scenario('runner_scenario'" in callback)
        else:
            bound = f"'{scenario}'" in callback
    else:
        bound = f"'{primary}'" in evidence or f'"{primary}"' in evidence
    if not bound:
        raise ValueError(f"Primary owner is not bound by the callback/fixture: {row['id']}: {primary}")


def owner_modules(row: dict) -> list[str]:
    candidates = row["candidate_modules"]
    if not candidates:
        raise ValueError(f"No owning module recorded for {row['id']}")
    # Candidate imports are conservative: HTTP tests exercise several modules
    # through a route even when their direct-call list is empty.
    return candidates


def entry(row: dict) -> dict:
    modules = owner_modules(row)
    stages = row["candidate_stages"]
    assertion = row["id"].rsplit(".", 1)[-1].removeprefix("test_").replace("_", " ")
    targets = row["direct_targets"] or modules
    python_only = all(module in PYTHON_ONLY for module in modules)
    if python_only:
        status = "scope_exception"
        reason = (
            "Python-only " + ", ".join(modules) + " owns '" + assertion
            + "'; PLAN names no Dart production replacement. Decide its A0/C treatment."
        )
    else:
        status = "pending_port"
        reason = (
            "Dart implementation of " + ", ".join(targets) + " is pending ("
            + ", ".join(stages) + "); required to check '" + assertion + "'."
        )
    return {
        "id": row["id"],
        "python_source": row["source"],
        "python_line": row["line"],
        "dart_file": f"core/test/ported/{Path(row['source']).stem}_ported_test.dart",
        "dart_name": row["id"],
        "owner_modules": modules,
        "owner_stages": stages,
        "direct_targets": row["direct_targets"],
        "status": status,
        "skip_reason": reason,
    }


def expected_manifest() -> dict:
    inventory = json.loads(INVENTORY.read_text(encoding="utf-8"))
    if inventory["test_count"] != 171 or len(inventory["tests"]) != 171:
        raise ValueError("The frozen 1.7.5 baseline must contain exactly 171 tests")
    listed = inventory["tests"]
    sources = {"tests/" + name for name in inventory["test_files"]}
    if len(sources) != 15 or {row["source"] for row in listed} != sources:
        raise ValueError("Inventory test file scope differs from the 15-file baseline")
    ids = [row["id"] for row in listed]
    if len(set(ids)) != 171:
        raise ValueError("Duplicate test ID in inventory")
    ast_found = {
        test_id
        for source in sources
        for test_id in ast_ids(ROOT / source)
    }
    if ast_found != set(ids):
        raise ValueError(f"Python AST differs: missing={sorted(ast_found-set(ids))}, extra={sorted(set(ids)-ast_found)}")
    entries = [entry(row) for row in listed]
    catalog = [
        {key: row[key] for key in ("id", "source", "line", "direct_targets", "candidate_modules", "candidate_stages")}
        for row in listed
    ]
    catalog_sha256 = hashlib.sha256(
        json.dumps(catalog, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    counts = {
        "total": 171,
        "translated": 0,
        "pending_port": sum(e["status"] == "pending_port" for e in entries),
        "scope_exception": sum(e["status"] == "scope_exception" for e in entries),
    }
    return {
        "schema": 1,
        "baseline": "Python 1.7.5: the 15 original tests/test_*.py files, excluding new A0 semantics tests",
        "test_catalog_sha256": catalog_sha256,
        "python_source_sha256": {source: sha256(ROOT / source) for source in sorted(sources)},
        "counts": counts,
        "tests": entries,
    }


def render_dart(entries: list[dict]) -> str:
    lines = [
        "// Generated from docs/port/inventory.json by core/tool/generate_ported_tests.py.",
        "// Skipped failing callbacks are unported assertions, not translations.",
        "import 'package:test/test.dart';",
        "",
        "void main() {",
    ]
    for row in entries:
        lines.extend([
            "  test(",
            f"    {dart_string(row['dart_name'])},",
            f"    () => fail({dart_string('Dart port not implemented: ' + row['id'])}),",
            f"    skip: {dart_string(row['skip_reason'])},",
            "  );",
        ])
    return "\n".join(lines + ["}", ""])


def write(force: bool) -> None:
    target = expected_manifest()
    if MANIFEST.exists() and not force:
        raise ValueError("Mapping already exists; use --check or review before --force")
    grouped = defaultdict(list)
    for row in target["tests"]:
        grouped[row["dart_file"]].append(row)
    OUT.mkdir(parents=True, exist_ok=True)
    for relative, entries in sorted(grouped.items()):
        path = ROOT / relative
        if path.exists() and not force:
            raise ValueError(f"Refusing to overwrite {relative}")
        path.write_text(render_dart(entries), encoding="utf-8")
    MANIFEST.write_text(json.dumps(target, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def check() -> None:
    expected = expected_manifest()
    inventory = json.loads(INVENTORY.read_text(encoding="utf-8"))["functions"]
    actual = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if actual["test_catalog_sha256"] != expected["test_catalog_sha256"]:
        raise ValueError("Inventory test catalog changed; reconcile test mapping")
    if actual["python_source_sha256"] != expected["python_source_sha256"]:
        raise ValueError("Baseline Python tests changed; reconcile assertion mapping")
    actual_rows = actual["tests"]
    if {row["id"] for row in actual_rows} != {row["id"] for row in expected["tests"]}:
        raise ValueError("Manifest test IDs differ from Python AST")
    if len(actual_rows) != 171 or len({row["id"] for row in actual_rows}) != 171:
        raise ValueError("Manifest must map 171 unique tests")
    by_file = defaultdict(list)
    baseline_rows = {row["id"]: row for row in expected["tests"]}
    for row in actual_rows:
        baseline = baseline_rows[row["id"]]
        for field in (
            "python_source",
            "python_line",
            "dart_file",
            "dart_name",
            "owner_modules",
            "owner_stages",
            "direct_targets",
        ):
            if row[field] != baseline[field]:
                raise ValueError(f"{field} drifted from inventory for {row['id']}")
        if not row["owner_modules"] or not row["owner_stages"]:
            raise ValueError(f"Missing owner/stage for {row['id']}")
        if row["status"] != "translated" and not row.get("skip_reason"):
            raise ValueError(f"Missing skip reason for {row['id']}")
        by_file[row["dart_file"]].append(row)
    existing_files = {str(path.relative_to(ROOT)) for path in OUT.glob("*_ported_test.dart")}
    if existing_files != set(by_file):
        raise ValueError("Dart test file set differs from the manifest")
    found = []
    for relative, rows in by_file.items():
        source = (ROOT / relative).read_text(encoding="utf-8")
        names = TEST_CALL.findall(source)
        expected_names = [row["dart_name"] for row in rows]
        if names != expected_names:
            raise ValueError(f"Dart test names differ from manifest: {relative}")
        parts = TEST_CALL.split(source)
        blocks = {parts[i]: parts[i + 1] for i in range(1, len(parts) - 1, 2)}
        for row in rows:
            body = blocks[row["dart_name"]]
            skipped = bool(re.search(r"\bskip\s*:", DART_TRIVIA.sub(" ", body)))
            if row["status"] == "translated" and skipped:
                raise ValueError(f"Translated test is still skipped: {row['id']}")
            if row["status"] in ("translated", "translated_skipped") and "Dart port not implemented:" in body:
                raise ValueError(f"Translated test still has a placeholder body: {row['id']}")
            if row["status"] == "translated_skipped" and not skipped:
                raise ValueError(f"Translated test awaiting a Dart owner has no skip: {row['id']}")
            if row["status"] in ("pending_port", "scope_exception") and not skipped:
                raise ValueError(f"Untranslated test has no skip: {row['id']}")
            if row["status"] not in ("pending_port", "scope_exception", "translated_skipped", "translated"):
                raise ValueError(f"Unknown mapping status: {row['id']}")
            if row["status"] in ("translated_skipped", "translated"):
                check_contract(row, source, body, inventory)
        found.extend(names)
    if len(found) != 171 or len(set(found)) != 171:
        raise ValueError("Dart test inventory does not contain 171 unique names")
    expected_counts = {
        "total": 171,
        "translated": sum(row["status"] == "translated" for row in actual_rows),
        "translated_skipped": sum(row["status"] == "translated_skipped" for row in actual_rows),
        "pending_port": sum(row["status"] == "pending_port" for row in actual_rows),
        "scope_exception": sum(row["status"] == "scope_exception" for row in actual_rows),
    }
    if actual["counts"] != expected_counts:
        raise ValueError("Manifest status counts are stale")
    print("Mapped {total} tests: {translated} active translations, "
          "{translated_skipped} translated and skipped, {pending_port} pending translations, "
          "{scope_exception} Python-tooling scope exceptions".format(**expected_counts))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--write", action="store_true", help="write the initial skipped Dart skeleton")
    group.add_argument("--check", action="store_true", help="compare AST, mapping and Dart test names")
    parser.add_argument("--force", action="store_true", help="allow overwriting hand-edited Dart tests")
    args = parser.parse_args()
    if args.write:
        write(args.force)
    check()


if __name__ == "__main__":
    main()
