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
import 'request_diagnostics.dart';
import 'request_lifecycle.dart';
import 'run_lease.dart';

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

/// A provider or transport failure that may recover without changing input.
final class TransientLLMError extends LLMError {
  const TransientLLMError(super.message);
}

/// The connection failed before any HTTP request could be sent.
final class ConnectionNotSent extends LLMError {
  const ConnectionNotSent(this.cause) : super('暂时连不上 AI 服务，正在重新连接');
  final Object cause;
}

/// The provider may have processed a dispatched request. Never retry implicitly.
final class UnknownOutcomeLLMError extends LLMError {
  const UnknownOutcomeLLMError(this.code) : super('没有收到完整结果，整理已暂停。已完成的内容已保留。');
  final String code;
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
        'CLASSIFIER_KEY',
        'JEV_API_KEY',
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
  const ChatRequest(this.url, this.headers, this.body, {this.method = 'POST'});

  final String method;

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
        if (model.toLowerCase().contains('qwen'))
          'chat_template_kwargs': <String, Object?>{
            'enable_thinking': variant == 'think',
          }
        else
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
    this.diagnostics,
  });

  final int status;
  final String contentType;
  final Stream<List<int>> body;

  /// Response headers that matter to retries, e.g. `Retry-After`.
  final Map<String, String> headers;
  final ModelRequestTrace? diagnostics;
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
    final RunCancellation? cancellation = RunCancellation.current;
    cancellation?.checkpoint();
    final ModelRequestTrace? trace = ModelRequestTrace.current;
    HttpClientRequest? active;
    bool opened = false;
    bool abandoned = false;
    final void Function()? remove = cancellation?.onCancel(() {
      abandoned = true;
      if (active != null) trace?.record('abort_requested', code: 'cancelled');
      active?.abort(const Cancelled());
    });
    Future<T> wait<T>(Future<T> operation) =>
        cancellation?.wait(operation) ?? operation;
    try {
      final Future<HttpClientRequest> opening = _client.openUrl(
        request.method,
        request.url,
      );
      // postUrl may settle after the deadline/cancel race. Abort that late
      // socket as well; no request may survive to overlap an explicit resume.
      unawaited(
        opening.then<void>((HttpClientRequest req) {
          active = req;
          if (abandoned) {
            trace?.record('abort_requested', code: 'late_open_abandoned');
            req.abort();
          }
        }, onError: (Object _, StackTrace __) {}),
      );
      final HttpClientRequest req = await wait(opening.timeout(timeout));
      opened = true;
      // Result polling must never forward credentials to a redirect target.
      if (request.method == 'GET') req.followRedirects = false;
      cancellation?.checkpoint();
      request.headers.forEach(req.headers.set);
      trace?.record('send_started');
      req.add(utf8.encode(request.body));
      final HttpClientResponse resp = await wait(req.close().timeout(timeout));
      final String? retry = resp.headers.value('retry-after');
      return ChatResponse(
        resp.statusCode,
        resp.headers.contentType?.toString() ?? '',
        resp.timeout(timeout),
        headers: <String, String>{
          if (retry != null) 'Retry-After': retry,
          for (final String name in ['location', 'preference-applied'])
            if (resp.headers.value(name) case final String value) name: value,
        },
      );
    } on Object catch (error) {
      abandoned = true;
      if (active != null) {
        trace?.record(
          'abort_requested',
          code: ModelRequestTrace.exceptionCode(error),
        );
      }
      active?.abort();
      if (!opened &&
          (error is SocketException ||
              error is HandshakeException ||
              error is TimeoutException)) {
        throw ConnectionNotSent(error);
      }
      rethrow;
    } finally {
      remove?.call();
    }
  }
}

ChatTransport transport = IoTransport();

