/// Resumable extraction, evidence verification and chronological graph compiler.
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
import '../py/py_int.dart';
import '../py/py_json.dart';
import '../py/py_re.dart';
import '../py/py_repr.dart';
import 'book_policy.dart' as policy;
import 'extract.dart' as extraction;
import 'jev.dart' as jevClient;
import 'judge.dart' as judge;
import 'kg.dart';
import 'lang.dart' as lang;
import 'link.dart' as linking;
import 'llm.dart' as llm;
import 'local.dart' as local;
import 'provenance.dart';
import 'run_lease.dart';
import 'run_prompts.dart' as prompts;

export 'run_lease.dart';
part 'run_support.dart';
part 'run_finalize.dart';
part 'run_loop.dart';

const int relationJudgeRevision = 2;
String get defaultModel => environ['EXTRACT_MODEL'] ?? 'deepseek-flash+nothink';
String get recapModel => environ['RECAP_MODEL'] ?? 'deepseek-flash+nothink';
const List<String> _classicKeys = [
  'new_people',
  'aliases',
  'merges',
  'events',
  'attrs',
  'rels',
  'profiles',
];
bool _truth(Object? v) =>
    v != null &&
    v != false &&
    v != 0 &&
    (v is! String || v.isNotEmpty) &&
    (v is! Iterable || v.isNotEmpty) &&
    (v is! Map || v.isNotEmpty);
Json _obj(Object? v) => v as Json? ?? {};
List<Json> _rows(Object? v) => ((v as List<Object?>?) ?? []).cast<Json>();
List<Object?> _list(Object? v) => v as List<Object?>? ?? [];
String _str(Object? v, [String fallback = '']) =>
    _truth(v) ? pyStr(v) : fallback;
String _cut(String v, int n) => PyCompat.slice(v, null, n);
String _tail(String v, int n) => PyCompat.slice(v, -n, null);
String _trim(String v) => PyCompat.strip(v);
int _int(Object? v, [int fallback = 0]) =>
    v is num
        ? v.toInt()
        : v is bool
        ? (v ? 1 : 0)
        : fallback;
num _num(Object? v, [num fallback = 0]) =>
    v is num
        ? v
        : v is bool
        ? (v ? 1 : 0)
        : fallback;
int _cp(String v) => v.runes.length;
List<String> _sorted(Iterable<String> v) => v.toList()..sort(PyCompat.compare);
Set<String> _set(Object? v) =>
    (v as Iterable<Object?>? ?? []).cast<String>().toSet();
Object? _clone(Object? v) =>
    v is Map
        ? <String, Object?>{
          for (final e in v.entries) e.key as String: _clone(e.value),
        }
        : v is List
        ? v.map(_clone).toList()
        : v is Set
        ? v.map(_clone).toSet()
        : v;
Json _read(File file) => jsonDecode(file.readAsStringSync()) as Json;
String _fmt(String pattern, Json args) {
  final String sentinelOpen = '\u0001', sentinelClose = '\u0002';
  String out = pattern
      .replaceAll('{{', sentinelOpen)
      .replaceAll('}}', sentinelClose);
  out = out.replaceAllMapped(RegExp(r'\{([^{}]+)\}'), (m) => pyStr(args[m[1]]));
  return out.replaceAll(sentinelOpen, '{').replaceAll(sentinelClose, '}');
}

String _error(Object error) => error is PyException ? error.message : '$error';
String _typedError(Object error) =>
    error is PyException
        ? '${error.pyType.split('.').last}: ${error.message}'
        : '${error.runtimeType}: $error';
int _writeSequence = 0;
void writeJson(File file, Object? data, {bool compact = true}) {
  file.parent.createSync(recursive: true);
  final File tmp = File('${file.path}.$pid.${_writeSequence++}.tmp');
  try {
    tmp.writeAsStringSync(
      PyJson.encode(data, ensureAscii: false, compact: compact),
    );
    tmp.renameSync(file.path);
  } finally {
    if (tmp.existsSync()) tmp.deleteSync();
  }
}

