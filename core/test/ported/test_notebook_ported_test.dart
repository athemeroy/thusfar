// Generated from docs/port/inventory.json by core/tool/generate_ported_tests.py.
// Skipped failing callbacks are unported assertions, not translations.
import 'package:test/test.dart';

void main() {
  test(
    "tests.test_notebook.NotebookHTTP.test_idempotency_conflict_and_independent_notes",
    () => fail(
      "Dart port not implemented: tests.test_notebook.NotebookHTTP.test_idempotency_conflict_and_independent_notes",
    ),
    skip:
        "Dart implementation of server.app, server.notebook is pending (A6); required to check 'idempotency conflict and independent notes'.",
  );
  test(
    "tests.test_notebook.NotebookHTTP.test_anchors_reject_fabricated_quote_surrogate_split_and_future_bounds",
    () => fail(
      "Dart port not implemented: tests.test_notebook.NotebookHTTP.test_anchors_reject_fabricated_quote_surrogate_split_and_future_bounds",
    ),
    skip:
        "Dart implementation of server.app.cached_json, server.app.wjson is pending (A6); required to check 'anchors reject fabricated quote surrogate split and future bounds'.",
  );
  test(
    "tests.test_notebook.NotebookHTTP.test_export_import_preserves_notes_and_refuses_different_personal_records",
    () => fail(
      "Dart port not implemented: tests.test_notebook.NotebookHTTP.test_export_import_preserves_notes_and_refuses_different_personal_records",
    ),
    skip:
        "Dart implementation of server.app, server.notebook is pending (A6); required to check 'export import preserves notes and refuses different personal records'.",
  );
  test(
    "tests.test_notebook.NotebookHTTP.test_delete_tombstone_markdown_and_book_removal_preserve_personal_data",
    () => fail(
      "Dart port not implemented: tests.test_notebook.NotebookHTTP.test_delete_tombstone_markdown_and_book_removal_preserve_personal_data",
    ),
    skip:
        "Dart implementation of server.app, server.notebook is pending (A6); required to check 'delete tombstone markdown and book removal preserve personal data'.",
  );
}
