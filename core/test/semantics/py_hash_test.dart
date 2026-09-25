import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/src/py/py_hash.dart';
import 'package:thusfar_core/src/py/py_json.dart';

void main() {
  test('Python hash and 1.7.5 source revision cases match Dart', () {
    int count = 0;
    for (final String line
        in File('../oracle/semantics/hashes.jsonl').readAsLinesSync()) {
      final Map<String, Object?> item =
          jsonDecode(line) as Map<String, Object?>;
      final String id = item['id']! as String;
      if (id == 'extractor-revision') {
        expect(LegacyHashes.extractorRevision, item['sha256']);
      } else if (id.startsWith('utf8-')) {
        expect(
          sha256Hex(utf8.encode(item['value']! as String)),
          item['sha256'],
        );
      } else {
        final String serialized = PyJson.encode(
          item['value'],
          ensureAscii: false,
          sortKeys: true,
          compact: item['compact']! as bool,
        );
        expect(serialized, item['serialized'], reason: id);
        expect(sha256Hex(utf8.encode(serialized)), item['sha256'], reason: id);
      }
      count++;
    }
    expect(count, 12);
  });
}
