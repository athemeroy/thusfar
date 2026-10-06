/// The judge (Jev) clients of `pipeline/llm.py`: classifier.dev (free),
/// the paid Jev API, a local evaluator, a chat-model stand-in, and the
/// exact-input cache that lets 1.7.x judge caches be reused.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../async_util.dart';
import '../env.dart';
import '../errors.dart';
import '../py/py_compat.dart';
import '../py/py_hash.dart';
import '../py/py_json.dart';
import '../py/py_json_decode.dart';
import 'judge_context.dart';
import 'llm.dart';
import 'models.dart' as pricing;
import 'provenance.dart';
import 'request_lifecycle.dart';
import 'run_lease.dart';

String get jevUrl =>
    environ['JEV_URL'] ?? 'https://api.typesafe.ai/v1/systemone';
String get jevModel => environ['JEV_MODEL'] ?? 'jev-latest';
String get classifierUrl =>
    environ['CLASSIFIER_URL'] ?? 'https://classifier.dev/v1/classify';

const int classifierDims = 20;
const int classifierDimChars = 16000;
const int classifierInstructionChars = 4000;

typedef Json = Map<String, Object?>;

/// The configured model answered, but neither bounded attempt supplied a
/// complete, usable probability distribution. No verdict may be cached.
final class ModelJudgeInvalidAnswer extends LLMError {
  const ModelJudgeInvalidAnswer(super.message);
}

/// Fixed diagnostic codes only. Never include model text, question/option ids,
/// probability values, prompts, URLs or credentials in the diagnostic receipt.
enum _ModelAnswerIssue {
  invalidJson('invalid_json', '回复不是有效 JSON'),
  missingAnswer('missing_answer', '缺少问题回答或回答类型错误'),
  invalidChoice('invalid_choice', '选项缺失或无效'),
  incompleteProbabilities('incomplete_probabilities', '概率字段缺失或选项数量不符'),
  nonNumericProbability('non_numeric_probability', '概率不是数字'),
  nonFiniteProbability('non_finite_probability', '概率不是有限数值'),
  probabilityOutOfRange('probability_out_of_range', '概率超出 0 到 1'),
  inconsistentSum('inconsistent_sum', '概率合计不为 1'),
  zeroChoiceProbability('zero_choice_probability', '所选选项概率为零');

  const _ModelAnswerIssue(this.code, this.label);
  final String code;
  final String label;
}

final class _ModelAnswerError extends ValueError {
  const _ModelAnswerError(this.issue) : super('model judge: invalid answer');
  final _ModelAnswerIssue issue;
}

void _recordModelAnswerFailure(
  Map<String, _ModelAnswerIssue> issues,
  int questionCount,
) {
  final String? directory = selectedJudgeDirectory();
  if (directory == null || directory.isEmpty) return;
  final Json diagnostic = <String, Object?>{
    'schema': 1,
    'at': wallClock(),
    'attempts': 2,
    'question_count': questionCount,
    'unresolved_count': issues.length,
    'reasons': <String, int>{
      for (final _ModelAnswerIssue issue in _ModelAnswerIssue.values)
        if (issues.containsValue(issue))
          issue.code: issues.values.where((value) => value == issue).length,
    },
  };
  try {
    final File file = File('$directory/model-answer-failure.json');
    file.parent.createSync(recursive: true);
    final File temp = File('${file.path}.$pid.tmp');
    temp.writeAsStringSync(jsonEncode(diagnostic), flush: true);
    temp.renameSync(file.path);
  } on FileSystemException {
    // Optional diagnostics must never obscure the original validation error.
  }
}

/// What the judge costs; reset per book run.
final Map<String, num> jevStats = <String, num>{
  'calls': 0,
  'chars': 0,
  'questions': 0,
  'paid_chars': 0,
  'passage_chars': 0,
  'model_calls': 0,
  'model_prompt_tokens': 0,
  'model_completion_tokens': 0,
  'model_cost_low': 0,
  'model_cost_high': 0,
};

void resetJevStats() {
  jevStats
    ..clear()
    ..addAll(<String, num>{
      'calls': 0,
      'chars': 0,
      'questions': 0,
      'paid_chars': 0,
      'passage_chars': 0,
      'model_calls': 0,
      'model_prompt_tokens': 0,
      'model_completion_tokens': 0,
      'model_cost_low': 0,
      'model_cost_high': 0,
    });
  try {
    final Json saved = readModelJudgeBudget(modelJudgeBudgetFile());
    for (final String key in const <String>[
      'model_calls',
      'model_prompt_tokens',
      'model_completion_tokens',
      'model_cost_low',
      'model_cost_high',
    ]) {
      jevStats[key] = (saved[key] as num?) ?? 0;
    }
  } on Object {
    // No book is selected yet, or no model fallback has been used.
  }
}

/// Where operational log lines go (Python printed them).
void Function(String line) logLine = stdout.writeln;

/// Injected wall clock in seconds.
double Function() wallClock = () => DateTime.now().microsecondsSinceEpoch / 1e6;

int _cpLen(String s) => s.runes.length;

double _envDouble(String key, String fallback) =>
    double.parse((environ[key] ?? fallback).trim());
int _envInt(String key, String fallback) =>
    int.parse((environ[key] ?? fallback).trim());

/// Python `json.dumps(..., ensure_ascii=False)` with default separators.
String _dumps(Object? v) => PyJson.encode(v, ensureAscii: false);

const String judgeSystem =
    '''You are a careful judge. You are given a state (the only evidence you may use) and multiple-choice questions. For every question pick exactly one option id and give a probability for each option; the probabilities of one question must sum to 1. Judge only from the state — never from outside knowledge of the work, and never from what you expect to happen later.

Reply with one compact JSON object and nothing else:
{"q1": {"choice": "<option id>", "probabilities": {"<option id>": 0.0, ...}}, ...}''';

