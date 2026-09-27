// Translated Python 1.7.5 support-cache contracts; enabled with the A5 runner.
import 'package:test/test.dart';

import 'contract_invoker.dart';

Map<String, Object?> _verdict([String choice = 'supported']) => {
  'choice': choice,
  'p': choice == 'supported' ? 1.0 : 0.0,
  'probs': {choice: 1.0},
};

Map<String, Object?> _data() => {
  'people': [
    {
      'id': 'a',
      'name': 'Alice',
      'names': ['Alice'],
    },
    {
      'id': 'b',
      'name': 'Bob',
      'names': ['Bob'],
    },
  ],
  'same': <Object?>[],
  'events': [
    {
      'who': ['a', 'b'],
      'text': 'Alice speaks to Bob.',
      'imp': 1,
      'para': 1,
      'quote': 'Alice speaks to Bob',
    },
  ],
  'facts': [
    {'who': 'a', 'key': 'identity', 'value': 'a speaker'},
  ],
  'rels': <Object?>[],
};

Map<String, Object?> _record({bool legacy = false}) => {
  'seg': 0,
  'model': 'fixture',
  'data': _data(),
  if (legacy) 'support': {'e0': _verdict(), 'a0': _verdict()},
};

Map<String, Object?> _run(
  String owner,
  Map<String, Object?> record,
  Map<String, Object?> scripted,
) =>
    callPorted(owner, {
          'fixture': {
            'bookText':
                List.filled(
                  30,
                  'Alice speaks to Bob about an ordinary book. ',
                ).join(),
            'chapter': 'Chapter',
            'env': {
              'EVENT_CHECK_ONE_IN': '1',
              'VERIFY_RECORDS': '1',
              'JUDGE_RELATIONS': '1',
              'CARD_LANG': 'zh',
            },
          },
          'record': record,
          'scripted': scripted,
        })
        as Map<String, Object?>;

List<Object?> _tuple(String owner, Map<String, Object?> args) =>
    (callPorted(owner, args) as Map<String, Object?>)['\$tuple']
        as List<Object?>;

