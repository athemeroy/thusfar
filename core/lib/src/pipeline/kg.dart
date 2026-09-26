/// Temporal knowledge graph and spoiler-safe UTF-16 evidence anchoring.
library;

import 'dart:math' as math;

import '../py/py_compat.dart';
import '../py/py_int.dart';
import '../py/py_re.dart';
import '../py/py_repr.dart';
import 'lang.dart' as lang;

typedef Json = Map<String, Object?>;

const Set<String> pronouns = <String>{
  "everyone",
  "he",
  "her",
  "herself",
  "him",
  "himself",
  "his",
  "i",
  "it",
  "me",
  "my",
  "myself",
  "nobody",
  "she",
  "somebody",
  "someone",
  "stranger",
  "the stranger",
  "them",
  "they",
  "us",
  "we",
  "you",
  "一人",
  "三人",
  "两人",
  "为师",
  "二人",
  "人家",
  "他",
  "他人",
  "他们",
  "众人",
  "你",
  "你们",
  "俺",
  "兄弟",
  "其他人",
  "其余人",
  "别人",
  "区区",
  "另一人",
  "咱",
  "咱们",
  "哀家",
  "哥们",
  "在下",
  "大家",
  "奴婢",
  "奴家",
  "她",
  "她们",
  "妾身",
  "它",
  "寡人",
  "对方",
  "对面的人",
  "小女子",
  "小弟",
  "小爷",
  "小生",
  "小的",
  "属下",
  "微臣",
  "您",
  "我",
  "我们",
  "所有人",
  "旁人",
  "晚辈",
  "有人",
  "朕",
  "末将",
  "本公子",
  "本姑娘",
  "本官",
  "本宫",
  "本尊",
  "本少",
  "本少爷",
  "本帅",
  "本座",
  "本王",
  "来人",
  "某人",
  "此人",
  "洒家",
  "神秘人",
  "老夫",
  "老娘",
  "老子",
  "老朽",
  "老衲",
  "老身",
  "自己",
  "说话之人",
  "说话的人",
  "贫僧",
  "贫尼",
  "贫道",
  "路人",
  "这个人",
  "这人",
  "那个人",
  "那人",
  "鄙人",
  "问话之人",
};

const Set<String> generic = <String>{
  "丈人",
  "丈夫",
  "主人",
  "乡下人",
  "乡下佬",
  "仆人",
  "仆役",
  "伯爵",
  "伯父",
  "侯爵",
  "儿媳",
  "儿子",
  "先生",
  "先生们",
  "公公",
  "公爵",
  "内人",
  "医生",
  "叔叔",
  "同学",
  "向导",
  "听差",
  "和尚",
  "哥哥",
  "商人",
  "国王",
  "堂长",
  "外公",
  "外婆",
  "大人",
  "大夫",
  "太太",
  "夫人",
  "夫人们",
  "女人",
  "女仆",
  "女儿",
  "女婿",
  "女子",
  "女孩",
  "奶奶",
  "妇人",
  "妈妈",
  "妹妹",
  "妻子",
  "姐姐",
  "姑妈",
  "姑娘",
  "姑娘们",
  "姨妈",
  "娘",
  "婆婆",
  "媳妇",
  "学生",
  "孩子",
  "守卫",
  "客人",
  "寡妇",
  "小伙子",
  "小姐",
  "少女",
  "少年",
  "少爷",
  "尼姑",
  "岳母",
  "岳父",
  "差役",
  "年轻人",
  "弟弟",
  "教士",
  "新夫人",
  "新娘",
  "新娘子",
  "新郎",
  "朋友",
  "未婚夫",
  "未婚女婿",
  "未婚妻",
  "校长",
  "母亲",
  "父亲",
  "爷爷",
  "爸爸",
  "爹",
  "王后",
  "男人",
  "男子",
  "男孩",
  "男爵",
  "病人",
  "皇帝",
  "祖母",
  "祖父",
  "神父",
  "神甫",
  "老人",
  "老太太",
  "老头",
  "老头子",
  "老师",
  "老板",
  "老板娘",
  "老爷",
  "舅舅",
  "邻居",
  "闺女",
  "青年",
};

