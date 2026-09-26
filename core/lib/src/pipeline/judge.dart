/// Jev decision jobs (`pipeline/judge.py`): ambiguous mentions, guards,
/// record verification, relation trees, importance, spoiler titles.
library;

import 'dart:async';

import '../errors.dart';
import '../py/py_compat.dart';
import '../py/py_re.dart';
import 'jev.dart';
import 'judge_tables.dart' as t;
import 'llm.dart';

typedef Json = Map<String, Object?>;

const int batch = 48;

/// The judge callable; tests swap it for a recorded one.
Future<Json> Function(Object? state, Json questions) judgeCall =
    (Object? s, Json q) => jev(s, q);

int _cp(String s) => s.runes.length;

String boundedPassage(String passage) {
  if (_cp(passage) > 12000) {
    throw const LLMError('原文段落超过核对上下文上限，已暂停；请先拆分长段落，不能截断证据后继续判断');
  }
  return passage;
}

final RegExp _sentenceEnd = pyRe('[。！？!?…」”]');

/// Passage around text[i:j] (code points) with the mention in 【】.
String context(String text, int i, int j, {int before = 200, int after = 80}) {
  final List<int> r = text.runes.toList();
  String sub(int a, int b) => String.fromCharCodes(r.sublist(a, b));
  final int a = i - before > 0 ? i - before : 0;
  int b = j + after < r.length ? j + after : r.length;
  final RegExpMatch? m = pySearch(_sentenceEnd, sub(j, b < j ? j : b));
  if (m != null) b = j + _cp(sub(j, b).substring(0, m.end));
  return '${sub(a, i)}【${sub(i, j)}】${sub(j, b < j ? j : b)}';
}

Json _obj(Object? v) => v is Json ? v : <String, Object?>{};

bool _truthy(Object? v) =>
    v != null &&
    v != false &&
    v != 0 &&
    v != '' &&
    !(v is Json && v.isEmpty) &&
    !(v is List<Object?> && v.isEmpty);

Json _answer(Json answers, String key) {
  final Object? a = answers[key];
  return _truthy(a) ? a! as Json : <String, Object?>{};
}

Json _probs(Json a) {
  final Object? p = a['probabilities'];
  return _truthy(p) ? p! as Json : <String, Object?>{};
}

Object? _get(Json m, Object? k, [Object? d = 0]) => m.containsKey(k) ? m[k] : d;

/// Runs [jobs] at most [n] at a time, keeping result order (ThreadPoolExecutor.map).
Future<List<T>> poolMap<S, T>(
  int n,
  List<S> items,
  Future<T> Function(S) f,
) async {
  final List<T?> out = List<T?>.filled(items.length, null);
  int next = 0;
  Future<void> worker() async {
    while (next < items.length) {
      final int i = next++;
      out[i] = await f(items[i]);
    }
  }

  await Future.wait(<Future<void>>[
    for (int w = 0; w < n && w < items.length; w++) worker(),
  ]);
  return out.cast<T>();
}