/// Stop receiving a response immediately. Transport cleanup may complete only
/// after its event loop advances, so it must not extend the request deadline.
Future<void> _cancelResponse<T>(
  StreamIterator<T> iterator, [
  ModelRequestTrace? trace,
]) async {
  trace?.record('body_cancel_requested');
  try {
    await iterator.cancel();
    trace?.record('body_cancelled');
  } on Object catch (error) {
    trace?.record(
      'body_cancel_error',
      code: ModelRequestTrace.exceptionCode(error),
    );
    // The request has already finished or failed; retain that outcome.
  }
}

/// Close a response whose body will not be parsed (e.g. ambiguous gateway errors).
Future<void> discardChatResponse(ChatResponse response) =>
    _disposeResponseBody(response.body, response.diagnostics);

Future<void> _disposeResponseBody(
  Stream<List<int>> body, [
  ModelRequestTrace? trace,
]) async {
  trace?.record('body_cancel_requested');
  try {
    // StreamIterator does not subscribe before moveNext; use a real
    // subscription so an unconsumed late response releases its socket too.
    await body.listen((_) {}, onError: (Object _) {}).cancel();
    trace?.record('body_cancelled');
  } on Object catch (error) {
    trace?.record(
      'body_cancel_error',
      code: ModelRequestTrace.exceptionCode(error),
    );
    // Preserve the already-established request outcome.
  }
}

/// Observe late headers after cancellation/deadline and dispose their body.
/// The native transport also aborts its socket before headers are available.
Future<ChatResponse> postRequest(
  ChatRequest request,
  Duration timeout, {
  ModelRequestTrace? trace,
}) async {
  final RunCancellation? cancellation = RunCancellation.current;
  cancellation?.checkpoint();
  bool abandoned = false;
  ChatResponse? arrived;
  final Future<ChatResponse> pending =
      trace == null
          ? transport.post(request, timeout)
          : trace.run(() => transport.post(request, timeout));
  unawaited(
    pending.then<void>((ChatResponse response) {
      arrived = response;
      trace?.record('headers', httpStatus: response.status);
      if (abandoned) unawaited(_disposeResponseBody(response.body, trace));
    }, onError: (Object _, StackTrace __) {}),
  );
  try {
    final Future<ChatResponse> bounded = pending.timeout(timeout);
    final ChatResponse response =
        await (cancellation?.wait(bounded) ?? bounded);
    if (trace == null) return response;
    return ChatResponse(
      response.status,
      response.contentType,
      response.body.transform(
        StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (List<int> bytes, EventSink<List<int>> sink) {
            trace.bytes(bytes.length);
            sink.add(bytes);
          },
          handleError: (
            Object error,
            StackTrace stack,
            EventSink<List<int>> sink,
          ) {
            trace.record(
              'body_error',
              code: ModelRequestTrace.exceptionCode(error),
            );
            sink.addError(error, stack);
          },
          handleDone: (EventSink<List<int>> sink) {
            trace.record('body_done');
            sink.close();
          },
        ),
      ),
      headers: response.headers,
      diagnostics: trace,
    );
  } on Object catch (error) {
    trace?.record(
      'transport_error',
      code: ModelRequestTrace.exceptionCode(
        error is ConnectionNotSent ? error.cause : error,
      ),
    );
    abandoned = true;
    if (arrived != null) unawaited(_disposeResponseBody(arrived!.body, trace));
    rethrow;
  }
}

