import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/book_policy.dart';
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/errors.dart';

class RecordedBackend implements BookPolicyBackend {
  RecordedBackend(this.fixture);
  final Json fixture;
  final List<Json> calls = <Json>[];
  int index = 0;

  @override
  Future<Json> evaluate(Json state, Json questions) async {
    calls.add(<String, Object?>{
      'type': 'judge',
      'state': state,
      'questions': questions,
    });
    final Object? value = (fixture['replies']! as List<Object?>)[index++];
    if (value == '__error__') throw StateError('offline judge failure');
    return value! as Json;
  }

  @override
  Future<Object?> generate(
    String model,
    List<Map<String, String>> messages,
  ) async {
    calls.add(<String, Object?>{
      'type': 'chat',
      'model': model,
      'messages': messages,
      'kwargs': <String, Object?>{'max_tokens': 4000, 'temperature': 0},
    });
    if (fixture['chat'] == '__error__')
      throw StateError('offline chat failure');
    return fixture['chat'];
  }
}

void main() {
  final Json fixtures =
      jsonDecode(
            File(
              '../oracle/goldens/special/book-policy.json',
            ).readAsStringSync(),
          )
          as Json;
  late Map<String, String> before;
  setUp(() {
    before = Map<String, String>.of(environ);
  });
  tearDown(() {
    environ
      ..clear()
      ..addAll(before);
  });
  final List<Object?> cases = fixtures['cases']! as List<Object?>;
  for (int i = 0; i < cases.length; i++) {
    final Json fixture = cases[i]! as Json;
    test(
      'Python request and result parity $i ${fixture['operation']}',
      () async {
        environ
          ..clear()
          ..addAll((fixture['env']! as Json).cast<String, String>());
        final RecordedBackend backend = RecordedBackend(fixture);
        final Json book = fixture['book']! as Json;
        final Object? result;
        switch (fixture['operation']) {
          case 'judge':
            result = await classifyByJudge(book, backend: backend);
          case 'classify':
            result = await classifyChapters(book, backend: backend);
          case 'detect':
            final (String kind, double p) = await detectKind(
              book,
              backend: backend,
            );
            result = <Object?>[kind, p];
          default:
            throw StateError('unknown fixture');
        }
        expect(result, fixture['expected']);
        expect(backend.calls, fixture['requests']);
        expect(backend.index, (fixture['replies']! as List<Object?>).length);
      },
    );
  }
  test(
    'ordinal boundaries match Python including supplementary characters',
    () {
      for (final List<Object?> row
          in (fixtures['ordinals']! as List<Object?>).cast<List<Object?>>()) {
        expect(ordinal(row[0] as String?), row[1], reason: '${row[0]}');
      }
    },
  );
  test('collections retain independent ranges', () {
    for (final Json row in (fixtures['works']! as List<Object?>).cast<Json>()) {
      expect(<List<int>>[
        for (final (int a, int b) in works(
          row['book']! as Json,
          minChars: row['min_chars']! as int,
        ))
          <int>[a, b],
      ], row['expected']);
    }
  });
  test('Python decimal numerals and large ordinals retain exact integers', () {
    expect(chineseNumber('１２'), 12);
    expect(chineseNumber('١٢'), 12);
    expect(() => chineseNumber('²'), throwsA(isA<ValueError>()));
    final BigInt huge = BigInt.parse('999999999999999999999999999');
    expect(chineseNumber('$huge'), huge);
    expect(ordinal('Chapter $huge'), huge);
  });
}
