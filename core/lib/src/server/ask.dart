/// Grounded, prefix-bounded question answering (`server/ask.py`).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../env.dart';
import '../errors.dart';
import '../pipeline/judge.dart' as judge;
import '../pipeline/llm.dart' as llm;
import '../py/py_compat.dart';
import '../py/py_int.dart';
import '../py/py_re.dart';
import 'storage.dart';
import 'temporal.dart';

export 'temporal.dart' show Json;

typedef AskEvent = void Function(String kind, Json value);

const String _system = '''你是一位读书伙伴，陪读者读《{title}》。读者现在读到了{where}。
规则（必须遵守）：
1. 只能根据下面【材料】回答。材料只包含读者已经读过的内容。即使你知道这部作品，也绝不能透露材料以外的任何情节、身份、结局或后来的变化。
2. 不要对后面的发展做任何预测、暗示或铺垫（不要说“恐怕”“注定”“后来会”“还会发生”之类的话）。
3. 如果材料不足以回答，就直说“读到这里还看不出来”，再说说目前已知的相关情况。
4. 【前情提要】【人物】【最近发生的事】是整理出的摘要，可以转述，但不要加引号当作原文。只有【原文n】里的句子才能用「」直接引用，并在句末标注 [n]。关键判断尽量给出 [n] 出处。
5. 回答具体、有温度、简洁（一般 80～250 字），用读者提问的语言回答（中文提问就用中文，人名可保留原文拼写），不要使用 Markdown 标题或列表符号。''';
final Set<int> _stop =
    '的了是在他她它们我你这那一个也就都而及与和或着过吗呢吧啊呀么什怎为何哪谁说道把被让给从到对向于以之其所有没不很还又再已'.runes.toSet();
final Set<String> _enStop =
    "the and that with was were had have has his her him she they them their this there then than what when where which who whom would could should shall will not but for from into upon about said says say one all any are been being did does your you our out very some such only own more most much like just over also how why its it's"
        .split(' ')
        .toSet();
String _head(String s, int count) => String.fromCharCodes(s.runes.take(count));
Json _obj(Object? v) => v is Json ? v : <String, Object?>{};
List<Json> _rows(Object? v) =>
    ((v as List<Object?>?) ?? <Object?>[]).cast<Json>();
num _num(Object? v) => v is num ? v : 0;
List<String> _names(Json p) => <String>[
  p['name']! as String,
  ...(p['aliases']! as List<Object?>).cast<String>(),
];

/// UTF-16 offsets, discarding an incomplete surrogate just as Python does.
String prefixText(String text, int units) {
  int end = units.clamp(0, text.length);
  if (end > 0 &&
      end < text.length &&
      text.codeUnitAt(end - 1) >= 0xd800 &&
      text.codeUnitAt(end - 1) <= 0xdbff)
    end--;
  return text.substring(0, end);
}

Set<String> bigrams(String text) {
  final Set<String> words =
      RegExp(r"[A-Za-z][A-Za-z'’]{2,}")
          .allMatches(text)
          .map((RegExpMatch m) => m[0]!.toLowerCase().replaceAll('’', "'"))
          .toSet()
        ..removeAll(_enStop);
  final List<int> chars =
      text.replaceAll(pyRe(r'[\sA-Za-z0-9]'), '').runes.toList();
  for (int i = 0; i + 1 < chars.length; i++) {
    if (!(_stop.contains(chars[i]) && _stop.contains(chars[i + 1])))
      words.add(String.fromCharCodes(chars.sublist(i, i + 2)));
  }
  return words;
}

List<Json> recentText(Json book, int pos, {int chars = 900}) {
  final List<Json> out = <Json>[];
  int total = 0;
  for (final Json b in _rows(book['blocks']).reversed) {
    final int o = b['o']! as int;
    if (o >= pos || b['k'] != 'p') continue;
    final String text = prefixText(b['t']! as String, pos - o);
    out.add(<String, Object?>{'o': o, 't': text});
    total += text.runes.length;
    if (total >= chars) break;
  }
  return out.reversed.toList();
}

