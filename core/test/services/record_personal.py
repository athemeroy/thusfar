"""Record native personal-service expectations from the unchanged Python oracle."""
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from server import notebook, reading_list, model_settings

BOOK = {"title": "Fixture", "len": 30, "blocks": [
    {"k": "p", "t": "😀Alice met Bob.", "o": 0},
    {"k": "h", "t": "Next", "o": 20},
    {"k": "img", "t": "image", "o": 25},
]}
NOTE = {"id": "note-test-01", "kind": "note", "start": 2, "end": 7,
        "quote": "Alice", "text": "Thought", "knowledge_cutoff": 15,
        "operation": "operation-01", "expected_revision": 0}
rows = []


def record(operation, args, **extra):
    row = {"operation": operation, "args": copy.deepcopy(args), **extra}
    try:
        with patch("time.time", return_value=1000.25):
            if operation == "notebook.apply": value = notebook.apply(*args)
            elif operation == "notebook.validate": value = notebook.validate(*args)
            elif operation == "notebook.restore": value = notebook.restore(*args)
            elif operation == "notebook.source_quote": value = notebook.source_quote(*args)
            elif operation == "reading_list.apply":
                value = reading_list.apply(*args, visible=lambda bid: bid in extra["visible"])
            elif operation == "model_settings.normalize": value = model_settings.normalize(*args)
            else: raise AssertionError(operation)
        row["result"] = value
    except Exception as error:
        row["error"] = {"type": type(error).__name__, "message": str(error)}
    rows.append(row)


record("notebook.validate", [NOTE, BOOK])
for change in [
    {"id": "bad"}, {"id": 12345678}, {"kind": "unknown"},
    {"start": True}, {"start": -1}, {"start": 1}, {"end": 31},
    {"quote": "Wrong"}, {"quote": None}, {"text": None},
    {"knowledge_cutoff": 6}, {"knowledge_cutoff": 31},
    {"text": "🙂" * 10000}, {"text": "a" * 10001},
    {"deleted": 1}, {"deleted": True},
    {"start": 0, "end": 0, "quote": "", "text": "\u001c"},
    {"kind": "bookmark", "start": 30, "end": 30, "quote": "", "text": ""},
]: record("notebook.validate", [NOTE | change, BOOK])
for start, end in [(0, 2), (1, 2), (0, 1), (0, 7), (2, 7), (15, 20), (20, 24), (25, 30), (30, 30)]:
    record("notebook.source_quote", [BOOK, start, end])
with patch("time.time", return_value=999.0):
    initial, old, _ = notebook.apply([], NOTE, BOOK)
for items, note in [
    ([], NOTE), (initial, NOTE),
    (initial, NOTE | {"operation": "operation-02"}),
    (initial, NOTE | {"operation": "operation-02", "expected_revision": 1, "text": "Edited"}),
    (initial, NOTE | {"id": "note-test-02", "operation": "operation-02"}),
    (initial, NOTE | {"operation": "operation-02", "expected_revision": 1, "deleted": True}),
    ([], NOTE | {"operation": "bad"}), ([], NOTE | {"expected_revision": True}),
]: record("notebook.apply", [items, note, BOOK])
for items in [[], initial, [NOTE], [NOTE, NOTE], None,
              [NOTE | {"created": True}], [NOTE | {"updated": -1}],
              [NOTE | {"revision": 0}], [NOTE | {"operation": None}],
              [NOTE | {"created": 1, "updated": 2.5}],
              [NOTE | {"operation": "🙂" * 90}]]:
    record("notebook.restore", [items, BOOK])

current = reading_list.empty()
request = {"items": ["two", "one"], "operation": "list-operation-01", "expected_revision": 0}
with patch("time.time", return_value=999.0):
    saved, _ = reading_list.apply(current, request, lambda bid: True)
for state, change, visible in [
    (current, {}, ["one", "two"]), (saved, {}, []),
    (saved, {"items": ["one"]}, ["one"]),
    (saved, {"operation": "list-operation-02"}, []),
    (saved, {"operation": "list-operation-02", "expected_revision": 1, "items": ["one", "two"]}, []),
    (current, {"items": ["missing"]}, []),
    *[(current, {"items": items}, ["one"]) for items in [["one", "one"], ["../one"], [True], "one", ["one"]*201]],
    *[(current, {"expected_revision": rev}, ["one", "two"]) for rev in [True, -1, 0.5, None]],
    (current, {"operation": "bad"}, ["one", "two"]),
]: record("reading_list.apply", [state, request | change], visible=visible)
for url, model in [
    ("https://example.invalid", "test-model"),
    (" https://example.invalid/v1/ ", " deepseek-test "),
    ("https://example.invalid/proxy/v1", "DeepSeek-Test"),
    ("https://example.invalid/v1", "deepseek-test+think"),
]: record("model_settings.normalize", [url, model])

target = Path(__file__).with_name("fixtures") / "personal.json"
target.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + "\n")
print(f"Recorded {len(rows)} Python reference cases")