/// Decide ambiguous occurrences: ({key: id|null}, raw answers).
Future<(Json, Json)> resolveMentions(
  Json book,
  Json seg,
  List<Json> occs,
  String Function(String) describe,
) async {
  final List<Json> todo =
      occs.where((Json o) => o['ambiguous'] == true).toList();
  if (todo.isEmpty) return (<String, Object?>{}, <String, Object?>{});
  final StringBuffer segText = StringBuffer();
  final Map<int, int> offsets = <int, int>{};
  final List<Object?> blocks = book['blocks']! as List<Object?>;
  for (final int bi in (seg['blocks']! as List<Object?>).cast<int>()) {
    offsets[bi] = _cp(segText.toString());
    segText
      ..write((blocks[bi]! as Json)['t'])
      ..write('\n');
  }
  final String text = segText.toString();
  final List<List<Json>> batches = <List<Json>>[
    for (int k = 0; k < todo.length; k += batch)
      todo.sublist(k, k + batch < todo.length ? k + batch : todo.length),
  ];
  Future<Json> run(List<Json> part) async {
    final List<String> ids =
        <String>{
            for (final Json o in part)
              for (final Object? x in o['ids']! as List<Object?>) x! as String,
          }.toList()
          ..sort();
    final Json state = <String, Object?>{
      'characters': <String, Object?>{
        for (final String pid in ids) pid: describe(pid),
      },
      'passages': <String, Object?>{},
    };
    final Json questions = <String, Object?>{};
    for (int n = 1; n <= part.length; n++) {
      final Json o = part[n - 1];
      final String qid = 'q$n';
      final int base = offsets[o['bi']! as int]!;
      (state['passages']! as Json)[qid] = context(
        text,
        base + (o['i']! as int),
        base + (o['j']! as int),
      );
      final Json criteria = <String, Object?>{
        for (final Object? pid in o['ids']! as List<Object?>)
          pid! as String: describe(pid as String),
      };
      criteria['none'] =
          'None of the listed characters: another person, a group, or the word is used generically / not as a reference to a specific character.';
      questions[qid] = <String, Object?>{
        'type': 'choice',
        'instructions':
            'Passage $qid is from a Chinese novel. Which character does the marked mention '
            '【${o['surface']}】 refer to in passage $qid? Decide from the passage and the '
            'character descriptions only.',
        'criteria': criteria,
      };
    }
    final Json answers = await judgeCall(state, questions);
    final Json out = <String, Object?>{};
    for (int n = 1; n <= part.length; n++) {
      final Json o = part[n - 1];
      final Json a = _answer(answers, 'q$n');
      final Json probs = _probs(a);
      final Object? choice = a['choice'];
      out[o['key']! as String] = <String, Object?>{
        'choice': choice,
        'p': pyRound(_get(probs, choice), 3),
        'surface': o['surface'],
      };
    }
    return out;
  }

  final Json raw = <String, Object?>{};
  for (final Json part in await poolMap(4, batches, run)) {
    raw.addAll(part);
  }
  final Json decisions = <String, Object?>{};
  for (final Json o in todo) {
    final Json r = _obj(raw[o['key']]);
    final bool ok =
        (o['ids']! as List<Object?>).contains(r['choice']) &&
        ((_get(r, 'p')! as num) >= 0.55);
    decisions[o['key']! as String] = ok ? r['choice'] : null;
  }
  return (decisions, raw);
}

Json _criteriaOf(Map<String, Object?> table, int index) => <String, Object?>{
  for (final MapEntry<String, Object?> e in table.entries)
    e.key: (e.value! as List<Object?>)[index],
};

/// Is each generated text established by the passage and earlier notes?
Future<Json> guardTexts(String passage, Json earlier, Json items) async {
  if (items.isEmpty) return <String, Object?>{};
  final Json out = <String, Object?>{};
  final List<String> keys = items.keys.toList();
  for (int k0 = 0; k0 < keys.length; k0 += batch) {
    final List<String> chunk = keys.sublist(
      k0,
      k0 + batch < keys.length ? k0 + batch : keys.length,
    );
    final Json state = <String, Object?>{
      'passage_read_so_far': passage,
      'earlier_notes': earlier,
    };
    final Json questions = <String, Object?>{};
    for (int n = 1; n <= chunk.length; n++) {
      final String noteKey = 'note_g$n';
      state[noteKey] = items[chunk[n - 1]];
      questions['g$n'] = <String, Object?>{
        'type': 'choice',
        'instructions':
            'A spoiler-free reading companion wrote the note below about a novel. The reader has read only '
            'passage_read_so_far (plus what earlier_notes summarise). Judge $noteKey as a claim, '
            'not as evidence. Only passage_read_so_far and earlier_notes can support it.',
        'criteria': <String, Object?>{
          'supported':
              'Every claim in the note is stated in, or directly follows from, the passage or the earlier notes.',
          'beyond_text':
              'The note asserts something (an event, identity, relationship, fate or later development) that the passage and earlier notes do not establish.',
          'contradicted': 'The note contradicts the passage.',
        },
      };
    }
    final Json answers = await judgeCall(state, questions);
    for (int n = 1; n <= chunk.length; n++) {
      final Json a = _answer(answers, 'g$n');
      final Json probs = _probs(a);
      final num bad =
          (_get(probs, 'beyond_text')! as num) +
          (_get(probs, 'contradicted')! as num);
      out[chunk[n - 1]] = <String, Object?>{
        'verdict': bad >= 0.6 ? 'flag' : 'ok',
        'p': pyRound(_get(probs, 'supported'), 3),
        'choice': a['choice'],
      };
    }
  }
  return out;
}

