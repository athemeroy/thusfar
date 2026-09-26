/// Link local people to the cast known before this segment (`pipeline/link.py`).
library;

import '../py/py_compat.dart';
import '../py/py_re.dart';
import '../py/py_repr.dart';
import 'jev.dart' as llm;
import 'judge.dart' show batch, sameQuestion;
import 'kg.dart';

typedef Json = Map<String, Object?>;
typedef LinkQuestion = (String, Json, List<String>);

/// Uses the normal Jev cache and routing; recordings replace this in tests.
Future<Json> Function(Object? state, Json questions) linkCall =
    (Object? state, Json questions) => llm.jev(state, questions);

int _len(String s) => s.runes.length;
String _unstar(String s) => s.replaceFirst(RegExp(r'^\*+'), '');
List<String> _sorted(Iterable<String> names) =>
    names.toList()..sort((String a, String b) => PyCompat.compare(a, b));
Set<String> _set(Object? value) =>
    value == null
        ? <String>{}
        : (value as Iterable<Object?>).cast<String>().toSet();
Json _obj(Object? value) => value as Json? ?? <String, Object?>{};
List<Json> _rows(Object? value) =>
    (value as List<Object?>? ?? <Object?>[]).cast<Json>();
bool _truthy(Object? value) =>
    value != null &&
    value != false &&
    value != 0 &&
    value != '' &&
    !(value is Iterable<Object?> && value.isEmpty) &&
    !(value is Map<Object?, Object?> && value.isEmpty);
Object? _get(Json obj, String key, [Object? fallback = '']) =>
    obj.containsKey(key) ? obj[key] : fallback;
String _role(Json obj) => pyStr(_get(obj, 'role'));
String _bio(Json obj) => pyStr(
  _truthy(obj['tagline'])
      ? obj['tagline']
      : _truthy(obj['intro'])
      ? obj['intro']
      : '',
);
Iterable<Object?> _rawNames(Json p) => <Object?>[
  _get(p, 'name'),
  ...(p['names'] as List<Object?>? ?? <Object?>[]),
];

bool isGeneric(String name) =>
    name.startsWith('*') || genericWord(_unstar(name));

Set<String> strongNames(Json p) {
  final Set<String> out = <String>{};
  for (final Object? raw in _rawNames(p)) {
    if (raw is! String) continue;
    final String n = PyCompat.strip(_unstar(raw));
    if (_len(n) >= 2 &&
        !pronouns.contains(n) &&
        !pronouns.contains(n.toLowerCase()) &&
        !isGeneric(raw))
      out.add(n);
  }
  return out;
}

Set<String> weakNames(Json p) {
  final Set<String> out = <String>{};
  for (final Object? raw in _rawNames(p)) {
    if (raw is! String || !isGeneric(raw)) continue;
    final String n = PyCompat.strip(_unstar(raw));
    if (_len(n) >= 2 &&
        !pronouns.contains(n) &&
        !pronouns.contains(n.toLowerCase()))
      out.add(n);
  }
  return out;
}

final RegExp suffix = pyRe(
  r'(先生|太太|夫人|小姐|老爹|老头子|老头|嫂子|大妈|大娘|大爷|老爷|少爷|姑娘|女士|博士|医生|律师|师傅|掌柜|老板|公子|奶奶'
  r'|大师|禅师|法师|道长|真人|长老|方丈|师太|道人|居士|上人|掌门|宗主|城主|门主|帮主|盟主|会长|队长|团长|将军|前辈|老祖'
  r'|师兄|师姐|师弟|师妹|师父|师尊|大哥|大姐|爷|嫂|娘)$',
);
final RegExp kin1 = pyRe(r'(叔|伯|哥|姐|嫂|婶|爷|总|董|老|兄|弟|妹)$');
final RegExp enTitle = pyRe(
  r'^(?:mr|mrs|miss|ms|dr|sir|lady|lord|uncle|aunt|captain|capt|master|mister|madame|madam|monsieur|mademoiselle'
  r'|father|mother|brother|sister|old|young|little|professor|colonel|major|general|reverend|rev)\.?\s+',
  ignoreCase: true,
);
const Set<String> enStop = <String>{
  'the',
  'of',
  'a',
  'an',
  'and',
  'de',
  'la',
  'le',
  'du',
  'von',
  'van',
  'old',
  'young',
  'little',
  'mr',
  'mrs',
  'miss',
  'sir',
  'lady',
  'lord',
};

