/// Streaming chat clients for OpenAI-compatible, Anthropic and Gemini APIs
/// (`pipeline/llm.py`), with the same retries and reader-facing errors.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../env.dart';
import '../errors.dart';
import '../py/py_json_decode.dart';
import '../py/py_re.dart';

/// `pipeline.llm.LLMError` (a `RuntimeError`).
base class LLMError extends RuntimeError {
  const LLMError(super.message);

  @override
  String get pyType => 'pipeline.llm.LLMError';
}

/// A request budget ran out (`DeadlineExceeded`).
final class DeadlineExceeded extends LLMError {
  const DeadlineExceeded(super.message);
}

String get gateway => environ['LLM_BASE_URL'] ?? 'https://api.deepseek.com/v1';

Map<String, String>? _envCache;

/// `_env`: the process environment, then SECRETS_FILE and ~/.env.
String? llmEnv(String name) {
  final String? direct = environ[name];
  // Native settings explicitly own these clears. Legacy environment-only
  // clients retain their established empty-value fallback behavior.
  final bool settingsClear =
      environ['LLM_SETTINGS_AUTHORITY'] == '1' &&
      const <String>{
        'LLM_PROTOCOL_MAP',
        'LLM_KEY_MAP',
        'LLM_API_KEY',
      }.contains(name);
  if (direct != null && (direct.isNotEmpty || settingsClear)) return direct;
  _envCache ??= _readEnvFiles();
  return _envCache![name];
}

/// Forget cached secrets after settings change (`apply_environment`).
void resetEnvCache() => _envCache = null;

final RegExp _envLine = RegExp(
  r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$',
);

Map<String, String> _readEnvFiles() {
  final Map<String, String> cache = <String, String>{};
  final String? home = environ['HOME'];
  for (final String? f in <String?>[
    environ['SECRETS_FILE'],
    if (home != null) '$home/.env',
  ]) {
    if (f == null || f.isEmpty || !File(f).existsSync()) continue;
    for (final String line in File(f).readAsLinesSync()) {
      final RegExpMatch? m = _envLine.firstMatch(line);
      if (m == null || cache.containsKey(m.group(1))) continue;
      String v = m.group(2)!;
      if (v.length >= 2 &&
          (v[0] == '"' || v[0] == "'") &&
          v[v.length - 1] == v[0]) {
        v = v.substring(1, v.length - 1);
      }
      cache[m.group(1)!] = v;
    }
  }
  return cache;
}

const Map<int, String> _fatal = <int, String>{
  401: 'API 密钥无效或已失效（HTTP 401），请到「模型设置」检查密钥',
  402: '模型账户余额不足（HTTP 402），请充值后再继续',
  403: '接口拒绝访问（HTTP 403），请检查密钥权限或接口地址',
  404: '接口地址或模型名不对（HTTP 404），请到「模型设置」检查',
};

final RegExp _httpError = RegExp(r'HTTP (\d{3}): ?([\s\S]*)');

List<String> _secretVariants(Iterable<String> secrets) {
  final Set<String> variants = <String>{};
  for (final String secret in secrets) {
    if (secret.isEmpty) continue;
    final String encoded = jsonEncode(secret);
    variants.addAll(<String>[
      secret,
      encoded.substring(1, encoded.length - 1),
      Uri.encodeComponent(secret),
    ]);
  }
  final List<String> ordered =
      variants.toList()
        ..sort((String a, String b) => b.length.compareTo(a.length));
  return ordered;
}

/// Remove request credentials before provider diagnostics reach UI or job logs.
String redactSecrets(String text, Iterable<String> secrets) {
  for (final String secret in _secretVariants(secrets)) {
    text = text.replaceAll(secret, '[REDACTED]');
  }
  return text;
}

