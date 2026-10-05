import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/llm.dart' as llm;
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/pipeline/jev.dart' as jev;
import 'package:thusfar_core/src/pipeline/request_lifecycle.dart';
import 'package:thusfar_core/src/pipeline/run_lease.dart';

typedef Json = Map<String, Object?>;

class FixtureTransport implements llm.ChatTransport {
  FixtureTransport(this.reply);
  final Future<llm.ChatResponse> Function(int) reply;
  int calls = 0;
  @override
  Future<llm.ChatResponse> post(llm.ChatRequest request, Duration timeout) =>
      reply(++calls);
}

llm.ChatResponse streamReply(String text, {bool terminal = true}) =>
    llm.ChatResponse(
      200,
      'text/event-stream',
      Stream<List<int>>.value(
        utf8.encode(
          'data: ${jsonEncode(<String, Object?>{
            'choices': <Object?>[
              <String, Object?>{
                'delta': <String, Object?>{'content': text},
              },
            ],
          })}\n\n${terminal ? 'data: [DONE]\n\n' : ''}',
        ),
      ),
    );

void main() {
  late llm.ChatTransport previous;
  late Map<String, String> previousEnv;
  late Future<void> Function(Duration) previousSleep;
  late Directory root;
  setUp(() {
    previous = llm.transport;
    previousEnv = Map<String, String>.of(environ);
    previousSleep = llm.sleep;
    llm.sleep = (_) async {};
    environ
      ..clear()
      ..addAll(<String, String>{
        'LLM_API_KEY': 'offline-test-key',
        'LLM_BASE_URL': 'https://offline.invalid/v1',
        'LLM_WALL_TIMEOUT': '2',
        'JEV_API_KEY': 'offline-test-key',
        'JEV_ROUTE': 'paid',
        'JEV_URL': 'https://offline.invalid/judge',
        'JUDGE_LOG': '0',
      });
    root = Directory.systemTemp.createTempSync('thusfar-request-');
    environ['JUDGE_LOG_DIR'] = '${root.path}/work/judge';
  });
  tearDown(() {
    llm.transport = previous;
    llm.sleep = previousSleep;
    environ
      ..clear()
      ..addAll(previousEnv);
    root.deleteSync(recursive: true);
  });

  Future<llm.ChatResult> chat() =>
      llm.chat('fixture', const <Map<String, String>>[], retries: 4);

  for (final (String code, Object error) in <(String, Object)>[
    (
      'network_interrupted',
      const SocketException('private endpoint and payload must not leak'),
    ),
    ('timeout', TimeoutException('private endpoint and payload must not leak')),
  ]) {
    test('$code is distinct and never replays an unknown request', () async {
      final FixtureTransport fake = FixtureTransport((_) async => throw error);
      llm.transport = fake;
      final ModelRequestScope scope = ModelRequestScope(root);
      await expectLater(
        scope.run(chat),
        throwsA(
          isA<llm.UnknownOutcomeLLMError>().having((e) => e.code, 'code', code),
        ),
      );
      expect(fake.calls, 1);
      expect(scope.hasUnknown, isTrue);
      scope.settle(receivedCommitted: true);
      final String journal =
          File(
            '${root.path}/work/model-request-journal.json',
          ).readAsStringSync();
      expect(journal, contains(code));
      for (final String secret in <String>[
        'offline-test-key',
        'offline.invalid',
        'private endpoint',
        'payload',
      ]) {
        expect(journal, isNot(contains(secret)));
      }
      expect(llm.transientFailure(llm.UnknownOutcomeLLMError(code)), isFalse);
    });
  }

  test('EOF after partial valid JSON is not a completed generation', () async {
    final FixtureTransport fake = FixtureTransport(
      (_) async => streamReply('{"ok":true}', terminal: false),
    );
    llm.transport = fake;
    await expectLater(
      chat(),
      throwsA(
        isA<llm.UnknownOutcomeLLMError>().having(
          (e) => e.code,
          'code',
          'incomplete_response',
        ),
      ),
    );
    expect(fake.calls, 1);
  });

  for (final int status in <int>[408, 500, 502, 503, 504]) {
    test(
      'HTTP $status can conceal upstream completion and is not replayed',
      () async {
        final FixtureTransport fake = FixtureTransport(
          (_) async => llm.ChatResponse(
            status,
            'application/json',
            Stream<List<int>>.value(utf8.encode('{}')),
          ),
        );
        llm.transport = fake;
        await expectLater(chat(), throwsA(isA<llm.UnknownOutcomeLLMError>()));
        expect(fake.calls, 1);
      },
    );
  }

  test(
    'explicit rate-limit rejection can retry within the existing bound',
    () async {
      final FixtureTransport fake = FixtureTransport(
        (int call) async =>
            call == 1
                ? llm.ChatResponse(
                  429,
                  'application/json',
                  Stream<List<int>>.value(utf8.encode('{}')),
                )
                : streamReply('done'),
      );
      llm.transport = fake;
      final ModelRequestScope scope = ModelRequestScope(root);
      expect((await scope.run(chat)).text, 'done');
      expect(fake.calls, 2);
      expect(
        hasUnsettledModelRequests(root),
        isTrue,
        reason:
            'successful receipt remains until higher-level cache commitment',
      );
      scope.settle(receivedCommitted: true);
      expect(hasUnsettledModelRequests(root), isFalse);
    },
  );

  test(
    'cancelled stream promptly closes client connection and retains unknown receipt',
    () async {
      bool disconnected = false;
      final Completer<void> started = Completer<void>();
      final StreamController<List<int>> body = StreamController<List<int>>(
        onListen: () => started.complete(),
        onCancel: () => disconnected = true,
      );
      final FixtureTransport fake = FixtureTransport(
        (_) async => llm.ChatResponse(200, 'text/event-stream', body.stream),
      );
      llm.transport = fake;
      final RunCancellation token = RunCancellation();
      final ModelRequestScope scope = ModelRequestScope(root);
      final Future<void> check = expectLater(
        token.run(() => scope.run(chat)),
        throwsA(isA<Cancelled>()),
      );
      await started.future;
      final Stopwatch watch = Stopwatch()..start();
      token.cancel();
      await check.timeout(const Duration(seconds: 1));
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(disconnected, isTrue);
      expect(fake.calls, 1);
      scope.settle(receivedCommitted: true);
      expect(hasUnsettledModelRequests(root), isTrue);
      expect(
        File('${root.path}/work/model-request-journal.json').readAsStringSync(),
        contains('cancelled'),
      );
      await body.close();
    },
  );

  test(
    'cancel during known-rejection backoff does not dispatch a retry',
    () async {
      final Completer<void> sleeping = Completer<void>();
      final Completer<void> release = Completer<void>();
      llm.sleep = (_) {
        sleeping.complete();
        return release.future;
      };
      final FixtureTransport fake = FixtureTransport(
        (_) async => llm.ChatResponse(
          429,
          'application/json',
          Stream<List<int>>.value(utf8.encode('{}')),
        ),
      );
      llm.transport = fake;
      final RunCancellation token = RunCancellation();
      final ModelRequestScope scope = ModelRequestScope(root);
      final Future<void> check = expectLater(
        token.run(() => scope.run(chat)),
        throwsA(isA<Cancelled>()),
      );
      await sleeping.future;
      token.cancel();
      await check.timeout(const Duration(seconds: 1));
      release.complete();
      expect(fake.calls, 1);
      scope.settle(receivedCommitted: true);
      expect(hasUnsettledModelRequests(root), isFalse);
    },
  );

  test(
    'late headers after cancellation have their response disposed',
    () async {
      final Completer<llm.ChatResponse> headers = Completer<llm.ChatResponse>();
      final FixtureTransport fake = FixtureTransport((_) => headers.future);
      llm.transport = fake;
      final RunCancellation token = RunCancellation();
      final Future<void> check = expectLater(
        token.run(chat),
        throwsA(isA<Cancelled>()),
      );
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      await check;
      final Completer<void> disposed = Completer<void>();
      final StreamController<List<int>> body = StreamController<List<int>>(
        onCancel: () => disposed.complete(),
      );
      headers.complete(llm.ChatResponse(200, 'text/event-stream', body.stream));
      await disposed.future.timeout(const Duration(seconds: 1));
      expect(fake.calls, 1);
      await body.close();
    },
  );

  test(
    'malformed event structure fails closed without another request',
    () async {
      final FixtureTransport fake = FixtureTransport(
        (_) async => llm.ChatResponse(
          200,
          'text/event-stream',
          Stream<List<int>>.value(
            utf8.encode('data: {"choices":{"private":"payload"}}\n\n'),
          ),
        ),
      );
      llm.transport = fake;
      final ModelRequestScope scope = ModelRequestScope(root);
      await expectLater(
        scope.run(chat),
        throwsA(
          isA<llm.UnknownOutcomeLLMError>().having(
            (e) => e.code,
            'code',
            'response_interrupted',
          ),
        ),
      );
      expect(fake.calls, 1);
      expect(scope.hasUnknown, isTrue);
    },
  );

  for (final (String protocol, List<Json> events) in <(String, List<Json>)>[
    (
      'openai',
      <Json>[
        <String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'delta': <String, Object?>{'content': 'done'},
              'finish_reason': 'stop',
            },
          ],
        },
      ],
    ),
    (
      'anthropic',
      <Json>[
        <String, Object?>{
          'type': 'content_block_delta',
          'delta': <String, Object?>{'text': 'done'},
        },
        <String, Object?>{'type': 'message_stop'},
      ],
    ),
    (
      'gemini',
      <Json>[
        <String, Object?>{
          'candidates': <Object?>[
            <String, Object?>{
              'content': <String, Object?>{
                'parts': <Object?>[
                  <String, Object?>{'text': 'done'},
                ],
              },
              'finishReason': 'STOP',
            },
          ],
        },
      ],
    ),
  ]) {
    test('$protocol terminal event proves completion at EOF', () async {
      llm.transport = FixtureTransport(
        (_) async => llm.ChatResponse(
          200,
          'text/event-stream',
          Stream<List<int>>.value(
            utf8.encode(events.map((e) => 'data: ${jsonEncode(e)}\n\n').join()),
          ),
        ),
      );
      final llm.ChatResult result = await llm.chat(
        'fixture',
        <Map<String, String>>[],
        endpoint: llm.ChatEndpoint(
          protocol: protocol,
          baseUrl: 'https://offline.invalid',
          apiKey: 'offline-test',
        ),
      );
      expect(result.text, 'done');
    });
  }

  test(
    'native HTTP cancellation closes a server-observed pending connection',
    () async {
      final ServerSocket server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final HttpClient client = HttpClient()..findProxy = (_) => 'DIRECT';
      llm.transport = llm.IoTransport(client);
      final Completer<void> started = Completer<void>(),
          disconnected = Completer<void>();
      final List<Socket> sockets = <Socket>[];
      final StreamSubscription<Socket> incoming = server.listen((
        Socket socket,
      ) {
        sockets.add(socket);
        bool sent = false;
        socket.listen(
          (_) {
            if (sent) return;
            sent = true;
            const String event =
                'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n';
            socket.write(
              'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n${utf8.encode(event).length.toRadixString(16)}\r\n$event\r\n',
            );
            unawaited(socket.flush().then((_) => started.complete()));
          },
          onDone: () {
            if (!disconnected.isCompleted) disconnected.complete();
          },
          onError: (Object _) {
            if (!disconnected.isCompleted) disconnected.complete();
          },
        );
      });
      final RunCancellation token = RunCancellation();
      try {
        final Future<void> check = expectLater(
          token.run(
            () => llm.chat(
              'fixture',
              <Map<String, String>>[],
              endpoint: llm.ChatEndpoint(
                protocol: 'openai',
                baseUrl: 'http://127.0.0.1:${server.port}',
                apiKey: 'offline-test',
              ),
              retries: 4,
            ),
          ),
          throwsA(isA<Cancelled>()),
        );
        await started.future.timeout(const Duration(seconds: 2));
        token.cancel();
        await check.timeout(const Duration(seconds: 1));
        await disconnected.future.timeout(const Duration(seconds: 2));
      } finally {
        client.close(force: true);
        await incoming.cancel();
        for (final Socket socket in sockets) {
          socket.destroy();
        }
        await server.close();
      }
    },
  );

  test('pre-cancelled call never dispatches or creates a journal', () async {
    final FixtureTransport fake = FixtureTransport(
      (_) async => streamReply('wrong'),
    );
    llm.transport = fake;
    final RunCancellation token = RunCancellation()..cancel();
    final ModelRequestScope scope = ModelRequestScope(root);
    await expectLater(
      token.run(() => scope.run(chat)),
      throwsA(isA<Cancelled>()),
    );
    expect(fake.calls, 0);
    expect(hasUnsettledModelRequests(root), isFalse);
  });

  test('paid gateway error disposes its response and never replays', () async {
    bool disposed = false;
    final StreamController<List<int>> body = StreamController<List<int>>(
      onCancel: () => disposed = true,
    );
    final FixtureTransport fake = FixtureTransport(
      (_) async => llm.ChatResponse(504, 'application/json', body.stream),
    );
    llm.transport = fake;
    final ModelRequestScope scope = ModelRequestScope(root);
    await expectLater(
      scope.run(
        () => jev.jevUncached('fixture', <String, Object?>{
          'q': <String, Object?>{
            'criteria': <String, Object?>{'yes': 'yes', 'no': 'no'},
          },
        }, retries: 6),
      ),
      throwsA(isA<llm.UnknownOutcomeLLMError>()),
    );
    expect(fake.calls, 1);
    expect(disposed, isTrue);
    expect(scope.hasUnknown, isTrue);
    await body.close();
  });

  test(
    'paid response processing failure becomes unknown without a retry',
    () async {
      final FixtureTransport fake = FixtureTransport(
        (_) async => llm.ChatResponse(
          200,
          'application/json',
          Stream<List<int>>.error(StateError('fixture stream broke')),
        ),
      );
      llm.transport = fake;
      final ModelRequestScope scope = ModelRequestScope(root);
      await expectLater(
        scope.run(
          () => jev.jevUncached('fixture', <String, Object?>{
            'q': <String, Object?>{
              'criteria': <String, Object?>{'yes': 'yes', 'no': 'no'},
            },
          }, retries: 6),
        ),
        throwsA(
          isA<llm.UnknownOutcomeLLMError>().having(
            (e) => e.code,
            'code',
            'response_interrupted',
          ),
        ),
      );
      expect(fake.calls, 1);
      expect(scope.hasUnknown, isTrue);
    },
  );

  for (final String route in <String>['paid', 'model']) {
    test('$route judge never replays an ambiguous paid request', () async {
      environ['JEV_ROUTE'] = route;
      environ['JUDGE_MODEL'] = 'fixture';
      final FixtureTransport fake = FixtureTransport(
        (_) async => throw const SocketException('fixture disconnect'),
      );
      llm.transport = fake;
      final ModelRequestScope scope = ModelRequestScope(root);
      await expectLater(
        scope.run(
          () => jev.jevUncached('fixture', <String, Object?>{
            'q': <String, Object?>{
              'criteria': <String, Object?>{'yes': 'yes', 'no': 'no'},
            },
          }, retries: 6),
        ),
        throwsA(isA<llm.UnknownOutcomeLLMError>()),
      );
      expect(fake.calls, 1);
      expect(scope.hasUnknown, isTrue);
    });
  }
}
