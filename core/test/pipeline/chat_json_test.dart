import 'dart:convert';

import 'package:test/test.dart';
import 'package:thusfar_core/llm.dart';
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/errors.dart';

typedef Json = Map<String, Object?>;

class Replies implements ChatTransport {
  Replies(this.texts);
  final List<String> texts;
  final List<Json> requests = <Json>[];

  @override
  Future<ChatResponse> post(ChatRequest request, Duration timeout) async {
    requests.add(jsonDecode(request.body) as Json);
    final int index = requests.length - 1;
    final Json event = <String, Object?>{
      'choices': <Json>[
        <String, Object?>{
          'delta': <String, Object?>{'content': texts[index]},
        },
      ],
      'usage': <String, Object?>{
        'prompt_tokens': index + 10,
        'completion_tokens': index + 20,
      },
    };
    return ChatResponse(
      200,
      'text/event-stream',
      Stream<List<int>>.value(
        utf8.encode('data: ${jsonEncode(event)}\n\ndata: [DONE]\n\n'),
      ),
    );
  }
}

void main() {
  late ChatTransport saved;
  late Map<String, String> savedEnv;
  setUp(() {
    saved = transport;
    savedEnv = Map<String, String>.of(environ);
    environ
      ..clear()
      ..addAll(<String, String>{
        'LLM_API_KEY': 'offline-test',
        'LLM_BASE_URL': 'https://offline.invalid/v1',
      });
  });
  tearDown(() {
    transport = saved;
    environ
      ..clear()
      ..addAll(savedEnv);
  });

  test(
    'valid reply takes one request and preserves prompt and parameters',
    () async {
      final Replies replies = Replies(<String>['{"value":"𠮷🙂"}']);
      transport = replies;
      final (Object? data, Json usage) = await chatJson(
        'test+nothink',
        <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'question'},
        ],
        maxTokens: 123,
        temperature: 0,
        retries: 0,
      );
      expect(data, <String, Object?>{'value': '𠮷🙂'});
      expect(usage['prompt_tokens'], 10);
      expect(replies.requests.length, 1);
      expect(replies.requests.single['max_tokens'], 123);
      expect(replies.requests.single['temperature'], 0);
    },
  );

  test(
    'one repair retains Python chat_json first-request usage semantics',
    () async {
      final Replies replies = Replies(<String>['not JSON', '{"ok":true}']);
      transport = replies;
      final List<Map<String, String>> messages = <Map<String, String>>[
        <String, String>{'role': 'user', 'content': 'question'},
      ];
      final (Object? data, Json usage) = await chatJson(
        'test',
        messages,
        retries: 0,
        maxTokens: 123,
      );
      expect(data, <String, Object?>{'ok': true});
      expect(usage['prompt_tokens'], 10);
      expect(usage['completion_tokens'], 20);
      expect(
        messages.length,
        1,
        reason: 'repair must not mutate caller conversation',
      );
      expect(replies.requests.length, 2);
      expect(replies.requests[1]['messages'], <Map<String, String>>[
        ...messages,
        <String, String>{'role': 'assistant', 'content': 'not JSON'},
        <String, String>{
          'role': 'user',
          'content': '上面的输出不是合法 JSON。请只输出修正后的完整 JSON，不要任何解释。',
        },
      ]);
      expect(replies.requests[1]['max_tokens'], 123);
    },
  );

  test('failed repair raises without a third model request', () async {
    final Replies replies = Replies(<String>['not JSON', 'still not JSON']);
    transport = replies;
    await expectLater(
      chatJson('test', <Map<String, String>>[], retries: 0),
      throwsA(isA<ValueError>()),
    );
    expect(replies.requests.length, 2);
  });
}