Json _criteria(Object? q) =>
    ((q! as Json)['criteria'] as Json?) ?? <String, Object?>{};

/// The same contract as [jev], answered by the reader's configured model.
/// Malformed answers are repaired once, never converted to a first-choice guess.
Future<Json> llmJudge(
  Object? state,
  Json questions, {
  String? model,
  bool reserveBudget = false,
}) async {
  String pick(String k) => environ[k] ?? '';
  final String m =
      model ??
      (pick('JUDGE_MODEL').isNotEmpty
          ? pick('JUDGE_MODEL')
          : pick('RECAP_MODEL').isNotEmpty
          ? pick('RECAP_MODEL')
          : 'deepseek-flash+nothink');
  if (m.isEmpty || keyFor(m.split('+').first)?.isNotEmpty != true) {
    throw const LLMError('模型判断需要先在「模型设置」保存可用的模型和 API 密钥');
  }
  final Json qs = <String, Object?>{
    for (final MapEntry<String, Object?> e in questions.entries)
      e.key: <String, Object?>{
        'instructions': (e.value! as Json)['instructions'] ?? '',
        'options': _criteria(e.value),
      },
  };
  final String user = _dumps(<String, Object?>{
    'state': state,
    'questions': qs,
  });
  final List<Map<String, String>> msgs = <Map<String, String>>[
    <String, String>{'role': 'system', 'content': judgeSystem},
    <String, String>{'role': 'user', 'content': user},
  ];
  // The reply needs a choice and every option probability for each question.
  // Leave room for the full JSON object even when the provider counts hidden
  // output tokens against the requested completion limit.
  final int budget = 400 + 200 * qs.length;
  int promptTokens = 0, completionTokens = 0;
  final Json valid = <String, Object?>{};
  final Json pending = Map<String, Object?>.of(questions);
  final Map<String, _ModelAnswerIssue> issues = {};
  for (int attempt = 0; attempt < 2; attempt++) {
    if (reserveBudget) {
      try {
        reserveModelJudge(
          msgs.fold<int>(0, (n, msg) => n + _cpLen(msg['content'] ?? '')),
          questions.length,
        );
      } on PyException catch (e) {
        throw LLMError(e.message);
      }
    }
    final ChatResult result = await chat(
      m,
      msgs,
      maxTokens: budget,
      temperature: 0,
      retries: 0,
    );
    final int input = (result.usage['prompt_tokens'] as num?)?.toInt() ?? 0;
    final int output =
        (result.usage['completion_tokens'] as num?)?.toInt() ?? 0;
    promptTokens += input;
    completionTokens += output;
    if (reserveBudget) _recordModelJudgeUsage(m, input, output);
    try {
      final Object? raw = parseJson(result.text);
      if (raw is! Json) throw const ValueError('model judge: expected object');
      for (final MapEntry<String, Object?> e in pending.entries.toList()) {
        try {
          // Accept only complete, strict answers. An invalid answer for one
          // question must not discard valid answers for the others.
          final Json one = _strictModelAnswers(
            <String, Object?>{e.key: raw[e.key]},
            <String, Object?>{e.key: e.value},
            m,
          );
          valid[e.key] = one[e.key];
          pending.remove(e.key);
          issues.remove(e.key);
        } on _ModelAnswerError catch (error) {
          issues[e.key] = error.issue;
        }
      }
    } on ValueError {
      // The entire reply is malformed; the next bounded attempt can repair it.
      for (final String key in pending.keys) {
        issues[key] = _ModelAnswerIssue.invalidJson;
      }
    }
    if (pending.isEmpty) break;
    if (attempt == 0) {
      msgs.addAll(<Map<String, String>>[
        <String, String>{'role': 'assistant', 'content': result.text},
        <String, String>{
          'role': 'user',
          'content':
              'Your answer was incomplete. Reply with one JSON object covering these remaining question ids: ${pending.keys.join(', ')}. Each choice must be a valid option id, and probabilities must include every option as numbers from 0 to 1 that sum to 1. No explanations.',
        },
      ]);
    }
  }
  // A short batch can fail just because its JSON object is too complex for
  // the model. Ask only unresolved questions separately, with the same strict
  // validation and per-call budget accounting. Cap this fallback's cost.
  if (pending.isNotEmpty && questions.length > 1 && questions.length <= 10) {
    for (final MapEntry<String, Object?> e in pending.entries.toList()) {
      final Json one = await llmJudge(
        state,
        <String, Object?>{e.key: e.value},
        model: m,
        reserveBudget: reserveBudget,
      );
      valid[e.key] = one[e.key];
      final Json usage = one['_usage']! as Json;
      promptTokens += (usage['prompt_tokens']! as num).toInt();
      completionTokens += (usage['completion_tokens']! as num).toInt();
      pending.remove(e.key);
    }
  }
  if (pending.isNotEmpty) {
    _recordModelAnswerFailure(issues, questions.length);
    final String reasons = issues.values
        .toSet()
        .map((issue) => issue.label)
        .join('、');
    throw ModelJudgeInvalidAnswer(
      '已配置模型的判断回答不完整或概率无效：$reasons（未完成 ${pending.length}/${questions.length} 个问题）；已保留进度，请检查模型后手动重试',
    );
  }
  valid['_usage'] = <String, Object?>{
    'prompt_tokens': promptTokens,
    'completion_tokens': completionTokens,
  };
  return valid;
}

