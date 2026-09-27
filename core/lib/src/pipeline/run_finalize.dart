part of 'run.dart';

const Set<String> _stopwords = {
  'that',
  'with',
  'this',
  'from',
  'have',
  'were',
  'been',
  'they',
  'their',
  'them',
  'what',
  'when',
  'where',
  'which',
  'would',
  'could',
  'should',
  'about',
  'into',
  'than',
  'then',
  'there',
  'these',
  'those',
  'will',
  'your',
  'said',
  'says',
  'like',
  'just',
  'very',
  'only',
  'also',
  'some',
  'more',
  'most',
  'much',
  'such',
  'upon',
  'over',
  'under',
  'after',
  'before',
  'while',
  'being',
  'does',
  'did',
};

extension RunnerFinalization on Runner {
  Future<Object?>? queueFinal(
    String kind,
    Object key,
    List<Object?> args,
    _RunPool target,
  ) {
    final File path = File('${work.path}/jobs/$kind-$key.json');
    Json job = {'kind': kind, 'key': key, 'args': args, 'state': 'pending'};
    if (path.existsSync()) {
      final Json saved = _read(path);
      if (saved['state'] != 'complete') job = saved;
    }
    writeJson(path, job);
    qualityPending.add(_stem(path));
    if (replaying) {
      deferred.add((path, target));
      return null;
    }
    final Future<Object?> future = target.submit(() => executeFinal(path));
    pending.add(future);
    return future;
  }

  Future<Object?> executeFinal(File path) async {
    final Json job = _read(path);
    final List<Object?> args = _list(job['args']);
    Object? result;
    try {
      result = switch (job['kind']) {
        'bio' => await bioJob(
          _int(args[0]),
          _int(args[1]),
          args[2]! as String,
          _list(args[3]).cast<String>(),
        ),
        'recap' => await chapterRecapJob(
          _int(args[0]),
          _int(args[1]),
          _rows(args[2]),
          _obj(args[3]),
        ),
        'classic-recap' => await classicRecapJob(
          _int(args[0]),
          _int(args[1]),
          _rows(args[2]),
          _obj(args[3]),
          _list(args[4]),
          _str(args[5]),
        ),
        'saga' => await sagaJob(
          _int(args[0]),
          _list(args[1]).cast<int>(),
          _str(args[3]),
        ),
        _ => throw StateError('未知的章节整理任务：${job['kind']}'),
      };
      if (result == false) throw const llm.LLMError('章节整理尚未通过验证');
    } on Cancelled {
      rethrow;
    } catch (e) {
      job.addAll({'state': 'failed', 'error': _cut(_typedError(e), 300)});
      writeJson(path, job);
      qualityPending.add(_stem(path));
      rethrow;
    }
    job['state'] = 'complete';
    job.remove('error');
    writeJson(path, job);
    qualityPending.remove(_stem(path));
    if (job['kind'] == 'bio') {
      final String prefix = 'bio-unverified-${args[1]}-';
      qualityPending.removeWhere((s) => s.startsWith(prefix));
    }
    return result;
  }

  void acknowledgeFinalCache(String kind, Object key) {
    final File path = File('${work.path}/jobs/$kind-$key.json');
    if (path.existsSync()) {
      final Json job = _read(path);
      if (job['state'] != 'complete') {
        job['state'] = 'complete';
        job.remove('error');
        writeJson(path, job);
      }
    }
    qualityPending.remove(_stem(path));
  }

  void resumeFinalJobs() {
    for (final (File path, _RunPool target) in deferred) {
      final Json job = _read(path);
      final Future<Object?> future = target.submit(() => executeFinal(path));
      pending.add(future);
      if (job['kind'] == 'recap') recapFutures[_int(job['key'])] = future;
    }
    deferred.clear();
  }

  void recap(int ci, int end, int start) {
    checkpoint();
    final File path = recapPath(ci);
    if (quarantined(path)) return;
    if (path.existsSync()) {
      final Json r = _read(path);
      if (Runner.verifiedSummary(r, ['recap', 'saga'])) {
        kg.addRecap(ci, end, _str(r['recap']), _str(r['saga']));
        acknowledgeFinalCache(twoPhase ? 'recap' : 'classic-recap', ci);
        return;
      }
    }
    final List<Json> events =
        kg.log
            .where(
              (e) =>
                  e['t'] == 'event' &&
                  start <= _num(e['p']) &&
                  _num(e['p']) <= end,
            )
            .toList();
    final Json names = {
      for (final Json e in events)
        for (final Object? x in _list(e['who']))
          if (kg.people.containsKey(x)) x! as String: kg.people[x]!['name'],
    };
    final List<Object?> profiles = [
      for (final Json e in kg.log)
        if (e['t'] == 'profile' &&
            start <= _num(e['p']) &&
            _num(e['p']) <= end &&
            kg.people.containsKey(e['id']) &&
            _truth(e['tagline']))
          [kg.people[e['id']]!['name'], e['tagline']],
    ];
    if (twoPhase) {
      recapFutures[ci] = queueFinal('recap', ci, [
        ci,
        end,
        events,
        names,
      ], recapPool);
    } else {
      queueFinal('classic-recap', ci, [
        ci,
        end,
        events,
        names,
        profiles,
        kg.saga,
      ], sagaPool);
    }
  }

