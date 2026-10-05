import 'dart:convert';

import 'package:test/test.dart';
import 'package:thusfar_core/ask_context.dart';

void main() {
  test(
    'references are exact book/cutoff scoped and limited to the last three pairs',
    () {
      final List<AskTurn> turns = <AskTurn>[
        const AskTurn(
          bookId: 'other',
          cutoff: 20,
          question: 'other book',
          answer: 'PRIVATE',
        ),
        const AskTurn(
          bookId: 'book',
          cutoff: 21,
          question: 'future',
          answer: 'FUTURE',
        ),
        for (int i = 0; i < 8; i++)
          AskTurn(bookId: 'book', cutoff: 20, question: 'q$i', answer: 'a$i'),
      ];
      final String result = boundedAskContext(turns, 'book', 20);
      expect(result, contains('q5'));
      expect(result, contains('q7'));
      expect(result, isNot(contains('q4')));
      expect(result, isNot(contains('PRIVATE')));
      expect(result, isNot(contains('FUTURE')));
      expect(boundedAskContext(turns, 'book', 19), isEmpty);
      expect(utf8.encode(result).length, lessThanOrEqualTo(12000));
    },
  );

  test('limits preserve complete emoji clusters and never silently truncate', () {
    final String question = List<String>.filled(500, 'a${'\u0301' * 100}').join();
    // The byte cap is a separate, disclosed hard limit for pathological clusters.
    expect(
      validateAskInput(
        List<String>.filled(500, '😀').join(),
        selection: '段' * 1200,
      ),
      isNull,
    );
    expect(validateAskInput('问' * 501), contains('没有被截断'));
    expect(
      validateAskInput('完整问题', selection: '段' * 1201),
      contains('问题会完整保留'),
    );
    expect(validateAskInput(question), contains('没有被截断'));
  });
}
