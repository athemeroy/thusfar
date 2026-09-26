import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../golden/codec.dart';
import 'link_adapters.dart';

void main() {
  for (final MapEntry<String, Object? Function(Json)> e
      in linkAdapters.entries) {
    test('${e.key} matches every existing Python function golden', () async {
      final File source = File(
        '../oracle/goldens/pipeline/link/${e.key.split('.').last}.jsonl',
      );
      int count = 0;
      await for (final String line in source
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())) {
        final Json sample = jsonDecode(line) as Json;
        final Json input = decodeInput(sample['input'])! as Json;
        expect(
          e.value(input),
          sample['output'],
          reason: '${source.path} #${++count}',
        );
      }
      expect(count, greaterThan(0));
    });
  }
}