Json _strictModelAnswers(Object? raw, Json questions, String model) {
  if (raw is! Json)
    throw const _ModelAnswerError(_ModelAnswerIssue.invalidJson);
  final Json out = <String, Object?>{};
  for (final MapEntry<String, Object?> e in questions.entries) {
    final Json criteria = _criteria(e.value);
    final Object? answer = raw[e.key];
    if (answer is! Json) {
      throw const _ModelAnswerError(_ModelAnswerIssue.missingAnswer);
    }
    if (answer['choice'] is! String ||
        !criteria.containsKey(answer['choice'])) {
      throw const _ModelAnswerError(_ModelAnswerIssue.invalidChoice);
    }
    final Object? given = answer['probabilities'];
    if (given is! Json ||
        given.length != criteria.length ||
        !given.keys.toSet().containsAll(criteria.keys)) {
      throw const _ModelAnswerError(_ModelAnswerIssue.incompleteProbabilities);
    }
    final Map<String, double> probs = <String, double>{};
    for (final String option in criteria.keys) {
      final Object? value = given[option];
      if (value is! num || value is bool) {
        throw const _ModelAnswerError(_ModelAnswerIssue.nonNumericProbability);
      }
      if (!value.isFinite) {
        throw const _ModelAnswerError(_ModelAnswerIssue.nonFiniteProbability);
      }
      if (value < 0 || value > 1) {
        throw const _ModelAnswerError(_ModelAnswerIssue.probabilityOutOfRange);
      }
      probs[option] = value.toDouble();
    }
    final double total = probs.values.fold(0.0, (a, b) => a + b);
    if ((total - 1).abs() > 0.02) {
      throw const _ModelAnswerError(_ModelAnswerIssue.inconsistentSum);
    }
    if (probs[answer['choice']] == 0) {
      throw const _ModelAnswerError(_ModelAnswerIssue.zeroChoiceProbability);
    }
    out[e.key] = <String, Object?>{
      'type': 'choice',
      'choice': answer['choice'],
      'probabilities': <String, double>{
        for (final entry in probs.entries)
          entry.key: PyCompat.roundDigits(entry.value / total, 3),
      },
      'by': model,
    };
  }
  validateAnswers(out, questions, 'model judge');
  return out;
}

void _recordModelJudgeUsage(String model, int input, int output) {
  double low = 0, high = 0;
  final String name = model.split('+').first;
  if (pricing.prices.containsKey(name) ||
      pricing.overrides().containsKey(name)) {
    final pricing.Price p = pricing.priceOf(name);
    low =
        (input * p.price.$1 * p.mult.$1 + output * p.price.$2 * p.mult.$1) /
        1e6;
    high =
        (input * p.price.$1 * p.mult.$2 + output * p.price.$2 * p.mult.$2) /
        1e6;
  }
  final Json saved = recordModelJudgeUsage(input, output, low, high);
  for (final String key in const <String>[
    'model_calls',
    'model_prompt_tokens',
    'model_completion_tokens',
    'model_cost_low',
    'model_cost_high',
  ]) {
    jevStats[key] = saved[key]! as num;
  }
}

/// The judge's state as one block of text.
String stateText(Object? state) {
  if (state is String) return state;
  final List<String> parts = <String>[];
  for (final MapEntry<String, Object?> e
      in ((state as Json?) ?? <String, Object?>{}).entries) {
    final Object? v = e.value;
    final String body = v is String ? v : _dumps(v);
    parts.add('[${e.key}]\n$body');
  }
  return parts.join('\n\n');
}

/// Retry-After: seconds or an HTTP date; malformed advice is not a delay.
double? retryHint(Map<String, String>? headers) {
  final String? value = headers?['Retry-After'];
  if (value == null) return null;
  double? seconds = double.tryParse(value.trim());
  if (seconds == null) {
    try {
      seconds =
          HttpDate.parse(value).millisecondsSinceEpoch / 1000 - wallClock();
    } on FormatException {
      return null;
    } on HttpException {
      return null;
    }
  }
  if (!seconds.isFinite) return null;
  return seconds < 0 ? 0.0 : seconds;
}

/// How long to wait after a 429, or null when waiting is not worth it.
double? retryAfter(Map<String, String>? headers, int attempt, {double? cap}) {
  final double limit = cap ?? _envDouble('JEV_MAX_WAIT', '60');
  final double? hinted = retryHint(headers);
  if (hinted != null && hinted > limit) return null;
  if (hinted != null) return hinted + random.nextDouble();
  final double blind = _envDouble('JEV_BLIND_WAIT', '8');
  return math.min(blind, 0.5 * math.pow(2, attempt)) + random.nextDouble();
}

Future<void> _judgeRetry(
  String route,
  String status,
  int attempt,
  int retries,
  double wait,
  Stopwatch started,
) async {
  jevStats['retries'] = (jevStats['retries'] ?? 0) + 1;
  jevStats['retry_wait_seconds'] = (jevStats['retry_wait_seconds'] ?? 0) + wait;
  logLine(
    '[judge] 路由=$route 状态=$status 尝试=${attempt + 1}/${retries + 1} '
    '等待=${wait.toStringAsFixed(1)}s 已用=${(started.elapsedMilliseconds / 1000).toStringAsFixed(1)}s',
  );
  final Future<void> delay = sleep(
    Duration(microseconds: (wait * 1e6).round()),
  );
  await (RunCancellation.current?.wait(delay) ?? delay);
}

void _judgeAttempt() => jevStats['attempts'] = (jevStats['attempts'] ?? 0) + 1;

/// Missing answers must cause a retry, not become confident negatives.
Json validateAnswers(Object? answers, Json questions, String route) {
  if (answers is! Json) throw ValueError('$route: answers must be an object');
  for (final MapEntry<String, Object?> e in questions.entries) {
    final Object? answer = answers[e.key];
    final Json criteria = _criteria(e.value);
    if (answer is! Json ||
        answer['choice'] is! String ||
        !criteria.containsKey(answer['choice'])) {
      throw ValueError('$route: missing or invalid answer for ${e.key}');
    }
    final Object? scores = answer['probabilities'];
    if (scores is! Json || !scores.containsKey(answer['choice'])) {
      throw ValueError('$route: missing probabilities for ${e.key}');
    }
    for (final MapEntry<String, Object?> s in scores.entries) {
      final Object? v = s.value;
      if (!criteria.containsKey(s.key) ||
          v is bool ||
          v is! num ||
          !v.isFinite ||
          v < 0 ||
          v > 1) {
        throw ValueError('$route: invalid probability for ${e.key}');
      }
    }
    if (!scores.values.any((Object? v) => v != 0)) {
      throw ValueError('$route: empty probability distribution for ${e.key}');
    }
  }
  return answers;
}

