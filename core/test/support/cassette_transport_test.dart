import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/llm.dart';
import 'package:thusfar_core/src/pipeline/provenance.dart';

import 'cassette_transport.dart';

void main() {
  final Directory directory = Directory('../oracle/cassettes/live');
  late CassetteTransport tape;
  late List<Json> candidates;
  setUpAll(() {
    tape = CassetteTransport(directory);
    candidates = <Json>[];
    for (final File file in directory.listSync().whereType<File>()) {
      if (!file.path.endsWith('.json')) continue;
      final Json row = jsonDecode(file.readAsStringSync()) as Json;
      if (row['request'] is! Json ||
          (row['attempts']! as List<Object?>).isEmpty)
        continue;
      final Json first = (row['attempts']! as List<Object?>).first! as Json;
      if (first['kind'] != 'response' || first['read_error'] != null) continue;
      final String url = (row['request']! as Json)['url']! as String;
      if (candidates.any(
        (Json r) => ((r['request']! as Json)['url']! as String) == url,
      ))
        continue;
      candidates.add(row);
      if (candidates.length == 2) break;
    }
  });
  test(
    'real stored model and judge responses replay through chat transport',
    () async {
      expect(candidates.length, 2);
      for (final Json row in candidates) {
        final Json request = row['request']! as Json;
        final ChatResponse response = await tape.post(
          ChatRequest(
            Uri.parse(request['url']! as String),
            (request['headers']! as Json).cast<String, String>(),
            jsonEncode(jsonDecode(request['body_utf8']! as String)),
          ),
          const Duration(seconds: 1),
        );
        final List<int> actual = <int>[];
        await for (final List<int> chunk in response.body) {
          actual.addAll(chunk);
        }
        final Json expected =
            (row['attempts']! as List<Object?>).first! as Json;
        final List<int> bytes = <int>[
          for (final Object? chunk
              in expected['chunks_base64']! as List<Object?>)
            ...base64.decode(chunk! as String),
        ];
        expect(response.status, expected['status']);
        expect(digest(actual), digest(bytes));
      }
      expect(tape.calls, 2);
      expect(tape.misses, isEmpty);
    },
  );
  test('unknown requests fail without a network fallback', () async {
    await expectLater(
      tape.post(
        ChatRequest(Uri.parse('https://offline.invalid/test'), <String, String>{
          'Content-Type': 'application/json',
        }, '{"unknown":true}'),
        const Duration(seconds: 1),
      ),
      throwsA(isA<MissingCassette>()),
    );
    expect(tape.misses.length, 1);
    expect(tape.calls, 2);
  });
}
