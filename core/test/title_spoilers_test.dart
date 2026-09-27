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
}
