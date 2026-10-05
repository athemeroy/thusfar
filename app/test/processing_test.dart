import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/model_settings.dart';
import 'package:thusfar_app/data/processing.dart';
import 'package:thusfar_app/data/processing_background_session.dart';
import 'package:thusfar_app/main.dart';
import 'package:thusfar_app/sheets/book_sheet.dart';
import 'package:thusfar_app/ui/theme.dart';

import 'support/viewport.dart';
import 'package:thusfar_core/jobs.dart' show AlreadyRunning, RunLease;

class FixtureProcessing extends BookProcessing {
  FixtureProcessing(this.library);

  final Library library;
  int initializations = 0;
  int starts = 0;
  Json? lastPlan;
  int pauses = 0;
  int removals = 0;
  int closes = 0;
  Completer<void>? pauseGate;
  Completer<void>? removalGate;
  Object? startError;
  Map<String, Object?> runtimeHealth = const <String, Object?>{};
  @override
  Map<String, Object?> get health => runtimeHealth;

  void status(BookEntry book, Json state) {
    writeJson(File('${book.dir.path}/status.json'), state);
    library.refreshStatus(book);
    notifyListeners();
  }

  @override
  Future<void> initialize() async => initializations++;

  @override
  Future<void> startBook(BookEntry book) async {
    starts++;
    if (startError != null) throw startError!;
    status(book, <String, Object?>{'state': 'running', 'done': 0, 'total': 2});
  }

  @override
  Future<void> startBookWithPlan(BookEntry book, Json plan) async {
    lastPlan = plan;
    await startBook(book);
  }

  @override
  Future<void> pauseBook(BookEntry book) async {
    pauses++;
    status(book, <String, Object?>{
      'state': 'cancelling',
      'done': 1,
      'total': 2,
    });
    await pauseGate?.future;
    status(book, <String, Object?>{'state': 'paused', 'done': 1, 'total': 2});
  }

  @override
  Future<void> pauseBookUntilIdle(BookEntry book) => pauseBook(book);

  @override
  Future<void> prepareRemoval(BookEntry book) async {
    removals++;
    status(book, <String, Object?>{'state': 'cancelling'});
    await removalGate?.future;
    status(book, <String, Object?>{'state': 'paused'});
  }

  @override
  Future<void> close() async => closes++;
}

Json fixtureBook() => <String, Object?>{
  'title': 'Fixture',
  'author': 'Writer',
  'len': 40,
  'lang': 'en',
  'notes': <String, Object?>{},
  'blocks': <Json>[
    <String, Object?>{
      'k': 'p',
      't': 'Alice came. Bob came. End of the chapter.',
      'o': 0,
    },
  ],
  'chapters': <Json>[
    <String, Object?>{
      'title': 'One',
      'b0': 0,
      'b1': 1,
      'o0': 0,
      'o1': 40,
      'kind': 'body',
    },
  ],
};

Json person(String id, String name, int position) => <String, Object?>{
  't': 'person',
  'id': id,
  'name': name,
  'p': position,
};

