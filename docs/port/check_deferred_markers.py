"""Reject unresolved implementation markers in tracked source files.

Deferred work belongs in MANIFEST.yaml with a reason and owning stage.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[2]
SOURCE_SUFFIXES = {".dart", ".py", ".js", ".mjs", ".kt", ".java", ".sh"}
MARKERS = tuple(("TO" + "DO", "FIX" + "ME", "HA" + "CK"))
PATTERN = re.compile(r"(?<![A-Za-z0-9_])(?:" + "|".join(MARKERS) + r")(?![A-Za-z0-9_])")


def find_markers(paths: Iterable[Path]) -> list[str]:
    failures = []
    for path in paths:
        if path.suffix not in SOURCE_SUFFIXES:
            continue
        for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if PATTERN.search(line):
                failures.append(f"{path}:{number}: unresolved implementation marker")
    return failures


def tracked_sources() -> list[Path]:
    result = subprocess.run(
        ["git", "ls-files", "-z"], cwd=ROOT, check=True, capture_output=True
    )
    return [ROOT / name.decode("utf-8") for name in result.stdout.split(b"\0") if name]


def main() -> None:
    failures = find_markers(tracked_sources())
    if failures:
        raise SystemExit("\n".join(failures))
    print("Tracked source files contain no unresolved implementation markers")


if __name__ == "__main__":
    main()
