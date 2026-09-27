#!/usr/bin/env python3
"""Regenerate source locators and blank E2E rows; this does not execute tests."""
from __future__ import annotations

import csv
from collections import Counter
import datetime as dt
import hashlib
import json
from pathlib import Path
import re

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
MATRIX = HERE / 'UI-E2E-MATRIX.md'
WIDGET_TYPES = [
    'TextField', 'TextFormField', 'DropdownButtonFormField', 'DropdownButton',
    'PopupMenuButton', 'Slider', 'SwitchListTile', 'Switch', 'ChoiceChip',
    'ActionChip', 'Segmented', 'Pill', 'TextButton', 'IconButton', 'FilledButton',
    'OutlinedButton', 'ElevatedButton', 'NavigationDestination', 'GestureDetector',
    'InkWell', 'Dismissible', 'ExpansionTile', 'ReorderableListView',
    'InteractiveViewer', 'PopScope', 'ListTile',
]
UI_CALLBACKS = [
    'onTap', 'onTapUp', 'onPressed', 'onChanged', 'onSelected', 'onSubmitted',
    'onLongPress', 'onLongPressStart', 'onLongPressMoveUpdate', 'onHorizontalDragEnd',
    'onChangeEnd', 'onReorderItem', 'onDestinationSelected', 'onKeyEvent',
    'onDismissed', 'onPageChanged', 'onPopInvokedWithResult', 'onDot', 'onNotes',
    'onRelationTap', 'onName', 'onLongPressAt',
]
CALLBACK_PATTERN = re.compile(r'\b(' + '|'.join(UI_CALLBACKS) + r')\s*:')
PATTERN = re.compile(r'\b(?:' + '|'.join(WIDGET_TYPES) + r')\b|\b(?:' + '|'.join(UI_CALLBACKS) + r')\s*:')
WIDGET_CONSTRUCTION = re.compile(
    r'\b(' + '|'.join(WIDGET_TYPES) + r')(?:\.\w+)?(?:<[^>]+>)?\s*\((?!\{)'
)
MODULE_CASES = {
    'main.dart': ['A', 'B', 'M', 'X'],
    'shelf_screen.dart': ['A', 'B', 'X'],
    'notes_screen.dart': ['N', 'X'],
    'settings_screen.dart': ['M', 'T', 'B', 'X'],
    'model_settings_screen.dart': ['M', 'X'],
    'reader_screen.dart': ['R', 'T', 'N', 'S', 'C', 'H', 'Q', 'J', 'X'],
    'page_body.dart': ['R', 'H', 'X'],
    'book_sheet.dart': ['A', 'B', 'P', 'N', 'X'],
    'ask_sheet.dart': ['Q', 'X'],
    'marginalia_sheet.dart': ['J', 'X'],
    'manual_entity_editor.dart': ['U', 'X'],
    'note_editor.dart': ['N', 'X'],
    'people_sheet.dart': ['H', 'U', 'G', 'X'],
    'person_sheet.dart': ['H', 'U', 'G', 'X'],
    'graph_view.dart': ['G', 'X'],
    'preview_sheet.dart': ['S', 'C', 'R', 'X'],
    'search_sheet.dart': ['S', 'X'],
    'toc_sheet.dart': ['C', 'N', 'X'],
    'recap_sheet.dart': ['Q', 'X'],
    'typography_sheet.dart': ['T', 'X'],
    'sheet_host.dart': ['A', 'X'],
    'theme.dart': ['X'],
    'cover.dart': ['A', 'P', 'X'],
}
text = MATRIX.read_text()
cases = []
for line in text.splitlines():
    match = re.match(r'^\| ([A-Z]-\d{3}) \| (P[012])([^|]*) \|', line)
    if match:
        cells = [cell.strip() for cell in line.split('|')[1:-1]]
        cases.append({'id': match[1], 'priority': match[2],
                      'precondition': match[3].strip(), 'steps': cells[2],
                      'expected': cells[3], 'status': 'NOT_RUN'})
ids = [case['id'] for case in cases]
if len(ids) != len(set(ids)):
    raise SystemExit('Duplicate case IDs')
if not cases:
    raise SystemExit('No E2E cases found')
files = []
widget_counts = Counter()
callback_counts = Counter()
for path in sorted((ROOT / 'app/lib').rglob('*.dart')):
    if path.parent.name == 'data':
        continue
    raw = path.read_bytes()
    entries = []
    for line_number, line in enumerate(raw.decode().splitlines(), 1):
        matches = [m.group(0).strip() for m in PATTERN.finditer(line)]
        if matches and not line.lstrip().startswith('//'):
            widget_counts.update(WIDGET_CONSTRUCTION.findall(line))
            callback_counts.update(CALLBACK_PATTERN.findall(line))
            entries.append({'line': line_number, 'tokens': matches,
                            'source': line.strip(),
                            'source_link': f'../../{path.relative_to(ROOT)}#L{line_number}'})
    if entries:
        groups = MODULE_CASES.get(path.name, [])
        files.append({'path': str(path.relative_to(ROOT)),
                      'sha256': hashlib.sha256(raw).hexdigest(),
                      'coverage_groups': groups,
                      'case_ids': [x for x in ids if x.split('-')[0] in groups],
                      'locators': entries})
