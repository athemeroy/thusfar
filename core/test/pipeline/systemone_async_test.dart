import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/llm.dart' as llm;
import 'package:thusfar_core/src/pipeline/jev.dart' as judge;
import 'package:thusfar_core/src/pipeline/request_lifecycle.dart';
import 'package:thusfar_core/src/pipeline/run_lease.dart';

class Fixture implements llm.ChatTransport {
  final List<llm.ChatRequest> requests = [];
  late Future<llm.ChatResponse> Function(llm.ChatRequest) respond;
  @override
  Future<llm.ChatResponse> post(llm.ChatRequest request, Duration timeout) {
    requests.add(request);
    return respond(request);
  }
}

llm.ChatResponse accepted({String location = '/judge?job=fixture'}) =>
    llm.ChatResponse(
      202,
      'application/json',
      const Stream.empty(),
      headers: {'location': location, 'preference-applied': 'respond-async'},
    );

llm.ChatResponse answer() => llm.ChatResponse(
  200,
  'application/json',
  Stream.value(
    utf8.encode(
      jsonEncode({
        'answers': {
          'q': {
            'type': 'choice',
            'choice': 'yes',
            'probabilities': {'yes': 0.9, 'no': 0.1},
          },
        },
      }),
    ),
  ),
);

void main() {
  late llm.ChatTransport old;
  late Future<void> Function(Duration) oldSleep;
  late Fixture fixture;
  late Directory root;
  late ModelRequestScope scope;
  Future<judge.Json> run() => scope.run(
    () => judge.systemOneJudge(
      'fixture',
      {
        'q': {
          'type': 'choice',
          'instructions': 'Supported?',
          'criteria': {'yes': 'Supported', 'no': 'Not supported'},
        },
      },
      endpoint: 'https://judge.invalid/judge',
      apiKey: 'test-key',
    ),
  );

  setUp(() {
    old = llm.transport;
    oldSleep = llm.sleep;
    fixture = Fixture();
    llm.transport = fixture;
    llm.sleep = (_) async {};
    root = Directory.systemTemp.createTempSync('async-judge-');
    scope = ModelRequestScope(root);
  });
  tearDown(() {
    llm.transport = old;
    llm.sleep = oldSleep;
    root.deleteSync(recursive: true);
  });

  test(
    'dropped polls and a truncated result recover without resubmitting inference',
    () async {
      int polls = 0;
      fixture.respond = (request) async {
        if (request.method == 'POST') return accepted();
        expect(request.headers['Authorization'], 'Bearer test-key');
        switch (++polls) {
          case 1:
            throw const SocketException('fixture disconnect');
          case 2:
            return llm.ChatResponse(
              200,
              'application/json',
              Stream.error(const HttpException('fixture truncated body')),
            );
          case 3:
            return const llm.ChatResponse(
              202,
              'application/json',
              Stream.empty(),
            );
          default:
            return answer();
        }
      };
      expect((await run())['q'], isNotNull);
      expect(fixture.requests.where((r) => r.method == 'POST').length, 1);
      expect(polls, 4);
      expect(scope.hasUnknown, isFalse);
      scope.settle(receivedCommitted: true);
      expect(hasUnsettledModelRequests(root), isFalse);
    },
  );

  test('result URL cannot send the key to another origin', () async {
    fixture.respond =
        (_) async => accepted(location: 'https://foreign.invalid/result');
    await expectLater(run(), throwsA(isA<llm.UnknownOutcomeLLMError>()));
    expect(fixture.requests.length, 1);
  });

  test('an uncertain initial POST is never automatically replayed', () async {
    fixture.respond = (_) async => throw const HttpException('lost acceptance');
    await expectLater(run(), throwsA(isA<llm.UnknownOutcomeLLMError>()));
    expect(fixture.requests.length, 1);
    expect(scope.hasUnknown, isTrue);
  });

  test(
    'a connection that never sent the judge request remains retryable',
    () async {
      fixture.respond =
          (_) async => throw const llm.ConnectionNotSent(HandshakeException());
      await expectLater(run(), throwsA(isA<llm.ConnectionNotSent>()));
      expect(scope.hasUnknown, isFalse);
      expect(hasUnsettledModelRequests(root), isFalse);
    },
  );

  test('an expired job does not trigger another inference', () async {
    fixture.respond =
        (r) async =>
            r.method == 'POST'
                ? accepted()
                : const llm.ChatResponse(
                  410,
                  'application/json',
                  Stream.empty(),
                );
    await expectLater(run(), throwsA(isA<llm.UnknownOutcomeLLMError>()));
    expect(fixture.requests.map((r) => r.method), ['POST', 'GET']);
  });

  test(
    'explicit pause cancels polling promptly and sends no more requests',
    () async {
      final RunCancellation cancellation = RunCancellation();
      final Completer<void> polling = Completer();
      final Completer<llm.ChatResponse> response = Completer();
      fixture.respond = (r) async {
        if (r.method == 'POST') return accepted();
        polling.complete();
        return response.future;
      };
      final Future<void> assertion = expectLater(
        cancellation.run(run),
        throwsA(isA<Cancelled>()),
      );
      await polling.future;
      cancellation.cancel(reason: 'user');
      await assertion;
      response.complete(answer());
      await Future<void>.delayed(Duration.zero);
      expect(fixture.requests.length, 2);
    },
  );
}
