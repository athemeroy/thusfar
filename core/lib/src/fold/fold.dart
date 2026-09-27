/// The reader-side temporal knowledge graph: `web/js/kg.js` `fold()`.
///
/// `fold(records, cutoff)` turns every record with `p <= cutoff` into what the
/// reader knows at that page. Values are JSON-shaped maps exactly as the
/// browser built them; [Person], [Relation] and [StoryEvent] give typed access.
library;

typedef Json = Map<String, Object?>;

final Set<String> generic =
    '父亲 母亲 爸爸 妈妈 爹 娘 儿子 女儿 丈夫 妻子 太太 夫人 先生 老爷 小姐 姑娘 少女 女孩 少年 男孩 青年 少爷 医生 大夫 校长 老师 神父 堂长 老板 老板娘 仆人 女仆 老头子 老太太 老头 孩子 哥哥 姐姐 弟弟 妹妹 叔叔 伯父 舅舅 姑妈 姨妈 祖父 祖母 爷爷 奶奶 外公 外婆 公公 婆婆 岳父 岳母 丈人 主人 客人 新娘 新郎 新娘子 新夫人 寡妇 邻居 朋友 同学 学生 病人 大人 老人 年轻人 女人 男人 闺女 媳妇 老婆 老公 东家 女婿 未婚女婿 未婚妻 未婚夫 儿媳'
        .split(' ')
        .toSet();

final RegExp _leadingKin = RegExp('^[他她的老小未]+');
final RegExp _notAName = RegExp('的|夫妇|夫妻|们|一家|俩');

bool _truthy(Object? v) =>
    v != null && v != false && v != 0 && v != '' && !(v is double && v.isNaN);

/// JavaScript `a || b`.
Object? _or(Object? a, Object? b) => _truthy(a) ? a : b;

num _num(Object? v) => v is num ? v : 0;

/// Copies [source] and sets [key] only when the JS value is defined.
void _put(Json target, String key, Object? value, {required bool defined}) {
  if (defined) target[key] = value;
}

/// What the reader knows at [cutoff].
final class World {
  World._(
    this.cutoff,
    this.people,
    this._merges,
    this.rels,
    this.events,
    this.recaps,
    this.saga,
  );

  final int cutoff;

  /// Person maps by id, in the order they entered the story.
  final Map<String, Json> people;
  final Map<String, Json> _merges;
  final List<Json> rels;
  final List<Json> events;
  final List<Json> recaps;
  final Json? saga;

  /// Filled by the caller from the book's processing status.
  int frontier = 0;
  String state = '';

  /// The identity [id] was merged into, following merge chains.
  String canon(String id) {
    if (!_merges.containsKey(id)) return id;
    final Set<String> seen = <String>{};
    String current = id;
    while (_merges.containsKey(current) && !seen.contains(current)) {
      seen.add(current);
      current = _merges[current]!['into']! as String;
    }
    return current;
  }

  Person? person(String id) {
    final Json? raw = people[canon(id)];
    return raw == null ? null : Person(raw);
  }

  /// This person's relations, ongoing first, most recent first.
  List<Json> relsOf(String rawId) {
    final String id = canon(rawId);
    final List<Json> out = <Json>[];
    for (final Json r in rels) {
      if (r['a'] != id && r['b'] != id) continue;
      final bool mine = r['a'] == id;
      final List<Object?> history =
          (r['history'] as List<Object?>?) ?? const [];
      final Object? current = mine ? r['b_is'] : r['a_is'];
      final List<Object?> also = <Object?>[];
      for (final Object? old in history) {
        final Object? v = (old! as Json)[mine ? 'b_is' : 'a_is'];
        if (_truthy(v) && v != current && !also.contains(v)) also.add(v);
      }
      final Json row = <String, Object?>{'other': mine ? r['b'] : r['a']};
      void copy(String to, String from) {
        if (r.containsKey(from)) row[to] = r[from];
      }

      if (mine) {
        copy('role', 'b_is');
        copy('myRole', 'a_is');
      } else {
        copy('role', 'a_is');
        copy('myRole', 'b_is');
      }
      copy('desc', 'desc');
      copy('status', 'status');
      copy('p', 'p');
      copy('s', 's');
      copy('history', 'history');
      row['also'] = also;
      row['times'] = _or(r['times'], 1);
      out.add(row);
    }
    final List<(int, Json)> indexed = <(int, Json)>[
      for (int i = 0; i < out.length; i++) (i, out[i]),
    ];
    indexed.sort(((int, Json) x, (int, Json) y) {
      final int ended =
          (y.$2['status'] != 'ended' ? 1 : 0) -
          (x.$2['status'] != 'ended' ? 1 : 0);
      if (ended != 0) return ended;
      final num byP = _num(y.$2['p']) - _num(x.$2['p']);
      if (byP != 0) return byP.sign.toInt();
      return x.$1.compareTo(y.$1);
    });
    return <Json>[for (final (int, Json) row in indexed) row.$2];
  }