/// Override only the external boundaries in deterministic offline tests.
class RunBackend {
  const RunBackend();
  double now() => DateTime.now().microsecondsSinceEpoch / 1e6;
  Future<void> sleep(Duration duration) => Future<void>.delayed(duration);
  Future<Json> evaluate(Object? state, Json questions) =>
      jevClient.jev(state, questions);
  Future<(Object?, Json)> generate(
    String model,
    List<Map<String, String>> messages, {
    bool jsonOutput = false,
    int maxTokens = 8000,
    double temperature = 0.2,
  }) async {
    if (jsonOutput)
      return llm.chatJson(
        model,
        messages,
        maxTokens: maxTokens,
        temperature: temperature,
      );
    final llm.ChatResult result = await llm.chat(
      model,
      messages,
      maxTokens: maxTokens,
      temperature: temperature,
    );
    return (result.text, result.usage);
  }

  Future<(Json, Json)> extractLocal(
    Json book,
    Json seg,
    Json? previous,
    String model,
    String hint,
  ) => local.extractLocal(book, seg, previous, model: model, castHint: hint);
  Future<(Json, Json)> extractClassic(
    Json book,
    Json state,
    Json seg,
    String model,
  ) async {
    final List<Map<String, String>> messages = extraction.buildMessages(
      book,
      state,
      seg,
    );
    final (Object? first, Json usage) = await generate(
      model,
      messages,
      maxTokens: 12000,
    );
    String text = first! as String;
    Object? data;
    try {
      data = llm.parseJson(text);
    } on ValueError {
      final (Object? fixed, _) = await generate(
        model,
        [
          ...messages,
          {'role': 'assistant', 'content': text},
          {
            'role': 'user',
            'content': '上面的输出不是合法 JSON（可能有未转义的英文引号或被截断）。请只输出修正后的完整 JSON。',
          },
        ],
        maxTokens: 12000,
        temperature: 0,
      );
      text = fixed! as String;
      data = llm.parseJson(text);
    }
    if (data is! Json) throw ValueError('模型返回了空结果：${_cut(text, 200)}');
    final Json result = data;
    if (!_classicKeys.any(
          (k) => result[k] is List && (result[k] as List).isNotEmpty,
        ) &&
        !_truth(data['surfaces'])) {
      throw ValueError('模型返回了空结果：${_cut(text, 200)}');
    }
    for (final String key in _classicKeys) {
      if (data[key] is! List) data[key] = <Object?>[];
    }
    if (data['surfaces'] is! Json) data['surfaces'] = <String, Object?>{};
    return (data, {...usage, '_raw': text});
  }
}

class _PolicyBackend implements policy.BookPolicyBackend {
  const _PolicyBackend(this.backend);
  final RunBackend backend;
  @override
  Future<Json> evaluate(Json state, Json questions) =>
      backend.evaluate(state, questions);
  @override
  Future<Object?> generate(
    String model,
    List<Map<String, String>> messages,
  ) async =>
      (await backend.generate(
        model,
        messages,
        jsonOutput: true,
        maxTokens: 4000,
        temperature: 0,
      )).$1;
}

/// A FIFO async task pool. Every accepted operation is observed and drained
/// before releasing the lease, including on cancellation or failed verification.
class _RunPool {
  _RunPool(int concurrency) : semaphore = Semaphore(concurrency);
  final Semaphore semaphore;
  final List<Future<Object?>> tasks = [];
  bool stopped = false;
  Future<T> submit<T>(Future<T> Function() operation) {
    final Future<T> future = semaphore.run(() async {
      if (stopped) throw const Cancelled();
      return operation();
    });
    final Future<Object?> observed = future.then<Object?>(
      (v) => v,
      onError: (Object e, StackTrace s) => null,
    );
    tasks.add(observed);
    return future;
  }

  Future<void> close({bool cancelled = false}) async {
    if (cancelled) stopped = true;
    await Future.wait(tasks);
  }
}

void settleRewrites(Json rec) {
  final Json guard = _obj(rec['guard']);
  for (final MapEntry<String, Object?> entry in _obj(guard['checks']).entries) {
    final Json c = entry.value! as Json;
    if (c['verdict'] != 'rewritten' ||
        (_truth(c['verified']) && c['after_verdict'] == 'ok'))
      continue;
    final num before = _num(c['first']), after = _num(c['jev']);
    if (after >= math.max(0.5, before + 0.2)) continue;
    final Json original = _obj(
      _obj(_obj(guard['rewrites'])[entry.key])['before'],
    );
    for (final Json pr in _rows(_obj(rec['data'])['profiles'])) {
      if (pyStr(pr['who']) == entry.key && original.isNotEmpty) {
        pr['tagline'] =
            _truth(original['tagline']) ? original['tagline'] : pr['tagline'];
        pr['bio'] = _truth(original['bio']) ? original['bio'] : pr['bio'];
      }
    }
    c['verdict'] = 'kept';
  }
}