  String _eventText(List<Json> events, Json names) => events
      .map(
        (e) =>
            "- ${e['text']}（${_list(e['who']).where(names.containsKey).map((x) => names[x]).join('、')}）",
      )
      .join('\n');
  Future<Json> chapterRecapJob(
    int ci,
    int end,
    List<Json> events,
    Json names,
  ) async {
    final String text = _eventText(events, names);
    final Json r;
    if (text.isEmpty) {
      r = {'chapter': ci, 'recap': ''};
    } else {
      final String generated =
          (await cachedGeneration(
                'recap-$ci',
                recapModel,
                [
                  {
                    'role': 'user',
                    'content':
                        _fmt(prompts.chapterRecap, {
                          'title': book['title'],
                          'chapter': chapterName(ci),
                          'events': text,
                        }) +
                        lang.outNote(book),
                  },
                ],
                maxTokens: 1200 * lang.scale(book),
                temperature: 0.3,
              ))!
              as String;
      r = {'chapter': ci, 'recap': zh(_trim(generated))};
      try {
        final Json verdict = await judge.guardTexts(text, {}, {
          'recap': r['recap'],
        });
        if (!['ok', 'flag'].contains(_obj(verdict['recap'])['verdict']))
          throw const llm.LLMError('章节摘要缺少有效验证结果');
        r['guard'] = verdict;
        if (_obj(verdict['recap'])['verdict'] == 'flag') {
          r['recap_flagged'] = r['recap'];
          r['recap'] = _cut(
            events
                .where((e) => _num(e['imp'], 1) >= 2)
                .map((e) => e['text'])
                .join('；'),
            300,
          );
          r['fallback_kind'] = 'verified-input-excerpt';
        }
      } on Cancelled {
        rethrow;
      } catch (e) {
        throw llm.LLMError('章节摘要验证失败：${_error(e)}');
      }
    }
    writeJson(recapPath(ci), r);
    kg.addRecap(ci, end, _str(r['recap']), '');
    return r;
  }

  void saga(int end, List<int> chapters) {
    checkpoint();
    final File path = sagaPath(end);
    if (quarantined(path)) return;
    if (path.existsSync()) {
      final Json r = _read(path);
      if (Runner.verifiedSummary(r, ['saga'])) {
        kg.addRecap(-1, end, '', _str(r['saga']));
        acknowledgeFinalCache('saga', end);
        return;
      }
    }
    queueFinal('saga', end, [end, chapters, null, kg.saga], sagaPool);
  }

  Future<Object?> sagaJob(int end, List<int> chapters, String before) async {
    for (final File path in _files('jobs', prefix: 'saga-')) {
      final Json job = _read(path);
      if (_int(job['key']) < end && job['state'] != 'complete')
        throw const llm.LLMError('较早的前情提要尚未完成，后续整理已暂停');
    }
    final List<String> recaps = [];
    for (final int ci in chapters) {
      if (quarantined(recapPath(ci)))
        throw const llm.LLMError('前情提要依赖的章节摘要仍在隔离中');
      final Future<Object?>? f = recapFutures[ci];
      final Json? r =
          f != null
              ? (await f) as Json?
              : recapPath(ci).existsSync()
              ? _read(recapPath(ci))
              : null;
      if (r == null || !Runner.verifiedSummary(r, ['recap']))
        throw const llm.LLMError('前情提要所需的章节摘要尚未通过验证');
      if (_truth(r['recap'])) recaps.add('【${chapterName(ci)}】${r['recap']}');
    }
    if (recaps.isEmpty) throw const llm.LLMError('前情提要所需的章节摘要尚未完成');
    before = earlierSaga(end, before);
    final String text =
        (await cachedGeneration(
              'saga-$end',
              recapModel,
              [
                {
                  'role': 'user',
                  'content':
                      _fmt(prompts.saga, {
                        'title': book['title'],
                        'chapter': chapterName(chapters.last),
                        'saga': before.isEmpty ? '（故事刚开始）' : before,
                        'recaps': recaps.join('\n'),
                      }) +
                      lang.outNote(book),
                },
              ],
              maxTokens: 2500 * lang.scale(book),
              temperature: 0.3,
            ))!
            as String;
    final Json r = {'end': end, 'saga': zh(_trim(text))};
    try {
      final Json v = await judge.guardTexts(
        recaps.join('\n'),
        {'previous_story_so_far': before},
        {'saga': r['saga']},
      );
      if (!['ok', 'flag'].contains(_obj(v['saga'])['verdict']))
        throw const llm.LLMError('前情提要缺少有效验证结果');
      r['guard'] = v;
      if (_obj(v['saga'])['verdict'] == 'flag') {
        r['saga_flagged'] = r['saga'];
        r['saga'] = _tail(_trim('$before\n${recaps.join('\n')}'), 1500);
        r['fallback_kind'] = 'verified-input-excerpt';
      }
    } on Cancelled {
      rethrow;
    } catch (e) {
      throw llm.LLMError('前情提要验证失败：${_error(e)}');
    }
    writeJson(sagaPath(end), r);
    kg.addRecap(-1, end, '', _str(r['saga']));
    return null;
  }