List<Json> _bookIndex(Json book) {
  final List<Json> out = <Json>[];
  final List<Json> blocks = _rows(book['blocks']);
  for (final Json c in _rows(book['chapters'])) {
    if (c['kind'] != 'body') continue;
    for (int i = c['b0']! as int; i < (c['b1']! as int); i++) {
      final Json b = blocks[i];
      if (b['k'] == 'p' && (b['t']! as String).runes.length >= 8)
        out.add(<String, Object?>{'o': b['o'], 't': b['t']});
    }
  }
  return out;
}

List<Json> retrieve(
  Json book,
  String q,
  List<String> names,
  int pos, {
  int k = 14,
  List<Json>? index,
}) {
  if (k <= 0) return <Json>[];
  final Set<String> query = bigrams(q);
  for (final String name in names) {
    query.addAll(bigrams(name));
  }
  final List<(int, String, Set<String>)> readable =
      <(int, String, Set<String>)>[];
  for (final Json row in index ?? _bookIndex(book)) {
    final int o = row['o']! as int;
    if (o >= pos) continue;
    final String text = prefixText(row['t']! as String, pos - o);
    readable.add((o, text, bigrams(text).intersection(query)));
  }
  if (readable.isEmpty) return <Json>[];
  final Map<String, int> df = <String, int>{};
  for (final (_, _, Set<String> grams) in readable) {
    for (final String gram in grams) {
      df[gram] = (df[gram] ?? 0) + 1;
    }
  }
  final Map<String, double> weight = <String, double>{
    for (final String gram in query)
      gram: math.log(1 + readable.length / (1 + (df[gram] ?? 0))),
  };
  for (final String name in names) {
    for (final String gram in bigrams(name)) {
      weight[gram] = (weight[gram] ?? 0) * 1.5;
    }
  }
  final List<(double, int, String)> scored = <(double, int, String)>[];
  for (final (int o, String text, Set<String> grams) in readable) {
    if (grams.isEmpty) continue;
    final List<String> sorted = grams.toList()..sort();
    final double sum = sorted.fold(0.0, (double s, String x) => s + weight[x]!);
    scored.add((sum / (1 + .002 * text.runes.length), o, text));
  }
  scored.sort(((double, int, String) a, (double, int, String) b) {
    final int score = b.$1.compareTo(a.$1);
    if (score != 0) return score;
    final int offset = b.$2.compareTo(a.$2);
    return offset != 0 ? offset : b.$3.compareTo(a.$3);
  });
  if (scored.length < k) {
    final Set<int> seen = scored.map(((double, int, String) p) => p.$2).toSet();
    final int slots = k - scored.length;
    for (int i = 0; i < math.min(slots, readable.length); i++) {
      final int at =
          pyRound(
            i * (readable.length - 1) / math.max(1, slots - 1),
            0,
          ).toInt();
      final (int o, String text, _) = readable[at];
      if (!seen.contains(o)) scored.add((0, o, text));
    }
  }
  final List<(double, int, String)> top =
      scored.take(k).toList()..sort(
        ((double, int, String) a, (double, int, String) b) =>
            a.$2.compareTo(b.$2),
      );
  return <Json>[
    for (final (_, int o, String text) in top)
      <String, Object?>{'o': o, 't': text},
  ];
}

/// Instance-local seam for recordings; production uses the shared clients.
class AskBackend {
  const AskBackend();
  Future<(String, Json)> route(String question) =>
      judge.routeQuestion(question);
  Future<Json> evaluate(Object? state, Json questions) =>
      judge.judgeCall(state, questions);
  Future<Json> guard(String material, String text) => judge.guardTexts(
    material,
    <String, Object?>{},
    <String, Object?>{'a': text},
  );
  Future<String> complete(
    String model,
    List<Map<String, String>> messages, {
    required int maxTokens,
    required double temperature,
    required double timeout,
  }) async =>
      (await llm.chat(
        model,
        messages,
        maxTokens: maxTokens,
        temperature: temperature,
        timeout: timeout,
        retries: 0,
      )).text;
}