/// The paid Choice API promises a complete distribution. Check that promise
/// before a verdict can be logged or cached; the free route keeps its own
/// existing response contract.
Json validatePaidAnswers(Object? answers, Json questions) {
  final Json checked = validateAnswers(answers, questions, 'Jev');
  for (final MapEntry<String, Object?> e in questions.entries) {
    final Object? type = (e.value as Json?)?['type'];
    if (type != null && type != 'choice') continue;
    final Json criteria = _criteria(e.value);
    final Json answer = checked[e.key]! as Json;
    final Object? raw = answer['probabilities'];
    if (raw is! Json ||
        raw.length != criteria.length ||
        !raw.keys.toSet().containsAll(criteria.keys)) {
      throw ValueError('Jev: incomplete probabilities for ${e.key}');
    }
    double total = 0;
    double highest = 0;
    for (final String option in criteria.keys) {
      final Object? value = raw[option];
      if (value is! num ||
          value is bool ||
          !value.isFinite ||
          value < 0 ||
          value > 1) {
        throw ValueError('Jev: invalid probability for ${e.key}');
      }
      final double probability = value.toDouble();
      total += probability;
      highest = math.max(highest, probability);
    }
    final double chosen = (raw[answer['choice']]! as num).toDouble();
    if ((total - 1).abs() > 0.02 || chosen == 0 || chosen < highest - 1e-9) {
      throw ValueError('Jev: inconsistent probabilities for ${e.key}');
    }
  }
  return checked;
}

/// Keeps a free best-effort route from holding up a book.
final class Breaker {
  Breaker(this.name, {this.fails = 3, this.cool = 600.0});

  final String name;
  final int fails;
  final double cool;
  int bad = 0;
  double until = 0.0;
  bool probing = false;

  bool open() => wallClock() < until;

  bool allow() {
    if (wallClock() < until || probing) return false;
    if (until != 0) probing = true;
    return true;
  }

  void ok() {
    if (until != 0) logLine('[judge] $name is answering again');
    bad = 0;
    until = 0.0;
    probing = false;
  }

  void failed(String why, {double? cool}) {
    probing = false;
    bad++;
    final double wait = math.min(
      cool ?? this.cool,
      _envDouble('JEV_MAX_COOLDOWN', '21600'),
    );
    if (bad >= fails && wallClock() >= until) {
      until = wallClock() + wait;
      logLine(
        '[judge] $name failed ${bad}x, skipping it for ${wait.toInt()}s: ${String.fromCharCodes(why.runes.take(120))}',
      );
    }
  }
}

final Breaker freeBreaker = Breaker(
  'classifier.dev',
  fails: _envInt('JEV_FREE_FAILS', '2'),
  cool: _envDouble('JEV_FREE_COOLDOWN', '1800'),
);
String? _freeCredentialStamp;

void _syncFreeCredential() {
  final String stamp = sha256Hex(utf8.encode(llmEnv('CLASSIFIER_KEY') ?? ''));
  if (_freeCredentialStamp == stamp) return;
  _freeCredentialStamp = stamp;
  freeBreaker
    ..bad = 0
    ..until = 0
    ..probing = false;
}

/// Honor both free-route limits before sending any request.
List<(List<String>, Json)> classifierBatches(Json questions) {
  final List<(List<String>, Json)> batches = <(List<String>, Json)>[];
  List<String> keys = <String>[];
  Json dims = <String, Object?>{};
  int candidateSize(Json c) => _dumps(c).length;
  for (final MapEntry<String, Object?> e in questions.entries) {
    final Json q = e.value! as Json;
    final Json criteria = _criteria(q);
    final String lines = criteria.entries
        .map((MapEntry<String, Object?> c) => '- ${c.key}: ${c.value}')
        .join('\n');
    final Json dimension = <String, Object?>{
      'labels': criteria.keys.toList(),
      'instructions': '${q['instructions'] ?? ''}\nChoose one label:\n$lines',
    };
    if ((dimension['instructions']! as String).length >
        classifierInstructionChars) {
      throw const LLMError('classifier.dev：单个问题的说明超过 4000 字符，未调用免费接口');
    }
    Json candidate = <String, Object?>{...dims, 'd${keys.length}': dimension};
    if (dims.isNotEmpty &&
        (candidate.length > classifierDims ||
            candidateSize(candidate) > classifierDimChars)) {
      batches.add((keys, dims));
      keys = <String>[];
      dims = <String, Object?>{};
      candidate = <String, Object?>{'d0': dimension};
    }
    if (candidateSize(candidate) > classifierDimChars) {
      throw const LLMError('classifier.dev：单个问题的维度定义超过字符上限，需要显式选择支持该长度的路由');
    }
    keys.add(e.key);
    dims = candidate;
  }
  if (dims.isNotEmpty) batches.add((keys, dims));
  return batches;
}

/// An HTTP failure carrying the status, like `urllib.error.HTTPError`.
final class _HttpFailure implements Exception {
  const _HttpFailure(this.code, this.detail, this.headers);

  final int code;
  final String detail;
  final Map<String, String> headers;
}

