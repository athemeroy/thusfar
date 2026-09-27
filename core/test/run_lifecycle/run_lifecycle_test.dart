import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:thusfar_core/jobs.dart' as jobs;
import 'package:thusfar_core/run.dart';
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/pipeline/judge.dart' as judge;
import 'package:thusfar_core/src/pipeline/llm.dart' as llm;

typedef Json = Map<String, Object?>;

class NoNetwork implements llm.ChatTransport {
  int calls = 0;
  @override
  Future<llm.ChatResponse> post(llm.ChatRequest request, Duration timeout) {
    calls++;
    throw StateError('Network is forbidden in runner lifecycle tests');
  }
}

class NoModels extends RunBackend {
  int calls = 0;
  Never unexpected() {
    calls++;
    throw StateError('No model call is permitted for cached replay');
  }

  @override
  Future<Json> evaluate(Object? state, Json questions) async => unexpected();
  @override
  Future<(Object?, Json)> generate(
    String model,
    List<Map<String, String>> messages, {
    bool jsonOutput = false,
    int maxTokens = 8000,
    double temperature = 0.2,
  }) async => unexpected();
  @override
  Future<(Json, Json)> extractLocal(
    Json book,
    Json seg,
    Json? previous,
    String model,
    String hint,
  ) async => unexpected();
}

class PendingExtraction extends NoModels {
  PendingExtraction({this.result});
  final Json? result;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  @override
  Future<(Json, Json)> extractLocal(
    Json book,
    Json seg,
    Json? previous,
    String model,
    String hint,
  ) async {
    calls++;
    started.complete();
    await release.future;
    if (result != null) {
      return (
        result!,
        <String, Object?>{'prompt_tokens': 10, 'completion_tokens': 5},
      );
    }
    throw const Cancelled();
  }
}

class PendingClassic extends NoModels {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  @override
  Future<(Json, Json)> extractClassic(
    Json book,
    Json state,
    Json seg,
    String model,
  ) async {
    calls++;
    started.complete();
    await release.future;
    return (
      <String, Object?>{
        'new_people': <Json>[
          <String, Object?>{'ref': 'a', 'name': '小林', 'intro': '小林在家中'},
        ],
        'aliases': <Object?>[],
        'merges': <Object?>[],
        'events': <Object?>[],
        'attrs': <Object?>[],
        'rels': <Object?>[],
        'profiles': <Object?>[],
        'surfaces': <String, Object?>{},
      },
      <String, Object?>{'prompt_tokens': 10, 'completion_tokens': 5},
    );
  }
}

class PendingGeneration extends NoModels {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  @override
  Future<(Object?, Json)> generate(
    String model,
    List<Map<String, String>> messages, {
    bool jsonOutput = false,
    int maxTokens = 8000,
    double temperature = 0.2,
  }) async {
    calls++;
    started.complete();
    await release.future;
    return (
      '小林回到家中。',
      <String, Object?>{'prompt_tokens': 10, 'completion_tokens': 5},
    );
  }
}

Json read(Directory root, String name) =>
    jsonDecode(File('${root.path}/$name').readAsStringSync()) as Json;

void save(Directory root, String name, Object? value) =>
    writeJson(File('${root.path}/$name'), value);

Directory minimalBook(Directory books, String name) {
  final Directory root = Directory('${books.path}/$name')..createSync();
  const String passage = '小林回到家中，打开窗户，望着窗外的树。';
  save(root, 'book.json', <String, Object?>{
    'title': '离线生命周期测试',
    'author': '',
    'lang': 'zh',
    'genre': 'novel',
    'classified': true,
    'len': passage.length,
    'blocks': <Json>[
      <String, Object?>{'k': 'p', 't': passage, 'o': 0},
    ],
    'chapters': <Json>[
      <String, Object?>{
        'title': '一',
        'b0': 0,
        'b1': 1,
        'o0': 0,
        'o1': passage.length,
        'kind': 'body',
        'spoil': false,
      },
    ],
    'notes': <String, Object?>{},
  });
  save(root, 'meta.json', <String, Object?>{'auto': false});
  save(root, 'status.json', <String, Object?>{'state': 'idle'});
  return root;
}

Directory copyBook(Directory source, Directory parent, String name) {
  final Directory target = Directory('${parent.path}/$name')..createSync();
  for (final FileSystemEntity entity in source.listSync(recursive: true)) {
    final String relative = entity.path.substring(source.path.length + 1);
    if (entity is Directory) {
      Directory('${target.path}/$relative').createSync(recursive: true);
    } else if (entity is File) {
      File('${target.path}/$relative').parent.createSync(recursive: true);
      entity.copySync('${target.path}/$relative');
    } else {
      throw StateError('Fixture contains a non-file entity');
    }
  }
  return target;
}

