import 'dart:async';
import 'dart:convert';

import 'package:thusfar_core/llm.dart' as llm;

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