/// Removes a title, only to propose candidates.
String core(String? name) {
  name ??= '';
  String c = name;
  if (isLatin(name)) {
    while (enTitle.hasMatch(c)) {
      c = c.replaceFirst(enTitle, '');
    }
  } else {
    c = c.replaceAll(suffix, '');
  }
  return _len(c) >= 2 && c != name ? c : '';
}

Set<String> tokens(String name) => <String>{
  for (final RegExpMatch m in RegExp(r"[A-Za-z][A-Za-z'’\-]+").allMatches(name))
    m[0]!.toLowerCase(),
}.difference(enStop);

String stem(String name) {
  String n = _unstar(name).replaceAll(suffix, '');
  if (_len(n) >= 2) n = n.replaceFirst(RegExp(r'^(老|小|阿)'), '');
  if (_len(n) >= 2 && _len(n) <= 3 && kin1.hasMatch(n)) {
    n = n.replaceAll(kin1, '');
  }
  return n;
}

/// Deliberately asymmetric: a new surname/title may attach to a known full name.
bool related(String newName, String known) {
  final String a = _unstar(newName), b = _unstar(known);
  if (a.isEmpty || b.isEmpty) return false;
  if (a == b ||
      (_len(a) >= 2 && _len(b) >= 2 && (a.contains(b) || b.contains(a))))
    return true;
  if (isLatin(a) || isLatin(b))
    return tokens(a).intersection(tokens(b)).isNotEmpty;
  final String sa = stem(a), sb = stem(b);
  if (_len(sa) >= 2 && _len(sb) >= 2) {
    return sb.contains(sa) ||
        sa.contains(sb) ||
        b.contains(sa) ||
        a.contains(sb);
  }
  if (_len(sa) == 1 && _len(sb) >= 2) {
    return b.startsWith(sa) || sb.startsWith(sa) || sb.endsWith(sa);
  }
  if (_len(sa) == 1 && _len(sb) == 1) return sa == sb;
  return false;
}

String properName(Json p) {
  final String name = p['name']! as String;
  if (!isGeneric(name)) return name;
  final List<String> named =
      _set(
          p['aliases'],
        ).where((String n) => !isGeneric(n) && !pronouns.contains(n)).toList()
        ..sort((String a, String b) {
          final int size = _len(b).compareTo(_len(a));
          return size != 0 ? size : PyCompat.compare(a, b);
        });
  return named.isNotEmpty ? named.first : name;
}

Set<String> namesOf(Json p) => <String>{
  ..._set(p['aliases']),
  p['name']! as String,
  ..._set(p['weak']),
};

Set<String> shortForms(String name) {
  if (isLatin(name)) {
    final String c = core(name);
    final List<String> parts =
        PyCompat.split(c.isNotEmpty ? c : name)
            .where(
              (String w) => _len(w) >= 3 && !enStop.contains(w.toLowerCase()),
            )
            .toList();
    return parts.length > 1 ? parts.toSet() : <String>{};
  }
  if (suffix.hasMatch(name)) return <String>{};
  if (name.contains('·'))
    return name.split('·').where((String x) => _len(x) >= 2).toSet();
  if (_len(name) >= 3 && _len(name) <= 4)
    return <String>{PyCompat.slice(name, 1, null)};
  return <String>{};
}

