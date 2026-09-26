/// Chapter classification and independent works, from classify.py / kind.py.
library;

import '../env.dart';
import '../errors.dart';
import '../py/py_compat.dart';
import '../py/py_int.dart';
import '../py/py_re.dart';
import '../py/py_repr.dart';
import 'book_policy_tables.dart';
import 'jev.dart' as judge;
import 'judge.dart' show batch;
import 'llm.dart' as llm;

export 'book_policy_tables.dart' show bookKinds;

typedef Json = Map<String, Object?>;

abstract interface class BookPolicyBackend {
  Future<Json> evaluate(Json state, Json questions);
  Future<Object?> generate(String model, List<Map<String, String>> messages);
}

class LiveBookPolicyBackend implements BookPolicyBackend {
  const LiveBookPolicyBackend();

  @override
  Future<Json> evaluate(Json state, Json questions) =>
      judge.jev(state, questions);

  @override
  Future<Object?> generate(
    String model,
    List<Map<String, String>> messages,
  ) async =>
      (await llm.chatJson(model, messages, maxTokens: 4000, temperature: 0)).$1;
}

String _prefix(String text, int n) => PyCompat.slice(text, 0, n);
List<Json> _chapters(Json book) =>
    ((book['chapters'] as List<Object?>?) ?? const []).cast<Json>();
String _title(Json c) =>
    '${(c['parent'] as String? ?? '').isEmpty ? '' : '${c['parent']} · '}${c['title']}';
String _head(Json book, Json chapter, int count) => _prefix(
  (book['blocks']! as List<Object?>)
      .sublist(chapter['b0']! as int, chapter['b1']! as int)
      .cast<Json>()
      .where((Json b) => b['k'] != 'img')
      .map((Json b) => b['t']! as String)
      .join(),
  count,
);

Future<List<String>?> classifyByJudge(
  Json book, {
  BookPolicyBackend backend = const LiveBookPolicyBackend(),
}) async {
  final List<Json> chapters = _chapters(book);
  final Map<int, String> out = <int, String>{};
  try {
    for (int start = 0; start < chapters.length; start += batch) {
      final int end =
          start + batch < chapters.length ? start + batch : chapters.length;
      final Json state = <String, Object?>{
        'book_title': book['title'] ?? '',
        'chapters': <String, Object?>{
          for (int i = start; i < end; i++)
            'c$i': <String, Object?>{
              'title': _title(chapters[i]),
              'length':
                  (chapters[i]['o1']! as int) - (chapters[i]['o0']! as int),
              'begins': _head(book, chapters[i], 120),
            },
        },
      };
      final Json questions = <String, Object?>{
        for (int i = start; i < end; i++)
          'q$i': <String, Object?>{
            'type': 'choice',
            'instructions':
                'Which part of the book is chapters.c$i ("${_title(chapters[i])}")?',
            'criteria': chapterCriteria,
          },
      };
      final Json answers = await backend.evaluate(state, questions);
      for (int i = start; i < end; i++) {
        final Object? choice = (answers['q$i'] as Json?)?['choice'];
        if (choice is String && chapterCriteria.containsKey(choice))
          out[i] = choice;
      }
    }
  } on Object {
    return null;
  }
  return out.length == chapters.length
      ? List<String>.generate(chapters.length, (int i) => out[i]!)
      : null;
}

Future<List<String>> classifyChapters(
  Json book, {
  String? model,
  BookPolicyBackend backend = const LiveBookPolicyBackend(),
}) async {
  final String selected =
      model == null || model.isEmpty
          ? environ['CLASSIFY_MODEL'] ?? 'deepseek-flash+nothink'
          : model;
  if ((environ['CLASSIFY_BY_JUDGE'] ?? '1') == '1') {
    final List<String>? kinds = await classifyByJudge(book, backend: backend);
    if (kinds != null && kinds.isNotEmpty) return kinds;
  }
  final List<Json> chapters = _chapters(book);
  final List<String> rows = <String>[
    for (int i = 0; i < chapters.length; i++)
      '$i｜${_title(chapters[i])}｜${(chapters[i]['o1']! as int) - (chapters[i]['o0']! as int)}｜${_head(book, chapters[i], 60)}',
  ];
  String fallback(Json c) =>
      (c['kind'] as String? ?? '').isEmpty ? 'body' : c['kind']! as String;
  try {
    final Object? raw = await backend.generate(selected, <Map<String, String>>[
      <String, String>{
        'role': 'user',
        'content': classifyPrompt
            .replaceAll('{title}', book['title']! as String)
            .replaceAll('{rows}', rows.join('\n')),
      },
    ]);
    final Json kinds = (raw! as Json)['kinds'] as Json? ?? <String, Object?>{};
    return List<String>.generate(chapters.length, (int i) {
      final Object? given = kinds['$i'];
      final Object? k =
          given == null || given == '' || given == false || given == 0
              ? fallback(chapters[i])
              : given;
      return chapterCriteria.containsKey(k) ? k! as String : 'body';
    });
  } on Object {
    return chapters.map(fallback).toList();
  }
}

