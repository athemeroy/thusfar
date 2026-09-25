/// Turn TXT / EPUB into the reader's book structure (`pipeline/parse.py`).
///
/// Output: `blocks` `[{k, t, o, fn?, src?}]`, `chapters`
/// `[{title, depth, parent, b0, b1, o0, o1, kind}]` and `notes`. Offsets are
/// UTF-16 code units into `"\n".join(block texts)`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_convert/enough_convert.dart';

import '../errors.dart';
import '../py/py_compat.dart';
import '../py/py_re.dart';

typedef Json = Map<String, Object?>;

const int maxChars = 60000000;

int u16(String s) => s.length;

/// Python `len(s)`: code points.
int cpLen(String s) {
  int n = 0;
  for (int i = 0; i < s.length; i++) {
    final int c = s.codeUnitAt(i);
    if (c < 0xdc00 ||
        c > 0xdfff ||
        i == 0 ||
        s.codeUnitAt(i - 1) < 0xd800 ||
        s.codeUnitAt(i - 1) > 0xdbff)
      n++;
  }
  return n;
}

/// Python `s[:n]` for code points, without materialising all runes.
String cpPrefix(String s, int n) {
  int seen = 0;
  for (int i = 0; i < s.length; i++) {
    if (seen == n) return s.substring(0, i);
    final int c = s.codeUnitAt(i);
    if (c >= 0xd800 &&
        c <= 0xdbff &&
        i + 1 < s.length &&
        s.codeUnitAt(i + 1) >= 0xdc00 &&
        s.codeUnitAt(i + 1) <= 0xdfff)
      i++;
    seen++;
  }
  return s;
}

final RegExp _zeroWidth = pyRe('[​‌‍﻿]');
final RegExp _spaces = pyRe('[ \\t\\r\\n ]+');

String clean(String s) {
  final String t = s.replaceAll(_zeroWidth, '').replaceAll(_spaces, ' ');
  return PyCompat.strip(t, chars: ' 　');
}

/// Python `str.splitlines()`.
List<String> splitlines(String s) {
  final List<String> out = <String>[];
  int start = 0;
  int i = 0;
  while (i < s.length) {
    final int c = s.codeUnitAt(i);
    final bool br =
        c == 0x0a ||
        c == 0x0d ||
        c == 0x0b ||
        c == 0x0c ||
        (c >= 0x1c && c <= 0x1e) ||
        c == 0x85 ||
        c == 0x2028 ||
        c == 0x2029;
    if (br) {
      out.add(s.substring(start, i));
      if (c == 0x0d && i + 1 < s.length && s.codeUnitAt(i + 1) == 0x0a) i++;
      start = i + 1;
    }
    i++;
  }
  if (start < s.length) out.add(s.substring(start));
  return out;
}

// ---------------------------------------------------------------- TXT

final RegExp chapterRe = pyRe(
  r'^\s*(?:[零〇一二三四五六七八九十百]{1,4}[、.．]?|'
  r'(?:第[零〇一二三四五六七八九十百千万两0-9０-９]+[章回节卷集部篇幕])[^\n]{0,30}|'
  r'(?:序章|序言|序|楔子|引子|尾声|后记|番外[^\n]{0,20}|chapter\s+\d+[^\n]{0,40}|CHAPTER\s+[IVXLC\d]+[^\n]{0,40}))\s*$',
  ignoreCase: true,
);

final RegExp _aozoraNote = pyRe(r'［＃(.*?)］');
final RegExp _aozoraHead = pyRe(r'「(.+?)」は(大|中|小)見出し');
final RegExp _jaPartRe = pyRe(
  r'^(?:第[零〇一二三四五六七八九十百千万0-9０-９]+(?:の手記|[\s　]+\S.{0,29})|'
  r'[上中下][\s　]+\S.{0,29})$',
);
final RegExp _jaFrameRe = pyRe(r'^(?:はしがき|あとがき|附記(?:[\s　]+.{1,30})?)$');

bool isAozora(String text) {
  final String head = cpPrefix(text, 4000);
  return head.contains('［＃') && (head.contains('《') || text.contains('底本：'));
}

final RegExp _pipes = pyRe(r'[｜|]');
final RegExp _ruby = pyRe(r'《[^》]*》');

