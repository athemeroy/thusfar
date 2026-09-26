import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/llm.dart' as llm;
import 'package:thusfar_core/model_settings.dart';
import 'package:thusfar_core/thusfar_core.dart' show environ, ValueError;

typedef Json = Map<String, Object?>;

final class ProtocolTransport implements llm.ChatTransport {
  ProtocolTransport(this.protocol);
  final String protocol;
  final List<llm.ChatRequest> requests = <llm.ChatRequest>[];
  @override
  Future<llm.ChatResponse> post(
    llm.ChatRequest request,
    Duration timeout,
  ) async {
    requests.add(request);
    final List<Json> events = switch (protocol) {
      'anthropic' => <Json>[
        <String, Object?>{
          'type': 'message_start',
          'message': <String, Object?>{
            'usage': <String, Object?>{'input_tokens': 3},
          },
        },
        <String, Object?>{
          'type': 'content_block_delta',
          'delta': <String, Object?>{'type': 'text_delta', 'text': '可以'},
        },
        <String, Object?>{
          'type': 'message_delta',
          'usage': <String, Object?>{'output_tokens': 2},
        },
      ],
      'gemini' => <Json>[
        <String, Object?>{
          'candidates': <Object?>[
            <String, Object?>{
              'content': <String, Object?>{
                'parts': <Object?>[
                  <String, Object?>{'text': '可以'},
                ],
              },
            },
          ],
          'usageMetadata': <String, Object?>{
            'promptTokenCount': 3,
            'candidatesTokenCount': 2,
          },
        },
      ],
      _ => <Json>[
        <String, Object?>{
          'choices': <Object?>[
            <String, Object?>{
              'delta': <String, Object?>{'content': '可以'},
            },
          ],
          'usage': <String, Object?>{
            'prompt_tokens': 3,
            'completion_tokens': 2,
          },
        },
      ],
    };
    return llm.ChatResponse(
      200,
      'text/event-stream',
      Stream<List<int>>.value(
        utf8.encode(
          '${events.map((Json e) => 'data: ${jsonEncode(e)}\n\n').join()}data: [DONE]\n\n',
        ),
      ),
    );
  }
}

final class CallbackTransport implements llm.ChatTransport {
  CallbackTransport(this.reply);
  final Future<llm.ChatResponse> Function(llm.ChatRequest) reply;
  @override
  Future<llm.ChatResponse> post(llm.ChatRequest request, Duration timeout) =>
      reply(request);
}