Json _roundAll(Json probs) => <String, Object?>{
  for (final MapEntry<String, Object?> e in probs.entries)
    e.key: pyRound(e.value, 3),
};

/// facts: {key: (name, who_they_are, attribute, value)}.
Future<Json> checkFacts(String passage, Map<String, List<String>> facts) async {
  if (facts.isEmpty) return <String, Object?>{};
  final Json out = <String, Object?>{};
  final List<String> keys = facts.keys.toList();
  for (int k0 = 0; k0 < keys.length; k0 += batch) {
    final List<String> chunk = keys.sublist(
      k0,
      k0 + batch < keys.length ? k0 + batch : keys.length,
    );
    final Json state = <String, Object?>{
      'passage_read_so_far': passage,
      'characters': <String, Object?>{
        for (int n = 1; n <= chunk.length; n++)
          'c$n': '${facts[chunk[n - 1]]![0]}: ${facts[chunk[n - 1]]![1]}',
      },
    };
    final Json questions = <String, Object?>{};
    for (int n = 1; n <= chunk.length; n++) {
      final List<String> f = facts[chunk[n - 1]]!;
      questions['f$n'] = <String, Object?>{
        'type': 'choice',
        'instructions':
            'Character c$n ("${f[0]}", see characters.c$n only to know WHO is meant; do not judge that '
            'description). Claimed attribute of this character — ${f[2]}: ${f[3]}. '
            'Judge only this attribute against passage_read_so_far.',
        'criteria': <String, Object?>{
          'supported':
              'The passage states or clearly implies this about this character.',
          'not_in_passage':
              'The passage does not establish this about this character (it may come from outside knowledge or be about someone else).',
          'contradicted': 'The passage contradicts it.',
        },
      };
    }
    final Json answers = await judgeCall(state, questions);
    for (int n = 1; n <= chunk.length; n++) {
      final Json a = _answer(answers, 'f$n');
      final Json probs = _probs(a);
      out[chunk[n - 1]] = <String, Object?>{
        'p': pyRound(_get(probs, 'supported'), 3),
        'choice': a['choice'],
        'probs': _roundAll(probs),
      };
    }
  }
  return out;
}

String label(String key, String lang) {
  final List<Map<String, Object?>> tables = <Map<String, Object?>>[
    for (final Object? v in t.leaves.values) v! as Map<String, Object?>,
    for (final Object? v in t.conceptLeaves.values) v! as Map<String, Object?>,
    t.stance,
    t.state,
  ];
  for (final Map<String, Object?> table in tables) {
    if (table.containsKey(key))
      return (table[key]! as List<Object?>)[lang != 'en' ? 0 : 1]! as String;
  }
  return '';
}

(Map<String, Object?>, Map<String, Object?>, Map<String, Object?>) trees([
  String kind = 'novel',
]) =>
    kind == 'concept'
        ? (t.conceptFamilies, t.conceptLeaves, t.conceptInverse)
        : (t.families, t.leaves, t.inverse);

String _name(Json names, String k) => names.containsKey(k) ? '${names[k]}' : k;