(Json, List<List<Object?>>) dropUnsupported(
  Json data,
  Json support, [
  double threshold = 0.3,
]) {
  if (support.isEmpty) return (data, []);
  final Json keep = {'events': <Json>[], 'facts': <Json>[], 'rels': <Json>[]};
  final List<List<Object?>> dropped = [];
  for (final (String field, String prefix) in [
    ('events', 'e'),
    ('facts', 'a'),
    ('rels', 'r'),
  ]) {
    final List<Json> records = _rows(data[field]);
    for (int j = 0; j < records.length; j++) {
      final Json v = _obj(support['$prefix$j']);
      if (v.isNotEmpty &&
          (_num(v['p']) < threshold ||
              v['choice'] == 'contradicted' && _num(v['p']) < 0.5)) {
        dropped.add(['$prefix$j', v['p'], v['choice']]);
      } else {
        (keep[field]! as List<Json>).add(records[j]);
      }
    }
  }
  return ({...data, ...keep}, dropped);
}

Map<String, List<String>> attrFacts(
  Json data,
  (String, String) Function(Object?) whoOf,
) => {
  for (final (int i, Json a) in _rows(data['attrs']).indexed)
    if (_truth(a['key']) && _truth(a['value']))
      '$i': [
        whoOf(a['who']).$1,
        whoOf(a['who']).$2,
        pyStr(a['key']),
        pyStr(a['value']),
      ],
};
Future<Json> checkAttrs(
  String text,
  Json data,
  (String, String) Function(Object?) whoOf,
) => judge.checkFacts(text, attrFacts(data, whoOf));

class Runner {
  Runner._(
    this.root,
    this.model,
    this.cancellation,
    this.backend,
    this.onProgress,
  );
  final Directory root;
  final String model;
  final RunCancellation? cancellation;
  final RunBackend backend;
  final void Function(Json)? onProgress;
  late Json book;
  late List<Json> segs;
  late KG kg;
  late Directory work;
  bool replaying = false;
  final List<(File, _RunPool)> deferred = [];
  Set<String> qualityPending = {};
  Set<int> refused = {};
  late String inputSha256;
  List<Json> priorLog = [];
  Json repairPolicy = {};
  late File usagePath;
  Json usage = {};
  final _RunPool pool = _RunPool(4),
      recapPool = _RunPool(4),
      sagaPool = _RunPool(1);
  _RunPool? localPool;
  bool twoPhase = false;
  int lastSaga = 0, lastBio = 0;
  Map<int, Future<Object?>?> recapFutures = {};
  final List<Future<Object?>> pending = [];
  Set<(String, String)> dedupeSeen = {}, descPairs = {};
  List<(int, int)> works = [];