Json parseAozora(String text, String name) {
  final List<String> lines = text.replaceAll('\r', '').split('\n');
  final List<int> dash = <int>[
    for (int i = 0; i < lines.length && i < 40; i++)
      if (lines[i].startsWith('---')) i,
  ];
  final List<String> headLines =
      dash.isNotEmpty ? lines.sublist(0, dash[0]) : lines.take(2).toList();
  List<String> body = dash.length >= 2 ? lines.sublist(dash[1] + 1) : lines;
  for (int i = 0; i < body.length; i++) {
    if (body[i].startsWith('底本：')) {
      body = body.sublist(0, i);
      break;
    }
  }
  String title = headLines.isNotEmpty ? PyCompat.strip(headLines[0]) : name;
  if (title.isEmpty) title = name;
  final String author =
      headLines.length > 1 ? PyCompat.strip(headLines[1]) : '';
  final List<Json> blocks = <Json>[];
  final List<(int, String, int)> starts = <(int, String, int)>[];
  for (final String raw in body) {
    int? level;
    for (final Object? n in pyFindall(_aozoraNote, raw)) {
      final RegExpMatch? m = pySearch(_aozoraHead, n! as String);
      if (m != null)
        level = const <String, int>{'大': 0, '中': 1, '小': 2}[m.group(2)];
    }
    String t = pySub(_aozoraNote, raw, '');
    t = pySub(_pipes, t, '');
    t = pySub(_ruby, t, '');
    t = clean(t);
    if (t.isEmpty) continue;
    if (level != null && cpLen(t) <= 40) {
      starts.add((blocks.length, t, level < 1 ? level : 1));
      blocks.add(<String, Object?>{'k': 'h', 't': t, 'level': 2});
    } else {
      blocks.add(<String, Object?>{'k': 'p', 't': t});
    }
  }
  if (starts.isEmpty || starts[0].$1 > 0) starts.insert(0, (0, '冒頭', 0));
  final Json book = finish(blocks, starts, <String, String>{}, title, author);
  book['lang'] = 'ja';
  return book;
}

/// `decode_txt`: UTF-16 by BOM, then UTF-8 (BOM allowed), GB18030, Big5.
String decodeTxt(Uint8List raw) {
  if (raw.length >= 2 &&
      ((raw[0] == 0xff && raw[1] == 0xfe) ||
          (raw[0] == 0xfe && raw[1] == 0xff))) {
    final bool le = raw[0] == 0xff;
    if (raw.length.isOdd)
      throw const ValueError("'utf-16' codec can't decode: truncated data");
    final StringBuffer out = StringBuffer();
    final List<int> units = <int>[
      for (int i = 2; i + 1 < raw.length; i += 2)
        le ? raw[i] | (raw[i + 1] << 8) : (raw[i] << 8) | raw[i + 1],
    ];
    out.write(String.fromCharCodes(units));
    return out.toString();
  }
  try {
    final List<int> body =
        raw.length >= 3 && raw[0] == 0xef && raw[1] == 0xbb && raw[2] == 0xbf
            ? raw.sublist(3)
            : raw;
    return const Utf8Decoder().convert(body);
  } on FormatException {
    // Not UTF-8: try the Chinese legacy encodings.
  }
  try {
    return const GbkCodec(allowInvalid: false).decode(raw);
  } on Object {
    // Not GBK.
  }
  try {
    return const Big5Codec(allowInvalid: false).decode(raw);
  } on Object {
    // Not Big5.
  }
  return const Utf8Decoder(allowMalformed: true).convert(raw);
}

const String headWords =
    r'chapter|book|part|stave|letter|volume|section|canto|act|scene|problem'
    r'|chapitre|livre|partie|acte|sc[eè]ne'
    r'|kapitel|buch|teil|abschnitt|aufzug|auftritt'
    r'|cap[ií]tulo|libro|parte|acto|escena|cap[ií]tulo'
    r'|capitolo|atto'
    r'|глава|часть|книга|действие|явление';
const String headNums =
    r'[0-9]+|[ivxlcdm]+|the\s+\w+'
    r'|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve'
    r'|first|second|third|fourth|fifth|last'
    r'|premi[eè]re?|deuxi[eè]me|second[e]?|troisi[eè]me|quatri[eè]me|cinqui[eè]me|derni[eè]re?'
    r'|erste[rsn]?|zweite[rsn]?|dritte[rsn]?|vierte[rsn]?|f[uü]nfte[rsn]?|letzte[rsn]?'
    r'|primer[ao]?|segund[ao]|tercer[ao]?|cuart[ao]|quint[ao]|[úu]ltim[ao]'
    r'|перв\w*|втор\w*|трет\w*|четв\w*|пят\w*|шест\w*|седьм\w*|последн\w*';
