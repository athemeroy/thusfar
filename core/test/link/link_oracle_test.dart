import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:thusfar_core/src/pipeline/link.dart' as link;

import '../golden/codec.dart';
import 'link_adapters.dart';

void main() {
  final Json fixture =
      jsonDecode(File('test/link/fixtures/oracles.json').readAsStringSync())
          as Json;
  test('offline link fixtures match the current Python source', () {
    expect(
      sha256.convert(File('../pipeline/link.py').readAsBytesSync()).toString(),
      fixture['source_sha256'],
    );
  });
  final original = link.linkCall;
  tearDown(() => link.linkCall = original);
  for (final Object? row in fixture['cases']! as List<Object?>) {
    final Json sample = row! as Json;
    test('Python oracle: ${sample['case']}', () async {
      final Json input = decodeInput(sample['input'])! as Json;
      final List<Object?> answers = sample['answers']! as List<Object?>;
      final List<Object?> calls = <Object?>[];
      link.linkCall = (Object? state, Json questions) async {
        final int index = calls.length;
        calls.add(<String, Object?>{'state': state, 'questions': questions});
        expect(
          index,
          lessThan(answers.length),
          reason: 'Unexpected Jev request',
        );
        return answers[index]! as Json;
      };
      final Object? result;
      switch (sample['function']) {
        case 'pipeline':
          final g = graph(<String, Object?>{
            'book': input['book'],
            'people': <String, Object?>{},
          });
          final List<Object?> phases = <Object?>[];
          for (final Json stage
              in (input['stages']! as List<Object?>).cast<Json>()) {
            final segment = stage['seg']! as Json;
            final (data, linked) = await link.linkSegment(
              g,
              segment,
              stage['local']! as Json,
              stage['context_text']! as String,
            );
            final planned = g.plan(segment, data);
            final decisions = <String, Object?>{
              for (final Json o
                  in (planned['occs']! as List<Object?>).cast<Json>())
                if (o['ambiguous'] == true)
                  o['key']! as String: (o['ids']! as List<Object?>).first,
            };
            final committed = g.commit(segment, data, planned, decisions);
            // Freeze mutable graph sets/logs at each segment boundary.
            phases.add(
              encodeOutput(<String, Object?>{
                'data': data,
                'linked': linked,
                'plan': planned,
                'committed': committed,
                'people': g.people,
                'mentions': g.mentions,
                'log': g.log,
              }),
            );
          }
          result = phases;
        case 'link_segment':
          result = await link.linkSegment(
            graph(input),
            input['seg']! as Json,
            input['local']! as Json,
            input['context_text']! as String,
            scopeStart: input['scope_start']! as int,
          );
        case 'verify_names':
          final Json decisions = input['decisions']! as Json;
          final value = await link.verifyNames(
            (input['cast']! as Json).cast<String, Json>(),
            (input['people']! as List<Object?>).cast<Json>(),
            decisions,
            input['passage']! as String,
          );
          result = <String, Object?>{'return': value, 'decisions': decisions};
        case '_ask_jev':
          result = await link.askJev(
            <link.LinkQuestion>[
              for (final List<Object?> q
                  in (input['questions']! as List<Object?>)
                      .cast<List<Object?>>())
                (
                  q[0]! as String,
                  q[1]! as Json,
                  (q[2]! as List<Object?>).cast<String>(),
                ),
            ],
            (input['cast']! as Json).cast<String, Json>(),
            input['context_text']! as String,
            localsById: (input['locals_by_id']! as Json).cast<String, Json>(),
          );
        default:
          throw StateError('Unknown function ${sample['function']}');
      }
      expect(
        encodeOutput(calls),
        sample['calls'],
        reason: 'Exact Jev requests preserve prompt/cache inputs',
      );
      expect(calls.length, answers.length);
      expect(encodeOutput(result), sample['output']);
    });
  }
  test(
    'Jev failure propagates instead of treating unresolved identity as new',
    () async {
      link.linkCall =
          (Object? state, Json questions) async =>
              throw StateError('offline failure');
      final g = graph(<String, Object?>{
        'people': <String, Object?>{
          'P1': <String, Object?>{
            'name': 'Alice',
            'aliases': <String>{'Alice'},
            'weak': <String>{'太太'},
          },
        },
      });
      await expectLater(
        link.linkSegment(g, <String, Object?>{}, <String, Object?>{
          'people': <Object?>[
            <String, Object?>{'id': 'a', 'name': '太太'},
          ],
        }, '原文'),
        throwsStateError,
      );
    },
  );
}