  /// People by prominence: mentions, importance and events.
  List<Json> ranked() {
    num score(Json p) =>
        _num(p['n']) +
        _num(p['imp']) * 8 +
        (p['events']! as List<Object?>).length * 2;
    final List<(int, Json)> indexed = <(int, Json)>[];
    int i = 0;
    for (final Json p in people.values) {
      indexed.add((i++, p));
    }
    indexed.sort(((int, Json) a, (int, Json) b) {
      final num d = score(b.$2) - score(a.$2);
      if (d != 0) return d.sign.toInt();
      return a.$1.compareTo(b.$1);
    });
    return <Json>[for (final (int, Json) row in indexed) row.$2];
  }
}

/// Folds [records] (sorted by `p`) up to and including [cutoff].
World fold(List<Json> records, int cutoff) {
  final Map<String, Json> people = <String, Json>{};
  final Map<String, Json> merges = <String, Json>{};
  final List<Json> relationRecords = <Json>[];
  final List<Json> events = <Json>[];
  final List<Json> recaps = <Json>[];
  Json? saga;
  final Map<Object?, List<Json>> early = <Object?, List<Json>>{};

  void hold(Json r) => early.putIfAbsent(r['id'], () => <Json>[]).add(r);

  void apply(Json r) {
    switch (r['t']) {
      case 'person':
        final Object? intro = r['intro'];
        final Json person = <String, Object?>{
          'id': r['id'],
          'name': r['name'],
          'firstName': r['name'],
          'aliases': <Object?>[],
        };
        _put(person, 'gender', r['gender'], defined: r.containsKey('gender'));
        person['imp'] = _or(r['imp'], 1);
        person['intro'] = _or(intro, '');
        person['tagline'] = _or(intro, '');
        person['bio'] = '';
        person['bioP'] = null;
        person['chk'] = null;
        person['attrs'] = <String, Object?>{};
        person['events'] = <Object?>[];
        person['n'] = 0;
        person['first'] = r['s'] ?? r['p'];
        person['color'] = personColor(r['id']);
        person['merged'] = <Object?>[];
        person['trail'] = <Object?>[
          if (_truthy(intro)) <String, Object?>{'p': r['p'], 't': intro},
        ];
        person['manual'] = _truthy(r['manual']);
        person['entityKind'] = _or(r['entity_kind'], 'person');
        people[r['id']! as String] = person;
      case 'name':
        final Json? p = people[r['id']];
        if (p == null) {
          hold(r);
        } else if (p['name'] != r['name']) {
          (p['aliases']! as List<Object?>).add(p['name']);
          p['name'] = r['name'];
        }
      case 'alias':
        final Json? p = people[r['id']];
        if (p != null) {
          (p['aliases']! as List<Object?>).add(r['alias']);
        } else {
          hold(r);
        }
      case 'merge':
        final Json m = <String, Object?>{'into': r['into']};
        _put(m, 'p', r['p'], defined: r.containsKey('p'));
        _put(m, 's', r['s'], defined: r.containsKey('s'));
        _put(m, 'reason', r['reason'], defined: r.containsKey('reason'));
        merges[r['from']! as String] = m;
      case 'profile':
        final Json? p = people[r['id']];
        if (p == null) hold(r);
        if (p != null) {
          if (_truthy(r['tagline'])) {
            p['tagline'] = r['tagline'];
            final List<Object?> trail = p['trail']! as List<Object?>;
            final Json? last = trail.isEmpty ? null : trail.last! as Json;
            if (last != null &&
                _num(r['p']) - _num(last['p']) < 600 &&
                trail.length > 1) {
              last['t'] = r['tagline'];
              last['p'] = r['p'];
            } else if (last == null || last['t'] != r['tagline']) {
              trail.add(<String, Object?>{'p': r['p'], 't': r['tagline']});
            }
          }
          if (_truthy(r['bio']) || _truthy(r['manual'])) {
            p['bio'] = _or(r['bio'], '');
            p['bioP'] = r['p'];
            p['chk'] = _or(r['chk'], null);
          }
        }
      case 'attr':
        final Json? p = people[r['id']];
        if (p != null) {
          final Json attrs = p['attrs']! as Json;
          final List<Object?> list =
              (attrs[r['key']! as String] ??= <Object?>[]) as List<Object?>;
          final Json v = <String, Object?>{'v': r['value'], 'p': r['p']};
          _put(v, 's', r['s'], defined: r.containsKey('s'));
          list.add(v);
        } else {
          hold(r);
        }
      case 'rel':
        relationRecords.add(r);
      case 'event':
        events.add(<String, Object?>{
          ...r,
          'who': <Object?>[...r['who']! as List<Object?>],
        });
      case 'imp':
        final Json? p = people[r['id']];
        if (p != null) {
          if (r.containsKey('imp')) {
            p['imp'] = r['imp'];
          } else {
            p.remove('imp');
          }
        }
      case 'cnt':
        for (final MapEntry<String, Object?> e in (r['c']! as Json).entries) {
          final Json? p = people[e.key];
          if (p != null) p['n'] = _num(p['n']) + _num(e.value);
        }
      case 'recap':
        recaps.add(r);
      case 'saga':
        saga = r;
    }
    if (r['t'] == 'person' && early.containsKey(r['id'])) {
      final List<Json> queue = early.remove(r['id'])!;
      queue.forEach(apply);
    }
  }

  for (final Json r in records) {
    if (_num(r['p']) > cutoff) break;
    apply(r);
  }

  final World world = World._(
    cutoff,
    people,
    merges,
    <Json>[],
    events,
    recaps,
    saga,
  );
  final String Function(String) canon = world.canon;

  for (final MapEntry<String, Json> entry in merges.entries.toList()) {
    final String from = entry.key;
    final Json m = entry.value;
    final String to = canon(from);
    final Json? a = people[from];
    final Json? b = people[to];
    if (a == null || b == null || identical(a, b)) continue;
    final Object? oldName = b['name'];
    if (generic.contains(b['name']) && !generic.contains(a['name'])) {
      b['name'] = a['name'];
    }
    (b['aliases']! as List<Object?>)
      ..add(a['name'])
      ..addAll(a['aliases']! as List<Object?>);
    b['n'] = _num(b['n']) + _num(a['n']);
    final num bf = _num(b['first']);
    final num af = _num(a['first']);
    b['first'] = af < bf ? a['first'] : b['first'];
    final Json bAttrs = b['attrs']! as Json;
    for (final MapEntry<String, Object?> e in (a['attrs']! as Json).entries) {
      final List<Object?> merged = <Object?>[
        ...e.value! as List<Object?>,
        ...(bAttrs[e.key] as List<Object?>?) ?? const <Object?>[],
      ];
      bAttrs[e.key] = _stableSortBy(
        merged,
        (Object? x) => _num((x! as Json)['p']),
      );
    }
    final Json note = <String, Object?>{
      'name': b['name'] != oldName ? oldName : _or(a['firstName'], a['name']),
    };
    _put(note, 'p', m['p'], defined: m.containsKey('p'));
    _put(note, 's', m['s'], defined: m.containsKey('s'));
    _put(note, 'reason', m['reason'], defined: m.containsKey('reason'));
    (b['merged']! as List<Object?>).add(note);
    if (!_truthy(b['bio']) && _truthy(a['bio'])) {
      b['bio'] = a['bio'];
      b['bioP'] = a['bioP'];
    }
    people.remove(from);
  }

  final Map<Object?, Object?> names = <Object?, Object?>{};
  for (final Json p in people.values) {
    names[p['name']] = p['id'];
  }
  for (final Json p in people.values) {
    final List<Object?> unique = <Object?>[];
    for (final Object? x in p['aliases']! as List<Object?>) {
      if (!unique.contains(x)) unique.add(x);
    }
    p['aliases'] = <Object?>[
      for (final Object? x in unique)
        if (_truthy(x) &&
            x != p['name'] &&
            !generic.contains(x) &&
            !generic.contains((x! as String).replaceFirst(_leadingKin, '')) &&
            !_notAName.hasMatch(x as String) &&
            !(names.containsKey(x) && names[x] != p['id']))
          x,
    ];
  }

  for (final Json e in events) {
    final List<String> who = <String>[];
    for (final Object? raw in e['who']! as List<Object?>) {
      final String id = canon(raw! as String);
      if (!who.contains(id) && people.containsKey(id)) who.add(id);
    }
    e['whoC'] = who;
    for (final String id in who) {
      (people[id]!['events']! as List<Object?>).add(e);
    }
  }

  final Map<String, Json> seen = <String, Json>{};
  for (final Json r in relationRecords) {
    final String a = canon(r['a']! as String);
    final String b = canon(r['b']! as String);
    if (a == b || !people.containsKey(a) || !people.containsKey(b)) continue;
    final List<String> ids = <String>[a, b]..sort(_jsCompare);
    final String k = <Object?>[...ids, _or(r['family'], '')].join('|');
    final Json x;
    if (a == ids[0]) {
      x = <String, Object?>{...r, 'a': a, 'b': b};
    } else {
      x = <String, Object?>{...r, 'a': b, 'b': a};
      x['a_is'] = r['b_is'];
      x['b_is'] = r['a_is'];
      if (!r.containsKey('b_is')) x.remove('a_is');
      if (!r.containsKey('a_is')) x.remove('b_is');
    }
    final Json? prev = seen[k];
    final List<Object?> history =
        prev != null ? prev['history']! as List<Object?> : <Object?>[];
    if (prev != null) {
      history.add(
        <String, Object?>{...prev}
          ..remove('history')
          ..remove('also'),
      );
    }
    final Json latest = <String, Object?>{...?prev, ...x, 'history': history};
    for (final String field in const <String>[
      'a_is',
      'b_is',
      'desc',
      'status',
    ]) {
      if (!_truthy(x[field]) && prev != null && _truthy(prev[field])) {
        latest[field] = prev[field];
      }
    }
    latest['times'] = history.length + 1;
    seen[k] = latest;
  }
  for (final Json r in seen.values) {
    final List<Object?> also = <Object?>[];
    for (final Object? old in r['history']! as List<Object?>) {
      final Object? v = (old! as Json)['b_is'];
      if (_truthy(v) && v != r['b_is'] && !also.contains(v)) also.add(v);
    }
    r['also'] = also;
  }
  world.rels.addAll(seen.values);
  return world;
}

