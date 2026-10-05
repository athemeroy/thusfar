/// Memory-only, book-and-prefix scoped conversational references.
/// References help resolve pronouns. They are never factual evidence.
library;

import 'dart:convert';

import 'package:characters/characters.dart';

const int askQuestionLimit = 500;
const int askSelectionLimit = 1200;
const int askContextTurns = 3;

class AskTurn {
  const AskTurn({
    required this.bookId,
    required this.cutoff,
    required this.question,
    required this.answer,
  });
  final String bookId;
  final int cutoff;
  final String question;
  final String answer;
}

String? validateAskInput(String question, {String? selection}) {
  if (question.trim().isEmpty) return '请先写下问题';
  if (question.characters.length > askQuestionLimit) {
    return '问题最多 $askQuestionLimit 字，请缩短后再发送；内容没有被截断。';
  }
  if (utf8.encode(question).length > 20000) {
    return '问题的数据量过大，请减少重复的组合符号后再发送；内容没有被截断。';
  }
  if (selection != null && selection.characters.length > askSelectionLimit) {
    return '所选原文最多 $askSelectionLimit 字，请重新选择或移除选文；问题会完整保留。';
  }
  if (selection != null && utf8.encode(selection).length > 48000) {
    return '所选原文的数据量过大，请缩小选区或移除选文；问题会完整保留。';
  }
  return null;
}

/// Exact cutoff equality intentionally rejects both rewound and advanced turns.
/// Limit the number and size before constructing a request or its cache key.
String boundedAskContext(Iterable<AskTurn> history, String bookId, int cutoff) {
  final List<AskTurn> safe =
      history
          .where(
            (AskTurn turn) => turn.bookId == bookId && turn.cutoff == cutoff,
          )
          .toList();
  final StringBuffer result = StringBuffer();
  int remainingBytes = 12000;
  for (final AskTurn turn in safe.skip(
    (safe.length - askContextTurns).clamp(0, safe.length),
  )) {
    final String question =
        turn.question.characters.take(askQuestionLimit).toString();
    final String answer = turn.answer.characters.take(800).toString();
    final String row = '读者：$question\n上次回答：$answer\n';
    final int bytes = utf8.encode(row).length;
    if (bytes > remainingBytes) continue;
    result.write(row);
    remainingBytes -= bytes;
  }
  return result.toString();
}

String askReferenceSection(String context, String? selectedText) => [
  if (context.isNotEmpty) '【同一阅读位置的对话，仅用于理解代词或上一点，不是事实证据】\n$context',
  if (selectedText?.isNotEmpty == true)
    '【读者所选文字，仅作为提问指向，不是独立证据】\n$selectedText',
  if (context.isNotEmpty || selectedText?.isNotEmpty == true)
    '上述对话和提问不能补充事实。所有事实必须由本次材料重新支持；材料没有就说读到这里还看不出来。',
].join('\n\n');