/// An explicitly accepted asynchronous job survives a dropped client socket.
/// Only GET is retried; never resubmit an uncertain inference POST.
Future<Object?> pollRetainedResult(
  Uri origin,
  ChatResponse accepted,
  Map<String, String> headers,
  ModelRequestTrace? trace,
) async {
  final String? location = accepted.headers['location'];
  final Uri resultUrl = origin.resolve(location ?? '');
  unawaited(discardChatResponse(accepted));
  if (accepted.headers['preference-applied'] != 'respond-async' ||
      location == null ||
      location.isEmpty ||
      resultUrl.scheme != origin.scheme ||
      resultUrl.host != origin.host ||
      resultUrl.port != origin.port ||
      resultUrl.userInfo.isNotEmpty ||
      resultUrl.fragment.isNotEmpty) {
    throw const LLMError('AI 服务没有返回有效的结果地址');
  }
  final RunCancellation? cancellation = RunCancellation.current;
  Future<T> wait<T>(Future<T> future) => cancellation?.wait(future) ?? future;
  // Android can suspend every thread while an accepted server job completes.
  // Charge scheduled polling and bounded reads, not that suspended wall time.
  // Each read has its own deadline; retries can only fetch the accepted job.
  const Duration interval = Duration(seconds: 2);
  const Duration readLimit = Duration(seconds: 15);
  Duration budget = const Duration(minutes: 10);
  while (budget > Duration.zero) {
    await wait(Future<void>.delayed(interval));
    budget -= interval;
    cancellation?.checkpoint();
    final Stopwatch readClock = Stopwatch()..start();
    Duration readRemaining() {
      final Duration remaining = readLimit - readClock.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('读取保存结果超时');
      }
      return remaining;
    }

    try {
      final ChatResponse response = await wait(
        postRequest(
          ChatRequest(
            resultUrl,
            <String, String>{
              'Accept': 'application/json',
              if (headers['Authorization'] case final String key)
                'Authorization': key,
            },
            '',
            method: 'GET',
          ),
          readLimit,
          trace: trace,
        ),
      );
      if (response.status == 202 ||
          response.status == 408 ||
          response.status == 429 ||
          response.status >= 500) {
        unawaited(discardChatResponse(response));
        continue;
      }
      if (response.status != 200) {
        unawaited(discardChatResponse(response));
        throw LLMError('读取保存的结果失败：HTTP ${response.status}');
      }
      final List<int> bytes = [];
      final StreamIterator<List<int>> chunks = StreamIterator(response.body);
      try {
        while (await wait(chunks.moveNext().timeout(readRemaining()))) {
          bytes.addAll(chunks.current);
          if (bytes.length > 16 * 1024 * 1024) {
            throw const LLMError('保存的结果超过大小上限');
          }
        }
      } finally {
        unawaited(chunks.cancel());
      }
      return jsonDecode(utf8.decode(bytes));
    } on ConnectionNotSent {
      continue;
    } on IOException {
      // The server retains the result; re-reading it creates no new inference.
      continue;
    } on TimeoutException {
      continue;
    } finally {
      // A timer can fire late after suspension. Count at most this read's
      // advertised deadline; the next GET must get a chance to recover.
      budget -= readClock.elapsed > readLimit ? readLimit : readClock.elapsed;
    }
  }
  throw TimeoutException('等待保存的结果超过十分钟');
}

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

