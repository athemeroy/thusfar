// Generated from docs/port/inventory.json by core/tool/generate_ported_tests.py.
// Some callbacks contain translated assertions but remain skipped until their Dart owners exist.
import 'package:test/test.dart';

import 'contract_invoker.dart';

const _runnerParagraphs = <String>[
  'Alice met Bob at the station.',
  'Later she revealed Bob was her brother.',
];

Map<String, Object?> _local() => {
  'people': [
    {
      'id': 'a',
      'name': 'Alice',
      'names': ['Alice'],
      'para': 1,
      'quote': 'Alice met Bob',
    },
    {
      'id': 'b',
      'name': 'Bob',
      'names': ['Bob'],
      'para': 1,
      'quote': 'Alice met Bob',
    },
  ],
  'same': [],
  'facts': [],
  'rels': [],
  'events': [
    {
      'who': ['a', 'b'],
      'text': 'Alice met Bob',
      'quote': 'Alice met Bob',
      'para': 1,
    },
  ],
};

/// Test-only adapters execute the named real Dart pipeline entry points in a
/// fresh temporary book/work directory. They use only the supplied scripted
/// model answers, clock values, and failures. They report observed records,
/// files, call counts, and errors; expected outcomes must never be synthesized
/// from the `case` name. The common runner setup mirrors PipelineRepair.runner:
/// make_book via finish/classify, classified novel, all chapters body, network
/// forbidden, JEV_ROUTE=free-only, and a new Runner with owned worker pools.
/// Symbolic fixture references such as `segment_o1`,
/// `current_runner_input_sha256`, `temp_root`, and
/// `converted_raw_local_with_profile` are resolved from that live setup before
/// the scripted operation runs.
Map<String, Object?> _scenario(
  String group,
  String name,
  Map<String, Object?> input,
) =>
    callPorted('tests.test_pipeline_repair.$group', {'case': name, ...input})
        as Map<String, Object?>;

Map<String, Object?> _runner(String name, Map<String, Object?> input) =>
    _scenario('runner_scenario', name, {
      'paragraphs': _runnerParagraphs,
      'local': _local(),
      ...input,
    });

List<Map<String, Object?>> _records(Map<String, Object?> result) =>
    (result['records'] as List<Object?>).cast<Map<String, Object?>>();

