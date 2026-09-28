// Browser model transport shared by preparation and Ask. Credentials are sent
// only as request headers and are never persisted or included in errors.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'web_storage.dart';

enum WebModelProtocol {
  openai,
  gemini,
  anthropic;

  static WebModelProtocol fromName(String? name, String endpoint) {
    for (final WebModelProtocol value in values) {
      if (value.name == name) return value;
    }
    final Uri? uri = Uri.tryParse(endpoint);
    if (uri?.host == 'api.anthropic.com') return anthropic;
    if (uri?.host == 'generativelanguage.googleapis.com' &&
        !(uri?.pathSegments.contains('openai') ?? false)) {
      return gemini;
    }
    // Older Web checkpoints used Gemini's OpenAI-compatible endpoint.
    return openai;
  }
}

class WebModelPreset {
  const WebModelPreset(
    this.id,
    this.label,
    this.protocol,
    this.endpoint,
    this.model,
  );

  final String id;
  final String label;
  final WebModelProtocol protocol;
  final String endpoint;
  final String model;

  static const List<WebModelPreset> all = <WebModelPreset>[
    WebModelPreset(
      'deepseek',
      'DeepSeek',
      WebModelProtocol.openai,
      'https://api.deepseek.com/v1',
      'deepseek-flash',
    ),
    WebModelPreset(
      'siliconflow',
      'SiliconFlow 硅基',
      WebModelProtocol.openai,
      'https://api.siliconflow.cn/v1',
      'deepseek-ai/DeepSeek-V3',
    ),
    WebModelPreset(
      'openai',
      'OpenAI',
      WebModelProtocol.openai,
      'https://api.openai.com/v1',
      'gpt-4o-mini',
    ),
    WebModelPreset(
      'claude',
      'Claude',
      WebModelProtocol.anthropic,
      'https://api.anthropic.com/v1',
      'claude-haiku-4-5-20251001',
    ),
    WebModelPreset(
      'gemini',
      'Google Gemini',
      WebModelProtocol.gemini,
      'https://generativelanguage.googleapis.com/v1beta',
      'gemini-3.5-flash-lite',
    ),
    WebModelPreset(
      'ollama',
      'Ollama 本地',
      WebModelProtocol.openai,
      'http://localhost:11434/v1',
      'qwen2.5:7b',
    ),
  ];

  static WebModelPreset? matching(
    WebModelProtocol protocol,
    String endpoint,
    String model,
  ) {
    for (final WebModelPreset preset in all) {
      final String address = endpoint.trim().replaceFirst(RegExp(r'/$'), '');
      final bool sameEndpoint =
          preset.endpoint == address ||
          (preset.id == 'deepseek' && address == 'https://api.deepseek.com');
      if (preset.protocol == protocol &&
          sameEndpoint &&
          preset.model == model.trim()) {
        return preset;
      }
    }
    return null;
  }
}

class WebModelException implements Exception {
  const WebModelException(this.message);
  final String message;

  @override
  String toString() => message;
}

class WebModelRequest {
  const WebModelRequest(this.uri, this.headers, this.body);
  final Uri uri;
  final Map<String, String> headers;
  final Json body;
}

class WebModelProvider {
  WebModelProvider._();

  static final RegExp _modelName = RegExp(
    r'^[A-Za-z0-9][A-Za-z0-9._/+:-]{0,99}$',
  );

  static Uri validateBase(String endpoint) {
    if (endpoint.length > 2048) {
      throw const WebModelException('模型 API 地址过长。');
    }
    final Uri? uri = Uri.tryParse(endpoint.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path.contains('://')) {
      throw const WebModelException('模型 API 地址无效，请填写不含账号、参数和片段的地址。');
    }
    final bool local = _loopback(uri);
    if (uri.scheme != 'https' && !(local && uri.scheme == 'http')) {
      throw const WebModelException('模型地址须使用 HTTPS；本机 localhost 可用 HTTP。');
    }
    return uri;
  }

  static void validateModel(String model) {
    if (!_modelName.hasMatch(model.trim())) {
      throw const WebModelException('模型名称无效。');
    }
  }

  static bool allowsEmptyKey(WebModelProtocol protocol, String endpoint) {
    final Uri? uri = Uri.tryParse(endpoint.trim());
    return protocol == WebModelProtocol.openai && uri != null && _loopback(uri);
  }

  static bool _loopback(Uri uri) => const <String>{
    'localhost',
    '127.0.0.1',
    '::1',
  }.contains(uri.host.toLowerCase());

