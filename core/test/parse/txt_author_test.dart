import 'package:test/test.dart';
import 'package:thusfar_core/src/pipeline/parse.dart';

void main() {
  // Same inputs and answers as pipeline.parse.txt_author in Python.
  final List<(List<String>, String, String)> cases = [
    (<String>['故乡', '', '鲁迅', '我冒了严寒'], '故乡', '鲁迅'),
    (<String>['第一章 雾港清晨', '林舟来到码头。', '沈砚'], 'x', ''),
    (<String>['书名', '作者：金庸', '正文'], 'y', '金庸'),
    (<String>['射雕', '作者: 金庸 ', '正文'], '射雕', '金庸'),
    (<String>['故乡', '第一章', '正文'], '故乡', ''),
    (<String>['故乡', '我冒了严寒，回到相隔二千馀里', 'x'], '故乡', ''),
  ];
  for (final (List<String> lines, String stem, String author) in cases) {
    test('txtAuthor ${lines.take(2).join('/')}', () {
      expect(txtAuthor(lines, stem), author);
    });
  }
}
