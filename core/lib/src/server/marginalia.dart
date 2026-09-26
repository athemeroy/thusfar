/// Source-anchored reader comments (`server/marginalia.py`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../async_util.dart';
import '../env.dart';
import '../errors.dart';
import '../pipeline/jev.dart' as jev;
import '../pipeline/judge.dart' as judge;
import '../pipeline/llm.dart' as llm;
import '../pipeline/provenance.dart';
import '../py/py_compat.dart';
import '../py/py_re.dart';
import '../py/py_repr.dart';
import 'ask.dart' show recentText;
import 'marginalia_prompts.dart';
import 'notebook.dart' show sourceQuote;
import 'storage.dart' as storage;
import 'temporal.dart';

export 'marginalia_prompts.dart' show personas, categoryPersona, commentStyles;
export 'temporal.dart' show Json;

const int cueVersion = 5, promptVersion = 7, maxCache = 2000;
String get model =>
    environ['MARGINALIA_MODEL'] ??
    environ['QA_MODEL'] ??
    'deepseek-flash+nothink';
String get autoModel =>
    environ['MARGINALIA_AUTO_MODEL'] ??
    environ['MARGINALIA_MODEL'] ??
    'gemini-2.5-flash-lite';
Json _obj(Object? v) => v as Json? ?? {};
List<Json> _rows(Object? v) => (v as List<Object?>? ?? []).cast<Json>();
List<Object?> _list(Object? v) => v as List<Object?>? ?? [];
String _str(Object? v, [String fallback = '']) =>
    v == null || v == false || v == '' ? fallback : pyStr(v);
num _num(Object? v, [num fallback = 0]) =>
    v is num
        ? v
        : v is bool
        ? (v ? 1 : 0)
        : fallback;
String _head(String s, int n) => PyCompat.slice(s, 0, n);
String _tail(String s, int n) => PyCompat.slice(s, -n, null);
String _trim(String s) => PyCompat.strip(s);
int _cp(String s) => s.runes.length;

String sliceU16(String text, int start, int end) {
  // Python byte slicing accepts negative indices and silently drops incomplete
  // surrogate pairs when decoding with errors='ignore'.
  final int length = text.length;
  int a = (start < 0 ? length + start : start).clamp(0, length),
      z = (end < 0 ? length + end : end).clamp(0, length);
  if (a < z && text.codeUnitAt(a) >= 0xdc00 && text.codeUnitAt(a) <= 0xdfff)
    a++;
  if (z > a &&
      text.codeUnitAt(z - 1) >= 0xd800 &&
      text.codeUnitAt(z - 1) <= 0xdbff)
    z--;
  return z <= a ? '' : text.substring(a, z);
}

List<Json> pageCandidates(Json book, int start, int end) {
  List<Json> out = [];
  for (final Json block in _rows(book['blocks'])) {
    if (!['p', 'h'].contains(block['k'])) continue;
    final String raw = block['t']! as String;
    final int b0 = block['o']! as int, b1 = b0 + raw.length;
    if (b1 <= start || b0 >= end) continue;
    final int lo = math.max(start, b0) - b0, hi = math.min(end, b1) - b0;
    final String visible = sliceU16(raw, lo, hi);
    final int visibleOffset = b0 + lo;
    for (final RegExpMatch match in pyRe(
      r'[^。！？!?；;.\n]+(?:[。！？!?；;.]+|$)',
    ).allMatches(visible)) {
      final String part = match[0]!;
      final String quote = _trim(part);
      if (_cp(quote) < 6 ||
          _cp(quote) > 180 ||
          !pyRe(r'[\w\u3400-\u9fff]').hasMatch(quote))
        continue;
      final int left =
          part.length - part.replaceFirst(pyRe(r'^\s+'), '').length;
      final int s = visibleOffset + match.start + left, e = s + quote.length;
      if (start <= s && s < e && e <= end)
        out.add({'start': s, 'end': e, 'quote': quote});
    }
  }
  if (out.length > 10) {
    final double step = (out.length - 1) / 9;
    out = [
      for (int i = 0; i < 10; i++)
        out[(PyCompat.round(i * step) as num).toInt()],
    ];
  }
  return out;
}

