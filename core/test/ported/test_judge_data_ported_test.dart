// Contracts translated from tests/test_judge_data.py. The named data-tool
// adapters remain skipped until their Dart replacements are available.
import 'dart:convert';

import 'package:test/test.dart';

import 'contract_invoker.dart';

Object? dataCall(String id, Map<String, Object?> args) => callPorted(id, args);
Map<String, Object?> obj(Object? value) => value as Map<String, Object?>;
List<Object?> list(Object? value) => value as List<Object?>;
List<Object?> tuple(Object? value) => list(obj(value)[r'$tuple']);
String repeated(String text, int count) => List.filled(count, text).join();

void main() {
  test(
    "tests.test_judge_data.StateFormat.test_export_matches_what_the_pipeline_sends",
    () {
      for (final state in <Object?>[
        {'this_passage': '甲乙丙'},
        {
          'this_passage': 'x',
          'known_characters': ['A', 'B'],
        },
        {
          'passages': [
            {'t': 'a'},
          ],
          'note': '',
        },
        'already a string',
      ]) {
        expect(
          dataCall('scripts.export_judge_data.state_text', {'state': state}),
          dataCall('pipeline.llm._state_text', {'state': state}),
          reason: '$state',
        );
      }
    },
    skip:
        'Dart scripts.export_judge_data.state_text and pipeline.llm._state_text adapters are pending (A3); export and serving must format state identically.',
  );
  test(
    "tests.test_judge_data.Windowing.test_finds_what_the_claim_borrowed_from_the_passage",
    () {
      final passage =
          '${repeated('甲', 900)}去看悉德·菲尔德的书，他开创了编剧理论。${repeated('乙', 900)}';
      const claim = '作者提及悉德·菲尔德是开创编剧理论的大师';
      final shared = list(
        dataCall('scripts.export_judge_data.shared', {
          'claim': claim,
          'passage': passage,
        }),
      );
      expect(shared, contains('悉德·菲尔德'));
      final window =
          dataCall('scripts.export_judge_data.focus', {
                'passage': passage,
                'instructions': 'is this supported? CLAIM: $claim',
                'radius': 300,
              })
              as String;
      expect(window, contains('悉德·菲尔德'));
      expect(window.length, lessThan(passage.length));
    },
    skip:
        'Dart scripts.export_judge_data.shared/focus windowing adapters are pending (A3 data-tool compatibility).',
  );
  test(
    "tests.test_judge_data.Windowing.test_keeps_the_people_the_question_names",
    () {
      final passage = '${repeated('丙', 1200)}张三对李四说话。${repeated('丁', 1200)}';
      const ask =
          'In this_passage, what kind of tie is between 「张三」 (A) and 「李四」 (B)?';
      final names = list(
        dataCall('scripts.export_judge_data.anchors', {
          'instructions': ask,
          'passage': passage,
        }),
      );
      expect(names.map((e) => e as String).toList()..sort(), ['张三', '李四']);
      final window =
          dataCall('scripts.export_judge_data.focus', {
                'passage': passage,
                'instructions': ask,
                'radius': 200,
                'cap': 800,
              })
              as String;
      expect(window, contains('张三'));
      expect(window, contains('李四'));
    },
    skip:
        'Dart scripts.export_judge_data.anchors/focus person-name windowing adapters are pending (A3 data-tool compatibility).',
  );
  test(
    "tests.test_judge_data.Windowing.test_no_anchor_keeps_the_passage_rather_than_its_opening",
    () {
      final window =
          dataCall('scripts.export_judge_data.focus', {
                'passage': repeated('戊', 2000),
                'instructions': 'CLAIM: 完全不相干的说法',
                'radius': 300,
                'cap': 1500,
              })
              as String;
      expect(window.length, 1500);
    },
    skip:
        'Dart scripts.export_judge_data.focus no-anchor fallback adapter is pending (A3 data-tool compatibility).',
  );
  test(
    "tests.test_judge_data.Splits.test_full_evidence_and_options_distinguish_questions",
    () {
      final common = repeated('same beginning ', 60);
      Object? decision(String passage, String answer) =>
          dataCall('scripts.export_judge_data.decision_id', {
            'instructions': 'q',
            'passage': passage,
            'options': {'a': answer},
          });
      expect(
        decision('${common}alive', 'yes'),
        isNot(decision('${common}dead', 'yes')),
      );
      expect(decision(common, 'yes'), isNot(decision(common, 'no')));
    },
    skip:
        'Dart scripts.export_judge_data.decision_id full-evidence hash adapter is pending (A3 data-tool compatibility).',
  );
  test(
    "tests.test_judge_data.Splits.test_reruns_of_one_book_are_one_work",
    () {
      Object? work(String title) =>
          dataCall('scripts.export_judge_data.work_of', {'title': title});
      final reruns = [
        '包法利夫人（关系树 v11）',
        '包法利夫人（裁判做关系 v9）',
        '包法利夫人（flash-lite 全流程）',
      ];
      expect({for (final title in reruns) work(title)}, hasLength(1));
      expect(work('儒林外史'), isNot(work('包法利夫人')));
    },
    skip:
        'Dart scripts.export_judge_data.work_of book-grouping adapter is pending (A3 data-tool compatibility).',
  );
  test(
    "tests.test_judge_data.Labels.test_options_become_english_sentences",
    () {
      expect(
        dataCall('scripts.gliclass_data.phrase_of', {
          'key': 'supported',
          'desc': 'whatever',
        }),
        'the passage supports this',
      );
      expect(
        dataCall('scripts.gliclass_data.phrase_of', {
          'key': 'kin',
          'desc': 'They are family by blood (parent, child)',
        }),
        'They are family by blood',
      );
    },
    skip:
        'Dart scripts.gliclass_data.phrase_of English-label adapter is pending (A3 data-tool compatibility).',
  );
  test(
    "tests.test_judge_data.Labels.test_two_options_never_collapse_into_one_label",
    () {
      final result = tuple(
        dataCall('scripts.gliclass_data.labels_of', {
          'options': {'a': 'same words', 'b': 'same words'},
        }),
      );
      expect(list(result[0]).toSet(), hasLength(2));
      expect(obj(result[1]).values.toSet(), {'a', 'b'});
    },
    skip:
        'Dart scripts.gliclass_data.labels_of collision-safe label adapter is pending (A3 data-tool compatibility).',
  );
  test(
    "tests.test_judge_data.Labels.test_round_trip_through_the_wire_format",
    () {
      final options = {
        'supported': 'The passage states it.',
        'not_in_passage': 'The passage does not say.',
        'contradicted': 'The passage says otherwise.',
      };
      final instructions =
          'Judging only this_passage: is this supported? CLAIM: 张三是李四的哥哥\n'
          'Choose one label:\n${options.entries.map((e) => '- ${e.key}: ${e.value}').join('\n')}';
      final decoded = tuple(
        dataCall('scripts.judge_server.criteria_of', {
          'labels': options.keys.toList(),
          'instructions': instructions,
        }),
      );
      final criteria = obj(decoded[0]);
      expect(criteria, options);
      expect(decoded[1], isNot(contains('Choose one label')));
      final encoded = tuple(
        dataCall('scripts.gliclass_data.labels_of', {'options': criteria}),
      );
      expect(
        obj(encoded[1]).values.map((e) => e as String).toList()..sort(),
        options.keys.toList()..sort(),
      );
      expect(list(encoded[0]).first, 'the passage supports this');
    },
    skip:
        'Dart scripts.judge_server.criteria_of and scripts.gliclass_data.labels_of wire-format adapters are pending (A3 data-tool compatibility).',
  );
  test(
    "tests.test_judge_data.LogIntegrity.test_missing_state_is_not_exported_as_empty_passage",
    () {
      final question = {
        'state': 'missing',
        'instructions': 'q',
        'criteria': {'yes': 'yes'},
        'choice': 'yes',
        'probabilities': {'yes': 1},
      };
      // Test adapter materializes relative files in an isolated directory,
      // invokes from_logs and returns rows or a tagged `$error`.
      final result = obj(
        dataCall('scripts.export_judge_data.from_logs', {
          'files': {
            'work/judge/states.jsonl': '',
            'work/judge/questions.jsonl': '${jsonEncode(question)}\n',
          },
          'meta': {'book': 'fixture'},
          'rows': <Object?>[],
        }),
      );
      final error = obj(result[r'$error']);
      expect(error['type'], 'ValueError');
      expect(error['message'], contains('不存在的原文'));
    },
    skip:
        'Dart scripts.export_judge_data.from_logs isolated-file adapter is pending (A3 data-tool compatibility); missing state must reject export.',
  );
  test(
    "tests.test_judge_data.LogIntegrity.test_corrupt_interior_line_is_not_silently_skipped",
    () {
      final result = obj(
        dataCall('scripts.export_judge_data.read_log', {
          'path': 'log.jsonl',
          'content': '{}\nbroken\n{}\n',
        }),
      );
      final error = obj(result[r'$error']);
      expect(error['type'], 'ValueError');
      expect(error['message'], contains('日志损坏'));
    },
    skip:
        'Dart scripts.export_judge_data.read_log append-only parser adapter is pending (A3 data-tool compatibility); corrupt interior rows must reject.',
  );
}