Future<List<Json>> rankByJudge(
  String question,
  List<Json> passages, {
  int keep = 6,
  AskBackend backend = const AskBackend(),
}) async {
  if (passages.length <= 2 || (environ['JUDGE_RETRIEVAL'] ?? '1') != '1')
    return passages.take(keep).toList();
  final Json questions = <String, Object?>{
    for (int i = 0; i < passages.length; i++)
      'p$i': <String, Object?>{
        'type': 'choice',
        'instructions':
            'Reader asks: $question\nDoes this passage from the book help answer that?\nPASSAGE: ${_head(passages[i]['t']! as String, 1200)}',
        'criteria': <String, Object?>{
          'answers':
              'Yes — it contains part of the answer, or the fact being asked about.',
          'related':
              'Same topic or people, but it does not answer the question.',
          'unrelated': 'No.',
        },
      },
  };
  final Json answer;
  try {
    answer = await backend.evaluate(<String, Object?>{
      'note': 'Judge each passage on its own.',
    }, questions);
  } on Object {
    return passages.take(keep).toList();
  }
  final List<(double, int, Json)> scores = <(double, int, Json)>[];
  for (int i = 0; i < passages.length; i++) {
    final Json probs = _obj(_obj(answer['p$i'])['probabilities']);
    scores.add((
      _num(probs['answers']).toDouble() + .3 * _num(probs['related']),
      i,
      passages[i],
    ));
  }
  scores.sort(
    ((double, int, Json) a, (double, int, Json) b) =>
        a.$1 == b.$1 ? a.$2.compareTo(b.$2) : b.$1.compareTo(a.$1),
  );
  List<Json> chosen =
      scores
          .where(((double, int, Json) x) => x.$1 >= .3)
          .take(keep)
          .map(((double, int, Json) x) => x.$3)
          .toList();
  if (chosen.isEmpty)
    chosen = scores.take(2).map(((double, int, Json) x) => x.$3).toList();
  return chosen
    ..sort((Json a, Json b) => (a['o']! as int).compareTo(b['o']! as int));
}

Future<String> retrievalQuery(
  String question,
  Json book, {
  AskBackend backend = const AskBackend(),
  String? model,
}) async {
  final String lang = book['lang'] as String? ?? 'zh';
  final bool cjk = RegExp(r'[\u3040-\u30ff\u3400-\u9fff]').hasMatch(question);
  if ((lang == 'zh' || lang == 'ja') == cjk ||
      (environ['QUERY_TRANSLATION'] ?? '1') != '1')
    return question;
  try {
    final String translated = await backend.complete(
      model ?? environ['QA_MODEL'] ?? 'deepseek-flash+nothink',
      <Map<String, String>>[
        <String, String>{
          'role': 'system',
          'content':
              'Translate the reader query into $lang for lexical search. Return only the translated query. Do not answer it, add facts, or guess identities.',
        },
        <String, String>{'role': 'user', 'content': question},
      ],
      maxTokens: 150,
      temperature: 0,
      timeout: 20,
    );
    return '$question ${_head(translated.trim(), 600)}';
  } on Object {
    return question;
  }
}

bool accepted(Json verdict) {
  final Object? p = verdict['p'];
  return verdict['verdict'] == 'ok' && p is num && p >= .4 && p <= 1;
}

/// Stop between remote calls; unverified text is never emitted.
class AskCancellation {
  bool _cancelled = false;
  void cancel() => _cancelled = true;
  void check() {
    if (_cancelled) throw const llm.LLMError('已停止回答');
  }
}

class AskService {
  AskService({
    this.backend = const AskBackend(),
    this.timeout = const Duration(seconds: 180),
  });
  final AskBackend backend;
  final Duration timeout;
  final LinkedHashMap<String, Json> _answers = LinkedHashMap<String, Json>();
  final LinkedHashMap<String, (List<Json>, int)> _indexes =
      LinkedHashMap<String, (List<Json>, int)>();
  int _running = 0;

