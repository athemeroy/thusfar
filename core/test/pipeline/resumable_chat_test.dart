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