final RegExp enChapterRe = pyRe(
  '^(?:(?:$headWords)\\s*(?:$headNums)\\b[.:]?.{0,60}'
  '|(?:$headNums)\\s+(?:$headWords)\\b[.:]?.{0,60}'
  '|[IVXLC]{1,7}\\.?)\$',
  ignoreCase: true,
);
final RegExp bareHeadRe = pyRe(
  r'^(?:[IVXLCDM]{1,7}\.?|[0-9]{1,3}\.?|'
  r'[一二三四五六七八九十百]{1,4}|第[一二三四五六七八九十百千0-9]{1,5}[章回節节部篇卷])$',
  ignoreCase: true,
);

final RegExp _gutStart = pyRe(
  r'^\*\*\*\s*START OF (?:THE|THIS) PROJECT GUTENBERG.*$',
  multiLine: true,
  ignoreCase: true,
);
final RegExp _gutEnd = pyRe(
  r'^\*\*\*\s*END OF (?:THE|THIS) PROJECT GUTENBERG.*$',
  multiLine: true,
  ignoreCase: true,
);
final RegExp _gutTitle = pyRe(r'^Title:\s*(.+)$', multiLine: true);
final RegExp _gutAuthor = pyRe(r'^Author:\s*(.+)$', multiLine: true);

(String, String, String) gutenberg(String text) {
  String title = '';
  String author = '';
  String t = text;
  final RegExpMatch? m = pySearch(_gutStart, t);
  if (m != null) {
    final String head = t.substring(0, m.start);
    final RegExpMatch? ti = pySearch(_gutTitle, head);
    final RegExpMatch? au = pySearch(_gutAuthor, head);
    title = ti != null ? PyCompat.strip(ti.group(1)!) : '';
    author = au != null ? PyCompat.strip(au.group(1)!) : '';
    t = t.substring(m.end);
    final RegExpMatch? e = pySearch(_gutEnd, t);
    if (e != null) t = t.substring(0, e.start);
  }
  return (t, title, author);
}

final RegExp _paraSplit = pyRe(r'\n\s*\n');
final RegExp _ws = pyRe(r'\s+');
final RegExp _twoCaps = pyRe(r'[A-Z]{2}');
final RegExp _lower = pyRe(r'[a-z]');
final RegExp _keyword = pyRe('^($headWords)\\b', ignoreCase: true);
final RegExp _frontProse = pyRe(
  r'(?:PREFACE|INTRODUCTION|CONTENTS|APPENDIX)\.?',
);

bool _caps(String t) {
  if (cpLen(t) > 60 ||
      pySearch(_twoCaps, t) == null ||
      pySearch(_lower, t) != null)
    return false;
  final String r = PyCompat.strip(t, chars: '”’"\' ');
  if (<String>['.', ',', '!', '?', ';', ':'].any(r.endsWith)) return false;
  if (<String>['[', '*', '“', '"', '‘', "'"].any(t.startsWith)) return false;
  return true;
}

String _rstripChars(String s, String chars) {
  int end = s.length;
  while (end > 0 && chars.contains(s[end - 1])) {
    end--;
  }
  return s.substring(0, end);
}