String _repeat(String text, int times) => List.filled(times, text).join();

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
    () {
      for (final status in ['new', 'changed', 'ended']) {
        final data = _local();
        data['rels'] = [
          {'a': 'a', 'b': 'b', 'b_is': 'friend', 'status': status},
        ];
        final result = _scenario('kg_scenario', 'convert_and_commit', {
          'paragraphs': ['Alice met Bob.'],
          'data': data,
          'decisions': <String, Object?>{},
        });
        final converted = result['converted'] as Map<String, Object?>;
        final convertedRel =
            (converted['rels'] as List<Object?>).first as Map<String, Object?>;
        expect(convertedRel['status'], status);
        final rel = _records(result).firstWhere((row) => row['t'] == 'rel');
        expect(rel['status'], status);
      }
    },
    skip:
        "Dart implementation of pipeline.extract.segments, pipeline.kg.KG.__init__, pipeline.link.to_classic is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'relation status survives conversion and kg'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_short_identity_reveal_and_unicode_entry",
    () {
      final result = _scenario('kg_scenario', 'commit_once', {
        'paragraphs': ['😀黑衣人推门走入客栈。', '随后他才报出真名：陈明。'],
        'data': {
          'new_people': [
            {
              'ref': 'N1',
              'name': '陈明',
              'para': 1,
              'quote': '黑衣人推门走入客栈',
              'intro': '失踪的陈明',
            },
          ],
          'surfaces': {
            'N1': ['黑衣人', '陈明'],
          },
        },
        'decisions': <String, Object?>{},
      });
      final records = _records(result);
      final book = result['book'] as Map<String, Object?>;
      final blocks =
          (book['blocks'] as List<Object?>).cast<Map<String, Object?>>();
      final secondOffset = blocks[1]['o'] as int;
      final person = records.firstWhere((row) => row['t'] == 'person');
      final reveal = records.firstWhere((row) => row['t'] == 'name');
      expect(person['name'], '黑衣人');
      expect(person['intro'], '');
      expect(reveal['p'] as int, greaterThanOrEqualTo(secondOffset));
      expect(
        records
            .where((row) => (row['p'] as int) < secondOffset)
            .every((row) => !'$row'.contains('陈明')),
        isTrue,
      );
    },
    skip:
        "Dart implementation of pipeline.extract.segments, pipeline.kg.KG.__init__ is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'short identity reveal and unicode entry'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_merge_between_existing_people_does_not_rewrite_past",
    () {
      final result = _scenario('kg_scenario', 'two_commits', {
        'paragraphs': ['黑衣人离开了。王子留在宫里。', '黑衣人偷走了信件。', '此时才揭晓：黑衣人就是王子。'],
        // The adapter uses [0] and [1,2] as the two segment block lists,
        // with the same o0/o1 boundaries as the Python fixture.
        'segment_blocks': [
          [0],
          [1, 2],
        ],
        'first_data': {
          'new_people': [
            {'ref': 'N1', 'name': '黑衣人', 'para': 1, 'quote': '黑衣人离开了'},
            {'ref': 'N2', 'name': '王子', 'para': 1, 'quote': '王子留在宫里'},
          ],
        },
        'second_data': {
          'merges': [
            {'from': 'P1', 'into': 'P2', 'para': 2, 'quote': '黑衣人就是王子'},
          ],
          'events': [
            {
              'who': ['P1'],
              'text': '黑衣人偷信',
              'para': 1,
              'quote': '黑衣人偷走了信件',
            },
          ],
        },
      });
      final records = _records(result);
      final event = records.firstWhere((row) => row['t'] == 'event');
      final merge = records.firstWhere((row) => row['t'] == 'merge');
      expect(event['who'], ['P1']);
      expect(event['p'] as int, lessThan(merge['p'] as int));
      expect(result['canonical_p1'], 'P2');
    },
    skip:
        "Dart implementation of pipeline.kg.KG.__init__ is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'merge between existing people does not rewrite past'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_judge_relation_uses_evidence_frontier",
    () {
      final data = _local();
      data['rels'] = [
        {
          'a': 'a',
          'b': 'b',
          'by': 'judge',
          'b_is': 'sibling',
          'para': 1,
          'quote': 'Alice met Bob',
        },
      ];
      final result = _scenario('kg_scenario', 'convert_and_commit', {
        'paragraphs': _runnerParagraphs,
        'use_runner_segment': true,
        'data': data,
        'decisions': <String, Object?>{},
      });
      final rel = _records(result).firstWhere((row) => row['t'] == 'rel');
      final segment = result['segment'] as Map<String, Object?>;
      expect(rel['p'], segment['o1']);
    },
    skip:
        "Dart implementation of pipeline.link.to_classic is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'judge relation uses evidence frontier'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_missing_facets_propagate_for_retry",
    () {
      final result = _scenario('judge_scenario', 'missing_facets', {
        'text': 'fixture',
        'pairs': [
          ['a', 'b'],
        ],
        'names': {'a': 'Alice', 'b': 'Bob'},
        'candidates': [
          {
            'pair': ['a', 'b'],
            'ties': [
              ['marriage', 0.99],
            ],
          },
        ],
        'jev_script': [
          {
            'l1': {
              'choice': 'spouse',
              'probabilities': {'spouse': 0.99},
            },
          },
          {'error': 'LLMError', 'message': 'outage'},
        ],
      });
      expect(result['error'], 'LLMError');
      expect(result['jev_calls'], 2);
    },
    skip:
        "Dart implementation of pipeline.judge.relations_by_judge is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'missing facets propagate for retry'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_relation_judge_receives_character_memory_but_requires_current_evidence",
    () {
      final context = <String, Object?>{
        'story_before_this_passage': 'Alice has been hiding a family secret.',
        'previous_passage_tail': 'Bob called her sister before leaving.',
        'character_context': {
          'a': {
            'known_before': {'name': 'Alice', 'bio': 'Bob的姐姐'},
          },
          'b': {
            'known_before': {'name': 'Bob', 'bio': 'Alice的弟弟'},
          },
        },
      };
      final result = _scenario('judge_scenario', 'character_memory', {
        'text': 'Alice met Bob again.',
        'pairs': [
          ['a', 'b'],
        ],
        'names': {'a': 'Alice', 'b': 'Bob'},
        'candidates': [
          {
            'pair': ['a', 'b'],
            'ties': [
              ['kin', 0.9],
            ],
          },
        ],
        'context': context,
        'jev_script': [
          {
            'l1': {
              'choice': 'sibling',
              'probabilities': {'sibling': 0.96, 'other': 0.04},
            },
          },
        ],
      });
      final state = result['judge_state'] as Map<String, Object?>;
      expect(state['character_context'], context['character_context']);
      expect(state['previous_passage_tail'], context['previous_passage_tail']);
      final instruction = result['family_instruction'] as String;
      expect(instruction, contains('the tie must still be established'));
      final relation = result['relation'] as Map<String, Object?>;
      final ties =
          (relation['ties'] as List<Object?>).cast<Map<String, Object?>>();
      expect(ties.first['role'], 'sibling');
      expect(result['jev_calls'], 1);
    },
    skip:
        "Dart implementation of pipeline.judge.family_questions, pipeline.judge.relations_by_judge is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'relation judge receives character memory but requires current evidence'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_relation_memory_keeps_biography_events_and_existing_ties",
    () {
      final common = <String, Object?>{
        'aliases': <String>[],
        'weak': <String>[],
        'first': 0,
        'mentions': 8,
        'last_seg': 0,
        'imp': 2,
        'merged_into': null,
        'intro': '',
      };
      final result = _runner('relation_memory', {
        'people': {
          'P1': {
            ...common,
            'id': 'P1',
            'name': 'Alice',
            'tagline': '寄住在车站的姐姐',
            'bio': '一路照料弟弟并隐瞒来信。',
          },
          'P2': {
            ...common,
            'id': 'P2',
            'name': 'Bob',
            'tagline': 'Alice的弟弟',
            'bio': '刚回到镇上。',
          },
        },
        'relations': {
          'P1|P2': {
            'a': 'P1',
            'b': 'P2',
            'a_is': '姐姐',
            'b_is': '弟弟',
            'desc': '姐弟',
            'status': 'new',
          },
        },
        'log': [
          {
            't': 'event',
            'p': 4,
            'who': ['P1', 'P2'],
            'text': 'Alice在站台接到了Bob。',
          },
        ],
        'recent': ['Alice在站台接到了Bob。'],
        'saga': '姐弟二人在车站重逢。',
        'segment': 0,
        'local_people': [
          {
            'id': 'a',
            'name': 'Alice',
            'known': 'P1',
            'known_name': 'Alice',
            'role': '写信的人',
          },
          {
            'id': 'b',
            'name': 'Bob',
            'known': 'P2',
            'known_name': 'Bob',
            'role': '回乡者',
          },
        ],
      });
      final context = result['context'] as Map<String, Object?>;
      final characters = context['character_context'] as Map<String, Object?>;
      final alice =
          ((characters['a'] as Map<String, Object?>)['known_before'])
              as Map<String, Object?>;
      expect(alice['bio'], '一路照料弟弟并隐瞒来信。');
      expect(alice['known_relations'] as List<Object?>, contains('Bob（弟弟）'));
      expect(
        alice['recent_events'] as List<Object?>,
        contains('Alice在站台接到了Bob。'),
      );
      expect(
        context['story_before_this_passage'] as String,
        contains('姐弟二人在车站重逢'),
      );
    },
    skip:
        "Dart implementation of pipeline.classify, pipeline.extract, pipeline.judge, pipeline.kg, pipeline.link, pipeline.llm, pipeline.parse, pipeline.provenance, pipeline.run is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'relation memory keeps biography events and existing ties'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_critical_outage_keeps_extraction_and_does_not_publish",
    () {
      final data = _local();
      ((data['events'] as List<Object?>).first
              as Map<String, Object?>)['text'] =
          'Alice杀死了Bob。';
      final result = _runner('critical_outage', {
        'link_segment_data': data,
        'convert_link_data': true,
        'link_decisions': <String, Object?>{},
        'verify_critical_script': [
          {'error': 'LLMError', 'message': 'outage'},
        ],
        'link_input': {'data': _local(), 'model': 'fixture'},
      });
      expect(result['error'], 'LLMError');
      expect(result['segment_exists'], isFalse);
      expect(result['verification_state'], 'failed');
      expect(result['verify_critical_calls'], 1);
    },
    skip:
        "Dart implementation of pipeline.link.to_classic is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'critical outage keeps extraction and does not publish'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_biography_order_and_unchecked_publication",
    () {
      final result = _runner('apply_bios', {
        'people': {
          'P1': {'name': 'Alice'},
        },
        'calls': [
          {
            'position': 200,
            'bios': {
              'P1': {
                'bio': 'new',
                'chk': {'verdict': 'ok'},
              },
            },
          },
          {
            'position': 100,
            'bios': {
              'P1': {
                'bio': 'old',
                'chk': {'verdict': 'ok'},
              },
            },
          },
          {
            'position': 300,
            'bios': {
              'P1': {
                'bio': 'unchecked',
                'chk': {'verdict': 'unchecked'},
              },
            },
          },
        ],
      });
      final people = result['people'] as Map<String, Object?>;
      expect((people['P1'] as Map<String, Object?>)['bio'], 'new');
      final log = (result['log'] as List<Object?>).cast<Map<String, Object?>>();
      expect(log.map((row) => row['p']).toList(), [200, 100]);
    },
    skip:
        "Dart implementation of pipeline.classify, pipeline.extract, pipeline.judge, pipeline.kg, pipeline.link, pipeline.llm, pipeline.parse, pipeline.provenance, pipeline.run is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'biography order and unchecked publication'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_complete_replay_is_model_free_and_preserves_final_decisions",
    () {
      final data = _local();
      data['attrs'] = [
        {'who': 'Na', 'key': '住处', 'value': 'old', 'para': 1},
        {'who': 'Na', 'key': '住处', 'value': 'new', 'para': 2},
      ];
      final result = _runner('complete_replay', {
        'raw_data': data,
        'convert_raw_data': true,
        'cached_files': {
          // Adapter inserts converted raw_data into this segment file and
          // resolves its saga path at the real segment's o1.
          'segment': {'seg': 0, 'mode': 'two-phase'},
          'dedupe': {'pairs': <Object?>[], 'merged': <Object?>[]},
          'bio': {'bios': <String, Object?>{}},
          'recap': {
            'recap': 'cached',
            'guard': {
              'recap': {'verdict': 'ok'},
            },
          },
          'saga': {
            'saga': 'cached',
            'guard': {
              'saga': {'verdict': 'ok'},
            },
          },
        },
        'prior_log': [
          {'t': 'imp', 'p': 'segment_o1', 'id': 'P1', 'imp': 3},
        ],
        'run2': {'limit': 0},
        'forbid_calls': ['importance', 'current_value'],
      });
      final people = result['people'] as Map<String, Object?>;
      expect((people['P1'] as Map<String, Object?>)['imp'], 3);
      expect(result['importance_calls'], 0);
      expect(result['current_value_calls'], 0);
    },
    skip:
        "Dart implementation of pipeline.link.to_classic is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'complete replay is model free and preserves final decisions'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_generation_draft_is_reused_after_failed_guard",
    () {
      final result = _runner('bio_draft_retry', {
        'segment': 0,
        'position': 100,
        'dossier': 'original dossier',
        'ids': ['P1'],
        'chat_json_script': [
          {
            'value': {
              'P1': {'bio': 'biography'},
            },
            'metadata': <String, Object?>{},
          },
        ],
        'guard_texts_script': [
          {'error': 'LLMError', 'message': 'outage'},
          {
            'P1': {'verdict': 'ok', 'p': 0.9},
          },
        ],
      });
      expect(result['first_error'], 'LLMError');
      expect(result['bio_exists_after_first'], isFalse);
      expect(result['chat_json_calls'], 1);
      expect(result['guard_texts_calls'], 2);
    },
    skip:
        "Dart implementation of pipeline.classify, pipeline.extract, pipeline.judge, pipeline.kg, pipeline.link, pipeline.llm, pipeline.parse, pipeline.provenance, pipeline.run is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'generation draft is reused after failed guard'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_collection_keeps_interstitial_front_matter",
    () {
      final result = _scenario('classify_scenario', 'interstitial_front', {
        'book': <String, Object?>{},
        'classify_by_judge_script': ['body', 'front', 'body'],
      });
      expect(result['kinds'], ['body', 'front', 'body']);
      expect(result['judge_calls'], 1);
    },
    skip:
        "Dart implementation of pipeline.classify.classify_chapters is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'collection keeps interstitial front matter'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_free_alias_never_reads_paid_credentials_on_outage",
    () {
      for (final route in ['free', 'free-only']) {
        final result = _scenario('llm_scenario', 'free_route_outage', {
          'env': {'JEV_ROUTE': route, 'JUDGE_CACHE': '0'},
          'breaker': 'fixture',
          'state': 'state',
          'questions': {
            'q': {
              'criteria': {'a': 'A'},
            },
          },
          'jev_free_script': [
            {'error': 'LLMError', 'message': 'outage'},
          ],
          'forbid_env_lookup': true,
        });
        expect(result['error'], 'LLMError', reason: route);
        expect(result['paid_env_lookup_calls'], 0, reason: route);
        expect(result['jev_free_calls'], 1, reason: route);
      }
    },
    skip:
        "Dart implementation of pipeline.llm._Breaker.__init__, pipeline.llm.jev is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'free alias never reads paid credentials on outage'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_paid_budget_persists_and_concurrency_cannot_exceed_cap",
    () {
      final result = _scenario('budget_scenario', 'concurrent_cap', {
        'budget_file': 'budget.json',
        'env': {'JEV_PAID_MAX_CALLS': '3', 'JEV_PAID_MAX_CHARS': '100'},
        'workers': 8,
        'requests': List.generate(
          20,
          (_) => <String, Object?>{'chars': 20, 'calls': 1},
        ),
        'extra_request': {'chars': 1, 'calls': 1},
      });
      expect(result['attempted_reservations'], 20);
      expect(result['successful_reservations'], 3);
      final budget = result['budget_file_data'] as Map<String, Object?>;
      expect(budget['calls'], 3);
      expect(result['extra_error'], 'RuntimeError');
    },
    skip:
        "Dart implementation of pipeline.provenance.reserve_paid is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'paid budget persists and concurrency cannot exceed cap'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_paid_budget_default_uses_durable_data_directory",
    () {
      final result = _scenario('budget_scenario', 'default_data_dir', {
        'clear_environment': true,
        'env': {'DATA_DIR': 'temp_root', 'JEV_PAID_MAX_CALLS': '1'},
        'requests': [
          {'chars': 1, 'calls': 1},
          {'chars': 1, 'calls': 1},
        ],
      });
      expect(result['budget_file'], 'paid-budget.json');
      expect((result['budget_file_data'] as Map<String, Object?>)['calls'], 1);
      expect(result['second_error'], 'RuntimeError');
    },
    skip:
        "Dart implementation of pipeline.provenance.reserve_paid is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'paid budget default uses durable data directory'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_legacy_chat_fallback_cannot_bypass_route_or_teacher_provenance",
    () {
      final result = _scenario('llm_scenario', 'paid_route_no_fallback', {
        'env': {'JEV_ROUTE': 'paid', 'JUDGE_FALLBACK': '1'},
        'env_lookup_result': null,
        'forbid_legacy_chat': true,
        'state': 'state',
        'questions': {
          'q': {
            'criteria': {'yes': 'yes', 'no': 'no'},
          },
        },
      });
      expect(result['error'], 'LLMError');
      expect(result['legacy_chat_calls'], 0);
    },
    skip:
        "Dart implementation of pipeline.llm.jev is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'legacy chat fallback cannot bypass route or teacher provenance'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_saga_refuses_missing_or_unverified_recap_before_generation",
    () {
      final result = _runner('saga_requires_verified_recap', {
        'segment_indices': [0],
        'saga_end': 'segment_o1',
        'recap_files_in_order': [
          null,
          {'recap': 'unchecked'},
        ],
        'forbid_cached_generation': true,
      });
      expect(result['errors'], ['LLMError', 'LLMError']);
      expect(result['cached_generation_calls'], 0);
    },
    skip:
        "Dart implementation of pipeline.classify, pipeline.extract, pipeline.judge, pipeline.kg, pipeline.link, pipeline.llm, pipeline.parse, pipeline.provenance, pipeline.run is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'saga refuses missing or unverified recap before generation'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_verified_output_reconciles_unacknowledged_job_without_calls",
    () {
      final result = _runner('reconcile_verified_recap', {
        'two_phase': true,
        'job_file': {'kind': 'recap', 'key': 0, 'state': 'pending'},
        'quality_pending': ['recap-0'],
        'recap_file': {
          'recap': 'verified',
          'guard': {
            'recap': {'verdict': 'ok'},
          },
        },
        'recap_call': {'chapter': 0, 'end': 'segment_o1', 'segment': 0},
        'forbid_cached_generation': true,
      });
      expect(
        result['quality_pending'] as List<Object?>,
        isNot(contains('recap-0')),
      );
      expect((result['job_file'] as Map<String, Object?>)['state'], 'complete');
      expect(result['cached_generation_calls'], 0);
    },
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
    () {
      final result = _runner('restart_rebuilding_journal', {
        'kg_file': {
          'log': [
            {
              't': 'merge',
              'p': 20,
              'from': 'P2',
              'into': 'P1',
              'kind': 'dedupe',
            },
            {'t': 'imp', 'p': 20, 'id': 'P1', 'imp': 3},
            {
              't': 'attr',
              'p': 20,
              'id': 'P1',
              'key': 'old',
              'value': 'tainted',
              'by': 'judge',
            },
          ],
        },
        'quality_retry_file': {
          'state': 'rebuilding',
          'first_segment': 0,
          'input_sha256': 'current_runner_input_sha256',
        },
        'restart_without_cli_flag': true,
      });
      expect(result['restarted_prior_log'], isEmpty);
    },
    skip:
        "Dart implementation of pipeline.classify, pipeline.extract, pipeline.judge, pipeline.kg, pipeline.link, pipeline.llm, pipeline.parse, pipeline.provenance, pipeline.run is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'rebuilding journal filters old graph on fresh runner without cli flag'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_explicit_quality_retry_archives_and_can_complete_from_preserved_extraction",
    () {
      final source = <String, Object?>{
        'seg': 0,
        'data': _local(),
        'model': 'fixture',
      };
      final result = _runner('quality_retry_lifecycle', {
        'local_file': source,
        'linked_record': {
          'seg': 0, 'mode': 'two-phase',
          // Adapter inserts to_classic(source.data, {}) here.
          'link': {'decisions': <String, Object?>{}},
          'timing': {'link': 0},
          'guard': <String, Object?>{},
        },
        'recap_file': {'recap': 'old unchecked'},
        'repair_policy': {
          'quarantine_after': 0,
          'blocked': ['work/recaps/0000.json'],
          'pending': ['derived-context-review'],
        },
        'quality_pending': ['derived-context-review'],
        'steps': [
          'prepare_quality_retry',
          'restore_segment_file',
          'prepare_quality_retry',
          'remove_segment_file',
          'run2_with_scripted_local_link_and_no_recap',
        ],
        'run2': {'concurrency': 1, 'model': 'fixture'},
      });
      final first = result['after_first_prepare'] as Map<String, Object?>;
      expect(first['segment_exists'], isFalse);
      expect(first['recap_exists'], isFalse);
      expect(first['local_file_base64'], result['original_local_base64']);
      expect(first['archive'] as String, isNotEmpty);
      expect(first['archived_recap'], 'old unchecked');
      expect(first['quality_pending'], ['quality-rebuild']);
      final repeated = result['after_repeated_prepare'] as Map<String, Object?>;
      expect(repeated['segment_exists'], isTrue);
      expect(repeated['archive'], first['archive']);
      final done = result['after_run2'] as Map<String, Object?>;
      expect(done['status_quality_state'], 'verified');
      expect(done['quality_retry_state'], 'complete');
      expect(done['local_file_base64'], result['original_local_base64']);
    },
    skip:
        "Dart implementation of pipeline.link.to_classic is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'explicit quality retry archives and can complete from preserved extraction'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_math_preserves_fraction_and_exponent",
    () {
      final result = _scenario('parse_scenario', 'doc_parser', {
        'title': 'fixture',
        'html':
            '<p>Equation: <math><mfrac><msup><mi>x</mi><mn>2</mn>'
            '</msup><mi>y</mi></mfrac></math>.</p>',
        'close': true,
      });
      final blocks =
          (result['blocks'] as List<Object?>).cast<Map<String, Object?>>();
      expect(blocks.first['t'] as String, contains('((x)^(2))/(y)'));
    },
    skip:
        "Dart implementation of pipeline.parse.DocParser.__init__ is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'math preserves fraction and exponent'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_svg_keeps_accessible_text_or_explicit_unavailable_marker",
    () {
      final result = _scenario('parse_scenario', 'doc_parser', {
        'title': 'fixture',
        'html':
            '<p>Diagram <svg><title>Flow</title><text>A to B</text>'
            '</svg> and <svg><path d="M0,0"/></svg>.</p>',
        'close': true,
      });
      final blocks =
          (result['blocks'] as List<Object?>).cast<Map<String, Object?>>();
      final text = blocks.first['t'] as String;
      expect(text, contains('图形：Flow；A to B'));
      expect(text, contains('图形缺少可读取文本'));
    },
    skip:
        "Dart implementation of pipeline.parse.DocParser.__init__ is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'svg keeps accessible text or explicit unavailable marker'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_oversized_paragraph_is_refused_before_extraction",
    () {
      final result = _scenario('runner_scenario', 'oversized_init', {
        'paragraphs': ['Alice ${_repeat('x', 12000)}'],
        'book_title': 'fixture',
        'write_book_json': true,
      });
      expect(result['error'], 'ValueError');
      expect(result['error_message'] as String, contains('长段落'));
      expect(result['extraction_calls'], 0);
    },
    skip:
        "Dart implementation of pipeline.run.Runner.__init__ is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'oversized paragraph is refused before extraction'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_archive_rejected_before_member_read",
    () {
      final result = _scenario('parse_scenario', 'epub_member_limit', {
        'archive_name': 'book.epub',
        'compression': 'deflated',
        'members': {'oversized': _repeat('x', 100)},
        'max_epub_member_bytes': 20,
        'forbid_member_read': true,
      });
      expect(result['error'], 'ValueError');
      expect(result['member_read_calls'], 0);
    },
    skip:
        "Dart implementation of pipeline.parse.parse_epub is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'archive rejected before member read'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_epub_detects_english_for_cost_and_extraction",
    () {
      final result = _scenario('parse_scenario', 'epub_language', {
        'archive_name': 'english.epub',
        'compression': 'deflated',
        'members': {
          'META-INF/container.xml':
              '<container><rootfiles><rootfile full-path="OPS/content.opf"/>'
              '</rootfiles></container>',
          'OPS/content.opf':
              '<package><metadata><title>English story</title></metadata>'
              '<manifest><item id="chapter" href="chapter.xhtml" '
              'media-type="application/xhtml+xml"/></manifest>'
              '<spine><itemref idref="chapter"/></spine></package>',
          'OPS/chapter.xhtml':
              '<html><body><p>${_repeat('Mr. Utterson met Dr. Jekyll at the door. ', 50)}'
              '</p></body></html>',
        },
      });
      expect(result['lang'], 'en');
    },
    skip:
        "Dart implementation of pipeline.parse.parse_epub is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'epub detects english for cost and extraction'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_request_deadline_spans_stages_and_refuses_unaffordable_retry",
    () {
      final result = _scenario('llm_scenario', 'shared_deadline', {
        'initial_monotonic': 100.0,
        'outer_request_budget': 5,
        'timeout_requested': 90,
        'advance_monotonic_by': 4,
        'sleep_requested': 2,
        'nested_request_budget': 99,
        'forbid_real_sleep': true,
      });
      expect(result['timeouts'], [5, 1, 1, 90]);
      expect(result['sleep_error'], 'DeadlineExceeded');
      expect(result['real_sleep_calls'], 0);
    },
    skip:
        "Dart implementation of pipeline.llm._sleep, pipeline.llm._timeout, pipeline.llm.request_budget is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'request deadline spans stages and refuses unaffordable retry'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_trickled_response_cannot_reset_request_deadline",
    () {
      final result = _scenario('llm_scenario', 'trickled_response', {
        'initial_monotonic': 100.0,
        'request_budget': 2,
        'response_chunk': 'x',
        'advance_per_read': 0.7,
        'consume_all_chunks': true,
        'max_scripted_reads': 10,
      });
      expect(result['error'], 'DeadlineExceeded');
      expect(result['reads'], 3);
    },
    skip:
        "Dart implementation of pipeline.llm._chunks, pipeline.llm.request_budget is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'trickled response cannot reset request deadline'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_expired_request_does_not_contact_any_route",
    () {
      final result = _scenario('llm_scenario', 'expired_before_route', {
        'initial_monotonic': 100.0,
        'request_budget': 2,
        'advance_before_jev': 3,
        'state': 'state',
        'questions': {
          'q': {
            'criteria': {'a': 'A'},
          },
        },
        'forbid_jev_free': true,
      });
      expect(result['error'], 'DeadlineExceeded');
      expect(result['jev_free_calls'], 0);
      expect(result['paid_route_calls'], 0);
    },
    skip:
        "Dart implementation of pipeline.llm.jev, pipeline.llm.request_budget is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'expired request does not contact any route'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_free_context_limit_never_silently_changes_teacher_input",
    () {
      final result = _scenario('llm_scenario', 'free_context_limit', {
        'breaker': 'fixture',
        'state': _repeat('x', 31001),
        'questions': {
          'q': {
            'criteria': {'a': 'A'},
          },
        },
      });
      expect(result['error'], 'LLMError');
      expect(result['jev_free_network_calls'], 0);
    },
    skip:
        "Dart implementation of pipeline.llm._Breaker.__init__, pipeline.llm.jev_free is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'free context limit never silently changes teacher input'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_classic_guard_outage_reuses_raw_extraction",
    () {
      final result = _runner('classic_guard_retry', {
        'raw_local': _local(),
        'profile': {
          'who': 'Na',
          'tagline': 'A traveler',
          'bio': 'Alice traveled.',
          'para': 1,
        },
        'extract_segment_script': [
          {
            'data': 'converted_raw_local_with_profile',
            'metadata': <String, Object?>{},
          },
        ],
        'guard_texts_script': [
          {'error': 'LLMError', 'message': 'outage'},
          {
            'Na': {'verdict': 'ok', 'p': 0.9},
          },
        ],
        'check_attrs_result': <String, Object?>{},
        'resolve_mentions_result': [<String, Object?>{}, <String, Object?>{}],
        'process_calls': [0, 0],
      });
      expect(result['first_error'], 'LLMError');
      expect(result['segment_exists_after_first'], isFalse);
      expect(result['extract_segment_calls'], 1);
      final record = result['second_record'] as Map<String, Object?>;
      final guard = record['guard'] as Map<String, Object?>;
      final checks = guard['checks'] as Map<String, Object?>;
      expect((checks['Na'] as Map<String, Object?>)['verdict'], 'ok');
    },
    skip:
        "Dart implementation of pipeline.link.to_classic is pending (A1, A2, A2/A4, A3, A4, A5); required to check 'classic guard outage reuses raw extraction'.",
  );
  test(
    "tests.test_pipeline_repair.PipelineRepair.test_classic_rejected_rewrite_is_withheld",
    () {
      final result = _runner('classic_rewrite_rejected', {
        'raw_local': _local(),
        'profile': {
          'who': 'Na',
          'tagline': 'Invented',
          'bio': 'Unsupported.',
          'para': 1,
        },
        'extract_segment_script': [
          {
            'data': 'converted_raw_local_with_profile',
            'metadata': <String, Object?>{},
          },
        ],
        'guard_texts_script': [
          {
            'Na': {'verdict': 'flag', 'p': 0.1},
          },
          {
            'Na': {'verdict': 'flag', 'p': 0.2},
          },
        ],
        'chat_json_script': [
          {
            'value': {
              'tagline': 'Still unsupported',
              'bio': 'Still unsupported.',
            },
            'metadata': <String, Object?>{},
          },
        ],
        'check_attrs_result': <String, Object?>{},
        'resolve_mentions_result': [<String, Object?>{}, <String, Object?>{}],
        'process_calls': [0],
      });
      final record = result['record'] as Map<String, Object?>;
      final data = record['data'] as Map<String, Object?>;
      expect(data['profiles'], isEmpty);
      final guard = record['guard'] as Map<String, Object?>;
      final checks = guard['checks'] as Map<String, Object?>;
      expect((checks['Na'] as Map<String, Object?>)['verdict'], 'withheld');
      expect(result['guard_texts_calls'], 2);
      expect(result['chat_json_calls'], 1);
    },
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