Json familyQuestions(
  List<(String, String)> pairs,
  Json names, {
  String kind = 'novel',
  bool hasContext = false,
}) {
  final Map<String, Object?> fams = trees(kind).$1;
  final String what =
      kind == 'concept'
          ? 'what kind of link is there between'
          : 'what kind of tie is there between';
  final String note =
      hasContext
          ? ' Use character_context, previous_passage_tail, and story_before_this_passage only to identify the people and understand their '
              'already-known situation; the tie must still be established or actively continued in this_passage.'
          : '';
  return <String, Object?>{
    for (int n = 1; n <= pairs.length; n++)
      'f$n': <String, Object?>{
        'type': 'choice',
        'instructions':
            'In this_passage, $what 「${_name(names, pairs[n - 1].$1)}」 (A) and 「${_name(names, pairs[n - 1].$2)}」 (B)?$note',
        'criteria': _criteriaOf(fams, 2),
      },
  };
}

/// {pair: [(family, p) up to two]}.
Map<(String, String), List<(String, num)>> readFamilies(
  Json ans,
  List<(String, String)> pairs,
) {
  final Map<(String, String), List<(String, num)>> out =
      <(String, String), List<(String, num)>>{};
  for (int n = 1; n <= pairs.length; n++) {
    final Json probs = _probs(_answer(ans, 'f$n'));
    final List<MapEntry<String, Object?>> sorted = PyCompat.stableSorted(
      probs.entries,
      key: (MapEntry<String, Object?> x) => -(x.value! as num),
    );
    out[pairs[n - 1]] =
        <(String, num)>[
          for (final MapEntry<String, Object?> e in sorted)
            if (e.key != 'none' && (e.value! as num) >= 0.35)
              (e.key, pyRound(e.value, 3)),
        ].take(2).toList();
  }
  return out;
}

Json relationState(String passage, [Json? ctx]) {
  final Json state = <String, Object?>{'this_passage': boundedPassage(passage)};
  if (ctx != null) {
    for (final String key in const <String>[
      'story_before_this_passage',
      'previous_passage_tail',
      'character_context',
    ]) {
      if (_truthy(ctx[key])) state[key] = ctx[key];
    }
  }
  return state;
}

Json recordQuestions(Map<String, (String, String)> items) {
  final Json qs = <String, Object?>{};
  for (final MapEntry<String, (String, String)> e in items.entries) {
    final String what =
        const <String, String>{
          'event': 'this event happens in this_passage',
          'attr': 'this_passage says this about the character',
          'rel': 'this_passage establishes this relationship',
        }[e.value.$1]!;
    qs['v_${e.key}'] = <String, Object?>{
      'type': 'choice',
      'instructions': 'Judging only this_passage: $what? CLAIM: ${e.value.$2}',
      'criteria': <String, Object?>{
        'supported':
            'The passage states it, shows it happening, or clearly implies it.',
        'not_in_passage':
            'The passage does not establish this — it may be outside knowledge, a guess, or about someone else.',
        'contradicted': 'The passage says otherwise.',
      },
    };
  }
  return qs;
}

Json readRecords(Json ans, Iterable<String> items) {
  final Json out = <String, Object?>{};
  for (final String k in items) {
    final Json a = _answer(ans, 'v_$k');
    final Json probs = _probs(a);
    out[k] = <String, Object?>{
      'p': pyRound(_get(probs, 'supported'), 3),
      'choice': a['choice'],
      'probs': _roundAll(probs),
    };
  }
  return out;
}

Future<(Json, Map<(String, String), List<(String, num)>>)> checkAndFamilies(
  String passage,
  Map<String, (String, String)> items,
  List<(String, String)> pairs,
  Json names, {
  String kind = 'novel',
  Json? ctx,
}) async {
  final Json qs = recordQuestions(items)..addAll(
    familyQuestions(
      pairs,
      names,
      kind: kind,
      hasContext: ctx != null && _truthy(ctx),
    ),
  );
  final Json ans = <String, Object?>{};
  final List<String> keys = qs.keys.toList();
  for (int k0 = 0; k0 < keys.length; k0 += batch) {
    final List<String> part = keys.sublist(
      k0,
      k0 + batch < keys.length ? k0 + batch : keys.length,
    );
    ans.addAll(
      await judgeCall(relationState(passage, ctx), <String, Object?>{
        for (final String k in part) k: qs[k],
      }),
    );
  }
  return (readRecords(ans, items.keys), readFamilies(ans, pairs));
}