  Future<Object?> classicRecapJob(
    int ci,
    int end,
    List<Json> events,
    Json names,
    List<Object?> profiles,
    String before,
  ) async {
    final String ev = _str(_eventText(events, names), '（本章没有记录到事件）');
    final String pr = _str(
      profiles.map((v) => '- ${_list(v)[0]}：${_list(v)[1]}').join('\n'),
      '（无）',
    );
    before = earlierSaga(end, before);
    final String text =
        (await cachedGeneration(
              'classic-recap-$ci',
              recapModel,
              [
                {
                  'role': 'user',
                  'content': _fmt(prompts.recap, {
                    'title': book['title'],
                    'chapter': chapterName(ci),
                    'saga': _str(before, '（故事刚开始）'),
                    'events': ev,
                    'profiles': pr,
                  }),
                },
              ],
              maxTokens: 3000,
              temperature: 0.3,
            ))!
            as String;
    final Json r = {
      'chapter': ci,
      for (final String key in ['recap', 'saga'])
        key: _trim(
          pyRe('<$key>(.*?)</$key>', dotAll: true).firstMatch(text)?[1] ??
              pyRe('<$key>(.*)', dotAll: true).firstMatch(text)?[1] ??
              '',
        ),
    };
    if (!_truth(r['saga'])) throw ValueError('提要格式不对：${_cut(text, 200)}');
    try {
      final Json v = await judge.guardTexts(
        ev,
        {'previous_story_so_far': before},
        {'recap': r['recap'], 'saga': r['saga']},
      );
      if ([
        'recap',
        'saga',
      ].any((k) => !['ok', 'flag'].contains(_obj(v[k])['verdict'])))
        throw const llm.LLMError('章节整理缺少有效验证结果');
      r['guard'] = v;
      if (_obj(v['recap'])['verdict'] == 'flag') {
        r['recap_flagged'] = r['recap'];
        r['recap'] = _cut(
          events
              .where((e) => _num(e['imp'], 1) >= 2)
              .map((e) => e['text'])
              .join('；'),
          300,
        );
        r['fallback_kind'] = 'verified-input-excerpt';
      }
      if (_obj(v['saga'])['verdict'] == 'flag') {
        r['saga_flagged'] = r['saga'];
        r['saga'] =
            _truth(r['recap']) ? _trim('$before\n${r['recap']}') : before;
        r['fallback_kind'] = 'verified-input-excerpt';
      }
    } on Cancelled {
      rethrow;
    } catch (e) {
      throw llm.LLMError('章节整理验证失败：${_error(e)}');
    }
    writeJson(recapPath(ci), r);
    kg.addRecap(ci, end, _str(r['recap']), _str(r['saga']));
    return null;
  }

