import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/llm.dart' as llm;
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/pipeline/request_diagnostics.dart';
import 'package:thusfar_core/src/pipeline/request_lifecycle.dart';
import 'package:thusfar_core/src/pipeline/run_lease.dart';

import '../support/request_fixture.dart';

typedef Json = Map<String, Object?>;

void main() {
  late Directory root;
  late llm.ChatTransport previous;
  late Map<String, String> previousEnv;
  setUp(() {
    root = Directory.systemTemp.createTempSync('thusfar-request-diagnostics-');
    previous = llm.transport;
    previousEnv = Map<String, String>.of(environ);
    environ
      ..clear()
      ..addAll({
        'LLM_API_KEY': 'private-fixture-key',
        'LLM_BASE_URL': 'https://private.invalid/v1',
        'LLM_WALL_TIMEOUT': '1',
      });
  });
  tearDown(() {
    llm.transport = previous;
    environ
      ..clear()
      ..addAll(previousEnv);
    root.deleteSync(recursive: true);
  });

  File diagnosticFile() =>
      File('${root.path}/work/model-request-diagnostics.json');
  Json diagnostics() => jsonDecode(diagnosticFile().readAsStringSync()) as Json;
  List<Json> attempts() => (diagnostics()['attempts']! as List).cast<Json>();
  List<Json> events(Json attempt) => (attempt['events']! as List).cast<Json>();
  Future<llm.ChatResult> chat(ModelRequestScope scope) => scope.run(
    () => llm.chat('fixture', const [
      {'role': 'user', 'content': 'private prompt'},
    ], retries: 4),
  );

  test(
    'success records local timing without changing commit evidence',
    () async {
      final FixtureTransport fake = FixtureTransport(
        (_) async => streamReply('private response'),
      );
      llm.transport = fake;
      final ModelRequestScope scope = ModelRequestScope(root);
      expect((await chat(scope)).text, 'private response');
      await Future<void>.delayed(Duration.zero);
      expect(hasUnsettledModelRequests(root), isTrue);
      scope.settle(receivedCommitted: true);
      expect(hasUnsettledModelRequests(root), isFalse);
      final Json row = attempts().single;
      expect(diagnostics()['id_scope'], 'local_only');
      expect(row['id'], 1);
      expect(row['run_id'], isA<int>());
      expect(row['phase'], 'received');
      expect(row['bytes_received'], greaterThan(0));
      expect(
        row['last_byte_at_ms'],
        greaterThanOrEqualTo(row['started_at_ms']!),
      );
      expect(row['last_byte_elapsed_ms'], greaterThanOrEqualTo(0));
      expect(
        events(row).map((e) => e['event']),
        containsAllInOrder([
          'dispatch',
          'headers',
          'body_cancel_requested',
          'received',
        ]),
      );
      expect(events(row).last['event'], 'run_settled');
      expect(events(row).last['received_committed'], true);
      expect(
        events(row).firstWhere((e) => e['event'] == 'headers')['http_status'],
        200,
      );
      expect(fake.calls, 1);
      for (final String secret in [
        'private prompt',
        'private response',
        'private-fixture-key',
        'private.invalid',
      ]) {
        expect(diagnosticFile().readAsStringSync(), isNot(contains(secret)));
      }
    },
  );

  test('network failure keeps exact safe cause and does not retry', () async {
    final FixtureTransport fake = FixtureTransport(
      (_) async => throw const SocketException('private endpoint credential'),
    );
    llm.transport = fake;
    final ModelRequestScope scope = ModelRequestScope(root);
    await expectLater(chat(scope), throwsA(isA<llm.UnknownOutcomeLLMError>()));
    final Json row = attempts().single;
    expect(row['phase'], 'unknown');
    expect(row['code'], 'network_interrupted');
    expect(
      events(row).firstWhere((e) => e['event'] == 'transport_error')['code'],
      'socket_exception',
    );
    expect(row['bytes_received'], 0);
    expect(fake.calls, 1);
    expect(hasUnsettledModelRequests(root), isTrue);
    expect(diagnosticFile().readAsStringSync(), isNot(contains('private')));
  });

  test('TLS failure before sending leaves no uncertain paid request', () async {
    final ServerSocket server = await ServerSocket.bind('127.0.0.1', 0);
    final subscription = server.listen((socket) {
      socket.listen((_) {
        socket.add(utf8.encode('HTTP/1.1 400 Bad Request\r\n\r\n'));
        unawaited(socket.flush().then((_) => socket.destroy()));
      }, onError: (Object _) => socket.destroy());
    });
    final HttpClient client = HttpClient()..findProxy = (_) => 'DIRECT';
    llm.transport = llm.IoTransport(client);
    environ['LLM_BASE_URL'] = 'https://127.0.0.1:${server.port}/v1';
    final ModelRequestScope scope = ModelRequestScope(root);
    try {
      await expectLater(
        scope.run(() => llm.chat('fixture', const [], retries: 0)),
        throwsA(isA<llm.TransientLLMError>()),
      );
      expect(hasUnsettledModelRequests(root), isFalse);
      expect(scope.hasUnknown, isFalse);
      expect(attempts().single['phase'], 'rejected');
      expect(
        events(attempts().single).map((e) => e['event']),
        isNot(contains('send_started')),
      );
      expect(
        events(
          attempts().single,
        ).firstWhere((e) => e['event'] == 'transport_error')['code'],
        'handshake_exception',
      );
    } finally {
      client.close(force: true);
      await subscription.cancel();
      await server.close();
    }
  });

  test('a failed connection can retry and then save the answer', () async {
    int calls = 0;
    final previousSleep = llm.sleep;
    llm.sleep = (_) async {};
    llm.transport = FixtureTransport((_) async {
      if (++calls == 1) {
        throw const llm.ConnectionNotSent(HandshakeException());
      }
      return streamReply('answer');
    });
    final ModelRequestScope scope = ModelRequestScope(root);
    try {
      expect((await chat(scope)).text, 'answer');
      expect(calls, 2);
      scope.settle(receivedCommitted: true);
      expect(hasUnsettledModelRequests(root), isFalse);
    } finally {
      llm.sleep = previousSleep;
    }
  });

  test(
    'raw-byte and stream-error timestamps survive a partial response',
    () async {
      final List<int> partial = utf8.encode('data: {"private":"text"}\n\n');
      final FixtureTransport fake = FixtureTransport(
        (_) async => llm.ChatResponse(
          200,
          'text/event-stream',
          Stream<List<int>>.multi((controller) {
            controller.add(partial);
            controller.addError(const HttpException('private response broke'));
            controller.close();
          }),
          headers: const {'request-id': 'private-provider-id'},
        ),
      );
      llm.transport = fake;
      final ModelRequestScope scope = ModelRequestScope(root);
      await expectLater(
        chat(scope),
        throwsA(isA<llm.UnknownOutcomeLLMError>()),
      );
      await Future<void>.delayed(Duration.zero);
      final Json row = attempts().single;
      expect(row['bytes_received'], partial.length);
      expect(row['last_byte_elapsed_ms'], isA<int>());
      expect(
        events(row).firstWhere((e) => e['event'] == 'body_error')['code'],
        'http_exception',
      );
      expect(row['code'], 'network_interrupted');
      expect(fake.calls, 1);
      expect(diagnosticFile().readAsStringSync(), isNot(contains('private')));
    },
  );

  test(
    'cancellation records first provenance before unknown settlement',
    () async {
      final Completer<void> listening = Completer<void>();
      final StreamController<List<int>> body = StreamController<List<int>>(
        onListen: listening.complete,
      );
      llm.transport = FixtureTransport(
        (_) async => llm.ChatResponse(200, 'text/event-stream', body.stream),
      );
      final ModelRequestScope scope = ModelRequestScope(root);
      final RunCancellation cancellation = RunCancellation();
      final Future<void> check = expectLater(
        cancellation.run(() => chat(scope)),
        throwsA(isA<Cancelled>()),
      );
      await listening.future;
      cancellation.cancel(reason: 'background_unavailable');
      cancellation.cancel(reason: 'user');
      await check;
      await Future<void>.delayed(Duration.zero);
      final Json row = attempts().single;
      expect(row['code'], 'cancelled');
      expect(
        events(row).firstWhere((e) => e['event'] == 'cancel_requested')['code'],
        'background_unavailable',
      );
      expect(events(row).map((e) => e['event']), contains('body_cancelled'));
      expect(hasUnsettledModelRequests(root), isTrue);
      await body.close();
    },
  );

  test(
    'native abort is recorded at actual abort call before headers',
    () async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final HttpClient client = HttpClient()..findProxy = (_) => 'DIRECT';
      final Completer<void> arrived = Completer<void>();
      final StreamSubscription<HttpRequest> incoming = server.listen((request) {
        unawaited(request.drain<void>().then((_) => arrived.complete()));
      });
      llm.transport = llm.IoTransport(client);
      environ['LLM_BASE_URL'] = 'http://127.0.0.1:${server.port}/v1';
      final ModelRequestScope scope = ModelRequestScope(root);
      final RunCancellation cancellation = RunCancellation();
      try {
        final Future<void> check = expectLater(
          cancellation.run(() => chat(scope)),
          throwsA(isA<Cancelled>()),
        );
        await arrived.future.timeout(const Duration(seconds: 2));
        cancellation.cancel(reason: 'user');
        await check;
        final Json row = attempts().single;
        expect(
          events(row).map((e) => e['event']),
          containsAllInOrder([
            'dispatch',
            'send_started',
            'cancel_requested',
            'abort_requested',
          ]),
        );
        expect(
          events(
            row,
          ).firstWhere((e) => e['event'] == 'abort_requested')['code'],
          'cancelled',
        );
        expect(row['code'], 'cancelled');
      } finally {
        client.close(force: true);
        await incoming.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'diagnostic storage failure cannot fail successful model or commit',
    () async {
      Directory(diagnosticFile().path).createSync(recursive: true);
      llm.transport = FixtureTransport((_) async => streamReply('done'));
      final ModelRequestScope scope = ModelRequestScope(root);
      expect((await chat(scope)).text, 'done');
      scope.settle(receivedCommitted: true);
      expect(hasUnsettledModelRequests(root), isFalse);
    },
  );

  test('attempts and events are bounded; loaded history is allowlisted', () {
    diagnosticFile().parent.createSync(recursive: true);
    diagnosticFile().writeAsStringSync(
      jsonEncode({
        'private-key': 'private history',
        'attempts': [
          {
            'run_id': 1,
            'id': 1,
            'phase': 'received',
            'private': 'private',
            'code': 'private-provider-id',
            'events': [
              {
                'event': 'headers',
                'at_ms': 1,
                'elapsed_ms': 0,
                'code': 'private-provider-id',
                'private': 'private',
              },
            ],
          },
        ],
      }),
    );
    final ModelRequestScope scope = ModelRequestScope(root);
    for (int i = 0; i < 40; i++) {
      final ModelRequestReceipt receipt = scope.begin();
      for (int j = 0; j < 20; j++) {
        receipt.trace.record('headers', code: 'private-provider-id');
      }
      receipt.received();
    }
    scope.settle(receivedCommitted: true);
    expect(attempts(), hasLength(32));
    expect(attempts().first['id'], 9);
    expect(attempts().every((row) => events(row).length <= 16), isTrue);
    expect(diagnosticFile().readAsStringSync(), isNot(contains('private')));
  });

  test('late cleanup from an older run cannot overwrite a newer trace', () {
    final ModelRequestTrace old = ModelRequestDiagnostics(root).begin(1);
    old.finish('unknown', code: 'cancelled');
    final ModelRequestTrace current = ModelRequestDiagnostics(root).begin(1);
    current.record('headers', httpStatus: 200);
    final String before = diagnosticFile().readAsStringSync();
    old.record('body_cancelled');
    expect(diagnosticFile().readAsStringSync(), before);
    expect(attempts(), hasLength(2));
    expect(attempts().last['phase'], 'inflight');
  });

  test(
    'last-byte writes are throttled but terminal boundary flushes latest',
    () {
      final ModelRequestDiagnostics owner = ModelRequestDiagnostics(root);
      final ModelRequestTrace trace = owner.begin(1);
      trace.bytes(1);
      expect(attempts().single['bytes_received'], 1);
      trace.bytes(2);
      expect(attempts().single['bytes_received'], 1);
      trace.finish('received');
      expect(attempts().single['bytes_received'], 3);
      expect(attempts().single['last_byte_at_ms'], isA<int>());
    },
  );
}