Json parseLatinTxt(String text, String name) {
  final (String body, String title, String author) = gutenberg(text);
  final List<String> paras = <String>[
    for (final String? p in pySplit(_paraSplit, body.replaceAll('\r', '')))
      if (PyCompat.strip(pySub(_ws, p!, ' ')).isNotEmpty)
        PyCompat.strip(pySub(_ws, p, ' ')).replaceAll('_', ''),
  ];
  final Map<String, List<int>> groups = <String, List<int>>{};
  for (int i = 0; i < paras.length; i++) {
    String t = paras[i];
    if (cpLen(t) > 80) continue;
    t = PyCompat.strip(t);
    if (t.isEmpty) continue;
    final String kind;
    if (pyMatch(enChapterRe, t) != null) {
      final RegExpMatch? m = pyMatch(_keyword, t);
      kind = m != null ? m.group(1)!.toLowerCase() : 'numbered';
    } else if (pyMatch(bareHeadRe, t) != null) {
      kind = 'bare';
    } else if (_caps(t)) {
      kind = 'shouted';
    } else {
      continue;
    }
    groups.putIfAbsent(kind, () => <int>[]).add(i);
  }
  bool divides(List<int> idx) =>
      idx.length >= 3 && idx.last >= paras.length * 0.5;
  final List<String> ranked = PyCompat.stableSorted<String>(
    groups.keys.where((String k) => divides(groups[k]!)),
    key:
        (String k) => <Object?>[
          k == 'bare',
          k == 'shouted',
          -groups[k]!.length,
        ],
  );
  final Map<int, int> depth = <int, int>{};
  List<int> chap;
  if (ranked.isNotEmpty) {
    String outer = ranked[0];
    if (ranked.length > 1) {
      for (final String k in ranked) {
        if (groups[k]!.length < groups[outer]!.length) outer = k;
      }
    }
    chap = List<int>.of(groups[outer]!);
    for (final String k in ranked) {
      if (k != outer && groups[k]!.length > groups[outer]!.length) {
        for (final int i in groups[k]!) {
          if (!chap.contains(i)) depth[i] = 1;
        }
        chap.addAll(groups[k]!.where((int i) => !chap.contains(i)).toList());
      }
    }
    chap.sort();
  } else if (groups.isNotEmpty) {
    List<int> best = groups.values.first;
    for (final List<int> v in groups.values) {
      if (v.length > best.length) best = v;
    }
    chap = List<int>.of(best)..sort();
  } else {
    chap = <int>[];
  }
  final Set<int> heads = chap.length >= 3 ? chap.toSet() : <int>{};
  final List<int> order = heads.toList()..sort();
  final int front = paras.length ~/ 10 > 10 ? paras.length ~/ 10 : 10;
  Set<int> toc = <int>{};
  for (int j = 0; j + 1 < order.length; j++) {
    final int a = order[j];
    final int b = order[j + 1];
    int between = 0;
    for (int k = a + 1; k < b; k++) {
      between += cpLen(paras[k]);
    }
    if (a < front && between < 120) toc.add(a);
  }
  if (toc.length >= 3) {
    heads.removeAll(toc);
  } else {
    toc = <int>{};
  }
  for (int i = 0; i < paras.length; i++) {
    if (pyFullmatch(_frontProse, paras[i]) != null) heads.add(i);
  }
  final List<Json> blocks = <Json>[];
  final List<(int, String, int)> starts = <(int, String, int)>[];
  for (int i = 0; i < paras.length; i++) {
    String t = paras[i];
    if (heads.contains(i)) {
      t = _rstripChars(t, '.');
      starts.add((blocks.length, t, depth[i] ?? 0));
      blocks.add(<String, Object?>{'k': 'h', 't': t, 'level': 2});
    } else {
      blocks.add(<String, Object?>{'k': 'p', 't': t});
    }
  }
  if (starts.isEmpty || starts[0].$1 > 0)
    starts.insert(0, (0, 'Front matter', 0));
  final Json book = finish(
    blocks,
    starts,
    <String, String>{},
    title.isNotEmpty ? title : name,
    author,
  );
  book['lang'] = detectLang(body);
  return book;
}

final RegExp _latin = pyRe(r'[A-Za-z]');
final RegExp _cjk = pyRe(r'[㐀-鿿]');
final RegExp _kana = pyRe(r'[぀-ヿ]');
final RegExp _cyr = pyRe(r'[Ѐ-ӿ]');

bool isLatinText(String text) {
  final String sample = cpPrefix(text, 200000);
  final int latin = _latin.allMatches(sample).length;
  final int cjk = _cjk.allMatches(sample).length;
  final int base = cjk < 1 ? 1 : cjk;
  return latin > 20 * base || _cyr.allMatches(sample).length > 20 * base;
}

final Map<String, RegExp> langWords = <String, RegExp>{
  'en': pyRe(r'\b(the|and|of|that|with|which|was|his|her)\b'),
  'fr': pyRe(r'\b(le|la|les|des|une|qui|que|dans|pour|elle|était)\b'),
  'de': pyRe(r'\b(der|die|das|und|nicht|sich|ein|den|mit|war)\b'),
  'es': pyRe(r'\b(el|la|los|las|que|con|por|para|una|más)\b'),
  'it': pyRe(r'\b(il|la|che|di|per|con|una|gli|nel)\b'),
  'pt': pyRe(r'\b(o|a|os|as|que|com|para|uma|não|ele)\b'),
  'nl': pyRe(r'\b(de|het|een|van|niet|dat|zijn|met)\b'),
  'ru': pyRe(r'\b(и|в|не|на|что|он|с|как|это|она)\b'),
};