String sourceBefore(Json book, int pos, {int chars = 2400}) => _tail(
  _trim(recentText(book, pos, chars: chars).map((r) => r['t']).join('\n')),
  chars,
);
String story(Json world, {String focus = '', int limitPeople = 12}) {
  final List<String> parts = [];
  if (_str(world['saga']).isNotEmpty)
    parts.add('故事线：${_head(pyStr(world['saga']), 700)}');
  final Json peopleById = _obj(world['people']);
  final Set<String> focused = {
    for (final e in peopleById.entries)
      if ([
        _str(_obj(e.value)['name']),
        ..._list(_obj(e.value)['aliases']).cast<String>(),
      ].any((n) => _cp(n) >= 2 && focus.contains(n)))
        e.key,
  };
  final List<Json> allEvents = _rows(world['events']),
      recent = allEvents.skip(math.max(0, allEvents.length - 14)).toList();
  final List<Json> related =
      allEvents
          .take(math.max(0, allEvents.length - 14))
          .where((e) => _list(e['who']).any(focused.contains))
          .toList();
  final List<String> events = [
    for (final Json e in [
      ...related.skip(math.max(0, related.length - 6)),
      ...recent,
    ])
      if (_str(e['text']).isNotEmpty) _head(pyStr(e['text']), 180),
  ];
  if (events.isNotEmpty) parts.add('此前事件：${events.join('；')}');
  final Set<Object?> recentIds = {
    for (final Json e in recent) ..._list(e['who']),
  };
  final List<Json> people = PyCompat.stableSorted(
    peopleById.values.cast<Json>(),
    key:
        (p) => [
          -(focused.contains(p['id']) ? 1 : 0),
          -(recentIds.contains(p['id']) ? 1 : 0),
          -_num(p['n']),
          -_num(p['imp']),
        ],
  );
  final List<String> cards = [];
  for (final Json p in people.take(limitPeople)) {
    final List<String> bits = [
      _head(_str(p['name']), 40),
      _head(_str(p['tagline']), 100),
      _head(_str(p['bio']), 180),
    ];
    final List<String> aliases =
        _list(
          p['aliases'],
        ).cast<String>().where(focus.contains).take(3).toList();
    if (aliases.isNotEmpty) bits.add('本页别名：${aliases.join('、')}');
    final String attrs = _head(
      _obj(
        p['attrs'],
      ).entries.take(8).map((e) => '${e.key}：${pyStr(e.value)}').join('、'),
      240,
    );
    if (attrs.isNotEmpty) bits.add(attrs);
    cards.add(bits.where((s) => s.isNotEmpty).join('｜'));
  }
  if (cards.isNotEmpty) parts.add('人物状态：${cards.join('\n')}');
  final Json names = {
    for (final e in peopleById.entries) e.key: _obj(e.value)['name'] ?? e.key,
  };
  final List<Json> relations = _obj(world['rels']).values.cast<Json>().toList();
  final List<Json> focusedRelations =
      relations
          .where((r) => focused.contains(r['a']) || focused.contains(r['b']))
          .toList();
  final List<Json> chosen =
      focusedRelations.skip(math.max(0, focusedRelations.length - 12)).toList();
  for (final Json r in relations.skip(math.max(0, relations.length - 16))) {
    if (!chosen.any((prior) => _sameJson(prior, r))) chosen.add(r);
  }
  final List<String> rels = [
    for (final Json r in chosen.take(18))
      '${names[r['a']] ?? pyStr(r['a'])}—${names[r['b']] ?? pyStr(r['b'])}：${_head(_str(r['desc'], _str(r['a_is'], _str(r['b_is'], '有关联'))), 120)}',
  ];
  if (rels.isNotEmpty) parts.add('人物关系：${rels.join('；')}');
  return parts.isEmpty ? '此前没有可用的故事线摘要。' : parts.join('\n');
}

bool _sameJson(Object? a, Object? b) => digest(a) == digest(b);
String material(
  Json book,
  List<Json> log,
  int frontier,
  int end,
  String quote,
) {
  final Json world = foldEvidence(
    log,
    frontier != 0 ? math.min(end, frontier) : end,
  );
  final String recent = sourceBefore(book, end, chars: 2600);
  return [
    '【截至这句话的故事状态】\n${story(world, focus: '$recent\n$quote')}',
    if (recent.isNotEmpty) '【此前原文】\n$recent',
    '【被划线的原句】\n$quote',
  ].join('\n\n');
}