const Set<String> genericEn = <String>{
  "attorney",
  "aunt",
  "baby",
  "baron",
  "baroness",
  "beggar",
  "bishop",
  "blacksmith",
  "boy",
  "bride",
  "bridegroom",
  "brother",
  "butler",
  "captain",
  "child",
  "clergyman",
  "clerk",
  "coachman",
  "colonel",
  "constable",
  "convict",
  "cook",
  "count",
  "countess",
  "cousin",
  "creature",
  "curate",
  "dad",
  "daughter",
  "doctor",
  "doorman",
  "driver",
  "duchess",
  "duke",
  "earl",
  "farmer",
  "father",
  "fellow",
  "figure",
  "fisherman",
  "footman",
  "friend",
  "general",
  "gentleman",
  "gentlemen",
  "girl",
  "governess",
  "grandfather",
  "grandma",
  "grandmother",
  "grandpa",
  "guard",
  "guest",
  "host",
  "hostess",
  "housekeeper",
  "husband",
  "inspector",
  "judge",
  "keeper",
  "king",
  "lad",
  "lady",
  "landlady",
  "landlord",
  "lass",
  "lawyer",
  "lord",
  "ma'am",
  "madam",
  "magistrate",
  "maid",
  "major",
  "mamma",
  "man",
  "master",
  "men",
  "merchant",
  "miss",
  "mister",
  "mistress",
  "mom",
  "mother",
  "mr",
  "mrs",
  "mum",
  "neighbor",
  "neighbour",
  "nephew",
  "niece",
  "nurse",
  "officer",
  "one",
  "orphan",
  "other",
  "others",
  "papa",
  "parson",
  "partner",
  "people",
  "person",
  "physician",
  "porter",
  "priest",
  "prince",
  "princess",
  "prisoner",
  "pupil",
  "queen",
  "reverend",
  "sailor",
  "schoolmaster",
  "secretary",
  "sergeant",
  "servant",
  "shopkeeper",
  "sir",
  "sister",
  "smith",
  "soldier",
  "son",
  "stranger",
  "student",
  "surgeon",
  "teacher",
  "thing",
  "uncle",
  "vicar",
  "visitor",
  "waiter",
  "waitress",
  "widow",
  "widower",
  "wife",
  "woman",
  "women",
};

final RegExp _enPrefix = pyRe(
  r'^(?:the|a|an|this|that|these|those|my|his|her|their|our|your|old|young|little|poor|dear|good|elder|younger)\s+',
  ignoreCase: true,
);
final RegExp _punct = pyRe(
  r'''[\s，。、；：？！“”‘’「」『』（）()《》〈〉…—\-·・,.;:?!"'\[\]【】]''',
);
const String _cjk = r'[\u3400-\u9fff\uff00-\uffef\u3000-\u303f“”‘’]';
const Map<String, String> _punctMap = {
  ',': '，',
  ';': '；',
  ':': '：',
  '?': '？',
  '!': '！',
  '(': '（',
  ')': '）',
};

bool _truth(Object? x) =>
    x != null &&
    x != false &&
    x != 0 &&
    (x is! String || x.isNotEmpty) &&
    (x is! Iterable || x.isNotEmpty) &&
    (x is! Map || x.isNotEmpty);
String _s(Object? x) => _truth(x) ? x as String : '';
int _len(String x) => x.runes.length;
String _cut(String x, int end) => PyCompat.slice(x, 0, end);
String _strip(String x) => PyCompat.strip(x);
List<Json> _rows(Object? x) => ((x as List<Object?>?) ?? const []).cast<Json>();
Set<String> _names(Object? x) =>
    (x as Iterable<Object?>).cast<String>().toSet();
String _leftStrip(String s, String chars) {
  final Set<int> trim = chars.runes.toSet();
  return String.fromCharCodes(s.runes.skipWhile(trim.contains));
}

String _rightStrip(String s, String chars) {
  final List<int> runes = s.runes.toList();
  final Set<int> trim = chars.runes.toSet();
  int end = runes.length;
  while (end > 0 && trim.contains(runes[end - 1])) {
    end--;
  }
  return String.fromCharCodes(runes.take(end));
}

bool _asciiAlpha(String s) =>
    s.isNotEmpty && RegExp(r'^[A-Za-z]+$').hasMatch(s);

bool isLatin(String? s) =>
    RegExp('[A-Za-z]').hasMatch(s ?? '') &&
    !RegExp(r'[\u3400-\u9fff]').hasMatch(s ?? '');

/// A kinship word, title or description rather than a person's name.
bool genericWord(String? f) {
  f = _strip(f ?? '');
  if (isLatin(f)) {
    String g = _rightStrip(f.toLowerCase(), '.');
    while (_enPrefix.hasMatch(g)) {
      g = g.replaceFirst(_enPrefix, '');
    }
    return genericEn.contains(g) ||
        pronouns.contains(g) ||
        genericEn.contains(_rightStrip(g, 's'));
  }
  return generic.contains(f) || generic.contains(_leftStrip(f, '他她的老小'));
}

/// Use full-width punctuation next to Chinese characters.
Object? zh(Object? text) {
  if (text is! String || text.isEmpty) return text;
  text = text.replaceAllMapped(pyRe(r'"([^"\n]{1,60})"'), (m) => '“${m[1]}”');
  return text.replaceAllMapped(
    pyRe('(?<=$_cjk)\\s*([,;:?!()])\\s*|\\s*([,;:?!()])\\s*(?=$_cjk)'),
    (m) => _punctMap[m[1] ?? m[2]]!,
  );
}