Map<String, String> immutableCacheHashes(Directory root) => <String, String>{
  for (final File file
      in Directory(
        '${root.path}/work',
      ).listSync(recursive: true).whereType<File>())
    if (!<String>{
      'run.lock',
      'usage.json',
    }.contains(file.uri.pathSegments.last))
      file.path.substring(root.path.length + 1):
          sha256.convert(file.readAsBytesSync()).toString(),
};

void main() {
  late Directory books;
  late Map<String, String> previousEnvironment;
  late llm.ChatTransport previousTransport;
  late NoNetwork network;
  late Future<Json> Function(Object?, Json) previousJudge;
  int judgeCalls = 0;
  setUp(() {
    books = Directory.systemTemp.createTempSync('thusfar-run-lifecycle-');
    previousEnvironment = Map<String, String>.of(environ);
    environ.addAll(<String, String>{
      'JUDGE_TITLES': '0',
      'JUDGE_RELATIONS': '0',
      'VERIFY_RECORDS': '0',
      'JUDGE_LOG': '0',
      'JEV_ROUTE': 'free-only',
      'JEV_RETRIES': '0',
      'JEV_FREE_RETRIES': '0',
    });
    previousTransport = llm.transport;
    llm.transport = network = NoNetwork();
    previousJudge = judge.judgeCall;
    judgeCalls = 0;
    judge.judgeCall = (Object? state, Json questions) async {
      judgeCalls++;
      throw StateError('No judge call is permitted in lifecycle tests');
    };
  });
  tearDown(() {
    llm.transport = previousTransport;
    judge.judgeCall = previousJudge;
    environ
      ..clear()
      ..addAll(previousEnvironment);
    if (books.existsSync()) books.deleteSync(recursive: true);
    expect(network.calls, 0, reason: 'Lifecycle tests must stay fully offline');
    expect(
      judgeCalls,
      0,
      reason: 'Cancellation and cached replay must not start new verification',
    );
  });

  test(
    'pre-cancelled execution releases its lease before touching the book',
    () async {
      final Directory root = minimalBook(books, 'pre-cancelled');
      final List<int> original =
          File('${root.path}/book.json').readAsBytesSync();
      final RunCancellation cancellation = RunCancellation()..cancel();
      final NoModels backend = NoModels();
      await expectLater(
        runBook(root, cancellation: cancellation, backend: backend),
        throwsA(isA<Cancelled>()),
      );
      expect(backend.calls, 0);
      expect(File('${root.path}/book.json').readAsBytesSync(), original);
      expect(read(root, 'status.json')['state'], 'idle');
      expect(await isBookRunning(root), isFalse);
    },
  );

  test(
    'existing ownership prevents a second runner and preserves its status',
    () async {
      final Directory root = minimalBook(books, 'owned');
      final RunLease lease = await RunLease.acquire(root);
      final NoModels backend = NoModels();
      try {
        await expectLater(
          runBook(root, backend: backend),
          throwsA(isA<AlreadyRunning>()),
        );
        expect(backend.calls, 0);
        expect(read(root, 'status.json')['state'], 'idle');
        expect(await isBookRunning(root), isTrue);
      } finally {
        lease.release();
      }
      expect(await isBookRunning(root), isFalse);
    },
  );

  test(
    'worker pause retains the real runner lease until an in-flight extraction settles',
    () async {
      final Directory root = minimalBook(books, 'pending');
      final PendingExtraction backend = PendingExtraction();
      final jobs.Worker worker = jobs.Worker(
        books,
        settings:
            () => const jobs.WorkerSettings(
              model: 'offline',
              localModel: 'offline',
              concurrency: 1,
            ),
        run:
            (
              Directory root, {
              required RunCancellation cancellation,
              required bool retryQuality,
              required String model,
              required String localModel,
              required int concurrency,
            }) => runBook(
              root,
              cancellation: cancellation,
              retryQuality: retryQuality,
              model: model,
              localModel: localModel,
              concurrency: concurrency,
              backend: backend,
            ),
      );
      try {
        await worker.startBook(root);
        await backend.started.future.timeout(const Duration(seconds: 3));
        expect(await isBookRunning(root), isTrue);
        await worker.pauseBook(root, timeout: const Duration(milliseconds: 1));
        expect(worker.health()['current'], 'pending');
        expect(await isBookRunning(root), isTrue);
        bool idle = false;
        final Future<void> settlement = worker
            .waitBookIdle(root)
            .then((_) => idle = true);
        await Future<void>.delayed(const Duration(milliseconds: 1));
        expect(idle, isFalse);
        expect(backend.calls, 1);
        backend.release.complete();
        await settlement;
        await worker.waitIdle();
        expect(idle, isTrue);
        expect(read(root, 'status.json')['state'], 'paused');
        expect(read(root, 'meta.json')['auto'], isFalse);
        expect(await isBookRunning(root), isFalse);
        expect(worker.health()['current'], isNull);
        expect(backend.calls, 1);
      } finally {
        if (!backend.release.isCompleted) backend.release.complete();
        await worker.close();
      }
    },
  );

  test(
    'pause retains a completed extraction cache without starting its verification',
    () async {
      final Directory root = minimalBook(books, 'settled-answer');
      environ['VERIFY_RECORDS'] = '1';
      final Json result = <String, Object?>{
        'people': <Json>[
          <String, Object?>{'id': 'a', 'name': '小林', 'role': '人物'},
        ],
        'same': <Object?>[],
        'events': <Object?>[],
        'facts': <Json>[
          <String, Object?>{'who': 'a', 'key': '位置', 'value': '家中'},
        ],
        'rels': <Object?>[],
      };
      final PendingExtraction backend = PendingExtraction(result: result);
      final RunCancellation cancellation = RunCancellation();
      final Future<void> execution = runBook(
        root,
        cancellation: cancellation,
        model: 'offline',
        localModel: 'offline',
        concurrency: 1,
        backend: backend,
      );
      final Future<void> cancelled = expectLater(
        execution,
        throwsA(isA<Cancelled>()),
      );
      try {
        await backend.started.future.timeout(const Duration(seconds: 3));
        cancellation.cancel();
        backend.release.complete();
        await cancelled;
        expect(backend.calls, 1);
        expect(read(root, 'work/local/0000.json')['data'], result);
        expect(read(root, 'work/usage.json')['llm_calls'], 1);
        expect(read(root, 'status.json')['state'], 'paused');
        expect(
          read(root, 'status.json')['usage'],
          read(root, 'work/usage.json'),
        );
        expect(network.calls, 0);
        expect(await isBookRunning(root), isFalse);
      } finally {
        if (!backend.release.isCompleted) backend.release.complete();
        await cancelled;
      }
    },
  );

  test(
    'classic cancellation also saves the settled draft and stops before verification',
    () async {
      final Directory root = minimalBook(books, 'classic-settled-answer');
      final PendingClassic backend = PendingClassic();
      final RunCancellation cancellation = RunCancellation();
      final Future<void> execution = runBook(
        root,
        cancellation: cancellation,
        model: 'offline',
        classic: true,
        concurrency: 1,
        backend: backend,
      );
      final Future<void> cancelled = expectLater(
        execution,
        throwsA(isA<Cancelled>()),
      );
      try {
        await backend.started.future.timeout(const Duration(seconds: 3));
        cancellation.cancel();
        backend.release.complete();
        await cancelled;
        expect(backend.calls, 1);
        expect(
          File('${root.path}/work/classic_raw/0000.json').existsSync(),
          isTrue,
        );
        expect(read(root, 'work/usage.json')['llm_calls'], 1);
        expect(read(root, 'status.json')['state'], 'paused');
        expect(
          read(root, 'status.json')['usage'],
          read(root, 'work/usage.json'),
        );
        expect(judgeCalls, 0);
        expect(await isBookRunning(root), isFalse);
      } finally {
        if (!backend.release.isCompleted) backend.release.complete();
        await cancelled;
      }
    },
  );

  test(
    'chapter finalization saves its generated draft but pauses before its guard',
    () async {
      final Directory root = minimalBook(books, 'recap-settled-answer');
      final PendingGeneration backend = PendingGeneration();
      final RunCancellation cancellation = RunCancellation();
      final Runner runner = await Runner.create(
        root,
        model: 'offline',
        cancellation: cancellation,
        backend: backend,
      );
      final Future<Json> operation = runner.chapterRecapJob(0, 20, <Json>[
        <String, Object?>{'text': '小林回到家中。', 'who': <String>[], 'imp': 3},
      ], <String, Object?>{});
      final Future<void> cancelled = expectLater(
        operation,
        throwsA(isA<Cancelled>()),
      );
      try {
        await backend.started.future.timeout(const Duration(seconds: 3));
        cancellation.cancel();
        backend.release.complete();
        await cancelled;
        final List<File> drafts =
            Directory(
              '${root.path}/work/drafts',
            ).listSync().whereType<File>().toList();
        expect(drafts, hasLength(1));
        expect(
          (jsonDecode(drafts.single.readAsStringSync()) as Json)['value'],
          '小林回到家中。',
        );
        expect(read(root, 'work/usage.json')['llm_calls'], 1);
        expect(
          File('${root.path}/work/recaps/0000.json').existsSync(),
          isFalse,
        );
        expect(judgeCalls, 0);
      } finally {
        if (!backend.release.isCompleted) backend.release.complete();
        await cancelled;
        await runner.close(cancelled: true);
      }
    },
  );

  test(
    'source-manifest mismatch is visible, retains caches and releases its lease',
    () async {
      final Directory root = minimalBook(books, 'changed');
      save(root, 'work/cache-manifest.json', <String, Object?>{
        'schema': 2,
        'input_sha256': 'belongs-to-a-different-book',
      });
      save(root, 'work/local/0000.json', <String, Object?>{'untouched': true});
      final Map<String, String> before = immutableCacheHashes(root);
      final NoModels backend = NoModels();
      await expectLater(
        runBook(root, backend: backend),
        throwsA(
          predicate<Object>(
            (Object error) => error.toString().contains('旧缓存不能混用'),
          ),
        ),
      );
      expect(backend.calls, 0);
      expect(read(root, 'status.json')['state'], 'error');
      expect(immutableCacheHashes(root), before);
      expect(await isBookRunning(root), isFalse);
    },
  );

  test(
    'quality retry archives derived results while retaining paid local extraction',
    () async {
      final Directory root = minimalBook(books, 'quality-archive');
      final NoModels backend = NoModels();
      final Runner runner = await Runner.create(root, backend: backend);
      final List<String> derived = <String>[
        'work/segs/0000.json',
        'work/dedupe/0000.json',
        'work/bios/0000.json',
        'work/recaps/0000.json',
        'work/sagas/000000020.json',
        'work/jobs/recap-0.json',
        'work/finalize/attrs-20.json',
        'work/drafts/recap-draft.json',
      ];
      for (final String path in derived) {
        save(root, path, <String, Object?>{'original': path});
      }
      save(root, 'work/local/0000.json', <String, Object?>{'paid': 'retained'});
      final Map<String, List<int>> originals = <String, List<int>>{
        for (final String path in derived)
          path: File('${root.path}/$path').readAsBytesSync(),
      };
      runner.repairPolicy = <String, Object?>{
        'input_sha256': runner.inputSha256,
        'quarantine_after': 0,
      };
      runner.qualityPending = <String>{
        'chapter-titles',
        'quarantined-critical-checks',
      };
      save(root, 'work/repair-policy.json', runner.repairPolicy);
      try {
        runner.prepareQualityRetry();
        final Json journal = read(root, 'work/quality-retry.json');
        expect(journal['state'], 'rebuilding');
        expect(journal['first_segment'], 0);
        expect(journal['files'], hasLength(derived.length));
        for (final Json row
            in (journal['files']! as List<Object?>).cast<Json>()) {
          final String path = row['path']! as String;
          final List<int> archived =
              File(
                '${root.path}/${journal['archive']}/$path',
              ).readAsBytesSync();
          expect(archived, originals[path], reason: path);
          expect(sha256.convert(archived).toString(), row['sha256']);
          expect(File('${root.path}/$path').existsSync(), isFalse);
        }
        expect(read(root, 'work/local/0000.json'), <String, Object?>{
          'paid': 'retained',
        });
        expect(
          read(root, '${journal['archive']}/snapshot/status.json')['state'],
          'idle',
        );
        expect(runner.qualityPending, <String>{
          'chapter-titles',
          'quality-rebuild',
        });
        runner.finishQualityRetry();
        expect(read(root, 'work/quality-retry.json')['state'], 'complete');
        expect(runner.qualityPending, <String>{'chapter-titles'});
        expect(backend.calls, 0);
      } finally {
        await runner.close();
      }
    },
  );

  test(
    'interrupted quality archiving resumes the same archive and verifies duplicate originals',
    () async {
      final Directory root = minimalBook(books, 'quality-resume');
      final Runner runner = await Runner.create(root, backend: NoModels());
      const String archive = 'work/retry-archive/interrupted';
      final List<Json> rows = <Json>[];
      for (final (int i, String path)
          in <String>[
            'work/recaps/0000.json',
            'work/bios/0000.json',
            'work/sagas/000000020.json',
          ].indexed) {
        final Json data = <String, Object?>{'original': path};
        if (i != 1)
          save(root, path, data); // First still original, second already moved.
        if (i != 0)
          save(root, '$archive/$path', data); // Third exists in both places.
        final File present = File(
          '${root.path}/${i == 1 ? '$archive/' : ''}$path',
        );
        rows.add(<String, Object?>{
          'path': path,
          'sha256': sha256.convert(present.readAsBytesSync()).toString(),
        });
      }
      save(root, 'work/quality-retry.json', <String, Object?>{
        'state': 'archiving',
        'archive': archive,
        'first_segment': 0,
        'files': rows,
        'input_sha256': runner.inputSha256,
      });
      try {
        runner.prepareQualityRetry();
        final Json journal = read(root, 'work/quality-retry.json');
        expect(journal['state'], 'rebuilding');
        expect(journal['archive'], archive);
        for (final Json row in rows) {
          expect(File('${root.path}/${row['path']}').existsSync(), isFalse);
          expect(
            sha256
                .convert(
                  File(
                    '${root.path}/$archive/${row['path']}',
                  ).readAsBytesSync(),
                )
                .toString(),
            row['sha256'],
          );
        }
        runner.prepareQualityRetry();
        expect(read(root, 'work/quality-retry.json'), journal);
        expect(
          Directory('${root.path}/work/retry-archive').listSync(),
          hasLength(1),
        );
      } finally {
        await runner.close();
      }
    },
  );

  test(
    'quality archive corruption or missing originals preserves the journal and remaining evidence',
    () async {
      for (final String damage in <String>['original', 'archive', 'missing']) {
        final Directory root = minimalBook(books, 'quality-$damage');
        final Runner runner = await Runner.create(root, backend: NoModels());
        const String relative = 'work/recaps/0000.json',
            archive = 'work/retry-archive/interrupted';
        save(root, relative, <String, Object?>{'original': true});
        final File original = File('${root.path}/$relative');
        final String hash =
            sha256.convert(original.readAsBytesSync()).toString();
        save(root, 'work/quality-retry.json', <String, Object?>{
          'state': 'archiving',
          'archive': archive,
          'first_segment': 0,
          'files': <Json>[
            <String, Object?>{'path': relative, 'sha256': hash},
          ],
          'input_sha256': runner.inputSha256,
        });
        if (damage == 'missing') {
          original.deleteSync();
        } else if (damage == 'original') {
          save(root, relative, <String, Object?>{'user_edits': 'preserve'});
        } else {
          save(root, '$archive/$relative', <String, Object?>{
            'archive_changed': true,
          });
        }
        final Map<String, String> before = immutableCacheHashes(root);
        try {
          expect(
            runner.prepareQualityRetry,
            throwsA(
              predicate<Object>(
                (Object error) => error.toString().contains(
                  damage == 'missing' ? '原件及归档均缺失' : '归档期间变更',
                ),
              ),
            ),
          );
          expect(immutableCacheHashes(root), before, reason: damage);
          expect(read(root, 'work/quality-retry.json')['state'], 'archiving');
        } finally {
          await runner.close();
        }
      }
    },
  );

  test(
    'limit zero replays all nine legacy segments without model calls or cache rewrites',
    () async {
      final Directory fixture = Directory(
        '../oracle/corpus/snapshots/aq_complete',
      );
      final Directory root = copyBook(fixture, books, 'legacy-complete');
      final Map<String, String> before = immutableCacheHashes(root);
      final NoModels backend = NoModels();
      await runBook(root, limit: 0, backend: backend);
      final Json state = read(root, 'status.json');
      expect(
        <Object?>[
          state['state'],
          state['done'],
          state['total'],
          state['frontier'],
        ],
        <Object?>['done', 9, 9, 21733],
      );
      expect(backend.calls, 0);
      expect(immutableCacheHashes(root), before);
      expect(read(root, 'kg.json'), read(fixture, 'kg.json'));
      for (final File file
          in Directory(
            '${fixture.path}/mentions',
          ).listSync().whereType<File>()) {
        final String name = file.uri.pathSegments.last;
        expect(
          jsonDecode(File('${root.path}/mentions/$name').readAsStringSync()),
          jsonDecode(file.readAsStringSync()),
          reason: name,
        );
      }
      expect(await isBookRunning(root), isFalse);
    },
  );
}
