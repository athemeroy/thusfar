/// Phase 1: local extraction, one segment at a time (`pipeline/local.py`).
library;

import '../env.dart';
import '../errors.dart';
import '../py/py_compat.dart';
import '../py/py_repr.dart';
import 'extract.dart';
import 'lang.dart';
import 'llm.dart';
import 'prompts.dart';

String get localModel => environ['LOCAL_MODEL'] ?? 'deepseek-flash+nothink';

const Map<String, String> langName = <String, String>{
  'zh': '中文',
  'ja': '日文',
  'en': '英文',
  'fr': '法文',
  'de': '德文',
  'es': '西班牙文',
  'it': '意大利文',
  'pt': '葡萄牙文',
  'nl': '荷兰文',
  'ru': '俄文',
};

int _round(double v) => (PyCompat.round(v) as num).toInt();

List<Map<String, String>> build(
  Json book,
  Json seg,
  Json? prev, {
  String castHint = '',
}) {
  final Object? l = book['lang'];
  final String lang = l is String && l.isNotEmpty ? l : 'zh';
  final bool cjk = lang == 'zh' || lang == 'ja';
  final int dense = cjk ? 1 : 3;
  final int chars = (seg['chars'] as int?) ?? 0;
  final int r1 = _round(chars / (300 * dense));
  final int need = r1 > 6 ? r1 : 6;
  final int r2 = _round(chars / (800 * dense));
  final int cap = r2 > 4 ? r2 : 4;
  final (int quoteLo, int quoteHi) = cjk ? (6, 30) : (20, 100);
  final bool concept =
      book['genre'] == 'nonfiction' || book['genre'] == 'reference';
  String before = '';
  if (prev != null) {
    final List<Object?> blocks = book['blocks']! as List<Object?>;
    final List<Object?> ids = prev['blocks']! as List<Object?>;
    final Iterable<Object?> tail =
        ids.length > 2 ? ids.sublist(ids.length - 2) : ids;
    before = tail
        .map(
          (Object? i) => PyCompat.slice(
            (blocks[i! as int]! as Json)['t']! as String,
            -200,
            null,
          ),
        )
        .join('\n');
  }
  final String user = '''【作品】《${book['title']}》
【章节】${chapterLabel(book, seg)}

【${concept ? '已知概念' : '已知人物'}】（前面章节已经出现过的，编号｜名字｜别称｜说明）
${castHint.isNotEmpty ? castHint : '（暂无）'}

【上文】（仅供理解，不要抽取）
${before.isNotEmpty ? before : '（无）'}

【本段原文】
${segText(book, seg)}

【本段长度】约 $chars 个字符，至少写满 $need 条 events（按顺序，宁多勿少）；${concept ? '条目最多 $cap 个，宁缺勿滥' : '人物、关系、facts 同样要抽全'}。

请输出 JSON。''';
  final String system = concept ? conceptSystem : localSystem;
  return <Map<String, String>>[
    <String, String>{
      'role': 'system',
      'content':
          system +
          langNote(lang, quoteLo, quoteHi, cardLang(book)) +
          localNote(book),
    },
    <String, String>{'role': 'user', 'content': user},
  ];
}

/// What changes when the book is not Chinese.
String langNote(
  String? lang,
  int quoteLo,
  int quoteHi, [
  String outputLang = 'zh',
]) {
  if (lang == 'zh' || lang == null) return '';
  final String name = langName[lang] ?? lang;
  final String output = outputLang == 'en' ? '英文' : '中文';
  return '''


【这本书是$name的】
- quote 必须是原文（$name）里逐字出现的连续片段，长度 $quoteLo～$quoteHi 个字符；不要翻译、不要改写、不要省略中间的词。
- name 和 names 也必须是原文里逐字出现的写法（$name），不要译成中文，不要音译。
- role、text、value、desc、why 请用$output写。
- 泛称加 * 的规则照旧，按$name的习惯判断（如 Madame / Monsieur / Herr / Frau / Госпожа / 先生 / 奥さん 这类不是名字的称呼）。''';
}

const List<String> keys = <String>['people', 'same', 'events', 'facts', 'rels'];

/// `_s`: a string out of whatever the model wrote.
String s(Object? x) {
  Object? v = x;
  if (v is List<Object?>) {
    v = v.firstWhere(
      (Object? y) => y is String && y.isNotEmpty,
      orElse: () => '',
    );
  }
  if (v is String) return v;
  if (v == null) return '';
  return pyStr(v);
}