bool goodAlias(String? a) {
  if (a == null ||
      a.isEmpty ||
      pronouns.contains(a) ||
      pronouns.contains(a.toLowerCase()) ||
      genericWord(a) ||
      generic.contains(_leftStrip(a, '他她的老小未')))
    return false;
  if (isLatin(a)) {
    return !pyRe(
      r"\b(?:and|family|brothers|sisters|folks|people)\b|'s\b",
      ignoreCase: true,
    ).hasMatch(a);
  }
  return !['夫妇', '夫妻', '们', '一家', '俩', '的'].any(a.contains);
}

/// Punctuation-free text and its original Python code-point indices.
(String, List<int>) normalizeQuote(String s) {
  final StringBuffer out = StringBuffer();
  final List<int> indices = [];
  int i = 0;
  for (final int rune in s.runes) {
    final String ch = String.fromCharCode(rune);
    if (!_punct.hasMatch(ch)) {
      out.write(ch);
      indices.add(i);
    }
    i++;
  }
  return (out.toString(), indices);
}

/// Locate model-provided quotes and expose global UTF-16 positions.
class Anchor {
  Anchor(Json book, this.seg)
    : blocks = [
        for (final Object? i in seg['blocks']! as List<Object?>)
          (book['blocks']! as List<Object?>)[i! as int]! as Json,
      ];

  /// Rehydrates an oracle snapshot without needing unrelated book blocks.
  Anchor.fromBlocks(this.blocks, [this.seg = const {}]);

  final List<Json> blocks;
  final Json seg;

  int globalPosition(Json b, int codePointIndex) =>
      (b['o']! as int) +
      PyCompat.slice(b['t']! as String, null, codePointIndex).length;

  Json? block(Object? para) {
    int? n;
    if (para is bool) {
      n = para ? 1 : 0;
    } else if (para is num && para.isFinite) {
      n = para.toInt();
    } else if (para is String) {
      final BigInt? parsed = tryPythonDecimal(para);
      if (parsed != null &&
          parsed >= BigInt.one &&
          parsed <= BigInt.from(blocks.length)) {
        n = parsed.toInt();
      }
    }
    return n != null && n >= 1 && n <= blocks.length ? blocks[n - 1] : null;
  }

  (int, int)? find(String? quote, [Object? para]) {
    if (quote == null || _len(quote) < 2) return null;
    final Json? b0 = block(para);
    final List<Json> order = [];
    if (b0 != null) {
      order.add(b0);
      final int k = blocks.indexOf(b0);
      for (final int j in [k - 1, k + 1, k - 2, k + 2]) {
        if (j >= 0 && j < blocks.length) order.add(blocks[j]);
      }
    }
    order.addAll(blocks.where((b) => !order.contains(b)).toList());
    for (final Json b in order) {
      final int i = (b['t']! as String).indexOf(quote);
      if (i >= 0)
        return ((b['o']! as int) + i, (b['o']! as int) + i + quote.length);
    }
    final String nq = normalizeQuote(quote).$1;
    if (_len(nq) < 3) return null;
    (int, int)? normalizedHit(String needle) {
      for (final Json b in order) {
        final (String nt, List<int> indices) = normalizeQuote(
          b['t']! as String,
        );
        final int units = nt.indexOf(needle);
        if (units >= 0) {
          final int i = _len(nt.substring(0, units));
          return (
            globalPosition(b, indices[i]),
            globalPosition(b, indices[i + _len(needle) - 1] + 1),
          );
        }
      }
      return null;
    }

    final (int, int)? hit = normalizedHit(nq);
    if (hit != null) return hit;
    return _len(nq) >= 12 ? normalizedHit(_cut(nq, _len(nq) ~/ 2)) : null;
  }

  int paraEnd(Object? para) {
    final Json b = block(para) ?? blocks.last;
    return (b['o']! as int) + (b['t']! as String).length;
  }

  (int, int) pos(Object? para, String? quote) {
    final (int, int)? hit = find(quote, para);
    if (hit != null) return hit;
    final Json? b = block(para);
    return b != null
        ? (b['o']! as int, (b['o']! as int) + (b['t']! as String).length)
        : (seg['o1']! as int, seg['o1']! as int);
  }

  (int, int)? first(String surface, [int after = -1]) {
    for (final Json b in blocks) {
      final String t = b['t']! as String;
      int start = 0;
      while (start <= t.length) {
        final int i = t.indexOf(surface, start);
        if (i < 0) break;
        if (_asciiAlpha(_cut(surface, 1)) &&
            ((i > 0 && _asciiAlpha(t.substring(i - 1, i))) ||
                (i + surface.length < t.length &&
                    _asciiAlpha(
                      t.substring(i + surface.length, i + surface.length + 1),
                    )))) {
          start = i + 1;
          continue;
        }
        final int g = (b['o']! as int) + i;
        if (g >= after) return (g, g + surface.length);
        start = i + 1;
      }
    }
    return null;
  }
}

class KG {
  KG(this.book) : k = lang.scale(book);

  final Json book;
  final int k;
  Map<String, Json> people = {};
  Map<String, Json> rels = {};
  List<Json> log = [];
  List<List<Object?>> mentions = [];
  List<String> recent = [];
  String saga = '';
  int n = 0;
  int seg = 0;
  List<String> warnings = [];