/// A reader-facing reason when retrying cannot help, or null.
String? explain(Object error) {
  final String text = error is PyException ? error.message : '$error';
  if (text.contains('缺少模型访问密钥')) return '还没有填写模型 API 密钥，请先到「模型设置」填写';
  if (text.contains('NOT_API:')) {
    return '模型接口地址不对：它返回的是网页，不是模型接口。多数接口地址以 /v1 结尾，例如 https://api.deepseek.com/v1，请到「模型设置」检查';
  }
  if (text.contains('THINKING_ONLY:')) {
    return '模型只“思考”没给正文。DeepSeek 请在模型名后加 +nothink（例如 deepseek-flash+nothink），请到「模型设置」修改';
  }
  final RegExpMatch? m = _httpError.firstMatch(text);
  if (m == null) return null;
  final int code = int.parse(m.group(1)!);
  String detail = m.group(2)!.trim();
  try {
    final Object? body = jsonDecode(detail);
    if (body is Map<String, Object?>) {
      final Object? e = body['error'];
      final Object? msg = e is Map<String, Object?> ? e['message'] : e;
      if (msg != null && msg != '' && msg != false) detail = '$msg';
    }
  } on FormatException {
    // Not JSON: keep the raw text.
  }
  if (detail.runes.length > 160)
    detail = String.fromCharCodes(detail.runes.take(160));
  final String? fatal = _fatal[code];
  if (fatal != null) return detail.isNotEmpty ? '$fatal。接口返回：$detail' : fatal;
  if (code == 400 || code == 422)
    return '接口不接受这个请求（HTTP $code），多半是模型名不对。接口返回：$detail';
  return null;
}

const Map<String, String> _defaultBase = <String, String>{
  'anthropic': 'https://api.anthropic.com/v1',
  'gemini': 'https://generativelanguage.googleapis.com/v1beta',
  'ollama': 'http://localhost:11434/v1',
};

String protocolFor(String model) {
  for (final String rule in (llmEnv('LLM_PROTOCOL_MAP') ?? '').split(',')) {
    final int i = rule.trim().indexOf('=');
    if (i <= 0) continue;
    final String prefix = rule.trim().substring(0, i);
    final String proto = rule.trim().substring(i + 1);
    if (proto.isNotEmpty && model.startsWith(prefix)) return proto;
  }
  return llmEnv('LLM_PROTOCOL') ?? 'openai';
}

String baseFor(String protocol) =>
    llmEnv('LLM_BASE_URL_${protocol.toUpperCase()}') ??
    (protocol == 'openai' ? llmEnv('LLM_BASE_URL') : null) ??
    _defaultBase[protocol] ??
    gateway;

/// Which secret to send for a model (`key_for`).
String? keyFor(String model) {
  for (final String rule in (llmEnv('LLM_KEY_MAP') ?? '').split(',')) {
    final int i = rule.trim().indexOf('=');
    if (i <= 0) continue;
    final String prefix = rule.trim().substring(0, i);
    final String name = rule.trim().substring(i + 1);
    if (name.isNotEmpty && model.startsWith(prefix)) return llmEnv(name);
  }
  final String keyName = environ['LLM_KEY_NAME'] ?? '';
  return (keyName.isEmpty ? null : llmEnv(keyName)) ?? llmEnv('LLM_API_KEY');
}

/// One prepared HTTP request.
final class ChatRequest {
  const ChatRequest(this.url, this.headers, this.body);

  final Uri url;
  final Map<String, String> headers;
  final String body;
}

/// Explicit endpoint for a connection probe without changing active settings.
class ChatEndpoint {
  const ChatEndpoint({
    required this.protocol,
    required this.baseUrl,
    required this.apiKey,
  });
  final String protocol;
  final String baseUrl;
  final String apiKey;
}

