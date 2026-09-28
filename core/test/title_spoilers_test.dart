import 'package:test/test.dart';
import 'package:thusfar_core/title_spoilers.dart';

void main() {
  test('chapter titles hide only confirmed or obvious spoilers', () {
    expect(titleSpoils(false, '第2章 主角身亡'), isFalse);
    expect(titleSpoils(true, '第2章 旧城'), isTrue);
    expect(titleSpoils(null, '第2章 旧城'), isFalse);
    expect(titleSpoils(null, '第2章 主角身亡'), isTrue);
    expect(titleSpoils('false', '第2章 旧城'), isFalse);
    expect(titleSpoils(true, '第2章 旧城', checkPending: true), isFalse);
    expect(
      titleSpoils(true, '第2章 旧城', checkPending: true, checkedByModel: true),
      isTrue,
    );
  });

  test('without a verdict each title is judged by its own words', () {
    for (final String title in <String>[
      '第九十八回　苦绛珠魂归离恨天　病神瑛泪洒相思地',
      '第九十五回　因讹成实元妃薨逝　以假混真宝玉疯颠',
      '第九十七回　林黛玉焚稿断痴情　薛宝钗出闺成大礼',
      '第百零五回　锦衣军查抄宁国府　骢马使弹劾平安州',
      '第九章　大团圆',
      '第六部：失手被擒',
      '第1436章 同归于尽',
      '第433章 他娘的叛变了？',
      '第四十四章：原來是二胎',
      'Chapter 12: The Traitor Unmasked',
    ]) {
      expect(titleSpoils(null, title), isTrue, reason: title);
    }
    for (final String title in <String>[
      '第四回　薄命女偏逢薄命郎　葫芦僧乱判葫芦案',
      '第133章 死亡沙海',
      '第870章 置之死地',
      '第298章 虚境刺杀',
      '第177章 花嫁·剑姬',
      'Die Verwandlung',
      'Chapter 3: The Letter',
    ]) {
      expect(titleSpoils(null, title), isFalse, reason: title);
    }
  });
}
