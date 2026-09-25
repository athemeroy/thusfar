// Generated from docs/port/inventory.json by core/tool/generate_ported_tests.py.
// Skipped failing callbacks are unported assertions, not translations.
import 'package:test/test.dart';

import 'contract_invoker.dart';

List<Object?> _quarantine(
  List<Map<String, Object?>> records,
  List<List<Object?>> mentions,
  Map<String, int> seeds,
) =>
    (callPorted('pipeline.kg.quarantine_identities', {
              'records': records,
              'mentions': mentions,
              'seeds': seeds,
            })
            as Map<String, Object?>)['\$tuple']
        as List<Object?>;

void main() {
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_relation_status_survives_conversion_and_kg",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_relation_status_survives_conversion_and_kg",
    ),
    skip:
        "Dart implementation of pipeline.extract.segments, pipeline.kg.KG.__init__, pipeline.link.to_classic is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'relation status survives conversion and kg'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_short_identity_reveal_and_unicode_entry",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_short_identity_reveal_and_unicode_entry",
    ),
    skip:
        "Dart implementation of pipeline.extract.segments, pipeline.kg.KG.__init__ is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'short identity reveal and unicode entry'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_merge_between_existing_people_does_not_rewrite_past",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_merge_between_existing_people_does_not_rewrite_past",
    ),
    skip:
        "Dart implementation of pipeline.kg.KG.__init__ is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'merge between existing people does not rewrite past'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_judge_relation_uses_evidence_frontier",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_judge_relation_uses_evidence_frontier",
    ),
    skip:
        "Dart implementation of pipeline.link.to_classic is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'judge relation uses evidence frontier'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_missing_facets_propagate_for_retry",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_missing_facets_propagate_for_retry",
    ),
    skip:
        "Dart implementation of pipeline.judge.relations_by_judge is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'missing facets propagate for retry'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_relation_judge_receives_character_memory_but_requires_current_evidence",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_relation_judge_receives_character_memory_but_requires_current_evidence",
    ),
    skip:
        "Dart implementation of pipeline.judge.family_questions, pipeline.judge.relations_by_judge is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'relation judge receives character memory but requires current evidence'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_relation_memory_keeps_biography_events_and_existing_ties",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_relation_memory_keeps_biography_events_and_existing_ties",
    ),
    skip:
        "Dart implementation of pipeline.classify, pipeline.extract, pipeline.judge, pipeline.kg, pipeline.link, pipeline.llm, pipeline.parse, pipeline.provenance, pipeline.run is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'relation memory keeps biography events and existing ties'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_critical_outage_keeps_extraction_and_does_not_publish",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_critical_outage_keeps_extraction_and_does_not_publish",
    ),
    skip:
        "Dart implementation of pipeline.link.to_classic is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'critical outage keeps extraction and does not publish'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_biography_order_and_unchecked_publication",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_biography_order_and_unchecked_publication",
    ),
    skip:
        "Dart implementation of pipeline.classify, pipeline.extract, pipeline.judge, pipeline.kg, pipeline.link, pipeline.llm, pipeline.parse, pipeline.provenance, pipeline.run is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'biography order and unchecked publication'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_complete_replay_is_model_free_and_preserves_final_decisions",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_complete_replay_is_model_free_and_preserves_final_decisions",
    ),
    skip:
        "Dart implementation of pipeline.link.to_classic is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'complete replay is model free and preserves final decisions'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_generation_draft_is_reused_after_failed_guard",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_generation_draft_is_reused_after_failed_guard",
    ),
    skip:
        "Dart implementation of pipeline.classify, pipeline.extract, pipeline.judge, pipeline.kg, pipeline.link, pipeline.llm, pipeline.parse, pipeline.provenance, pipeline.run is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'generation draft is reused after failed guard'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_collection_keeps_interstitial_front_matter",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_collection_keeps_interstitial_front_matter",
    ),
    skip:
        "Dart implementation of pipeline.classify.classify_chapters is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'collection keeps interstitial front matter'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_free_alias_never_reads_paid_credentials_on_outage",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_free_alias_never_reads_paid_credentials_on_outage",
    ),
    skip:
        "Dart implementation of pipeline.llm._Breaker.__init__, pipeline.llm.jev is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'free alias never reads paid credentials on outage'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_paid_budget_persists_and_concurrency_cannot_exceed_cap",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_paid_budget_persists_and_concurrency_cannot_exceed_cap",
    ),
    skip:
        "Dart implementation of pipeline.provenance.reserve_paid is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'paid budget persists and concurrency cannot exceed cap'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_paid_budget_default_uses_durable_data_directory",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_paid_budget_default_uses_durable_data_directory",
    ),
    skip:
        "Dart implementation of pipeline.provenance.reserve_paid is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'paid budget default uses durable data directory'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_legacy_chat_fallback_cannot_bypass_route_or_teacher_provenance",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_legacy_chat_fallback_cannot_bypass_route_or_teacher_provenance",
    ),
    skip:
        "Dart implementation of pipeline.llm.jev is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'legacy chat fallback cannot bypass route or teacher provenance'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_saga_refuses_missing_or_unverified_recap_before_generation",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_saga_refuses_missing_or_unverified_recap_before_generation",
    ),
    skip:
        "Dart implementation of pipeline.classify, pipeline.extract, pipeline.judge, pipeline.kg, pipeline.link, pipeline.llm, pipeline.parse, pipeline.provenance, pipeline.run is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'saga refuses missing or unverified recap before generation'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_verified_output_reconciles_unacknowledged_job_without_calls",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_verified_output_reconciles_unacknowledged_job_without_calls",
    ),
    skip:
        "Dart implementation of pipeline.classify, pipeline.extract, pipeline.judge, pipeline.kg, pipeline.link, pipeline.llm, pipeline.parse, pipeline.provenance, pipeline.run is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'verified output reconciles unacknowledged job without calls'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_identity_taint_propagates_at_temporal_merge_boundaries",
    () {
      final rows = <Map<String, Object?>>[
        {'t': 'merge', 'p': 5, 'from': 'P1', 'into': 'P2'},
        {'t': 'merge', 'p': 20, 'from': 'P2', 'into': 'P3'},
        {
          't': 'event',
          'p': 8,
          'who': ['P2'],
          'text': 'early',
        },
        {
          't': 'event',
          'p': 12,
          'who': ['P2'],
          'text': 'tainted',
        },
        {
          't': 'event',
          'p': 19,
          'who': ['P3'],
          'text': 'before later merge',
        },
        {
          't': 'event',
          'p': 21,
          'who': ['P3'],
          'text': 'after later merge',
        },
      ];
      final result = _quarantine(
        rows,
        [
          [9, 11, 'P2', 0],
          [18, 19, 'P3', 0],
        ],
        {'P1': 10},
      );
      final kept = result[0] as List<Object?>;
      final mentions = result[1] as List<Object?>;
      final dropped = result[2] as List<Object?>;
      final taint = result[4];
      expect(taint, {'P1': 10, 'P2': 10, 'P3': 20});
      expect(
        kept
            .cast<Map<String, Object?>>()
            .where((row) => row['t'] == 'event')
            .map((row) => row['text'])
            .toList(),
        ['early', 'before later merge'],
      );
      expect(mentions, [
        [18, 19, 'P3', 0],
      ]);
      expect(dropped, hasLength(3));
    },
    skip:
        "Dart implementation of pipeline.kg.quarantine_identities is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'identity taint propagates at temporal merge boundaries'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_tainted_person_retains_source_identity_without_unverified_intro",
    () {
      final person = <String, Object?>{
        't': 'person',
        'p': 1,
        'id': 'P1',
        'name': 'Alice',
        'intro': 'Secret identity claim',
      };
      final result = _quarantine([person], [], {'P1': 0});
      expect(result[0], [
        {...person, 'intro': ''},
      ]);
      expect(result[2], [person]);
    },
    skip:
        "Dart implementation of pipeline.kg.quarantine_identities is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'tainted person retains source identity without unverified intro'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_rebuilding_journal_filters_old_graph_on_fresh_runner_without_cli_flag",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_rebuilding_journal_filters_old_graph_on_fresh_runner_without_cli_flag",
    ),
    skip:
        "Dart implementation of pipeline.classify, pipeline.extract, pipeline.judge, pipeline.kg, pipeline.link, pipeline.llm, pipeline.parse, pipeline.provenance, pipeline.run is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'rebuilding journal filters old graph on fresh runner without cli flag'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_explicit_quality_retry_archives_and_can_complete_from_preserved_extraction",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_explicit_quality_retry_archives_and_can_complete_from_preserved_extraction",
    ),
    skip:
        "Dart implementation of pipeline.link.to_classic is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'explicit quality retry archives and can complete from preserved extraction'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_math_preserves_fraction_and_exponent",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_math_preserves_fraction_and_exponent",
    ),
    skip:
        "Dart implementation of pipeline.parse.DocParser.__init__ is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'math preserves fraction and exponent'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_svg_keeps_accessible_text_or_explicit_unavailable_marker",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_svg_keeps_accessible_text_or_explicit_unavailable_marker",
    ),
    skip:
        "Dart implementation of pipeline.parse.DocParser.__init__ is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'svg keeps accessible text or explicit unavailable marker'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_oversized_paragraph_is_refused_before_extraction",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_oversized_paragraph_is_refused_before_extraction",
    ),
    skip:
        "Dart implementation of pipeline.run.Runner.__init__ is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'oversized paragraph is refused before extraction'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_archive_rejected_before_member_read",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_archive_rejected_before_member_read",
    ),
    skip:
        "Dart implementation of pipeline.parse.parse_epub is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'archive rejected before member read'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_epub_detects_english_for_cost_and_extraction",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_epub_detects_english_for_cost_and_extraction",
    ),
    skip:
        "Dart implementation of pipeline.parse.parse_epub is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'epub detects english for cost and extraction'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_request_deadline_spans_stages_and_refuses_unaffordable_retry",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_request_deadline_spans_stages_and_refuses_unaffordable_retry",
    ),
    skip:
        "Dart implementation of pipeline.llm._sleep, pipeline.llm._timeout, pipeline.llm.request_budget is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'request deadline spans stages and refuses unaffordable retry'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_trickled_response_cannot_reset_request_deadline",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_trickled_response_cannot_reset_request_deadline",
    ),
    skip:
        "Dart implementation of pipeline.llm._chunks, pipeline.llm.request_budget is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'trickled response cannot reset request deadline'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_expired_request_does_not_contact_any_route",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_expired_request_does_not_contact_any_route",
    ),
    skip:
        "Dart implementation of pipeline.llm.jev, pipeline.llm.request_budget is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'expired request does not contact any route'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_free_context_limit_never_silently_changes_teacher_input",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_free_context_limit_never_silently_changes_teacher_input",
    ),
    skip:
        "Dart implementation of pipeline.llm._Breaker.__init__, pipeline.llm.jev_free is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'free context limit never silently changes teacher input'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_classic_guard_outage_reuses_raw_extraction",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_classic_guard_outage_reuses_raw_extraction",
    ),
    skip:
        "Dart implementation of pipeline.link.to_classic is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'classic guard outage reuses raw extraction'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_classic_rejected_rewrite_is_withheld",
    () => fail(
      "Dart port not implemented: tests.test_pipeline_repair.PipelineRepair.test_classic_rejected_rewrite_is_withheld",
    ),
    skip:
        "Dart implementation of pipeline.link.to_classic is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'classic rejected rewrite is withheld'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_flagged_cache_needs_explicit_deterministic_fallback",
    () {
      final record = <String, Object?>{
        'recap': 'claim',
        'guard': {
          'recap': {'verdict': 'flag'},
        },
      };
      Object? verified() => callPorted('pipeline.run.Runner.verified_summary', {
        'record': record,
        'fields': {
          '\$tuple': ['recap'],
        },
      });

      expect(verified(), isFalse);
      record.addAll({
        'recap_flagged': 'original',
        'fallback_kind': 'verified-input-excerpt',
      });
      expect(verified(), isTrue);
    },
    skip:
        "Dart implementation of pipeline.run.Runner.verified_summary is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'flagged cache needs explicit deterministic fallback'.",
  );
}