ChatRequest buildRequest(
  String protocol,
  String model,
  List<Map<String, String>> messages,
  String key,
  int maxTokens,
  double temperature,
  String variant, {
  String? baseUrl,
}) {
  String base = baseUrl ?? baseFor(protocol);
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  final String system = <String>[
    for (final Map<String, String> m in messages)
      if (m['role'] == 'system') m['content']!,
  ].join('\n\n');
  final List<Map<String, String>> rest = <Map<String, String>>[
    for (final Map<String, String> m in messages)
      if (m['role'] != 'system') m,
  ];
  final Map<String, String> headers = <String, String>{
    'Content-Type': 'application/json',
    'Accept': 'text/event-stream',
  };
  final String url;
  final Map<String, Object?> body;
  if (protocol == 'anthropic') {
    url = '$base/messages';
    body = <String, Object?>{
      'model': model,
      'max_tokens': maxTokens,
      'temperature': temperature,
      'stream': true,
      'messages': rest,
      if (system.isNotEmpty) 'system': system,
    };
    headers
      ..['x-api-key'] = key
      ..['anthropic-version'] = '2023-06-01'
      ..['anthropic-dangerous-direct-browser-access'] = 'true';
  } else if (protocol == 'gemini') {
    final String resource =
        model.startsWith('models/') ? model : 'models/$model';
    url = '$base/$resource:streamGenerateContent?alt=sse';
    body = <String, Object?>{
      'contents': <Object?>[
        for (final Map<String, String> m in rest)
          <String, Object?>{
            'role': m['role'] == 'assistant' ? 'model' : 'user',
            'parts': <Object?>[
              <String, Object?>{'text': m['content']},
            ],
          },
      ],
      'generationConfig': <String, Object?>{
        'maxOutputTokens': maxTokens,
        'temperature': temperature,
      },
      if (system.isNotEmpty)
        'systemInstruction': <String, Object?>{
          'parts': <Object?>[
            <String, Object?>{'text': system},
          ],
        },
    };
    headers['x-goog-api-key'] = key;
  } else {
    url = '$base/chat/completions';
    body = <String, Object?>{
      'model': model,
      'messages': messages,
      'max_tokens': maxTokens,
      'temperature': temperature,
      'stream': true,
      'stream_options': <String, Object?>{'include_usage': true},
      if (variant == 'think' || variant == 'nothink')
        'thinking': <String, Object?>{
          'type': variant == 'think' ? 'enabled' : 'disabled',
        },
    };
    headers['Authorization'] = 'Bearer $key';
  }
  return ChatRequest(Uri.parse(url), headers, jsonEncode(body));
}

/// Text of one streamed event; [usage] is filled in place (`_delta`).
String delta(
  String protocol,
  Map<String, Object?> ev,
  Map<String, Object?> usage,
) {
  Map<String, Object?> obj(Object? v) =>
      v is Map<String, Object?> ? v : const <String, Object?>{};
  List<Object?> list(Object? v) => v is List<Object?> ? v : const <Object?>[];
  if (protocol == 'anthropic') {
    if (ev['type'] == 'message_start') {
      usage['prompt_tokens'] =
          obj(obj(ev['message'])['usage'])['input_tokens'] ?? 0;
    }
    if (ev['type'] == 'message_delta') {
      usage['completion_tokens'] =
          obj(ev['usage'])['output_tokens'] ?? usage['completion_tokens'] ?? 0;
    }
    return ev['type'] == 'content_block_delta'
        ? '${obj(ev['delta'])['text'] ?? ''}'
        : '';
  }
  if (protocol == 'gemini') {
    final Map<String, Object?> um = obj(ev['usageMetadata']);
    if (um.isNotEmpty) {
      usage['prompt_tokens'] = um['promptTokenCount'] ?? 0;
      usage['completion_tokens'] = um['candidatesTokenCount'] ?? 0;
    }
    final StringBuffer out = StringBuffer();
    for (final Object? c in list(ev['candidates'])) {
      for (final Object? part in list(obj(obj(c)['content'])['parts'])) {
        // Gemini marks optional thought summaries separately from the answer.
        // They must not contaminate the engine's JSON or reader-facing output.
        if (obj(part)['thought'] == true) continue;
        final Object? text = obj(part)['text'];
        if (text is String && text.isNotEmpty) out.write(text);
      }
    }
    return out.toString();
  }
  final Map<String, Object?> u = obj(ev['usage']);
  if (u.isNotEmpty) {
    usage['prompt_tokens'] = u['prompt_tokens'] ?? 0;
    usage['completion_tokens'] = u['completion_tokens'] ?? 0;
  }
  final StringBuffer out = StringBuffer();
  for (final Object? ch in list(ev['choices'])) {
    final Map<String, Object?> d = obj(obj(ch)['delta']);
    final Object? reasoning = d['reasoning_content'];
    if (reasoning is String && reasoning.isNotEmpty) {
      usage['_reasoning'] = ((usage['_reasoning'] as int?) ?? 0) + 1;
    }
    final Object? content = d['content'];
    if (content is String) out.write(content);
  }
  return out.toString();
}

