import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/llm.dart' as llm;
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/pipeline/request_lifecycle.dart';

import '../support/request_fixture.dart';

class Transport implements llm.ChatTransport {
  final requests = <llm.ChatRequest>[];
  late Future<llm.ChatResponse> Function(llm.ChatRequest) reply;
  @override
  Future<llm.ChatResponse> post(llm.ChatRequest request, Duration timeout) {
    requests.add(request);
    return reply(request);
  }
}

void main() {
  late llm.ChatTransport old;
  late Map<String, String> saved;
  late Directory root;
  late Transport transport;
  setUp(() {
    old = llm.transport;
    saved = Map.of(environ);
    environ.addAll({
      'LLM_API_KEY': 'fixture',
      'LLM_BASE_URL': 'https://fixture.invalid/v1',
    });
    root = Directory.systemTemp.createTempSync('retained-chat-');
    transport = Transport();
    llm.transport = transport;
  });
  tearDown(() {
    llm.transport = old;
    environ
      ..clear()
      ..addAll(saved);
    root.deleteSync(recursive: true);
  });

  test(
    'book completion survives lost and truncated result reads with one inference',
    () async {
      int polls = 0;
      transport.reply = (request) async {
        if (request.method == 'POST') {
          expect(request.headers['Prefer'], 'respond-async');
          return const llm.ChatResponse(
            202,
            'application/json',
            Stream.empty(),
            headers: {
              'preference-applied': 'respond-async',
              'location': '/v1/chat/completions?job=fixture',
            },
          );
        }
        expect(request.headers['Authorization'], 'Bearer fixture');
        if (++polls == 1) throw const HttpException('lost connection');
        if (polls == 2) {
          return llm.ChatResponse(
            200,
            'application/json',
            Stream.error(const HttpException('truncated result')),
          );
        }
        final body =
            await streamReply('完整人物资料').body.transform(utf8.decoder).join();
        return llm.ChatResponse(
          200,
          'application/json',
          Stream.value(
            utf8.encode(
              jsonEncode({
                'status': 200,
                'content_type': 'text/event-stream',
                'body': body,
              }),
            ),
          ),
        );
      };
      final scope = ModelRequestScope(root);
      final answer = await scope.run(
        () => llm.chat('fixture', const [
          {'role': 'user', 'content': 'synthetic'},
        ]),
      );
      expect(answer.text, '完整人物资料');
      expect(transport.requests.where((r) => r.method == 'POST').length, 1);
      expect(polls, 3);
      scope.settle(receivedCommitted: true);
      expect(hasUnsettledModelRequests(root), isFalse);
    },
  );

  test(
    'accepted result outlives the live-stream deadline without becoming unknown',
    () async {
      // The first scheduled result read is two seconds after acceptance.
      // A suspended phone has the same ordering: dispatch deadline first,
      // then the saved response. Never settle unknown before that safe read.
      environ['LLM_WALL_TIMEOUT'] = '0.1';
      final body =
          await streamReply('保存的人物小传').body.transform(utf8.decoder).join();
      transport.reply = (request) async {
        if (request.method == 'POST') {
          return const llm.ChatResponse(
            202,
            'application/json',
            Stream.empty(),
            headers: {
              'preference-applied': 'respond-async',
              'location': '/v1/chat/completions?job=retained',
            },
          );
        }
        return llm.ChatResponse(
          200,
          'application/json',
          Stream.value(
            utf8.encode(
              jsonEncode({
                'status': 200,
                'content_type': 'text/event-stream',
                'body': body,
              }),
            ),
          ),
        );
      };
      final scope = ModelRequestScope(root);
      final answer = await scope.run(() => llm.chat('fixture', const []));
      expect(answer.text, '保存的人物小传');
      expect(transport.requests.map((r) => r.method), ['POST', 'GET']);
      expect(scope.hasUnknown, isFalse);
      scope.settle(receivedCommitted: true);
      expect(hasUnsettledModelRequests(root), isFalse);
    },
  );

  test(
    'result reads back off through a long outage and recover one job',
    () async {
      final oldSleep = llm.sleep;
      final waits = <Duration>[];
      llm.sleep = (delay) async {
        waits.add(delay);
      };
      addTearDown(() {
        llm.sleep = oldSleep;
      });
      int polls = 0;
      final body =
          await streamReply('恢复的小传').body.transform(utf8.decoder).join();
      transport.reply = (request) async {
        if (request.method == 'POST') {
          return const llm.ChatResponse(
            202,
            'application/json',
            Stream.empty(),
            headers: {
              'preference-applied': 'respond-async',
              'location': '/v1/chat/completions?job=outage',
            },
          );
        }
        if (++polls <= 70) {
          if (polls.isEven) throw const SocketException('offline');
          return const llm.ChatResponse(
            503,
            'application/json',
            Stream.empty(),
          );
        }
        return llm.ChatResponse(
          200,
          'application/json',
          Stream.value(
            utf8.encode(
              jsonEncode({
                'status': 200,
                'content_type': 'text/event-stream',
                'body': body,
              }),
            ),
          ),
        );
      };
      final answer = await ModelRequestScope(
        root,
      ).run(() => llm.chat('fixture', const []));
      expect(answer.text, '恢复的小传');
      expect(transport.requests.where((r) => r.method == 'POST').length, 1);
      expect(waits.take(7).map((d) => d.inSeconds), [2, 4, 8, 16, 32, 60, 60]);
      expect(waits.fold<int>(0, (n, d) => n + d.inSeconds), greaterThan(3600));
      expect(waits.every((d) => d <= const Duration(minutes: 1)), isTrue);
    },
  );

  test(
    'gateway 404 retries the saved job and healthy pending resets backoff',
    () async {
      final oldSleep = llm.sleep;
      final waits = <Duration>[];
      llm.sleep = (delay) async {
        waits.add(delay);
      };
      addTearDown(() {
        llm.sleep = oldSleep;
      });
      final statuses = [404, 503, 202, 503, 200];
      transport.reply = (request) async {
        final status = statuses.removeAt(0);
        return llm.ChatResponse(
          status,
          'application/json',
          status == 200
              ? Stream.value(utf8.encode('{}'))
              : const Stream.empty(),
        );
      };
      await llm.pollRetainedResult(
        Uri.parse('https://fixture.invalid/v1'),
        const llm.ChatResponse(
          202,
          'application/json',
          Stream.empty(),
          headers: {
            'preference-applied': 'respond-async',
            'location': '/v1/result',
          },
        ),
        {},
        null,
      );
      expect(waits.map((d) => d.inSeconds), [2, 4, 8, 2, 4]);
    },
  );

  test(
    'unreachable saved result stops at two hours without new inference',
    () async {
      final oldSleep = llm.sleep;
      Duration waited = Duration.zero;
      llm.sleep = (delay) async {
        waited += delay;
      };
      addTearDown(() {
        llm.sleep = oldSleep;
      });
      transport.reply = (request) async {
        throw const SocketException('offline');
      };
      await expectLater(
        llm.pollRetainedResult(
          Uri.parse('https://fixture.invalid/v1'),
          const llm.ChatResponse(
            202,
            'application/json',
            Stream.empty(),
            headers: {
              'preference-applied': 'respond-async',
              'location': '/v1/result',
            },
          ),
          {},
          null,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(waited.inSeconds, closeTo(7200, 1));
      expect(transport.requests.every((r) => r.method == 'GET'), isTrue);
    },
  );

  test(
    'phone model slot waits for a saved result before the next inference',
    () async {
      environ['LLM_MAX_CONCURRENT'] = '1';
      final oldSleep = llm.sleep;
      llm.sleep = (_) async {};
      addTearDown(() {
        llm.sleep = oldSleep;
      });
      final entered = Completer<void>();
      final release = Completer<void>();
      int posts = 0;
      final body =
          await streamReply('serial').body.transform(utf8.decoder).join();
      transport.reply = (request) async {
        if (request.method == 'POST') {
          posts++;
          return const llm.ChatResponse(
            202,
            'application/json',
            Stream.empty(),
            headers: {
              'preference-applied': 'respond-async',
              'location': '/v1/result',
            },
          );
        }
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
        return llm.ChatResponse(
          200,
          'application/json',
          Stream.value(
            utf8.encode(
              jsonEncode({
                'status': 200,
                'content_type': 'text/event-stream',
                'body': body,
              }),
            ),
          ),
        );
      };
      final scope = ModelRequestScope(root);
      final first = scope.run(() => llm.chat('fixture', const []));
      await entered.future;
      final second = scope.run(() => llm.chat('fixture', const []));
      await Future<void>.delayed(Duration.zero);
      expect(posts, 1);
      release.complete();
      final results = await Future.wait([first, second]);
      expect(results.map((r) => r.text), ['serial', 'serial']);
      expect(posts, 2);
    },
  );

  test(
    'interactive calls keep ordinary live streaming without async opt in',
    () async {
      transport.reply = (request) async {
        expect(request.headers.containsKey('Prefer'), isFalse);
        return streamReply('interactive');
      };
      expect((await llm.chat('fixture', const [])).text, 'interactive');
      expect(transport.requests.length, 1);
    },
  );
}
