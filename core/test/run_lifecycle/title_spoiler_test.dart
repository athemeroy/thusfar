import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/run.dart';
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/errors.dart';
import 'package:thusfar_core/src/pipeline/judge.dart' as judge;
import 'package:thusfar_core/src/pipeline/llm.dart' as llm;

typedef Json = Map<String, Object?>;

Directory _book(Directory parent, String name) {
  final Directory root = Directory('${parent.path}/$name')..createSync();
  const String passage = '一个人走过窗边。';
  writeJson(File('${root.path}/book.json'), <String, Object?>{
    'title': '标题核对测试',
    'author': '',
    'lang': 'zh',
    'genre': 'novel',
    'classified': true,
    'len': passage.length * 2,
    'blocks': <Json>[
      <String, Object?>{'k': 'p', 't': passage, 'o': 0},
      <String, Object?>{'k': 'p', 't': passage, 'o': passage.length},
    ],
    'chapters': <Json>[
      <String, Object?>{
        'title': '第 1 章 林间',
        'b0': 0,
        'b1': 1,
        'o0': 0,
        'o1': passage.length,
        'kind': 'body',
        'spoil': false,
      },
      <String, Object?>{
        'title': '第 2 章 谁获胜',
        'b0': 1,
        'b1': 2,
        'o0': passage.length,
        'o1': passage.length * 2,
        'kind': 'body',
      },
    ],
    'notes': <String, Object?>{},
  });
  writeJson(File('${root.path}/status.json'), <String, Object?>{
    'state': 'idle',
  });
  return root;
}

List<Json> _chapters(Directory root) {
  final Json book =
      jsonDecode(File('${root.path}/book.json').readAsStringSync()) as Json;
  return (book['chapters']! as List<Object?>).cast<Json>();
}

Json _label(String label, [double confidence = 0.94]) => <String, Object?>{
  'choice': label,
  'probabilities': <String, Object?>{label: confidence},
};