String clean(String text) {
  text = _trim(text).replaceFirst(pyRe(r'^\s*(?:批注|评论|弹幕|短评)\s*[：:]\s*'), '');
  text = _trim(text.replaceAll(pyRe(r'```.*?```', dotAll: true), ''));
  text = text
      .split(pyRe(r'\r\n|[\n\r\v\f\x1c-\x1e\x85\u2028\u2029]'))
      .map(_trim)
      .where((s) => s.isNotEmpty)
      .join(' ');
  text = _head(PyCompat.strip(text, chars: '“”"'), 160);
  if (pyRe(r'[\u3400-\u9fff]').allMatches(text).length < 6 ||
      ['，', ',', '：', ':'].any(text.endsWith) ||
      pyRe(r'Markdown|JSON|系统提示', ignoreCase: true).hasMatch(text))
    return '';
  return text;
}

bool accepted(Json verdict) =>
    verdict['verdict'] == 'ok' &&
    (verdict['p'] is num || verdict['p'] is bool) &&
    _num(verdict['p']) >= .4;
List<String> commentPersonas(String first) =>
    <String>{first, 'detective', 'empathy', 'wit'}.take(3).toList();
String key(Json payload) => digest({
  'v': payload['mode'] == 'cues' ? cueVersion : promptVersion,
  ...payload,
}).substring(0, 32);

/// Python difflib.SequenceMatcher(None,a,b).ratio(). Comment bodies contain at
/// most 160 code points, so its popular-element (autojunk) threshold is inactive.
double sequenceRatio(String a, String b) {
  final List<int> x = a.runes.toList(), y = b.runes.toList();
  if (x.isEmpty && y.isEmpty) return 1;
  final Map<int, List<int>> indices = {};
  for (int j = 0; j < y.length; j++) {
    indices.putIfAbsent(y[j], () => []).add(j);
  }
  if (y.length >= 200) {
    final int limit = y.length ~/ 100 + 1;
    indices.removeWhere((_, v) => v.length > limit);
  }
  final List<(int, int, int, int)> queue = [(0, x.length, 0, y.length)];
  int matches = 0;
  while (queue.isNotEmpty) {
    final (int lo, int hi, int blo, int bhi) = queue.removeLast();
    int bestA = lo, bestB = blo, size = 0;
    Map<int, int> prior = {};
    for (int i = lo; i < hi; i++) {
      final Map<int, int> next = {};
      for (final int j in indices[x[i]] ?? <int>[]) {
        if (j < blo) continue;
        if (j >= bhi) break;
        final int n = (prior[j - 1] ?? 0) + 1;
        next[j] = n;
        if (n > size) {
          bestA = i - n + 1;
          bestB = j - n + 1;
          size = n;
        }
      }
      prior = next;
    }
    while (bestA > lo && bestB > blo && x[bestA - 1] == y[bestB - 1]) {
      bestA--;
      bestB--;
      size++;
    }
    while (bestA + size < hi &&
        bestB + size < bhi &&
        x[bestA + size] == y[bestB + size]) {
      size++;
    }
    if (size == 0) continue;
    matches += size;
    if (lo < bestA && blo < bestB) queue.add((lo, bestA, blo, bestB));
    if (bestA + size < hi && bestB + size < bhi)
      queue.add((bestA + size, hi, bestB + size, bhi));
  }
  return 2 * matches / (x.length + y.length);
}

class MarginaliaCancelled implements Exception {
  const MarginaliaCancelled();
  @override
  String toString() => '已停止批注';
}

class MarginaliaCancellation {
  final Completer<void> _signal = Completer<void>();
  bool get isCancelled => _signal.isCompleted;
  Future<void> get whenCancelled => _signal.future;
  void cancel() {
    if (!isCancelled) _signal.complete();
  }

  void check() {
    if (isCancelled) throw const MarginaliaCancelled();
  }
}

typedef MarginaliaEvent = void Function(String stage);
typedef MarginaliaRead = Object? Function(File file);
typedef MarginaliaWrite = void Function(File file, Object? value);
typedef MarginaliaRevision = Object? Function(File file);