const Set<String> _faceted = <String>{
  'kin',
  'marriage',
  'romance',
  'power',
  'grace',
  'conflict',
};

/// Tie family → exact role → how they stand.
Future<Map<(String, String), Json>> relationsByJudge(
  String passage,
  List<(String, String)> pairs,
  Json names, {
  Map<(String, String), List<(String, num)>>? fam,
  String kind = 'novel',
  Json? ctx,
}) async {
  final (Map<String, Object?> fams, Map<String, Object?> leaves, _) = trees(
    kind,
  );
  final bool hasCtx = ctx != null && _truthy(ctx);
  Map<(String, String), List<(String, num)>> families =
      fam ?? <(String, String), List<(String, num)>>{};
  if (fam == null) {
    families = <(String, String), List<(String, num)>>{};
    for (int k0 = 0; k0 < pairs.length; k0 += batch) {
      final List<(String, String)> chunk = pairs.sublist(
        k0,
        k0 + batch < pairs.length ? k0 + batch : pairs.length,
      );
      families.addAll(
        readFamilies(
          await judgeCall(
            relationState(passage, ctx),
            familyQuestions(chunk, names, kind: kind, hasContext: hasCtx),
          ),
          chunk,
        ),
      );
    }
  }
  final List<((String, String), String, num)> jobs =
      <((String, String), String, num)>[
        for (final MapEntry<(String, String), List<(String, num)>> e
            in families.entries)
          for (final (String f, num p) in e.value) (e.key, f, p),
      ];
  final Map<(String, String), Json> out = <(String, String), Json>{
    for (final (String, String) pr in pairs)
      pr: <String, Object?>{'ties': <Object?>[], 'stance': null, 'state': null},
  };
  for (int k0 = 0; k0 < jobs.length; k0 += batch) {
    final List<((String, String), String, num)> chunk = jobs.sublist(
      k0,
      k0 + batch < jobs.length ? k0 + batch : jobs.length,
    );
    final Json qs = <String, Object?>{};
    for (int n = 1; n <= chunk.length; n++) {
      final ((String a, String b), String f, _) = chunk[n - 1];
      final Json crit = <String, Object?>{
        for (final MapEntry<String, Object?> e
            in (leaves[f]! as Map<String, Object?>).entries)
          e.key:
              kind == 'concept'
                  ? 'B is ${(e.value! as List<Object?>)[1]}'
                  : "B is A's ${(e.value! as List<Object?>)[1]}",
      };
      final String famName = (fams[f]! as List<Object?>)[1]! as String;
      crit['other'] = 'They have a $famName link, but none of these fits';
      qs['l$n'] = <String, Object?>{
        'type': 'choice',
        'instructions':
            'In this_passage, 「${_name(names, b)}」 (B) and 「${_name(names, a)}」 (A) have a '
            '$famName link. What exactly is B to A?',
        'criteria': crit,
      };
    }
    final Json ans = await judgeCall(relationState(passage, ctx), qs);
    for (int n = 1; n <= chunk.length; n++) {
      final ((String, String) pr, String f, num fp) = chunk[n - 1];
      final Json x = _answer(ans, 'l$n');
      final Object? role = x['choice'];
      final num p = pyRound(_get(_probs(x), role), 3);
      if (_truthy(role) && p >= 0.5 && fp * p >= 0.35) {
        (out[pr]!['ties']! as List<Object?>).add(<String, Object?>{
          'family': f,
          'role': role,
          'p': p,
          'family_p': fp,
        });
      }
    }
  }
  final List<(String, String)> live =
      kind == 'concept'
          ? <(String, String)>[]
          : <(String, String)>[
            for (final MapEntry<(String, String), Json> e in out.entries)
              if ((e.value['ties']! as List<Object?>).any(
                (Object? t0) => _faceted.contains((t0! as Json)['family']),
              ))
                e.key,
          ];
  const int half = batch ~/ 2;
  for (int k0 = 0; k0 < live.length; k0 += half) {
    final List<(String, String)> chunk = live.sublist(
      k0,
      k0 + half < live.length ? k0 + half : live.length,
    );
    final Json qs = <String, Object?>{};
    for (int n = 1; n <= chunk.length; n++) {
      final (String a, String b) = chunk[n - 1];
      qs['s$n'] = <String, Object?>{
        'type': 'choice',
        'instructions':
            'In this_passage, how do 「${_name(names, a)}」 and 「${_name(names, b)}」 stand towards each other?',
        'criteria': _criteriaOf(t.stance, 2),
      };
      qs['t$n'] = <String, Object?>{
        'type': 'choice',
        'instructions':
            'In this_passage, does the tie between 「${_name(names, a)}」 and 「${_name(names, b)}」 still hold, and is it open?',
        'criteria': _criteriaOf(t.state, 2),
      };
    }
    final Json ans = await judgeCall(relationState(passage, ctx), qs);
    for (int n = 1; n <= chunk.length; n++) {
      final (String, String) pr = chunk[n - 1];
      for (final (String tag, Map<String, Object?> table, String key)
          in <(String, Map<String, Object?>, String)>[
            ('s', t.stance, 'stance'),
            ('t', t.state, 'state'),
          ]) {
        final Json x = _answer(ans, '$tag$n');
        final num p = pyRound(_get(_probs(x), x['choice']), 3);
        if (table.containsKey(x['choice']) && p >= 0.5)
          out[pr]![key] = <Object?>[x['choice'], p];
      }
    }
  }
  return <(String, String), Json>{
    for (final MapEntry<(String, String), Json> e in out.entries)
      if ((e.value['ties']! as List<Object?>).isNotEmpty) e.key: e.value,
  };
}