Future<Object?> _postJson(
  String url,
  String body,
  Map<String, String> headers,
  double timeout,
  int detailBytes, {
  bool paid = false,
}) async {
  final RunCancellation? cancellation = RunCancellation.current;
  cancellation?.checkpoint();
  if (ModelRequestScope.current?.hasUnknown ?? false) {
    throw const UnknownOutcomeLLMError('previous_request_unknown');
  }
  Future<T> wait<T>(Future<T> operation) =>
      cancellation?.wait(operation) ?? operation;
  final ModelRequestReceipt? receipt =
      paid ? ModelRequestScope.current?.begin() : null;
  late ChatResponse resp;
  final List<int> raw = <int>[];
  try {
    resp = await wait(
      postRequest(
        ChatRequest(Uri.parse(url), headers, body),
        Duration(microseconds: (timeout * 1e6).round()),
      ),
    );
    if (resp.status >= 400) {
      if (paid &&
          !const <int>{
            400,
            401,
            402,
            403,
            404,
            422,
            429,
          }.contains(resp.status)) {
        unawaited(discardChatResponse(resp));
        throw const UnknownOutcomeLLMError('provider_outcome_unknown');
      }
      receipt?.rejected();
    }
    final StreamIterator<List<int>> chunks = StreamIterator<List<int>>(
      resp.body,
    );
    try {
      while (await wait(chunks.moveNext())) {
        raw.addAll(chunks.current);
        if (raw.length > 16 * 1024 * 1024) throw const LLMError('模型响应超过大小上限');
      }
    } finally {
      unawaited(chunks.cancel().catchError((Object _) {}));
    }
    receipt?.received();
  } on Cancelled {
    receipt?.unknown('cancelled');
    rethrow;
  } on UnknownOutcomeLLMError catch (e) {
    receipt?.unknown(e.code);
    rethrow;
  } on TimeoutException {
    if (!paid) rethrow;
    receipt?.unknown('timeout');
    throw const UnknownOutcomeLLMError('timeout');
  } on IOException {
    if (!paid) rethrow;
    receipt?.unknown('network_interrupted');
    throw const UnknownOutcomeLLMError('network_interrupted');
  } on Object {
    if (!paid) rethrow;
    receipt?.unknown('response_interrupted');
    throw const UnknownOutcomeLLMError('response_interrupted');
  }

  if (resp.status >= 400) {
    String detail = utf8.decode(
      raw.take(detailBytes).toList(),
      allowMalformed: true,
    );
    final String? authorization = headers['Authorization'];
    if (authorization != null && authorization.startsWith('Bearer ')) {
      detail = redactSecrets(detail, <String>[
        authorization.substring('Bearer '.length),
      ]);
    }
    throw _HttpFailure(resp.status, detail, resp.headers);
  }
  return pyJsonLoads(utf8.decode(raw, allowMalformed: true));
}

/// A classifier.dev failure that knows when the daily quota reopens.
final class ReopeningError extends LLMError {
  const ReopeningError(super.message, this.reopensIn);

  final double reopensIn;
}

/// Permanent access refusal: do not send this same anonymous request again.
final class ClassifierAccessError extends LLMError {
  const ClassifierAccessError(super.message);
}

String _typeName(Object e) => switch (e) {
  final PyException p => p.pyType.split('.').last,
  TimeoutException() => 'TimeoutError',
  SocketException() => 'ConnectionError',
  HttpException() => 'OSError',
  HandshakeException() => 'OSError',
  _ => e.runtimeType.toString(),
};

String _str(Object e) => e is PyException ? e.message : '$e';