class MarginaliaBackend {
  const MarginaliaBackend();
  Future<Json> evaluate(Json state, Json questions) =>
      jev.jev(state, questions);
  Future<Json> guard(String passage, Json items) =>
      judge.guardTexts(passage, {}, items);
  Future<String> complete(
    String model,
    List<Map<String, String>> messages, {
    required int maxTokens,
    required double temperature,
    required double timeout,
    required int retries,
  }) async =>
      (await llm.chat(
        model,
        messages,
        maxTokens: maxTokens,
        temperature: temperature,
        timeout: timeout,
        retries: retries,
      )).text;
  List<String> styles(int count) {
    final List<String> choices = [...commentStyles]..shuffle(math.Random());
    return choices.take(count).toList();
  }

  double now() => DateTime.now().microsecondsSinceEpoch / 1e6;
}

Object? _readJson(File file) =>
    file.existsSync() ? jsonDecode(file.readAsStringSync()) : null;

class MarginaliaService {
  MarginaliaService({
    this.backend = const MarginaliaBackend(),
    MarginaliaRead? readJson,
    MarginaliaWrite? writeJson,
    this.graphRevision,
    this.timeout = const Duration(seconds: 180),
  }) : readJson = readJson ?? _readJson,
       writeJson = writeJson ?? storage.writeJson;
  final MarginaliaBackend backend;
  final MarginaliaRead readJson;
  final MarginaliaWrite writeJson;
  final MarginaliaRevision? graphRevision;
  final Duration timeout;
  final Semaphore _models = Semaphore(3),
      _prefetch = Semaphore(2),
      _comments = Semaphore(4);
  final Map<String, Semaphore> _locks = {};
  final Map<String, List<Semaphore>> _stripes = {};
  Semaphore _lock(Directory root) =>
      _locks.putIfAbsent(root.resolveSymbolicLinksSync(), () => Semaphore(1));
  Semaphore _keyLock(Directory root, String key) =>
      _stripes.putIfAbsent(
        root.resolveSymbolicLinksSync(),
        () => List.generate(64, (_) => Semaphore(1)),
      )[int.parse(key.substring(0, 8), radix: 16) % 64];
  Future<List<Json>> select(
    Json book,
    List<Json> log,
    int frontier,
    int pageStart,
    int pageEnd, {
    MarginaliaCancellation? cancellation,
  }) async {
    final MarginaliaCancellation token =
        cancellation ?? MarginaliaCancellation();
    token.check();
    final List<Json> candidates = pageCandidates(book, pageStart, pageEnd);
    if (candidates.isEmpty) return [];
    final Json world = foldEvidence(
      log,
      frontier != 0 ? math.min(pageStart, frontier) : pageStart,
    );
    final String prior = sourceBefore(book, pageStart);
    final Json visible = {
      for (final (int i, Json r) in candidates.indexed) 's${i + 1}': r['quote'],
    };
    final Json state = {
      'story_before_this_page': story(
        world,
        focus: '$prior\n${visible.values.join('\n')}',
      ),
      'source_before_this_page': prior,
      'visible_page_sentences': visible,
    };
    final Json criteria = {
      'ordinary':
          'A routine transition or isolated line that gains little from a reader reaction.',
      'feeling':
          'A specific emotional undercurrent made richer by the story so far.',
      'clue':
          'A concrete detail, information gap, or callback already supported by the read text.',
      'theme':
          'A revealing moment of motive, self-deception, power, or manners.',
      'craft':
          'Distinctive wording, viewpoint, rhythm, image, or structural turn.',
      'wit':
          'A real irony, reversal, or comic contrast that supports a brief witty reaction.',
    };
    final Json questions = {
      for (final (int i, Json row) in candidates.indexed)
        's${i + 1}': {
          'type': 'choice',
          'instructions':
              'Which kind of short reader reaction, if any, would fit this exact sentence? Use only story_before_this_page, source_before_this_page and visible_page_sentences; never infer later plot. Choose ordinary if there is no concrete reason to comment. Sentence: ${row['quote']}',
          'criteria': criteria,
        },
    };
    final Json answers = await backend.evaluate(state, questions);
    token.check();
    final double threshold = double.parse(
      environ['MARGINALIA_MIN_SCORE'] ?? '0.45',
    );
    final List<(double, Json)> eligible = [];
    for (final (int i, Json row) in candidates.indexed) {
      final Json answer = _obj(answers['s${i + 1}']),
          probs = _obj(answer['probabilities']);
      final Object? choice = answer['choice'];
      final double score = 1 - _num(probs['ordinary'], 1).toDouble(),
          confidence = choice != null ? _num(probs[choice]).toDouble() : 0;
      if (!categoryPersona.containsKey(choice) ||
          score < threshold ||
          confidence < .38)
        continue;
      eligible.add((
        score * (.7 + .3 * confidence),
        {
          ...row,
          'persona': categoryPersona[choice],
          'kind': choice,
          'score': pyRound(score, 3),
        },
      ));
    }
    final int span = pageEnd - pageStart,
        limit = math.min(4, math.max(1, (span + 199) ~/ 280)),
        gap = math.max(80, span ~/ (limit + 1));
    final List<Json> selected = [];
    for (final (_, Json row) in PyCompat.stableSorted(
      eligible,
      key: (r) => -r.$1,
    )) {
      if (selected.every(
        (p) => ((row['start']! as int) - (p['start']! as int)).abs() >= gap,
      )) {
        selected.add(row);
        if (selected.length == limit) break;
      }
    }
    selected.sort((a, b) => (a['start']! as int).compareTo(b['start']! as int));
    return selected;
  }