Future<Json> verifyRecords(
  String passage,
  Map<String, (String, String)> items,
) async {
  final Json qs = recordQuestions(items);
  final List<String> keys = qs.keys.toList();
  final Json ans = <String, Object?>{};
  for (int k0 = 0; k0 < keys.length; k0 += batch) {
    final List<String> part = keys.sublist(
      k0,
      k0 + batch < keys.length ? k0 + batch : keys.length,
    );
    ans.addAll(
      await judgeCall(
        <String, Object?>{'this_passage': boundedPassage(passage)},
        <String, Object?>{for (final String k in part) k: qs[k]},
      ),
    );
  }
  return readRecords(ans, items.keys);
}

/// How much each person or idea matters so far: {id: 1|2|3}.
Future<Map<String, int>> importanceOf(
  Map<String, String> dossiers, {
  bool concept = false,
}) async {
  final Map<String, int> out = <String, int>{};
  final List<String> keys = dossiers.keys.toList();
  final String what = concept ? 'idea or term' : 'character';
  for (int k0 = 0; k0 < keys.length; k0 += batch) {
    final List<String> chunk = keys.sublist(
      k0,
      k0 + batch < keys.length ? k0 + batch : keys.length,
    );
    final Json qs = <String, Object?>{
      for (int n = 1; n <= chunk.length; n++)
        'i$n': <String, Object?>{
          'type': 'choice',
          'instructions':
              'In the book so far, how much does this $what matter?\n${dossiers[chunk[n - 1]]}',
          'criteria': _criteriaOf(t.importance, 1),
        },
    };
    final Json ans;
    try {
      ans = await judgeCall(<String, Object?>{
        'note': 'Judge only from what is given about each $what.',
      }, qs);
    } on Object {
      break;
    }
    for (int n = 1; n <= chunk.length; n++) {
      final Json a = _answer(ans, 'i$n');
      if (t.importance.containsKey(a['choice']))
        out[chunk[n - 1]] =
            (t.importance[a['choice']]! as List<Object?>)[0]! as int;
    }
  }
  return out;
}

