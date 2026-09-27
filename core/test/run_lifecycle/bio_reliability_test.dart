import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/jobs.dart' as jobs;
import 'package:thusfar_core/run.dart';
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/pipeline/judge.dart' as judge;
import 'package:thusfar_core/src/pipeline/llm.dart' as llm;

typedef Json = Map<String, Object?>;

class ScriptedGeneration extends RunBackend {
  ScriptedGeneration(this.answers);

  final List<Object?> answers;
  int calls = 0;

  @override
  Future<(Object?, Json)> generate(
    String model,
    List<Map<String, String>> messages, {
    bool jsonOutput = false,
    int maxTokens = 8000,
    double temperature = 0.2,
  }) async => (
    answers[calls++],
    <String, Object?>{'prompt_tokens': 10, 'completion_tokens': 5},
  );
}

Json _read(Directory root, String path) =>
    jsonDecode(File('${root.path}/$path').readAsStringSync()) as Json;

void _save(Directory root, String path, Object? value) =>
    writeJson(File('${root.path}/$path'), value);

Directory _book(Directory books, String name, {int chapters = 1}) {
  final Directory root = Directory('${books.path}/$name')..createSync();
  final String passage = List<String>.filled(2500, '甲').join();
  final List<Json> blocks = <Json>[];
  final List<Json> chapterRows = <Json>[];
  for (int i = 0; i < chapters; i++) {
    final int offset = i * passage.length;
    blocks.add(<String, Object?>{'k': 'p', 't': passage, 'o': offset});
    chapterRows.add(<String, Object?>{
      'title': '第 ${i + 1} 章',
      'b0': i,
      'b1': i + 1,
      'o0': offset,
      'o1': offset + passage.length,
      'kind': 'body',
      'spoil': false,
    });
  }
  _save(root, 'book.json', <String, Object?>{
    'title': '离线人物小传测试',
    'author': '',
    'lang': 'zh',
    'genre': 'novel',
    'classified': true,
    'len': chapters * passage.length,
    'blocks': blocks,
    'chapters': chapterRows,
    'notes': <String, Object?>{},
  });
  _save(root, 'meta.json', <String, Object?>{'auto': false});
  _save(root, 'status.json', <String, Object?>{'state': 'idle'});
  return root;
}

void _person(Runner runner, String id, {int eventPosition = 10}) {
  runner.kg.people[id] = <String, Object?>{
    'id': id,
    'name': id,
    'aliases': <String>{},
    'first': 0,
    'imp': 3,
    'mentions': 2,
  };
  runner.kg.log.add(<String, Object?>{
    't': 'event',
    'p': eventPosition,
    'who': <String>[id],
    'text': '$id 出场',
    'imp': 3,
  });
}

Json _bio(String text) => <String, Object?>{'tagline': '已出场的人物', 'bio': text};

Json _guard(bool supported) => <String, Object?>{
  'g1': <String, Object?>{
    'choice': supported ? 'supported' : 'beyond_text',
    'probabilities': <String, Object?>{
      'supported': supported ? 0.95 : 0.05,
      'beyond_text': supported ? 0.05 : 0.95,
      'contradicted': 0.0,
    },
  },
};

