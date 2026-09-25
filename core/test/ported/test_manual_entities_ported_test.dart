// Generated from docs/port/inventory.json by core/tool/generate_ported_tests.py.
// Skipped failing callbacks are unported assertions, not translations.
import 'package:test/test.dart';

void main() {
  test(
    "tests.test_manual_entities.ManualRules.test_utf16_anchor_and_versions_do_not_spoil_earlier_pages",
    () => fail(
      "Dart port not implemented: tests.test_manual_entities.ManualRules.test_utf16_anchor_and_versions_do_not_spoil_earlier_pages",
    ),
    skip:
        "Dart implementation of server.manual_entities.apply, server.manual_entities.restore, server.manual_entities.rows is pending (A6); required to check 'utf16 anchor and versions do not spoil earlier pages'.",
  );
  test(
    "tests.test_manual_entities.ManualRules.test_existing_visible_name_is_not_duplicated",
    () => fail(
      "Dart port not implemented: tests.test_manual_entities.ManualRules.test_existing_visible_name_is_not_duplicated",
    ),
    skip:
        "Dart implementation of server.manual_entities.apply is pending (A6); required to check 'existing visible name is not duplicated'.",
  );
  test(
    "tests.test_manual_entities.ManualRules.test_name_must_be_in_already_read_source",
    () => fail(
      "Dart port not implemented: tests.test_manual_entities.ManualRules.test_name_must_be_in_already_read_source",
    ),
    skip:
        "Dart implementation of server.manual_entities.apply is pending (A6); required to check 'name must be in already read source'.",
  );
  test(
    "tests.test_manual_entities.ManualRules.test_inline_mentions_preserve_generated_names_and_utf16_positions",
    () => fail(
      "Dart port not implemented: tests.test_manual_entities.ManualRules.test_inline_mentions_preserve_generated_names_and_utf16_positions",
    ),
    skip:
        "Dart implementation of server.manual_entities.mentions is pending (A6); required to check 'inline mentions preserve generated names and utf16 positions'.",
  );
  test(
    "tests.test_manual_entities.ManualHTTP.test_manual_endpoint_cutoff_retry_export_and_delete",
    () => fail(
      "Dart port not implemented: tests.test_manual_entities.ManualHTTP.test_manual_endpoint_cutoff_retry_export_and_delete",
    ),
    skip:
        "Dart implementation of server.manual_entities is pending (A6); required to check 'manual endpoint cutoff retry export and delete'.",
  );
}