  Future<String> writeComment(
    String material,
    String persona, {
    String? previous,
    String? model,
    String? style,
    MarginaliaCancellation? cancellation,
  }) async {
    final MarginaliaCancellation token =
        cancellation ?? MarginaliaCancellation();
    token.check();
    final List<String> voice = personas[persona]!;
    final String system =
        commentSystem
            .replaceAll('{label}', voice[0])
            .replaceAll('{voice}', voice[1]) +
        (style ?? backend.styles(1).single);
    final String user =
        material +
        (previous != null && previous.isNotEmpty
            ? '\n\n上一版未通过材料核对：$previous\n请删掉材料没有支持的判断，重新写一句。'
            : '');
    final String raw = await _comments.run(() {
      token.check();
      return backend.complete(
        model ?? _manualModel,
        [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': user},
        ],
        maxTokens: 160,
        temperature: persona == 'wit' ? .75 : .65,
        timeout: 45,
        retries: 0,
      );
    });
    token.check();
    final String result = clean(raw);
    if (result.isEmpty) throw const ValueError('AI 这次没有写出可用的批注，请稍后再试');
    return result;
  }

  String get _manualModel => model;
  Future<(String, Json)> generate(
    Json book,
    List<Json> log,
    int frontier,
    Json selected, {
    String? model,
    MarginaliaCancellation? cancellation,
    MarginaliaEvent? onEvent,
  }) async {
    final MarginaliaCancellation token =
        cancellation ?? MarginaliaCancellation();
    final String source = material(
      book,
      log,
      frontier,
      selected['end']! as int,
      selected['quote']! as String,
    );
    token.check();
    onEvent?.call('正在写批注');
    String text = await writeComment(
      source,
      selected['persona']! as String,
      model: model,
      cancellation: token,
    );
    token.check();
    onEvent?.call('核对已读原文');
    Json verdict = _obj(
      (await backend.guard(source, {'comment': text}))['comment'],
    );
    token.check();
    if (!accepted(verdict)) {
      onEvent?.call('删去未获支持的内容，重新写一句');
      text = await writeComment(
        source,
        selected['persona']! as String,
        previous: text,
        model: model,
        cancellation: token,
      );
      token.check();
      final Json second = _obj(
        (await backend.guard(source, {'comment': text}))['comment'],
      );
      token.check();
      if (!accepted(second)) throw const ValueError('这条批注没有通过已读内容核对，已替你隐藏');
      verdict = {
        'verdict': 'rewritten',
        'p': second['p'],
        'first': verdict['p'],
      };
    }
    return (text, {'verdict': verdict['verdict'], 'p': verdict['p']});
  }

