import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:test/test.dart';
import 'package:thusfar_core/src/pipeline/epub.dart';
import 'package:thusfar_core/src/pipeline/parse.dart';
import 'package:thusfar_core/src/py/py_re.dart';

// 中文回目与正文回指的边界回归（与 tests/test_parse_chinese.py 同一输入）。
const String reference = '第四回中既将薛家母子在荣府内寄居等事略已表明，此回则暂不能写矣。';
const List<String> titles = <String>['第四回 葫芦僧乱判葫芦案', '第五回游幻境指迷十二钗'];
final List<String> lines = <String>[
  titles[0],
  '正文。' * 100,
  titles[1],
  reference,
  '后文。' * 100,
];

Uint8List epub() {
  final Archive a = Archive();
  void add(String name, String text) {
    final List<int> data = utf8.encode(text);
    a.addFile(ArchiveFile(name, data.length, data));
  }

  add(
    'META-INF/container.xml',
    '<?xml version="1.0"?><container version="1.0" '
        'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
        '<rootfile full-path="content.opf" '
        'media-type="application/oebps-package+xml"/></rootfiles></container>',
  );
  add(
    'content.opf',
    '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" '
        'version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>书</dc:title></metadata><manifest>'
        '<item id="nav" href="nav.xhtml" properties="nav" '
        'media-type="application/xhtml+xml"/>'
        '<item id="c" href="c.xhtml" media-type="application/xhtml+xml"/>'
        '</manifest><spine><itemref idref="c"/></spine></package>',
  );
  add(
    'nav.xhtml',
    '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml" '
        'xmlns:epub="http://www.idpf.org/2007/ops"><body>'
        '<nav epub:type="toc"><ol>'
        '<li><a href="c.xhtml#c4">${titles[0]}</a></li>'
        '<li><a href="c.xhtml#c5">${titles[1]}</a></li>'
        '</ol></nav></body></html>',
  );
  add(
    'c.xhtml',
    '<?xml version="1.0"?><html xmlns="http://www.w3.org/1999/xhtml"><body>'
        '<h2 id="c4">${lines[0]}</h2><p>${lines[1]}</p>'
        '<h2 id="c5">${lines[2]}</h2><p>${lines[3]}</p><p>${lines[4]}</p>'
        '</body></html>',
  );
  return Uint8List.fromList(ZipEncoder().encode(a));
}

void main() {
  test('chapterRe 不把正文回指当回目', () {
    expect(pyMatch(chapterRe, reference), isNull);
    for (final String t in <String>[
      ...titles,
      '第三回：托内兄如海荐西宾',
      '第十回中秋夜宴',
      '第二章里',
    ]) {
      expect(pyMatch(chapterRe, t), isNotNull, reason: t);
    }
  });

  final Map<String, Json Function()> formats = <String, Json Function()>{
    'txt': () => parseTxtText(lines.join('\n'), '书'),
    'epub': () => parseEpub(epub(), '书', (String _, List<int> __) {}),
  };
  formats.forEach((String format, Json Function() parse) {
    test('回指留在第五回（$format）', () {
      final Json book = parse();
      final List<Json> chapters =
          (book['chapters']! as List<Object?>).cast<Json>();
      final List<Json> blocks = (book['blocks']! as List<Object?>).cast<Json>();
      expect(<Object?>[for (final Json c in chapters) c['title']], titles);
      final Json fifth = chapters[1];
      expect(<Object?>[
        for (final Json b in blocks.sublist(
          fifth['b0']! as int,
          fifth['b1']! as int,
        ))
          b['t'],
      ], contains(reference));
      int total = 0;
      for (final Json b in blocks) {
        total += (b['t']! as String).length + 1;
      }
      expect(book['len'], total);
    });
  });
}