/// How the client reaches the network; tests replace it with a cassette.
abstract interface class ChatTransport {
  Future<ChatResponse> post(ChatRequest request, Duration timeout);
}

/// Status, content type and a byte stream of the body.
final class ChatResponse {
  const ChatResponse(
    this.status,
    this.contentType,
    this.body, {
    this.headers = const <String, String>{},
  });

  final int status;
  final String contentType;
  final Stream<List<int>> body;

  /// Response headers that matter to retries, e.g. `Retry-After`.
  final Map<String, String> headers;
}

/// `dart:io` transport honouring system proxies like urllib does.
final class IoTransport implements ChatTransport {
  IoTransport([HttpClient? client])
    : _client =
          client ??
          (HttpClient()..findProxy = HttpClient.findProxyFromEnvironment);

  final HttpClient _client;

  @override
  Future<ChatResponse> post(ChatRequest request, Duration timeout) async {
    final HttpClientRequest req = await _client
        .postUrl(request.url)
        .timeout(timeout);
    request.headers.forEach(req.headers.set);
    req.add(utf8.encode(request.body));
    final HttpClientResponse resp = await req.close().timeout(timeout);
    final String? retry = resp.headers.value('retry-after');
    return ChatResponse(
      resp.statusCode,
      resp.headers.contentType?.toString() ?? '',
      resp.timeout(timeout),
      headers: <String, String>{if (retry != null) 'Retry-After': retry},
    );
  }
}

ChatTransport transport = IoTransport();

/// Injected wait for retries; tests make it instant.
Future<void> Function(Duration) sleep = Future<void>.delayed;
math.Random random = math.Random();

final Map<String, List<double>> _replySeconds = <String, List<double>>{};

double stallTimeout(String model) {
  final String? fixed = environ['LLM_TIMEOUT'];
  if (fixed != null && fixed.isNotEmpty) return double.parse(fixed);
  final List<double> seen = _replySeconds[model] ?? const <double>[];
  if (seen.length < 3) return 300.0;
  return math.min(600.0, math.max(90.0, 3 * seen.reduce(math.max)));
}

/// The reply text and token usage of one chat.
final class ChatResult {
  const ChatResult(this.text, this.usage);

  final String text;
  final Map<String, Object?> usage;
}