void main() {
  late Directory root;
  late ModelSettings settings;
  late Map<String, String> savedEnv;
  late llm.ChatTransport savedTransport;
  setUp(() {
    root = Directory.systemTemp.createTempSync('thusfar-settings-');
    settings = ModelSettings(File('${root.path}/.model.env'));
    savedEnv = Map<String, String>.of(environ);
    savedTransport = llm.transport;
    environ.clear();
    llm.resetEnvCache();
  });
  tearDown(() {
    llm.transport = savedTransport;
    environ
      ..clear()
      ..addAll(savedEnv);
    llm.resetEnvCache();
    root.deleteSync(recursive: true);
  });

  test(
    'unsaved probe uses the form and preserves active settings and file',
    () async {
      settings.save(<String, Object?>{
        'base_url': 'https://saved.invalid/v1',
        'model': 'saved',
        'api_key': 'saved-fixture-key',
      });
      final String bytes = settings.file.readAsStringSync();
      final Map<String, String> environment = Map<String, String>.of(environ);
      final ProtocolTransport transport = ProtocolTransport('gemini');
      llm.transport = transport;
      expect(
        (await settings.test(
          payload: <String, Object?>{
            'protocol': 'gemini',
            'base_url': 'https://draft.invalid/v1beta',
            'model': 'draft',
            'api_key': 'draft-fixture-key',
          },
        ))['ok'],
        true,
      );
      expect(transport.requests.single.url.host, 'draft.invalid');
      expect(
        transport.requests.single.url.path,
        '/v1beta/models/draft:streamGenerateContent',
      );
      expect(
        transport.requests.single.headers['x-goog-api-key'],
        'draft-fixture-key',
      );
      expect(settings.file.readAsStringSync(), bytes);
      expect(environ, environment);
      await expectLater(
        settings.test(
          payload: <String, Object?>{
            'base_url': 'https://elsewhere.invalid/v1',
            'api_key': '',
          },
        ),
        throwsA(isA<ValueError>()),
      );
      expect(transport.requests.length, 1);
    },
  );

  test('unconfigured defaults expose only the three requested protocols', () {
    expect(ModelSettings.protocolLabels.values, <String>[
      'OpenAI Compatible',
      'Gemini',
      'Claude Compatible',
    ]);
    expect(settings.read()['protocol'], 'openai');
    expect(settings.read()['base_url'], 'https://api.openai.com/v1');
    expect(settings.read()['model'], '');
    expect(settings.public()['api_key_set'], false);
    expect(settings.public().containsKey('api_key'), false);
    expect(settings.file.existsSync(), false);
  });

  test(
    'legacy empty environment values retain file fallback without settings authority',
    () {
      final File legacy = File('${root.path}/legacy.env')
        ..writeAsStringSync('LLM_API_KEY=legacy-offline-key\n');
      environ['SECRETS_FILE'] = legacy.path;
      environ['LLM_API_KEY'] = '';
      expect(llm.llmEnv('LLM_API_KEY'), 'legacy-offline-key');
    },
  );

  for (final String protocol in ModelSettings.protocolLabels.keys) {
    test(
      '$protocol custom endpoint is used by actual chat/test requests',
      () async {
        final Directory home = Directory('${root.path}/home')..createSync();
        environ['HOME'] = home.path;
        File('${home.path}/.env').writeAsStringSync(
          'LLM_PROTOCOL_MAP=fixture=${protocol == 'anthropic' ? 'gemini' : 'anthropic'}\n'
          'LLM_KEY_MAP=fixture=UNRELATED_KEY\n'
          'UNRELATED_KEY=unrelated-home-secret\n',
        );
        environ.addAll(<String, String>{
          'LLM_PROTOCOL_MAP': 'fixture=wrong',
          'LLM_KEY_MAP': 'fixture=WRONG_KEY',
          'LLM_KEY_NAME': 'WRONG_KEY',
          'WRONG_KEY': 'wrong-offline-secret',
          'LLM_BASE_URL_ANTHROPIC': 'https://wrong.invalid/v1',
          'LLM_BASE_URL_GEMINI': 'https://wrong.invalid/v1beta',
        });
        final Json result = settings.save(<String, Object?>{
          'protocol': protocol,
          'base_url': 'https://custom.invalid/proxy',
          'model': 'fixture-model',
          'api_key': 'offline-test-secret',
        });
        expect(result['protocol'], protocol);
        expect(result.containsKey('api_key'), false);
        expect(result['api_key_last4'], 'cret');
        final ProtocolTransport transport = ProtocolTransport(protocol);
        llm.transport = transport;
        expect((await settings.test())['ok'], true);
        await llm.chat('fixture-model', <Map<String, String>>[
          <String, String>{'role': 'user', 'content': 'offline routing check'},
        ], retries: 0);
        expect(transport.requests, hasLength(2));
        expect(transport.requests.last.url, transport.requests.first.url);
        expect(
          transport.requests.last.headers,
          transport.requests.first.headers,
        );
        final llm.ChatRequest request = transport.requests.last;
        expect(request.url.host, 'custom.invalid');
        final Json body = jsonDecode(request.body) as Json;
        switch (protocol) {
          case 'gemini':
            expect(
              request.url.path,
              '/proxy/models/fixture-model:streamGenerateContent',
            );
            expect(request.url.queryParameters, <String, String>{'alt': 'sse'});
            expect(request.headers['x-goog-api-key'], 'offline-test-secret');
            expect(body['contents'], isA<List<Object?>>());
          case 'anthropic':
            expect(request.url.path, '/proxy/messages');
            expect(request.headers['x-api-key'], 'offline-test-secret');
            expect(request.headers['anthropic-version'], '2023-06-01');
            expect(body['model'], 'fixture-model');
          case 'openai':
            expect(request.url.path, '/proxy/chat/completions');
            expect(
              request.headers['Authorization'],
              'Bearer offline-test-secret',
            );
            expect(body['model'], 'fixture-model');
        }
        expect(request.url.toString(), isNot(contains('offline-test-secret')));
        expect(body['stream'] ?? protocol == 'gemini', true);
        if (!Platform.isWindows)
          expect(settings.file.statSync().mode & 511, 384);
        expect(root.listSync().whereType<File>().length, 1);
      },
    );
  }

  test(
    'legacy custom OpenAI settings retain user endpoint and normalize model',
    () {
      settings.file.writeAsStringSync(
        'LLM_BASE_URL=https://custom.invalid\nEXTRACT_MODEL=deepseek-test\nLLM_API_KEY=offline-legacy\nJEV_ROUTE=free-only\n',
      );
      expect(settings.read()['base_url'], 'https://custom.invalid/v1');
      expect(settings.read()['model'], 'deepseek-test+nothink');
      expect(settings.read()['protocol'], 'openai');
      expect(settings.public()['api_key_last4'], 'gacy');
      settings.save(<String, Object?>{'model': 'replacement'});
      expect(settings.read()['api_key'], 'offline-legacy');
      expect(settings.read()['base_url'], 'https://custom.invalid/v1');
    },
  );

  test('switching endpoint or protocol cannot send the previous saved key', () {
    settings.save(<String, Object?>{
      'base_url': 'https://one.invalid/v1',
      'model': 'fixture',
      'api_key': 'offline-old-key',
    });
    final String original = settings.file.readAsStringSync();
    for (final Json update in <Json>[
      <String, Object?>{'protocol': 'gemini'},
      <String, Object?>{'base_url': 'https://two.invalid/v1'},
    ]) {
      expect(() => settings.save(update), throwsA(isA<ValueError>()));
      expect(settings.file.readAsStringSync(), original);
    }
    settings.save(<String, Object?>{
      'protocol': 'gemini',
      'base_url': 'https://two.invalid',
      'api_key': 'offline-new-key',
    });
    expect(settings.read()['base_url'], 'https://two.invalid/v1beta');
    expect(environ['LLM_BASE_URL_GEMINI'], 'https://two.invalid/v1beta');
    expect(environ['LLM_API_KEY'], 'offline-new-key');
    settings.save(<String, Object?>{'clear_key': true});
    expect(environ['LLM_API_KEY'], '');
    expect(settings.public()['api_key_set'], false);
  });

  test('invalid settings do not write a file or affect runtime', () {
    for (final Json change in <Json>[
      <String, Object?>{'protocol': 'relay'},
      <String, Object?>{'base_url': 'http://example.invalid/v1'},
      <String, Object?>{'base_url': 'https://user:pass@example.invalid'},
      <String, Object?>{'base_url': 'https://example.invalid?api_key=test'},
      <String, Object?>{'base_url': 'https://example.invalid/#fragment'},
      <String, Object?>{'base_url': 'https://example.invalid\nLLM_API_KEY=x'},
      <String, Object?>{'model': ''},
      <String, Object?>{'api_key': 'line\nbreak'},
      <String, Object?>{'clear_key': 1},
      <String, Object?>{'clear_key': true, 'api_key': 'offline-test'},
    ]) {
      expect(
        () => settings.save(<String, Object?>{'model': 'fixture', ...change}),
        throwsA(isA<ValueError>()),
      );
      expect(settings.file.existsSync(), false);
      expect(environ, isEmpty);
    }
  });

  test('missing key never makes a request', () async {
    final ProtocolTransport transport = ProtocolTransport('openai');
    llm.transport = transport;
    expect((await settings.test())['ok'], false);
    expect(transport.requests, isEmpty);
  });

  test(
    'explicit key clear cannot revive HOME credentials or route maps',
    () async {
      final Directory home = Directory('${root.path}/home')..createSync();
      environ['HOME'] = home.path;
      File('${home.path}/.env').writeAsStringSync(
        'LLM_API_KEY=unrelated-home-secret\n'
        'LLM_KEY_MAP=fixture=UNRELATED_KEY\n'
        'UNRELATED_KEY=unrelated-mapped-secret\n',
      );
      settings.save(<String, Object?>{
        'model': 'fixture',
        'api_key': 'saved-fixture-key',
      });
      settings.save(<String, Object?>{'clear_key': true});
      final ProtocolTransport transport = ProtocolTransport('openai');
      llm.transport = transport;
      expect(llm.llmEnv('LLM_API_KEY'), '');
      expect(llm.keyFor('fixture'), '');
      await expectLater(
        llm.chat('fixture', <Map<String, String>>[], retries: 0),
        throwsA(
          isA<llm.LLMError>().having(
            (e) => e.message,
            'message',
            contains('缺少模型访问密钥'),
          ),
        ),
      );
      expect((await settings.test())['ok'], false);
      expect(transport.requests, isEmpty);
    },
  );

  for (final String protocol in ModelSettings.protocolLabels.keys) {
    test(
      '$protocol provider errors redact draft and normal request keys',
      () async {
        const String savedKey = 'offline/saved-"key?=+';
        const String draftKey = 'offline/draft-"key?=+';
        settings.save(<String, Object?>{
          'protocol': protocol,
          'model': 'fixture',
          'api_key': savedKey,
        });
        final String bytes = settings.file.readAsStringSync();
        final Map<String, String> environment = Map<String, String>.of(environ);
        llm.transport = CallbackTransport((llm.ChatRequest request) async {
          final String key =
              request.headers['x-api-key'] ??
              request.headers['x-goog-api-key'] ??
              request.headers['Authorization']!.substring(7);
          return llm.ChatResponse(
            401,
            'application/json',
            Stream<List<int>>.value(
              utf8.encode(
                jsonEncode(<String, Object?>{
                  'error': <String, Object?>{
                    'message':
                        'Invalid credential $key, encoded ${Uri.encodeComponent(key)}',
                  },
                }),
              ),
            ),
          );
        });
        final Json result = await settings.test(
          payload: <String, Object?>{
            'base_url': 'https://draft.invalid/proxy',
            'api_key': draftKey,
          },
        );
        expect(result['ok'], false);
        expect(result['message'], contains('HTTP 401'));
        expect(result['message'], contains('[REDACTED]'));
        expect(result['message'], isNot(contains(draftKey)));
        expect(
          result['message'],
          isNot(contains(Uri.encodeComponent(draftKey))),
        );
        expect(settings.file.readAsStringSync(), bytes);
        expect(environ, environment);
        await expectLater(
          llm.chat('fixture', <Map<String, String>>[], retries: 0),
          throwsA(
            isA<llm.LLMError>().having(
              (e) => e.message,
              'redacted message',
              allOf(
                contains('[REDACTED]'),
                isNot(contains(savedKey)),
                isNot(contains(Uri.encodeComponent(savedKey))),
              ),
            ),
          ),
        );
      },
    );
  }

  test('errors redact credentials before diagnostic truncation', () async {
    const String key = 'boundary-secret-with-a-long-distinct-suffix';
    settings.save(<String, Object?>{'model': 'fixture', 'api_key': key});
    llm.transport = CallbackTransport(
      (_) async => llm.ChatResponse(
        401,
        'text/plain',
        Stream<List<int>>.fromIterable(
          utf8
              .encode('${'x' * 390}$key rejected')
              .map((int byte) => <int>[byte]),
        ),
      ),
    );
    await expectLater(
      llm.chat('fixture', <Map<String, String>>[], retries: 0),
      throwsA(
        isA<llm.LLMError>().having(
          (e) => e.message,
          'redacted boundary',
          allOf(contains('[REDACTED]'), isNot(contains('boundary-secret'))),
        ),
      ),
    );
  });

  test(
    'legacy URI-escaped Unicode key is redacted across the read boundary',
    () async {
      final String key = '密钥' * 20;
      environ['LLM_API_KEY'] = key;
      llm.transport = CallbackTransport(
        (_) async => llm.ChatResponse(
          401,
          'text/plain',
          Stream<List<int>>.fromIterable(
            utf8
                .encode('${'x' * 390}${Uri.encodeComponent(key)} rejected')
                .map((int byte) => <int>[byte]),
          ),
        ),
      );
      await expectLater(
        llm.chat('fixture', <Map<String, String>>[], retries: 0),
        throwsA(
          isA<llm.LLMError>().having(
            (e) => e.message,
            'redacted Unicode boundary',
            allOf(contains('[REDACTED]'), isNot(contains('%E'))),
          ),
        ),
      );
    },
  );

  test(
    'probe success redacts echoed credentials before shortening reply',
    () async {
      const String key = 'success-secret-longer-than-twenty-characters';
      settings.save(<String, Object?>{'model': 'fixture', 'api_key': key});
      llm.transport = CallbackTransport(
        (_) async => llm.ChatResponse(
          200,
          'text/event-stream',
          Stream<List<int>>.value(
            utf8.encode(
              'data: ${jsonEncode(<String, Object?>{
                'choices': <Object?>[
                  <String, Object?>{
                    'delta': <String, Object?>{'content': key},
                  },
                ],
              })}\n\ndata: [DONE]\n\n',
            ),
          ),
        ),
      );
      final Json result = await settings.test();
      expect(result['ok'], true);
      expect(result['message'], contains('[REDACTED]'));
      expect(result['message'], isNot(contains('success-secret')));
    },
  );

  for (final String kind in <String>['http', 'deadline', 'unexpected']) {
    test('$kind transport exception cannot publish a credential', () async {
      const String key = 'offline-exception-secret';
      settings.save(<String, Object?>{'model': 'fixture', 'api_key': key});
      llm.transport = CallbackTransport((_) async {
        switch (kind) {
          case 'http':
            throw const HttpException('failed with $key');
          case 'deadline':
            throw const llm.DeadlineExceeded('timed out with $key');
          default:
            throw StateError('transport failed with $key');
        }
      });
      await expectLater(
        llm.chat('fixture', <Map<String, String>>[], retries: 0),
        throwsA(
          isA<llm.LLMError>().having(
            (e) => e.message,
            'message',
            allOf(contains('[REDACTED]'), isNot(contains(key))),
          ),
        ),
      );
      final Json result = await settings.test();
      expect(result['ok'], false);
      expect(result['message'], contains('[REDACTED]'));
      expect(result['message'], isNot(contains(key)));
    });
  }

  test('Gemini model resource and thought parts are handled independently', () {
    environ['LLM_BASE_URL_GEMINI'] = 'https://custom.invalid/v1beta';
    final llm.ChatRequest request = llm.buildRequest(
      'gemini',
      'models/fixture',
      <Map<String, String>>[
        <String, String>{'role': 'user', 'content': 'question'},
      ],
      'offline-key',
      16,
      0,
      '',
    );
    expect(request.url.path, '/v1beta/models/fixture:streamGenerateContent');
    final Json usage = <String, Object?>{};
    expect(
      llm.delta('gemini', <String, Object?>{
        'candidates': <Object?>[
          <String, Object?>{
            'content': <String, Object?>{
              'parts': <Object?>[
                <String, Object?>{'thought': true, 'text': 'Reasoning summary'},
                <String, Object?>{'text': '{"answer":"verified"}'},
              ],
            },
          },
        ],
      }, usage),
      '{"answer":"verified"}',
    );
  });
}
