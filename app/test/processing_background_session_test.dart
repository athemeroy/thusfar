import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/library.dart';
import 'package:thusfar_app/data/processing_background_session.dart';

BookEntry backgroundBook(String id) => BookEntry(
  id: id,
  dir: Directory('/unused-fixture/$id'),
  meta: <String, Object?>{'title': 'Fixture $id'},
  status: ProcessStatus(<String, Object?>{
    'state': 'running',
    'done': 3,
    'total': 10,
  }),
  added: 0,
);

void main() {
  late List<String> events;
  late List<String> unavailable;
  late ProcessingBackgroundSession session;
  late BookEntry first;
  late BookEntry second;
  Duration now = Duration.zero;

  ProcessingBackgroundSession create({
    Future<bool> Function(BookEntry, String)? start,
    Future<bool> Function(BookEntry, String)? update,
    Future<void> Function(String)? stop,
    Future<void> Function(String)? onUnavailable,
  }) {
    final ProcessingBackgroundSession value = ProcessingBackgroundSession(
      start:
          start ??
          (BookEntry book, String phase) async {
            events.add('start:${book.id}:$phase');
            return true;
          },
      update:
          update ??
          (BookEntry book, String phase) async {
            events.add('update:${book.id}:$phase');
            return true;
          },
      stop:
          stop ??
          (String id) async {
            events.add('stop:$id');
          },
      onUnavailable:
          onUnavailable ??
          (String id) async {
            unavailable.add(id);
          },
      heartbeatInterval: const Duration(seconds: 30),
      elapsed: () => now,
    );
    addTearDown(value.close);
    return value;
  }

  setUp(() {
    events = <String>[];
    unavailable = <String>[];
    now = Duration.zero;
    first = backgroundBook('first');
    second = backgroundBook('second');
  });

  test('idle session never acquires or refreshes native resources', () async {
    session = create();
    session.workerHeartbeat();
    session.synchronize(<String, Object?>{
      'alive': true,
      'current': null,
      'queued': <String>[],
    });
    await session.refresh();
    await session.close();
    expect(events, isEmpty);
    expect(unavailable, isEmpty);
  });

  test('acquire waits for native readiness before refreshing', () async {
    final Completer<bool> ready = Completer<bool>();
    session = create(
      start: (BookEntry book, String phase) {
        events.add('start:${book.id}:$phase');
        return ready.future;
      },
    );
    bool acquired = false;
    final Future<void> pending = session.acquire(first).then((_) {
      acquired = true;
    });
    await Future<void>.delayed(Duration.zero);
    await session.refresh();
    expect(acquired, isFalse);
    expect(events, <String>['start:first:preparing']);

    ready.complete(true);
    await pending;
    await session.refresh();
    expect(acquired, isTrue);
    expect(events, <String>['start:first:preparing', 'update:first:running']);
  });

  test(
    'notification visibility denial does not reject native readiness',
    () async {
      session = create(start: (_, _) async => false);
      await session.acquire(first);
      await session.refresh();
      expect(events, <String>['update:first:running']);
      expect(unavailable, isEmpty);
    },
  );

  test('native start failure cleans up and cannot heartbeat', () async {
    session = create(
      start: (_, _) async => throw StateError('native start failed'),
    );
    await expectLater(session.acquire(first), throwsStateError);
    session.workerHeartbeat();
    await session.refresh();
    expect(events, <String>['stop:first']);
    expect(unavailable, isEmpty);
  });

  test('stop before native acknowledgement rejects late acquire', () async {
    final Completer<bool> ready = Completer<bool>();
    session = create(start: (_, _) => ready.future);
    final Future<void> rejected = expectLater(
      session.acquire(first),
      throwsStateError,
    );
    await session.stopBook(first.id);
    expect(events, <String>['stop:first']);
    ready.complete(true);
    await rejected;
    await session.refresh();
    expect(events.where((String e) => e.startsWith('update:')), isEmpty);
    expect(events.where((String e) => e == 'stop:first'), hasLength(1));
  });

  test('close cancels pending native readiness and rejects new work', () async {
    final Completer<bool> ready = Completer<bool>();
    session = create(start: (_, _) => ready.future);
    final Future<void> rejected = expectLater(
      session.acquire(first),
      throwsStateError,
    );
    await session.close();
    ready.complete(true);
    await rejected;
    await expectLater(session.acquire(second), throwsStateError);
    await session.refresh();
    expect(events.every((String e) => e == 'stop:first'), isTrue);
    expect(events, isNotEmpty);
  });

  test('idle worker cancels pending acquire before native readiness', () async {
    final Completer<bool> ready = Completer<bool>();
    session = create(start: (_, _) => ready.future);
    final Future<void> rejected = expectLater(
      session.acquire(first),
      throwsStateError,
    );
    session.synchronize(<String, Object?>{
      'alive': true,
      'current': null,
      'queued': <String>[],
    });
    await Future<void>.delayed(Duration.zero);
    ready.complete(true);
    await rejected;
    await session.refresh();
    expect(events.where((String e) => e.startsWith('update:')), isEmpty);
  });

  test(
    'queue handoff keeps old service until next native acquire succeeds',
    () async {
      final Completer<bool> secondReady = Completer<bool>();
      session = create(
        start: (BookEntry book, String phase) async {
          events.add('start:${book.id}:$phase');
          return book.id == second.id ? secondReady.future : true;
        },
      );
      await session.acquire(first);
      session.synchronize(<String, Object?>{
        'alive': true,
        'current': null,
        'queued': <String>[second.id],
      });
      await session.refresh();
      expect(events.last, 'update:first:queued');
      final Future<void> pending = session.acquire(second);
      await Future<void>.delayed(Duration.zero);
      expect(events, isNot(contains('stop:first')));
      secondReady.complete(true);
      await pending;
      expect(
        events.indexOf('stop:first'),
        greaterThan(events.indexOf('start:second:preparing')),
      );
      await session.refresh();
      expect(events.last, 'update:second:running');
      expect(events.where((String e) => e == 'stop:first'), hasLength(1));
    },
  );

  test(
    'failed handoff leaves previous service owned until worker becomes idle',
    () async {
      session = create(
        start: (BookEntry book, String phase) async {
          if (book.id == second.id) throw StateError('native start failed');
          return true;
        },
      );
      await session.acquire(first);
      await expectLater(session.acquire(second), throwsStateError);
      await session.refresh();
      expect(events, <String>['stop:second', 'update:first:running']);
      session.synchronize(<String, Object?>{
        'alive': true,
        'current': null,
        'queued': <String>[],
      });
      await Future<void>.delayed(Duration.zero);
      expect(events.last, 'stop:first');
    },
  );

  for (final bool alive in <bool>[true, false]) {
    test(
      'terminal worker health releases every resource (alive: $alive)',
      () async {
        session = create();
        await session.acquire(first);
        session.synchronize(<String, Object?>{
          'alive': alive,
          'current': null,
          'queued': <String>[],
        });
        await Future<void>.delayed(Duration.zero);
        session.workerHeartbeat();
        await session.refresh();
        await session.close();
        expect(events, <String>['start:first:preparing', 'stop:first']);
        expect(unavailable, isEmpty);
      },
    );
  }

  test(
    'stale worker heartbeat retires native resources despite UI refreshes',
    () async {
      session = create();
      await session.acquire(first);
      now = const Duration(seconds: 59);
      await session.refresh();
      expect(events.last, 'update:first:running');
      final int updateCount = events
          .where((String e) => e.startsWith('update:'))
          .length;
      now = const Duration(seconds: 61);
      await session.refresh();
      expect(events.last, 'stop:first');
      now = const Duration(minutes: 5);
      await session.refresh();
      expect(
        events.where((String e) => e.startsWith('update:')),
        hasLength(updateCount),
      );
      session.workerHeartbeat();
      await session.refresh();
      expect(
        events.where((String e) => e.startsWith('update:')),
        hasLength(updateCount),
        reason: 'late heartbeat must not reacquire a retired native lease',
      );
    },
  );

  test(
    'fresh worker heartbeat keeps lease alive across many UI refreshes',
    () async {
      session = create();
      await session.acquire(first);
      for (int seconds = 30; seconds <= 300; seconds += 30) {
        now = Duration(seconds: seconds);
        session.workerHeartbeat();
        await session.refresh();
      }
      expect(
        events.where((String e) => e.startsWith('update:')),
        hasLength(10),
      );
      expect(events.where((String e) => e.startsWith('stop:')), isEmpty);
      expect(unavailable, isEmpty);
    },
  );

  test(
    'late cancelled start cannot stop a newer lease for the same book',
    () async {
      final Completer<bool> firstReady = Completer<bool>();
      int starts = 0;
      session = create(
        start: (_, _) async {
          starts++;
          return starts == 1 ? firstReady.future : true;
        },
      );
      final Future<void> rejected = expectLater(
        session.acquire(first),
        throwsStateError,
      );
      await session.stopBook(first.id);
      await session.acquire(first);
      firstReady.complete(true);
      await rejected;
      await session.refresh();
      expect(events, <String>['stop:first', 'update:first:running']);
      expect(unavailable, isEmpty);
    },
  );

  for (final bool throws in <bool>[false, true]) {
    test(
      'stale update cannot retire newer same-book lease (throws: $throws)',
      () async {
        final Completer<bool> firstUpdate = Completer<bool>();
        int updates = 0;
        session = create(
          update: (BookEntry book, String phase) async {
            events.add('update:${book.id}:$phase');
            updates++;
            return updates == 1 ? firstUpdate.future : true;
          },
        );
        await session.acquire(first);
        final Future<void> pending = session.refresh();
        await session.stopBook(first.id);
        await session.acquire(first);
        if (throws) {
          firstUpdate.completeError(StateError('old native generation failed'));
        } else {
          firstUpdate.complete(false);
        }
        await pending;
        await session.refresh();
        expect(events.where((String e) => e == 'stop:first'), hasLength(1));
        expect(events.last, 'update:first:running');
        expect(unavailable, isEmpty);
      },
    );
  }

  test('refresh sends waiting and finalizing progress phases', () async {
    session = create();
    await session.acquire(first);
    first.status = ProcessStatus(<String, Object?>{
      'state': 'running',
      'notice': '等待模型回复',
      'done': 3,
      'total': 10,
    });
    await session.refresh();
    expect(events.last, 'update:first:waiting');
    first.status = ProcessStatus(<String, Object?>{
      'state': 'finalizing',
      'done': 10,
      'total': 10,
    });
    await session.refresh();
    expect(events.last, 'update:first:finalizing');
  });

  for (final bool throws in <bool>[false, true]) {
    test(
      'lost native service cleans up before reporting unavailable (throws: $throws)',
      () async {
        session = create(
          update: (_, _) async {
            if (throws) throw StateError('native service disappeared');
            return false;
          },
        );
        await session.acquire(first);
        await session.refresh();
        expect(events, <String>['start:first:preparing', 'stop:first']);
        expect(unavailable, <String>[first.id]);
        await session.refresh();
        expect(unavailable, hasLength(1));
      },
    );
  }

  test(
    'stale heartbeat releases native resources before worker pause settles',
    () async {
      final Completer<void> pause = Completer<void>();
      session = create(
        onUnavailable: (String id) async {
          events.add('pause:$id');
          await pause.future;
        },
      );
      await session.acquire(first);
      now = const Duration(seconds: 61);
      final Future<void> pending = session.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(events, <String>[
        'start:first:preparing',
        'stop:first',
        'pause:first',
      ]);
      await session.close();
      expect(events.where((String e) => e == 'stop:first'), hasLength(1));
      pause.complete();
      await pending;
    },
  );

  test('new admission while old native stop settles is not paused', () async {
    final Completer<void> oldStop = Completer<void>();
    int stops = 0;
    int updates = 0;
    session = create(
      stop: (String id) async {
        events.add('stop:$id');
        stops++;
        if (stops == 1) await oldStop.future;
      },
      update: (BookEntry book, String phase) async {
        events.add('update:${book.id}:$phase');
        updates++;
        return updates > 1;
      },
    );
    await session.acquire(first);
    final Future<void> pending = session.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(events.last, 'stop:first');
    await session.acquire(first);
    oldStop.complete();
    await pending;
    await session.refresh();
    expect(events.where((String e) => e == 'stop:first'), hasLength(1));
    expect(events.last, 'update:first:running');
    expect(unavailable, isEmpty);
  });

  test(
    'unchanged UI refreshes are throttled but native lease is renewed',
    () async {
      session = create();
      await session.acquire(first);
      await session.refresh();
      for (int seconds = 1; seconds < 30; seconds++) {
        now = Duration(seconds: seconds);
        await session.refresh();
      }
      expect(events.where((String e) => e.startsWith('update:')), hasLength(1));
      now = const Duration(seconds: 30);
      session.workerHeartbeat();
      await session.refresh();
      expect(events.where((String e) => e.startsWith('update:')), hasLength(2));
      first.status = ProcessStatus(<String, Object?>{
        'state': 'running',
        'done': 4,
        'total': 10,
      });
      await session.refresh();
      expect(events.where((String e) => e.startsWith('update:')), hasLength(3));
    },
  );

  test('overlapping timer refreshes cannot duplicate native updates', () async {
    final Completer<bool> updated = Completer<bool>();
    session = create(
      update: (BookEntry book, String phase) {
        events.add('update:${book.id}:$phase');
        return updated.future;
      },
    );
    await session.acquire(first);
    final Future<void> pending = session.refresh();
    await session.refresh();
    expect(events.where((String e) => e.startsWith('update:')), hasLength(1));
    updated.complete(true);
    await pending;
  });
}