/// Which of several recorded values for one attribute still holds.
Future<Json> currentValue(
  Map<String, (String, String, List<String>)> items,
) async {
  final Json out = <String, Object?>{};
  final List<String> keys = items.keys.toList();
  for (int k0 = 0; k0 < keys.length; k0 += batch) {
    final List<String> chunk = keys.sublist(
      k0,
      k0 + batch < keys.length ? k0 + batch : keys.length,
    );
    final Json qs = <String, Object?>{};
    for (int n = 1; n <= chunk.length; n++) {
      final (String who, String attr, List<String> values) =
          items[chunk[n - 1]]!;
      final Json crit = <String, Object?>{
        for (int i = 0; i < values.length; i++) 'v$i': values[i],
      };
      crit['both'] = 'Both still hold — they are not in conflict.';
      qs['c$n'] = <String, Object?>{
        'type': 'choice',
        'instructions':
            'The book has said these things about 「$who」 — $attr — in this order '
            '(earliest first). Which one describes the situation as it stands now?',
        'criteria': crit,
      };
    }
    final Json ans;
    try {
      ans = await judgeCall(<String, Object?>{
        'note': 'Judge only from the statements given.',
      }, qs);
    } on Object {
      break;
    }
    for (int n = 1; n <= chunk.length; n++) {
      final Json a = _answer(ans, 'c$n');
      final Object? choice = a['choice'];
      final num p = _get(_probs(a), choice)! as num;
      if (choice is String &&
          choice.isNotEmpty &&
          choice.startsWith('v') &&
          p >= 0.6) {
        out[chunk[n - 1]] =
            items[chunk[n - 1]]!.$3[int.parse(choice.substring(1))];
      }
    }
  }
  return out;
}

/// Which chapter titles give away what happens in that chapter.
Future<List<bool>> titleSpoilers(
  List<String> titles, [
  String bookTitle = '',
]) async {
  final List<bool> out = List<bool>.filled(titles.length, true);
  for (int k0 = 0; k0 < titles.length; k0 += batch) {
    final List<int> chunk = <int>[
      for (
        int i = k0;
        i < (k0 + batch < titles.length ? k0 + batch : titles.length);
        i++
      )
        i,
    ];
    final Json qs = <String, Object?>{
      for (final int i in chunk)
        't$i': <String, Object?>{
          'type': 'choice',
          'instructions':
              'A chapter of the novel 《$bookTitle》 is called 「${titles[i]}」. The reader has not read '
              'this chapter yet. Does the title itself give away what happens in it?',
          'criteria': <String, Object?>{
            'spoils':
                'Yes — it states an outcome: someone dies or is killed, a marriage or birth happens, a secret '
                'or true identity is revealed, someone wins, loses, is caught, betrayed or rescued.',
            'safe':
                'No — it only names a place, a person, an object, a scene or a vague hint, or is just a number.',
          },
        },
    };
    final Json ans;
    try {
      ans = await judgeCall(<String, Object?>{
        'note': 'Judge only the title text.',
      }, qs);
    } on Object {
      continue;
    }
    for (final int i in chunk) {
      out[i] = (_get(_probs(_answer(ans, 't$i')), 'spoils', 1)! as num) >= 0.5;
    }
  }
  return out;
}

final RegExp critical = pyRe(
  r'死|去世|身亡|亡故|病故|病逝|殁|薨|夭|自尽|自刎|投井|上吊|吞金|咽气|气绝|过世|归天|殒|丧命|遇害|被杀|'
  r'娶|嫁|成亲|成婚|完婚|拜堂|过门|纳妾|二房|订婚|定亲|婚配|'
  r'凶手|元凶|主谋|幕后|行凶|刺杀|暗杀|下毒|毒杀|陷害|嫁祸|'
  r'\b(?:attacker|assailant|culprit|murderer|killer|poisoner|poisoned|framed|behind the attack)\b|'
  r'\b(?:die[sd]?|dying|dead|death|killed|murder(?:ed)?|drown(?:s|ed)|suicide|hanged|executed|perish(?:ed|es)|'
  r'marr(?:y|ies|ied)|wedding|wed|widow(?:ed)?|engaged|betrothed)\b',
  ignoreCase: true,
);