  Future<void> dedupe(int ci, int end, int start) async {
    checkpoint();
    final File path = dedupePath(ci);
    if (quarantined(path) ||
        end >= _num(repairPolicy['quarantine_after'], double.infinity))
      return;
    final Json out;
    if (path.existsSync()) {
      out = _read(path);
    } else if (replaying) {
      final List<Object?> merged = [
        for (final Json r in priorLog)
          if (r['t'] == 'merge' && r['kind'] == 'dedupe' && r['p'] == end)
            [r['from'], r['into']],
      ];
      out = {'pairs': merged, 'merged': merged};
    } else {
      final (
        List<List<String>> pairs,
        Map<String, String> dossiers,
      ) = dedupeCandidates(end, start);
      out = {
        'chapter': ci,
        'end': end,
        'pairs': pairs,
        'answers': <String, Object?>{},
        'merged': <Object?>[],
      };
      if (pairs.isNotEmpty) {
        try {
          out['answers'] = await dedupeAsk(pairs, dossiers);
          usage['jev_calls'] =
              _int(usage['jev_calls']) + (pairs.length + 15) ~/ 16;
        } on Cancelled {
          rethrow;
        } catch (_) {
          return;
        }
        for (final List<String> pair in pairs) {
          if (_num(_obj(out['answers'])['${pair[0]}|${pair[1]}']) >=
              (descPairs.contains((pair[0], pair[1])) ? 0.9 : 0.8))
            _list(out['merged']).add(pair);
        }
      }
      writeJson(path, out);
    }
    for (final Object? raw in _list(out['pairs'])) {
      final List<Object?> pair = _list(raw);
      dedupeSeen.add((pair[0]! as String, pair[1]! as String));
    }
    for (final Object? raw in _list(out['merged'])) {
      final List<Object?> pair = _list(raw);
      final String? a = kg.canon(pair[0] as String?),
          b = kg.canon(pair[1] as String?);
      if (a != null &&
          b != null &&
          a != b &&
          kg.people.containsKey(a) &&
          kg.people.containsKey(b))
        kg.log.add(kg.merge(a, b, end, end, '章末核对：同一人物的重复记录', 'dedupe'));
    }
  }

  (List<List<String>>, Map<String, String>) dedupeCandidates(
    int end,
    int start,
  ) {
    final int scope = scopeStart(end);
    final Map<String, Json> people = {
      for (final e in kg.people.entries)
        if (!_truth(e.value['merged_into']) &&
            scope <= _num(e.value['first']) &&
            _num(e.value['first']) <= end)
          e.key: e.value,
    };
    (String, String) sortedPair(String a, String b) =>
        PyCompat.compare(a, b) < 0 ? (a, b) : (b, a);
    final Set<(String, String)> together = {};
    for (final Json row in kg.log) {
      if (row['t'] == 'event' && _list(row['who']).length > 1) {
        final List<String> ws =
            _list(
              row['who'],
            ).cast<String>().map(kg.canon).whereType<String>().toSet().toList();
        for (int x = 0; x < ws.length; x++) {
          for (int y = x + 1; y < ws.length; y++)
            together.add(sortedPair(ws[x], ws[y]));
        }
      }
    }
    for (final Json row in kg.rels.values) {
      final String? a = kg.canon(row['a'] as String?),
          b = kg.canon(row['b'] as String?);
      if (a != null && b != null) together.add(sortedPair(a, b));
    }
    final Set<String> recent = {
      for (final e in people.entries)
        if (_num(e.value['first']) >= start ||
            _num(e.value['last_seg'], -1) >= kg.seg - 6)
          e.key,
    };
    Set<String> names(Json p) =>
        (_set(p['aliases'])
          ..add(_str(p['name']))).where((n) => _cp(n) >= 2).toSet();
    int firstCompare(String a, String b) => PyCompat.compare(
      [people[a]!['first'] ?? 0, a],
      [people[b]!['first'] ?? 0, b],
    );
    bool clash(String a, String b) =>
        together.contains(sortedPair(a, b)) ||
        _truth(people[a]!['gender']) &&
            _truth(people[b]!['gender']) &&
            people[a]!['gender'] != people[b]!['gender'];
    final List<(String, String)> pairs = [];
    final List<String> ordered = recent.toList()..sort(firstCompare);
    for (final String a in ordered) {
      for (final String b in people.keys) {
        if (a == b || clash(a, b)) continue;
        final (String x, String y) = firstCompare(a, b) <= 0 ? (a, b) : (b, a);
        if (dedupeSeen.contains((y, x)) || pairs.contains((y, x))) continue;
        final Set<String> na = names(people[a]!), nb = names(people[b]!);
        final Set<String> pa = na.where((n) => !linking.isGeneric(n)).toSet(),
            pb = nb.where((n) => !linking.isGeneric(n)).toSet();
        final Set<String> ca = pa.map(linking.core).toSet(),
            cb = pb.map(linking.core).toSet();
        final bool close = pa.any(
          (m) => pb.any((n) => linking.related(m, n) || linking.related(n, m)),
        );
        if (na.intersection(nb).isNotEmpty ||
            (ca.intersection(cb)..remove('')).isNotEmpty ||
            close)
          pairs.add((y, x));
      }
    }
    Set<String> words(String id) {
      final Json p = people[id]!;
      final String text = [
        _str(p['intro']),
        _str(p['tagline']),
        for (final Json e in kg.log.skip(math.max(0, kg.log.length - 4000)))
          if (e['t'] == 'event' &&
              _list(e['who']).cast<String>().map(kg.canon).contains(id))
            _str(e['text']),
      ].join(' ');
      final Set<String> en =
          pyRe(
              r'[A-Za-z]{4,}',
            ).allMatches(text).map((m) => m[0]!.toLowerCase()).toSet()
            ..removeAll(_stopwords);
      final String zhText = text.replaceAll(pyRe(r'[^\u4e00-\u9fff]'), '');
      return {
        ...en,
        for (int i = 0; i < zhText.length - 1; i++) zhText.substring(i, i + 2),
      };
    }

    final List<String> nameless =
        _sorted(recent)
            .where((a) => !names(people[a]!).any((n) => !linking.isGeneric(n)))
            .toList();
    final List<String> named =
        people.keys
            .where(
              (b) =>
                  !nameless.contains(b) &&
                  names(people[b]!).any((n) => !linking.isGeneric(n)) &&
                  (recent.contains(b) || _num(people[b]!['first']) >= start),
            )
            .toList();
    for (final String a in nameless) {
      final Set<String> wa = words(a);
      final List<(int, String)> scores = [];
      for (final String b in named) {
        if (clash(a, b) ||
            dedupeSeen.contains((a, b)) ||
            dedupeSeen.contains((b, a)))
          continue;
        final int score = wa.intersection(words(b)).length;
        if (score >= 3) scores.add((score, b));
      }
      scores.sort((a, b) => PyCompat.compare([b.$1, b.$2], [a.$1, a.$2]));
      for (final (_, String b) in scores.take(2)) {
        final pair =
            _num(people[a]!['first']) > _num(people[b]!['first'])
                ? (a, b)
                : (b, a);
        pairs.add(pair);
        descPairs.add(pair);
      }
    }
    final List<(String, String)> selected = pairs.toSet().take(32).toList();
    final Map<String, String> dossiers = {};
    for (final String id in _sorted(
      selected.expand((p) => [p.$1, p.$2]).toSet(),
    )) {
      final Json p = kg.people[id]!;
      final List<String> evs = [
        for (final Json e in kg.log)
          if (e['t'] == 'event' &&
              _num(e['p']) <= end &&
              _list(e['who']).cast<String>().map(kg.canon).contains(id))
            _str(e['text']),
      ];
      final List<String> rels = [
        for (final Json r in kg.rels.values)
          if ([r['a'], r['b']].contains(id))
            "${kg.people[r['a'] == id ? r['b'] : r['a']]!['name']}（${r['a'] == id ? r['b_is'] : r['a_is']}）",
      ];
      final String aliases = _sorted(
        (_set(p['aliases'])..addAll(_set(p['weak'])))..remove(p['name']),
      ).take(8).join('、');
      final List<String> ev = [
        ...evs.take(4),
        if (evs.length > 8) ...[
          '……',
          ...evs.skip(evs.length - 4),
        ] else
          ...evs.skip(4).take(4),
      ];
      dossiers[id] = _cut(
        "${p['name']}（又称：${_str(aliases, '无')}；性别：${_str(p['gender'], '未知')}）：${_str(p['tagline'], _str(p['intro']))}。关系：${_str(rels.take(6).join('、'), '无')}。经历：${ev.join('；')}",
        900,
      );
      if (descPairs.any((pair) => pair.$1 == id || pair.$2 == id))
        dossiers[id] =
            '${dossiers[id]}\n首次出场处原文：「${textAround(_int(p['first']), 500)}」';
    }
    return (
      [
        for (final pair in selected) [pair.$1, pair.$2],
      ],
      dossiers,
    );
  }