/// The same Jev model through classifier.dev: no key, free.
Future<Json> jevFree(
  Object? state,
  Json questions, {
  int timeout = 90,
  int retries = 6,
}) async {
  if (questions.isEmpty) return <String, Object?>{};
  _syncFreeCredential();
  if (freeBreaker.open()) throw const LLMError('classifier.dev 暂时跳过（连续失败，冷却中）');
  final int t = math.min(timeout, _envInt('JEV_FREE_TIMEOUT', '20'));
  final int tries = math.min(retries, _envInt('JEV_FREE_RETRIES', '1'));
  final Stopwatch started = Stopwatch()..start();
  final Json out = <String, Object?>{};
  final String text = stateText(state);
  if (_cpLen(text) > 31000)
    throw const LLMError('上下文超过免费接口上限；未裁剪原文，需要显式选择支持该长度的路由');
  for (final (List<String> chunk, Json dims) in classifierBatches(questions)) {
    final String body = _dumps(<String, Object?>{
      'items': <Object?>[text],
      'dimensions': dims,
    });
    jevStats['calls'] = jevStats['calls']! + 1;
    jevStats['chars'] = jevStats['chars']! + _cpLen(body);
    jevStats['questions'] = jevStats['questions']! + chunk.length;
    jevStats['passage_chars'] = (jevStats['passage_chars'] ?? 0) + _cpLen(text);
    Object? last;
    bool done = false;
    for (int attempt = 0; attempt <= tries; attempt++) {
      String status;
      try {
        final Map<String, String> headers = <String, String>{
          'Content-Type': 'application/json',
        };
        final String? key = llmEnv('CLASSIFIER_KEY');
        if (key != null && key.isNotEmpty)
          headers['Authorization'] = 'Bearer $key';
        _judgeAttempt();
        final Object? data = await _postJson(
          classifierUrl,
          body,
          headers,
          t.toDouble(),
          200,
        );
        final Object? results = data is Json ? data['results'] : null;
        if (results is! List<Object?> || results.isEmpty || results[0] is! Json)
          throw const ValueError('classifier.dev: missing results');
        final Object? got = (results[0]! as Json)['dimensions'];
        if (got is! Json)
          throw const ValueError('classifier.dev: missing dimensions');
        final Json chunkOut = <String, Object?>{};
        for (int i = 0; i < chunk.length; i++) {
          final Object? raw = got['d$i'];
          final Object? a =
              raw == null ||
                      raw == false ||
                      raw == 0 ||
                      raw == '' ||
                      (raw is Json && raw.isEmpty)
                  ? <String, Object?>{}
                  : raw;
          if (a is! Json)
            throw const ValueError('classifier.dev: invalid dimension');
          Object? scores = a['scores'];
          if (scores == null) {
            final Object? label = a['label'];
            scores =
                label != null && label != '' && label != false && label != 0
                    ? <String, Object?>{
                      '$label':
                          a.containsKey('confidence') ? a['confidence'] : 1.0,
                    }
                    : <String, Object?>{};
          }
          chunkOut[chunk[i]] = <String, Object?>{
            'type': 'choice',
            'choice': a['label'],
            'probabilities': scores,
            'confidence': a['confidence'],
          };
        }
        validateAnswers(chunkOut, <String, Object?>{
          for (final String k in chunk) k: questions[k],
        }, 'classifier.dev');
        for (final Object? answer in chunkOut.values) {
          final Json ans = answer! as Json;
          ans['probabilities'] = <String, Object?>{
            for (final MapEntry<String, Object?> p
                in (ans['probabilities']! as Json).entries)
              p.key:
                  p.value is double
                      ? PyCompat.roundDigits(p.value! as double, 3)
                      : p.value,
          };
        }
        out.addAll(chunkOut);
        done = true;
        break;
      } on _HttpFailure catch (e) {
        final LLMError err = LLMError(
          'classifier.dev HTTP ${e.code}: ${e.detail}',
        );
        last = err;
        if (e.code == 429) {
          final double? wait = retryAfter(
            e.headers,
            attempt,
            cap: _envDouble('JEV_FREE_MAX_WAIT', '2'),
          );
          if (wait == null)
            throw ReopeningError(err.message, retryHint(e.headers) ?? 0);
          if (attempt >= tries)
            throw LLMError('classifier.dev 调用失败：${err.message}');
          await _judgeRetry(
            '免费',
            'HTTP ${e.code}',
            attempt,
            tries,
            wait,
            started,
          );
          continue;
        }
        if (e.code == 401 || e.code == 403) {
          final bool hasWorkspaceKey =
              (llmEnv('CLASSIFIER_KEY') ?? '').isNotEmpty;
          throw ClassifierAccessError(
            hasWorkspaceKey
                ? 'classifier.dev HTTP ${e.code}: 工作区密钥访问被拒绝，请检查密钥和余额'
                : e.detail.contains('proxy_requires_payment')
                ? 'classifier.dev HTTP ${e.code}: 匿名免费额度不可用，需要已充值的工作区密钥'
                : 'classifier.dev HTTP ${e.code}: 匿名访问被拒绝',
          );
        }
        if (e.code == 400) throw err;
        status = 'HTTP ${e.code}';
      } on DeadlineExceeded {
        rethrow;
      } on ValueError catch (e) {
        last = e;
        status = _typeName(e);
      } on TimeoutException catch (e) {
        last = e;
        status = 'TimeoutError';
      } on SocketException catch (e) {
        last = e;
        status = 'ConnectionError';
      } on HttpException catch (e) {
        last = e;
        status = 'OSError';
      } on HandshakeException catch (e) {
        last = e;
        status = 'OSError';
      }
      if (attempt < tries) {
        await _judgeRetry(
          '免费',
          status,
          attempt,
          tries,
          math.min(20, 2 * math.pow(2, attempt)) + random.nextDouble(),
          started,
        );
      }
    }
    if (!done)
      throw LLMError(
        'classifier.dev 调用失败：${last == null ? 'None' : _str(last)}',
      );
  }
  return out;
}

final Semaphore _jevGate = Semaphore(_envInt('JEV_CONCURRENCY', '6'));
final Set<String> _teacherSeen = <String>{};

/// Every judged question as asked and answered, for training later.
void teacherLog(Object? state, Json questions, Json answers, String route) {
  final String? d = selectedJudgeDirectory();
  if (d == null || d.isEmpty || (environ['JUDGE_LOG'] ?? '1') != '1') return;
  try {
    final Directory path = Directory(d)..createSync(recursive: true);
    final String text = state is String ? state : _dumps(state);
    final String h = sha1Hex(utf8.encode(text)).substring(0, 16);
    final String identity = '${path.absolute.path}\u0000$h';
    if (!_teacherSeen.contains(identity)) {
      File('${path.path}/states.jsonl').writeAsStringSync(
        '${_dumps(<String, Object?>{'h': h, 'state': state})}\n',
        mode: FileMode.append,
      );
      _teacherSeen.add(identity);
    }
    final StringBuffer lines = StringBuffer();
    for (final MapEntry<String, Object?> e in questions.entries) {
      final Json q = e.value! as Json;
      final Json a = (answers[e.key] as Json?) ?? <String, Object?>{};
      lines.writeln(
        _dumps(<String, Object?>{
          'state': h,
          'key': e.key,
          'instructions': q['instructions'] ?? '',
          'criteria': q['criteria'] ?? <String, Object?>{},
          'choice': a['choice'],
          'probabilities': a['probabilities'],
          'model':
              route == 'configured-model'
                  ? (environ['JUDGE_MODEL'] ?? environ['RECAP_MODEL'] ?? '')
                  : jevModel,
          'route': route,
          'capture_schema': 2,
        }),
      );
    }
    File(
      '${path.path}/questions.jsonl',
    ).writeAsStringSync(lines.toString(), mode: FileMode.append);
  } on Object catch (e) {
    logLine('[judge] 训练日志写入失败：${_typeName(e)}，目录=$d');
  }
}

final Semaphore _localJudgeGate = Semaphore(1);