void main() {
  late Directory root;
  late Directory bookRoot;
  late Library library;
  late BookEntry entry;
  late FixtureProcessing processing;
  late ModelSettings settings;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('thusfar-processing-ui-');
    bookRoot = Directory('${root.path}/books/fixture')
      ..createSync(recursive: true);
    writeJson(File('${bookRoot.path}/book.json'), fixtureBook());
    writeJson(File('${bookRoot.path}/meta.json'), <String, Object?>{
      'auto': false,
    });
    writeJson(File('${bookRoot.path}/status.json'), <String, Object?>{
      'state': 'idle',
    });
    library = Library(root);
    await library.scan();
    entry = library.books.single;
    processing = FixtureProcessing(library);
    settings = ModelSettings(File('${root.path}/.model.env'));
  });

  tearDown(() {
    processing.dispose();
    library.dispose();
    root.deleteSync(recursive: true);
  });

  void configure() {
    expect(
      settings.save(
        url: 'https://example.invalid/v1',
        model: 'fixture',
        key: 'test-only-placeholder',
      ),
      isNull,
    );
  }

  Future<void> open(
    WidgetTester tester, {
    VoidCallback? onRemoved,
    bool settle = true,
  }) async {
    await setTestViewport(tester, const Size(430, 1000));
    addTearDown(() => setTestViewport(tester, null));
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => BookSheet.open(
                context,
                BookSheet(
                  library: library,
                  entry: entry,
                  settings: settings,
                  processing: processing,
                  onRead: () {},
                  onNotes: () {},
                  onModelSettings: () async {},
                  onExport: () async {},
                  onRemoved: onRemoved,
                  focusProcessing: true,
                ),
              ),
              child: const Text('Open fixture'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open fixture'));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }
  }

  test('AppModel defers worker startup until explicit initialize', () async {
    late FixtureProcessing fake;
    final AppModel model = AppModel(
      root,
      createProcessing: (Library value) => fake = FixtureProcessing(value),
    );
    expect(fake.initializations, 0);
    expect(fake.starts, 0);
    await model.initialize();
    expect(fake.initializations, 1);
    expect(fake.starts, 0);
    expect(model.library.books, hasLength(1));
    model.dispose();
  });

  test('real worker isolate leaves explicitly disabled work paused', () async {
    writeJson(File('${bookRoot.path}/meta.json'), <String, Object?>{
      'auto': false,
    });
    writeJson(File('${bookRoot.path}/status.json'), <String, Object?>{
      'state': 'running',
      'done': 1,
      'total': 2,
    });
    final ProcessingController actual = ProcessingController(library);
    try {
      await actual.initialize().timeout(const Duration(seconds: 10));
      expect(entry.status.state, 'paused');
      await expectLater(actual.startBook(entry), throwsA(isA<Exception>()));
      expect(entry.status.state, 'paused');
      expect(
        File('${bookRoot.path}/work/worker-receipt.json').existsSync(),
        isTrue,
      );
    } finally {
      await actual.close().timeout(const Duration(seconds: 10));
      actual.dispose();
    }
  });

  for (final bool pauseBeforeReady in <bool>[false, true]) {
    test(
      'real isolate makes no model requests before native readiness '
      '(${pauseBeforeReady ? 'user pause before acknowledgement' : 'native start failure'})',
      () async {
        // The configured model route is a loopback HTTP server. No fixture
        // contains credentials that could authorize a paid model request.
        final HttpServer server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        int modelRequests = 0;
        server.listen((HttpRequest request) async {
          modelRequests++;
          request.response.statusCode = HttpStatus.serviceUnavailable;
          request.response.write(
            'Offline fixture: model work is not permitted',
          );
          await request.response.close();
        });
        final Completer<bool> nativeReady = Completer<bool>();
        final Completer<void> nativeRequested = Completer<void>();
        final List<String> stops = <String>[];
        final ProcessingBackgroundSession background =
            ProcessingBackgroundSession(
              start: (BookEntry book, String phase) {
                expect(book.id, entry.id);
                expect(phase, 'preparing');
                if (!nativeRequested.isCompleted) nativeRequested.complete();
                return nativeReady.future;
              },
              update: (_, _) async => true,
              stop: (String id) async {
                stops.add(id);
              },
              onUnavailable: (_) async {},
            );
        final ProcessingController actual = ProcessingController(
          library,
          background: background,
        );
        try {
          expect(
            settings.save(
              url: 'http://127.0.0.1:${server.port}/v1',
              model: 'offline-fixture',
              key: 'offline-placeholder-not-a-real-key',
            ),
            isNull,
          );
          writeJson(File('${bookRoot.path}/status.json'), <String, Object?>{
            'state': 'paused',
            'done': 1,
            'total': 2,
            'frontier': 17,
          });
          library.refreshStatus(entry);
          await actual.initialize().timeout(const Duration(seconds: 10));
          await actual.startBook(entry).timeout(const Duration(seconds: 10));
          await nativeRequested.future.timeout(const Duration(seconds: 10));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(modelRequests, 0);
          expect(entry.status.done, 1);
          expect(entry.status.frontier, 17);
          expect(actual.health['current'], entry.id);

          if (pauseBeforeReady) {
            await actual
                .pauseBookUntilIdle(entry)
                .timeout(const Duration(seconds: 10));
            nativeReady.complete(true);
          } else {
            nativeReady.completeError(
              StateError('native foreground service failed'),
            );
          }
          final DateTime deadline = DateTime.now().add(
            const Duration(seconds: 10),
          );
          while (actual.health['current'] != null &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
          library.refreshStatus(entry);
          expect(actual.health['current'], isNull);
          expect(modelRequests, 0);
          expect(stops, contains(entry.id));
          expect(entry.status.isActive, isFalse);
          expect(entry.status.done, 1);
          expect(entry.status.frontier, 17);
          if (pauseBeforeReady) {
            expect(entry.status.state, 'paused');
            expect(entry.status.raw['pause_reason'], 'user');
            expect(
              (readJson(File('${bookRoot.path}/meta.json')) as Json)['auto'],
              false,
            );
          }
        } finally {
          if (!nativeReady.isCompleted) {
            nativeReady.completeError(StateError('fixture cleanup'));
          }
          await actual.close().timeout(const Duration(seconds: 10));
          actual.dispose();
          await server.close(force: true);
        }
      },
    );
  }

  test(
    'dead worker pauses unowned manual work without replacing its receipt',
    () async {
      final File status = File('${bookRoot.path}/status.json');
      final File receipt = File('${bookRoot.path}/work/worker-receipt.json');
      writeJson(status, <String, Object?>{
        'state': 'running',
        'done': 3,
        'total': 603,
        'frontier': 9042,
      });
      writeJson(receipt, <String, Object?>{
        'request_id': 'original-request',
        'phase': 'running',
      });
      library.refreshStatus(entry);
      await reconcileStoppedWorker(library, '整理任务意外停止');
      expect(
        entry.status.state,
        'running',
      ); // disk changes are refreshed by the controller
      library.refreshStatus(entry);
      expect(entry.status.state, 'paused');
      expect(entry.status.done, 3);
      expect(entry.status.frontier, 9042);
      expect(entry.status.raw['pause_reason'], 'interrupted');
      expect((readJson(receipt) as Json)['request_id'], 'original-request');
      expect(File('${bookRoot.path}/work/activity.json').existsSync(), isTrue);
    },
  );

  test(
    'dead worker keeps authorized work queued for the next startup',
    () async {
      final File status = File('${bookRoot.path}/status.json');
      final File receipt = File('${bookRoot.path}/work/worker-receipt.json');
      writeJson(File('${bookRoot.path}/meta.json'), <String, Object?>{
        'auto': true,
      });
      writeJson(status, <String, Object?>{
        'state': 'running',
        'done': 10,
        'total': 603,
        'frontier': 9042,
      });
      writeJson(receipt, <String, Object?>{
        'request_id': 'original-request',
        'phase': 'running',
      });
      library.refreshStatus(entry);

      await reconcileStoppedWorker(library, '整理任务意外停止');

      final Json saved = readJson(status)! as Json;
      expect(saved['state'], 'queued');
      expect(saved['done'], 10);
      expect(saved['frontier'], 9042);
      expect(saved['error'], isNull);
      expect(saved['notice'], '整理任务意外停止');
      expect((readJson(receipt) as Json)['request_id'], 'original-request');
      expect(
        (readJson(File('${bookRoot.path}/meta.json')) as Json)['auto'],
        true,
      );
      expect(
        File('${bookRoot.path}/work/activity.json').readAsStringSync(),
        contains('重新打开应用后自动继续'),
      );
    },
  );

  for (final String journalKind in <String>[
    'inflight',
    'received',
    'invalid',
  ]) {
    test(
      'dead worker fails closed for $journalKind request evidence',
      () async {
        final File status = File('${bookRoot.path}/status.json');
        final File meta = File('${bookRoot.path}/meta.json');
        final File journal = File(
          '${bookRoot.path}/work/model-request-journal.json',
        );
        writeJson(meta, <String, Object?>{'auto': true});
        writeJson(status, <String, Object?>{
          'state': 'running',
          'done': 10,
          'total': 603,
          'frontier': 9042,
          'retryable': true,
          'retry_at': 1780000000,
        });
        journal.parent.createSync(recursive: true);
        if (journalKind == 'invalid') {
          journal.writeAsStringSync('{"version":1,"requests":');
        } else {
          writeJson(journal, <String, Object?>{
            'version': 1,
            'requests': <Json>[
              <String, Object?>{'id': 1, 'phase': journalKind},
            ],
          });
        }
        final String originalJournal = journal.readAsStringSync();
        library.refreshStatus(entry);

        await reconcileStoppedWorker(library, '整理任务意外停止');

        final Json saved = readJson(status)! as Json;
        expect(saved['state'], 'paused');
        expect(saved['pause_reason'], 'request_outcome_unknown');
        expect(saved['request_outcome'], 'unknown');
        expect(saved['retryable'], false);
        expect(saved.containsKey('retry_at'), false);
        expect(saved['done'], 10);
        expect(saved['total'], 603);
        expect(saved['frontier'], 9042);
        expect((readJson(meta) as Json)['auto'], false);
        expect(journal.readAsStringSync(), originalJournal);
        expect(
          File('${bookRoot.path}/work/activity.json').readAsStringSync(),
          contains('上次模型请求结果未确认'),
        );
      },
    );
  }

  test('dead worker respects an already recorded user pause', () async {
    final File status = File('${bookRoot.path}/status.json');
    writeJson(File('${bookRoot.path}/meta.json'), <String, Object?>{
      'auto': true,
    });
    writeJson(status, <String, Object?>{
      'state': 'cancelling',
      'pause_reason': 'user',
      'done': 10,
    });
    library.refreshStatus(entry);

    await reconcileStoppedWorker(library, 'worker stopped');

    expect((readJson(status) as Json)['state'], 'paused');
    expect((readJson(status) as Json)['pause_reason'], 'user');
    expect(
      (readJson(File('${bookRoot.path}/meta.json')) as Json)['auto'],
      false,
    );
  });

  test('dead worker does not overwrite an active independent lease', () async {
    final File status = File('${bookRoot.path}/status.json');
    writeJson(status, <String, Object?>{'state': 'running', 'done': 1});
    library.refreshStatus(entry);
    final RunLease lease = await RunLease.acquire(bookRoot);
    try {
      await reconcileStoppedWorker(library, 'worker stopped');
      expect((readJson(status) as Json)['state'], 'running');
    } finally {
      lease.release();
    }
  });

  testWidgets(
    'start is explicit, progress updates, pause settles, and resume works',
    (WidgetTester tester) async {
      configure();
      await open(tester);
      expect(processing.starts, 0);
      await tester.tap(find.text('开始整理'));
      await tester.pump();
      expect(processing.starts, 0);
      expect(find.textContaining('会调用你的模型接口'), findsOneWidget);
      await tester.tap(find.text('开始'));
      await tester.pump();
      expect(processing.starts, 1);
      expect(find.text('已整理 0 / 2 段'), findsOneWidget);
      processing.status(entry, <String, Object?>{
        'state': 'running',
        'done': 1,
        'total': 2,
      });
      await tester.pump();
      expect(find.text('已整理 1 / 2 段'), findsOneWidget);
      processing.pauseGate = Completer<void>();
      await tester.tap(find.text('暂停整理'));
      await tester.pump();
      expect(processing.pauses, 1);
      expect(find.textContaining('已经整理好的内容会保留'), findsOneWidget);
      expect(find.text('继续整理'), findsNothing);
      processing.pauseGate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('继续整理'), findsOneWidget);
      await tester.tap(find.text('继续整理'));
      await tester.pump();
      expect(processing.starts, 2);
      expect(tester.takeException(), isNull);
    },
  );

  for (final bool journalOnly in <bool>[false, true]) {
    for (final String decision in <String>['cancel', 'confirm', 'dismiss']) {
      testWidgets(
        'unknown request resume requires explicit confirmation '
        '(${journalOnly ? 'journal without pause marker' : 'unknown pause marker'}, $decision)',
        (WidgetTester tester) async {
          configure();
          processing.status(entry, <String, Object?>{
            'state': 'paused',
            'done': 1,
            'total': 2,
            'frontier': 17,
            'pause_reason': journalOnly
                ? 'interrupted'
                : 'request_outcome_unknown',
          });
          final File journal = File(
            '${bookRoot.path}/work/model-request-journal.json',
          );
          if (journalOnly) {
            writeJson(journal, <String, Object?>{
              'version': 1,
              'requests': <Json>[
                <String, Object?>{'id': 1, 'phase': 'inflight'},
              ],
            });
          }
          String? readJournal() =>
              journal.existsSync() ? journal.readAsStringSync() : null;
          final String? originalJournal = readJournal();
          final String originalStatus = File(
            '${bookRoot.path}/status.json',
          ).readAsStringSync();
          await open(tester);
          await tester.tap(find.text('继续整理'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(processing.starts, 0);
          expect(find.text('上次模型请求结果未确认'), findsOneWidget);
          expect(find.textContaining('服务器可能已经处理并计费'), findsOneWidget);
          expect(find.textContaining('可能再次产生模型费用'), findsOneWidget);
          expect(readJournal(), originalJournal);

          if (decision == 'confirm') {
            await tester.tap(find.text('确认继续'));
          } else if (decision == 'cancel') {
            await tester.tap(find.text('暂不继续'));
          } else {
            await tester.binding.handlePopRoute();
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.text('上次模型请求结果未确认'), findsNothing);
          expect(processing.starts, decision == 'confirm' ? 1 : 0);
          if (decision != 'confirm') {
            expect(readJournal(), originalJournal);
            expect(
              File('${bookRoot.path}/status.json').readAsStringSync(),
              originalStatus,
            );
            expect(entry.status.done, 1);
            expect(entry.status.frontier, 17);
            expect(find.text('继续整理'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  test(
    'background-limit pause forwards to legacy processing implementations',
    () async {
      processing.status(entry, <String, Object?>{'state': 'running'});
      await processing.pauseForBackgroundLimit(entry);
      expect(processing.pauses, 1);
      expect(entry.status.state, 'paused');
    },
  );

  testWidgets(
    'foreground resumes a background-limit pause after late settlement',
    (WidgetTester tester) async {
      configure();
      late FixtureProcessing appProcessing;
      final AppModel model = AppModel(
        root,
        createProcessing: (Library value) =>
            appProcessing = FixtureProcessing(value),
      );
      model.prefs.update(
        (p) => p.updateCheckedAt = DateTime.now().millisecondsSinceEpoch,
      );
      await model.initialize();
      final BookEntry appBook = model.library.books.single;
      appProcessing.status(appBook, <String, Object?>{
        'state': 'cancelling',
        'pause_reason': 'background_time_limit',
      });
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(appProcessing.starts, 0);

      appProcessing.status(appBook, <String, Object?>{
        'state': 'paused',
        'pause_reason': 'background_time_limit',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(appProcessing.starts, 1);
      expect(appBook.status.state, 'running');

      await tester.pumpWidget(const SizedBox());
      model.dispose();
    },
  );

  for (final String reason in <String>[
    'background_time_limit',
    'background_unavailable',
  ]) {
    testWidgets(
      'foreground does not silently resume $reason with unsettled request evidence',
      (WidgetTester tester) async {
        configure();
        late FixtureProcessing appProcessing;
        final AppModel model = AppModel(
          root,
          createProcessing: (Library value) =>
              appProcessing = FixtureProcessing(value),
        );
        model.prefs.update(
          (p) => p.updateCheckedAt = DateTime.now().millisecondsSinceEpoch,
        );
        await model.initialize();
        final BookEntry appBook = model.library.books.single;
        appProcessing.status(appBook, <String, Object?>{
          'state': 'paused',
          'pause_reason': reason,
          'done': 1,
          'total': 2,
          'frontier': 17,
        });
        final File journal = File(
          '${appBook.dir.path}/work/model-request-journal.json',
        );
        writeJson(journal, <String, Object?>{
          'version': 1,
          'requests': <Json>[
            <String, Object?>{'id': 1, 'phase': 'inflight'},
          ],
        });
        final String evidence = journal.readAsStringSync();
        try {
          await tester.pumpWidget(ThusfarApp(model: model));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 20));
          expect(appProcessing.starts, 0);
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          await tester.pump();
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 20));
          expect(appProcessing.starts, 0);
          expect(appBook.status.done, 1);
          expect(appBook.status.frontier, 17);
          expect(journal.readAsStringSync(), evidence);
        } finally {
          await tester.pumpWidget(const SizedBox());
          model.dispose();
        }
      },
    );
  }

  testWidgets(
    'HomeShell hidden paused and detached lifecycle does not cancel processing',
    (WidgetTester tester) async {
      configure();
      late FixtureProcessing appProcessing;
      final AppModel model = AppModel(
        root,
        createProcessing: (Library value) =>
            appProcessing = FixtureProcessing(value),
      );
      model.prefs.update(
        (p) => p.updateCheckedAt = DateTime.now().millisecondsSinceEpoch,
      );
      await model.initialize();
      final BookEntry appBook = model.library.books.single;
      appProcessing.status(appBook, <String, Object?>{
        'state': 'running',
        'done': 3,
        'total': 10,
        'frontier': 9042,
      });
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pump();
      try {
        for (final AppLifecycleState state in <AppLifecycleState>[
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
          AppLifecycleState.detached,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
          await tester.pump();
          expect(
            appProcessing.pauses,
            0,
            reason: '$state must not pause the worker',
          );
          expect(
            appProcessing.closes,
            0,
            reason: '$state must not close the worker',
          );
          expect(
            appProcessing.starts,
            0,
            reason: '$state must not duplicate a run',
          );
          expect(appBook.status.state, 'running');
          expect(appBook.status.done, 3);
          expect(appBook.status.frontier, 9042);
        }
        await tester.pumpWidget(const SizedBox());
        expect(
          appProcessing.closes,
          0,
          reason: 'disposing a screen does not own worker lifetime',
        );
        expect(appProcessing.pauses, 0);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      }
    },
  );

  testWidgets(
    'background completion survives detached screen recreation and library reload',
    (WidgetTester tester) async {
      configure();
      late FixtureProcessing appProcessing;
      final AppModel model = AppModel(
        root,
        createProcessing: (Library value) =>
            appProcessing = FixtureProcessing(value),
      );
      model.prefs.update(
        (p) => p.updateCheckedAt = DateTime.now().millisecondsSinceEpoch,
      );
      await model.initialize();
      final BookEntry appBook = model.library.books.single;
      appProcessing.status(appBook, <String, Object?>{
        'state': 'running',
        'done': 3,
        'total': 10,
        'frontier': 9042,
      });
      await tester.pumpWidget(ThusfarApp(model: model));
      await tester.pump();
      try {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        await tester.pump();
        appProcessing.status(appBook, <String, Object?>{
          'state': 'done',
          'done': 10,
          'total': 10,
          'frontier': 20000,
        });
        final String durable = File(
          '${appBook.dir.path}/status.json',
        ).readAsStringSync();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.detached,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(ThusfarApp(model: model));
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
        await model.library.scan();
        final BookEntry reloaded = model.library.books.single;
        expect(reloaded.status.state, 'done');
        expect(reloaded.status.done, 10);
        expect(reloaded.status.total, 10);
        expect(reloaded.status.frontier, 20000);
        expect(
          File('${appBook.dir.path}/status.json').readAsStringSync(),
          durable,
        );
        expect(appProcessing.pauses, 0);
        expect(appProcessing.closes, 0);
        expect(appProcessing.starts, 0);
      } finally {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpWidget(const SizedBox());
        model.dispose();
      }
    },
  );

  testWidgets('preflight and model wait remain visible before first segment', (
    WidgetTester tester,
  ) async {
    configure();
    processing.runtimeHealth = <String, Object?>{
      'alive': true,
      'current': entry.id,
      'queued': const <String>[],
    };
    writeJson(File('${bookRoot.path}/work/activity.json'), <Object?>[
      <String, Object?>{
        'at': DateTime.now().millisecondsSinceEpoch / 1000 - 70,
        'phase': 'running',
        'message': '正在检查书籍和整理缓存',
      },
    ]);
    processing.status(entry, <String, Object?>{
      'state': 'queued',
      'done': 0,
      'total': 0,
    });
    await open(tester, settle: false);
    expect(find.text('正在准备整理'), findsOneWidget);
    expect(find.textContaining('正在检查书籍和整理缓存'), findsWidgets);
    expect(find.textContaining('准备 · 正在检查书籍和整理缓存'), findsOneWidget);
    expect(find.textContaining('已等待 1 分'), findsNothing);
    expect(find.text('整理记录'), findsOneWidget);

    final double waitingSince =
        DateTime.now().millisecondsSinceEpoch / 1000 - 70;
    writeJson(File('${bookRoot.path}/work/activity.json'), <Object?>[
      <String, Object?>{
        'at': waitingSince,
        'started_at': waitingSince,
        'phase': 'stage_heartbeat',
        'stage': 'extract',
        'segment': 1,
        'message': '第 1 段正文抽取仍在等待模型',
      },
    ]);
    processing.status(entry, <String, Object?>{
      'state': 'running',
      'done': 0,
      'total': 603,
      'notice': '已发送 4 段，正在等待模型回复',
    });
    await tester.pump();
    expect(find.text('已整理 0 / 603 段'), findsOneWidget);
    expect(find.text('已发送 4 段，正在等待模型回复'), findsOneWidget);
    expect(find.textContaining('已等待 1 分'), findsOneWidget);

    writeJson(File('${bookRoot.path}/work/activity.json'), <Object?>[
      <String, Object?>{
        'at': DateTime.now().millisecondsSinceEpoch / 1000,
        'phase': 'running',
        'message': '已完成 9 / 603 段',
        'done': 9,
        'total': 603,
      },
    ]);
    processing.status(entry, <String, Object?>{
      'state': 'running',
      'done': 9,
      'total': 603,
    });
    await tester.pump();
    expect(find.textContaining('正文 · 已完成 9 / 603 段'), findsOneWidget);
  });

  testWidgets('paused card names the unfinished segment and last stage', (
    WidgetTester tester,
  ) async {
    writeJson(File('${bookRoot.path}/work/activity.json'), <Object?>[
      <String, Object?>{
        'at': 1780000000,
        'phase': 'stage_heartbeat',
        'message': 'not used by the paused summary',
        'done': 10,
        'total': 603,
        'segment': 11,
        'stage': 'relation',
        'started_at': 1779999940,
      },
      <String, Object?>{
        'at': 1780000060,
        'phase': 'paused',
        'message': '整理已暂停',
      },
    ]);
    processing.status(entry, <String, Object?>{
      'state': 'paused',
      'done': 10,
      'total': 603,
      'pause_reason': 'interrupted',
      'updated': 1780000060,
    });
    await open(tester);
    expect(find.text('下一段：第 11 / 603 段，尚未完成。'), findsOneWidget);
    expect(find.textContaining('上次整理中断后已暂停'), findsOneWidget);
    expect(find.textContaining('第 11 段 · 人物关联已等待'), findsWidgets);
    await tester.scrollUntilVisible(
      find.text('导出整理诊断'),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('导出整理诊断').hitTestable(), findsOneWidget);
  });

  testWidgets('automatic retry can be stopped from the book card', (
    WidgetTester tester,
  ) async {
    writeJson(File('${bookRoot.path}/meta.json'), <String, Object?>{
      'auto': true,
    });
    processing.runtimeHealth = <String, Object?>{
      'alive': true,
      'current': null,
      'queued': const <String>[],
    };
    processing.status(entry, <String, Object?>{
      'state': 'error',
      'done': 10,
      'total': 603,
      'error': '模型连接超时',
      'retryable': true,
      'retry_at': DateTime.now().millisecondsSinceEpoch / 1000 + 600,
    });
    await open(tester);
    expect(find.text('模型请求遇到问题，等待自动重试'), findsOneWidget);
    expect(find.textContaining('自动重试；已经整理好的部分会保留'), findsOneWidget);
    await tester.tap(find.text('停止自动重试'));
    await tester.pumpAndSettle();
    expect(processing.pauses, 1);
    expect(find.text('继续整理'), findsOneWidget);
  });

  testWidgets(
    'classifier 403 offers a one-book model route and a pause-to-disable action',
    (WidgetTester tester) async {
      configure();
      processing.status(entry, <String, Object?>{
        'state': 'error',
        'done': 16,
        'total': 603,
        'error':
            '章节摘要验证失败：免费裁判暂不可用，未调用付费接口：LLMError: classifier.dev HTTP 403: {"code":"proxy_requires_payment"}',
        'retryable': false,
      });
      await open(tester);
      expect(find.textContaining('上次匿名判断请求被拒绝'), findsOneWidget);
      expect(find.textContaining('proxy_requires_payment'), findsNothing);
      expect(settings.judgeFallbackEnabled, false);
      await tester.ensureVisible(find.text('用已配置模型继续整理'));
      await tester.tap(find.text('用已配置模型继续整理'));
      await tester.pumpAndSettle();
      expect(processing.starts, 1);
      expect(
        settings.judgeFallbackEnabled,
        false,
        reason: 'one-book consent must not alter global settings',
      );
      expect(
        (readJson(File('${bookRoot.path}/meta.json'))
            as Json)['judge_fallback_route'],
        'model',
      );
      final Directory anotherBook = Directory('${root.path}/books/another')
        ..createSync();
      writeJson(File('${anotherBook.path}/meta.json'), <String, Object?>{
        'auto': false,
      });
      expect(
        (readJson(File('${anotherBook.path}/meta.json')) as Json).containsKey(
          'judge_fallback_route',
        ),
        false,
      );
      expect(find.textContaining('判断路线：免费优先'), findsOneWidget);
      await tester.ensureVisible(find.text('暂停并停用本书判断兜底'));
      await tester.tap(find.text('暂停并停用本书判断兜底'));
      await tester.pumpAndSettle();
      expect(processing.pauses, 1);
      expect(
        (readJson(File('${bookRoot.path}/meta.json')) as Json).containsKey(
          'judge_fallback_route',
        ),
        false,
      );
    },
  );

  testWidgets('Jev gateway consent and allowance stay on one book', (
    WidgetTester tester,
  ) async {
    configure();
    settings.save(
      url: 'https://example.invalid/v1',
      model: 'fixture',
      jevApiKey: 'offline-jev-fixture-key',
    );
    processing.status(entry, <String, Object?>{
      'state': 'error',
      'done': 16,
      'total': 603,
      'error': 'classifier.dev HTTP 403: 匿名免费额度不可用',
    });
    await open(tester);
    expect(settings.judgeFallbackEnabled, false);
    await tester.ensureVisible(find.text('用 Jev 网关继续整理'));
    await tester.tap(find.text('用 Jev 网关继续整理'));
    await tester.pumpAndSettle();
    expect(processing.starts, 1);
    expect(settings.judgeFallbackEnabled, false);
    final Json meta = readJson(File('${bookRoot.path}/meta.json')) as Json;
    expect(meta['judge_fallback_route'], 'jev');
    expect(meta.containsKey('judge_model_fallback'), false);
    expect(find.textContaining('判断路线：免费优先，失败后使用 Jev 网关'), findsOneWidget);
    expect(find.textContaining('本书 Jev 网关额度：0/1000 次'), findsOneWidget);
    processing.pauseGate = Completer<void>();
    await tester.ensureVisible(find.text('暂停并停用本书判断兜底'));
    await tester.tap(find.text('暂停并停用本书判断兜底'));
    await tester.pump();
    expect(
      (readJson(File('${bookRoot.path}/meta.json'))
          as Json)['judge_fallback_route'],
      'jev',
      reason: 'paid consent stays recorded until the active request settles',
    );
    processing.pauseGate!.complete();
    await tester.pumpAndSettle();
    expect(processing.pauses, 1);
    expect(
      (readJson(File('${bookRoot.path}/meta.json')) as Json).containsKey(
        'judge_fallback_route',
      ),
      false,
    );
  });

  testWidgets('bio rejection offers direct model recheck for this book', (
    WidgetTester tester,
  ) async {
    configure();
    processing.status(entry, <String, Object?>{
      'state': 'error',
      'done': 9,
      'total': 603,
      'error': '第 2 章人物小传通过 0/2 位（拦截 2，缺失 0），已保留模型草稿',
    });
    await open(tester);
    await tester.ensureVisible(find.text('本书用已配置模型直接核对'));
    await tester.tap(find.text('本书用已配置模型直接核对'));
    await tester.pumpAndSettle();
    expect(processing.starts, 1);
    expect(
      (readJson(File('${bookRoot.path}/meta.json'))
          as Json)['judge_fallback_route'],
      'model-direct',
    );
    expect(find.textContaining('判断路线：直接使用'), findsOneWidget);
  });

  testWidgets('bio rejection offers direct Jev recheck for this book', (
    WidgetTester tester,
  ) async {
    configure();
    settings.save(
      url: 'https://example.invalid/v1',
      model: 'fixture',
      jevApiKey: 'offline-jev-fixture-key',
    );
    processing.status(entry, <String, Object?>{
      'state': 'error',
      'done': 9,
      'total': 603,
      'error': '第 2 章人物小传通过 0/2 位（拦截 2，缺失 0），已保留模型草稿',
    });
    await open(tester);
    await tester.ensureVisible(find.text('本书用 Jev 网关直接核对'));
    await tester.tap(find.text('本书用 Jev 网关直接核对'));
    await tester.pumpAndSettle();
    expect(processing.starts, 1);
    expect(
      (readJson(File('${bookRoot.path}/meta.json'))
          as Json)['judge_fallback_route'],
      'jev-direct',
    );
    expect(find.textContaining('判断路线：直接使用 Jev 网关'), findsOneWidget);
  });

  testWidgets('completed book can recheck a deferred biography with Jev', (
    WidgetTester tester,
  ) async {
    configure();
    settings.save(
      url: 'https://example.invalid/v1',
      model: 'fixture',
      jevApiKey: 'offline-jev-fixture-key',
    );
    processing.status(entry, <String, Object?>{
      'state': 'done',
      'done': 603,
      'total': 603,
      'quality': <String, Object?>{
        'state': 'pending',
        'pending': <String>['bio-1'],
      },
    });
    Directory('${bookRoot.path}/work/jobs').createSync(recursive: true);
    writeJson(File('${bookRoot.path}/work/jobs/bio-1.json'), <String, Object?>{
      'kind': 'bio',
      'state': 'deferred',
      'bio_review': <String, Object?>{'blocked': 2},
    });
    await open(tester);
    expect(find.text('重试待核对部分'), findsOneWidget);
    await tester.ensureVisible(find.text('本书用 Jev 网关直接核对'));
    await tester.tap(find.text('本书用 Jev 网关直接核对'));
    await tester.pumpAndSettle();
    expect(processing.starts, 1);
    expect(
      (readJson(File('${bookRoot.path}/meta.json'))
          as Json)['judge_fallback_route'],
      'jev-direct',
    );
  });

  testWidgets('invalid model biography check offers official Jev route', (
    WidgetTester tester,
  ) async {
    configure();
    settings.save(
      url: 'https://example.invalid/v1',
      model: 'fixture',
      jevApiKey: 'offline-jev-fixture-key',
    );
    final Json meta = readJson(File('${bookRoot.path}/meta.json')) as Json;
    meta['judge_fallback_route'] = 'model-direct';
    writeJson(File('${bookRoot.path}/meta.json'), meta);
    processing.status(entry, <String, Object?>{
      'state': 'error',
      'done': 9,
      'total': 603,
      'error': '人物小传验证失败：已配置模型的判断回答不完整或概率无效',
    });
    await open(tester);
    await tester.ensureVisible(find.text('本书用 Jev 网关直接核对'));
    await tester.tap(find.text('本书用 Jev 网关直接核对'));
    await tester.pumpAndSettle();
    expect(processing.starts, 1);
    expect(
      (readJson(File('${bookRoot.path}/meta.json'))
          as Json)['judge_fallback_route'],
      'jev-direct',
    );
  });

  testWidgets('Jev 401 explains the key and switches this book to model', (
    WidgetTester tester,
  ) async {
    configure();
    final Json meta = readJson(File('${bookRoot.path}/meta.json')) as Json;
    meta['judge_fallback_route'] = 'jev-direct';
    writeJson(File('${bookRoot.path}/meta.json'), meta);
    processing.status(entry, <String, Object?>{
      'state': 'error',
      'done': 9,
      'total': 603,
      'error':
          '人物小传验证失败：Jev HTTP 401: {"error":{"message":"Authentication failed"}}',
    });
    await open(tester);
    expect(find.textContaining('TypeSafe AI 拒绝了已保存的 Jev 密钥'), findsOneWidget);
    expect(find.textContaining('Authentication failed'), findsNothing);
    await tester.ensureVisible(find.text('本书改用已配置模型直接核对'));
    await tester.tap(find.text('本书改用已配置模型直接核对'));
    await tester.pumpAndSettle();
    expect(processing.starts, 1);
    expect(
      (readJson(File('${bookRoot.path}/meta.json'))
          as Json)['judge_fallback_route'],
      'model-direct',
    );
  });

  testWidgets('paid route stays recorded until idle when UI status is stale', (
    WidgetTester tester,
  ) async {
    configure();
    final Json meta = readJson(File('${bookRoot.path}/meta.json')) as Json;
    meta['judge_fallback_route'] = 'jev';
    writeJson(File('${bookRoot.path}/meta.json'), meta);
    processing.status(entry, <String, Object?>{
      'state': 'error',
      'done': 16,
      'total': 603,
      'error': '模型请求状态尚未刷新',
    });
    processing.pauseGate = Completer<void>();
    await open(tester);
    await tester.ensureVisible(find.text('停用本书判断兜底'));
    await tester.tap(find.text('停用本书判断兜底'));
    await tester.pump();
    expect(
      processing.pauses,
      1,
      reason: 'the UI must ask the worker even if its status looks inactive',
    );
    expect(
      (readJson(File('${bookRoot.path}/meta.json'))
          as Json)['judge_fallback_route'],
      'jev',
    );
    processing.pauseGate!.complete();
    await tester.pumpAndSettle();
    expect(
      (readJson(File('${bookRoot.path}/meta.json')) as Json).containsKey(
        'judge_fallback_route',
      ),
      false,
    );
  });

  testWidgets(
    'historic anonymous error stays anonymous after adding workspace key',
    (WidgetTester tester) async {
      configure();
      processing.status(entry, <String, Object?>{
        'state': 'error',
        'done': 16,
        'total': 603,
        'error': 'classifier.dev HTTP 403: proxy_requires_payment',
      });
      settings.save(
        url: 'https://example.invalid/v1',
        model: 'fixture',
        classifierKey: 'funded-workspace-key',
      );
      await open(tester);
      expect(find.textContaining('上次匿名判断请求被拒绝'), findsOneWidget);
      expect(find.textContaining('上次 classifier.dev 工作区密钥被拒绝'), findsNothing);
    },
  );

  testWidgets('book budget top-up preserves usage and resumes the same book', (
    WidgetTester tester,
  ) async {
    configure();
    final Json meta = readJson(File('${bookRoot.path}/meta.json')) as Json;
    meta['judge_model_fallback'] = true;
    writeJson(File('${bookRoot.path}/meta.json'), meta);
    final File allowance = File(
      '${bookRoot.path}/work/judge/model-budget.json',
    );
    writeJson(allowance, <String, Object?>{
      'calls': 1,
      'chars': 100,
      'max_calls': 1,
      'max_chars': 200,
    });
    processing.status(entry, <String, Object?>{
      'state': 'error',
      'done': 16,
      'total': 603,
      'error': '模型判断额度已达上限；已保留整理缓存',
    });
    await open(tester);
    await tester.ensureVisible(find.text('追加 1000 次额度并继续'));
    await tester.tap(find.text('追加 1000 次额度并继续'));
    await tester.pumpAndSettle();
    final Json after = readJson(allowance) as Json;
    expect(after['calls'], 1);
    expect(after['max_calls'], 1001);
    expect(processing.starts, 1);
  });

  testWidgets(
    'Jev allowance top-up preserves usage and resumes only this book',
    (WidgetTester tester) async {
      configure();
      final Json meta = readJson(File('${bookRoot.path}/meta.json')) as Json;
      meta['judge_fallback_route'] = 'jev';
      writeJson(File('${bookRoot.path}/meta.json'), meta);
      final File allowance = File(
        '${bookRoot.path}/work/judge/paid-budget.json',
      );
      writeJson(allowance, <String, Object?>{
        'calls': 1000,
        'chars': 5000000,
        'questions': 1000,
      });
      processing.status(entry, <String, Object?>{
        'state': 'error',
        'done': 16,
        'total': 603,
        'error': '付费裁判预算已达上限；已保留缓存',
      });
      await open(tester);
      await tester.ensureVisible(find.text('追加 500 次 Jev 网关额度并继续'));
      await tester.tap(find.text('追加 500 次 Jev 网关额度并继续'));
      await tester.pumpAndSettle();
      final Json after = readJson(allowance) as Json;
      expect(after['calls'], 1000);
      expect(after['chars'], 5000000);
      expect(after['top_up_calls'], 500);
      expect(after['top_up_chars'], 2500000);
      expect(processing.starts, 1);
    },
  );

  testWidgets('missing key and start failures remain visible and retryable', (
    WidgetTester tester,
  ) async {
    await open(tester);
    await tester.tap(find.text('开始整理'));
    await tester.pump();
    expect(find.text('还没有填写模型 API 密钥'), findsOneWidget);
    expect(processing.starts, 0);
    configure();
    await tester.tap(find.text('去填写'));
    await tester.pump();
    processing.startError = StateError('正在暂停，请稍后继续');
    await tester.tap(find.text('开始整理'));
    await tester.pump();
    await tester.tap(find.text('开始'));
    await tester.pumpAndSettle();
    expect(find.text('正在暂停，请稍后继续'), findsOneWidget);
    expect(find.text('开始整理'), findsOneWidget);
  });

  testWidgets('quality retry is exposed only when requested by durable state', (
    WidgetTester tester,
  ) async {
    configure();
    processing.status(entry, <String, Object?>{
      'state': 'done',
      'people': 2,
      'quality': <String, Object?>{'pending': true},
    });
    await open(tester);
    expect(processing.starts, 0);
    await tester.tap(find.text('重试待核对部分'));
    await tester.pump();
    expect(processing.starts, 1);
    expect(find.text('已整理 0 / 2 段'), findsOneWidget);
  });

  testWidgets('removal waits for actual settlement even if the drawer closes', (
    WidgetTester tester,
  ) async {
    int removed = 0;
    processing.removalGate = Completer<void>();
    await open(tester, onRemoved: () => removed++);
    await tester.scrollUntilVisible(
      find.text('移到回收站'),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('移到回收站'));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('移到回收站'),
      240,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('移到回收站'));
    await tester.pump();
    expect(processing.removals, 1);
    expect(bookRoot.existsSync(), isTrue);
    expect(removed, 0);
    Navigator.of(tester.element(find.text('Fixture').last)).pop();
    await tester.pumpAndSettle();
    processing.removalGate!.complete();
    await tester.pumpAndSettle();
    expect(removed, 1);
    expect(bookRoot.existsSync(), isFalse);
    expect(Directory('${root.path}/trash').listSync(), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  test(
    'remove refuses an active lease or cancelling status and retains the book',
    () async {
      final RunLease lease = await RunLease.acquire(bookRoot);
      try {
        await expectLater(
          library.remove(entry),
          throwsA(isA<AlreadyRunning>()),
        );
        expect(bookRoot.existsSync(), isTrue);
      } finally {
        lease.release();
      }
      writeJson(File('${bookRoot.path}/status.json'), <String, Object?>{
        'state': 'cancelling',
      });
      await expectLater(library.remove(entry), throwsStateError);
      expect(bookRoot.existsSync(), isTrue);
      expect(library.books, hasLength(1));
    },
  );

  test(
    'processing refresh invalidates worlds and mentions while keeping text and notes',
    () {
      writeJson(File('${bookRoot.path}/kg.json'), <String, Object?>{
        'log': <Json>[person('p1', 'Alice', 0)],
      });
      Directory('${bookRoot.path}/mentions').createSync();
      writeJson(File('${bookRoot.path}/mentions/0000.json'), <Object?>[
        <Object?>[0, 5, 'p1', 0],
      ]);
      processing.status(entry, <String, Object?>{
        'state': 'running',
        'frontier': 12,
      });
      final BookData data = BookData.open(entry);
      final Object text = data.blocks;
      final Object notes = data.notes;
      expect(data.world(40).people.keys, <String>['p1']);
      expect(data.mentions(0), hasLength(1));
      writeJson(File('${bookRoot.path}/kg.json'), <String, Object?>{
        'log': <Json>[person('p1', 'Alice', 0), person('p2', 'Bob', 12)],
      });
      writeJson(File('${bookRoot.path}/mentions/0000.json'), <Object?>[
        <Object?>[0, 5, 'p1', 0],
        <Object?>[12, 15, 'p2', 0],
      ]);
      processing.status(entry, <String, Object?>{
        'state': 'running',
        'frontier': 20,
      });
      expect(data.refreshKnowledge(), isTrue);
      expect(data.world(40).people.keys, <String>['p1', 'p2']);
      expect(data.mentions(0), hasLength(2));
      expect(identical(data.blocks, text), isTrue);
      expect(identical(data.notes, notes), isTrue);
      expect(data.refreshKnowledge(), isFalse);
      // A replacement with unchanged frontier must still invalidate the world.
      writeJson(File('${bookRoot.path}/kg.json'), <String, Object?>{
        'log': <Json>[person('p1', 'Alice Smith', 0)],
      });
      expect(library.refreshStatus(entry), isTrue);
      data.refreshKnowledge();
      expect(data.world(40).person('p1')!.name, 'Alice Smith');
      File('${bookRoot.path}/kg.json').writeAsStringSync('{invalid');
      library.refreshStatus(entry);
      data.refreshKnowledge();
      expect(data.knowledgeError, isNotNull);
      expect(data.world(40).person('p1')!.name, 'Alice Smith');
      data.notes.dispose();
      data.dispose();
    },
  );

  test('open reader refreshes chapter spoiler verdicts after processing', () {
    final BookData data = BookData.open(entry);
    final Chapter chapter = data.chapters.single;
    final Object blocks = data.blocks;
    expect(chapter.raw['spoil'], isNull);

    final Json updated = fixtureBook();
    final Json row = (updated['chapters']! as List<Object?>).single! as Json;
    row['spoil'] = false;
    writeJson(File('${bookRoot.path}/book.json'), updated);
    expect(library.refreshStatus(entry), isTrue);
    expect(data.refreshKnowledge(), isTrue);
    expect(identical(data.chapters.single, chapter), isTrue);
    expect(identical(data.blocks, blocks), isTrue);
    expect(chapter.raw['spoil'], isFalse);

    row['spoil'] = true;
    writeJson(File('${bookRoot.path}/book.json'), updated);
    expect(library.refreshStatus(entry), isTrue);
    expect(data.refreshKnowledge(), isTrue);
    expect(chapter.raw['spoil'], isTrue);

    row['title'] = 'Different chapter';
    row['spoil'] = false;
    writeJson(File('${bookRoot.path}/book.json'), updated);
    expect(library.refreshStatus(entry), isTrue);
    data.refreshKnowledge();
    expect(chapter.raw['spoil'], isTrue);
    data.notes.dispose();
    data.dispose();
  });
}