  String textAround(int pos, int width) {
    final List<Json> blocks = _rows(book['blocks']);
    int lo = 0, hi = blocks.length - 1;
    while (lo < hi) {
      final int mid = (lo + hi + 1) ~/ 2;
      if (_num(blocks[mid]['o']) <= pos)
        lo = mid;
      else
        hi = mid - 1;
    }
    final int start = math.max(0, lo - 2);
    final String text = blocks
        .skip(start)
        .take(lo + 2 - start)
        .map((b) => b['t'])
        .join(' ');
    final int at =
        blocks
            .skip(start)
            .take(lo - start)
            .fold(0, (n, b) => n + _cp(b['t']! as String) + 1) +
        pos -
        _int(blocks[lo]['o']);
    return PyCompat.slice(text, math.max(0, at - width ~/ 2), at + width ~/ 2);
  }

  Future<Json> dedupeAsk(
    List<List<String>> pairs,
    Map<String, String> dossiers,
  ) async {
    final Json out = {};
    for (int offset = 0; offset < pairs.length; offset += 16) {
      final List<List<String>> chunk = pairs.skip(offset).take(16).toList();
      final Json questions = {};
      for (final (int index, List<String> p) in chunk.indexed) {
        questions['d${index + 1}'] = {
          'type': 'choice',
          'instructions':
              "Two character records were built from a novel, read up to the same point. Record A: ${dossiers[p[0]]}\nRecord B: ${dossiers[p[1]]}\nAre A and B the same character recorded twice? A story may keep a stranger's identity secret on purpose: similar descriptions are not enough — say \"same\" only if the records themselves establish it (same name, or the text says who that person is).",
          'criteria': {
            'same':
                'Clearly one character, established by the records: compatible names, same role and situation, nothing contradicts.',
            'different':
                'Different characters: e.g. relatives sharing a surname, two people with the same job or title, or anything contradicts.',
            'unclear': 'Cannot tell from these records.',
          },
        };
      }
      final Json answers = await backend.evaluate({
        'note': 'Judge only from the two records given.',
      }, questions);
      for (final (int index, List<String> p) in chunk.indexed) {
        out['${p[0]}|${p[1]}'] = pyRound(
          _num(_obj(_obj(answers['d${index + 1}'])['probabilities'])['same']),
          3,
        );
      }
    }
    return out;
  }