  String? canon(String? pid) {
    final Set<String> seen = {};
    while (_truth(pid) &&
        people.containsKey(pid) &&
        _truth(people[pid]!['merged_into']) &&
        !seen.contains(pid)) {
      seen.add(pid!);
      pid = people[pid]!['merged_into']! as String;
    }
    return pid;
  }

  String? lookup(Object? x, Json refmap) {
    if (x is! String) return null;
    x = _strip(x);
    if (refmap.containsKey(x)) return refmap[x] as String?;
    if (people.containsKey(x)) return canon(x);
    for (final Json p in people.values) {
      if (!_truth(p['merged_into']) &&
          (x == p['name'] || _names(p['aliases']).contains(x)))
        return p['id']! as String;
    }
    return null;
  }

  Json promptState() => {
    'people': {
      for (final MapEntry<String, Json> e in people.entries)
        e.key: {
          'id': e.key,
          'name': e.value['name'],
          'aliases':
              (_names(e.value['aliases'])..remove(e.value['name'])).toList()
                ..sort(PyCompat.compare),
          'tagline': e.value['tagline'] ?? '',
          'bio': e.value['bio'] ?? '',
          'importance': e.value['imp'] ?? 1,
          'mentions': e.value['mentions'] ?? 0,
          'last_seg': e.value['last_seg'] ?? -99,
          'merged_into': e.value['merged_into'],
        },
    },
    'rels': rels,
    'seg': seg,
    'recent_events': recent.skip(math.max(0, recent.length - 12)).toList(),
    'saga': saga,
  };

  String describe(String pid) {
    final Json p = people[pid]!;
    return '${p['name']}（${_truth(p['tagline']) ? p['tagline'] : _s(p['intro'])}）';
  }

  /// Assign ids and find occurrences that require identity decisions.
  Json plan(Json segment, Json data) {
    final Json refmap = {};
    int count = n;
    for (final Json np in _rows(data['new_people'])) {
      final String ref = pyStr(_truth(np['ref']) ? np['ref'] : '');
      if (ref.isNotEmpty && !refmap.containsKey(ref))
        refmap[ref] = 'P${++count}';
    }
    final Map<String, Json> surfaces = {};
    for (final MapEntry<String, Object?> e
        in ((data['surfaces'] as Json?) ?? {}).entries) {
      final String? pid =
          refmap[e.key] as String? ??
          (people.containsKey(e.key) ? canon(e.key) : null);
      if (pid == null || e.value is! List<Object?>) continue;
      for (final Object? form in e.value! as List<Object?>) {
        if (form is! String) continue;
        final String f = _strip(_leftStrip(form, '*'));
        final bool isGeneric = form.startsWith('*') || genericWord(f);
        if (_len(f) < 2 ||
            pronouns.contains(f) ||
            pronouns.contains(f.toLowerCase()))
          continue;
        final Json entry = surfaces.putIfAbsent(
          f,
          () => {'ids': <String>[], 'generic': false},
        );
        final List<String> ids = entry['ids']! as List<String>;
        if (!ids.contains(pid)) ids.add(pid);
        entry['generic'] = entry['generic'] == true || isGeneric;
      }
    }
    final List<Json> occurrences = [];
    if (surfaces.isNotEmpty) {
      final List<String> forms = PyCompat.stableSorted(
        surfaces.keys,
        key: _len,
        reverse: true,
      );
      final RegExp rx = RegExp(
        forms
            .map((s) {
              final String escaped = RegExp.escape(s);
              return _asciiAlpha(PyCompat.slice(s, -1, null))
                  ? '(?<![A-Za-z])$escaped(?![A-Za-z])'
                  : escaped;
            })
            .join('|'),
        unicode: true,
      );
      for (final Object? bi in segment['blocks']! as List<Object?>) {
        final Json b = (book['blocks']! as List<Object?>)[bi! as int]! as Json;
        final String t = b['t']! as String;
        for (final RegExpMatch m in rx.allMatches(t)) {
          final Json e = surfaces[m[0]]!;
          final int s = (b['o']! as int) + m.start;
          occurrences.add({
            'key': '$s',
            'bi': bi,
            'i': _len(t.substring(0, m.start)),
            'j': _len(t.substring(0, m.end)),
            's': s,
            'e': (b['o']! as int) + m.end,
            'surface': m[0],
            'ids': e['ids'],
            'generic': e['generic'],
            'ambiguous':
                (e['ids']! as List<Object?>).length > 1 || e['generic'] == true,
          });
        }
      }
    }
    return {'refmap': refmap, 'surfaces': surfaces, 'occs': occurrences};
  }