web_sources = [
    'main.js', 'shelf.js', 'reading-list.js', 'notebook-hub.js', 'offline-library.js',
    'model-settings.js', 'readerview.js', 'reader.js', 'views.js', 'graph.js',
    'manual.js', 'marginalia.js', 'notebook.js', 'person.js', 'search.js',
    'source-preview.js', 'panes.js', 'workspace-nav.js',
]
web_files = []
for name in web_sources:
    path = ROOT / 'web/js' / name
    raw = path.read_bytes()
    entries = []
    for n, line in enumerate(raw.decode().splitlines(), 1):
        if re.search(r"h\('(input|textarea|select|button)'|addEventListener\('(click|change|input|submit|keydown)'|onclick:", line):
            entries.append({'line': n, 'source': line.strip(),
                            'source_link': f'../../{path.relative_to(ROOT)}#L{n}'})
    web_files.append({'path': str(path.relative_to(ROOT)),
                      'sha256': hashlib.sha256(raw).hexdigest(),
                      'coverage_groups': ['W'], 'locators': entries})
result = {
    'schema': 1,
    'generated_at_utc': dt.datetime.now(dt.timezone.utc).isoformat(),
    'purpose': 'Source control/input locators and coverage pointers; NOT an executed test result.',
    'matrix_sha256': hashlib.sha256(MATRIX.read_bytes()).hexdigest(),
    'default_execution_status': 'NOT_RUN',
    'case_count': len(cases),
    'count_semantics': 'Lexical source occurrences, not the number of runtime controls. Builders, loops, conditional states and reused helpers create different runtime counts. All controls must still be activated on device.',
    'flutter_widget_construction_counts': dict(sorted(widget_counts.items())),
    'flutter_callback_argument_counts': dict(sorted(callback_counts.items())),
    'flutter_locator_line_count': sum(len(item['locators']) for item in files),
    'web_locator_line_count': sum(len(item['locators']) for item in web_files),
    'flutter_text_field_count': sum('TextField' in row['tokens'] for item in files for row in item['locators']),
    'flutter_files': files,
    'web_files': web_files,
    'cases': cases,
}
(HERE / 'ui-interaction-inventory.json').write_text(
    json.dumps(result, ensure_ascii=False, indent=2) + '\n'
)
with (HERE / 'ui-e2e-results-template.csv').open('w', newline='') as stream:
    columns = ['case_id', 'priority', 'platform', 'variant', 'build', 'fixture',
               'status', 'actual', 'visual_evidence', 'durable_or_network_evidence',
               'supporting_automated_evidence', 'defect_id', 'tester', 'executed_at']
    writer = csv.DictWriter(stream, fieldnames=columns, lineterminator='\n')
    writer.writeheader()
    for case in cases:
        writer.writerow({'case_id': case['id'], 'priority': case['priority'],
                         'platform': 'W/S' if case['id'].startswith('W-') else 'A',
                         'status': 'NOT_RUN'})
summary = [
    '# UI source control inventory', '',
    'Generated by `generate-ui-inventory.py`. Source locator counts only; no UI test was executed.', '',
    f'Base E2E cases: **{len(cases)}**. Editable Flutter text fields: **{result["flutter_text_field_count"]}**.', '',
    result['count_semantics'], '',
    'The 12 field audit and full control/option checklist are in [UI-E2E-MATRIX.md](UI-E2E-MATRIX.md).',
    'Source paths, exact line numbers, source hashes, and case pointers are in [ui-interaction-inventory.json](ui-interaction-inventory.json).', '',
    '## Flutter widget construction occurrences', '',
    '| Source widget category | Occurrences |', '|---|---:|',
    *[f'| `{kind}` | {count} |' for kind, count in sorted(widget_counts.items())], '',
    'Counts are lexical constructors, not the number of visible controls. A single ChoiceChip constructor in a loop creates five persona choices; a shared Pill constructor can create many state-dependent actions. Static ListTile instances may have no action. An inventory cannot prove exhaustive execution.', '',
    '## Flutter interaction callback argument occurrences', '',
    '| Callback | Occurrences |', '|---|---:|',
    *[f'| `{kind}` | {count} |' for kind, count in sorted(callback_counts.items())], '',
    '## Source files and matrix groups', '',
    '| File | Locator lines | Case groups |', '|---|---:|---|',
    *[f'| [{item["path"]}](../../{item["path"]}) | {len(item["locators"])} | {", ".join(item["coverage_groups"])} |' for item in files], '',
    f'Web inventory: {len(web_files)} selected source files, {result["web_locator_line_count"]} locator lines. The web-specific W cases identify its extra login/sync/offline controls; web source coverage is explicitly separate from Flutter.', '',
    'Rerun this generator after source changes. Review new controls manually, add case IDs, and expand all state/option variants before claiming complete UI regression.', '',
]
(HERE / 'UI-CONTROL-INVENTORY.md').write_text('\n'.join(summary))
print(f"已生成 {len(cases)} 个待执行用例；Flutter 输入框 {result['flutter_text_field_count']} 个；没有执行 UI 测试。")