void main() {
  test(
    "tests.test_support_cache.SupportCache.test_added_worded_relation_gets_own_check_and_negative_is_dropped",
    () {
      final result = _run('pipeline.run.Runner.add_support', _record(), {
        'addRelations': true,
        'checkAndFamilies': 'supportAll',
        'relationsByJudge': {
          'a|b': {
            'ties': [
              {'role': 'other', 'family': 'social', 'p': 0.9},
            ],
            'state': null,
            'stance': null,
          },
        },
        'nameRelations': {
          'a|b': {'b_is': '房东'},
        },
        'verifyRecords': {'r0': _verdict('not_in_passage')},
      });
      expect(result['combinedKeys'], unorderedEquals(['e0', 'a0']));
      expect(result['verifiedKeys'], ['r0']);
      final rec = result['record'] as Map<String, Object?>;
      final data = rec['data'] as Map<String, Object?>;
      final relation =
          (data['rels'] as List<Object?>).first as Map<String, Object?>;
      expect(relation['by'], 'judge+llm');
      final support = rec['support'] as Map<String, Object?>;
      final dropped = _tuple('pipeline.run.drop_unsupported', {
        'data': data,
        'support': support,
      });
      expect((dropped[0] as Map<String, Object?>)['rels'], isEmpty);
      expect(dropped[1], [
        ['r0', 0.0, 'not_in_passage'],
      ]);
      expect(support['a0'], _verdict());
      expect(
        (rec['support_fingerprints'] as Map<String, Object?>).keys,
        unorderedEquals(['e0', 'a0', 'r0']),
      );
    },
    skip: 'A5 relation support and deterministic judge adapters are pending.',
  );
  test(
    "tests.test_support_cache.SupportCache.test_changed_existing_wording_invalidates_only_its_old_check",
    () {
      final rec = _record(legacy: true);
      final data = rec['data'] as Map<String, Object?>;
      data['rels'] = [
        {'a': 'a', 'b': 'b', 'b_is': 'B 对 A 而言是一个有待确认的关系', 'a_is': ''},
      ];
      (rec['support'] as Map<String, Object?>)['r0'] = _verdict();
      final result = _run('pipeline.run.Runner.add_support', rec, {
        'addRelations': true,
        'checkAndFamilies': 'supportAll',
        'relationsByJudge': {
          'a|b': {
            'ties': [
              {'role': 'friend', 'family': 'social', 'p': 0.9},
            ],
            'state': null,
            'stance': null,
          },
        },
        'verifyRecords': {'r0': _verdict('contradicted')},
      });
      expect(result['combinedQuestions'], isEmpty);
      expect(result['verifiedKeys'], ['r0']);
      final updated = result['record'] as Map<String, Object?>;
      final updatedData = updated['data'] as Map<String, Object?>;
      final relation =
          (updatedData['rels'] as List<Object?>).first as Map<String, Object?>;
      expect(relation['b_is'], '朋友');
      final dropped = _tuple('pipeline.run.drop_unsupported', {
        'data': updatedData,
        'support': updated['support'],
      });
      expect((dropped[0] as Map<String, Object?>)['rels'], isEmpty);
      expect((updated['support'] as Map<String, Object?>)['e0'], _verdict());
    },
    skip: 'A5 relation-wording fingerprints and support reuse are pending.',
  );
  test(
    "tests.test_support_cache.SupportCache.test_confident_context_judge_corrects_a_canonical_reversed_role",
    () {
      final rec = _record(legacy: true);
      rec['relation_context'] = {
        'story_before_this_passage': 'Alice is Bob’s mother.',
        'character_context': {
          'a': {
            'known_before': {'bio': 'Bob的母亲'},
          },
          'b': {
            'known_before': {'bio': 'Alice的儿子'},
          },
        },
      };
      (rec['data'] as Map<String, Object?>)['rels'] = [
        {'a': 'a', 'b': 'b', 'b_is': '父母', 'a_is': '子女'},
      ];
      (rec['support'] as Map<String, Object?>)['r0'] = _verdict();
      final result = _run('pipeline.run.Runner.add_support', rec, {
        'addRelations': true,
        'checkAndFamilies': 'supportAll',
        'relationsByJudge': {
          'a|b': {
            'ties': [
              {'role': 'child', 'family': 'kin', 'p': 0.97},
            ],
            'state': null,
            'stance': null,
          },
        },
        'verifyRecords': {'r0': _verdict()},
      });
      final relation =
          (((result['record'] as Map<String, Object?>)['data']
                          as Map<String, Object?>)['rels']
                      as List<Object?>)
                  .first
              as Map<String, Object?>;
      expect([relation['b_is'], relation['a_is']], ['子女', '父母']);
      expect(result['relationJudgeContext'], rec['relation_context']);
    },
    skip: 'A5 relation context and canonical role correction are pending.',
  );
  test(
    "tests.test_support_cache.SupportCache.test_legacy_cached_rewrite_is_checked_once_and_other_keys_survive",
    () {
      final rec = _record(legacy: true);
      rec['judge_rels'] = <String, Object?>{};
      (rec['data'] as Map<String, Object?>)['rels'] = [
        {'a': 'a', 'b': 'b', 'b_is': '朋友', 'fixed_by': 'judge'},
      ];
      (rec['support'] as Map<String, Object?>)['r0'] = _verdict();
      final result = _run('pipeline.run.Runner.add_support', rec, {
        'repeat': 2,
        'verifyRecords': {'r0': _verdict()},
      });
      expect(result['verifyCalls'], 1);
      expect(result['verifiedKeys'], ['r0']);
      final updated = result['record'] as Map<String, Object?>;
      expect(updated['support_sampling'], 'legacy');
      expect(updated['support_legacy_adopted'], unorderedEquals(['e0', 'a0']));
    },
    skip: 'A5 legacy support adoption and no-repeat verification are pending.',
  );
  test(
    "tests.test_support_cache.SupportCache.test_fingerprints_detect_changed_claim_and_complete_passage",
    () {
      final result = _run(
        'pipeline.run.Runner.add_support',
        _record(legacy: true),
        {
          'steps': [
            {'verifyRecords': <String, Object?>{}},
            {
              'changeFactValue': 'a different identity',
              'verifyRecords': {'a0': _verdict('not_in_passage')},
            },
            {
              'insertBookTextAt': 300,
              'insertBookText': 'changed evidence',
              'verifyRecords': {'a0': _verdict(), 'e0': _verdict()},
            },
          ],
        },
      );
      final calls =
          (result['verifyKeysByStep'] as List<Object?>).cast<List<Object?>>();
      expect(calls[0], isEmpty);
      expect(calls[1], unorderedEquals(['a0']));
      expect(calls[2], unorderedEquals(['a0', 'e0']));
      final fingerprints =
          (result['fingerprintsByStep'] as List<Object?>)
              .cast<Map<String, Object?>>();
      expect(fingerprints[1]['e0'], fingerprints[0]['e0']);
      expect(fingerprints[2]['e0'], isNot(fingerprints[0]['e0']));
    },
    skip:
        'A5 full-passage support fingerprints and selective retry are pending.',
  );
  test(
    "tests.test_support_cache.SupportCache.test_fresh_event_sampling_is_stable_and_legacy_sampling_is_preserved",
    () {
      final data = _data();
      data['events'] = [
        for (var i = 0; i < 60; i++) {'text': 'Ordinary event $i.', 'imp': 1},
      ];
      final result = _run(
        'pipeline.run.Runner.support_items',
        {
          'data': data,
          'support': {'a0': _verdict()},
        },
        {
          'eventCheckOneIn': 6,
          'hashResults': [0, 1],
          'adoptPreviouslyCheckedUnsampledEvent': true,
        },
      );
      final first = result['firstItems'] as Map<String, Object?>;
      final second = result['secondItems'] as Map<String, Object?>;
      expect(first, second);
      final sampled = first.keys.where((key) => key.startsWith('e')).toList();
      expect(sampled.length, greaterThan(0));
      expect(sampled.length, lessThan(60));
      final oldKey = result['unsampledLegacyKey'] as String;
      expect(sampled, isNot(contains(oldKey)));
      expect(result['verifyCallsAfterLegacyAdoption'], 0);
      expect(result['finalSupportKeys'], unorderedEquals([oldKey, 'a0']));
    },
    skip:
        'A5 deterministic event sampling and legacy support adapter are pending.',
  );
  test(
    "tests.test_support_cache.SupportCache.test_failed_check_retries_from_cache_without_reextracting",
    () {
      final result = _run('pipeline.run.Runner._local_job', _record(), {
        'judgeRelations': false,
        'extractLocal': {
          'data': _data(),
          'usage': {'prompt_tokens': 3, 'completion_tokens': 4, '_raw': '{}'},
        },
        'verifyRecords': [
          {'error': 'judge unavailable'},
          {'e0': _verdict(), 'a0': _verdict()},
        ],
        'runTwice': true,
      });
      expect(result['firstError'], contains('judge unavailable'));
      expect(
        (result['cachedRecord'] as Map<String, Object?>).containsKey(
          'support_error',
        ),
        isTrue,
      );
      expect(result['extractCalls'], 1);
      expect(result['sleepCalls'], 0);
      expect(result['verifyCalls'], 2);
      expect(
        (result['finalRecord'] as Map<String, Object?>).containsKey(
          'support_error',
        ),
        isFalse,
      );
    },
    skip: 'A5 failed-judge cache reuse without extraction is pending.',
  );
  test(
    "tests.test_support_cache.SupportCache.test_partial_answer_retries_only_missing_question",
    () {
      final result = _run('pipeline.run.Runner.add_support', _record(), {
        'verifyRecords': [
          {'a0': _verdict()},
          {'e0': _verdict()},
        ],
        'retryFromSavedRecord': true,
      });
      expect(result['firstErrorType'], 'LLMError');
      final cached = result['cachedRecord'] as Map<String, Object?>;
      expect((cached['support'] as Map<String, Object?>).keys, ['a0']);
      final calls =
          (result['verifyKeysByCall'] as List<Object?>).cast<List<Object?>>();
      expect(calls[0], unorderedEquals(['a0', 'e0']));
      expect(calls[1], ['e0']);
    },
    skip:
        'A5 partial judge-answer persistence and selective retry are pending.',
  );
  test(
    "tests.test_support_cache.SupportCache.test_relation_failure_keeps_successful_checks_and_never_reextracts",
    () {
      final result = _run('pipeline.run.Runner._local_job', _record(), {
        'extractLocal': {
          'data': _data(),
          'usage': {'prompt_tokens': 3, 'completion_tokens': 4, '_raw': '{}'},
        },
        'checkAndFamilies': 'supportAll',
        'relationsByJudge': [
          {'error': 'relation unavailable'},
          <String, Object?>{},
        ],
        'runTwice': true,
      });
      expect(result['firstError'], contains('relation unavailable'));
      expect(result['extractCalls'], 1);
      expect(result['verifyCalls'], 0);
      final calls =
          (result['combinedQuestionsByCall'] as List<Object?>)
              .cast<List<Object?>>();
      expect(calls[0], unorderedEquals(['e0', 'a0']));
      expect(calls[1], isEmpty);
      expect(
        (result['finalRecord'] as Map<String, Object?>).containsKey(
          'relation_check_error',
        ),
        isFalse,
      );
    },
    skip: 'A5 relation-judge retry from cached extraction is pending.',
  );
}
