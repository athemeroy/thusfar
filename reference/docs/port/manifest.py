"""Initialize and validate the Dart port ledger against the frozen AST inventory."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

from docs.port.generate_inventory import STAGE_BY_MODULE


ROOT = Path(__file__).resolve().parents[2]
INVENTORY = ROOT / "docs" / "port" / "inventory.json"
MANIFEST = ROOT / "docs" / "port" / "MANIFEST.yaml"
STATUSES = {"pending_port", "golden_passed", "not_ported"}


def stage_for(row: dict) -> str:
    module = row["module"]
    if module == "server.storage":
        return "A1" if row["category"] == "纯函数" else "A6"
    if module == "pipeline.classify":
        return "A4" if row["category"] == "模型调用" else "A2"
    return STAGE_BY_MODULE[module].split("/")[0]


def inventory_rows() -> list[dict]:
    return json.loads(INVENTORY.read_text(encoding="utf-8"))["functions"]


def initialize() -> None:
    if MANIFEST.exists():
        raise FileExistsError(f"Refusing to overwrite port progress: {MANIFEST}")
    lines = [
        "schema: 1",
        "oracle: python-1.7.5",
        "inventory: docs/port/inventory.json",
        "tests_manifest: core/test/ported/manifest.json",
        "functions:",
    ]
    for row in inventory_rows():
        stage = stage_for(row)
        lines.extend((
            f"  - id: {row['id']}",
            f"    stage: {stage}",
            "    status: pending_port",
            "    dart_symbol: null",
            f"    reason: {json.dumps(f'Stage {stage} has not started')}",
        ))
    MANIFEST.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Initialized {len(inventory_rows())} function entries")


def parse() -> dict:
    """Parse the intentionally narrow human-editable YAML ledger without PyYAML."""
    result: dict = {"functions": []}
    current: dict | None = None
    for number, raw in enumerate(MANIFEST.read_text(encoding="utf-8").splitlines(), 1):
        if not raw or raw.lstrip().startswith("#"):
            continue
        if raw == "functions:":
            continue
        match = re.fullmatch(r"(  - |    |)([a-z_]+): (.*)", raw)
        if not match:
            raise ValueError(f"MANIFEST.yaml:{number}: unsupported YAML syntax")
        prefix, key, text = match.groups()
        value = None if text == "null" else json.loads(text) if text.startswith('"') else text
        if prefix == "  - ":
            if key != "id":
                raise ValueError(f"MANIFEST.yaml:{number}: list item must begin with id")
            current = {"id": value}
            result["functions"].append(current)
        elif prefix == "    ":
            if current is None:
                raise ValueError(f"MANIFEST.yaml:{number}: field without function")
            current[key] = value
        else:
            result[key] = int(value) if key == "schema" else value
    return result


def check() -> None:
    manifest = parse()
    if manifest.get("schema") != 1 or manifest.get("oracle") != "python-1.7.5":
        raise ValueError("Manifest schema or Python oracle version differs")
    if manifest.get("tests_manifest") != "core/test/ported/manifest.json":
        raise ValueError("Test ledger path differs")
    rows = manifest["functions"]
    found = [row.get("id") for row in rows]
    expected = [row["id"] for row in inventory_rows()]
    if found != expected:
        raise ValueError("Function list differs from AST inventory or is reordered")
    for row, inventory in zip(rows, inventory_rows()):
        if row.get("stage") != stage_for(inventory):
            raise ValueError(f"Wrong stage for {row['id']}")
        status = row.get("status")
        if status not in STATUSES:
            raise ValueError(f"Invalid status for {row['id']}")
        if status == "golden_passed" and not row.get("dart_symbol"):
            raise ValueError(f"Missing Dart symbol for {row['id']}")
        if status != "golden_passed" and not row.get("reason"):
            raise ValueError(f"Missing reason for {row['id']}")
    print(f"Validated {len(rows)} function entries; "
          f"passed={sum(row['status'] == 'golden_passed' for row in rows)}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--init", action="store_true")
    actions.add_argument("--check", action="store_true")
    actions.add_argument("--list-pending", action="store_true")
    args = parser.parse_args()
    if args.init:
        initialize()
    else:
        check()
        if args.list_pending:
            for row in parse()["functions"]:
                if row["status"] == "pending_port":
                    print(f"{row['stage']} {row['id']}: {row['reason']}")


if __name__ == "__main__":
    main()