  static WebModelRequest build({
    required WebModelProtocol protocol,
    required String endpoint,
    required String model,
    required String apiKey,
    required String system,
    required String user,
    required int maxOutputTokens,
    bool jsonOutput = true,
  }) {
    final Uri base = validateBase(endpoint);
    final String name = model.trim();
    validateModel(name);
    final int plus = name.indexOf('+');
    final String requestModel = plus < 0 ? name : name.substring(0, plus);
    final String variant = plus < 0 ? '' : name.substring(plus + 1);
    final String key = apiKey.trim();
    if (key.isEmpty && !allowsEmptyKey(protocol, endpoint)) {
      throw const WebModelException('请填写自己的模型 API 密钥。');
    }
    final Map<String, String> headers = <String, String>{
      'Content-Type': 'application/json',
    };
    final List<String> path = base.pathSegments
        .where((String segment) => segment.isNotEmpty)
        .toList();
    final Uri uri;
    final Json body;
    switch (protocol) {
      case WebModelProtocol.openai:
        if (!(path.length >= 2 &&
            path[path.length - 2] == 'chat' &&
            path.last == 'completions')) {
          path.addAll(const <String>['chat', 'completions']);
        }
        uri = base.replace(pathSegments: path);
        body = <String, Object?>{
          'model': requestModel,
          'stream': false,
          'max_tokens': maxOutputTokens,
          'messages': <Json>[
            <String, Object?>{'role': 'system', 'content': system},
            <String, Object?>{'role': 'user', 'content': user},
          ],
          if (variant == 'think' || variant == 'nothink')
            'thinking': <String, String>{
              'type': variant == 'think' ? 'enabled' : 'disabled',
            },
          if (base.host == 'api.deepseek.com') ...<String, Object?>{
            if (jsonOutput)
              'response_format': <String, String>{'type': 'json_object'},
          },
        };
        if (key.isNotEmpty) headers['Authorization'] = 'Bearer $key';
        break;
      case WebModelProtocol.gemini:
        final String resource = requestModel.startsWith('models/')
            ? requestModel.substring('models/'.length)
            : requestModel;
        final List<String> resourceSegments = resource.split('/');
        if (resource.isEmpty ||
            resourceSegments.any(
              (String part) => part.isEmpty || part == '..',
            )) {
          throw const WebModelException('Gemini 模型名称无效。');
        }
        // The native Gemini protocol uses streamGenerateContent. The reader
        // consumes a full response, so generateContent avoids SSE buffering
        // while keeping the same native request and response schema.
        uri = base.replace(
          pathSegments: <String>[
            ...path,
            'models',
            ...resourceSegments.take(resourceSegments.length - 1),
            '${resourceSegments.last}:generateContent',
          ],
        );
        body = <String, Object?>{
          'contents': <Json>[
            <String, Object?>{
              'role': 'user',
              'parts': <Json>[
                <String, Object?>{'text': user},
              ],
            },
          ],
          'systemInstruction': <String, Object?>{
            'parts': <Json>[
              <String, Object?>{'text': system},
            ],
          },
          'generationConfig': <String, Object?>{
            'maxOutputTokens': maxOutputTokens,
            if (jsonOutput) 'responseMimeType': 'application/json',
          },
        };
        headers['x-goog-api-key'] = key;
        break;
      case WebModelProtocol.anthropic:
        if (path.isEmpty || path.last != 'messages') path.add('messages');
        uri = base.replace(pathSegments: path);
        body = <String, Object?>{
          'model': requestModel,
          'max_tokens': maxOutputTokens,
          'stream': false,
          'system': system,
          'messages': <Json>[
            <String, Object?>{'role': 'user', 'content': user},
          ],
        };
        headers
          ..['x-api-key'] = key
          ..['anthropic-version'] = '2023-06-01'
          // Claude's official API requires this opt-in for browser CORS.
          ..['anthropic-dangerous-direct-browser-access'] = 'true';
        break;
    }
    return WebModelRequest(uri, headers, body);
  }