  Future<List<Json>> generateMany(
    Json book,
    List<Json> log,
    int frontier,
    Json selected, {
    String? model,
    MarginaliaCancellation? cancellation,
    MarginaliaEvent? onEvent,
  }) async {
    final MarginaliaCancellation token =
        cancellation ?? MarginaliaCancellation();
    token.check();
    onEvent?.call('正在写不同角度的读者评论');
    final String source = material(
      book,
      log,
      frontier,
      selected['end']! as int,
      selected['quote']! as String,
    );
    final List<String> voices = commentPersonas(selected['persona']! as String),
        styles = backend.styles(voices.length);
    final List<Object> failures = [];
    final List<String?> results = await Future.wait([
      for (final (int i, String voice) in voices.indexed)
        writeComment(
          source,
          voice,
          model: model ?? autoModel,
          style: styles[i],
          cancellation: token,
        ).then<String?>(
          (s) => s,
          onError: (Object e, StackTrace _) {
            failures.add(e);
            return null;
          },
        ),
    ]);
    token.check();
    final Json drafts = {
      for (final (int i, String voice) in voices.indexed)
        if (results[i] != null) voice: results[i],
    };
    if (drafts.isEmpty) throw failures.first;
    final Map<String, String> unique = {};
    for (final e in drafts.entries) {
      final String normalized =
          (e.value! as String)
              .replaceAll(pyRe(r'[^\w\u3400-\u9fff]'), '')
              .toLowerCase();
      if (unique.values.any((p) => sequenceRatio(normalized, p) >= .82))
        continue;
      unique[e.key] = normalized;
    }
    onEvent?.call('核对已读原文');
    final Json verdicts = await backend.guard(source, {
      for (final String voice in unique.keys) voice: drafts[voice],
    });
    token.check();
    final List<Json> items = [
      for (final String voice in unique.keys)
        if (accepted(_obj(verdicts[voice])))
          {
            ...selected,
            'persona': voice,
            'comment': drafts[voice],
            'guard': {'verdict': 'ok', 'p': _obj(verdicts[voice])['p']},
          },
    ];
    if (items.isEmpty) throw const ValueError('这次生成的评论没有通过已读内容核对，点虚线可重试');
    return items;
  }

  Future<Json> respond(
    Directory root,
    Object? data, {
    MarginaliaCancellation? cancellation,
    MarginaliaEvent? onEvent,
    void Function()? onSettled,
  }) async {
    final MarginaliaCancellation token =
        cancellation ?? MarginaliaCancellation();
    final Future<Json> operation = Future<Json>.sync(() {
      token.check();
      return _respond(root, data, token, onEvent);
    });
    unawaited(
      operation.then<void>(
        (_) => onSettled?.call(),
        onError: (Object _, StackTrace __) => onSettled?.call(),
      ),
    );
    // Cancellation/timeout suppresses publication immediately. The operation
    // keeps its gates until the underlying calls settle and observe the token.
    return Future.any([
      operation,
      token.whenCancelled.then<Json>((_) => throw const MarginaliaCancelled()),
    ]).timeout(
      timeout,
      onTimeout: () {
        token.cancel();
        throw const llm.DeadlineExceeded('批注超时，请稍后重试');
      },
    );
  }