  /// Memory-only cache: exact source bytes, prefix, question and model settings.
  /// Refused and failed replies never enter the cache.
  Future<Json> answer(
    Directory directory,
    String question,
    int pos, {
    AskEvent? onEvent,
    AskCancellation? cancellation,
    void Function()? onSettled,
  }) async {
    bool handedOff = false;
    try {
      if (_running >= 2) throw const llm.LLMError('正在回答其他问题，请稍后重试');
      final String q = _head(question.trim(), 500);
      if (q.isEmpty) throw const ValueError('问题是空的');
      final List<List<int>> source = <List<int>>[];
      Json read(String name, {bool required = false}) {
        final File file = File('${directory.path}/$name');
        if (!file.existsSync() && !required) {
          source.add(<int>[]);
          return <String, Object?>{};
        }
        final List<int> bytes = file.readAsBytesSync();
        source.add(bytes);
        final Object? raw = jsonDecode(utf8.decode(bytes));
        if (raw is! Json) throw ValueError('$name 格式无效');
        return raw;
      }

      final Json book = validateBook(read('book.json', required: true));
      final Json kg = validateGraph(read('kg.json'), book['len']! as int);
      final Json status = read('status.json');
      integer(pos, '阅读位置', high: book['len']! as int);
      final String model = environ['QA_MODEL'] ?? 'deepseek-flash+nothink';
      final String config = _configFingerprint();
      final String key =
          sha256
              .convert(
                utf8.encode(
                  jsonEncode(<Object?>[
                    directory.absolute.path,
                    ...source.map(
                      (List<int> b) => sha256.convert(b).toString(),
                    ),
                    q,
                    pos,
                    config,
                  ]),
                ),
              )
              .toString();
      final AskCancellation token = cancellation ?? AskCancellation();
      token.check();
      final Json? cached = _answers.remove(key);
      if (cached != null) {
        _answers[key] = cached;
        final Json result = <String, Object?>{
          ..._clone(cached),
          'cached': true,
        };
        onEvent?.call('answer', result);
        return result;
      }
      final String bookKey = sha256.convert(source.first).toString();
      final (List<Json>, int)? saved = _indexes.remove(bookKey);
      final List<Json> index = saved?.$1 ?? _bookIndex(book);
      final int weight =
          saved?.$2 ??
          index.fold(
            0,
            (int n, Json p) => n + utf8.encode(p['t']! as String).length + 64,
          );
      if (weight <= 4 * 1024 * 1024) {
        _indexes[bookKey] = (index, weight);
        while (_indexes.length > 4 ||
            _indexes.values.fold(0, (int n, (List<Json>, int) x) => n + x.$2) >
                8 * 1024 * 1024) {
          _indexes.remove(_indexes.keys.first);
        }
      }
      _running++;
      final Future<Json> work = answerSnapshot(
        book,
        kg,
        status,
        q,
        pos,
        backend: backend,
        model: model,
        index: index,
        cancellation: token,
        onEvent: onEvent,
        auditDirectory: directory,
      );
      // A timeout stops publication, but the transport may still be unwinding.
      // Keep its concurrency permit until that work actually settles.
      handedOff = true;
      unawaited(
        work.then<void>(
          (Json _) {
            _running--;
            onSettled?.call();
          },
          onError: (Object _, StackTrace __) {
            _running--;
            onSettled?.call();
          },
        ),
      );
      final Json result = await work.timeout(
        timeout,
        onTimeout: () {
          token.cancel();
          throw const llm.DeadlineExceeded('回答超时，请稍后重试');
        },
      );
      token.check();
      if (_obj(result['guard'])['verdict'] != 'withheld' &&
          config == _configFingerprint()) {
        _answers[key] = _clone(result);
        while (_answers.length > 24 ||
            utf8.encode(jsonEncode(_answers)).length > 512 * 1024) {
          _answers.remove(_answers.keys.first);
        }
      }
      return result;
    } finally {
      if (!handedOff) onSettled?.call();
    }
  }
}

Json _clone(Json value) => jsonDecode(jsonEncode(value)) as Json;

