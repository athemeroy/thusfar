import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/web/ask_selection.dart';

void main() {
  final List<AskSourceJson> blocks = <AskSourceJson>[
    <String, Object?>{'k': 'p', 'o': 0, 't': '已读开头。'},
    <String, Object?>{'k': 'p', 'o': 5, 't': '选中😀这段。UNREAD_SECRET'},
    <String, Object?>{'k': 'p', 'o': 25, 't': 'LATER_CHAPTER'},
  ];
  test(
    'verified partial source ends exactly at selection, rejecting fabricated or split-surrogate text',
    () {
      final List<VerifiedAskFragment> safe = verifyAskSelection(
        blocks: blocks,
        chapterStart: 0,
        chapterEnd: 2,
        text: '选中😀这段。',
        start: 5,
        end: 12,
      );
      expect(safe.single.text, '选中😀这段。');
      expect(safe.single.end, 12);
      expect(safe.single.text, isNot(contains('UNREAD_SECRET')));
      expect(
        verifyAskSelection(
          blocks: blocks,
          chapterStart: 0,
          chapterEnd: 2,
          text: 'invented',
          start: 5,
          end: 12,
        ),
        isEmpty,
      );
      expect(
        verifyAskSelection(
          blocks: blocks,
          chapterStart: 0,
          chapterEnd: 2,
          text: 'LATER_CHAPTER',
          start: 25,
          end: 38,
        ),
        isEmpty,
      );
      expect(
        verifyAskSelection(
          blocks: blocks,
          chapterStart: 0,
          chapterEnd: 2,
          text: '选中',
          start: 5,
          end: 8,
        ),
        isEmpty,
      );
    },
  );
  test(
    'multi-paragraph verification includes only matching source fragments',
    () {
      final List<AskSourceJson> source = <AskSourceJson>[
        <String, Object?>{'k': 'p', 'o': 0, 't': '甲在这里。'},
        <String, Object?>{'k': 'p', 'o': 6, 't': '乙也在。未读部分'},
      ];
      final List<VerifiedAskFragment> verified = verifyAskSelection(
        blocks: source,
        chapterStart: 0,
        chapterEnd: 2,
        text: '在这里。\n乙也在。',
        start: 1,
        end: 10,
      );
      expect(verified.map((e) => e.text).toList(), <String>['在这里。', '乙也在。']);
      expect(verified.last.end, 10);
      expect(verified.map((e) => e.text).join(), isNot(contains('未读部分')));
      expect(
        verifyAskSelection(
          blocks: source,
          chapterStart: 0,
          chapterEnd: 2,
          text: '甲在这里。\n乙也在。',
          start: 1,
          end: 10,
        ),
        isEmpty,
      );
    },
  );

  test(
    'selection cannot cross a non-prose block or malformed chapter range',
    () {
      final List<AskSourceJson> source = <AskSourceJson>[
        <String, Object?>{'k': 'p', 'o': 0, 't': '开头。'},
        <String, Object?>{'k': 'h', 'o': 3, 't': '后章标题'},
        <String, Object?>{'k': 'p', 'o': 7, 't': '结尾。'},
      ];
      expect(
        verifyAskSelection(
          blocks: source,
          chapterStart: 0,
          chapterEnd: 3,
          text: '开头。\n后章标题\n结尾。',
          start: 0,
          end: 10,
        ),
        isEmpty,
      );
      expect(
        verifyAskSelection(
          blocks: source,
          chapterStart: 0,
          chapterEnd: 4,
          text: '开头。',
          start: 0,
          end: 3,
        ),
        isEmpty,
      );
    },
  );
}