/// Only failures likely to recover when a connection or provider recovers.
/// Permanent credentials, endpoint and response-format errors require a person.
bool transientFailure(Object error) {
  if (error is UnknownOutcomeLLMError) return false;
  if (error is DeadlineExceeded ||
      error is ConnectionNotSent ||
      error is TransientLLMError ||
      error is TimeoutException ||
      error is SocketException ||
      error is HttpException ||
      error is HandshakeException) {
    return true;
  }
  // Parsing and validation errors can quote arbitrary model output. Never
  // classify their text as a network failure and retry paid calls forever.
  if (error is! LLMError) return false;
  if (explain(error) != null) return false;
  final String message = error.message;
  return RegExp(
    r'^(?:HTTP (?:408|429|5\d\d)\b|模型调用失败：(HTTP (?:408|429|5\d\d)\b|TimeoutException|SocketException|HandshakeException|HttpException|Connection (?:closed|reset|refused|terminated)|Failed host lookup|No route to host|Network is unreachable))',
    caseSensitive: false,
  ).hasMatch(message);
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
  final RunCancellation? cancellation = RunCancellation.current;
  cancellation?.checkpoint();
  Future<T> waitFor<T>(Future<T> operation) =>
      cancellation?.wait(operation) ?? operation;
  final bool adaptive = timeout == null;
  final double wait = timeout ?? stallTimeout(fullModel);
  final double wall =
      double.tryParse(environ['LLM_WALL_TIMEOUT'] ?? '') ??
      math.max(wait, 600.0);
  if (!wall.isFinite || wall <= 0) {
    throw const LLMError('模型请求总时限必须大于零');
  }
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
    cancellation?.checkpoint();
    if (ModelRequestScope.current?.hasUnknown ?? false) {
      throw const UnknownOutcomeLLMError('previous_request_unknown');
    }
    ModelRequestReceipt? receipt;
    bool responseSettled = false;
    try {
      ChatRequest req = buildRequest(
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
      final Stopwatch deadline = Stopwatch()..start();
      bool retained = false;
      Duration remaining() {
        final int milliseconds =
            (wall * 1000).round() - deadline.elapsedMilliseconds;
        if (milliseconds <= 0) {
          throw TimeoutException('模型请求超过 ${wall.round()} 秒总时限');
        }
        return Duration(milliseconds: milliseconds);
      }

      double? first;
      receipt = ModelRequestScope.current?.begin();
      // Only book processing asks for retained results. Interactive chat and
      // ordinary providers retain their normal streaming behaviour.
      if (receipt != null) {
        req = ChatRequest(req.url, {
          ...req.headers,
          'Prefer': 'respond-async',
        }, req.body);
      }
      ChatResponse resp = await waitFor(
        postRequest(
          req,
          Duration(
            milliseconds: math.min(
              (wait * 1000).round(),
              remaining().inMilliseconds,
            ),
          ),
          trace: receipt?.trace,
        ).timeout(remaining()),
      );
      if (receipt != null && resp.status == 202) {
        retained = true;
        final Object? result = await waitFor(
          pollRetainedResult(req.url, resp, req.headers, receipt.trace),
        );
        // This is now a complete, retained reply. A wall timer left over from
        // dispatch must not discard it or race a still-running polling future.
        deadline.reset();
        if (result is! Map<String, Object?> ||
            result['status'] is! int ||
            result['content_type'] is! String ||
            result['body'] is! String) {
          throw const UnknownOutcomeLLMError('response_interrupted');
        }
        resp = ChatResponse(
          result['status']! as int,
          result['content_type']! as String,
          Stream.value(utf8.encode(result['body']! as String)),
        );
      }
      if (resp.status >= 400) {
        if (!const <int>{
          400,
          401,
          402,
          403,
          404,
          422,
          429,
        }.contains(resp.status)) {
          unawaited(_disposeResponseBody(resp.body, receipt?.trace));
          throw const UnknownOutcomeLLMError('provider_outcome_unknown');
        }
        receipt?.rejected();
        responseSettled = true;
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
        final StreamIterator<List<int>> chunks = StreamIterator<List<int>>(
          resp.body,
        );
        bool exhausted = false;
        try {
          while (raw.length < readLimit) {
            if (!await waitFor(chunks.moveNext().timeout(remaining()))) {
              exhausted = true;
              break;
            }
            raw.addAll(chunks.current);
          }
        } finally {
          if (!exhausted) unawaited(_cancelResponse(chunks, receipt?.trace));
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
        responseSettled = true;
        receipt?.rejected();
        unawaited(_disposeResponseBody(resp.body, receipt?.trace));
        throw LLMError('NOT_API: 接口地址返回的是网页，不是模型接口：${req.url}');
      }
      final StringBuffer parts = StringBuffer();
      final Map<String, Object?> usage = <String, Object?>{};
      final StreamIterator<String> lines = StreamIterator<String>(
        resp.body
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter()),
      );
      bool exhausted = false;
      bool complete = false;
      try {
        while (true) {
          if (!await waitFor(lines.moveNext().timeout(remaining()))) {
            exhausted = true;
            break;
          }
          final String line = lines.current.trim();
          if (!line.startsWith('data:')) continue;
          final String data = line.substring(5).trim();
          if (data == '[DONE]') {
            complete = true;
            break;
          }
          final Object? ev;
          try {
            ev = jsonDecode(data);
          } on FormatException {
            continue;
          }
          if (ev is! Map<String, Object?>) continue;
          if (protocol == 'anthropic' && ev['type'] == 'message_stop' ||
              protocol == 'gemini' &&
                  (ev['candidates'] as List<Object?>? ?? []).any(
                    (c) =>
                        c is Map<String, Object?> && c['finishReason'] != null,
                  ) ||
              protocol != 'anthropic' &&
                  protocol != 'gemini' &&
                  (ev['choices'] as List<Object?>? ?? []).any(
                    (c) =>
                        c is Map<String, Object?> && c['finish_reason'] != null,
                  )) {
            complete = true;
          }
          final String text = delta(protocol, ev, usage);
          if (text.isNotEmpty) {
            first ??= clock.elapsedMilliseconds / 1000;
            parts.write(text);
            onText?.call(parts.toString());
          }
        }
      } finally {
        if (!exhausted) unawaited(_cancelResponse(lines, receipt?.trace));
      }
      if (!complete) throw const UnknownOutcomeLLMError('incomplete_response');
      receipt?.received();
      responseSettled = true;
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
      if (adaptive && !retained) {
        final List<double> seen = _replySeconds.putIfAbsent(
          fullModel,
          () => <double>[],
        )..add(secs);
        if (seen.length > 20) seen.removeAt(0);
      }
      return ChatResult(text, out);
    } on Cancelled {
      receipt?.unknown('cancelled');
      rethrow;
    } on UnknownOutcomeLLMError catch (e) {
      receipt?.unknown(e.code);
      rethrow;
    } on _Fatal catch (f) {
      throw f.error;
    } on DeadlineExceeded catch (e) {
      throw DeadlineExceeded(redactSecrets(e.message, <String>[key]));
    } on ConnectionNotSent catch (e) {
      receipt?.rejected();
      last = e;
    } on LLMError catch (e) {
      if (!responseSettled) {
        receipt?.unknown('provider_outcome_unknown');
        throw const UnknownOutcomeLLMError('provider_outcome_unknown');
      }
      last = e;
    } on TimeoutException {
      receipt?.unknown('timeout');
      throw const UnknownOutcomeLLMError('timeout');
    } on SocketException {
      receipt?.unknown('network_interrupted');
      throw const UnknownOutcomeLLMError('network_interrupted');
    } on HttpException {
      receipt?.unknown('network_interrupted');
      throw const UnknownOutcomeLLMError('network_interrupted');
    } on HandshakeException {
      receipt?.unknown('network_interrupted');
      throw const UnknownOutcomeLLMError('network_interrupted');
    } on Object catch (error) {
      if (!responseSettled) {
        receipt?.unknown('response_interrupted');
        throw const UnknownOutcomeLLMError('response_interrupted');
      }
      final String message = error is PyException ? error.message : '$error';
      final String safe = redactSecrets(message, <String>[key]);
      if (safe != message) throw LLMError(safe);
      rethrow;
    }
    if (attempt < tries) {
      await waitFor(
        sleep(
          Duration(
            milliseconds:
                ((math.min(60, 3 * math.pow(2, attempt)) +
                            random.nextDouble() * 2) *
                        1000)
                    .round(),
          ),
        ),
      );
    }
  }
  final String reason = redactSecrets(
    '模型调用失败：${last is PyException ? last.message : last}',
    <String>[key],
  );
  if (last != null && transientFailure(last)) throw TransientLLMError(reason);
  throw LLMError(reason);
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