void main() {
  late Directory books;
  late Map<String, String> oldEnvironment;
  late Future<Json> Function(Object?, Json) oldJudge;

  setUp(() {
    books = Directory.systemTemp.createTempSync('thusfar-bio-reliability-');
    oldEnvironment = Map<String, String>.of(environ);
    oldJudge = judge.judgeCall;
    environ.addAll(<String, String>{
      'JUDGE_TITLES': '0',
      'JUDGE_IMPORTANCE': '0',
    });
  });

  tearDown(() {
    judge.judgeCall = oldJudge;
    environ
      ..clear()
      ..addAll(oldEnvironment);
    if (books.existsSync()) books.deleteSync(recursive: true);
  });

  test(
    'legacy empty cache is retried only when there are candidates',
    () async {
      final Directory root = _book(books, 'legacy-empty');
      final Runner runner = await Runner.create(root, activity: false);
      try {
        runner.replaying = true;
        _save(root, 'work/bios/0000.json', <String, Object?>{
          'chapter': 0,
          'bios': <String, Object?>{},
        });
        _person(runner, 'P1');
        runner.consolidate(0, 2500, 0);
        expect(runner.deferred, hasLength(1));
        expect(_read(root, 'work/jobs/bio-0.json')['state'], 'pending');
        expect(_read(root, 'work/bios/0000.json')['bios'], isEmpty);
      } finally {
        await runner.close();
      }

      final Directory emptyRoot = _book(books, 'no-candidates');
      final Runner empty = await Runner.create(emptyRoot, activity: false);
      try {
        empty.replaying = true;
        empty.consolidate(0, 2500, 0);
        expect(empty.deferred, isEmpty);
        expect(
          _read(emptyRoot, 'work/bios/0000.json')['reason'],
          'skipped_no_candidates',
        );
      } finally {
        await empty.close();
      }
    },
  );

  test(
    'legacy verified cache replays even if candidates are now empty',
    () async {
      final Directory root = _book(books, 'legacy-approved');
      final Runner runner = await Runner.create(root, activity: false);
      try {
        runner.replaying = true;
        runner.kg.people['P1'] = <String, Object?>{
          'id': 'P1',
          'name': '小林',
          'first': 0,
        };
        _save(root, 'work/bios/0000.json', <String, Object?>{
          'chapter': 0,
          'bios': <String, Object?>{
            'P1': <String, Object?>{
              ..._bio('旧版通过核对的小传。'),
              'chk': <String, Object?>{'verdict': 'ok'},
            },
          },
        });
        runner.consolidate(0, 2500, 0);
        expect(runner.kg.people['P1']!['bio'], '旧版通过核对的小传。');
        expect(runner.deferred, isEmpty);
        expect(_read(root, 'work/bios/0000.json')['reason'], isNull);
      } finally {
        await runner.close();
      }
    },
  );

  test(
    'zero output fails visibly, then explicit retry uses a new draft',
    () async {
      final Directory root = _book(books, 'empty-then-good');
      final ScriptedGeneration backend = ScriptedGeneration(<Object?>[
        <String, Object?>{},
        <String, Object?>{'P1': _bio('小林已在本章出场。')},
      ]);
      final Runner runner = await Runner.create(root, backend: backend);
      final File job = File('${root.path}/work/jobs/bio-0.json');
      _person(runner, 'P1');
      _save(root, 'work/jobs/bio-0.json', <String, Object?>{
        'kind': 'bio',
        'key': 0,
        'args': <Object?>[
          0,
          2500,
          '【P1｜小林】小林已出场',
          <String>['P1'],
        ],
        'state': 'pending',
      });
      judge.judgeCall = (Object? state, Json questions) async => _guard(true);
      try {
        await expectLater(
          runner.executeFinal(job),
          throwsA(isA<llm.LLMError>()),
        );
        expect(_read(root, 'work/jobs/bio-0.json')['state'], 'failed');
        expect(_read(root, 'work/jobs/bio-0.json')['generation_attempt'], 1);
        expect(
          _read(root, 'work/jobs/bio-0.json')['bio_review'],
          <String, Object?>{
            'candidates': 1,
            'passed': 0,
            'blocked': 0,
            'missing': 1,
          },
        );
        expect(File('${root.path}/work/bios/0000.json').existsSync(), isFalse);
        expect(Directory('${root.path}/work/drafts').listSync(), hasLength(1));

        await runner.executeFinal(job);
        expect(backend.calls, 2);
        expect(Directory('${root.path}/work/drafts').listSync(), hasLength(2));
        expect(_read(root, 'work/jobs/bio-0.json')['state'], 'complete');
        expect(_read(root, 'work/jobs/bio-0.json')['failure_kind'], isNull);
        expect(
          (_read(root, 'work/bios/0000.json')['bios'] as Json).keys,
          contains('P1'),
        );
        expect(runner.kg.people['P1']!['bio'], '小林已在本章出场。');
      } finally {
        await runner.close();
      }
    },
  );

  test(
    'guard blocked all bios fails, but a verified partial bio is published',
    () async {
      final Directory blockedRoot = _book(books, 'all-blocked');
      final ScriptedGeneration blockedBackend = ScriptedGeneration(<Object?>[
        <String, Object?>{'P1': _bio('缺少证据的说法。')},
      ]);
      final Runner blocked = await Runner.create(
        blockedRoot,
        backend: blockedBackend,
      );
      final File blockedJob = File('${blockedRoot.path}/work/jobs/bio-0.json');
      _save(blockedRoot, 'work/jobs/bio-0.json', <String, Object?>{
        'kind': 'bio',
        'key': 0,
        'args': <Object?>[
          0,
          2500,
          '【P1｜小林】',
          <String>['P1'],
        ],
        'state': 'pending',
      });
      judge.judgeCall = (Object? state, Json questions) async => _guard(false);
      try {
        await expectLater(
          blocked.executeFinal(blockedJob),
          throwsA(isA<llm.LLMError>()),
        );
        expect(
          _read(blockedRoot, 'work/jobs/bio-0.json')['bio_review'],
          <String, Object?>{
            'candidates': 1,
            'passed': 0,
            'blocked': 1,
            'missing': 0,
          },
        );
        expect(
          File('${blockedRoot.path}/work/bios/0000.json').existsSync(),
          isFalse,
        );
      } finally {
        await blocked.close();
      }

      final Directory partialRoot = _book(books, 'partial');
      final ScriptedGeneration partialBackend = ScriptedGeneration(<Object?>[
        <String, Object?>{'P1': _bio('小林已出场。')},
      ]);
      final Runner partial = await Runner.create(
        partialRoot,
        backend: partialBackend,
      );
      _person(partial, 'P1');
      _person(partial, 'P2');
      final File partialJob = File('${partialRoot.path}/work/jobs/bio-0.json');
      _save(partialRoot, 'work/jobs/bio-0.json', <String, Object?>{
        'kind': 'bio',
        'key': 0,
        'args': <Object?>[
          0,
          2500,
          '【P1｜小林】【P2｜阿明】',
          <String>['P1', 'P2'],
        ],
        'state': 'pending',
      });
      judge.judgeCall = (Object? state, Json questions) async => _guard(true);
      try {
        await partial.executeFinal(partialJob);
        final Json out = _read(partialRoot, 'work/bios/0000.json');
        expect((out['bios'] as Json).keys, <String>['P1']);
        expect(out['review'], <String, Object?>{
          'candidates': 2,
          'passed': 1,
          'blocked': 0,
          'missing': 1,
        });
        expect(_read(partialRoot, 'work/jobs/bio-0.json')['state'], 'complete');
        expect(partial.kg.people['P1']!['bio'], '小林已出场。');
      } finally {
        await partial.close();
      }
    },
  );

  test(
    'first-chapter preview does not move a legacy 12k bio milestone',
    () async {
      final Directory root = _book(books, 'legacy-milestone', chapters: 6);
      final Runner runner = await Runner.create(root, activity: false);
      try {
        expect(runner.segs, hasLength(6));
        runner.twoPhase = true;
        runner.replaying = true;
        _person(runner, 'P1', eventPosition: 8000);
        _save(root, 'work/bios/0005.json', <String, Object?>{
          'chapter': 5,
          'bios': <String, Object?>{
            'P1': <String, Object?>{
              ..._bio('旧版第六章已核对的小传。'),
              'chk': <String, Object?>{'verdict': 'ok', 'jev': 0.97},
            },
          },
        });
        await runner.maybeRecap(0);
        expect(runner.lastBio, 0);
        expect(
          _read(root, 'work/bios/0000.json')['reason'],
          'skipped_no_candidates',
        );
        await runner.maybeRecap(5);
        expect(runner.lastBio, 15000);
        expect(runner.kg.people['P1']!['bio'], '旧版第六章已核对的小传。');
        expect(
          runner.deferred.where(
            (entry) => entry.$1.path.endsWith('bio-5.json'),
          ),
          isEmpty,
        );
      } finally {
        await runner.close();
      }
    },
  );

  test('first-chapter preview leaves classic processing unchanged', () async {
    final Directory root = _book(books, 'classic-first-chapter', chapters: 2);
    final Runner runner = await Runner.create(root, activity: false);
    try {
      runner.replaying = true;
      _person(runner, 'P1');
      await runner.maybeRecap(0);
      expect(File('${root.path}/work/bios/0000.json').existsSync(), isFalse);
      expect(runner.lastBio, 0);
      expect(
        runner.deferred.where((entry) => entry.$1.path.endsWith('bio-0.json')),
        isEmpty,
      );
    } finally {
      await runner.close();
    }
  });

  test(
    'worker resumes a failed bio job in place and stops automatic retries',
    () async {
      final Directory root = _book(books, 'worker-retry');
      _save(root, 'status.json', <String, Object?>{
        'state': 'error',
        'quality': <String, Object?>{
          'state': 'pending',
          'pending': <String>['bio-0'],
        },
      });
      _save(root, 'work/jobs/bio-0.json', <String, Object?>{
        'kind': 'bio',
        'key': 0,
        'state': 'failed',
        'failure_kind': 'bio_content',
        'generation_attempt': 1,
      });
      final List<bool> retryQualityCalls = <bool>[];
      final jobs.Worker worker = jobs.Worker(
        books,
        probe: (Directory _) async => false,
        settings:
            () => const jobs.WorkerSettings(
              model: 'offline',
              localModel: 'offline',
            ),
        run: (
          Directory root, {
          required jobs.RunCancellation cancellation,
          required bool retryQuality,
          required String model,
          required String localModel,
          required int concurrency,
        }) async {
          retryQualityCalls.add(retryQuality);
          _save(root, 'status.json', <String, Object?>{
            'state': 'error',
            'error': '第 1 章人物小传通过 0/1 位',
            'quality': <String, Object?>{
              'state': 'pending',
              'pending': <String>['bio-0'],
            },
          });
          throw const llm.LLMError('第 1 章人物小传通过 0/1 位');
        },
      );
      try {
        await worker.startBook(root);
        await worker.waitIdle();
        expect(retryQualityCalls, <bool>[false]);
        expect(_read(root, 'meta.json')['retry_quality'], isNull);
        expect(_read(root, 'meta.json')['auto'], isFalse);
        expect(_read(root, 'status.json')['state'], 'error');
        expect(_read(root, 'status.json')['error'], contains('人物小传'));
      } finally {
        await worker.close();
      }
    },
  );

  test(
    'bio API failure resumes in place without replacing its draft',
    () async {
      final Directory root = _book(books, 'worker-api-retry');
      _save(root, 'status.json', <String, Object?>{
        'state': 'error',
        'quality': <String, Object?>{
          'state': 'pending',
          'pending': <String>['bio-0'],
        },
      });
      _save(root, 'work/jobs/bio-0.json', <String, Object?>{
        'kind': 'bio',
        'key': 0,
        'state': 'failed',
        'generation_attempt': 0,
      });
      final List<bool> calls = <bool>[];
      final jobs.Worker worker = jobs.Worker(
        books,
        probe: (Directory _) async => false,
        settings: () => const jobs.WorkerSettings(),
        run: (
          Directory root, {
          required jobs.RunCancellation cancellation,
          required bool retryQuality,
          required String model,
          required String localModel,
          required int concurrency,
        }) async {
          calls.add(retryQuality);
          _save(root, 'status.json', <String, Object?>{'state': 'done'});
        },
      );
      try {
        await worker.startBook(root);
        await worker.waitIdle();
        expect(calls, <bool>[false]);
        expect(_read(root, 'meta.json')['retry_quality'], isNull);
      } finally {
        await worker.close();
      }
    },
  );

  test('unrelated quality is not hidden by an old failed bio job', () async {
    final Directory root = _book(books, 'unrelated-quality');
    _save(root, 'status.json', <String, Object?>{
      'state': 'error',
      'quality': <String, Object?>{
        'state': 'pending',
        'pending': <String>['chapter-titles'],
      },
    });
    _save(root, 'work/jobs/bio-0.json', <String, Object?>{
      'kind': 'bio',
      'key': 0,
      'state': 'failed',
      'failure_kind': 'bio_content',
    });
    final List<bool> calls = <bool>[];
    final jobs.Worker worker = jobs.Worker(
      books,
      probe: (Directory _) async => false,
      settings: () => const jobs.WorkerSettings(),
      run: (
        Directory root, {
        required jobs.RunCancellation cancellation,
        required bool retryQuality,
        required String model,
        required String localModel,
        required int concurrency,
      }) async {
        calls.add(retryQuality);
        _save(root, 'status.json', <String, Object?>{'state': 'done'});
      },
    );
    try {
      await worker.startBook(root);
      await worker.waitIdle();
      expect(calls, <bool>[true]);
    } finally {
      await worker.close();
    }
  });
}