  /// Append a segment's facts only from the point a reader may know them.
  List<Json> commit(
    Json segment,
    Json data,
    Json planned,
    Json decisions, [
    Json? guard,
  ]) {
    final Anchor anchor = Anchor(book, segment);
    final Set<String> knownNames = {
      for (final Json p in people.values) ...{
        ..._names(p['aliases']),
        p['name']! as String,
      },
    };
    final Json refmap = planned['refmap']! as Json;
    final Json surfaces = planned['surfaces']! as Json;
    final List<Json> records = [];
    String? ref(Object? x) => lookup(x, refmap);
    for (final Json np in _rows(data['new_people'])) {
      final String? pid =
          refmap[pyStr(_truth(np['ref']) ? np['ref'] : '')] as String?;
      if (pid == null || people.containsKey(pid)) continue;
      n = math.max(n, int.parse(pid.substring(1)));
      final (int s, _) = anchor.pos(np['para'], np['quote'] as String?);
      final String name =
          _strip(_s(np['name'])).isEmpty ? '无名氏' : _strip(_s(np['name']));
      final List<(int, String)> firsts = [];
      for (final MapEntry<String, Object?> f in surfaces.entries) {
        if (!((f.value! as Json)['ids']! as List<Object?>).contains(pid))
          continue;
        final (int, int)? hit = anchor.first(f.key);
        if (hit != null) firsts.add((hit.$1, f.key));
      }
      firsts.sort(
        (a, b) =>
            a.$1 != b.$1 ? a.$1.compareTo(b.$1) : PyCompat.compare(a.$2, b.$2),
      );
      final (int, int)? nameHit = anchor.first(name);
      String shown = name;
      if (nameHit != null && nameHit.$1 > s && !genericWord(name)) {
        final List<(int, String)> early =
            firsts.where((x) => s - 50 <= x.$1 && x.$1 < nameHit.$1).toList();
        final List<(int, String)> proper =
            early
                .where((x) => (surfaces[x.$2]! as Json)['generic'] != true)
                .toList();
        if (proper.isNotEmpty || early.isNotEmpty)
          shown = (proper.isNotEmpty ? proper : early).first.$2;
      }
      final Object imp =
          [1, 2, 3, true].contains(np['importance']) ? np['importance']! : 1;
      final String gender =
          ['男', '女'].contains(np['gender']) ? np['gender']! as String : '';
      final String intro = _cut(_strip(_s(np['intro'])), 40 * k);
      final int entry =
          shown != name || nameHit == null ? s : math.max(s, nameHit.$2);
      records.add({
        't': 'person',
        'p': entry,
        's': s,
        'id': pid,
        'name': shown,
        'gender': gender,
        'imp': imp,
        'intro': '',
      });
      if (intro.isNotEmpty)
        records.add({
          't': 'profile',
          'p': segment['o1'],
          'id': pid,
          'tagline': intro,
          'bio': '',
          'kind': 'intro',
        });
      if (shown != name && nameHit != null)
        records.add({'t': 'name', 'p': nameHit.$2, 'id': pid, 'name': name});
      people[pid] = {
        'id': pid,
        'name': name,
        'aliases': <String>{name, shown},
        'gender': gender,
        'imp': imp,
        'intro': intro,
        'tagline': intro,
        'bio': '',
        'first': entry,
        'mentions': 0,
        'profile_p': intro.isNotEmpty ? segment['o1'] : -1,
        'last_seg': seg,
      };
    }
    for (final Json a in _rows(data['aliases'])) {
      final String? pid = ref(a['who']);
      final String alias = _strip(_s(a['alias']));
      if (pid == null || !goodAlias(alias)) continue;
      final (_, int e) = anchor.pos(
        a['para'],
        _truth(a['quote']) ? a['quote'] as String : alias,
      );
      final int p = anchor.first(alias)?.$2 ?? e;
      records.add({'t': 'alias', 'p': p, 'id': pid, 'alias': alias});
      final Json person = people[pid]!;
      (person['aliases']! as Set<String>).add(alias);
      if (_truth(a['primary']) && alias != person['name']) {
        records.add({'t': 'name', 'p': p, 'id': pid, 'name': alias});
        person['name'] = alias;
      }
    }
    for (final MapEntry<String, Object?> e in surfaces.entries) {
      final Json v = e.value! as Json;
      if (v['generic'] == true) {
        for (final Object? pid in v['ids']! as List<Object?>) {
          if (people.containsKey(pid))
            ((people[pid]!['weak'] ??= <String>{}) as Set<String>).add(e.key);
        }
      }
    }
    for (final MapEntry<String, Object?> e in surfaces.entries) {
      final String f = e.key;
      final Json v = e.value! as Json;
      final List<Object?> ids = v['ids']! as List<Object?>;
      if (v['generic'] == true || ids.length != 1 || !goodAlias(f)) continue;
      final String pid = ids.first! as String;
      if (people[pid] != null && _names(people[pid]!['aliases']).contains(f))
        continue;
      final (int, int)? hit = anchor.first(f);
      if (hit != null) {
        records.add({'t': 'alias', 'p': hit.$2, 'id': pid, 'alias': f});
        (people[pid]!['aliases']! as Set<String>).add(f);
        if (genericWord(people[pid]!['name']! as String)) {
          records.add({'t': 'name', 'p': hit.$2, 'id': pid, 'name': f});
          people[pid]!['name'] = f;
        }
      }
    }
    for (final Json ev in _rows(data['events'])) {
      final List<String> who = [
        for (final Object? w in (ev['who'] as List<Object?>?) ?? [])
          if (ref(w) != null) ref(w)!,
      ];
      final String text = _strip(_s(ev['text']));
      if (text.isEmpty) continue;
      final (int s, int e) = anchor.pos(ev['para'], ev['quote'] as String?);
      final Object imp =
          [1, 2, 3, true].contains(ev['importance']) ? ev['importance']! : 1;
      records.add({
        't': 'event',
        'p': e,
        's': s,
        'who': who.toSet().toList(),
        'text': _cut(text, 80 * k),
        'imp': imp,
      });
      recent.add(text);
    }
    for (final Json at in _rows(data['attrs'])) {
      final String? pid = ref(at['who']);
      if (pid == null || !_truth(at['key']) || !_truth(at['value'])) continue;
      final (int s, int e) = anchor.pos(at['para'], at['quote'] as String?);
      records.add({
        't': 'attr',
        'p': e,
        's': s,
        'id': pid,
        'key': _cut(pyStr(at['key']), 8 * k),
        'value': _cut(pyStr(at['value']), 40 * k),
      });
    }
    for (final Json r in _rows(data['rels'])) {
      final String? a = ref(r['a']), b = ref(r['b']);
      if (a == null || b == null || a == b) continue;
      final (int s, int foundEnd) = anchor.pos(
        r['para'],
        r['quote'] as String?,
      );
      final int e =
          ['judge', 'judge+llm'].contains(r['by']) ||
                  r['evidence_scope'] == 'segment'
              ? segment['o1']! as int
              : foundEnd;
      final String status =
          ['new', 'changed', 'ended'].contains(r['status'])
              ? r['status']! as String
              : 'new';
      for (final String f in ['a_is', 'b_is']) {
        if (r[f] is String)
          r[f] = _strip(
            r[f]! as String,
          ).replaceFirst(pyRe(r'^[abAB]\s*的\s*'), '');
      }
      final int labelLimit = k == 1 ? 12 : 48;
      final Json record = {
        't': 'rel',
        'p': e,
        's': s,
        'a': a,
        'b': b,
        'a_is': _cut(_s(r['a_is']), labelLimit),
        'b_is': _cut(_s(r['b_is']), labelLimit),
        'desc': _cut(_s(r['desc']), 60 * k),
        'status': status,
      };
      records.add(record);
      rels[([a, b]..sort(PyCompat.compare)).join('|')] = {
        for (final String key in ['a', 'b', 'a_is', 'b_is', 'desc', 'status'])
          key: record[key],
      };
    }
    final Json checks = (guard?['checks'] as Json?) ?? {};
    for (final Json pr in _rows(data['profiles'])) {
      final String? pid = ref(pr['who']);
      if (pid == null) continue;
      final String tagline = _cut(_strip(_s(pr['tagline'])), 30 * k);
      final String bio = _cut(_strip(_s(pr['bio'])), 400 * k);
      if (tagline.isEmpty && bio.isEmpty) continue;
      final int p =
          pr['evidence_scope'] == 'segment'
              ? segment['o1']! as int
              : anchor.paraEnd(pr['para']);
      final Json record = {
        't': 'profile',
        'p': p,
        'id': pid,
        'tagline': tagline,
        'bio': bio,
      };
      final Object? check = checks[pyStr(pr['who'])];
      if (_truth(check)) record['chk'] = check;
      records.add(record);
      final Json person = people[pid]!;
      if (p >= ((person['profile_p'] as int?) ?? -1)) {
        person['tagline'] =
            tagline.isNotEmpty ? tagline : person['tagline'] ?? '';
        person['bio'] = bio.isNotEmpty ? bio : person['bio'] ?? '';
        person['profile_p'] = p;
      }
    }
    // Resolve dated references before mutating the identity registry.
    for (final Json m in _rows(data['merges'])) {
      final String? a = ref(m['from']), b = ref(m['into']);
      if (a == null || b == null || a == b) continue;
      final (int s, int e) = anchor.pos(m['para'], m['quote'] as String?);
      records.add(merge(a, b, e, s, _s(m['reason'])));
    }
    final Map<String, int> counts = {};
    for (final Json o in _rows(planned['occs'])) {
      final List<Object?> ids = o['ids']! as List<Object?>;
      String? pid =
          (o['ambiguous'] == true ? decisions[o['key']] : ids.first) as String?;
      if (pid == null || pid.isEmpty) continue;
      if (((people[pid]?['first'] as int?) ?? 0) > (o['e']! as int)) {
        final List<String> alternatives =
            ids
                .cast<String>()
                .where(
                  (x) =>
                      ((people[x]?['first'] as int?) ?? (1 << 60)) <=
                      (o['e']! as int),
                )
                .toList();
        if (alternatives.isEmpty) continue;
        pid = alternatives.first;
      }
      mentions.add([o['s'], o['e'], pid, o['generic'] == true ? 1 : 0]);
      final String cid = canon(pid)!;
      counts[cid] = (counts[cid] ?? 0) + 1;
      people[cid]!['mentions'] = ((people[cid]!['mentions'] as int?) ?? 0) + 1;
      people[cid]!['last_seg'] = seg;
    }
    for (final Json record in records) {
      for (final Object? pid in [
        record['id'],
        ...((record['who'] as List<Object?>?) ?? []),
        record['a'],
        record['b'],
      ]) {
        if (pid is String && people.containsKey(pid))
          people[canon(pid)]!['last_seg'] = seg;
      }
    }
    if (counts.isNotEmpty)
      records.add({'t': 'cnt', 'p': segment['o1'], 'c': counts});
    final Map<String, int> intro = {
      for (final Json r in records)
        if (r['t'] == 'person') r['id']! as String: r['p']! as int,
    };
    final Map<String, String> earlyId = {
      for (final Json r in records)
        if (r['t'] == 'merge' && intro.containsKey(r['into']))
          r['into']! as String: r['from']! as String,
    };
    String before(String x, int p) {
      final String? src = earlyId[x];
      return src != null && p < intro[x]! && (intro[src] ?? -1) <= p ? src : x;
    }

    for (final Json r in records) {
      final int p = r['p']! as int;
      if (r['t'] == 'event') {
        r['who'] =
            (r['who']! as List<Object?>)
                .cast<String>()
                .map((x) => before(x, p))
                .toSet()
                .toList();
      } else if (['attr', 'alias', 'profile'].contains(r['t']) &&
          earlyId.containsKey(r['id'])) {
        r['id'] = before(r['id']! as String, p);
      } else if (r['t'] == 'rel') {
        r['a'] = before(r['a']! as String, p);
        r['b'] = before(r['b']! as String, p);
      }
    }
    final List<(String, int, String)> reveals = [];
    final Map<String, String> shown = {
      for (final Json r in records)
        if (r['t'] == 'person') r['id']! as String: r['name']! as String,
    };
    for (final Json r in records) {
      if (r['t'] == 'name' && shown.containsKey(r['id']))
        reveals.add((r['name']! as String, r['p']! as int, shown[r['id']]!));
    }
    for (final MapEntry<String, String> pair in earlyId.entries) {
      final String? oldName =
          shown[pair.value] ?? people[pair.value]?['name'] as String?;
      if (oldName == null || oldName.isEmpty) continue;
      final Set<String> forms = {
        for (final MapEntry<String, Object?> f in surfaces.entries)
          if (((f.value! as Json)['ids']! as List<Object?>).contains(
                pair.key,
              ) &&
              (f.value! as Json)['generic'] != true)
            f.key,
        people[pair.key]!['name']! as String,
      };
      for (final String f in PyCompat.stableSorted(
        forms,
        key: (String name) => [-_len(name), name],
      )) {
        reveals.add((f, anchor.first(f)?.$1 ?? intro[pair.key]!, oldName));
      }
    }
    reveals.sort(
      (a, b) => PyCompat.compare(
        [-_len(a.$1), a.$1, a.$2, a.$3],
        [-_len(b.$1), b.$1, b.$2, b.$3],
      ),
    );
    const List<String> textKeys = [
      'text',
      'value',
      'tagline',
      'bio',
      'intro',
      'desc',
    ];
    for (final Json r in records) {
      for (final String key in textKeys) {
        if (r[key] is! String) continue;
        String text = r[key]! as String;
        for (final (String name, int q, String oldName) in reveals) {
          if ((r['p']! as int) < q &&
              name.isNotEmpty &&
              text.contains(name) &&
              name != oldName) {
            text = text
                .replaceAll(oldName + name, oldName)
                .replaceAll(name, oldName);
          }
        }
        r[key] = text;
      }
    }
    final Set<String> fresh = {
      for (final Json p in people.values)
        for (final String name in {
          ..._names(p['aliases']),
          p['name']! as String,
        })
          if (_len(name) >= 2 &&
              !knownNames.contains(name) &&
              !generic.contains(name))
            name,
    };
    final Map<String, int> firstAt = {};
    for (final String name in fresh.toList()..sort(PyCompat.compare)) {
      final (int, int)? hit = anchor.first(name);
      if (hit != null) firstAt[name] = hit.$2;
    }
    for (final Json r in records) {
      if (r['t'] == 'person' || r['t'] == 'cnt') continue;
      final String text = textKeys
          .map((key) => pyStr(_truth(r[key]) ? r[key] : ''))
          .join(' ');
      for (final MapEntry<String, int> e in firstAt.entries) {
        if (e.value > (r['p']! as int) && text.contains(e.key))
          r['p'] = e.value;
      }
    }
    for (final Json r in records) {
      final List<int> bounds = [r['p']! as int];
      if (['attr', 'alias', 'name', 'profile'].contains(r['t']) &&
          intro.containsKey(r['id'])) {
        bounds.add(intro[r['id']]!);
      } else if (r['t'] == 'rel') {
        bounds.addAll([intro[r['a']] ?? 0, intro[r['b']] ?? 0]);
      } else if (r['t'] == 'event') {
        bounds.addAll((r['who']! as List<Object?>).map((w) => intro[w] ?? 0));
      } else if (r['t'] == 'merge') {
        bounds.addAll([intro[r['from']] ?? 0, intro[r['into']] ?? 0]);
      }
      r['p'] = bounds.reduce(math.max);
      for (final String key in [...textKeys, 'reason']) {
        if (r[key] is String) r[key] = zh(r[key]);
      }
    }
    log.addAll(records);
    seg++;
    return records;
  }