Future<(Json, Json)> linkSegment(
  KG kg,
  Json seg,
  Json local,
  String contextText, {
  int scopeStart = 0,
}) async {
  final Map<String, Json> cast = <String, Json>{
    for (final MapEntry<String, Json> e in kg.people.entries)
      if (!_truthy(e.value['merged_into']) &&
          (e.value['first'] as num? ?? 0) >= scopeStart)
        e.key: e.value,
  };
  final Map<String, Set<String>> byName = <String, Set<String>>{};
  final Map<String, Set<String>> weakIdx = <String, Set<String>>{};
  final List<(String, String)> allNames = <(String, String)>[];
  for (final MapEntry<String, Json> e in cast.entries) {
    for (final String n in _sorted(<String>{
      ..._set(e.value['aliases']),
      e.value['name']! as String,
    })) {
      byName.putIfAbsent(n, () => <String>{}).add(e.key);
      allNames.add((n, e.key));
      for (final String s in _sorted(shortForms(n))) {
        byName.putIfAbsent('~$s', () => <String>{}).add(e.key);
      }
    }
    for (final String n in _set(e.value['weak'])) {
      weakIdx.putIfAbsent(n, () => <String>{}).add(e.key);
      allNames.add((n, e.key));
    }
  }
  Set<String> contains(Set<String> names) => <String>{
    for (final String n in names)
      for (final (String g, String pid) in allNames)
        if (_len(g) >= 2 &&
            _len(n) >= 2 &&
            g != n &&
            (g.contains(n) || n.contains(g)))
          pid,
  };
  final RegExp groups = pyRe(r'夫妇|夫妻|们$|一家|众人|全家|大伙');
  final List<Json> people =
      _rows(local['people']).where((Json q) {
        final String name = q['name'] as String? ?? '';
        return !groups.hasMatch(name) &&
            (strongNames(q).isNotEmpty ||
                !pronouns.contains(
                  PyCompat.strip(_unstar(name)).toLowerCase(),
                ));
      }).toList();
  final Json decisions = <String, Object?>{};
  final List<LinkQuestion> questions = <LinkQuestion>[];
  final List<Json> namedHere =
      people.where((Json q) => strongNames(q).isNotEmpty).toList();
  for (final Json lp in people) {
    final String lid = pyStr(lp['id']);
    final Set<String> strong = strongNames(lp), weak = weakNames(lp);
    final Set<String> exact = <String>{
      for (final String n in strong) ...?byName[n],
    };
    final Set<String> fuzzy = <String>{
      for (final String n in strong) ...?byName['~$n'],
      for (final String n in strong)
        for (final String s in shortForms(n)) ...?byName[s],
    };
    final Set<String> weakC = <String>{
      for (final String n in weak) ...?byName[n],
      for (final String n in <String>{...weak, ...strong}) ...?weakIdx[n],
    };
    final Set<String> near = contains(<String>{...strong, ...weak});
    final List<String> localC = <String>[
      if (strong.isEmpty)
        for (final Json q in namedHere)
          if (!identical(q, lp) && !genderClash(lp, q)) 'L:${pyStr(q['id'])}',
    ];
    String? hint = resolveHint(kg, lp, byName);
    if (!cast.containsKey(hint) || genderClash(lp, cast[hint]!)) hint = null;
    final Set<String> distinct = <String>{
      for (final String n in strong)
        if (byName[n]?.length == 1 && !genderClash(lp, cast[byName[n]!.first]!))
          byName[n]!.first,
    };
    final Set<String> cores = <String>{
      for (final String n in <String>{...strong, ...weak}) core(n),
    }..remove('');
    final Set<String> sameCore = <String>{
      if (cores.isNotEmpty)
        for (final MapEntry<String, Json> e in cast.entries)
          if (cores
                  .intersection(
                    <String>{for (final String n in namesOf(e.value)) core(n)}
                      ..remove(''),
                  )
                  .isNotEmpty &&
              !genderClash(lp, e.value))
            e.key,
    };
    if (distinct.length == 1) {
      decisions[lid] = <String, Object?>{
        'to': distinct.first,
        'how':
            hint == null || distinct.contains(hint) ? 'name' : 'name-over-hint',
      };
    } else if (distinct.length > 1 ||
        hint != null ||
        exact.isNotEmpty ||
        fuzzy.isNotEmpty ||
        weakC.isNotEmpty ||
        near.isNotEmpty ||
        sameCore.isNotEmpty ||
        localC.isNotEmpty) {
      final List<String> pool =
          <String>{
              ...distinct,
              ...exact,
              ...fuzzy,
              ...weakC,
              ...near,
              ...sameCore,
            }.toList()
            ..sort((String a, String b) {
              final int n = (cast[b]!['mentions'] as num? ?? 0).compareTo(
                cast[a]!['mentions'] as num? ?? 0,
              );
              return n != 0 ? n : PyCompat.compare(a, b);
            });
      final List<String> cands =
          <String>{if (hint != null) hint, ...pool}.take(6).toList();
      questions.add((lid, lp, <String>[...cands, ...localC.take(4)]));
    } else {
      decisions[lid] = <String, Object?>{'to': null, 'how': 'new'};
    }
  }
  Json raw = <String, Object?>{};
  if (questions.isNotEmpty) {
    raw = await askJev(
      questions,
      cast,
      contextText,
      localsById: <String, Json>{
        for (final Json q in people) pyStr(q['id']): q,
      },
    );
    for (final (String lid, Json lp, List<String> cands) in questions) {
      final Json r = _obj(raw[lid]);
      final Object? choice = r['choice'];
      final num p = r['p'] as num? ?? 0;
      if (cands.contains(choice) &&
          p >= 0.6 &&
          (choice! as String).startsWith('L:')) {
        decisions[lid] = <String, Object?>{
          'same_as_local': (choice as String).substring(2),
          'how': 'jev-local',
          'p': p,
        };
      } else if (cands.contains(choice) && p >= 0.6) {
        decisions[lid] = <String, Object?>{'to': choice, 'how': 'jev', 'p': p};
      } else if (choice == 'new' && p >= 0.6) {
        decisions[lid] = <String, Object?>{
          'to': null,
          'how': 'jev-new',
          'p': p,
        };
      } else {
        final List<String> exact =
            cands
                .where(
                  (String c) =>
                      cast.containsKey(c) &&
                      strongNames(lp).intersection(<String>{
                        ..._set(cast[c]!['aliases']),
                        cast[c]!['name']! as String,
                      }).isNotEmpty,
                )
                .toList();
        decisions[lid] =
            exact.isNotEmpty
                ? <String, Object?>{'to': exact.first, 'how': 'fallback-name'}
                : <String, Object?>{'to': null, 'how': 'fallback-new'};
      }
    }
  }
  final (Map<String, Set<String>> drop, Json checked) = await verifyNames(
    cast,
    people,
    decisions,
    contextText,
  );
  for (final Object? value in decisions.values) {
    final Json d = value! as Json;
    if (d.containsKey('same_as_local')) {
      d['to'] = _obj(decisions[d['same_as_local']])['to'];
      d['local'] = d['same_as_local'];
    }
  }
  return (
    toClassic(local, decisions, drop: drop, k: kg.k),
    <String, Object?>{'decisions': decisions, 'jev': raw, 'verify': checked},
  );
}