  static Future<String> post(
    WebModelRequest spec, {
    required WebModelProtocol protocol,
    void Function(html.HttpRequest request)? onRequest,
  }) {
    final Completer<String> result = Completer<String>();
    final html.HttpRequest request = html.HttpRequest();
    void fail(String message) {
      if (!result.isCompleted) result.completeError(WebModelException(message));
    }

    request.onLoad.listen((_) {
      if (result.isCompleted) return;
      int status = 0;
      try {
        status = request.status ?? 0;
        if (status >= 200 && status < 300) {
          final String? response = request.responseText;
          if (response == null ||
              response.isEmpty ||
              response.length > 512 * 1024) {
            fail('模型返回了空响应或过长响应。');
          } else {
            result.complete(_normalize(protocol, response));
          }
        } else if (status == 401 || status == 403) {
          fail('模型密钥无效或没有此模型的访问权限（HTTP $status）。');
        } else if (status == 402) {
          fail('模型账户余额不足或需要开通计费（HTTP 402）。');
        } else if (status == 429) {
          fail('模型请求过于频繁或额度已用尽（HTTP 429）。');
        } else if (status >= 500) {
          fail('模型服务暂时不可用（HTTP $status）。');
        } else {
          fail('模型请求失败（HTTP $status），请检查协议、地址、模型和账户权限。');
        }
      } on WebModelException catch (error) {
        fail(
          status >= 200 && status < 300
              ? '${error.message} 请求已到达服务商，可能已计费。'
              : error.message,
        );
      } on Object {
        fail('模型响应无法解析，请检查所选协议与 API 地址；若请求已到达服务商，可能已计费。');
      }
    });
    request.onError.listen(
      (_) => fail(
        '浏览器无法连接模型：请检查网络，以及服务商是否允许当前网页来源跨域访问。'
        '本机 Ollama 位于当前浏览设备，且需要允许该网页来源。',
      ),
    );
    request.onTimeout.listen((_) => fail('模型请求超过 90 秒；若已到达服务商，仍可能计费。'));
    request.onAbort.listen((_) => fail('模型请求已中止；若已到达服务商，仍可能收费。'));

    try {
      onRequest?.call(request);
      request.open('POST', spec.uri.toString(), async: true);
      request.timeout = 90000;
      request.withCredentials = false;
      for (final MapEntry<String, String> header in spec.headers.entries) {
        request.setRequestHeader(header.key, header.value);
      }
      request.send(jsonEncode(spec.body));
    } on Object {
      fail('无法发起模型请求，请检查地址和浏览器权限。');
    }
    return result.future;
  }

  static String _normalize(WebModelProtocol protocol, String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw const WebModelException('模型接口没有返回 JSON。');
    }
    if (decoded is! Json) {
      throw const WebModelException('模型接口响应格式有误。');
    }
    if (protocol == WebModelProtocol.openai) return raw;

    String content;
    bool truncated;
    int inputTokens;
    int outputTokens;
    if (protocol == WebModelProtocol.gemini) {
      final Object? candidates = decoded['candidates'];
      if (candidates is! List ||
          candidates.isEmpty ||
          candidates.first is! Json) {
        throw const WebModelException('Gemini 没有返回正文；可能受到安全设置限制。');
      }
      final Json candidate = candidates.first as Json;
      final Object? body = candidate['content'];
      final Object? parts = body is Json ? body['parts'] : null;
      if (parts is! List) {
        throw const WebModelException('Gemini 回复缺少正文。');
      }
      content = <String>[
        for (final Object? part in parts)
          if (part is Json && part['thought'] != true && part['text'] is String)
            part['text'] as String,
      ].join();
      truncated = candidate['finishReason'] == 'MAX_TOKENS';
      final Object? usage = decoded['usageMetadata'];
      inputTokens = usage is Json
          ? (usage['promptTokenCount'] as num?)?.toInt() ?? 0
          : 0;
      outputTokens = usage is Json
          ? (usage['candidatesTokenCount'] as num?)?.toInt() ?? 0
          : 0;
    } else {
      final Object? blocks = decoded['content'];
      if (blocks is! List) {
        throw const WebModelException('Claude 回复缺少正文。');
      }
      content = <String>[
        for (final Object? block in blocks)
          if (block is Json &&
              block['type'] == 'text' &&
              block['text'] is String)
            block['text'] as String,
      ].join();
      truncated = decoded['stop_reason'] == 'max_tokens';
      final Object? usage = decoded['usage'];
      inputTokens = usage is Json
          ? (usage['input_tokens'] as num?)?.toInt() ?? 0
          : 0;
      outputTokens = usage is Json
          ? (usage['output_tokens'] as num?)?.toInt() ?? 0
          : 0;
    }
    if (content.trim().isEmpty) {
      throw const WebModelException('模型没有返回可用正文。');
    }
    return jsonEncode(<String, Object?>{
      'choices': <Json>[
        <String, Object?>{
          'finish_reason': truncated ? 'length' : 'stop',
          'message': <String, Object?>{'content': content},
        },
      ],
      'usage': <String, Object?>{
        'prompt_tokens': inputTokens < 0 ? 0 : inputTokens,
        'completion_tokens': outputTokens < 0 ? 0 : outputTokens,
      },
    });
  }
}