  /// Return the merge record; callers decide when to append it to the log.
  Json merge(
    String a,
    String b,
    int p,
    int s,
    String reason, [
    String kind = '',
  ]) {
    final Json record = {
      't': 'merge',
      'p': p,
      's': s,
      'from': a,
      'into': b,
      'reason': _cut(reason, 80 * k),
    };
    if (kind.isNotEmpty) record['kind'] = kind;
    final Json src = people[a]!, dst = people[b]!;
    src['merged_into'] = b;
    (dst['aliases']! as Set<String>).addAll(_names(src['aliases']));
    if (genericWord(dst['name']! as String) &&
        !genericWord(src['name']! as String))
      dst['name'] = src['name'];
    ((dst['weak'] ??= <String>{}) as Set<String>).addAll(
      _names(src['weak'] ?? <String>{}),
    );
    dst['mentions'] =
        ((dst['mentions'] as int?) ?? 0) + ((src['mentions'] as int?) ?? 0);
    final Object dstImp = dst['imp'] ?? 1, srcImp = src['imp'] ?? 1;
    dst['imp'] = PyCompat.compare(dstImp, srcImp) >= 0 ? dstImp : srcImp;
    for (final MapEntry<String, Json> e in rels.entries.toList()) {
      final Json r = e.value;
      if (r['a'] == a || r['b'] == a) {
        rels.remove(e.key);
        final Json updated = {
          ...r,
          'a': r['a'] == a ? b : r['a'],
          'b': r['b'] == a ? b : r['b'],
        };
        if (updated['a'] != updated['b']) {
          rels[([updated['a']! as String, updated['b']! as String]
                ..sort(PyCompat.compare)).join('|')] =
              updated;
        }
      }
    }
    return record;
  }

