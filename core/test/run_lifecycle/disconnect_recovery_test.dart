import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/jobs.dart' as jobs;
import 'package:thusfar_core/run.dart';
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/pipeline/llm.dart' as llm;
import 'package:thusfar_core/src/pipeline/request_lifecycle.dart';

import '../pipeline/request_interruption_test.dart'
    show FixtureTransport, streamReply;
import 'run_lifecycle_test.dart' show minimalBook, read, save;

typedef Json = Map<String, Object?>;

void main() {
  late Directory books;
  late Map<String, String> previousEnv;
  late llm.ChatTransport previousTransport;
  final List<jobs.Worker> workers = <jobs.Worker>[];
  setUp(() {
    books = Directory.systemTemp.createTempSync('thusfar-disconnect-');
    previousEnv = Map<String, String>.of(environ);
    previousTransport = llm.transport;
    environ
      ..clear()
      ..addAll(<String, String>{
        'LLM_API_KEY': 'offline-test',
        'LLM_BASE_URL': 'https://offline.invalid/v1',
        'LLM_RETRIES': '4',
        'LOCAL_SEGMENT_RETRIES': '4',
        'LLM_WALL_TIMEOUT': '2',
        'JUDGE_TITLES': '0',
        'JUDGE_RELATIONS': '0',
        'VERIFY_RECORDS': '0',
        'JUDGE_LOG': '0',
        'JEV_ROUTE': 'free-only',
      });
  });
  tearDown(() async {
    for (final jobs.Worker worker in workers) {
      await worker.close();
    }
    workers.clear();
    llm.transport = previousTransport;
    environ
      ..clear()
      ..addAll(previousEnv);
    books.deleteSync(recursive: true);
  });

  jobs.Worker realWorker() {
    final jobs.Worker worker = jobs.Worker(
      books,
      resumeInterrupted: true,
      settings:
          () => const jobs.WorkerSettings(
            model: 'fixture',
            localModel: 'fixture',
            concurrency: 1,
          ),
    );
    workers.add(worker);
    return worker;
  }

  test(
    'network loss crosses chat, segment and worker layers with one dispatch',
    () async {
      final Directory root = minimalBook(books, 'lost');
      final FixtureTransport fake = FixtureTransport(
        (_) async => throw const SocketException('fixture'),
      );
      llm.transport = fake;
      final jobs.Worker worker = realWorker();
      await worker.startBook(root);
      await worker.waitIdle();
      expect(fake.calls, 1);
      expect(read(root, 'status.json')['state'], 'paused');
      expect(
        read(root, 'status.json')['pause_reason'],
        'request_outcome_unknown',
      );
      expect(read(root, 'status.json')['failure_code'], 'network_interrupted');
      expect(read(root, 'status.json')['retryable'], isFalse);
      expect(read(root, 'status.json').containsKey('retry_at'), isFalse);
      expect(read(root, 'meta.json')['auto'], isFalse);
      expect(hasUnsettledModelRequests(root), isTrue);
      await worker.processBook(root);
      expect(fake.calls, 1);
      expect(await isBookRunning(root), isFalse);
    },
  );

  test(
    'cache-write failure retains received evidence and never replays inside the run',
    () async {
      final Directory root = minimalBook(books, 'cache-failure');
      // A directory at the file destination deterministically denies the atomic
      // cache rename after the complete, locally mocked response is received.
      Directory(
        '${root.path}/work/local/0000.json',
      ).createSync(recursive: true);
      final FixtureTransport fake = FixtureTransport(
        (_) async => streamReply(
          '{"people":[],"same":[],"events":[],"facts":[],"rels":[]}',
        ),
      );
      llm.transport = fake;
      final jobs.Worker worker = realWorker();
      await worker.startBook(root);
      await worker.waitIdle();
      expect(fake.calls, 1);
      expect(hasUnsettledModelRequests(root), isTrue);
      expect(
        File('${root.path}/work/model-request-journal.json').readAsStringSync(),
        contains('received'),
      );
      expect(
        read(root, 'status.json')['pause_reason'],
        'request_outcome_unknown',
      );
      expect(read(root, 'meta.json')['auto'], isFalse);
      await worker.processBook(root);
      expect(fake.calls, 1);
      expect(await isBookRunning(root), isFalse);
    },
  );

  for (final jobs.BookPauseReason reason in <jobs.BookPauseReason>[
    jobs.BookPauseReason.user,
    jobs.BookPauseReason.backgroundTimeLimit,
    jobs.BookPauseReason.backgroundUnavailable,
  ]) {
    test(
      '${reason.value} promptly stops live I/O and cannot overwrite unknown outcome',
      () async {
        final Directory root = minimalBook(books, reason.value);
        final Completer<void> started = Completer<void>();
        bool disconnected = false;
        final StreamController<List<int>> body = StreamController<List<int>>(
          onListen: () => started.complete(),
          onCancel: () => disconnected = true,
        );
        final FixtureTransport fake = FixtureTransport(
          (_) async => llm.ChatResponse(200, 'text/event-stream', body.stream),
        );
        llm.transport = fake;
        final jobs.Worker worker = realWorker();
        await worker.startBook(root);
        await started.future.timeout(const Duration(seconds: 2));
        await worker
            .pauseBook(root, reason: reason)
            .timeout(const Duration(seconds: 1));
        await worker.waitIdle();
        expect(disconnected, isTrue);
        expect(fake.calls, 1);
        expect(worker.health()['current'], isNull);
        expect(await isBookRunning(root), isFalse);
        expect(read(root, 'meta.json')['auto'], isFalse);
        expect(
          read(root, 'status.json')['pause_reason'],
          'request_outcome_unknown',
        );
        expect(hasUnsettledModelRequests(root), isTrue);
        await body.close();
      },
    );
  }

  for (final String phase in <String>[
    'inflight',
    'received',
    'unknown',
    'corrupt',
  ]) {
    test(
      'restart requires explicit resume after $phase dispatch evidence',
      () async {
        final Directory root = minimalBook(books, phase);
        save(root, 'meta.json', <String, Object?>{'auto': true});
        save(root, 'status.json', <String, Object?>{
          'state': 'running',
          'done': 1,
        });
        save(root, 'work/local/0000.json', <String, Object?>{
          'verified': 'paid-cache',
        });
        final String cache =
            File('${root.path}/work/local/0000.json').readAsStringSync();
        final File journal = File(
          '${root.path}/work/model-request-journal.json',
        );
        journal.writeAsStringSync(
          phase == 'corrupt'
              ? '{broken'
              : jsonEncode(<String, Object?>{
                'version': 1,
                'requests': <Object?>[
                  <String, Object?>{'id': 1, 'phase': phase},
                ],
              }),
        );
        int calls = 0;
        final jobs.Worker worker = jobs.Worker(
          books,
          resumeInterrupted: true,
          run: (
            Directory root, {
            required RunCancellation cancellation,
            required bool retryQuality,
            required String model,
            required String localModel,
            required int concurrency,
          }) async {
            calls++;
            expect(hasUnsettledModelRequests(root), isFalse);
            expect(
              File('${root.path}/work/local/0000.json').readAsStringSync(),
              cache,
            );
            save(root, 'status.json', <String, Object?>{
              'state': 'done',
              'done': 1,
            });
          },
        );
        workers.add(worker);
        await worker.start();
        await worker.waitIdle();
        expect(calls, 0);
        expect(
          read(root, 'status.json')['pause_reason'],
          'request_outcome_unknown',
        );
        expect(read(root, 'meta.json')['auto'], isFalse);
        expect(read(root, 'status.json')['done'], 1);
        await worker.resumeBook(root);
        await worker.waitIdle();
        expect(calls, 1);
        expect(
          File('${root.path}/work/local/0000.json').readAsStringSync(),
          cache,
        );
      },
    );
  }

  test(
    'explicit resume cannot erase dispatch evidence owned by another runner',
    () async {
      final Directory root = minimalBook(books, 'external');
      save(root, 'work/model-request-journal.json', <String, Object?>{
        'requests': <Object?>[
          <String, Object?>{'phase': 'inflight'},
        ],
      });
      final RunLease lease = await RunLease.acquire(root);
      final jobs.Worker worker = realWorker();
      try {
        await expectLater(
          worker.startBook(root),
          throwsA(isA<jobs.BusyBook>()),
        );
        expect(hasUnsettledModelRequests(root), isTrue);
      } finally {
        lease.release();
      }
    },
  );

  test(
    'healthy received generation remains cached and is not repeated on resume',
    () async {
      final Directory root = minimalBook(books, 'checkpoint');
      int calls = 0;
      final FixtureTransport fake = FixtureTransport((_) async {
        calls++;
        return streamReply(
          '{"people":[],"same":[],"events":[],"facts":[],"rels":[]}',
        );
      });
      llm.transport = fake;
      final ModelRequestScope scope = ModelRequestScope(root);
      final Runner first = await Runner.create(root, model: 'fixture');
      await scope.run(() => first.localJob(0, 'fixture'));
      await first.close();
      expect(calls, 1);
      expect(File('${root.path}/work/local/0000.json').existsSync(), isTrue);
      scope.settle(receivedCommitted: true);
      expect(hasUnsettledModelRequests(root), isFalse);
      final Runner resumed = await Runner.create(root, model: 'fixture');
      await resumed.localJob(0, 'fixture');
      await resumed.close();
      expect(calls, 1);
    },
  );

  test(
    'queued books never publish a false idle transition between runs',
    () async {
      final Directory a = minimalBook(books, 'a'), b = minimalBook(books, 'b');
      final Completer<void> aStarted = Completer<void>(),
          bStarted = Completer<void>();
      final Completer<void> aRelease = Completer<void>(),
          bRelease = Completer<void>();
      final List<Json> observed = <Json>[];
      final jobs.Worker worker = jobs.Worker(
        books,
        onChange: (Json health) => observed.add(health),
        run: (
          Directory root, {
          required RunCancellation cancellation,
          required bool retryQuality,
          required String model,
          required String localModel,
          required int concurrency,
        }) async {
          if (root.path == a.path) {
            aStarted.complete();
            await aRelease.future;
          } else {
            bStarted.complete();
            await bRelease.future;
          }
          save(root, 'status.json', <String, Object?>{'state': 'done'});
        },
      );
      workers.add(worker);
      await worker.startBook(a);
      await aStarted.future;
      await worker.startBook(b);
      observed.clear();
      aRelease.complete();
      await bStarted.future;
      expect(observed, isNotEmpty);
      expect(
        observed.where(
          (h) =>
              h['current'] == null && (h['queued']! as List<Object?>).isEmpty,
        ),
        isEmpty,
      );
      bRelease.complete();
      await worker.waitIdle();
      expect(worker.health()['current'], isNull);
      expect(worker.health()['queued'], isEmpty);
    },
  );
}