int _jsCompare(String a, String b) => a.compareTo(b);

List<Object?> _stableSortBy(List<Object?> list, num Function(Object?) key) {
  final List<(int, Object?)> rows = <(int, Object?)>[
    for (int i = 0; i < list.length; i++) (i, list[i]),
  ];
  rows.sort(((int, Object?) x, (int, Object?) y) {
    final num d = key(x.$2) - key(y.$2);
    if (d != 0) return d.sign.toInt();
    return x.$1.compareTo(y.$1);
  });
  return <Object?>[for (final (int, Object?) r in rows) r.$2];
}

/// `util.js personColor`: a stable ink per person id.
String personColor(Object? id) {
  final String digits = '$id'.replaceAll(RegExp(r'\D'), '');
  final int n = int.tryParse(digits.isEmpty ? 'x' : digits) ?? 0;
  return inks[(n * 7) % inks.length];
}

/// `util.js INKS`.
const List<String> inks = <String>[
  '#b8401c',
  '#35507a',
  '#4f7a5a',
  '#8a5a2b',
  '#b08a2e',
  '#9c3450',
  '#3d5d6b',
  '#2f6f63',
  '#6d4a3a',
  '#6a4a7a',
  '#557080',
  '#c0602a',
];

/// Typed view of a folded person.
extension type Person(Json raw) {
  String get id => raw['id']! as String;
  String get name => '${raw['name']}';
  List<String> get aliases => <String>[
    for (final Object? a in raw['aliases']! as List<Object?>) '$a',
  ];
  String get tagline => '${raw['tagline'] ?? ''}';
  String get bio => '${raw['bio'] ?? ''}';
  int get importance => _num(raw['imp']).toInt();
  int get mentions => _num(raw['n']).toInt();
  int get first => _num(raw['first']).toInt();
  bool get manual => raw['manual'] == true;
  String get entityKind => '${raw['entityKind']}';
  List<Json> get events => <Json>[
    for (final Object? e in raw['events']! as List<Object?>) e! as Json,
  ];
  Map<String, List<Json>> get attrs => <String, List<Json>>{
    for (final MapEntry<String, Object?> e in (raw['attrs']! as Json).entries)
      e.key: <Json>[
        for (final Object? v in e.value! as List<Object?>) v! as Json,
      ],
  };
  List<Json> get trail => <Json>[
    for (final Object? t in raw['trail']! as List<Object?>) t! as Json,
  ];
}