/// Coerce every field to the expected type; drop entries that cannot be used.
Json sanitize(Json data) {
  final List<Json> people = <Json>[];
  for (final Object? raw
      in (data['people'] as List<Object?>?) ?? const <Object?>[]) {
    if (raw is! Json) continue;
    final Object? namesRaw = raw['names'];
    final List<Object?> names =
        namesRaw is List<Object?> ? namesRaw : <Object?>[namesRaw];
    final String id = s(raw['id']);
    final Json p = <String, Object?>{
      ...raw,
      'id': id.isNotEmpty ? id : 'x${people.length}',
      'name': s(raw['name']),
      'known': PyCompat.strip(s(raw['known'])),
      'names': <String>[
        for (final Object? n in names)
          if (s(n).isNotEmpty) s(n),
      ],
      'role': s(raw['role']),
      'quote': s(raw['quote']),
      'gender': s(raw['gender']),
    };
    if ((p['name']! as String).isNotEmpty ||
        (p['names']! as List<String>).isNotEmpty)
      people.add(p);
  }
  data['people'] = people;
  for (final String k in const <String>['same', 'events', 'facts', 'rels']) {
    data[k] = <Json>[
      for (final Object? x in (data[k] as List<Object?>?) ?? const <Object?>[])
        if (x is Json) x,
    ];
  }
  for (final Object? raw in data['events']! as List<Object?>) {
    final Json e = raw! as Json;
    final Object? who = e['who'];
    e['who'] = <String>[
      for (final Object? w in who is List<Object?> ? who : <Object?>[who])
        if (s(w).isNotEmpty) s(w),
    ];
    e['text'] = s(e['text']);
    e['quote'] = s(e['quote']);
  }
  for (final Object? raw in <Object?>[
    ...data['facts']! as List<Object?>,
    ...data['rels']! as List<Object?>,
    ...data['same']! as List<Object?>,
  ]) {
    final Json x = raw! as Json;
    for (final String f in const <String>[
      'who',
      'a',
      'b',
      'key',
      'value',
      'quote',
      'b_is',
      'a_is',
      'desc',
      'why',
    ]) {
      if (x.containsKey(f)) x[f] = s(x[f]);
    }
  }
  return data;
}

/// One phase-1 model call with the JSON-repair follow-up and refusal detection.
Future<(Json, Map<String, Object?>)> extractLocal(
  Json book,
  Json seg,
  Json? prev, {
  String? model,
  String castHint = '',
}) async {
  final String m = model ?? localModel;
  final List<Map<String, String>> msgs = build(
    book,
    seg,
    prev,
    castHint: castHint,
  );
  final ChatResult first = await chat(
    m,
    msgs,
    maxTokens: 9000,
    temperature: 0.2,
  );
  String text = first.text;
  Map<String, Object?> usage = first.usage;
  Object? data;
  try {
    data = parseJson(text);
  } on ValueError {
    if (!text.contains('{') && PyCompat.strip(text).runes.length < 300) {
      throw LLMError(
        'REFUSED: ${String.fromCharCodes(PyCompat.strip(text).runes.take(120))}',
      );
    }
    final ChatResult fix = await chat(
      m,
      <Map<String, String>>[
        ...msgs,
        <String, String>{'role': 'assistant', 'content': text},
        <String, String>{
          'role': 'user',
          'content': '上面的输出不是合法 JSON。请只输出修正后的完整 JSON。',
        },
      ],
      maxTokens: 9000,
      temperature: 0,
    );
    data = parseJson(fix.text);
    text = fix.text;
    usage = <String, Object?>{
      for (final String k in const <String>[
        'prompt_tokens',
        'completion_tokens',
      ])
        k: ((usage[k] as num?) ?? 0) + ((fix.usage[k] as num?) ?? 0),
    };
  }
  if (data is! Json) throw const ValueError('模型没有返回 JSON 对象');
  for (final String k in keys) {
    if (data[k] is! List<Object?>) data[k] = <Object?>[];
  }
  final Json clean = sanitize(data);
  if ((clean['people']! as List<Object?>).isEmpty &&
      ((seg['chars'] as int?) ?? 0) > 800 &&
      (clean['events']! as List<Object?>).isEmpty) {
    throw ValueError('局部抽取为空：${String.fromCharCodes(text.runes.take(160))}');
  }
  return (clean, <String, Object?>{...usage, '_raw': text});
}
