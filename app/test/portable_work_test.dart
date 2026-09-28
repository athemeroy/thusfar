import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/portable_work.dart';

void main() {
  const String digest =
      '0000000000000000000000000000000000000000000000000000000000000000';
  const String cachePath = 'judge/cache/$digest.json';

  Map<String, Object?> cache(Map<String, Object?> answer) => <String, Object?>{
    'request_sha256': digest,
    'answers': <String, Object?>{'q1': answer},
    'route': 'free',
    'model': 'synthetic-model',
  };

  test('judge cache accepts a numeric probability option named secret', () {
    final Map<String, Object?> value = cache(<String, Object?>{
      'type': 'choice',
      'choice': 'secret',
      'probabilities': <String, Object?>{'secret': 0.8, 'open': 0.2},
    });
    final Map<String, Object?> result = validatedPortableWork(<String, Object?>{
      cachePath: value,
    });
    expect(result[cachePath], equals(value));
  });

  test('judge cache rejects nonnumeric probabilities and token-like IDs', () {
    for (final Map<String, Object?> probabilities in <Map<String, Object?>>[
      <String, Object?>{'secret': 'synthetic-secret'},
      <String, Object?>{'sk-abcdefghijklmnop': 0.5},
    ]) {
      expect(
        () => validatedPortableWork(<String, Object?>{
          cachePath: cache(<String, Object?>{
            'choice': 'secret',
            'probabilities': probabilities,
          }),
        }),
        throwsFormatException,
      );
    }
  });

  test('judge cache still rejects credential-shaped control fields', () {
    expect(
      () => validatedPortableWork(<String, Object?>{
        cachePath: cache(<String, Object?>{
          'choice': 'secret',
          'probabilities': <String, Object?>{'secret': 1.0},
          'api_key': 'synthetic-secret',
        }),
      }),
      throwsFormatException,
    );
  });

  test('diagnostic masks untrusted cache filenames', () {
    final String path = 'drafts/sk-abcdefghijklmnop-$digest.json';
    try {
      validatedPortableWork(<String, Object?>{
        path: <String, Object?>{
          'input_sha256': digest,
          'value': <String, Object?>{'api_key': 'synthetic-secret'},
        },
      });
      fail('Expected a credential rejection');
    } on FormatException catch (error) {
      expect(error.message, contains('drafts/…'));
      expect(error.message, isNot(contains('sk-abcdefghijklmnop')));
    }
  });
}