Future<(String, double)> detectKind(
  Json book, {
  BookPolicyBackend backend = const LiveBookPolicyBackend(),
}) async {
  if ((environ['DETECT_KIND'] ?? '1') != '1') return ('novel', 0.0);
  final List<Json> chapters = _chapters(book);
  final Json state = <String, Object?>{
    'title': book['title'] ?? '',
    'author': book['author'] ?? '',
    'table_of_contents': chapters
        .take(40)
        .map((Json c) => _prefix(c['title'] as String? ?? '', 24))
        .join('、'),
    'opening_lines': _prefix(
      ((book['blocks'] as List<Object?>?) ?? const [])
          .take(40)
          .cast<Json>()
          .where((Json b) => b['k'] != 'img')
          .map((Json b) => b['t']! as String)
          .join(' '),
      1500,
    ),
    'length_in_characters': book['len'] ?? 0,
    'number_of_chapters': chapters.length,
  };
  final Json q = <String, Object?>{
    'k': <String, Object?>{
      'type': 'choice',
      'instructions':
          'What kind of book is this? Judge from its title, table of contents and opening lines.',
      'criteria': <String, String>{
        for (final MapEntry<String, List<String>> e in bookKinds.entries)
          e.key: e.value[2],
      },
    },
  };
  final Json answer;
  try {
    answer =
        (await backend.evaluate(state, q))['k'] as Json? ?? <String, Object?>{};
  } on Object {
    return ('novel', 0.0);
  }
  final Object? choice = answer['choice'];
  final Json probabilities =
      answer['probabilities'] as Json? ?? <String, Object?>{};
  return choice is String && bookKinds.containsKey(choice)
      ? (
        choice,
        PyCompat.roundDigits(
          (probabilities[choice] as num? ?? 0).toDouble(),
          3,
        ),
      )
      : ('novel', 0.0);
}

final RegExp _ordinal = pyRe(
  r'^\s*(?:第\s*([0-9]+|[零一二三四五六七八九十百千]+)\s*[部章回卷节篇集]|(?:chapter|part|book|volume)\s+([0-9]+|[ivxlcdm]+)|([0-9]{1,3})[.、])',
  ignoreCase: true,
);
final RegExp _opener = pyRe(
  r'^\s*(楔子|序章|序幕|序言|引子|前言|自序|开篇|prologue|preface|foreword)',
  ignoreCase: true,
);
final RegExp _roman = pyRe(r'[ivxlcdm]+', ignoreCase: true);

Object _decimal(String s) {
  final BigInt? value = tryPythonDecimal(s);
  if (value == null)
    throw ValueError('invalid literal for int() with base 10: ${pyRepr(s)}');
  return value.isValidInt ? value.toInt() : value;
}

/// Python integers remain arbitrary-precision for unusual chapter headings.
Object chineseNumber(String s) {
  if (PyCompat.isDigit(s)) return _decimal(s);
  int value = 0;
  int current = 0;
  for (final int cp in s.runes) {
    final String char = String.fromCharCode(cp);
    final int digit = '零一二三四五六七八九'.indexOf(char);
    if (digit >= 0) {
      current = digit;
    } else if (<String>['十', '百', '千'].contains(char)) {
      value +=
          (current == 0 ? 1 : current) *
          <String, int>{'十': 10, '百': 100, '千': 1000}[char]!;
      current = 0;
    }
  }
  return value + current;
}

Object? ordinal(String? title) {
  final RegExpMatch? match = pyMatch(_ordinal, title ?? '');
  if (match == null) return null;
  final String raw =
      (match.group(1) ?? match.group(2) ?? match.group(3) ?? '').toLowerCase();
  if (PyCompat.isDigit(raw)) return _decimal(raw);
  if (pyFullmatch(_roman, raw) != null) {
    const Map<String, int> vals = <String, int>{
      'i': 1,
      'v': 5,
      'x': 10,
      'l': 50,
      'c': 100,
      'd': 500,
      'm': 1000,
    };
    int sum = 0;
    for (int i = 0; i < raw.length; i++) {
      final int v = vals[raw[i]]!;
      sum += i + 1 < raw.length && v < vals[raw[i + 1]]! ? -v : v;
    }
    return sum;
  }
  final Object n = chineseNumber(raw);
  return n == 0 ? null : n;
}

List<(int, int)> works(Json book, {int minChars = 20000}) {
  final List<Json> body =
      _chapters(book).where((Json c) => c['kind'] == 'body').toList();
  if (body.isEmpty) return <(int, int)>[];
  bool parent(Json c) => (c['parent'] as String? ?? '').isNotEmpty;
  final List<Json> tops = body.where((Json c) => !parent(c)).toList();
  final List<(int, int)> spans = <(int, int)>[];
  if (body.any(parent) && tops.length > 1) {
    for (final Json c in tops) {
      final int s = c['o0']! as int;
      final int e = c['o1']! as int;
      if (e - s >= minChars) spans.add((s, e));
    }
  } else {
    final List<int> starts = <int>[0];
    BigInt? previous;
    for (int i = 0; i < body.length; i++) {
      final String title = body[i]['title'] as String? ?? '';
      final Object? value = ordinal(title);
      final BigInt? n =
          value == null
              ? null
              : value is BigInt
              ? value
              : BigInt.from(value as int);
      final bool opener = pyMatch(_opener, title) != null;
      if (i > 0 &&
          (opener ||
              (n != null &&
                  previous != null &&
                  n <= previous &&
                  n <= BigInt.two)))
        starts.add(i);
      if (n != null) {
        previous = n;
      } else if (opener) {
        previous = BigInt.zero;
      }
    }
    for (int k = 0; k < starts.length; k++) {
      final int j = k + 1 < starts.length ? starts[k + 1] : body.length;
      final int s = body[starts[k]]['o0']! as int;
      final int e = body[j - 1]['o1']! as int;
      if (e - s >= minChars) spans.add((s, e));
    }
  }
  if (spans.length < 2) return <(int, int)>[];
  final List<(int, int)> merged = <(int, int)>[spans.first];
  for (final (int s, int e) in spans.skip(1)) {
    if (s <= merged.last.$2) {
      merged[merged.length - 1] = (
        merged.last.$1,
        e > merged.last.$2 ? e : merged.last.$2,
      );
    } else {
      merged.add((s, e));
    }
  }
  return merged;
}