  void consolidate(int ci, int end, int start) {
    checkpoint();
    final File path = bioPath(ci);
    if (quarantined(path)) return;
    if (path.existsSync()) {
      final Json cached = _read(path);
      applyBios(cached, end);
      if (_obj(
        cached['bios'],
      ).values.every((v) => _obj(_obj(v)['chk'])['verdict'] == 'ok')) {
        acknowledgeFinalCache('bio', ci);
        return;
      }
    }
    final (String text, List<String> chosen) = dossiers(end, start);
    if (chosen.isEmpty) {
      writeJson(path, {'chapter': ci, 'bios': <String, Object?>{}});
      return;
    }
    queueFinal('bio', ci, [ci, end, text, chosen], pool);
  }

  Future<void> rateImportance(int end, int start) async {
    checkpoint();
    if ((environ['JUDGE_IMPORTANCE'] ?? '1') != '1' ||
        end >= _num(repairPolicy['quarantine_after'], double.infinity))
      return;
    final File saved = File('${work.path}/finalize/$end-importance.json');
    if (saved.existsSync() || replaying) {
      final List<Json> records =
          saved.existsSync()
              ? _rows(_read(saved)['records'])
              : priorLog
                  .where((r) => r['t'] == 'imp' && r['p'] == end)
                  .toList();
      for (final Json r in records) {
        if (kg.people.containsKey(r['id'])) {
          kg.people[r['id']]!.addAll({'imp': r['imp'], 'imp_p': end});
          kg.log.add({...r});
        }
      }
      return;
    }
    final List<Json> fresh =
        PyCompat.stableSorted(
          kg.people.values.where(
            (p) =>
                !_truth(p['merged_into']) &&
                _num(p['first']) <= end &&
                _num(p['imp_p'], -1) < start &&
                (_num(p['mentions']) >= 2 || _num(p['first']) >= start),
          ),
          key: (p) => -_num(p['mentions']),
        ).take(judge.batch).toList();
    if (fresh.isEmpty) return;
    final Map<String, String> records = {};
    for (final Json p in fresh) {
      final List<String> ev =
          [
            for (final Json e in kg.log)
              if (e['t'] == 'event' &&
                  _num(e['p']) <= end &&
                  _list(
                    e['who'],
                  ).cast<String>().map(kg.canon).contains(p['id']))
                _str(e['text']),
          ].take(6).toList();
      records[p['id']! as String] = _cut(
        "${p['name']}（${_str(p['tagline'], _str(p['intro']))}；出现 ${p['mentions'] ?? 0} 次）：${_str(ev.join('；'), '本段之前没有记录到事件')}",
        600,
      );
    }
    final Map<String, int> rated;
    try {
      rated = await judge.importanceOf(
        records,
        concept: ['nonfiction', 'reference'].contains(book['genre']),
      );
      usage['jev_calls'] = _int(usage['jev_calls']) + 1;
    } on Cancelled {
      rethrow;
    } catch (_) {
      return;
    }
    for (final e in rated.entries) {
      final Json? p = kg.people[e.key];
      if (p == null || p['imp'] == e.value) continue;
      p.addAll({'imp': e.value, 'imp_p': end});
      kg.log.add({'t': 'imp', 'p': end, 'id': e.key, 'imp': e.value});
    }
    for (final Json p in fresh) {
      p['imp_p'] = end;
    }
    writeJson(saved, {
      'records': kg.log.where((r) => r['t'] == 'imp' && r['p'] == end).toList(),
    });
  }

