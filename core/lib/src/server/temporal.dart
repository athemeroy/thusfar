/// Server evidence graph (`server/temporal.py`), distinct from reader UI data.
library;

import '../fold/fold.dart' show Json, generic;

export '../fold/fold.dart' show Json;

Json foldEvidence(List<Json> log, int pos) {
  final Map<String, Json> people = <String, Json>{};
  final Map<String, String> merges = <String, String>{};
  final List<Json> relations = <Json>[];
  final List<Json> events = <Json>[];
  final List<Json> recaps = <Json>[];
  final Map<String, List<Json>> early = <String, List<Json>>{};
  String saga = '';
  void apply(Json r) {
    final String kind = r['t']! as String;
    final String? id = r['id'] as String?;
    if (<String>['name', 'alias', 'profile', 'attr', 'imp'].contains(kind) &&
        !people.containsKey(id)) {
      early.putIfAbsent(id!, () => <Json>[]).add(r);
      return;
    }
    switch (kind) {
      case 'person':
        people[id!] = <String, Object?>{
          'id': id,
          'name': r['name'],
          'aliases': <String>[],
          'tagline': r['intro'] ?? '',
          'bio': '',
          'attrs': <String, Object?>{},
          'attr_history': <String, Object?>{},
          'imp': r['imp'] ?? 1,
          'n': 0,
          'events': <Json>[],
        };
        for (final Json held in early.remove(id) ?? <Json>[]) {
          apply(held);
        }
      case 'name':
        if (people[id]!['name'] != r['name']) {
          (people[id]!['aliases']! as List<String>).add(
            people[id]!['name']! as String,
          );
          people[id]!['name'] = r['name'];
        }
      case 'alias':
        (people[id]!['aliases']! as List<String>).add(r['alias']! as String);
      case 'merge':
        merges[r['from']! as String] = r['into']! as String;
      case 'profile':
        for (final String key in <String>['tagline', 'bio']) {
          if (r[key] != null && r[key] != '') people[id]![key] = r[key];
        }
      case 'attr':
        final Json history = people[id]!['attr_history']! as Json;
        (history.putIfAbsent(r['key']! as String, () => <Json>[])!
                as List<Json>)
            .add(<String, Object?>{'v': r['value'], 'p': r['p']});
      case 'rel':
        relations.add(r);
      case 'event':
        events.add(r);
      case 'imp':
        people[id]!['imp'] = r['imp'];
      case 'cnt':
        for (final MapEntry<String, Object?> e in (r['c']! as Json).entries) {
          if (people.containsKey(e.key)) {
            people[e.key]!['n'] =
                (people[e.key]!['n']! as num) + (e.value! as num);
          }
        }
      case 'recap':
        recaps.add(r);
    }
  }

  for (final Json row in log) {
    if ((row['p']! as num) > pos) break;
    if (row['t'] == 'saga') {
      saga = row['text']! as String;
    } else {
      apply(row);
    }
  }
  String canon(String id) {
    final Set<String> seen = <String>{};
    while (merges.containsKey(id) && seen.add(id)) {
      id = merges[id]!;
    }
    return id;
  }

  for (final String id in merges.keys) {
    final String targetId = canon(id);
    if (id == targetId ||
        !people.containsKey(id) ||
        !people.containsKey(targetId))
      continue;
    final Json source = people.remove(id)!;
    final Json target = people[targetId]!;
    if (generic.contains(target['name']) && !generic.contains(source['name']))
      target['name'] = source['name'];
    (target['aliases']! as List<String>).addAll(<String>[
      source['name']! as String,
      ...source['aliases']! as List<String>,
    ]);
    target['n'] = (target['n']! as num) + (source['n']! as num);
    if (target['bio'] == '') target['bio'] = source['bio'];
    final Json history = target['attr_history']! as Json;
    for (final MapEntry<String, Object?> e
        in (source['attr_history']! as Json).entries) {
      history[e.key] = <Json>[
        ...e.value! as List<Json>,
        ...(history[e.key] as List<Json>?) ?? <Json>[],
      ];
    }
  }
  final Map<Object?, Object?> names = <Object?, Object?>{
    for (final Json p in people.values) p['name']: p['id'],
  };
  for (final Json p in people.values) {
    p['aliases'] =
        (p['aliases']! as List<String>)
            .where(
              (String x) =>
                  x.isNotEmpty &&
                  x != p['name'] &&
                  !generic.contains(x) &&
                  !generic.contains(x.replaceFirst(RegExp('^[他她的老小未]+'), '')) &&
                  !RegExp('的|夫妇|夫妻|们|一家|俩').hasMatch(x) &&
                  !(names.containsKey(x) && names[x] != p['id']),
            )
            .toSet()
            .toList();
    for (final MapEntry<String, Object?> e
        in (p['attr_history']! as Json).entries) {
      final List<Json> values = e.value! as List<Json>;
      // Preserve Python's stable order when two records share a position.
      final List<(int, Json)> sorted = <(int, Json)>[
        for (int i = 0; i < values.length; i++) (i, values[i]),
      ]..sort(((int, Json) a, (int, Json) b) {
        final int byPos = (a.$2['p']! as num).compareTo(b.$2['p']! as num);
        return byPos != 0 ? byPos : a.$1.compareTo(b.$1);
      });
      values
        ..clear()
        ..addAll(sorted.map(((int, Json) row) => row.$2));
      (p['attrs']! as Json)[e.key] = sorted.last.$2['v'];
    }
  }
  for (final Json e in events) {
    for (final String id
        in (e['who']! as List<Object?>).cast<String>().map(canon).toSet()) {
      if (people.containsKey(id)) (people[id]!['events']! as List<Json>).add(e);
    }
  }
  final Map<String, Json> rels = <String, Json>{};
  for (final Json r in relations) {
    final String a = canon(r['a']! as String), b = canon(r['b']! as String);
    if (a == b || !people.containsKey(a) || !people.containsKey(b)) continue;
    final List<String> pair = <String>[a, b]..sort();
    final String key =
        '${pair.join('|')}${r['family'] != null && r['family'] != '' ? '|${r['family']}' : ''}';
    final Json row = <String, Object?>{...r, 'a': a, 'b': b};
    if (a.compareTo(b) > 0)
      row.addAll(<String, Object?>{
        'a': b,
        'b': a,
        'a_is': r['b_is'] ?? '',
        'b_is': r['a_is'] ?? '',
      });
    final Json? previous = rels[key];
    if (previous != null) {
      final bool reverse = previous['a'] != row['a'];
      for (final String field in <String>['a_is', 'b_is', 'desc', 'status']) {
        final String old =
            reverse && field == 'a_is'
                ? 'b_is'
                : reverse && field == 'b_is'
                ? 'a_is'
                : field;
        if (row[field] == null || row[field] == '')
          row[field] = previous[old] ?? '';
      }
      row['history'] = <Json>[
        ...(previous['history']! as List<Json>),
        <String, Object?>{
          for (final MapEntry<String, Object?> e in previous.entries)
            if (e.key != 'history') e.key: e.value,
        },
      ];
    } else {
      row['history'] = <Json>[];
    }
    rels[key] = row;
  }
  return <String, Object?>{
    'people': people,
    'rels': rels,
    'events': events,
    'saga': saga,
    'recaps': recaps,
  };
}
