import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/jobs.dart' as jobs;
import 'package:thusfar_core/run.dart';
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/pipeline/jev.dart' as jev;
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

  test('zero output gets one bounded automatic repair draft', () async {
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
      await runner.executeFinal(job);
      expect(_read(root, 'work/jobs/bio-0.json')['state'], 'complete');
      expect(_read(root, 'work/jobs/bio-0.json')['generation_attempt'], 1);
      expect(
        _read(root, 'work/jobs/bio-0.json')['bio_review'],
        <String, Object?>{
          'candidates': 1,
          'passed': 1,
          'blocked': 0,
          'missing': 0,
          'rejection_reasons': <String, int>{},
        },
      );
      expect(backend.calls, 2);
      expect(Directory('${root.path}/work/drafts').listSync(), hasLength(2));
      expect(_read(root, 'work/jobs/bio-0.json')['failure_kind'], isNull);
      expect(
        (_read(root, 'work/bios/0000.json')['bios'] as Json).keys,
        contains('P1'),
      );
      expect(runner.kg.people['P1']!['bio'], '小林已在本章出场。');
    } finally {
      await runner.close();
    }
  });

  test(
    'invalid model judge defers the draft and rechecks it on request',
    () async {
      final Directory root = _book(books, 'judge-format-deferred');
      final ScriptedGeneration backend = ScriptedGeneration(<Object?>[
        <String, Object?>{'P1': _bio('小林已在本章出场。')},
      ]);
      final Runner runner = await Runner.create(
        root,
        backend: backend,
        activity: false,
      );
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
        'generation_attempt': 0,
        'content_failures': 0,
      });
      judge.judgeCall =
          (Object? state, Json questions) async =>
              throw const jev.ModelJudgeInvalidAnswer('模型判断回答格式无效');
      try {
        await runner.executeFinal(job);
        final Json deferred = _read(root, 'work/jobs/bio-0.json');
        expect(deferred['state'], 'deferred');
        expect(deferred['failure_kind'], 'bio_judge_format');
        expect(deferred['generation_attempt'], 0);
        expect(deferred['content_failures'], 0);
        expect(runner.qualityPending, contains('bio-0'));
        expect(File('${root.path}/work/bios/0000.json').existsSync(), isFalse);
        expect(runner.kg.people['P1']!['bio'], isNull);
        expect(runner.kg.log.where((r) => r['t'] == 'profile'), isEmpty);
        expect(backend.calls, 1);
        final Directory drafts = Directory('${root.path}/work/drafts');
        final List<File> savedDrafts =
            drafts.listSync().whereType<File>().toList();
        expect(savedDrafts, hasLength(1));
        final String originalDraft = savedDrafts.single.readAsStringSync();

        deferred['retry_requested'] = true;
        _save(root, 'work/jobs/bio-0.json', deferred);
        judge.judgeCall = (Object? state, Json questions) async => _guard(true);
        runner.replaying = true;
        runner.consolidate(0, 2500, 0);
        expect(_read(root, 'work/jobs/bio-0.json')['state'], 'pending');
        runner.replaying = false;
        runner.resumeFinalJobs();
        await Future.wait(runner.pending);
        expect(backend.calls, 1, reason: 'the same generated draft is reused');
        expect(savedDrafts.single.readAsStringSync(), originalDraft);
        expect(_read(root, 'work/jobs/bio-0.json')['state'], 'complete');
        expect(runner.qualityPending, isNot(contains('bio-0')));
        expect(runner.kg.people['P1']!['bio'], '小林已在本章出场。');
      } finally {
        await runner.close();
      }
    },
  );

  test('interruption keeps the remaining biography repair budget', () async {
    final Directory root = _book(books, 'interrupted-repair');
    final ScriptedGeneration backend = ScriptedGeneration(<Object?>[
      <String, Object?>{'P1': _bio('第一次缺少证据。')},
      <String, Object?>{'P1': _bio('第二次仍缺少证据。')},
    ]);
    final jobs.RunCancellation cancellation = jobs.RunCancellation();
    final File job = File('${root.path}/work/jobs/bio-0.json');
    _save(root, 'work/jobs/bio-0.json', <String, Object?>{
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
    final Runner first = await Runner.create(
      root,
      backend: backend,
      cancellation: cancellation,
    );
    judge.judgeCall = (Object? state, Json questions) async {
      cancellation.cancel();
      return _guard(false);
    };
    try {
      await expectLater(
        first.executeFinal(job),
        throwsA(isA<jobs.Cancelled>()),
      );
      expect(_read(root, 'work/jobs/bio-0.json')['state'], 'pending');
      expect(_read(root, 'work/jobs/bio-0.json')['content_failures'], 1);
      expect(_read(root, 'work/jobs/bio-0.json')['generation_attempt'], 1);
      expect(backend.calls, 1);
    } finally {
      await first.close(cancelled: true);
    }

    judge.judgeCall = (Object? state, Json questions) async => _guard(false);
    final Runner resumed = await Runner.create(root, backend: backend);
    try {
      await resumed.executeFinal(job);
      expect(_read(root, 'work/jobs/bio-0.json')['state'], 'deferred');
      expect(_read(root, 'work/jobs/bio-0.json')['content_failures'], 2);
      expect(_read(root, 'work/jobs/bio-0.json')['generation_attempt'], 2);
      expect(backend.calls, 2);
      expect(Directory('${root.path}/work/drafts').listSync(), hasLength(2));
    } finally {
      await resumed.close();
    }
  });

  test(
    'guard blocked all bios defers without publishing; partial bio is published',
    () async {
      final Directory blockedRoot = _book(books, 'all-blocked');
      final ScriptedGeneration blockedBackend = ScriptedGeneration(<Object?>[
        <String, Object?>{'P1': _bio('缺少证据的说法。')},
        <String, Object?>{'P1': _bio('仍然缺少证据。')},
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
        await blocked.executeFinal(blockedJob);
        expect(_read(blockedRoot, 'work/jobs/bio-0.json')['state'], 'deferred');
        expect(
          _read(blockedRoot, 'work/jobs/bio-0.json')['generation_attempt'],
          2,
        );
        expect(blockedBackend.calls, 2);
        expect(blocked.qualityPending, contains('bio-0'));
        expect(
          _read(blockedRoot, 'work/jobs/bio-0.json')['bio_review'],
          <String, Object?>{
            'candidates': 1,
            'passed': 0,
            'blocked': 1,
            'missing': 0,
            'rejection_reasons': <String, int>{'beyond_text': 1},
          },
        );
        expect(
          File('${blockedRoot.path}/work/bios/0000.json').existsSync(),
          isFalse,
        );
        blocked.replaying = true;
        _person(blocked, 'P1');
        blocked.consolidate(0, 2500, 0);
        expect(blocked.deferred, isEmpty);
        expect(_read(blockedRoot, 'work/jobs/bio-0.json')['state'], 'deferred');
        expect(blockedBackend.calls, 2);
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
          'rejection_reasons': <String, int>{},
        });
        expect(_read(partialRoot, 'work/jobs/bio-0.json')['state'], 'complete');
        expect(partial.kg.people['P1']!['bio'], '小林已出场。');
      } finally {
        await partial.close();
      }
    },
  );

  test('explicit quality retry reopens only the deferred biography', () async {
    final Directory root = _book(books, 'explicit-deferred');
    _save(root, 'status.json', <String, Object?>{
      'state': 'done',
      'quality': <String, Object?>{
        'state': 'pending',
        'pending': <String>['bio-0'],
      },
    });
    _save(root, 'work/jobs/bio-0.json', <String, Object?>{
      'kind': 'bio',
      'key': 0,
      'args': <Object?>[
        0,
        2500,
        '【P1｜小林】小林已出场',
        <String>['P1'],
      ],
      'state': 'deferred',
      'generation_attempt': 2,
      'content_failures': 2,
      'failure_kind': 'bio_content',
      'retry_requested': true,
    });
    final ScriptedGeneration backend = ScriptedGeneration(<Object?>[
      <String, Object?>{'P1': _bio('小林已在本章出场。')},
    ]);
    judge.judgeCall = (Object? state, Json questions) async => _guard(true);
    final Runner runner = await Runner.create(root, backend: backend);
    try {
      runner.replaying = true;
      _person(runner, 'P1');
      runner.consolidate(0, 2500, 0);
      expect(runner.deferred, hasLength(1));
      expect(_read(root, 'work/jobs/bio-0.json')['state'], 'pending');
      expect(_read(root, 'work/jobs/bio-0.json')['content_failures'], 0);
      expect(_read(root, 'work/jobs/bio-0.json')['generation_attempt'], 2);
      expect(_read(root, 'work/jobs/bio-0.json')['retry_requested'], isNull);
      runner.replaying = false;
      runner.resumeFinalJobs();
      await Future.wait(runner.pending);
      expect(backend.calls, 1);
      expect(_read(root, 'work/jobs/bio-0.json')['state'], 'complete');
      expect(runner.qualityPending, isNot(contains('bio-0')));
    } finally {
      await runner.close();
    }
  });

  test(
    'preflight failure keeps explicit deferred retry until the job reopens',
    () async {
      final Directory root = _book(books, 'done-deferred');
      _save(root, 'status.json', <String, Object?>{
        'state': 'done',
        'quality': <String, Object?>{
          'state': 'pending',
          'pending': <String>['chapter-titles', 'bio-0'],
        },
      });
      _save(root, 'work/jobs/bio-0.json', <String, Object?>{
        'kind': 'bio',
        'key': 0,
        'args': <Object?>[
          0,
          2500,
          '【P1｜小林】',
          <String>['P1'],
        ],
        'state': 'deferred',
        'failure_kind': 'bio_content',
      });
      int attempts = 0;
      double now = 1000;
      final jobs.Worker worker = jobs.Worker(
        books,
        probe: (Directory _) async => false,
        clock: () => now,
        settings: () => const jobs.WorkerSettings(),
        run: (
          Directory root, {
          required jobs.RunCancellation cancellation,
          required bool retryQuality,
          required String model,
          required String localModel,
          required int concurrency,
        }) async {
          attempts++;
          expect(retryQuality, isFalse);
          expect(
            _read(root, 'work/jobs/bio-0.json')['retry_requested'],
            isTrue,
          );
          if (attempts == 1) {
            _save(root, 'status.json', <String, Object?>{
              'state': 'error',
              'error': '章节标题网络暂不可用',
              'retryable': true,
              'quality': <String, Object?>{
                'state': 'pending',
                'pending': <String>['chapter-titles', 'bio-0'],
              },
            });
            throw const llm.TransientLLMError('章节标题网络暂不可用');
          }
          final Runner runner = await Runner.create(root, activity: false);
          try {
            runner.replaying = true;
            _person(runner, 'P1');
            runner.consolidate(0, 2500, 0);
            expect(runner.deferred, hasLength(1));
            expect(_read(root, 'work/jobs/bio-0.json')['state'], 'pending');
            expect(
              _read(root, 'work/jobs/bio-0.json')['retry_requested'],
              isNull,
            );
          } finally {
            await runner.close();
          }
          _save(root, 'status.json', <String, Object?>{'state': 'done'});
        },
      );
      try {
        await worker.startBook(root);
        await worker.waitIdle();
        expect(attempts, 1);
        expect(_read(root, 'work/jobs/bio-0.json')['retry_requested'], isTrue);
        now = (_read(root, 'status.json')['retry_at']! as num).toDouble() + 1;
        await worker.processBook(root);
        expect(attempts, 2);
        expect(_read(root, 'meta.json')['retry_quality'], isNull);
      } finally {
        await worker.close();
      }
    },
  );

  test('a deferred bio does not disable a later network retry', () async {
    final Directory root = _book(books, 'deferred-plus-network');
    _save(root, 'status.json', <String, Object?>{
      'state': 'paused',
      'quality': <String, Object?>{
        'state': 'pending',
        'pending': <String>['bio-0'],
      },
    });
    _save(root, 'work/jobs/bio-0.json', <String, Object?>{
      'kind': 'bio',
      'key': 0,
      'state': 'deferred',
      'failure_kind': 'bio_content',
    });
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
        _save(root, 'status.json', <String, Object?>{
          'state': 'error',
          'error': '模型网络暂不可用',
          'retryable': true,
          'quality': <String, Object?>{
            'state': 'pending',
            'pending': <String>['bio-0'],
          },
        });
        throw const llm.TransientLLMError('模型网络暂不可用');
      },
    );
    try {
      await worker.startBook(root);
      await worker.waitIdle();
      expect(_read(root, 'meta.json')['auto'], isTrue);
      expect(_read(root, 'status.json')['retryable'], isTrue);
      expect(_read(root, 'status.json')['retry_at'], isA<num>());
      expect(_read(root, 'work/jobs/bio-0.json')['state'], 'deferred');
    } finally {
      await worker.close();
    }
  });

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

  test(
    'failed bio and pending title check retry without archiving verified work',
    () async {
      final Directory root = _book(books, 'bio-and-titles', chapters: 2);
      _save(root, 'status.json', <String, Object?>{
        'state': 'error',
        'quality': <String, Object?>{
          'state': 'pending',
          'pending': <String>['bio-0', 'chapter-titles'],
        },
      });
      _save(root, 'work/jobs/bio-0.json', <String, Object?>{
        'kind': 'bio',
        'key': 0,
        'state': 'failed',
        'failure_kind': 'bio_content',
        'generation_attempt': 1,
      });
      final Json verifiedBio = <String, Object?>{
        'chapter': 1,
        'bios': <String, Object?>{
          'P1': <String, Object?>{
            ..._bio('已核对的小传。'),
            'chk': <String, Object?>{'verdict': 'ok'},
          },
        },
      };
      _save(root, 'work/bios/0001.json', verifiedBio);
      _save(root, 'work/jobs/bio-1.json', <String, Object?>{
        'kind': 'bio',
        'key': 1,
        'state': 'complete',
      });
      _save(root, 'work/drafts/bio-1.json', <String, Object?>{
        'text': '已保留的生成草稿',
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
          if (retryQuality) {
            final Runner runner = await Runner.create(root, activity: false);
            try {
              runner.prepareQualityRetry();
            } finally {
              await runner.close();
            }
          }
          _save(root, 'status.json', <String, Object?>{'state': 'done'});
        },
      );
      try {
        await worker.startBook(root);
        await worker.waitIdle();
        expect(calls, <bool>[false]);
        expect(_read(root, 'meta.json')['retry_quality'], isNull);
        expect(_read(root, 'work/bios/0001.json'), verifiedBio);
        expect(_read(root, 'work/jobs/bio-1.json')['state'], 'complete');
        expect(_read(root, 'work/drafts/bio-1.json')['text'], '已保留的生成草稿');
        expect(
          File('${root.path}/work/quality-retry.json').existsSync(),
          isFalse,
        );
      } finally {
        await worker.close();
      }
    },
  );

  test(
    'old failed bio job does not turn title-only retry into a rebuild',
    () async {
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
        expect(calls, <bool>[false]);
      } finally {
        await worker.close();
      }
    },
  );

  test(
    'completed book retries only title checks without archiving final work',
    () async {
      final Directory root = _book(books, 'titles-only');
      _save(root, 'status.json', <String, Object?>{
        'state': 'done',
        'done': 1,
        'total': 1,
        'quality': <String, Object?>{
          'state': 'pending',
          'pending': <String>['chapter-titles'],
        },
      });
      final Map<String, Object?> retained = <String, Object?>{
        'work/bios/0000.json': <String, Object?>{'verified': true},
        'work/drafts/bio-0.json': <String, Object?>{'draft': true},
        'work/jobs/bio-0.json': <String, Object?>{
          'kind': 'bio',
          'state': 'complete',
        },
        'work/segs/0000.json': <String, Object?>{
          'mode': 'two-phase',
          'verified': true,
        },
      };
      for (final MapEntry<String, Object?> entry in retained.entries) {
        _save(root, entry.key, entry.value);
      }
      environ['JUDGE_TITLES'] = '1';
      int titleChecks = 0;
      judge.judgeCall = (Object? _, Json questions) async {
        titleChecks++;
        return <String, Object?>{
          for (final String key in questions.keys)
            key: <String, Object?>{
              'choice': 'spoils',
              'probabilities': <String, Object?>{'spoils': 0.95},
            },
        };
      };
      final List<bool> attempts = <bool>[];
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
          attempts.add(retryQuality);
          final Runner runner = await Runner.create(root, activity: false);
          try {
            if (retryQuality) runner.prepareQualityRetry();
            await runner.markTitles();
          } finally {
            await runner.close();
          }
          final Json status = _read(root, 'status.json');
          status['state'] = 'done';
          status['quality'] = <String, Object?>{
            'state': 'verified',
            'pending': <String>[],
          };
          _save(root, 'status.json', status);
        },
      );
      try {
        await worker.startBook(root);
        await worker.waitIdle();
        expect(attempts, <bool>[false]);
        expect(titleChecks, 1);
        final Json book = _read(root, 'book.json');
        expect(
          (book['chapters']! as List<Object?>).first,
          containsPair('spoil', true),
        );
        for (final MapEntry<String, Object?> entry in retained.entries) {
          expect(_read(root, entry.key), entry.value, reason: entry.key);
        }
        expect(
          File('${root.path}/work/quality-retry.json').existsSync(),
          isFalse,
        );
        expect(_read(root, 'status.json')['quality'], <String, Object?>{
          'state': 'verified',
          'pending': <String>[],
        });
      } finally {
        await worker.close();
      }
    },
  );

  test(
    'critical quality pending still requests a rebuild beside failed bio',
    () async {
      final Directory root = _book(books, 'critical-and-bio');
      _save(root, 'status.json', <String, Object?>{
        'state': 'error',
        'quality': <String, Object?>{
          'state': 'pending',
          'pending': <String>[
            'bio-0',
            'chapter-titles',
            'quarantined-critical-checks',
          ],
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
    },
  );
}