  Future<Json> _respond(
    Directory root,
    Object? data,
    MarginaliaCancellation token,
    MarginaliaEvent? onEvent,
  ) async {
    if (data is! Json) throw const ValueError('评论请求格式无效');
    final Json book = storage.validateBook(
          readJson(File('${root.path}/book.json')),
        ),
        graph = storage.validateGraph(
          readJson(File('${root.path}/kg.json')) ?? <String, Object?>{},
          book['len']! as int,
        ),
        status = _obj(readJson(File('${root.path}/status.json')));
    final Object? mode = data['mode'] ?? 'manual',
        purpose = data['purpose'] ?? 'visible',
        persona = data['persona'] ?? 'auto';
    if (!['manual', 'auto', 'cues'].contains(mode))
      throw const ValueError('评论模式无效');
    if (!['visible', 'prefetch'].contains(purpose) ||
        mode == 'manual' && purpose != 'visible')
      throw const ValueError('评论请求用途无效');
    final int pos = storage.integer(
      data['pos'],
      '已读位置',
      high: book['len']! as int,
    );
    if (persona != 'auto' && !personas.containsKey(persona))
      throw const ValueError('不认识这种批注口吻');
    final int frontier =
        status['frontier'] is int ? status['frontier']! as int : 0;
    final File graphFile = File('${root.path}/kg.json');
    // Native cache identity deliberately uses source/graph content and model
    // configuration, avoiding Python's platform-specific inode/mtime tuple.
    // Existing records remain in marginalia.json; oracle adapters may inject
    // the historical revision tuple to compare the original protocol exactly.
    final Object? revision =
        graphRevision != null
            ? graphRevision!(graphFile)
            : digest({
              'book': book,
              'graph': graph,
              'model': model,
              'auto_model': autoModel,
              'settings': [
                for (final String name in [
                  'JUDGE_MODEL',
                  'JEV_ROUTE',
                  'LLM_BASE_URL',
                  'LLM_BASE_URL_OPENAI',
                  'LLM_BASE_URL_GEMINI',
                  'LLM_BASE_URL_ANTHROPIC',
                  'MARGINALIA_MIN_SCORE',
                  'LLM_PROTOCOL',
                  'LLM_PROTOCOL_MAP',
                  'LLM_KEY_MAP',
                  'LLM_KEY_NAME',
                ])
                  environ[name] ?? llm.llmEnv(name),
              ],
            });
    final Json payload = {
      'mode': mode,
      'pos': pos,
      'persona': persona,
      'knowledge_frontier': math.min(pos, frontier),
      'graph_revision': revision,
    };
    int start = 0, end = 0;
    String quote = '';
    if (mode == 'manual') {
      start = storage.integer(data['start'], '划线位置', high: pos);
      end = storage.integer(data['end'], '划线终点', low: start + 1, high: pos);
      quote = sourceQuote(book, start, end);
      if (_trim(quote).isEmpty || _cp(quote) > 600)
        throw const ValueError('请选择 1～600 字的原文生成批注');
      payload.addAll({'start': start, 'end': end, 'quote': quote});
    } else {
      start = storage.integer(data['page_start'], '本页起点', high: pos);
      end = storage.integer(
        data.containsKey('page_end') ? data['page_end'] : pos,
        '本页终点',
        low: start,
        high: pos,
      );
      if (end - start > 12000) throw const ValueError('本页范围过大，请重新翻页后再试');
      payload.addAll({'page_start': start, 'page_end': end});
    }
    final String cacheKey = key(payload);
    final File path = File('${root.path}/marginalia.json');
    List<Json> cacheRows() {
      final Object? raw = readJson(path);
      if (raw == null) return [];
      if (raw is! List<Object?> || raw.any((r) => r is! Json))
        throw const ValueError('已保存的批注格式无效，请先保留原文件');
      return raw.cast<Json>();
    }

    Json? lookup(List<Json> rows) {
      for (final Json r in rows) {
        if (r['key'] == cacheKey &&
            _verifiedCache(r, mode! as String, book, pos, start, end))
          return {...r, 'cached': true};
      }
      return null;
    }

    final Json? old = await _lock(root).run(() async => lookup(cacheRows()));
    token.check();
    if (old != null) return old;
    return _keyLock(root, cacheKey).run(() async {
      token.check();
      final Json? old = await _lock(root).run(() async => lookup(cacheRows()));
      token.check();
      if (old != null) return old;
      Future<Json> generateRecord() => _models.run(() async {
        token.check();
        if (mode == 'cues') {
          onEvent?.call('从已读页面挑选值得一读的句子');
          return {
            'key': cacheKey,
            'items': await select(
              book,
              _rows(graph['log']),
              frontier,
              start,
              end,
              cancellation: token,
            ),
            'reason': 'cues',
            'created': backend.now(),
          };
        }
        if (mode == 'auto') {
          quote = sourceQuote(book, start, end);
          if (_trim(quote).isEmpty || _cp(quote) > 600)
            throw const ValueError('点选的原文范围无效，请重新点虚线');
        }
        final Json selected = {
          'start': start,
          'end': end,
          'quote': quote,
          'persona': persona == 'auto' ? 'empathy' : persona,
          'kind': mode == 'auto' ? 'reader' : 'manual',
          'score': 1.0,
        };
        if (mode == 'auto') {
          final List<Json> items = [
            for (final Json item in await generateMany(
              book,
              _rows(graph['log']),
              frontier,
              selected,
              model: autoModel,
              cancellation: token,
              onEvent: onEvent,
            ))
              {...item, 'position': pos, 'knowledge_cutoff': end},
          ];
          return {
            'key': cacheKey,
            ...items.first,
            'items': items,
            'created': backend.now(),
          };
        }
        final (String comment, Json guard) = await generate(
          book,
          _rows(graph['log']),
          frontier,
          selected,
          model: model,
          cancellation: token,
          onEvent: onEvent,
        );
        return {
          'key': cacheKey,
          'comment': comment,
          'start': start,
          'end': end,
          'quote': quote,
          'persona': selected['persona'],
          'kind': selected['kind'],
          'score': selected['score'],
          'guard': guard,
          'position': pos,
          'knowledge_cutoff': end,
          'created': backend.now(),
        };
      });
      final Json record =
          purpose == 'prefetch'
              ? await _prefetch.run(generateRecord)
              : await generateRecord();
      token.check();
      return _lock(root).run(() async {
        token.check();
        final List<Json> rows = cacheRows();
        final Json? old = lookup(rows);
        if (old != null) return old;
        // A changed source/graph/settings while a request was in flight must
        // not publish or cache an answer against a different reader snapshot.
        if (graphRevision == null) {
          final Json currentBook = storage.validateBook(
                readJson(File('${root.path}/book.json')),
              ),
              currentGraph = storage.validateGraph(
                readJson(graphFile) ?? <String, Object?>{},
                currentBook['len']! as int,
              );
          final Object? now = digest({
            'book': currentBook,
            'graph': currentGraph,
            'model': model,
            'auto_model': autoModel,
            'settings': [
              for (final String name in [
                'JUDGE_MODEL',
                'JEV_ROUTE',
                'LLM_BASE_URL',
                'LLM_BASE_URL_OPENAI',
                'LLM_BASE_URL_GEMINI',
                'LLM_BASE_URL_ANTHROPIC',
                'MARGINALIA_MIN_SCORE',
                'LLM_PROTOCOL',
                'LLM_PROTOCOL_MAP',
                'LLM_KEY_MAP',
                'LLM_KEY_NAME',
              ])
                environ[name] ?? llm.llmEnv(name),
            ],
          });
          if (now != revision) throw const ValueError('书籍内容或模型设置已更新，请重新生成批注');
        }
        final List<Json> updated = [...rows, record];
        writeJson(
          path,
          updated.skip(math.max(0, updated.length - maxCache)).toList(),
        );
        return {...record, 'cached': false};
      });
    });
  }