  static Future<Runner> create(
    Directory root, {
    String? model,
    RunCancellation? cancellation,
    RunBackend backend = const RunBackend(),
    void Function(Json)? onProgress,
  }) async {
    final Runner r = Runner._(
      root,
      model ?? defaultModel,
      cancellation,
      backend,
      onProgress,
    );
    r.book = _read(File('${root.path}/book.json'));
    final bool legacy = Directory('${root.path}/work/segs').existsSync();
    final _PolicyBackend pb = _PolicyBackend(backend);
    if ((!_truth(r.book['genre']) && !legacy) ||
        _truth(r.book['genre_provisional'])) {
      final (String genre, num confidence) = await policy.detectKind(
        r.book,
        backend: pb,
      );
      if (confidence > 0) {
        r.book.addAll({
          'genre': genre,
          'genre_p': confidence,
          'genre_provisional': false,
        });
        writeJson(File('${root.path}/book.json'), r.book);
      } else if ((environ['DETECT_KIND'] ?? '1') == '1') {
        throw const llm.LLMError('书籍类型尚未确认，请稍后重试或手动选择类型');
      }
    }
    if (!_truth(r.book['classified'])) {
      final List<String> kinds = await policy.classifyChapters(
        r.book,
        backend: pb,
      );
      for (final (int i, Json chapter) in _rows(r.book['chapters']).indexed) {
        chapter['kind'] = kinds[i];
      }
      r.book['classified'] = true;
      writeJson(File('${root.path}/book.json'), r.book);
    }
    final List<int> body = [
      for (final (int i, Json c) in _rows(r.book['chapters']).indexed)
        if (c['kind'] == 'body') i,
    ];
    r.segs = extraction.segments(r.book, body);
    if (r.segs.isEmpty)
      throw const ValueError('未找到正文段落；请检查解析和章节分类，不能将 0/0 标记为完成');
    if (r.segs.any((s) => _cp(extraction.segText(r.book, s)) > 12000)) {
      throw const ValueError('正文含超过核对上限的长段落；请先拆分段落，避免截断证据');
    }
    r.kg = KG(r.book);
    r.work = Directory('${root.path}/work');
    final File status = File('${root.path}/status.json');
    final Json prior = status.existsSync() ? _read(status) : {};
    r.qualityPending = _set(_obj(prior['quality'])['pending']);
    r.refused = _list(prior['refused']).cast<int>().toSet();
    r.inputSha256 = sourceFingerprint(r.book, r.segs);
    final File manifest = File('${r.work.path}/cache-manifest.json');
    if (manifest.existsSync() &&
        _read(manifest)['input_sha256'] != r.inputSha256) {
      throw const ValueError('书籍或分段已变更，旧缓存不能混用；请先执行分离的数据修复');
    }
    if (!manifest.existsSync())
      writeJson(manifest, {
        'schema': provenanceSchema,
        'input_sha256': r.inputSha256,
        'legacy_adopted': legacy,
      });
    final File priorPath = File('${root.path}/kg.json');
    r.priorLog = priorPath.existsSync() ? _rows(_read(priorPath)['log']) : [];
    final File repair = File('${r.work.path}/repair-policy.json');
    r.repairPolicy = repair.existsSync() ? _read(repair) : {};
    if (r.repairPolicy['input_sha256'] != null &&
        r.repairPolicy['input_sha256'] != r.inputSha256) {
      throw const llm.LLMError('修复隔离策略与书籍来源不符');
    }
    r.qualityPending.addAll(_set(r.repairPolicy['pending']));
    r.restoreQualityRetryContext();
    environ.putIfAbsent('JUDGE_LOG_DIR', () => '${r.work.path}/judge');
    r.usagePath = File('${r.work.path}/usage.json');
    r.usage = r.usagePath.existsSync() ? _read(r.usagePath) : {};
    for (final String key in [
      'prompt',
      'completion',
      'jev_calls',
      'llm_calls',
    ]) {
      r.usage.putIfAbsent(key, () => 0);
    }
    r.usage.putIfAbsent('by_model', () => <String, Object?>{});
    r.lastSaga = r.lastBio = _int(r.segs.first['o0']);
    r.works = r.book['genre'] == 'collection' ? policy.works(r.book) : [];
    return r;
  }

  void checkpoint() => cancellation?.checkpoint();
  Future<T> awaitFuture<T>(Future<T> future) =>
      cancellation?.wait(future) ?? future;
  Future<void> close({bool cancelled = false}) async {
    final List<_RunPool> pools = [
      if (localPool != null) localPool!,
      pool,
      recapPool,
      sagaPool,
    ];
    if (cancelled) {
      for (final _RunPool p in pools) {
        p.stopped = true;
      }
    }
    await Future.wait(pools.map((p) => p.close(cancelled: cancelled)));
  }

  File segPath(int i) =>
      File('${work.path}/segs/${i.toString().padLeft(4, '0')}.json');
  File recapPath(int ci) =>
      File('${work.path}/recaps/${ci.toString().padLeft(4, '0')}.json');
  File bioPath(int ci) =>
      File('${work.path}/bios/${ci.toString().padLeft(4, '0')}.json');
  File sagaPath(int end) =>
      File('${work.path}/sagas/${end.toString().padLeft(9, '0')}.json');
  File dedupePath(int ci) =>
      File('${work.path}/dedupe/${ci.toString().padLeft(4, '0')}.json');
  File localPath(int i) =>
      File('${work.path}/local/${i.toString().padLeft(4, '0')}.json');
  String chapterName(int ci) {
    final Json c = _rows(book['chapters'])[ci];
    return '${_truth(c['parent']) ? '${c['parent']} · ' : ''}${c['title']}';
  }