  Future<void> settleAttrs(int end, int start) async {
    checkpoint();
    if ((environ['JUDGE_ATTRS'] ?? '1') != '1' ||
        end >= _num(repairPolicy['quarantine_after'], double.infinity))
      return;
    final File saved = File('${work.path}/finalize/$end-attrs.json');
    if (saved.existsSync() || replaying) {
      kg.log.addAll(
        (saved.existsSync()
                ? _rows(_read(saved)['records'])
                : priorLog.where(
                  (r) =>
                      r['t'] == 'attr' && r['by'] == 'judge' && r['p'] == end,
                ))
            .map((r) => <String, Object?>{...r}),
      );
      return;
    }
    final Map<(String, String), List<(int, String)>> seen = {};
    for (final Json r in kg.log) {
      if (r['t'] == 'attr' && _num(r['p']) <= end) {
        final String? id = kg.canon(r['id'] as String?);
        if (id != null && kg.people.containsKey(id))
          seen.putIfAbsent((id, r['key']! as String), () => []).add((
            _int(r['p']),
            r['value']! as String,
          ));
      }
    }
    final Map<String, (String, String, List<String>)> items = {};
    for (final e in seen.entries) {
      if (e.value.length < 2 || e.value.last.$1 < start) continue;
      final List<(int, String)> ordered =
          e.value.toList()
            ..sort((a, b) => PyCompat.compare([a.$1, a.$2], [b.$1, b.$2]));
      final List<String> values =
          ordered
              .skip(math.max(0, ordered.length - 4))
              .map((v) => v.$2)
              .toSet()
              .toList();
      if (values.length < 2) continue;
      items['${e.key.$1}|${e.key.$2}'] = (
        kg.people[e.key.$1]!['name']! as String,
        e.key.$2,
        values,
      );
      if (items.length == judge.batch) break;
    }
    if (items.isEmpty) return;
    final Json chosen;
    try {
      chosen = await judge.currentValue(items);
      usage['jev_calls'] = _int(usage['jev_calls']) + 1;
    } on Cancelled {
      rethrow;
    } catch (_) {
      return;
    }
    for (final e in chosen.entries) {
      final int bar = e.key.indexOf('|');
      final String id = e.key.substring(0, bar), key = e.key.substring(bar + 1);
      Json? latest;
      for (final Json r in kg.log) {
        if (r['t'] == 'attr' &&
            kg.canon(r['id'] as String?) == id &&
            r['key'] == key &&
            _num(r['p']) <= end &&
            (latest == null || _num(r['p']) > _num(latest['p'])))
          latest = r;
      }
      if (latest != null && latest['value'] != e.value)
        kg.log.add({
          't': 'attr',
          'p': end,
          's': end,
          'id': id,
          'key': key,
          'value': e.value,
          'by': 'judge',
        });
    }
    writeJson(saved, {
      'records':
          kg.log
              .where(
                (r) => r['t'] == 'attr' && r['by'] == 'judge' && r['p'] == end,
              )
              .toList(),
    });
  }

  (String, List<String>) dossiers(int end, int start) {
    final Map<String, int> active = {};
    for (final Json e in kg.log) {
      if (e['t'] == 'event' && start <= _num(e['p']) && _num(e['p']) <= end) {
        for (final String who in _list(e['who']).cast<String>()) {
          final String? id = kg.canon(who);
          if (id != null) active[id] = (active[id] ?? 0) + 1;
        }
      }
    }
    final List<String> chosen =
        PyCompat.stableSorted(
          active.keys.where(
            (id) =>
                kg.people.containsKey(id) &&
                (active[id]! >= 2 ||
                    _num(kg.people[id]!['imp'], 1) >= 3 && active[id]! > 0),
          ),
          key: (id) => -active[id]!,
        ).take(10).toList();
    final List<String> blocks = [];
    for (final String id in chosen) {
      final Json p = kg.people[id]!, attrs = {};
      for (final Json r in kg.log) {
        if (r['t'] == 'attr' &&
            kg.canon(r['id'] as String?) == id &&
            _num(r['p']) <= end)
          attrs[r['key']! as String] = r['value'];
      }
      final List<String> rels = [
        for (final Json r in kg.rels.values)
          if ([r['a'], r['b']].contains(id) &&
              r['status'] != 'ended' &&
              kg.people.containsKey(r['a'] == id ? r['b'] : r['a']))
            "${kg.people[r['a'] == id ? r['b'] : r['a']]!['name']}（${r['a'] == id ? r['b_is'] : r['a_is']}）",
      ];
      final List<Json> history = PyCompat.stableSorted(
        kg.log.where(
          (e) =>
              e['t'] == 'event' &&
              _num(e['p']) <= end &&
              _list(e['who']).cast<String>().map(kg.canon).contains(id) &&
              (_num(e['imp'], 1) >= 2 || _num(e['p']) >= start),
        ),
        key: (e) => e['p'],
      );
      final String aliases = _sorted(
        _set(p['aliases'])..remove(p['name']),
      ).take(6).join('、');
      blocks.add(
        "【$id｜${p['name']}】\n别称：${_str(aliases, '无')}\n当前一句话身份：${_str(p['tagline'])}\n档案（最新）：${_str(attrs.entries.map((e) => '${e.key}：${e.value}').join('；'), '无')}\n关系：${_str(rels.join('、'), '无')}\n至今经历（按时间）：\n${history.skip(math.max(0, history.length - 45)).map((e) => '- ${e['text']}').join('\n')}",
      );
    }
    return (blocks.join('\n\n'), chosen);
  }