String? resolveHint(KG kg, Json lp, Map<String, Set<String>> byName) {
  final Object? kid = lp['known'], kn = lp['known_name'];
  if (kg.people.containsKey(kid)) {
    final String pid = kg.canon(kid! as String)!;
    if (!_truthy(kn) || namesOf(kg.people[pid]!).contains(kn)) return pid;
  }
  if (_truthy(kn) && byName[kn]?.length == 1) return byName[kn]!.first;
  return null;
}

/// Validate unrelated identity claims and name forms before KG writes.
Future<(Map<String, Set<String>>, Json)> verifyNames(
  Map<String, Json> cast,
  List<Json> people,
  Json decisions,
  String passage,
) async {
  final Map<String, (String, String, String, String)> claims =
      <String, (String, String, String, String)>{};
  final Map<(String, String), String> forms = <(String, String), String>{};
  for (final Json lp in people) {
    final String lid = pyStr(lp['id']);
    final Json d = _obj(decisions[lid]);
    final Set<String> strong = strongNames(lp);
    final String? tgt = cast.containsKey(d['to']) ? d['to']! as String : null;
    final Set<String> base;
    final String who;
    if (tgt != null) {
      final Json t = cast[tgt]!;
      base =
          <String>{
            ..._set(t['aliases']),
            t['name']! as String,
          }.where((String n) => !isGeneric(n)).toSet();
      if (base.isEmpty) base.add(t['name']! as String);
      who = '${properName(t)}（${_bio(t)}）';
      if (((d['how'] as String? ?? '').startsWith('jev') ||
              d['how'] == 'fallback-name') &&
          strong.isNotEmpty &&
          !_sorted(
            strong,
          ).any((String a) => _sorted(base).any((String b) => related(a, b)))) {
        final String name = _unstar(lp['name'] as String? ?? '');
        claims[lid] = (
          name.isNotEmpty ? name : _sorted(strong).first,
          properName(t),
          _truthy(lp['role']) ? lp['role']! as String : '',
          _bio(t),
        );
      }
    } else {
      final String main = _unstar(lp['name'] as String? ?? '');
      base =
          strong.contains(main)
              ? <String>{main}
              : _sorted(strong).take(1).toSet();
      who = '$main（${_role(lp)}）';
    }
    for (final String f in _sorted(strong.difference(base))) {
      final bool taken = cast.entries.any(
        (MapEntry<String, Json> e) =>
            e.key != tgt &&
            <String>{
              ..._set(e.value['aliases']),
              e.value['name']! as String,
            }.contains(f),
      );
      if (taken || !_sorted(base).any((String b) => related(f, b)))
        forms[(lid, f)] = who;
    }
  }
  if (claims.isEmpty && forms.isEmpty)
    return (<String, Set<String>>{}, <String, Object?>{});
  final Json qs = <String, Object?>{};
  final Map<String, (String, String, String?)> keys =
      <String, (String, String, String?)>{};
  for (final MapEntry<String, (String, String, String, String)> e
      in claims.entries) {
    final String key = 'c${qs.length + 1}';
    keys[key] = ('claim', e.key, null);
    final (String a, String b, String da, String db) = e.value;
    qs[key] = <String, Object?>{
      'type': 'choice',
      'instructions': sameQuestion(a, b, da, db),
      'criteria': <String, Object?>{
        'same':
            'The passage makes clear these two names refer to one and the same person.',
        'different':
            'They are different people (relatives, colleagues, two people with similar titles or names).',
        'unclear': 'The passage does not establish it.',
      },
    };
  }
  for (final MapEntry<(String, String), String> e in forms.entries) {
    final String key = 'a${qs.length + 1}', f = e.key.$2;
    keys[key] = ('form', e.key.$1, f);
    qs[key] = <String, Object?>{
      'type': 'choice',
      'instructions':
          'In this_passage, is the name 「$f」 used to refer to the character ${e.value}?',
      'criteria': <String, Object?>{
        'yes':
            'Yes — in this passage 「$f」 is a name/nickname/title used for this very character.',
        'no':
            'No — 「$f」 is someone else (e.g. a person being talked about or addressed), or is not used for this character here.',
      },
    };
  }
  final Json ans = <String, Object?>{};
  final List<String> ids = qs.keys.toList();
  for (int k0 = 0; k0 < ids.length; k0 += batch) {
    ans.addAll(
      await linkCall(
        <String, Object?>{'this_passage': PyCompat.slice(passage, 0, 12000)},
        <String, Object?>{
          for (final String key in ids.skip(k0).take(batch)) key: qs[key],
        },
      ),
    );
  }
  final Map<String, Set<String>> drop = <String, Set<String>>{};
  final Json record = <String, Object?>{};
  for (final MapEntry<String, (String, String, String?)> e in keys.entries) {
    final Json probs = _obj(_obj(ans[e.key])['probabilities']);
    final (String kind, String lid, String? form) = e.value;
    if (kind == 'claim') {
      final num p = pyRound(_get(probs, 'same', 0), 3);
      record['claim:$lid'] = p;
      if (p < 0.7)
        decisions[lid] = <String, Object?>{
          'to': null,
          'how': 'unconfirmed-new',
          'was': _obj(decisions[lid])['to'],
          'p': p,
        };
    } else {
      final num p = pyRound(_get(probs, 'yes', 0), 3);
      record['form:$lid:$form'] = p;
      if (p < 0.5) drop.putIfAbsent(lid, () => <String>{}).add(form!);
    }
  }
  return (drop, record);
}