  void count(String model, Json? tokens) {
    final Json u = tokens ?? {};
    final Json row =
        (_obj(usage['by_model']).putIfAbsent(
              model,
              () => <String, Object?>{'calls': 0, 'prompt': 0, 'completion': 0},
            ))!
            as Json;
    row['calls'] = _int(row['calls']) + 1;
    row['prompt'] = _num(row['prompt']) + _num(u['prompt_tokens']);
    row['completion'] = _num(row['completion']) + _num(u['completion_tokens']);
    usage['llm_calls'] = _int(usage['llm_calls']) + 1;
    usage['prompt'] = _num(usage['prompt']) + _num(u['prompt_tokens']);
    usage['completion'] =
        _num(usage['completion']) + _num(u['completion_tokens']);
    writeJson(usagePath, usage, compact: false);
  }

  Future<Object?> cachedGeneration(
    String key,
    String model,
    List<Map<String, String>> messages, {
    bool jsonOutput = false,
    int maxTokens = 8000,
    double temperature = 0.2,
  }) async {
    checkpoint();
    final Json kw = {'max_tokens': maxTokens, 'temperature': temperature};
    final String fingerprint = digest([model, messages, jsonOutput, kw]);
    final File path = File('${work.path}/drafts/$key-$fingerprint.json');
    if (path.existsSync()) return _read(path)['value'];
    checkpoint();
    final (Object? value, Json usage) = await backend.generate(
      model,
      messages,
      jsonOutput: jsonOutput,
      maxTokens: maxTokens,
      temperature: temperature,
    );
    count(model, usage);
    writeJson(path, {'input_sha256': fingerprint, 'value': value});
    checkpoint();
    return value;
  }

  bool quarantined(File path) =>
      _list(repairPolicy['blocked']).contains(_relative(path));
  String _relative(File path) => path.absolute.path
      .substring(root.absolute.path.length + 1)
      .replaceAll('\\', '/');
  List<File> _files(String directory, {String prefix = ''}) {
    final Directory d = Directory('${work.path}/$directory');
    return !d.existsSync()
          ? []
          : d
              .listSync()
              .whereType<File>()
              .where(
                (f) =>
                    f.path.endsWith('.json') &&
                    f.uri.pathSegments.last.startsWith(prefix),
              )
              .toList()
      ..sort((a, b) => PyCompat.compare(a.path, b.path));
  }

  String _stem(File f) =>
      f.uri.pathSegments.last.replaceFirst(RegExp(r'\.json$'), '');
  static bool verifiedSummary(Json record, List<String> fields) =>
      !_truth(record['guard_error']) &&
      fields.every((field) {
        final Object? verdict = _obj(_obj(record['guard'])[field])['verdict'];
        return !_truth(record[field]) ||
            verdict == 'ok' ||
            (verdict == 'flag' &&
                record['${field}_flagged'] is String &&
                record['${field}_flagged'] != record[field] &&
                record['fallback_kind'] == 'verified-input-excerpt');
      });
  String earlierSaga(int end, [String fallback = '']) {
    Json? before;
    for (final Json r in kg.log) {
      if (r['t'] == 'saga' &&
          _int(r['p']) < end &&
          (before == null || _int(r['p']) > _int(before['p'])))
        before = r;
    }
    return before?['text'] as String? ?? fallback;
  }

  void restoreQualityRetryContext() {
    final File journal = File('${work.path}/quality-retry.json');
    final Json saved = journal.existsSync() ? _read(journal) : {};
    if (saved['state'] != 'rebuilding') return;
    if (saved['input_sha256'] != inputSha256)
      throw const llm.LLMError('质量重试来源已变更，已保留归档，请先检查');
    final int first = _int(saved['first_segment']);
    final num cutoff =
        first < segs.length ? _num(segs[first]['o0']) : double.infinity;
    priorLog =
        priorLog
            .where(
              (r) =>
                  r['t'] == 'merge' &&
                  r['kind'] == 'dedupe' &&
                  _num(r['p']) < cutoff,
            )
            .toList();
  }