Future<Json> answerSnapshot(
  Json book,
  Json kg,
  Json status,
  String question,
  int pos, {
  AskBackend backend = const AskBackend(),
  String? model,
  List<Json>? index,
  AskCancellation? cancellation,
  AskEvent? onEvent,
  Directory? auditDirectory,
}) async {
  final Stopwatch clock = Stopwatch()..start();
  final AskCancellation token = cancellation ?? AskCancellation();
  final String qaModel =
      model ?? environ['QA_MODEL'] ?? 'deepseek-flash+nothink';
  void emit(String kind, Json payload) {
    token.check();
    onEvent?.call(kind, payload);
  }

  void stage(String text) => emit('stage', <String, Object?>{'text': text});
  final bool chinese = RegExp(r'[\u3400-\u9fff]').hasMatch(question);
  stage('理解你的问题');
  String route = 'other';
  Json probs = <String, Object?>{};
  try {
    (route, probs) = await backend.route(question);
  } on Object {
    token.check();
  }
  token.check();
  emit('route', <String, Object?>{
    'route': route,
    'p': pyRound(probs[route] ?? 0, 2),
  });
  if (route == 'future' && _num(probs['future']) >= .5) {
    final Json result = <String, Object?>{
      'text':
          chinese
              ? '后面的内容要继续读下去才知道；我现在不会透露或预测后续情节。'
              : 'That concerns later pages. I will not reveal or predict events beyond your current position.',
      'cites': <Json>[],
      'route': route,
      'guard': <String, Object?>{'verdict': 'safe', 'reason': 'future'},
      'people': <String>[],
      'position': pos,
      'ms': clock.elapsedMilliseconds,
    };
    emit('answer', result);
    return result;
  }
  stage('翻阅你读过的部分');
  final int frontier = (status['frontier'] as num?)?.toInt() ?? 0;
  final Json world = foldEvidence(
    _rows(kg['log']),
    frontier != 0 ? math.min(pos, frontier) : pos,
  );
  final Json people = world['people']! as Json;
  final List<Json> all = people.values.cast<Json>().toList();
  final Map<String, int> insertion = <String, int>{
    for (int i = 0; i < all.length; i++) all[i]['id']! as String: i,
  };
  int stable(Json a, Json b) =>
      insertion[a['id']]!.compareTo(insertion[b['id']]!);
  final List<Json> ordered = List<Json>.of(all)..sort((Json a, Json b) {
    final int result = _names(b)
        .map((String n) => n.runes.length)
        .reduce(math.max)
        .compareTo(
          _names(a).map((String n) => n.runes.length).reduce(math.max),
        );
    return result != 0 ? result : stable(a, b);
  });
  final List<Json> named = <Json>[];
  for (final Json p in ordered) {
    if (_names(
      p,
    ).any((String n) => n.runes.length >= 2 && question.contains(n)))
      named.add(p);
  }
  final List<Json> rels = (world['rels']! as Json).values.cast<Json>().toList();
  final Set<String> grams = bigrams(question);
  for (final Json p in List<Json>.of(named)) {
    for (final Json r in rels) {
      if (r['a'] != p['id'] && r['b'] != p['id']) continue;
      final bool mine = r['a'] == p['id'];
      final Json? other = people[r[mine ? 'b' : 'a']] as Json?;
      final String role = r[mine ? 'b_is' : 'a_is'] as String? ?? '';
      if (other != null &&
          !named.contains(other) &&
          role.isNotEmpty &&
          (bigrams(role).intersection(grams).isNotEmpty ||
              question.contains(role)))
        named.add(other);
    }
  }
  if (named.isEmpty && <String>['who', 'relation', 'recap'].contains(route)) {
    all.sort((Json a, Json b) {
      final int result = _num(b['n']).compareTo(_num(a['n']));
      return result != 0 ? result : stable(a, b);
    });
    named.addAll(all.take(3));
  }
  final List<String> names = named.expand(_names).toList();
  final String query = await retrievalQuery(
    question,
    book,
    backend: backend,
    model: qaModel,
  );
  token.check();
  final List<Json> passages = await rankByJudge(
    question,
    retrieve(book, query, names, pos, index: index),
    backend: backend,
  );
  token.check();
  final Set<Object?> seen = passages.map((Json p) => p['o']).toSet();
  passages.addAll(
    recentText(book, pos).where((Json p) => !seen.contains(p['o'])),
  );
  passages.sort((Json a, Json b) => (a['o']! as int).compareTo(b['o']! as int));
  final List<String> parts = <String>[];
  if (world['saga'] != '') parts.add('【前情提要】\n${world['saga']}');
  for (final Json p in named.take(5)) {
    final List<String> lines = <String>[];
    for (final Json r in rels) {
      if (r['a'] != p['id'] && r['b'] != p['id']) continue;
      final bool mine = r['a'] == p['id'];
      final Json other = people[r[mine ? 'b' : 'a']]! as Json;
      final String timing =
          r['status'] == 'ended'
              ? '过去的关系，已结束'
              : r['status'] == 'changed'
              ? '关系已经变化，以下是当前记录'
              : '截至已读位置';
      lines.add(
        '${other['name']}（${r[mine ? 'b_is' : 'a_is'] ?? ''}；$timing）：${r['desc'] ?? ''}',
      );
    }
    final List<Json> events = _rows(p['events']);
    final String evs = events
        .skip(math.max(0, events.length - 8))
        .map((Json e) => e['text'])
        .join('；');
    final String attrs = (p['attrs']! as Json).entries
        .map((MapEntry<String, Object?> e) => '${e.key}：${e.value}')
        .join('；');
    final String aliases = (p['aliases']! as List<Object?>).toSet().join('、');
    parts.add(
      '【人物：${p['name']}】又称：${aliases.isEmpty ? '无' : aliases}\n${p['tagline']}。${p['bio']}\n档案：${attrs.isEmpty ? '无' : attrs}\n关系：${lines.isEmpty ? '无' : lines.join('；')}\n经历：${evs.isEmpty ? '无' : evs}',
    );
  }
  final List<Json> events = _rows(world['events']);
  if (events.isNotEmpty)
    parts.add(
      '【最近发生的事】\n${events.skip(math.max(0, events.length - 12)).map((Json e) => '- ${e['text']}').join('\n')}',
    );
  List<Json> cites = <Json>[];
  for (int i = 0; i < passages.length; i++) {
    final Json p = passages[i];
    parts.add('【原文${i + 1}】${p['t']}');
    cites.add(<String, Object?>{
      'n': i + 1,
      'o': p['o'],
      'text': _head(p['t']! as String, 80),
    });
  }
  final String material = parts.join('\n\n');
  final List<Json> chapters = _rows(book['chapters']);
  final int chapter = chapters.indexWhere(
    (Json c) => _num(c['o0']) <= pos && pos <= _num(c['o1']),
  );
  final String where = chapter < 0 ? '当前位置' : '第 ${chapter + 1} 章的当前位置';
  final String system = _system.replaceAllMapped(
    RegExp(r'\{(title|where)\}'),
    (Match m) => m[1] == 'title' ? book['title']! as String : where,
  );
  String user = '【材料】\n$material\n\n【读者的问题】$question';
  if (frontier != 0 && pos > frontier)
    user += '\n\n（说明：人物资料目前只整理到读者位置之前的一部分，原文材料是完整的。）';
  stage('组织回答');
  final List<Map<String, String>> messages = <Map<String, String>>[
    <String, String>{'role': 'system', 'content': system},
    <String, String>{'role': 'user', 'content': user},
  ];
  String text =
      (await backend.complete(
        qaModel,
        messages,
        maxTokens: 1200,
        temperature: .3,
        timeout: 90,
      )).trim();
  stage('检查有没有剧透');
  Json guard = <String, Object?>{};
  final List<Json> rejected = <Json>[];
  try {
    final Json first = _obj((await backend.guard(material, text))['a']);
    token.check();
    guard = <String, Object?>{'p': first['p'], 'verdict': first['verdict']};
    if (!accepted(first)) {
      rejected.add(<String, Object?>{'text': text, 'guard': first});
      stage('发现可能超出已读内容的说法，正在重写');
      final String rewrite = await backend.complete(
        qaModel,
        <Map<String, String>>[
          ...messages,
          <String, String>{'role': 'assistant', 'content': text},
          <String, String>{
            'role': 'user',
            'content':
                '自动校验发现上面的回答里有材料没有提供的内容（可能是编造或后文剧透）。请严格只用材料重写回答，材料里没有的一律不说。',
          },
        ],
        maxTokens: 1200,
        temperature: .2,
        timeout: 90,
      );
      token.check();
      final Json second = _obj((await backend.guard(material, rewrite))['a']);
      token.check();
      guard = <String, Object?>{
        'p': second['p'],
        'verdict': accepted(second) ? 'rewritten' : 'withheld',
        'first': first['p'],
      };
      if (accepted(second)) {
        text = rewrite.trim();
      } else {
        rejected.add(<String, Object?>{'text': rewrite, 'guard': second});
      }
    }
  } on Object {
    token.check();
    rejected.add(<String, Object?>{
      'text': text,
      'guard': <String, Object?>{'reason': 'verification_unavailable'},
    });
    guard = <String, Object?>{
      'verdict': 'withheld',
      'reason': 'verification_unavailable',
    };
  }
  if (guard['verdict'] == 'withheld') {
    text =
        chinese
            ? '这次回答未能通过已读原文核对，我暂时不展示它，以免透露后文或说错。你可以稍后重试，或回到相关原文查看。'
            : 'I could not verify this answer against the pages you have read, so I have withheld it. Please retry later or check the relevant passage.';
    cites = <Json>[];
  }
  if (rejected.isNotEmpty && auditDirectory != null)
    _audit(auditDirectory, pos, question, rejected);
  text = text
      .replaceAllMapped(
        RegExp(r'"([^"\n]{1,80})"', unicode: true),
        (Match m) => '「${m[1]}」',
      )
      .replaceAllMapped(
        RegExp(r'“([^”\n]{1,80})”', unicode: true),
        (Match m) => '「${m[1]}」',
      )
      .replaceAll(pyRe(r'\s*\[(?!\d+\])[^\]]{1,12}\]'), '');
  String plain(String s) => s.replaceAll(pyRe(r'[\s，。、；：？！“”‘’「」…—]'), '');
  final Map<int, String> sources = <int, String>{
    for (final Json c in cites)
      c['n']! as int: plain(passages[(c['n']! as int) - 1]['t']! as String),
  };
  text = text.replaceAllMapped(pyRe(r'「([^」]{1,80})」\s*(?:\[(\d+)\])?'), (
    Match m,
  ) {
    final String body = m[1]!;
    final String? number = m[2];
    final String pool =
        number == null
            ? sources.values.join()
            : sources[_citationNumber(number, sources.length)] ?? '';
    return '${plain(body).isNotEmpty && pool.contains(plain(body)) ? '「$body」' : body}${number == null ? '' : '[$number]'}';
  });
  final Set<int> used =
      pyRe(r'\[(\d+)\]')
          .allMatches(text)
          .map((RegExpMatch m) => _citationNumber(m[1]!, passages.length))
          .whereType<int>()
          .toSet();
  final Json result = <String, Object?>{
    'text': text,
    'cites': cites.where((Json c) => used.contains(c['n'])).toList(),
    'route': route,
    'guard': guard,
    'people': named.take(5).map((Json p) => p['id']).toList(),
    'position': pos,
    'ms': clock.elapsedMilliseconds,
  };
  emit('answer', result);
  return result;
}

