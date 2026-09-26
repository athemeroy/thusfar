import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:thusfar_core/jobs.dart';
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/pipeline/jev.dart' as jev;
import 'package:thusfar_core/storage.dart' show writeJson;

Json read(Directory root, String name) {
  final File f = File('${root.path}/$name');
  return f.existsSync()
      ? jsonDecode(f.readAsStringSync()) as Json
      : <String, Object?>{};
}

void save(Directory root, String name, Json value) =>
    writeJson(File('${root.path}/$name'), value);

Directory book(Directory books, String id, {Json? meta, Json? status}) {
  final Directory root = Directory('${books.path}/$id')
    ..createSync(recursive: true);
  save(root, 'book.json', <String, Object?>{'title': '离线测试'});
  save(root, 'meta.json', meta ?? <String, Object?>{'auto': false});
  save(root, 'status.json', status ?? <String, Object?>{'state': 'idle'});
  return root;
}

const WorkerSettings fixtureSettings = WorkerSettings(
  model: 'extract-fixture',
  localModel: 'local-fixture',
  concurrency: 3,
);
Future<bool> free(Directory _) async => false;

Future<void> until(bool Function() condition) async {
  final Stopwatch watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 3))
      fail('Worker did not reach expected boundary');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  late Directory books;
  final List<Worker> workers = <Worker>[];
  setUp(
    () => books = Directory.systemTemp.createTempSync('thusfar-worker-test-'),
  );
  tearDown(() async {
    for (final Worker worker in workers) {
      await worker.close(timeout: const Duration(milliseconds: 20));
    }
    workers.clear();
    if (books.existsSync()) books.deleteSync(recursive: true);
  });
  final Json fixtures =
      jsonDecode(
            File('test/jobs/fixtures/worker_oracles.json').readAsStringSync(),
          )
          as Json;
  test('worker reference was recorded from the current Python 3.11 source', () {
    expect(fixtures['python'], '3.11');
    expect(
      sha256.convert(File('../server/jobs.py').readAsBytesSync()).toString(),
      fixtures['source_sha256'],
    );
  });
  for (final Json scenario
      in (fixtures['cases']! as List<Object?>).cast<Json>()) {
    test('Python worker oracle: ${scenario['case']}', () async {
      final Json spec = scenario['input']! as Json;
      final Directory root = book(
        books,
        'fixture',
        meta: spec['meta'] as Json?,
        status: spec['status'] as Json?,
      );
      if (spec['journal'] != null)
        save(root, 'work/quality-retry.json', spec['journal']! as Json);
      final List<Json> calls = <Json>[];
      late Worker worker;
      worker = Worker(
        books,
        probe: free,
        clock: () => 5000,
        settings: () => fixtureSettings,
        run: (
          Directory directory, {
          required RunCancellation cancellation,
          required bool retryQuality,
          required String model,
          required String localModel,
          required int concurrency,
        }) async {
          expect(directory.path, root.path);
          calls.add(<String, Object?>{
            'retry_quality': retryQuality,
            'model': model,
            'local_model': localModel,
            'concurrency': concurrency,
          });
          switch (spec['run']) {
            case 'cancel':
              await worker.pauseBook(root, timeout: Duration.zero);
              expect(cancellation.isCancelled, isTrue);
              throw const Cancelled();
            case 'stop':
              worker.stop();
              expect(cancellation.isCancelled, isTrue);
              throw const Cancelled();
            case 'busy':
              throw const AlreadyRunning('fixture busy');
            case 'error':
              throw StateError('fixture failure');
            case 'incomplete':
              return;
          }
          if (spec['write_journal'] != null)
            save(
              root,
              'work/quality-retry.json',
              spec['write_journal']! as Json,
            );
          save(root, 'status.json', <String, Object?>{
            ...read(root, 'status.json'),
            'state': 'done',
          });
        },
      );
      workers.add(worker);
      for (final Object? action
          in spec['actions'] as List<Object?>? ?? <Object?>['one']) {
        if (action == 'enable') {
          await worker.setAuto(root, true);
        } else if (action == 'disable') {
          await worker.setAuto(root, false);
        } else {
          await worker.processBook(root);
        }
      }
      expect(<String, Object?>{
        'meta': read(root, 'meta.json'),
        'status': read(root, 'status.json'),
        'calls': calls,
        'last_error': worker.health()['last_error'],
        'current': worker.health()['current'],
        'journal':
            File('${root.path}/work/quality-retry.json').existsSync()
                ? read(root, 'work/quality-retry.json')
                : null,
      }, scenario['output']);
    });
  }

  test(
    'startup reconciles stale states without dispatching persisted auto flags or rebuilding caches',
    () async {
      final List<Directory> roots = <Directory>[
        for (final String state in <String>[
          'running',
          'finalizing',
          'cancelling',
          'queued',
        ])
          book(
            books,
            state,
            meta: <String, Object?>{'auto': true},
            status: <String, Object?>{
              'state': state,
              'done': 4,
              'frontier': 120,
            },
          ),
      ];
      for (final Directory root in roots) {
        save(root, 'work/seg-0000.json', <String, Object?>{
          'local': 'do not rewrite',
        });
      }
      final Directory done = book(
        books,
        'done',
        meta: <String, Object?>{'auto': true},
        status: <String, Object?>{
          'state': 'done',
          'quality': <String, Object?>{'state': 'pending'},
        },
      );
      int calls = 0;
      final Worker worker = Worker(
        books,
        probe: free,
        run: (
          Directory root, {
          required RunCancellation cancellation,
          required bool retryQuality,
          required String model,
          required String localModel,
          required int concurrency,
        }) async {
          calls++;
        },
      );
      workers.add(worker);
      await worker.start();
      await worker.waitIdle();
      expect(calls, 0);
      expect(worker.health()['alive'], isTrue);
      for (final Directory root in roots) {
        expect(read(root, 'status.json')['state'], 'paused');
        expect(read(root, 'status.json')['done'], 4);
        expect(read(root, 'status.json')['frontier'], 120);
        expect(read(root, 'meta.json'), <String, Object?>{'auto': true});
        expect(read(root, 'work/seg-0000.json'), <String, Object?>{
          'local': 'do not rewrite',
        });
        expect(read(root, 'work/worker-receipt.json')['reason'], 'reconciled');
      }
      expect(read(done, 'status.json')['state'], 'done');
      expect(read(done, 'meta.json').containsKey('retry_quality'), isFalse);
    },
  );

  test(
    'explicit tasks serialize and resolve current settings for each job',
    () async {
      final Directory a = book(books, 'a'), b = book(books, 'b');
      final List<String> calls = <String>[];
      final List<String> models = <String>[];
      final List<Completer<void>> pending = <Completer<void>>[];
      WorkerSettings settings = fixtureSettings;
      int active = 0, maximum = 0;
      final Worker worker = Worker(
        books,
        probe: free,
        settings: () => settings,
        run: (
          Directory root, {
          required RunCancellation cancellation,
          required bool retryQuality,
          required String model,
          required String localModel,
          required int concurrency,
        }) async {
          active++;
          if (active > maximum) maximum = active;
          calls.add(root.path);
          models.add(model);
          save(root, 'status.json', <String, Object?>{'state': 'running'});
          final Completer<void> boundary = Completer<void>();
          pending.add(boundary);
          await boundary.future;
          active--;
          save(root, 'status.json', <String, Object?>{'state': 'done'});
        },
      );
      workers.add(worker);
      await worker.startBook(a);
      await until(() => pending.length == 1);
      await worker.startBook(a);
      await worker.startBook(b);
      expect(calls, <String>[a.path]);
      settings = const WorkerSettings(
        model: 'new-reader-model',
        localModel: 'new-reader-model',
        concurrency: 1,
      );
      pending[0].complete();
      await until(() => pending.length == 2);
      pending[1].complete();
      await worker.waitIdle();
      expect(calls, <String>[a.path, b.path]);
      expect(models, <String>['extract-fixture', 'new-reader-model']);
      expect(maximum, 1);
      expect(worker.health()['current'], isNull);
      expect(read(a, 'work/worker-receipt.json')['phase'], 'done');
    },
  );

  test(
    'pause timeout retains the active slot and resume reuses receipt and cached work',
    () async {
      final Directory a = book(books, 'a'), b = book(books, 'b');
      save(a, 'work/segment-0000.json', <String, Object?>{
        'verified': true,
        'sequence': 1,
      });
      final List<String> calls = <String>[];
      final List<RunCancellation> tokens = <RunCancellation>[];
      final List<Completer<void>> pending = <Completer<void>>[];
      final Worker worker = Worker(
        books,
        probe: free,
        settings: () => fixtureSettings,
        run: (
          Directory root, {
          required RunCancellation cancellation,
          required bool retryQuality,
          required String model,
          required String localModel,
          required int concurrency,
        }) async {
          expect(retryQuality, isFalse);
          calls.add(root.path);
          tokens.add(cancellation);
          save(root, 'status.json', <String, Object?>{
            'state': 'running',
            'done': 1,
          });
          final Completer<void> boundary = Completer<void>();
          pending.add(boundary);
          await boundary.future;
          cancellation.check();
          save(root, 'status.json', <String, Object?>{
            'state': 'done',
            'done': 2,
          });
        },
      );
      workers.add(worker);
      await worker.startBook(a);
      await until(() => pending.length == 1);
      final Object? requestId =
          read(a, 'work/worker-receipt.json')['request_id'];
      await worker.startBook(b);
      await worker.pauseBook(a, timeout: const Duration(milliseconds: 1));
      expect(tokens[0].isCancelled, isTrue);
      expect(worker.health()['current'], 'a');
      expect(read(a, 'status.json')['state'], 'cancelling');
      expect(calls, <String>[a.path]);
      await expectLater(
        worker.resumeBook(a),
        throwsA(
          predicate<Object>(
            (Object error) => error.toString().contains('正在暂停'),
          ),
        ),
      );
      expect(read(a, 'meta.json')['auto'], isFalse);
      expect(worker.health()['current'], 'a');
      bool removalReady = false;
      final Future<void> removal = worker
          .waitBookIdle(a)
          .then((_) => removalReady = true);
      await Future<void>.delayed(const Duration(milliseconds: 1));
      expect(removalReady, isFalse);
      pending[0].complete();
      await until(() => pending.length == 2);
      await removal;
      expect(removalReady, isTrue);
      expect(read(a, 'status.json')['state'], 'paused');
      pending[1].complete();
      await worker.waitIdle();
      await worker.resumeBook(a);
      await until(() => pending.length == 3);
      expect(read(a, 'work/worker-receipt.json')['request_id'], requestId);
      expect(read(a, 'work/worker-receipt.json')['attempt'], 2);
      expect(read(a, 'work/segment-0000.json'), <String, Object?>{
        'verified': true,
        'sequence': 1,
      });
      pending[2].complete();
      await worker.waitIdle();
      expect(calls, <String>[a.path, b.path, a.path]);
    },
  );

  test(
    'a live external lease is neither reconciled nor cancelled by guessed ownership',
    () async {
      final Directory root = book(
        books,
        'busy',
        meta: <String, Object?>{'auto': true},
        status: <String, Object?>{'state': 'running', 'frontier': 12},
      );
      int calls = 0;
      final Worker worker = Worker(
        books,
        probe: (_) async => true,
        run: (
          Directory root, {
          required RunCancellation cancellation,
          required bool retryQuality,
          required String model,
          required String localModel,
          required int concurrency,
        }) async {
          calls++;
        },
      );
      workers.add(worker);
      await worker.start();
      await worker.processBook(root);
      expect(read(root, 'status.json')['state'], 'running');
      await expectLater(worker.pauseBook(root), throwsA(isA<BusyBook>()));
      expect(read(root, 'status.json')['state'], 'running');
      expect(calls, 0);
    },
  );

  test(
    'reconciliation holds run.lock through its write, closing the probe race',
    () async {
      final Directory root = book(
        books,
        'locked',
        meta: <String, Object?>{'auto': true},
        status: <String, Object?>{'state': 'running', 'frontier': 42},
      );
      RunLease? external;
      final Worker worker = Worker(
        books,
        probe: (Directory root) async {
          external ??= await RunLease.acquire(root);
          return false; // A second process won the lease immediately after a free probe.
        },
      );
      workers.add(worker);
      try {
        await worker.start();
        expect(read(root, 'status.json'), <String, Object?>{
          'state': 'running',
          'frontier': 42,
        });
        expect(worker.health()['current'], isNull);
        expect(
          File('${root.path}/work/worker-receipt.json').existsSync(),
          isFalse,
        );
      } finally {
        external?.release();
      }
    },
  );

  test('settings or launch failure does not terminate the queue', () async {
    final Directory a = book(books, 'a'), b = book(books, 'b');
    int settingsCalls = 0;
    final List<String> calls = <String>[];
    final Worker worker = Worker(
      books,
      probe: free,
      settings: () {
        if (++settingsCalls == 1) throw StateError('fixture settings error');
        return fixtureSettings;
      },
      run: (
        Directory root, {
        required RunCancellation cancellation,
        required bool retryQuality,
        required String model,
        required String localModel,
        required int concurrency,
      }) async {
        calls.add(root.path);
        save(root, 'status.json', <String, Object?>{'state': 'done'});
      },
    );
    workers.add(worker);
    await worker.startBook(a);
    await worker.startBook(b);
    await worker.waitIdle();
    expect(read(a, 'status.json')['state'], 'error');
    expect(read(b, 'status.json')['state'], 'done');
    expect(calls, <String>[b.path]);
    expect(worker.health()['alive'], isTrue);
    expect(worker.health()['current'], isNull);
  });

  test(
    'sequential books own separate judge caches and do not inherit prior counters',
    () async {
      final Directory a = book(books, 'a'), b = book(books, 'b');
      final String? previous = environ['JUDGE_LOG_DIR'];
      final Map<String, num> previousStats = Map<String, num>.of(jev.jevStats);
      final List<String?> directories = <String?>[];
      final List<num?> initialCalls = <num?>[];
      environ['JUDGE_LOG_DIR'] = 'caller-selected-judge-directory';
      jev.jevStats['calls'] = 999;
      final Worker worker = Worker(
        books,
        probe: free,
        settings: () => fixtureSettings,
        run: (
          Directory root, {
          required RunCancellation cancellation,
          required bool retryQuality,
          required String model,
          required String localModel,
          required int concurrency,
        }) async {
          directories.add(environ['JUDGE_LOG_DIR']);
          initialCalls.add(jev.jevStats['calls']);
          jev.jevStats['calls'] = 7;
          save(root, 'status.json', <String, Object?>{'state': 'done'});
        },
      );
      workers.add(worker);
      try {
        await worker.startBook(a);
        await worker.startBook(b);
        await worker.waitIdle();
        expect(directories, <String>[
          '${a.path}/work/judge',
          '${b.path}/work/judge',
        ]);
        expect(initialCalls, <num>[0, 0]);
        expect(environ['JUDGE_LOG_DIR'], 'caller-selected-judge-directory');
      } finally {
        if (previous == null) {
          environ.remove('JUDGE_LOG_DIR');
        } else {
          environ['JUDGE_LOG_DIR'] = previous;
        }
        jev.jevStats
          ..clear()
          ..addAll(previousStats);
      }
    },
  );

  test(
    'explicit stop retains pending work and cannot dispatch the next book',
    () async {
      final Directory a = book(books, 'a'), b = book(books, 'b');
      final Completer<void> started = Completer<void>(),
          release = Completer<void>();
      final List<String> calls = <String>[];
      final Worker worker = Worker(
        books,
        probe: free,
        run: (
          Directory root, {
          required RunCancellation cancellation,
          required bool retryQuality,
          required String model,
          required String localModel,
          required int concurrency,
        }) async {
          calls.add(root.path);
          started.complete();
          await release.future;
          cancellation.check();
        },
      );
      workers.add(worker);
      await worker.startBook(a);
      await started.future;
      await worker.startBook(b);
      worker.stop();
      release.complete();
      await worker.waitIdle();
      expect(calls, <String>[a.path]);
      expect(read(a, 'status.json')['state'], 'queued');
      expect(read(a, 'meta.json')['auto'], isTrue);
      expect(read(b, 'status.json')['state'], 'queued');
      expect(worker.health()['alive'], isFalse);
    },
  );
}
