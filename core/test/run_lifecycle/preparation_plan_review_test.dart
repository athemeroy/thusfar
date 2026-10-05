import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/run.dart';
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/pipeline/judge.dart' as judge;
import 'package:thusfar_core/src/pipeline/llm.dart' as llm;

import 'preparation_plan_test.dart' as fixtures;

typedef Json = Map<String, Object?>;

class RecordingFinalization extends RunBackend {
  final List<String> requests = <String>[];
  @override
  Future<(Object?, Json)> generate(
    String model,
    List<Map<String, String>> messages, {
    bool jsonOutput = false,
    int maxTokens = 8000,
    double temperature = .2,
  }) async {
    requests.add(jsonEncode(messages));
    return (
      jsonOutput
          ? <String, Object?>{
            'P1': <String, Object?>{'tagline': '已读人物', 'bio': '已读甲在场。'},
          }
          : '已读甲在场。',
      <String, Object?>{'prompt_tokens': 10, 'completion_tokens': 2},
    );
  }
}

void person(Runner runner, {int at = 10, String text = '已读甲在场。'}) {
  runner.kg.people['P1'] = <String, Object?>{
    'id': 'P1',
    'name': '已读甲',
    'aliases': <String>{},
    'first': 0,
    'imp': 3,
    'mentions': 2,
  };
  runner.kg.log.add(<String, Object?>{
    't': 'event',
    'p': at,
    'who': <String>['P1'],
    'text': text,
    'imp': 3,
  });
}

void main() {
  late Directory books;
  late Map<String, String> oldEnvironment;
  late llm.ChatTransport oldTransport;
  late fixtures.OfflineTransport transport;
  late Future<Json> Function(Object?, Json) oldJudge;
  final List<String> judgments = <String>[];
  setUp(() {
    books = Directory.systemTemp.createTempSync('thusfar-plan-review-');
    oldEnvironment = Map<String, String>.of(environ);
    environ.addAll(<String, String>{
      'JUDGE_TITLES': '0',
      'JUDGE_IMPORTANCE': '0',
      'JUDGE_RELATIONS': '0',
      'JUDGE_ATTRS': '0',
      'VERIFY_RECORDS': '0',
      'JUDGE_LOG': '0',
    });
    oldTransport = llm.transport;
    llm.transport = transport = fixtures.OfflineTransport();
    oldJudge = judge.judgeCall;
    judgments.clear();
    judge.judgeCall = (Object? state, Json questions) async {
      judgments.add(jsonEncode(<Object?>[state, questions]));
      return <String, Object?>{
        for (final String key in questions.keys)
          key: <String, Object?>{
            'choice': 'supported',
            'probabilities': <String, Object?>{
              'supported': .99,
              'beyond_text': .005,
              'contradicted': .005,
            },
          },
      };
    };
  });
  tearDown(() {
    llm.transport = oldTransport;
    judge.judgeCall = oldJudge;
    environ
      ..clear()
      ..addAll(oldEnvironment);
    expect(transport.calls, 0);
    books.deleteSync(recursive: true);
  });

  for (final bool twoPhase in <bool>[false, true]) {
    test(
      'shrunk plan skips existing future final jobs, twoPhase=$twoPhase',
      () async {
        final Directory root = fixtures.fixture(books);
        fixtures.save(root, 'meta.json', <String, Object?>{
          'preparation_plan': fixtures.plan(480),
        });
        final RecordingFinalization backend = RecordingFinalization();
        final Runner runner = await Runner.create(
          root,
          backend: backend,
          activity: false,
        );
        final String recapKind = twoPhase ? 'recap' : 'classic-recap';
        final List<String> paths = <String>[
          'work/jobs/bio-1.json',
          'work/jobs/$recapKind-1.json',
          'work/jobs/saga-960.json',
        ];
        for (final String path in paths) {
          fixtures.save(root, path, <String, Object?>{
            'state': 'failed',
            'error': 'previous interrupted request',
            'future': '秘密丙',
          });
        }
        final List<String> before = <String>[
          for (final String path in paths)
            File('${root.path}/$path').readAsStringSync(),
        ];
        try {
          runner.twoPhase = twoPhase;
          runner.replaying = true;
          person(runner, at: 600, text: '以后乙与秘密丙在场。');
          runner.consolidate(1, 960, 480);
          runner.recap(1, 960, 480);
          runner.saga(960, <int>[0, 1]);
          runner.replaying = false;
          runner.resumeFinalJobs();
          await runner.close();
          expect(runner.pending, isEmpty);
          expect(backend.requests, isEmpty);
          expect(judgments, isEmpty);
          expect(<String>[
            for (final String path in paths)
              File('${root.path}/$path').readAsStringSync(),
          ], before);
        } finally {
          await runner.close();
        }
      },
    );
  }

  for (final bool twoPhase in <bool>[false, true]) {
    test(
      'early queued recap captures only prefix before future KG replay, twoPhase=$twoPhase',
      () async {
        final Directory root = fixtures.fixture(books);
        fixtures.save(root, 'meta.json', <String, Object?>{
          'preparation_plan': fixtures.plan(480),
        });
        final RecordingFinalization backend = RecordingFinalization();
        final Runner runner = await Runner.create(
          root,
          backend: backend,
          activity: false,
        );
        try {
          runner.twoPhase = twoPhase;
          runner.replaying = true;
          person(runner);
          runner.recap(0, 480, 0);
          expect(runner.deferred, hasLength(1));
          runner.kg.people['P1']!['name'] = '秘密丙';
          runner.kg.saga = '未来秘密与结局';
          runner.kg.log.add(<String, Object?>{
            't': 'event',
            'p': 800,
            'who': <String>['P1'],
            'text': '未来秘密与结局',
          });
          runner.replaying = false;
          runner.resumeFinalJobs();
          await runner.close();
          expect(backend.requests, hasLength(1));
          final String requests = <String>[
            ...backend.requests,
            ...judgments,
          ].join('\n');
          expect(requests, contains('已读甲'));
          expect(requests, isNot(contains('秘密丙')));
          expect(requests, isNot(contains('未来秘密与结局')));
        } finally {
          await runner.close();
        }
      },
    );
  }

  test(
    'early queued biography captures only prefix before future KG replay',
    () async {
      final Directory root = fixtures.fixture(books);
      fixtures.save(root, 'meta.json', <String, Object?>{
        'preparation_plan': fixtures.plan(480),
      });
      final RecordingFinalization backend = RecordingFinalization();
      final Runner runner = await Runner.create(
        root,
        backend: backend,
        activity: false,
      );
      try {
        runner.twoPhase = true;
        runner.replaying = true;
        person(runner);
        runner.consolidate(0, 480, 0);
        expect(runner.deferred, hasLength(1));
        runner.kg.people['P1']!['name'] = '秘密丙';
        runner.kg.people['P1']!['bio'] = '未来秘密与结局';
        runner.kg.saga = '未来秘密与结局';
        runner.replaying = false;
        runner.resumeFinalJobs();
        await runner.close();
        expect(backend.requests, hasLength(1));
        final String requests = <String>[
          ...backend.requests,
          ...judgments,
        ].join('\n');
        expect(requests, contains('已读甲'));
        expect(requests, isNot(contains('秘密丙')));
        expect(requests, isNot(contains('未来秘密与结局')));
      } finally {
        await runner.close();
      }
    },
  );
}