void main() {
  late Directory temp;
  late Map<String, String> previousEnvironment;
  late Future<Json> Function(Object?, Json) previousJudge;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('thusfar-title-spoiler-');
    previousEnvironment = Map<String, String>.of(environ);
    previousJudge = judge.judgeCall;
    environ.addAll(<String, String>{'JUDGE_TITLES': '1', 'JUDGE_LOG': '0'});
  });

  tearDown(() {
    judge.judgeCall = previousJudge;
    environ
      ..clear()
      ..addAll(previousEnvironment);
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test(
    'single-label safe and spoils answers classify their chosen labels',
    () async {
      judge.judgeCall =
          (Object? state, Json questions) async => <String, Object?>{
            't0': _label('safe'),
            't1': _label('spoils'),
          };
      expect(await judge.titleSpoilers(<String>['林间', '谁获胜']), <bool>[
        false,
        true,
      ]);
    },
  );

  test(
    'a failed later batch does not return verified default-true flags',
    () async {
      int calls = 0;
      judge.judgeCall = (Object? state, Json questions) async {
        calls++;
        if (calls == 2) throw StateError('classifier unavailable');
        return <String, Object?>{
          for (final String key in questions.keys) key: _label('safe'),
        };
      };
      await expectLater(
        judge.titleSpoilers(List<String>.filled(judge.batch + 1, '林间')),
        throwsA(isA<StateError>()),
      );
      expect(calls, 2);
    },
  );

  test('missing or uncertain answers remain unverified', () async {
    judge.judgeCall =
        (Object? state, Json questions) async => <String, Object?>{};
    await expectLater(
      judge.titleSpoilers(<String>['林间']),
      throwsA(isA<ValueError>()),
    );
    judge.judgeCall =
        (Object? state, Json questions) async => <String, Object?>{
          't0': _label('safe', 0.4),
        };
    await expectLater(
      judge.titleSpoilers(<String>['林间']),
      throwsA(isA<llm.LLMError>()),
    );
    judge.judgeCall =
        (Object? state, Json questions) async => <String, Object?>{
          't0': <String, Object?>{
            'choice': 'safe',
            'probabilities': <String, Object?>{'safe': 0.6, 'spoils': 0.7},
          },
        };
    await expectLater(
      judge.titleSpoilers(<String>['林间']),
      throwsA(isA<llm.LLMError>()),
    );
  });

  test('verified results persist and clear title quality pending', () async {
    final Directory root = _book(temp, 'verified');
    judge.judgeCall =
        (Object? state, Json questions) async => <String, Object?>{
          't0': _label('safe'),
          't1': _label('spoils'),
        };
    final Runner runner = await Runner.create(root, activity: false);
    try {
      runner.qualityPending.add('chapter-titles');
      await runner.markTitles();
      expect(_chapters(root).map((Json c) => c['spoil']), <Object?>[
        false,
        true,
      ]);
      expect(runner.qualityPending, isNot(contains('chapter-titles')));
    } finally {
      await runner.close();
    }
  });

  test(
    'network failure keeps local spoiler fallback and automatic retry',
    () async {
      final Directory root = _book(temp, 'network-retry');
      judge.judgeCall = (Object? state, Json questions) async {
        throw const llm.LLMError(
          '免费裁判暂不可用，未调用付费接口：LLMError: classifier.dev 调用失败：SocketException: Network is unreachable',
        );
      };

      await expectLater(runBook(root, limit: 1), throwsA(isA<llm.LLMError>()));
      final Json status =
          jsonDecode(File('${root.path}/status.json').readAsStringSync())
              as Json;
      expect(status['state'], 'error');
      expect(status['retryable'], isTrue);
      expect(
        (status['quality']! as Json)['pending'],
        contains('chapter-titles'),
      );
      expect(_chapters(root).map((Json c) => c['spoil']), <Object?>[
        false,
        null,
      ]);
      expect(File('${root.path}/work/segs/0000.json').existsSync(), isFalse);

      judge.judgeCall =
          (Object? state, Json questions) async => <String, Object?>{
            't0': _label('safe'),
            't1': _label('spoils'),
          };
      final Runner resumed = await Runner.create(root, activity: false);
      try {
        await resumed.markTitles();
        expect(_chapters(root).map((Json c) => c['spoil']), <Object?>[
          false,
          true,
        ]);
        expect(resumed.qualityPending, isNot(contains('chapter-titles')));
      } finally {
        await resumed.close();
      }
    },
  );

  test(
    'uncertain check leaves unknown verdict and keeps retry pending',
    () async {
      final Directory root = _book(temp, 'retry');
      final RunCancellation cancellation = RunCancellation();
      judge.judgeCall = (Object? state, Json questions) async {
        cancellation.cancel();
        throw const llm.LLMError('章节标题核对结果不确定：正文提到 TimeoutError');
      };
      final Runner runner = await Runner.create(
        root,
        cancellation: cancellation,
        activity: true,
      );
      try {
        await expectLater(runner.run2(limit: 1), throwsA(isA<Cancelled>()));
        expect(runner.qualityPending, contains('chapter-titles'));
        expect(_chapters(root).map((Json c) => c['spoil']), <Object?>[
          false,
          null,
        ]);
        final List<Object?> activity =
            jsonDecode(
                  File('${root.path}/work/activity.json').readAsStringSync(),
                )
                as List<Object?>;
        expect(
          activity.map((Object? row) => (row! as Json)['phase']),
          contains('check_titles_pending'),
        );
      } finally {
        await runner.close(cancelled: true);
      }
    },
  );

  test(
    'cancelled title check keeps its pending marker across reopening',
    () async {
      final Directory root = _book(temp, 'cancelled-reopen');
      final RunCancellation cancellation = RunCancellation();
      judge.judgeCall = (Object? state, Json questions) async {
        cancellation.cancel();
        throw const llm.LLMError('章节标题核对结果不确定');
      };

      await expectLater(
        runBook(root, limit: 1, cancellation: cancellation),
        throwsA(isA<Cancelled>()),
      );
      final Json status =
          jsonDecode(File('${root.path}/status.json').readAsStringSync())
              as Json;
      expect(status['state'], 'paused');
      expect(status['retryable'], isNot(true));
      expect(
        (status['quality']! as Json)['pending'],
        contains('chapter-titles'),
      );
      expect(_chapters(root).map((Json c) => c['spoil']), <Object?>[
        false,
        null,
      ]);

      int rechecks = 0;
      judge.judgeCall = (Object? state, Json questions) async {
        rechecks++;
        return <String, Object?>{'t0': _label('safe'), 't1': _label('spoils')};
      };
      final Runner reopened = await Runner.create(root, activity: false);
      try {
        expect(reopened.qualityPending, contains('chapter-titles'));
        await reopened.markTitles();
        expect(rechecks, 1);
        expect(reopened.qualityPending, isNot(contains('chapter-titles')));
      } finally {
        await reopened.close();
      }
    },
  );
}