String detectLang(String text) {
  final String sample = cpPrefix(text, 200000);
  final int cjk = _cjk.allMatches(sample).length;
  final int kana = _kana.allMatches(sample).length;
  if (kana > (cjk * 0.05 > 200 ? cjk * 0.05 : 200)) return 'ja';
  if (cjk > 200 && cjk > _latin.allMatches(sample).length / 20) return 'zh';
  final String low = sample.toLowerCase();
  String best = 'en';
  int top = -1;
  for (final MapEntry<String, RegExp> e in langWords.entries) {
    final int score = pyFinditer(e.value, low).length;
    if (score > top) {
      top = score;
      best = e.key;
    }
  }
  return top >= 20
      ? best
      : (_cyr.allMatches(sample).length > 200 ? 'ru' : 'en');
}

bool isCjk(String? lang) => lang == 'zh' || lang == 'ja' || lang == null;

/// `parse_txt` from the decoded text and the file's stem.
Json parseTxtText(String text, String stem) {
  if (cpLen(text) > maxChars) throw const ValueError('这本书超过 6000 万字，拆成几本再传。');
  if (isAozora(text)) return parseAozora(text, stem);
  if (isLatinText(text)) return parseLatinTxt(text, stem);
  final String lang = detectLang(text);
  final List<Json> blocks = <Json>[];
  final List<(int, String, int)> starts = <(int, String, int)>[];
  for (final String line in splitlines(text)) {
    final String t = clean(line);
    if (t.isEmpty) continue;
    final bool major =
        lang == 'ja' &&
        (pyFullmatch(_jaPartRe, t) != null ||
            pyFullmatch(_jaFrameRe, t) != null);
    if (cpLen(t) <= 40 && (major || pyMatch(chapterRe, t) != null)) {
      starts.add((blocks.length, t, 0));
      blocks.add(<String, Object?>{'k': 'h', 't': t, 'level': 2});
    } else {
      blocks.add(<String, Object?>{'k': 'p', 't': t});
    }
  }
  if (starts.isEmpty || starts[0].$1 > 0) starts.insert(0, (0, '开始', 0));
  final Json book = finish(blocks, starts, <String, String>{}, stem, '');
  book['lang'] = lang;
  return book;
}

// ---------------------------------------------------------------- assemble

const List<String> frontWords = <String>[
  '书名', '版权', '出版说明', '前言', '序', '译序', '译者', '目录', '献词', '题记', '内容简介', //
  '简介', '作者简介', '导读', '推荐', '致谢', '引言', '图书在版', '封面', '扉页', '编者', '说明',
  'Front matter',
  'Contents',
  'CONTENTS',
  'Preface',
  'PREFACE',
  'Introduction',
  'Dedication',
  'Copyright',
];
const List<String> backWords = <String>[
  '后记',
  '附录',
  '书目',
  '译后记',
  '年表',
  '注释',
  '参考',
  '版权',
  '致谢',
  '跋',
];

Json finish(
  List<Json> blocks,
  List<(int, String, int)> starts,
  Map<String, String> notes,
  String title,
  String author,
) {
  int o = 0;
  for (final Json b in blocks) {
    b.remove('cls');
    b.remove('ids');
    final Object? fn = b['fn'];
    if (fn == null || (fn is List<Object?> && fn.isEmpty)) b.remove('fn');
    b['o'] = o;
    o += u16(b['t']! as String) + 1;
  }
  final int total = o;
  final Set<int> seen = <int>{};
  final List<(int, String, int)> cleanStarts = <(int, String, int)>[];
  final List<(int, String, int)> sortedStarts = PyCompat.stableSorted(
    starts,
    key: ((int, String, int) s) => s.$1,
  );
  for (final (int idx, String t, int d) in sortedStarts) {
    if (cleanStarts.isNotEmpty &&
        (seen.contains(idx) ||
            (idx - cleanStarts.last.$1 <= 1 && d > cleanStarts.last.$3))) {
      final (int pi, String pt, int pd) = cleanStarts.last;
      cleanStarts[cleanStarts.length - 1] = (pi, '$pt · $t', pd > d ? pd : d);
      continue;
    }
    seen.add(idx);
    cleanStarts.add((idx, t, d));
  }
  if (cleanStarts.isEmpty || cleanStarts[0].$1 != 0)
    cleanStarts.insert(0, (0, '封面', 0));
  final List<Json> chapters = <Json>[];
  final Map<int, String> parentTitle = <int, String>{};
  for (int n = 0; n < cleanStarts.length; n++) {
    final (int idx, String t, int d) = cleanStarts[n];
    final int end =
        n + 1 < cleanStarts.length ? cleanStarts[n + 1].$1 : blocks.length;
    if (end <= idx) continue;
    parentTitle[d] = t;
    chapters.add(<String, Object?>{
      'title': t,
      'depth': d,
      'parent': d != 0 ? parentTitle[d - 1] : null,
      'b0': idx,
      'b1': end,
      'o0': blocks[idx]['o'],
      'o1':
          (blocks[end - 1]['o']! as int) + u16(blocks[end - 1]['t']! as String),
    });
  }
  classify(chapters, blocks);
  final Map<String, String> short = <String, String>{};
  for (final Json b in blocks) {
    final List<Object?>? fn = b['fn'] as List<Object?>?;
    if (fn == null) continue;
    for (final Object? raw in fn) {
      final List<Object?> f = raw! as List<Object?>;
      final String? target = f[1] as String?;
      if (target != null && notes.containsKey(target)) {
        f[1] = short.putIfAbsent(target, () => 'n${short.length + 1}');
      } else {
        f[1] = null;
      }
    }
    final List<Object?> kept = <Object?>[
      for (final Object? f in fn)
        if ((f! as List<Object?>)[1] != null) f,
    ];
    if (kept.isEmpty) {
      b.remove('fn');
    } else {
      b['fn'] = kept;
    }
  }
  final Map<String, Object?> outNotes = <String, Object?>{
    for (final MapEntry<String, String> e in notes.entries)
      if (short.containsKey(e.key)) short[e.key]!: e.value,
  };
  return <String, Object?>{
    'title': title,
    'author': author,
    'len': total,
    'blocks': blocks,
    'chapters': chapters,
    'notes': outNotes,
  };
}