/// The explicit local-only route.
Future<Json> jevLocal(Object? state, Json questions) async {
  final String url = environ['CLASSIFIER_URL'] ?? '';
  String trimmed = url;
  while (trimmed.endsWith('/')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  if (url.isEmpty || !trimmed.endsWith('/v1/evaluate')) {
    throw const LLMError(
      '本地裁判需要显式设置 CLASSIFIER_URL=http://主机:8008/v1/evaluate',
    );
  }
  final String body = _dumps(<String, Object?>{
    'state': state,
    'questions': questions,
  });
  try {
    final Object? data = await _localJudgeGate.run(() async {
      jevStats['calls'] = jevStats['calls']! + 1;
      jevStats['chars'] = jevStats['chars']! + _cpLen(body);
      jevStats['questions'] = jevStats['questions']! + questions.length;
      jevStats['local_calls'] = (jevStats['local_calls'] ?? 0) + 1;
      _judgeAttempt();
      return _postJson(
        url,
        body,
        <String, String>{'Content-Type': 'application/json'},
        _envDouble('JEV_LOCAL_TIMEOUT', '120'),
        0,
      );
    });
    final Object? answers = data is Json ? data['answers'] : null;
    validateAnswers(answers, questions, 'Kev local');
    for (final MapEntry<String, Object?> e in questions.entries) {
      final Json scores =
          ((answers! as Json)[e.key]! as Json)['probabilities']! as Json;
      final double sum = scores.values.fold(
        0.0,
        (double a, Object? b) => a + (b! as num),
      );
      if (!_sameKeys(scores.keys, _criteria(e.value).keys) ||
          (sum - 1).abs() > 0.01) {
        throw const ValueError(
          'local judge must return a complete normalized distribution',
        );
      }
    }
    return answers! as Json;
  } on DeadlineExceeded {
    rethrow;
  } on _HttpFailure catch (e) {
    throw LLMError('本地裁判失败，未调用付费接口：HTTPError: HTTP Error ${e.code}');
  } on ValueError catch (e) {
    throw LLMError('本地裁判失败，未调用付费接口：${_typeName(e)}: ${e.message}');
  } on IOException catch (e) {
    throw LLMError('本地裁判失败，未调用付费接口：${_typeName(e)}: $e');
  } on TimeoutException catch (e) {
    throw LLMError('本地裁判失败，未调用付费接口：TimeoutError: $e');
  }
}

bool _sameKeys(Iterable<String> a, Iterable<String> b) =>
    a.toSet().length == b.toSet().length && a.toSet().containsAll(b);

String _routeUsed = 'unknown';

/// Call the selected judge route. Model overflow uses the saved model key and
/// its own per-book allowance; paid Jev remains a separate gateway route.
Future<Json> jevUncached(
  Object? state,
  Json questions, {
  int timeout = 90,
  int? retries,
}) async {
  if (questions.isEmpty) return <String, Object?>{};
  final Stopwatch started = Stopwatch()..start();
  String route = selectedJudgeRoute();
  if (route == 'free') route = 'free-only';
  if (!const <String>[
    'local',
    'free-only',
    'free-then-model',
    'free-then-paid',
    'model',
    'paid',
  ].contains(route)) {
    throw const LLMError(
      '未知裁判路由；使用 local、free-only、free-then-model、free-then-paid、model 或 paid',
    );
  }
  if (route == 'local') return jevLocal(state, questions);
  _syncFreeCredential();
  if ((route == 'free-only' ||
          route == 'free-then-model' ||
          route == 'free-then-paid') &&
      freeBreaker.allow()) {
    try {
      final Json out = await jevFree(state, questions, timeout: timeout);
      freeBreaker.ok();
      _routeUsed = 'free';
      teacherLog(state, questions, out, 'free');
      return out;
    } on DeadlineExceeded {
      rethrow;
    } on Cancelled {
      rethrow;
    } on UnknownOutcomeLLMError {
      rethrow;
    } on Object catch (e) {
      if (e is ClassifierAccessError) freeBreaker.bad = freeBreaker.fails - 1;
      freeBreaker.failed(
        _str(e),
        cool:
            e is ReopeningError && e.reopensIn != 0
                ? e.reopensIn
                : e is ClassifierAccessError
                ? 21600
                : null,
      );
      if (route == 'free-only') {
        throw LLMError('免费裁判暂不可用，未调用付费接口：${_typeName(e)}: ${_str(e)}');
      }
      logLine(
        '[judge] classifier.dev unavailable; using ${route == 'free-then-model' ? 'the configured model' : 'the Jev gateway'}',
      );
    }
  } else if (route == 'free-only') {
    throw const LLMError('免费裁判处于冷却期，未调用付费接口；稍后可从缓存继续');
  }
  if (route == 'free-then-model' || route == 'model') {
    final Json out = await llmJudge(state, questions, reserveBudget: true);
    _routeUsed = 'configured-model';
    teacherLog(state, questions, out, 'configured-model');
    return out;
  }
  final String keyName = environ['JEV_KEY_NAME'] ?? '';
  final String? key =
      environ['LLM_SETTINGS_AUTHORITY'] == '1'
          ? llmEnv('JEV_API_KEY')
          : (keyName.isNotEmpty ? llmEnv(keyName) : null) ??
              llmEnv('JEV_API_KEY') ??
              (jevUrl.contains('vercel')
                  ? llmEnv('VERCEL_AI_GATEWAY_KEY')
                  : null);
  if (key == null || key.isEmpty) throw const LLMError('缺少 Jev 密钥');
  final String body = _dumps(<String, Object?>{
    'model': jevModel,
    'state': state,
    'questions': questions,
  });
  jevStats['calls'] = jevStats['calls']! + 1;
  jevStats['chars'] = jevStats['chars']! + _cpLen(body);
  jevStats['paid_chars'] = jevStats['paid_chars']! + _cpLen(body);
  jevStats['questions'] = jevStats['questions']! + questions.length;
  Object? last;
  final int tries = retries ?? _envInt('JEV_RETRIES', '6');
  if (tries < 0) throw const ValueError('JEV_RETRIES must be nonnegative');
  for (int attempt = 0; attempt <= tries; attempt++) {
    try {
      reservePaid(_cpLen(body), questions.length);
    } on PyException catch (e) {
      throw LLMError(e.message);
    }
    String status;
    try {
      final Object? data = await _jevGate.run(() {
        _judgeAttempt();
        return _postJson(
          jevUrl,
          body,
          <String, String>{
            'Authorization': 'Bearer $key',
            'Content-Type': 'application/json',
          },
          timeout.toDouble(),
          300,
          paid: true,
        );
      });
      if (data is! Json || data.containsKey('error'))
        throw const ValueError('Jev: invalid response');
      final Object? out =
          _truthy(data['answers'])
              ? data['answers']
              : (_truthy(data['results']) ? data['results'] : data);
      validatePaidAnswers(out, questions);
      if (attempt > 0) {
        logLine(
          '[judge] 路由=付费 已恢复 尝试=${attempt + 1}/${tries + 1} 已用=${(started.elapsedMilliseconds / 1000).toStringAsFixed(1)}s',
        );
      }
      _routeUsed = 'paid';
      teacherLog(state, questions, out! as Json, 'paid');
      return out as Json;
    } on _HttpFailure catch (e) {
      final LLMError err = LLMError('Jev HTTP ${e.code}: ${e.detail}');
      last = err;
      if (e.code == 429) {
        final double? wait = retryAfter(e.headers, attempt);
        if (wait == null) throw err;
        if (attempt >= tries) break;
        await _judgeRetry(
          '付费',
          'HTTP ${e.code}',
          attempt,
          tries,
          wait,
          started,
        );
        continue;
      }
      if (const <int>[400, 401, 402, 403, 404, 422].contains(e.code)) throw err;
      status = 'HTTP ${e.code}';
    } on DeadlineExceeded {
      rethrow;
    } on ValueError catch (e) {
      last = e;
      status = _typeName(e);
    } on TimeoutException catch (e) {
      last = e;
      status = 'TimeoutError';
    } on IOException catch (e) {
      last = e;
      status = _typeName(e);
    }
    if (attempt < tries) {
      await _judgeRetry(
        '付费',
        status,
        attempt,
        tries,
        math.min(30, 2 * math.pow(2, attempt)) + random.nextDouble(),
        started,
      );
    }
  }
  throw LLMError('Jev 调用失败：${last == null ? 'None' : _str(last)}');
}

bool _truthy(Object? v) =>
    v != null &&
    v != false &&
    v != 0 &&
    v != '' &&
    !(v is List<Object?> && v.isEmpty) &&
    !(v is Json && v.isEmpty);

final Map<String, Semaphore> _cacheLocks = <String, Semaphore>{};

/// Cache complete teacher requests, retaining successful batches on retry.
Future<Json> jev(
  Object? state,
  Json questions, {
  int timeout = 90,
  int? retries,
}) async {
  final String? directory = selectedJudgeDirectory();
  final String route = selectedJudgeRoute();
  if (directory == null ||
      directory.isEmpty ||
      route == 'local' ||
      (environ['JUDGE_CACHE'] ?? '1') != '1' ||
      questions.isEmpty) {
    return jevUncached(state, questions, timeout: timeout, retries: retries);
  }
  final String fingerprint = digest(<String, Object?>{
    'state': state,
    'questions': questions,
    'model': jevModel,
    'route': route,
    'url': jevUrl,
    if (route == 'free-then-model' || route == 'model') ...<String, Object?>{
      'fallback_model': environ['JUDGE_MODEL'] ?? environ['RECAP_MODEL'] ?? '',
      'fallback_url': baseFor(
        protocolFor(environ['JUDGE_MODEL'] ?? environ['RECAP_MODEL'] ?? ''),
      ),
    },
    'version': 1,
  });
  final File path = File('$directory/cache/$fingerprint.json');
  final Semaphore lock = _cacheLocks.putIfAbsent(
    path.absolute.path,
    () => Semaphore(1),
  );
  return lock.run(() async {
    if (path.existsSync()) {
      final Json saved = pyJsonLoads(path.readAsStringSync())! as Json;
      if (saved['request_sha256'] != fingerprint)
        throw const LLMError('裁判缓存校验失败');
      validateAnswers(saved['answers'], questions, 'judge cache');
      return saved['answers']! as Json;
    }
    if (route == 'free-then-model' || route == 'free-then-paid') {
      // Successful free-only judgments remain reusable after this book opts
      // into either fallback. A failed free request never creates a cache.
      final String freeFingerprint = digest(<String, Object?>{
        'state': state,
        'questions': questions,
        'model': jevModel,
        'route': 'free-only',
        'url': jevUrl,
        'version': 1,
      });
      final File freePath = File('$directory/cache/$freeFingerprint.json');
      if (freePath.existsSync()) {
        final Json saved = pyJsonLoads(freePath.readAsStringSync())! as Json;
        if (saved['request_sha256'] != freeFingerprint) {
          throw const LLMError('裁判缓存校验失败');
        }
        validateAnswers(saved['answers'], questions, 'judge cache');
        return saved['answers']! as Json;
      }
    }
    final Json answers = await jevUncached(
      state,
      questions,
      timeout: timeout,
      retries: retries,
    );
    path.parent.createSync(recursive: true);
    final File tmp = File(
      '${path.path.substring(0, path.path.length - 5)}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    tmp.writeAsStringSync(
      _dumps(<String, Object?>{
        'request_sha256': fingerprint,
        'answers': answers,
        'route': _routeUsed == 'unknown' ? route : _routeUsed,
        'model': jevModel,
      }),
    );
    tmp.renameSync(path.path);
    return answers;
  });
}
