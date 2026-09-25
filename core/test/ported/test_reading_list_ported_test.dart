// Generated from docs/port/inventory.json by core/tool/generate_ported_tests.py.
// Skipped failing callbacks are unported assertions, not translations.
import 'package:test/test.dart';

void main() {
  test(
    "tests.test_reading_list.ReadingListHTTP.test_order_receipt_conflict_and_no_progress_inference",
    () => fail(
      "Dart port not implemented: tests.test_reading_list.ReadingListHTTP.test_order_receipt_conflict_and_no_progress_inference",
    ),
    skip:
        "Dart implementation of server.app is pending (A6); required to check 'order receipt conflict and no progress inference'.",
  );
  test(
    "tests.test_reading_list.ReadingListHTTP.test_concurrent_reorders_have_exactly_one_winner",
    () => fail(
      "Dart port not implemented: tests.test_reading_list.ReadingListHTTP.test_concurrent_reorders_have_exactly_one_winner",
    ),
    skip:
        "Dart implementation of server.app is pending (A6); required to check 'concurrent reorders have exactly one winner'.",
  );
  test(
    "tests.test_reading_list.ReadingListHTTP.test_unavailable_slots_preserved_but_new_hidden_or_missing_books_rejected",
    () => fail(
      "Dart port not implemented: tests.test_reading_list.ReadingListHTTP.test_unavailable_slots_preserved_but_new_hidden_or_missing_books_rejected",
    ),
    skip:
        "Dart implementation of server.app.wjson is pending (A6); required to check 'unavailable slots preserved but new hidden or missing books rejected'.",
  );
  test(
    "tests.test_reading_list.ReadingListHTTP.test_bad_payload_never_creates_state",
    () => fail(
      "Dart port not implemented: tests.test_reading_list.ReadingListHTTP.test_bad_payload_never_creates_state",
    ),
    skip:
        "Dart implementation of server.app is pending (A6); required to check 'bad payload never creates state'.",
  );
}