/// Streamed chat completion in any supported protocol (`chat`).
Future<ChatResult> chat(
  String fullModel,
  List<Map<String, String>> messages, {
  int maxTokens = 8000,
  double temperature = 0.2,
  double? timeout,
  int? retries,
  String? keyName,
  void Function(String partial)? onText,
  ChatEndpoint? endpoint,
}) async {
  final bool adaptive = timeout == null;
  final double wait = timeout ?? stallTimeout(fullModel);
  final int tries = retries ?? int.parse(environ['LLM_RETRIES'] ?? '4');
  final int plus = fullModel.indexOf('+');
  final String model = plus < 0 ? fullModel : fullModel.substring(0, plus);
  final String variant = plus < 0 ? '' : fullModel.substring(plus + 1);
  final String? key =
      endpoint?.apiKey ?? (keyName != null ? llmEnv(keyName) : keyFor(model));
  if (key == null || key.isEmpty) throw const LLMError('缺少模型访问密钥');
  final String protocol = endpoint?.protocol ?? protocolFor(model);
  final String baseUrl = endpoint?.baseUrl ?? baseFor(protocol);
  Object? last;
  for (int attempt = 0; attempt <= tries; attempt++) {
    try {
      final ChatRequest req = buildRequest(
        protocol,
        model,
        messages,
        key,
        maxTokens,
        temperature,
        variant,
        baseUrl: baseUrl,
      );
      final Stopwatch clock = Stopwatch()..start();
      double? first;
      final ChatResponse resp = await transport.post(
        req,
        Duration(milliseconds: (wait * 1000).round()),
      );
      if (resp.status >= 400) {
        final List<int> raw = <int>[];
        // Include enough of a credential crossing the diagnostic boundary to
        // redact it before truncation, including JSON/URL-escaped variants.
        final int readLimit =
            400 +
            _secretVariants(<String>[key]).fold<int>(
              0,
              (int longest, String variant) =>
                  math.max(longest, utf8.encode(variant).length),
            );
        await for (final List<int> chunk in resp.body) {
          raw.addAll(chunk);
          if (raw.length >= readLimit) break;
        }
        final String safe = redactSecrets(
          utf8.decode(raw.take(readLimit).toList(), allowMalformed: true),
          <String>[key],
        );
        final String detail = String.fromCharCodes(safe.runes.take(400));
        final LLMError e = LLMError('HTTP ${resp.status}: $detail');
        if (const <int>[400, 401, 402, 403, 404, 422].contains(resp.status))
          throw _Fatal(e);
        throw e;
      }
      if (resp.contentType.contains('text/html')) {
        throw LLMError('NOT_API: 接口地址返回的是网页，不是模型接口：${req.url}');
      }
      final StringBuffer parts = StringBuffer();
      final Map<String, Object?> usage = <String, Object?>{};
      bool doneStream = false;
      await for (final String raw in resp.body
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())) {
        if (doneStream) continue;
        final String line = raw.trim();
        if (!line.startsWith('data:')) continue;
        final String data = line.substring(5).trim();
        if (data == '[DONE]') {
          doneStream = true;
          continue;
        }
        final Object? ev;
        try {
          ev = jsonDecode(data);
        } on FormatException {
          continue;
        }
        if (ev is! Map<String, Object?>) continue;
        final String text = delta(protocol, ev, usage);
        if (text.isNotEmpty) {
          first ??= clock.elapsedMilliseconds / 1000;
          parts.write(text);
          onText?.call(parts.toString());
        }
      }
      final String text = parts.toString();
      if (text.trim().isEmpty) {
        if (usage['_reasoning'] != null) {
          throw const LLMError('THINKING_ONLY: 模型把回复额度都用在“思考”上，没有给出正文');
        }
        throw const LLMError('模型返回空内容');
      }
      final double secs = clock.elapsedMilliseconds / 1000;
      final Map<String, Object?> out = <String, Object?>{
        ...usage,
        '_secs': (secs * 100).round() / 100,
        '_ttft': ((first ?? secs) * 100).round() / 100,
      };
      if (adaptive) {
        final List<double> seen = _replySeconds.putIfAbsent(
          fullModel,
          () => <double>[],
        )..add(secs);
        if (seen.length > 20) seen.removeAt(0);
      }
      return ChatResult(text, out);
    } on _Fatal catch (f) {
      throw f.error;
    } on DeadlineExceeded catch (e) {
      throw DeadlineExceeded(redactSecrets(e.message, <String>[key]));
    } on LLMError catch (e) {
      last = e;
    } on TimeoutException catch (e) {
      last = e;
    } on SocketException catch (e) {
      last = e;
    } on HttpException catch (e) {
      last = e;
    } on HandshakeException catch (e) {
      last = e;
    } on Object catch (error) {
      final String message = error is PyException ? error.message : '$error';
      final String safe = redactSecrets(message, <String>[key]);
      if (safe != message) throw LLMError(safe);
      rethrow;
    }
    if (attempt < tries) {
      await sleep(
        Duration(
          milliseconds:
              ((math.min(60, 3 * math.pow(2, attempt)) +
                          random.nextDouble() * 2) *
                      1000)
                  .round(),
        ),
      );
    }
  }
  throw LLMError(
    redactSecrets(
      '模型调用失败：${last is PyException ? last.message : last}',
      <String>[key],
    ),
  );
}