void _audit(Directory book, int pos, String question, List<Json> rejected) {
  try {
    final String name =
        book.uri.pathSegments.where((String p) => p.isNotEmpty).last;
    final File file = File('${book.parent.parent.path}/qa-audit/$name.jsonl');
    file.parent.createSync(recursive: true);
    if (file.existsSync() && file.lengthSync() > 1000000) {
      final File old = File(
        file.path.replaceFirst(RegExp(r'\.jsonl$'), '.previous.jsonl'),
      );
      if (old.existsSync()) old.deleteSync();
      file.renameSync(old.path);
    }
    file.writeAsStringSync(
      '${jsonEncode(<String, Object?>{'at': DateTime.now().millisecondsSinceEpoch / 1000, 'position': pos, 'question': question, 'rejected': rejected})}\n',
      mode: FileMode.append,
      flush: true,
    );
  } on FileSystemException {
    /* Local auditing does not expose rejected prose. */
  }
}

int? _citationNumber(String text, int maximum) {
  final BigInt? value = tryPythonDecimal(text);
  return value != null && value >= BigInt.zero && value <= BigInt.from(maximum)
      ? value.toInt()
      : null;
}

/// Resolve an exact selected occurrence using only people and prose already read.
Future<Json> whoIs(
  Json book,
  List<Json> log,
  int pos,
  int start,
  int end, {
  AskBackend backend = const AskBackend(),
}) async {
  if (start < 0 || end <= start || end > pos)
    return <String, Object?>{'ok': false, 'why': '选中位置无效'};
  final Json people = foldEvidence(log, pos)['people']! as Json;
  if (people.isEmpty)
    return <String, Object?>{'ok': false, 'why': 'nobody yet'};
  final int left = math.max(0, start - 1500), right = math.min(pos, end + 200);
  final List<String> window = <String>[];
  String word = '';
  for (final Json b in _rows(book['blocks'])) {
    final int offset = b['o']! as int;
    final String raw = b['t']! as String;
    if (offset <= start && offset + raw.length >= end && word.isEmpty)
      word = _sliceUtf16(raw, start - offset, end - offset);
    if (offset + raw.length < left || offset >= right) continue;
    final int lo = math.max(0, left - offset),
        hi = math.min(raw.length, right - offset);
    final String text;
    if (offset <= start && start < end && end <= offset + raw.length) {
      final int a = start - offset, z = end - offset;
      text =
          '${_sliceUtf16(raw, lo, a)}<selected>${_sliceUtf16(raw, a, z)}</selected>${_sliceUtf16(raw, z, hi)}';
    } else {
      text = _sliceUtf16(raw, lo, hi);
    }
    if (text.isNotEmpty) window.add(text);
  }
  final String passage = window.join('\n');
  if (word.isEmpty || !passage.contains('<selected>'))
    return <String, Object?>{'ok': false, 'why': '选中位置无效'};
  final List<Json> near = people.values.cast<Json>().toList();
  final Map<Object?, int> original = <Object?, int>{
    for (int i = 0; i < near.length; i++) near[i]['id']: i,
  };
  int local(Json p) => _names(p)
      .where((String n) => n.runes.length >= 2)
      .fold(-1, (int best, String n) => math.max(best, passage.lastIndexOf(n)));
  near.sort((Json a, Json b) {
    final int byLocal = local(b).compareTo(local(a));
    if (byLocal != 0) return byLocal;
    num count(Json p) => _num(p['n']) + (_num(p['imp']) >= 3 ? 40 : 0);
    final int byCount = count(b).compareTo(count(a));
    return byCount != 0
        ? byCount
        : original[a['id']]!.compareTo(original[b['id']]!);
  });
  final Json criteria = <String, Object?>{
    for (final Json p in near.take(12))
      p['id']! as String:
          '${p['name']}（${p['tagline'] != '' ? p['tagline'] : _head(p['bio']! as String, 40)}）',
    'unknown':
        'Someone the reader has not been introduced to yet, or not a person at all.',
  };
  final Json result;
  try {
    result = _obj(
      (await backend.evaluate(
        <String, Object?>{'this_passage': passage},
        <String, Object?>{
          'w': <String, Object?>{
            'type': 'choice',
            'instructions':
                'In this_passage, who does 「$word」 refer to at the exact occurrence marked <selected>...</selected>?',
            'criteria': criteria,
          },
        },
      ))['w'],
    );
  } on Object catch (e) {
    return <String, Object?>{'ok': false, 'why': _head('$e', 120)};
  }
  final Object? choice = result['choice'];
  final num probability = pyRound(
    _obj(result['probabilities'])[choice] ?? 0,
    3,
  );
  if (people.containsKey(choice) && probability >= .45 && probability <= 1)
    return <String, Object?>{
      'ok': true,
      'id': choice,
      'name': (people[choice]! as Json)['name'],
      'p': probability,
      'word': word,
    };
  return <String, Object?>{
    'ok': false,
    'why': 'unsure',
    'p': probability,
    'word': word,
  };
}