  void prepareQualityRetry() {
    final File journal = File('${work.path}/quality-retry.json');
    final Json saved = journal.existsSync() ? _read(journal) : {};
    if (saved['state'] == 'rebuilding') {
      restoreQualityRetryContext();
      return;
    }
    final Json transaction;
    if (saved['state'] == 'archiving') {
      transaction = saved;
    } else {
      Object? start = repairPolicy['quarantine_after'];
      if (start == null &&
          qualityPending.contains('quarantined-critical-checks'))
        start = 0;
      int first = segs.length;
      for (int i = 0; i < segs.length; i++) {
        if (start != null && _num(segs[i]['o1']) >= _num(start)) {
          first = i;
          break;
        }
      }
      final Map<String, File> candidates = {};
      for (final String dir in [
        'bios',
        'recaps',
        'sagas',
        'jobs',
        'finalize',
        'drafts',
      ]) {
        for (final File f in _files(dir)) {
          candidates[f.path] = f;
        }
      }
      for (int i = first; i < segs.length; i++) {
        final File f = segPath(i);
        if (f.existsSync()) candidates[f.path] = f;
      }
      for (final File f in _files('dedupe')) {
        if (segs.skip(first).any((s) => s['chapter'] == int.parse(_stem(f))))
          candidates[f.path] = f;
      }
      final Directory archive = Directory(
        '${work.path}/retry-archive/${(backend.now() * 1e9).toInt()}-$pid',
      );
      final List<Json> rows = [
        for (final String path in _sorted(candidates.keys))
          {
            'path': _relative(candidates[path]!),
            'sha256': sha256Hex(candidates[path]!.readAsBytesSync()),
          },
      ];
      transaction = {
        'state': 'archiving',
        'archive': archive.path.substring(root.path.length + 1),
        'first_segment': first,
        'files': rows,
        'input_sha256': inputSha256,
      };
      for (final File source in [
        File('${root.path}/kg.json'),
        File('${root.path}/status.json'),
        File('${work.path}/repair-policy.json'),
      ]) {
        if (source.existsSync()) {
          final File target = File(
            '${archive.path}/snapshot/${_relative(source)}',
          );
          target.parent.createSync(recursive: true);
          source.copySync(target.path);
        }
      }
      writeJson(journal, transaction);
    }
    if (transaction['input_sha256'] != inputSha256)
      throw const llm.LLMError('质量重试来源已变更，已保留归档，请先检查');
    final Directory archive = Directory(
      '${root.path}/${transaction['archive']}',
    );
    for (final Json row in _rows(transaction['files'])) {
      final File original = File('${root.path}/${row['path']}'),
          target = File('${archive.path}/${row['path']}');
      for (final File f in [original, target]) {
        if (f.existsSync() && sha256Hex(f.readAsBytesSync()) != row['sha256'])
          throw llm.LLMError('质量重试文件在归档期间变更：${row['path']}');
      }
      if (target.existsSync()) {
        if (original.existsSync()) original.deleteSync();
      } else if (original.existsSync()) {
        target.parent.createSync(recursive: true);
        original.renameSync(target.path);
      } else {
        throw llm.LLMError('质量重试原件及归档均缺失：${row['path']}');
      }
    }
    qualityPending = {
      'quality-rebuild',
      ...qualityPending.intersection({'chapter-titles'}),
    };
    repairPolicy = {
      'schema': provenanceSchema,
      'input_sha256': inputSha256,
      'blocked': <Object?>[],
      'pending': _sorted(qualityPending),
    };
    writeJson(File('${work.path}/repair-policy.json'), repairPolicy);
    final int first = _int(transaction['first_segment']);
    final num cutoff =
        first < segs.length ? _num(segs[first]['o0']) : double.infinity;
    priorLog =
        priorLog
            .where(
              (r) =>
                  r['t'] == 'merge' &&
                  r['kind'] == 'dedupe' &&
                  _num(r['p']) < cutoff,
            )
            .toList();
    transaction['state'] = 'rebuilding';
    writeJson(journal, transaction);
  }

  void finishQualityRetry() {
    if (!qualityPending.remove('quality-rebuild')) return;
    repairPolicy['pending'] = _sorted(qualityPending);
    writeJson(File('${work.path}/repair-policy.json'), repairPolicy);
    final File journal = File('${work.path}/quality-retry.json');
    if (journal.existsSync()) {
      final Json t = _read(journal);
      t['state'] = 'complete';
      writeJson(journal, t);
    }
  }

