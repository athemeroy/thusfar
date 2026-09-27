"""Mark inventory functions as ported in MANIFEST.yaml: mark.py STATUS SYMBOL_PREFIX ID..."""
from __future__ import annotations

import re
import sys
from pathlib import Path

MANIFEST = Path(__file__).resolve().parent / 'MANIFEST.yaml'


def main() -> None:
    status, reason, ids = sys.argv[1], sys.argv[2], set(sys.argv[3:])
    lines = MANIFEST.read_text(encoding='utf-8').splitlines()
    current = None
    found = set()
    for i, line in enumerate(lines):
        m = re.match(r'  - id: (\S+)$', line)
        if m:
            current = m.group(1)
            continue
        if current in ids:
            found.add(current)
            if line.startswith('    status: '):
                lines[i] = f'    status: {status}'
            elif line.startswith('    reason: '):
                lines[i] = f'    reason: "{reason}"'
            elif line.startswith('    dart_symbol: '):
                lines[i] = f'    dart_symbol: "{current}"'
    missing = ids - found
    if missing:
        raise SystemExit(f'unknown ids: {sorted(missing)}')
    MANIFEST.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    print(f'marked {len(found)} as {status}')


if __name__ == '__main__':
    main()
