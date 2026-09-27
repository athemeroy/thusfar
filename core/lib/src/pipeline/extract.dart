/// Segments and phase-1 prompt material (`pipeline/extract.py`).
library;

import '../py/py_compat.dart';
import 'lang.dart' as lang;
import 'prompts.dart';

typedef Json = Map<String, Object?>;

int _u16(String s) => s.length;

List<Json> _list(Object? v) => <Json>[
  for (final Object? x in (v as List<Object?>?) ?? const <Object?>[])
    x! as Json,
];

/// Paragraph-aligned segments of about [maxChars] over the body chapters.
List<Json> segments(Json book, List<int> body, {int? maxChars}) {
  final int limit = maxChars ?? lang.segChars(book);
  final List<Json> segs = <Json>[];
  final List<Json> blocks = _list(book['blocks']);
  final List<Json> chapters = _list(book['chapters']);
  for (final int ci in body) {
    final Json ch = chapters[ci];
    List<int> cur = <int>[];
    int size = 0;
    for (int bi = ch['b0']! as int; bi < (ch['b1']! as int); bi++) {
      final Json b = blocks[bi];
      final String t = b['t']! as String;
      if (b['k'] == 'img' || t.isEmpty) continue;
      final int n = _u16(t);
      if (cur.isNotEmpty && size + n > limit) {
        segs.add(<String, Object?>{'chapter': ci, 'blocks': cur});
        cur = <int>[];
        size = 0;
      }
      cur.add(bi);
      size += n;
    }
    if (cur.isNotEmpty)
      segs.add(<String, Object?>{'chapter': ci, 'blocks': cur});
  }
  final List<Json> merged = <Json>[];
  List<int> carry = <int>[];
  for (int k = 0; k < segs.length; k++) {
    final Json s = segs[k];
    final List<int> ids = (s['blocks']! as List<Object?>).cast<int>();
    int textLen = 0;
    for (final int i in ids) {
      textLen += _u16(blocks[i]['t']! as String);
    }
    if (textLen < 120 && k != segs.length - 1) {
      carry.addAll(ids);
      continue;
    }
    s['blocks'] = <int>[...carry, ...ids];
    carry = <int>[];
    merged.add(s);
  }
  for (int i = 0; i < merged.length; i++) {
    final Json s = merged[i];
    final List<int> ids = (s['blocks']! as List<Object?>).cast<int>();
    s['i'] = i;
    s['o0'] = blocks[ids.first]['o'];
    final Json last = blocks[ids.last];
    s['o1'] = (last['o']! as int) + _u16(last['t']! as String);
    int chars = 0;
    for (final int j in ids) {
      chars += _u16(blocks[j]['t']! as String);
    }
    s['chars'] = chars;
  }
  return merged;
}

String segText(Json book, Json seg) {
  final List<Object?> blocks = book['blocks']! as List<Object?>;
  final List<String> lines = <String>[];
  int n = 1;
  for (final Object? bi in seg['blocks']! as List<Object?>) {
    final Json b = blocks[bi! as int]! as Json;
    final String prefix = b['k'] == 'h' ? '【标题】' : '';
    lines.add('[P$n] $prefix${b['t']}');
    n++;
  }
  return lines.join('\n');
}

num _n(Object? v, num d) => v is num ? v : d;

List<String> _aliases(Json p) => <String>[
  for (final Object? a in (p['aliases'] as List<Object?>?) ?? const <Object?>[])
    '$a',
];

String registryPrompt(Json state, String text) {
  final List<Json> people = <Json>[];
  for (final Object? raw in (state['people']! as Json).values) {
    final Json p = raw! as Json;
    final Object? m = p['merged_into'];
    if (m == null || m == '' || m == false || m == 0) people.add(p);
  }
  if (people.isEmpty) return '（暂无，本段是第一段或此前没有出现人物）';
  final num segNo = _n(state['seg'], 0);
  final List<String> full = <String>[];
  final List<String> short = <String>[];
  final List<Json> sorted = PyCompat.stableSorted<Json>(
    people,
    key: (Json p) => <Object?>[-_n(p['importance'], 1), -_n(p['mentions'], 0)],
  );
  for (final Json p in sorted) {
    final List<String> aliases = _aliases(p);
    final List<Object?> names = <Object?>[p['name'], ...aliases];
    final bool present = names.any(
      (Object? n) => n is String && n.isNotEmpty && text.contains(n),
    );
    final bool recent = segNo - _n(p['last_seg'], -99) <= 4;
    if (present || recent || _n(p['importance'], 1) >= 3) {
      full.add(
        '${p['id']}｜${p['name']}｜别称：${aliases.isEmpty ? '无' : aliases.join('、')}｜${p['tagline'] ?? ''}\n    简介：${p['bio'] ?? ''}',
      );
    } else {
      short.add(
        '${p['id']}｜${p['name']}｜${aliases.take(4).join('、')}｜${p['tagline'] ?? ''}',
      );
    }
  }
  String out = full.join('\n');
  if (short.isNotEmpty)
    out += '\n\n（以下人物本段可能未出场，仅列出以便沿用 id）\n${short.take(400).join('\n')}';
  return out;
}

String relationsPrompt(Json state, String text) {
  final List<String> rows = <String>[];
  final Json people = state['people']! as Json;
  for (final Object? raw in (state['rels']! as Json).values) {
    final Json r = raw! as Json;
    if (r['status'] == 'ended') continue;
    final Json? a = people[r['a']] as Json?;
    final Json? b = people[r['b']] as Json?;
    if (a == null || b == null) continue;
    final List<Object?> names = <Object?>[
      a['name'],
      b['name'],
      ..._aliases(a),
      ..._aliases(b),
    ];
    if (names.any((Object? n) => text.contains('$n'))) {
      rows.add(
        '${r['a']}（${a['name']}）的${r['b_is']}是 ${r['b']}（${b['name']}）：${r['desc'] ?? ''}',
      );
    }
  }
  return rows.isEmpty ? '（无）' : rows.take(120).join('\n');
}

String chapterLabel(Json book, Json seg) {
  final Json ch =
      (book['chapters']! as List<Object?>)[seg['chapter']! as int]! as Json;
  final Object? parent = ch['parent'];
  final bool hasParent = parent is String && parent.isNotEmpty;
  return '${hasParent ? '$parent · ' : ''}${ch['title']}';
}

List<Map<String, String>> buildMessages(Json book, Json state, Json seg) {
  final String text = segText(book, seg);
  final List<Object?> recentEvents =
      (state['recent_events'] as List<Object?>?) ?? const <Object?>[];
  final Iterable<Object?> last10 =
      recentEvents.length > 10
          ? recentEvents.sublist(recentEvents.length - 10)
          : recentEvents;
  final String recent =
      last10.isEmpty ? '（无）' : last10.map((Object? e) => '- $e').join('\n');
  final Object? author = book['author'];
  final Object? saga = state['saga'];
  final String user =
      '''【作品】《${book['title']}》${author is String && author.isNotEmpty ? author : ''}
【当前章节】${chapterLabel(book, seg)}

【前情提要】
${saga is String && saga.isNotEmpty ? saga : '（故事刚开始）'}

【最近发生的事】
$recent

【已知人物档案】（截至本段之前）
${registryPrompt(state, text)}

【已知关系】
${relationsPrompt(state, text)}

【本段原文】
$text

请输出 JSON。''';
  return <Map<String, String>>[
    <String, String>{'role': 'system', 'content': extractSystem},
    <String, String>{'role': 'user', 'content': user},
  ];
}
