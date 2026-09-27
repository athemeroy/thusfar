"""Replay deterministic personal-service inputs into the common golden harness."""
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
from oracle.record.common import canonical, encode, require_reference_runtime
from server import manual_entities, notebook, reading_list


def main():
    require_reference_runtime()
    out = []
    modules = {'notebook': notebook, 'reading_list': reading_list}
    for index, row in enumerate(json.loads((ROOT / 'core/test/services/fixtures/personal.json').read_text())):
        operation = row['operation']
        if operation not in ('notebook.apply', 'notebook.restore', 'reading_list.apply'):
            continue
        args = copy.deepcopy(row['args'])
        module, function = operation.split('.')
        if operation == 'reading_list.apply':
            value_input = {'current': args[0], 'payload': args[1], 'visible': row['visible'], 'now': 1000.25}
            args.append(lambda bid, visible=row['visible']: bid in visible)
        elif operation == 'notebook.apply':
            value_input = {'items': args[0], 'item': args[1], 'book': args[2], 'now': 1000.25}
        else:
            value_input = {'items': args[0], 'book': args[1], 'now': 1000.25}
        with patch('time.time', return_value=1000.25):
            try:
                result = getattr(modules[module], function)(*args)
            except Exception as error:
                result = error
        out.append({'schema': 1, 'function': 'server.' + operation,
                    'case': f'personal_service_{index:03}', 'input': encode(value_input), 'output': encode(result)})

    manual = json.loads((ROOT / 'core/test/manual_entities/fixtures/python.json').read_text())
    for index, row in enumerate(manual['cases']):
        if row['function'] != 'apply':
            continue
        args = copy.deepcopy(row['args'])
        value_input = dict(zip(('items', 'payload', 'book', 'graph'), args)) | {'now': 1234.5}
        with patch('time.time', return_value=1234.5):
            try:
                result = manual_entities.apply(*args)
            except Exception as error:
                result = error
        out.append({'schema': 1, 'function': 'server.manual_entities.apply',
                    'case': f'personal_service_{index:03}', 'input': encode(value_input), 'output': encode(result)})
    target = ROOT / 'oracle/goldens/special/personal_service_cases.jsonl'
    target.write_text(''.join(canonical(row) + '\n' for row in out))
    print(f'Recorded {len(out)} Python personal-service golden cases')


if __name__ == '__main__':
    main()