  void notify(String? notice) {
    final File path = File('${root.path}/status.json');
    Json state;
    try {
      state = _read(path);
    } on FileSystemException {
      return;
    } on FormatException {
      return;
    }
    state.addAll({'notice': notice, 'updated': backend.now()});
    writeJson(path, state, compact: false);
    onProgress?.call(state);
  }

  void status(String state, int done, {String? error}) {
    final Json? seg = done > 0 ? segs[done - 1] : null;
    usage['jev'] = {...jevClient.jevStats};
    final Json snapshot = _clone(usage)! as Json;
    writeJson(usagePath, snapshot, compact: false);
    final Json out = {
      'state': state,
      'done': done,
      'total': segs.length,
      'frontier': seg?['o1'] ?? 0,
      'body_start': segs.first['o0'],
      'body_end': segs.last['o1'],
      'model': model,
      'people': kg.people.values.where((p) => !_truth(p['merged_into'])).length,
      'updated': backend.now(),
      'error': error,
      'usage': snapshot,
      'refused': refused.toList()..sort(),
      'quality': {
        'state': qualityPending.isNotEmpty ? 'pending' : 'verified',
        'pending': _sorted(qualityPending),
      },
    };
    writeJson(File('${root.path}/status.json'), out, compact: false);
    onProgress?.call(out);
  }

  void publish() {
    final result = quarantineIdentities(
      kg.log,
      kg.mentions,
      _obj(repairPolicy['identity_taint']).cast<String, int>(),
    );
    final List<(List<Object?>, Json)> ordered = [];
    for (final (int i, Json row) in result.$1.indexed) {
      final int phase =
          row['t'] == 'profile' && row['kind'] == 'chapter'
              ? 1
              : row['t'] == 'recap'
              ? 2
              : row['t'] == 'saga'
              ? 3
              : 0;
      ordered.add((
        [
          row['p'],
          phase,
          phase > 0
              ? [
                row['chapter'] ?? -1,
                row['id'] ?? '',
                PyJson.encode(row, ensureAscii: false, sortKeys: true),
              ]
              : <Object?>[],
          i,
        ],
        row,
      ));
    }
    ordered.sort((a, b) => PyCompat.compare(a.$1, b.$1));
    writeJson(File('${root.path}/kg.json'), {
      'log': ordered.map((r) => r.$2).toList(),
      'segments': [
        for (final Json s in segs) [s['o0'], s['o1'], s['chapter']],
      ],
    });
    final Map<int, List<List<Object?>>> byChapter = {};
    final List<Json> chapters = _rows(book['chapters']);
    int ci = 0;
    final List<List<Object?>> mentions =
        result.$2.toList()..sort(PyCompat.compare);
    for (final List<Object?> m in mentions) {
      while (ci < chapters.length - 1 &&
          _num(m[0]) >= _num(chapters[ci]['o1'])) {
        ci++;
      }
      byChapter.putIfAbsent(ci, () => []).add(m);
    }
    for (final entry in byChapter.entries) {
      writeJson(
        File(
          '${root.path}/mentions/${entry.key.toString().padLeft(4, '0')}.json',
        ),
        entry.value,
      );
    }
    final Directory d = Directory('${root.path}/mentions');
    if (d.existsSync()) {
      for (final File f in d.listSync().whereType<File>().where(
        (f) => f.path.endsWith('.json'),
      )) {
        final int? n = int.tryParse(_stem(f));
        if (n != null && !byChapter.containsKey(n)) f.deleteSync();
      }
    }
  }

  void apply(Json rec) {
    settleRewrites(rec);
    final Json seg = segs[_int(rec['seg'])];
    if (['o0', 'o1'].any((k) => rec.containsKey(k) && rec[k] != seg[k]))
      throw const llm.LLMError('分段边界与缓存不符，拒绝混用旧结果');
    final Json provenance = _obj(rec['provenance']);
    if (_truth(provenance['input_sha256']) &&
        provenance['input_sha256'] != inputSha256)
      throw const llm.LLMError('书籍输入与缓存不符，拒绝重放');
    final Json data = _obj(rec['data']), plan = kg.plan(seg, _obj(rec['data']));
    kg.commit(seg, data, plan, _obj(rec['decisions']), rec['guard'] as Json?);
  }
}