const int sectionChars = 20000;

Json splitLongChapters(Json book, {int? limit, int? target}) {
  final bool latin = !isCjk(book['lang'] as String?);
  final int tgt = target ?? (latin ? sectionChars * 3 : sectionChars);
  final int lim = limit ?? tgt * 3;
  final String name = latin ? 'Part {n}' : '第 {n} 节';
  final List<Json> blocks = <Json>[
    for (final Object? b in book['blocks']! as List<Object?>) b! as Json,
  ];
  final List<Json> out = <Json>[];
  int n = 0;
  for (final Object? raw in book['chapters']! as List<Object?>) {
    final Json c = raw! as Json;
    if (c['kind'] != 'body' || (c['o1']! as int) - (c['o0']! as int) <= lim) {
      out.add(c);
      continue;
    }
    int start = c['b0']! as int;
    int size = 0;
    final int b1 = c['b1']! as int;
    for (int bi = c['b0']! as int; bi < b1; bi++) {
      size += u16(blocks[bi]['t']! as String) + 1;
      final bool last = bi == b1 - 1;
      if (size >= tgt || last) {
        n++;
        out.add(<String, Object?>{
          ...c,
          'title': name.replaceAll('{n}', '$n'),
          'parent':
              c['title'] != '开始' && c['title'] != '封面' ? c['title'] : null,
          'depth': c['depth'] ?? 0,
          'b0': start,
          'b1': bi + 1,
          'o0': blocks[start]['o'],
          'o1': (blocks[bi]['o']! as int) + u16(blocks[bi]['t']! as String),
        });
        start = bi + 1;
        size = 0;
      }
    }
  }
  book['chapters'] = out;
  book['sectioned'] = n > 0;
  return book;
}

/// Heuristic front/body/back split.
void classify(List<Json> chapters, List<Json> blocks) {
  bool bodySeen = false;
  for (final Json c in chapters) {
    final String t = c['title']! as String;
    final int size = (c['o1']! as int) - (c['o0']! as int);
    final bool front =
        frontWords.any(t.contains) || ((t == '封面' || t == '开始') && size < 400);
    if (!bodySeen && (front || size < 300)) {
      c['kind'] = 'front';
    } else {
      bodySeen = true;
      c['kind'] = 'body';
    }
  }
  for (final Json c in chapters.reversed) {
    if (c['kind'] == 'body' &&
        backWords.any((String w) => (c['title']! as String).contains(w))) {
      c['kind'] = 'back';
    } else {
      break;
    }
  }
}

/// Parses a TXT file's bytes; [stem] is the file name without extension.
Json parseTxt(Uint8List raw, String stem) {
  final Json book = parseTxtText(decodeTxt(raw), stem);
  if (!(book['blocks']! as List<Object?>).any(
    (Object? b) => ((b! as Json)['t']! as String).isNotEmpty,
  )) {
    throw const ValueError('没有读到文字内容。');
  }
  return splitLongChapters(book);
}