  bool _verifiedCache(
    Json record,
    String mode,
    Json book,
    int pos,
    int start,
    int end,
  ) {
    bool anchor(Json r) {
      if (r['start'] is! int || r['end'] is! int) return false;
      final int a = r['start']! as int, z = r['end']! as int;
      if (a < start || z > end || z <= a) return false;
      try {
        return r['quote'] == sourceQuote(book, a, z);
      } on Object {
        return false;
      }
    }

    bool safe(Json r) =>
        anchor(r) &&
        r['knowledge_cutoff'] == r['end'] &&
        r['position'] == pos &&
        r['comment'] is String &&
        clean(r['comment']! as String).isNotEmpty &&
        ['ok', 'rewritten'].contains(_obj(r['guard'])['verdict']) &&
        _num(_obj(r['guard'])['p']) >= .4;
    if (mode == 'cues')
      return record['reason'] == 'cues' &&
          record['items'] is List &&
          _rows(record['items']).every(anchor);
    if (mode == 'auto')
      return record['items'] is List &&
          _rows(record['items']).isNotEmpty &&
          _rows(record['items']).every(safe) &&
          safe(record);
    return safe(record);
  }
}

final MarginaliaService _defaultService = MarginaliaService();
Future<Json> respond(
  Directory root,
  Object? data, {
  MarginaliaCancellation? cancellation,
  MarginaliaEvent? onEvent,
}) => _defaultService.respond(
  root,
  data,
  cancellation: cancellation,
  onEvent: onEvent,
);