bool genderClash(Json lp, Json gp) =>
    <String>{'男', '女'}.contains(lp['gender']) &&
    <String>{'男', '女'}.contains(gp['gender']) &&
    lp['gender'] != gp['gender'];

Future<Json> askJev(
  List<LinkQuestion> questions,
  Map<String, Json> cast,
  String contextText, {
  Map<String, Json>? localsById,
}) async {
  final Json out = <String, Object?>{};
  String desc(String c) {
    if (c.startsWith('L:')) {
      final Json q = localsById?[c.substring(2)] ?? <String, Object?>{};
      return '本段中的「${pyStr(_get(q, 'name'))}」：${_role(q)}（same person as this one）';
    }
    final Json p = cast[c]!;
    final String names = _sorted(
      <String>{..._set(p['aliases']), ..._set(p['weak'])}..remove(p['name']),
    ).take(8).join('、');
    return '${p['name']}（又称：${names.isEmpty ? '无' : names}）：${_bio(p)}';
  }

  for (int k0 = 0; k0 < questions.length; k0 += batch) {
    final List<LinkQuestion> chunk = questions.skip(k0).take(batch).toList();
    final Json characters = <String, Object?>{
      for (final LinkQuestion q in chunk)
        for (final String c in q.$3) c: desc(c),
    };
    final Json state = <String, Object?>{
      'this_passage': PyCompat.slice(contextText, 0, 12000),
      'known_characters': characters,
    };
    final Json qs = <String, Object?>{};
    for (int n = 1; n <= chunk.length; n++) {
      final (_, Json lp, List<String> cands) = chunk[n - 1];
      final String names = _sorted(<String>{
        ...strongNames(lp),
        ...weakNames(lp),
      }).join('、');
      qs['q$n'] = <String, Object?>{
        'type': 'choice',
        'instructions':
            'In this_passage a character is called 「${names.isEmpty ? pyStr(_get(lp, 'name')) : names}」 '
            '(described in the passage as: ${_role(lp)}). '
            'Which already-known character is this, if any? Decide from this_passage and the known characters only.',
        'criteria': <String, Object?>{
          for (final String pid in cands) pid: characters[pid],
          'new':
              'Someone else: a character not among these (new to the story, or a different person who shares a title/name).',
        },
      };
    }
    final Json ans = await linkCall(state, qs);
    for (int n = 1; n <= chunk.length; n++) {
      final Json a = _obj(ans['q$n']),
          probs = _obj(_obj(ans['q$n'])['probabilities']);
      out[chunk[n - 1].$1] = <String, Object?>{
        'choice': a['choice'],
        'p': pyRound(
          probs.containsKey(a['choice']) ? probs[a['choice']] : 0,
          3,
        ),
      };
    }
  }
  return out;
}