  void addRecap(int chapter, int pos, String recap, String sagaText) {
    recap = zh(recap)! as String;
    sagaText = zh(sagaText)! as String;
    if (recap.isNotEmpty)
      log.add({'t': 'recap', 'p': pos, 'chapter': chapter, 'text': recap});
    if (sagaText.isNotEmpty) {
      log.add({'t': 'saga', 'p': pos, 'text': sagaText});
      saga = sagaText;
    }
  }
}

/// Withhold facts that depend on an identity at or after its taint frontier.
(
  List<Json>,
  List<List<Object?>>,
  List<Json>,
  List<List<Object?>>,
  Map<String, int>,
)
quarantineIdentities(
  List<Json> records,
  List<List<Object?>> mentions,
  Map<String, int> seeds,
) {
  final Map<String, int> taint = {...seeds};
  final List<Json> edges = records.where((r) => r['t'] == 'merge').toList();
  bool changed = true;
  while (changed) {
    changed = false;
    for (final Json r in edges) {
      final String a = r['from']! as String, b = r['into']! as String;
      for (final (String source, String target) in [(a, b), (b, a)]) {
        if (taint.containsKey(source)) {
          final int start = math.max(r['p']! as int, taint[source]!);
          if (!taint.containsKey(target) || start < taint[target]!) {
            taint[target] = start;
            changed = true;
          }
        }
      }
    }
  }
  final List<Json> kept = [], withheld = [];
  for (final Json row in records) {
    final int p = row['p']! as int;
    bool unsafe(Object? id) => taint.containsKey(id) && p >= taint[id]!;
    if (row['t'] == 'person' && unsafe(row['id']) && _truth(row['intro'])) {
      withheld.add(row);
      kept.add({...row, 'intro': ''});
      continue;
    }
    final List<Object?> refs = [
      for (final String key in ['id', 'a', 'b', 'from', 'into'])
        if (row.containsKey(key)) row[key],
      ...((row['who'] as List<Object?>?) ?? []),
      ...((row['c'] as Json?) ?? {}).keys,
    ];
    (row['t'] != 'person' && refs.any(unsafe) ? withheld : kept).add(row);
  }
  final List<List<Object?>> safeMentions = [], withheldMentions = [];
  for (final List<Object?> mention in mentions) {
    (taint.containsKey(mention[2]) && (mention[1]! as int) >= taint[mention[2]]!
            ? withheldMentions
            : safeMentions)
        .add(mention);
  }
  return (kept, safeMentions, withheld, withheldMentions, taint);
}
