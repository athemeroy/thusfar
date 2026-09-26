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
import 'llm.dart';
import 'provenance.dart';

String get jevUrl =>
    environ['JEV_URL'] ?? 'https://ai-gateway.vercel.sh/v1/evaluate';
String get jevModel => environ['JEV_MODEL'] ?? 'typesafe-ai/jev';
String get classifierUrl =>
    environ['CLASSIFIER_URL'] ?? 'https://classifier.dev/v1/classify';

const int classifierDims = 20;
const int classifierDimChars = 16000;
const int classifierInstructionChars = 4000;

typedef Json = Map<String, Object?>;

/// What the judge costs; reset per book run.
final Map<String, num> jevStats = <String, num>{
  'calls': 0,
  'chars': 0,
  'questions': 0,
  'paid_chars': 0,
  'passage_chars': 0,
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
    });
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

/// The same contract as [jev], answered by an ordinary chat model.
Future<Json> llmJudge(Object? state, Json questions, {String? model}) async {
  String pick(String k) => environ[k] ?? '';
  final String m =
      model ??
      (pick('JUDGE_MODEL').isNotEmpty
          ? pick('JUDGE_MODEL')
          : pick('RECAP_MODEL').isNotEmpty
          ? pick('RECAP_MODEL')
          : 'deepseek-flash+nothink');
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
  final int budget = 200 + 120 * qs.length;
  ChatResult r = await chat(m, msgs, maxTokens: budget, temperature: 0);
  Map<String, Object?> usage = r.usage;
  Object? data;
  try {
    data = parseJson(r.text);
  } on ValueError {
    final ChatResult fix = await chat(
      m,
      <Map<String, String>>[
        ...msgs,
        <String, String>{'role': 'assistant', 'content': r.text},
        <String, String>{
          'role': 'user',
          'content': 'Reply again with only the JSON object.',
        },
      ],
      maxTokens: budget,
      temperature: 0,
    );
    data = parseJson(fix.text);
    usage = <String, Object?>{
      for (final String k in const <String>[
        'prompt_tokens',
        'completion_tokens',
      ])
        k: ((usage[k] as num?) ?? 0) + ((fix.usage[k] as num?) ?? 0),
    };
    r = fix;
  }
  final Json out = <String, Object?>{};
  for (final MapEntry<String, Object?> e in questions.entries) {
    final Object? a = data is Json ? data[e.key] : null;
    final Object? rawProbs = a is Json ? a['probabilities'] : null;
    final Json given = rawProbs is Json ? rawProbs : <String, Object?>{};
    final Map<String, double> probs = <String, double>{
      for (final String o in _criteria(e.value).keys) o: _toFloat(given[o]),
    };
    double total = probs.values.fold(0.0, (double a, double b) => a + b);
    if (total == 0) total = 1.0;
    final Map<String, double> norm = <String, double>{
      for (final MapEntry<String, double> p in probs.entries)
        p.key: PyCompat.roundDigits(p.value / total, 3),
    };
    Object? choice = a is Json ? a['choice'] : null;
    if (!norm.containsKey(choice)) {
      choice = null;
      double best = double.negativeInfinity;
      for (final MapEntry<String, double> p in norm.entries) {
        if (p.value > best) {
          best = p.value;
          choice = p.key;
        }
      }
    }
    out[e.key] = <String, Object?>{
      'type': 'choice',
      'choice': choice,
      'probabilities': norm,
      'by': m,
    };
  }
  out['_usage'] = usage;
  return out;
}

double _toFloat(Object? v) {
  if (v == null || v == false || v == 0 || v == '') return 0.0;
  if (v == true) return 1.0;
  if (v is num) return v.toDouble();
  if (v is String) {
    final double? d = double.tryParse(v.trim());
    if (d != null) return d;
  }
  throw ValueError('could not convert string to float: ${PyJson.encode(v)}');
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
  await sleep(Duration(microseconds: (wait * 1e6).round()));
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
  int detailBytes,
) async {
  final ChatResponse resp = await transport.post(
    ChatRequest(Uri.parse(url), headers, body),
    Duration(microseconds: (timeout * 1e6).round()),
  );
  final List<int> raw = <int>[];
  await for (final List<int> chunk in resp.body) {
    raw.addAll(chunk);
    if (raw.length > 16 * 1024 * 1024) throw const LLMError('模型响应超过大小上限');
  }
  if (resp.status >= 400) {
    throw _HttpFailure(
      resp.status,
      utf8.decode(raw.take(detailBytes).toList(), allowMalformed: true),
      resp.headers,
    );
  }
  return pyJsonLoads(utf8.decode(raw, allowMalformed: true));
}

/// A classifier.dev failure that knows when the daily quota reopens.
final class ReopeningError extends LLMError {
  const ReopeningError(super.message, this.reopensIn);

  final double reopensIn;
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
        if (e.code == 400 || e.code == 401 || e.code == 403) throw err;
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
  final String? d = environ['JUDGE_LOG_DIR'];
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
          'model': jevModel,
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

/// Call the selected judge route, with explicit bounded paid overflow only.
Future<Json> jevUncached(
  Object? state,
  Json questions, {
  int timeout = 90,
  int? retries,
}) async {
  if (questions.isEmpty) return <String, Object?>{};
  final Stopwatch started = Stopwatch()..start();
  String route = environ['JEV_ROUTE'] ?? 'free-only';
  if (route == 'free') route = 'free-only';
  if (!const <String>[
    'local',
    'free-only',
    'free-then-paid',
    'paid',
  ].contains(route)) {
    throw const LLMError('未知裁判路由；使用 local、free-only、free-then-paid 或 paid');
  }
  if (route == 'local') return jevLocal(state, questions);
  if ((route == 'free-only' || route == 'free-then-paid') &&
      freeBreaker.allow()) {
    try {
      final Json out = await jevFree(state, questions, timeout: timeout);
      freeBreaker.ok();
      _routeUsed = 'free';
      teacherLog(state, questions, out, 'free');
      return out;
    } on DeadlineExceeded {
      rethrow;
    } on Object catch (e) {
      freeBreaker.failed(
        _str(e),
        cool: e is ReopeningError && e.reopensIn != 0 ? e.reopensIn : null,
      );
      if (route == 'free-only') {
        throw LLMError('免费裁判暂不可用，未调用付费接口：${_typeName(e)}: ${_str(e)}');
      }
      logLine(
        '[judge] classifier.dev unavailable, falling back to the paid route: ${String.fromCharCodes(_str(e).runes.take(120))}',
      );
    }
  } else if (route == 'free-only') {
    throw const LLMError('免费裁判处于冷却期，未调用付费接口；稍后可从缓存继续');
  }
  final String keyName = environ['JEV_KEY_NAME'] ?? '';
  final String? key =
      (keyName.isNotEmpty ? llmEnv(keyName) : null) ??
      (jevUrl.contains('vercel') ? llmEnv('VERCEL_AI_GATEWAY_KEY') : null) ??
      llmEnv('JEV_API_KEY');
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
        );
      });
      if (data is! Json || data.containsKey('error'))
        throw const ValueError('Jev: invalid response');
      final Object? out =
          _truthy(data['answers'])
              ? data['answers']
              : (_truthy(data['results']) ? data['results'] : data);
      validateAnswers(out, questions, 'Jev');
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
  final String? directory = environ['JUDGE_LOG_DIR'];
  final String route = environ['JEV_ROUTE'] ?? 'free-only';
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