/// Deaths and marriages must be narrated as having happened.
Future<Json> checkCritical(String passage, Json items) async {
  final Json out = <String, Object?>{};
  final List<String> keys = items.keys.toList();
  for (int k0 = 0; k0 < keys.length; k0 += batch) {
    final List<String> chunk = keys.sublist(
      k0,
      k0 + batch < keys.length ? k0 + batch : keys.length,
    );
    final Json qs = <String, Object?>{};
    for (int n = 1; n <= chunk.length; n++) {
      qs['c$n'] = <String, Object?>{
        'type': 'choice',
        'instructions':
            'Statement about a Chinese novel: 「${items[chunk[n - 1]]}」. According to this_passage only, how is this presented?',
        'criteria': <String, Object?>{
          'fact':
              'The passage narrates it as something that actually happened / is actually the case in the story.',
          'not_real':
              'Only a rumour, misreport, suspicion, fear, dream, vision, prophecy, joke, curse, threat, plan, proposal or wish — the passage does not establish that it actually happened.',
          'unsupported':
              'The passage does not say this at all, or says the opposite.',
        },
      };
    }
    final Json ans = await judgeCall(<String, Object?>{
      'this_passage': passage,
    }, qs);
    for (int n = 1; n <= chunk.length; n++) {
      final Json a = _answer(ans, 'c$n');
      final Json probs = _probs(a);
      out[chunk[n - 1]] = <String, Object?>{
        'fact': pyRound(_get(probs, 'fact'), 3),
        'choice': a['choice'],
        'probs': _roundAll(probs),
      };
    }
  }
  return out;
}

String sameQuestion(String a, String b, [String da = '', String db = '']) {
  final String ka = da.isNotEmpty ? '（known so far as: $da）' : '';
  final String kb = db.isNotEmpty ? '（known so far as: $db）' : '';
  return 'In this_passage, are 「$a」$ka and 「$b」$kb the same person?';
}

/// "A 就是 B": does the passage establish that two names are one person?
Future<Json> checkSame(String passage, Map<String, List<String>> pairs) async {
  final Json qs = <String, Object?>{};
  int n = 0;
  for (final List<String> pr in pairs.values) {
    n++;
    qs['s$n'] = <String, Object?>{
      'type': 'choice',
      'instructions': sameQuestion(
        pr[0],
        pr[1],
        pr.length > 2 ? pr[2] : '',
        pr.length > 3 ? pr[3] : '',
      ),
      'criteria': <String, Object?>{
        'same':
            'The passage makes clear these two names refer to one and the same person.',
        'different':
            'They are different people (e.g. relatives, sisters, master and servant, two people with similar titles).',
        'unclear': 'The passage does not establish it.',
      },
    };
  }
  if (qs.isEmpty) return <String, Object?>{};
  final Json ans = await judgeCall(<String, Object?>{
    'this_passage': passage,
  }, qs);
  final Json out = <String, Object?>{};
  n = 0;
  for (final String k in pairs.keys) {
    n++;
    final Json a = _answer(ans, 's$n');
    final Json probs = _probs(a);
    out[k] = <String, Object?>{
      'same': pyRound(_get(probs, 'same'), 3),
      'choice': a['choice'],
      'probs': _roundAll(probs),
    };
  }
  return out;
}

Future<(String, Json)> routeQuestion(
  String question, [
  String contextHint = '',
]) async {
  final Json ans = await judgeCall(
    <String, Object?>{
      'question': question,
      'reader_position':
          contextHint.isNotEmpty ? contextHint : 'middle of the novel',
    },
    <String, Object?>{
      'route': <String, Object?>{
        'type': 'choice',
        'instructions':
            'Classify the reader question about the novel they are currently reading.',
        'criteria': t.routes,
      },
    },
  );
  final Json a = _answer(ans, 'route');
  final Object? choice = a['choice'];
  return (choice is String && choice.isNotEmpty ? choice : 'other', _probs(a));
}

/// Ensures unused-error analysis stays quiet for callers that only catch.
typedef JudgeError = PyException;
