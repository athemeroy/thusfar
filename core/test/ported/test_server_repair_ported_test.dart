// Generated from docs/port/inventory.json by core/tool/generate_ported_tests.py.
// Some callbacks contain translated assertions but remain skipped until their Dart owners exist.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'contract_invoker.dart';

void main() {
  test(
    "tests.test_server_repair.HTTPRepair.test_old_epub_without_language_gets_english_shelf_estimate",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_old_epub_without_language_gets_english_shelf_estimate",
    ),
    skip:
        "Dart implementation of server.app.wjson, server.storage.shelf_metadata, server.storage.signature is pending (A1/A6, A5, A6); required to check 'old epub without language gets english shelf estimate'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_upload_never_calls_judge_and_concurrent_same_upload_is_idempotent",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_upload_never_calls_judge_and_concurrent_same_upload_is_idempotent",
    ),
    skip:
        "Dart implementation of server.app, server.ask, server.jobs, server.storage, server.temporal is pending (A1/A6, A5, A6); required to check 'upload never calls judge and concurrent same upload is idempotent'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_export_import_preserves_images_graph_progress_and_snapshot_state",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_export_import_preserves_images_graph_progress_and_snapshot_state",
    ),
    skip:
        "Dart implementation of server.app.wjson is pending (A1/A6, A5, A6); required to check 'export import preserves images graph progress and snapshot state'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_import_rejects_bad_hash_and_unsorted_graph_without_publication",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_import_rejects_bad_hash_and_unsorted_graph_without_publication",
    ),
    skip:
        "Dart implementation of server.app, server.ask, server.jobs, server.storage, server.temporal is pending (A1/A6, A5, A6); required to check 'import rejects bad hash and unsorted graph without publication'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_legacy_text_export_import_works_but_missing_images_are_explicit",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_legacy_text_export_import_works_but_missing_images_are_explicit",
    ),
    skip:
        "Dart implementation of server.app, server.ask, server.jobs, server.storage, server.temporal is pending (A1/A6, A5, A6); required to check 'legacy text export import works but missing images are explicit'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_conflicting_snapshot_is_not_silently_reused_or_overwritten",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_conflicting_snapshot_is_not_silently_reused_or_overwritten",
    ),
    skip:
        "Dart implementation of server.app, server.ask, server.jobs, server.storage, server.temporal is pending (A1/A6, A5, A6); required to check 'conflicting snapshot is not silently reused or overwritten'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_negative_length_and_transfer_encoding_rejected",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_negative_length_and_transfer_encoding_rejected",
    ),
    skip:
        "Dart implementation of server.app, server.ask, server.jobs, server.storage, server.temporal is pending (A1/A6, A5, A6); required to check 'negative length and transfer encoding rejected'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_malformed_json_shape_and_expensive_request_admission",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_malformed_json_shape_and_expensive_request_admission",
    ),
    skip:
        "Dart implementation of server.app, server.ask, server.jobs, server.storage, server.temporal is pending (A1/A6, A5, A6); required to check 'malformed json shape and expensive request admission'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_slow_incomplete_body_has_deadline",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_slow_incomplete_body_has_deadline",
    ),
    skip:
        "Dart implementation of server.app, server.ask, server.jobs, server.storage, server.temporal is pending (A1/A6, A5, A6); required to check 'slow incomplete body has deadline'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_static_sibling_cannot_escape_root",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_static_sibling_cannot_escape_root",
    ),
    skip:
        "Dart implementation of server.app, server.ask, server.jobs, server.storage, server.temporal is pending (A1/A6, A5, A6); required to check 'static sibling cannot escape root'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_static_revalidation_and_compression",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_static_revalidation_and_compression",
    ),
    skip:
        "Dart implementation of server.app, server.ask, server.jobs, server.storage, server.temporal is pending (A1/A6, A5, A6); required to check 'static revalidation and compression'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_byline_in_file_name_is_shown_as_title_and_author",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_byline_in_file_name_is_shown_as_title_and_author",
    ),
    skip:
        "Dart implementation of server.app.wjson, server.storage.display_title is pending (A1/A6, A5, A6); required to check 'byline in file name is shown as title and author'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_optimistic_progress_does_not_overwrite_other_device",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_optimistic_progress_does_not_overwrite_other_device",
    ),
    skip:
        "Dart implementation of server.app, server.ask, server.jobs, server.storage, server.temporal is pending (A1/A6, A5, A6); required to check 'optimistic progress does not overwrite other device'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_explicit_process_queues_completed_pending_quality",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_explicit_process_queues_completed_pending_quality",
    ),
    skip:
        "Dart implementation of server.app.cached_json, server.app.wjson is pending (A1/A6, A5, A6); required to check 'explicit process queues completed pending quality'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_progress_end_cutoff_reaches_100_without_losing_resume_anchor",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_progress_end_cutoff_reaches_100_without_losing_resume_anchor",
    ),
    skip:
        "Dart implementation of server.app, server.ask, server.jobs, server.storage, server.temporal is pending (A1/A6, A5, A6); required to check 'progress end cutoff reaches 100 without losing resume anchor'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_cookie_is_secure_expiring_and_authentication_required",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_cookie_is_secure_expiring_and_authentication_required",
    ),
    skip:
        "Dart implementation of server.app, server.ask, server.jobs, server.storage, server.temporal is pending (A1/A6, A5, A6); required to check 'cookie is secure expiring and authentication required'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_health_disabled_worker_and_manifest_revision",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_health_disabled_worker_and_manifest_revision",
    ),
    skip:
        "Dart implementation of server.app.wjson is pending (A1/A6, A5, A6); required to check 'health disabled worker and manifest revision'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_delete_busy_external_book_refuses_and_keeps_content",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_delete_busy_external_book_refuses_and_keeps_content",
    ),
    skip:
        "Dart implementation of server.jobs.book_lease is pending (A1/A6, A5, A6); required to check 'delete busy external book refuses and keeps content'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_delete_archives_data_and_clears_progress",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_delete_archives_data_and_clears_progress",
    ),
    skip:
        "Dart implementation of server.app.progress_all, server.app.wjson is pending (A1/A6, A5, A6); required to check 'delete archives data and clears progress'.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_shelf_uses_small_metadata_and_reflects_book_updates",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.HTTPRepair.test_shelf_uses_small_metadata_and_reflects_book_updates",
    ),
    skip:
        "Dart implementation of server.app.wjson is pending (A1/A6, A5, A6); required to check 'shelf uses small metadata and reflects book updates'.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_shared_temporal_contract",
    () {
      final fixture =
          jsonDecode(File('../tests/temporal-fixtures.json').readAsStringSync())
              as Map<String, Object?>;
      for (final rawCase in fixture['cases']! as List<Object?>) {
        final caseData = rawCase! as Map<String, Object?>;
        final result =
            callPorted('server.temporal.fold', {
                  'log': caseData['records'],
                  'pos': caseData['cutoff'],
                })
                as Map<String, Object?>;
        final rels =
            (result['rels']! as Map<String, Object?>).values
                .cast<Map<String, Object?>>()
                .toList();
        final expected =
            (caseData['expected_rels']! as List<Object?>)
                .cast<Map<String, Object?>>();
        expect(
          rels.length,
          expected.length,
          reason: caseData['name'] as String,
        );
        for (var i = 0; i < expected.length; i++) {
          expect(
            {for (final key in expected[i].keys) key: rels[i][key]},
            expected[i],
            reason: caseData['name'] as String,
          );
        }
      }
    },
    skip:
        "Dart implementation of server.temporal.fold is pending (A1/A6, A5, A6); required to check 'shared temporal contract'.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_early_and_merged_latest_attributes_preserved",
    () {
      final log = [
        {'t': 'attr', 'p': 1, 'id': 'a', 'key': 'job', 'value': 'teacher'},
        {'t': 'person', 'p': 2, 'id': 'a', 'name': 'Alice'},
        {'t': 'person', 'p': 3, 'id': 'b', 'name': 'Alias'},
        {'t': 'attr', 'p': 4, 'id': 'b', 'key': 'job', 'value': 'writer'},
        {'t': 'merge', 'p': 5, 'from': 'b', 'into': 'a'},
      ];
      Object? jobAt(int pos) {
        final result =
            callPorted('server.temporal.fold', {'log': log, 'pos': pos})
                as Map<String, Object?>;
        final people = result['people']! as Map<String, Object?>;
        final alice = people['a']! as Map<String, Object?>;
        final attrs = alice['attrs']! as Map<String, Object?>;
        return attrs['job'];
      }

      expect(jobAt(2), 'teacher');
      expect(jobAt(5), 'writer');
    },
    skip:
        "Dart implementation of server.temporal.fold is pending (A1/A6, A5, A6); required to check 'early and merged latest attributes preserved'.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_failed_guard_never_publishes_rejected_prose",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.QualityRepair.test_failed_guard_never_publishes_rejected_prose",
    ),
    skip:
        "Dart implementation of server.ask.answer is pending (A1/A6, A5, A6); required to check 'failed guard never publishes rejected prose'.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_ended_relationship_is_explicitly_historical_in_answer_evidence",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.QualityRepair.test_ended_relationship_is_explicitly_historical_in_answer_evidence",
    ),
    skip:
        "Dart implementation of server.ask.answer is pending (A1/A6, A5, A6); required to check 'ended relationship is explicitly historical in answer evidence'.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_multilingual_fallback_and_query_translation",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.QualityRepair.test_multilingual_fallback_and_query_translation",
    ),
    skip:
        "Dart implementation of server.ask.retrieval_query, server.ask.retrieve is pending (A1/A6, A5, A6); required to check 'multilingual fallback and query translation'.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_pronoun_exact_span_and_local_candidate",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.QualityRepair.test_pronoun_exact_span_and_local_candidate",
    ),
    skip:
        "Dart implementation of server.ask.who_is is pending (A1/A6, A5, A6); required to check 'pronoun exact span and local candidate'.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_cache_budget_and_corruption_visibility",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.QualityRepair.test_cache_budget_and_corruption_visibility",
    ),
    skip:
        "Dart implementation of server.storage.JsonCache.__init__, server.storage.write_json is pending (A1/A6, A5, A6); required to check 'cache budget and corruption visibility'.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_concurrent_cache_read_parses_one_body",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.QualityRepair.test_concurrent_cache_read_parses_one_body",
    ),
    skip:
        "Dart implementation of server.storage.JsonCache.__init__, server.storage.write_json is pending (A1/A6, A5, A6); required to check 'concurrent cache read parses one body'.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_worker_cancel_owned_process_and_spawn_error_cleanup",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.QualityRepair.test_worker_cancel_owned_process_and_spawn_error_cleanup",
    ),
    skip:
        "Dart implementation of server.jobs.Worker.__init__, server.storage.JsonCache.__init__, server.storage.write_json is pending (A1/A6, A5, A6); required to check 'worker cancel owned process and spawn error cleanup'.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_worker_loop_survives_spawn_failure",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.QualityRepair.test_worker_loop_survives_spawn_failure",
    ),
    skip:
        "Dart implementation of server.jobs.Worker.__init__, server.storage.JsonCache.__init__, server.storage.write_json is pending (A1/A6, A5, A6); required to check 'worker loop survives spawn failure'.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_quality_retry_requires_explicit_request_and_survives_launch_failure",
    () => fail(
      "Dart port not implemented: tests.test_server_repair.QualityRepair.test_quality_retry_requires_explicit_request_and_survives_launch_failure",
    ),
    skip:
        "Dart implementation of server.jobs.Worker.__init__, server.storage.JsonCache.__init__, server.storage.write_json is pending (A1/A6, A5, A6); required to check 'quality retry requires explicit request and survives launch failure'.",
  );
}