/// Convert local extraction and decisions to the schema KG.plan/commit accept.
Json toClassic(
  Json local,
  Json decisions, {
  Map<String, Set<String>>? drop,
  int k = 1,
}) {
  final Map<String, String> ref = <String, String>{};
  final List<Json> newPeople = <Json>[], profiles = <Json>[];
  final Map<String, List<String>> surfaces = <String, List<String>>{};
  final List<Json> people = _rows(local['people']);
  final List<Json> order = <Json>[
    ...people.where(
      (Json q) => !_obj(decisions[pyStr(q['id'])]).containsKey('local'),
    ),
    ...people.where(
      (Json q) => _obj(decisions[pyStr(q['id'])]).containsKey('local'),
    ),
  ];
  for (final Json lp in order) {
    final String lid = pyStr(lp['id']);
    final Json d = _obj(decisions[lid]);
    if (_truthy(d['to'])) {
      ref[lid] = d['to']! as String;
    } else if (_truthy(d['local']) && ref.containsKey(d['local'])) {
      ref[lid] = ref[d['local']]!;
    } else {
      ref[lid] = 'N$lid';
      final Set<String> strong = strongNames(lp);
      final String fallback = (lp['names'] as List<Object?>? ?? <Object?>[])
          .whereType<String>()
          .map((String n) => PyCompat.strip(_unstar(n)))
          .firstWhere(strong.contains, orElse: () => '无名氏');
      newPeople.add(<String, Object?>{
        'ref': ref[lid],
        'name': _unstar(_truthy(lp['name']) ? lp['name']! as String : fallback),
        'gender': lp['gender'],
        'importance': 2,
        'para': lp['para'],
        'quote': lp['quote'],
        'intro': _truthy(lp['role']) ? lp['role'] : '',
      });
      if (_truthy(lp['role']))
        profiles.add(<String, Object?>{
          'who': ref[lid],
          'tagline': PyCompat.slice(lp['role']! as String, 0, 24 * k),
          'bio': '',
          'para': lp['para'],
          'evidence_scope': 'segment',
        });
    }
    final List<String> forms = <String>[
      for (final Object? n in _rawNames(lp))
        if (n is String &&
            PyCompat.strip(n, chars: '*').isNotEmpty &&
            !(drop?[lid]?.contains(PyCompat.strip(_unstar(n))) ?? false))
          '${isGeneric(n) ? '*' : ''}${_unstar(n)}',
    ];
    final List<String> target = surfaces.putIfAbsent(
      ref[lid]!,
      () => <String>[],
    );
    // Python builds the entire extension before +=, preserving duplicates in it.
    target.addAll(forms.where((String f) => !target.contains(f)).toList());
  }
  final List<Json> merges = <Json>[];
  for (final Json s in _rows(local['same'])) {
    final String? a = ref[pyStr(s['a'])], b = ref[pyStr(s['b'])];
    if (a != null && b != null && a != b)
      merges.add(<String, Object?>{
        'from': a,
        'into': b,
        'para': s['para'],
        'quote': s['quote'],
        'reason': _get(s, 'why'),
      });
  }
  String? m(Object? x) => ref[pyStr(x)];
  return <String, Object?>{
    'new_people': newPeople,
    'surfaces': surfaces,
    'aliases': <Object?>[],
    'merges': merges,
    'events': <Json>[
      for (final Json e in _rows(local['events']))
        <String, Object?>{
          ...e,
          'who': <String>[
            for (final Object? w in e['who'] as List<Object?>? ?? <Object?>[])
              if (m(w) != null) m(w)!,
          ],
          'importance': _get(e, 'imp', 1),
        },
    ],
    'attrs': <Json>[
      for (final Json f in _rows(local['facts']))
        if (m(f['who']) != null) <String, Object?>{...f, 'who': m(f['who'])},
    ],
    'rels': <Json>[
      for (final Json r in _rows(local['rels']))
        if (m(r['a']) != null && m(r['b']) != null)
          <String, Object?>{
            ...r,
            'a': m(r['a']),
            'b': m(r['b']),
            'status':
                <String>{'new', 'changed', 'ended'}.contains(r['status'])
                    ? r['status']
                    : 'new',
          },
    ],
    'profiles': profiles,
  };
}