  Future<Object?> bioJob(
    int ci,
    int end,
    String dossiers,
    List<String> chosen,
  ) async {
    final Object? data = await cachedGeneration(
      'bio-$ci',
      model,
      [
        {
          'role': 'user',
          'content':
              _fmt(prompts.consolidate, {
                'title': book['title'],
                'chapter': chapterName(ci),
                'dossiers': dossiers,
              }) +
              lang.outNote(book),
        },
      ],
      maxTokens: 6000 * lang.scale(book),
      temperature: 0.2,
      jsonOutput: true,
    );
    final Json bios = {
      for (final e in _obj(data).entries)
        if (chosen.contains(e.key) &&
            e.value is Json &&
            _truth(_obj(e.value)['bio']))
          e.key: e.value,
    };
    final Json verdicts;
    try {
      verdicts = await judge.guardTexts(dossiers, {}, {
        for (final e in bios.entries)
          e.key: '${_str(_obj(e.value)['tagline'])}。${_obj(e.value)['bio']}',
      });
      usage['jev_calls'] = _int(usage['jev_calls']) + 1;
    } on Cancelled {
      rethrow;
    } catch (e) {
      throw llm.LLMError('人物小传验证失败：${_error(e)}');
    }
    for (final String id in bios.keys.toList()) {
      final Json v = _obj(verdicts[id]);
      if (!['ok', 'flag'].contains(v['verdict']))
        throw const llm.LLMError('人物小传缺少有效验证结果');
      _obj(bios[id])['chk'] = {'jev': v['p'], 'verdict': v['verdict']};
      if (v['verdict'] == 'flag') bios.remove(id);
    }
    final Json out = {'chapter': ci, 'bios': bios};
    writeJson(bioPath(ci), out);
    applyBios(out, end);
    publish();
    return null;
  }

  void applyBios(Json out, int end) {
    for (final e in _obj(out['bios']).entries) {
      if (!kg.people.containsKey(e.key)) continue;
      final Json v = _obj(e.value);
      if (_obj(v['chk'])['verdict'] != 'ok') {
        qualityPending.add('bio-unverified-$end-${e.key}');
        continue;
      }
      final int k = lang.scale(book);
      final Json rec = {
        't': 'profile',
        'p': end,
        'id': e.key,
        'tagline': zh(_cut(_str(v['tagline']), 30 * k)),
        'bio': zh(_cut(v['bio']! as String, 420 * k)),
        'chk': v['chk'],
        'kind': 'chapter',
      };
      kg.log.add(rec);
      final Json p = kg.people[e.key]!;
      if (end >= _num(p['profile_p'], -1)) {
        p.addAll({
          'tagline':
              _truth(rec['tagline']) ? rec['tagline'] : p['tagline'] ?? '',
          'bio': rec['bio'],
          'profile_p': end,
        });
      }
    }
  }

  Future<void> maybeRecap(int i) async {
    final Json seg = segs[i];
    final bool last =
        i == segs.length - 1 || segs[i + 1]['chapter'] != seg['chapter'];
    if (!last) return;
    final int start = segs
            .where((s) => s['chapter'] == seg['chapter'])
            .map((s) => _int(s['o0']))
            .reduce(math.min),
        end = _int(seg['o1']),
        ci = _int(seg['chapter']);
    final bool doBio = end - lastBio >= 12000 || i == segs.length - 1;
    if (doBio && twoPhase) {
      await dedupe(ci, end, lastBio);
      try {
        await rateImportance(end, lastBio);
      } on Cancelled {
        rethrow;
      } catch (_) {}
      try {
        await settleAttrs(end, lastBio);
      } on Cancelled {
        rethrow;
      } catch (_) {}
    }
    if (doBio) {
      consolidate(ci, end, lastBio);
      lastBio = end;
    }
    recap(ci, end, start);
    if (twoPhase && (end - lastSaga >= 30000 || i == segs.length - 1)) {
      final List<int> chapters =
          segs
              .where((s) => lastSaga < _num(s['o1']) && _num(s['o1']) <= end)
              .map((s) => _int(s['chapter']))
              .toSet()
              .toList()
            ..sort();
      saga(end, chapters);
      lastSaga = end;
    }
  }
}