final class _Fatal implements Exception {
  const _Fatal(this.error);

  final LLMError error;
}

final RegExp _trailingComma = pyRe(r',\s*([}\]])');

/// Escape stray double quotes inside strings and drop trailing commas.
String repairJson(String s) {
  final StringBuffer out = StringBuffer();
  bool inStr = false;
  bool esc = false;
  final int n = s.length;
  bool ws(String c) => c == ' ' || c == '\t' || c == '\r' || c == '\n';
  for (int i = 0; i < n; i++) {
    final String ch = s[i];
    if (inStr) {
      if (esc) {
        esc = false;
      } else if (ch == r'\') {
        esc = true;
      } else if (ch == '"') {
        int j = i + 1;
        while (j < n && ws(s[j])) {
          j++;
        }
        bool closes = j >= n || '}]'.contains(s[j]);
        if (j < n && ',:'.contains(s[j])) {
          int k = j + 1;
          while (k < n && ws(s[k])) {
            k++;
          }
          closes = k >= n || '"{[-0123456789tfn]}'.contains(s[k]);
        }
        if (!closes) {
          out.write(r'\"');
          continue;
        }
        inStr = false;
      } else if (ch == '\n') {
        out.write(r'\n');
        continue;
      }
    } else if (ch == '"') {
      inStr = true;
    }
    out.write(ch);
  }
  return pySub(_trailingComma, out.toString(), r'\1');
}

final RegExp _fence = pyRe(r'```(?:json)?\s*(.*?)```', dotAll: true);

/// The first JSON object in a model reply (tolerates ```json fences).
Object? parseJson(String reply) {
  String text = reply;
  final RegExpMatch? m = pySearch(_fence, text);
  if (m != null) text = m.group(1)!;
  final int start = text.indexOf('{');
  final int end = text.lastIndexOf('}');
  if (start < 0 || end < 0) throw const ValueError('回复里没有 JSON');
  final String body = end + 1 > start ? text.substring(start, end + 1) : '';
  try {
    return pyJsonLoads(body);
  } on PyJsonDecodeError {
    return pyJsonLoads(repairJson(body));
  }
}

/// Parse a chat reply, asking for one repair if needed (`chat_json`).
/// The Python oracle returns first-request usage even after a repair.
Future<(Object?, Map<String, Object?>)> chatJson(
  String model,
  List<Map<String, String>> messages, {
  int maxTokens = 8000,
  double temperature = 0.2,
  double? timeout,
  int? retries,
  String? keyName,
  void Function(String partial)? onText,
}) async {
  Future<ChatResult> request(List<Map<String, String>> input) => chat(
    model,
    input,
    maxTokens: maxTokens,
    temperature: temperature,
    timeout: timeout,
    retries: retries,
    keyName: keyName,
    onText: onText,
  );
  final ChatResult first = await request(messages);
  try {
    return (parseJson(first.text), first.usage);
  } on ValueError {
    final ChatResult repaired = await request(<Map<String, String>>[
      ...messages,
      <String, String>{'role': 'assistant', 'content': first.text},
      <String, String>{
        'role': 'user',
        'content': '上面的输出不是合法 JSON。请只输出修正后的完整 JSON，不要任何解释。',
      },
    ]);
    return (parseJson(repaired.text), first.usage);
  }
}