String _sliceUtf16(String text, int start, int end) {
  int a = start.clamp(0, text.length), z = end.clamp(0, text.length);
  if (a < z && text.codeUnitAt(a) >= 0xdc00 && text.codeUnitAt(a) <= 0xdfff)
    a++;
  if (z > a &&
      text.codeUnitAt(z - 1) >= 0xd800 &&
      text.codeUnitAt(z - 1) <= 0xdbff)
    z--;
  return z <= a ? '' : text.substring(a, z);
}

String _configFingerprint() =>
    sha256
        .convert(
          utf8.encode(
            jsonEncode(<Object?>[
              for (final String name in <String>[
                'QA_MODEL',
                'JUDGE_MODEL',
                'JEV_ROUTE',
                'JUDGE_RETRIEVAL',
                'QUERY_TRANSLATION',
                'LLM_BASE_URL',
                'LLM_BASE_URL_OPENAI',
                'LLM_BASE_URL_ANTHROPIC',
                'LLM_BASE_URL_GEMINI',
                'LLM_PROTOCOL',
                'LLM_PROTOCOL_MAP',
                'LLM_KEY_MAP',
                'LLM_KEY_NAME',
              ])
                environ[name] ?? llm.llmEnv(name),
            ]),
          ),
        )
        .toString();
