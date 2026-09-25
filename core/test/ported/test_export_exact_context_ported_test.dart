// Translated Python 1.7.5 teacher-data provenance contracts.
// The owning Dart data-export tool is staged with the A4 judge input and C archive.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'contract_invoker.dart';

const _instructions = 'Judge the note. NOTE: tail evidence.';
const _criteria = <String, Object?>{
  'supported': 'Established',
  'missing': 'Absent',
};

Map<String, Object?> _export(Object state, int radius) =>
    callPorted('scripts.export_judge_data.from_logs', {
          // Test adapter constructs one states.jsonl and one questions.jsonl,
          // then returns the first exported row without a model call.
          'state': state,
          'radius': radius,
          'question': {
            'state': 'state',
            'instructions': _instructions,
            'criteria': _criteria,
            'choice': 'supported',
            'probabilities': {'supported': 0.9, 'missing': 0.1},
          },
        })
        as Map<String, Object?>;

Object? _decisionId(String passage) => callPorted(
  'scripts.export_judge_data.decision_id',
  {'instructions': _instructions, 'passage': passage, 'options': _criteria},
);

void main() {
  test(
    "tests.test_export_exact_context.ExactTeacherContextTests.test_zero_window_keeps_tail_beyond_old_cap",
    () {
      final original =
          List.filled(13000, 'x').join() + ' decisive tail evidence';
      final row = _export(original, 0);
      expect(row['passage'], original);
      expect(row['context_exact'], isTrue);
      expect(
        row['original_passage_sha256'],
        sha256.convert(utf8.encode(original)).toString(),
      );
      expect(row['teacher_input_sha256'], _decisionId(original));
    },
    skip: 'A4/C Dart exact-context data-export adapter is pending.',
  );
  test(
    "tests.test_export_exact_context.ExactTeacherContextTests.test_cropped_context_is_explicitly_unverified",
    () {
      final original =
          List.filled(13000, 'x').join() + ' decisive tail evidence';
      final row = _export(original, 300);
      final cropped = row['passage'] as String;
      expect(cropped, isNot(original));
      expect(row['context_exact'], isFalse);
      expect(row['teacher_input_sha256'], isNot(_decisionId(cropped)));
    },
    skip: 'C Dart data-export provenance adapter is pending.',
  );
  test(
    "tests.test_export_exact_context.ExactTeacherContextTests.test_structured_state_preserves_all_sections_and_order",
    () {
      final state = <String, Object?>{
        'characters': 'Hamlet',
        'this_passage': 'Horatio enters.',
        'notes': ['evidence'],
      };
      final row = _export(state, 0);
      final serialized = callPorted('scripts.export_judge_data.state_text', {
        'state': state,
      });
      expect(row['passage'], serialized);
      expect(row['passage'], contains('[this_passage]\nHoratio enters.'));
      expect(row['context_exact'], isTrue);
    },
    skip: 'A4/C ordered judge-state serialization adapter is pending.',
  );
}
