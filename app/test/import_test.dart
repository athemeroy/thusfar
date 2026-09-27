import 'dart:convert';
import 'dart:io';

import "dart:typed_data";

import "package:crypto/crypto.dart" as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/backup.dart';
import 'package:thusfar_app/data/library.dart';

void main() {
  test('TXT and EPUB import like 1.7.x upload, and re-import is recognised', () async {
    final Directory root = Directory.systemTemp.createTempSync('thusfar-import');
    final Library lib = Library(root);
    await lib.scan();
    final List<int> txt = File('../oracle/corpus/books/aq.txt').readAsBytesSync();
    final ImportResult a = await importBookFile(lib, '阿Q正传.txt', Uint8List.fromList(txt));
    expect(a.error, isNull);
    expect(a.id, crypto.sha1.convert(txt).toString().substring(0, 16));
    final Map<String, Object?> book = jsonDecode(File('${root.path}/books/${a.id}/book.json').readAsStringSync()) as Map<String, Object?>;
    expect(book['title'], '阿Q正传');
    expect(book['genre'], 'novel');
    expect(File('${root.path}/books/${a.id}/source.txt').existsSync(), isTrue);
    final ImportResult again = await importBookFile(lib, '阿Q正传.txt', Uint8List.fromList(txt));
    expect(again.existed, isTrue);

    final ImportResult e = await importBookFile(lib, 'notes.epub', File('../oracle/corpus/synthetic/footnote_illustration.epub').readAsBytesSync());
    expect(e.error, isNull);
    await lib.scan();
    expect(lib.books.length, 2);
    final ImportResult bad = await importBookFile(lib, 'empty.txt', File('../oracle/corpus/synthetic/empty.txt').readAsBytesSync());
    expect(bad.error, '没有读到文字内容。');
    root.deleteSync(recursive: true);
  });
}
