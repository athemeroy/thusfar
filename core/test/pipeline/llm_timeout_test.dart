import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/llm.dart' as llm;
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/errors.dart';

class TrickleTransport implements llm.ChatTransport {
  TrickleTransport() {
    body = StreamController<List<int>>(
      onListen: () {
        void sendEvent() {
          eventsSent++;
          body.add(
            utf8.encode('data: {"choices":[{"delta":{"content":"x"}}]}\n\n'),
          );
        }

        // Seed several events synchronously; loaded full-suite runs can delay
        // the first periodic tick beyond the intentionally short wall limit.
        sendEvent();
        sendEvent();
        ticker = Timer.periodic(
          const Duration(milliseconds: 10),
          (_) => sendEvent(),
        );
      },
      onCancel: () {
        ticker.cancel();
        cancelled = true;
      },
    );
  }

  late final StreamController<List<int>> body;
  late Timer ticker;
  int eventsSent = 0;
  int requests = 0;
  bool cancelled = false;

  @override
  Future<llm.ChatResponse> post(
    llm.ChatRequest request,
    Duration timeout,
  ) async {
    requests++;
    return llm.ChatResponse(200, 'text/event-stream', body.stream);
  }
}

void main() {
  late llm.ChatTransport savedTransport;
  late Map<String, String> savedEnv;

  setUp(() {
    savedTransport = llm.transport;
    savedEnv = Map<String, String>.of(environ);
    environ
      ..clear()
      ..addAll(<String, String>{
        'LLM_API_KEY': 'offline-test',
        'LLM_BASE_URL': 'https://offline.invalid/v1',
        'LLM_WALL_TIMEOUT': '0.12',
      });
  });

  tearDown(() {
    llm.transport = savedTransport;
    environ
      ..clear()
      ..addAll(savedEnv);
  });

  test(
    'whole-request deadline stops a stream that keeps sending tokens',
    () async {
      final TrickleTransport fake = TrickleTransport();
      llm.transport = fake;
      int partials = 0;
      final Stopwatch clock = Stopwatch()..start();

      await expectLater(
        llm.chat(
          'fixture',
          <Map<String, String>>[
            <String, String>{'role': 'user', 'content': 'offline test'},
          ],
          timeout: 1,
          retries: 0,
          onText: (_) => partials++,
        ),
        throwsA(
          isA<llm.LLMError>().having(
            (llm.LLMError e) => e.message,
            'message',
            contains('TimeoutException'),
          ),
        ),
      );
      clock.stop();

      expect(fake.requests, 1);
      expect(fake.eventsSent, greaterThan(1));
      expect(partials, greaterThan(0));
      expect(
        fake.cancelled,
        isTrue,
        reason: 'timed-out stream must be cancelled',
      );
      expect(
        clock.elapsed,
        lessThan(const Duration(seconds: 1)),
        reason: 'frequent tokens must not reset the whole-request deadline',
      );
    },
  );

  test('transient failures are retried, configuration failures are not', () {
    for (final Object failure in <Object>[
      const llm.DeadlineExceeded('model wait ended'),
      TimeoutException('slow response'),
      const SocketException('Connection refused'),
      const HttpException('connection reset'),
      const llm.LLMError('HTTP 429: rate limited'),
      const llm.LLMError('HTTP 503: unavailable'),
      const llm.LLMError('模型调用失败：TimeoutException: no data'),
      const llm.TransientLLMError('模型调用失败：连接中断'),
    ]) {
      expect(llm.transientFailure(failure), isTrue, reason: '$failure');
    }
    for (final Object failure in <Object>[
      const llm.LLMError('HTTP 400: unsupported parameter'),
      const llm.LLMError('HTTP 401: invalid key'),
      const llm.LLMError('HTTP 404: unknown model'),
      const llm.LLMError('NOT_API: HTML response'),
      const llm.LLMError('模型返回空内容'),
      const ValueError('正文里出现 timeout 字样'),
      const ValueError('正文里出现 HTTP 503 字样'),
    ]) {
      expect(llm.transientFailure(failure), isFalse, reason: '$failure');
    }
  });
}
