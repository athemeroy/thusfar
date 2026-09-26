part of 'run.dart';

extension RunnerSupport on Runner {
  int scopeStart(int pos) {
    for (final (int a, int b) in works) {
      if (a <= pos && pos <= b) return a;
    }
    return 0;
  }

  List<Json> _memoryPeople(int limit) {
    final int start =
        works.isNotEmpty && segs.isNotEmpty
            ? scopeStart(_int(segs[math.min(kg.seg, segs.length - 1)]['o0']))
            : 0;
    return PyCompat.stableSorted(
      kg.people.values.where(
        (p) => !_truth(p['merged_into']) && _int(p['first']) >= start,
      ),
      key:
          (Json p) => [
            -(_int(p['mentions']) +
                20 * (kg.seg - _int(p['last_seg'], -99) <= 6 ? 1 : 0)),
            p['id'],
          ],
    ).take(limit).toList();
  }

  String castHint([int limit = 90]) => _memoryPeople(limit)
      .map((p) {
        final String aliases = _sorted(
          (_set(p['aliases'])..addAll(_set(p['weak'])))..remove(p['name']),
        ).take(6).join('、');
        return "${p['id']}｜${p['name']}｜${aliases.isEmpty ? '—' : aliases}｜${_cut(_str(p['tagline'], _str(p['intro'])), 24)}";
      })
      .join('\n');
  Json relationMemory([int limit = 90]) {
    final Map<String, Json> chosen = {
      for (final Json p in _memoryPeople(limit)) p['id']! as String: p,
    };
    final Map<String, List<String>> events = {
          for (final String id in chosen.keys) id: [],
        },
        relations = {for (final String id in chosen.keys) id: []};
    for (final Json row in kg.log.skip(math.max(0, kg.log.length - 3000))) {
      if (row['t'] != 'event') continue;
      for (final Object? raw in _list(row['who'])) {
        final String? id = kg.canon(raw as String?);
        if (events.containsKey(id)) events[id]!.add(_str(row['text']));
      }
    }
    for (final Json rel in kg.rels.values) {
      for (final Object? id in [rel['a'], rel['b']]) {
        if (!relations.containsKey(id)) continue;
        final Object? other = rel['a'] == id ? rel['b'] : rel['a'];
        if (!kg.people.containsKey(other)) continue;
        final Object? role = rel['a'] == id ? rel['b_is'] : rel['a_is'];
        relations[id]!.add(
          '${kg.people[other]!['name']}（${_str(role, '关系未命名')}）',
        );
      }
    }
    return {
      'story': _cut(kg.saga, 1800),
      'recent_events':
          kg.recent.skip(math.max(0, kg.recent.length - 12)).toList(),
      'people': {
        for (final e in chosen.entries)
          e.key: {
            'name': e.value['name'],
            'aliases':
                _sorted(
                  (_set(e.value['aliases'])
                    ..addAll(_set(e.value['weak'])))..remove(e.value['name']),
                ).take(6).toList(),
            'tagline': _cut(
              _str(e.value['tagline'], _str(e.value['intro'])),
              120,
            ),
            'bio': _cut(_str(e.value['bio']), 520),
            'known_relations': relations[e.key]!.take(8).toList(),
            'recent_events':
                events[e.key]!
                    .skip(math.max(0, events[e.key]!.length - 6))
                    .where((t) => t.isNotEmpty)
                    .toList(),
          },
      },
    };
  }

  Json relationContext(int i, Json data, Json? memory) {
    memory ??= {};
    final Json known = _obj(memory['people']), characters = {};
    for (final Json person in _rows(data['people'])) {
      final Json row = {
        'name_in_this_passage': _str(
          person['name'],
        ).replaceFirst(RegExp(r'^\*+'), ''),
        'description_in_this_passage': _str(person['role']),
      };
      final Json prior = _obj(known[pyStr(person['known'])]);
      if (prior.isNotEmpty) {
        row['known_before'] = prior;
      } else if (_truth(person['known_name'])) {
        row['known_before'] = {'name': person['known_name']};
      }
      characters[pyStr(person['id'])] = row;
    }
    String story = _str(memory['story']);
    final List<String> recent =
        _list(memory['recent_events']).where(_truth).cast<String>().toList();
    if (recent.isNotEmpty)
      story += '${story.isEmpty ? '' : '\n'}最近事件：${recent.join('；')}';
    String previous = '';
    if (i > 0 && _num(segs[i - 1]['o0']) >= scopeStart(_int(segs[i]['o0'])))
      previous = _tail(extraction.segText(book, segs[i - 1]), 1600);
    return {
      'story_before_this_passage': _cut(story, 2600),
      'previous_passage_tail': previous,
      'character_context': characters,
    };
  }

  Map<String, (String, String)> supportItems(
    Json data, {
    bool sampleEvents = true,
    Iterable<String> checkedEvents = const [],
  }) {
    final Json names = {
      for (final Json p in _rows(data['people']))
        pyStr(p['id']): _str(p['name']).replaceFirst(RegExp(r'^\*+'), ''),
    };
    final BigInt? parsed = tryPythonDecimal(
      environ['EVENT_CHECK_ONE_IN'] ?? '6',
    );
    if (parsed == null) throw const ValueError('EVENT_CHECK_ONE_IN 必须是整数');
    final BigInt rate = parsed;
    final Map<String, (String, String)> items = {};
    for (final (int j, Json e) in _rows(data['events']).indexed) {
      final String text = _str(e['text']);
      if (text.isEmpty) continue;
      final bool risky =
          judge.critical.hasMatch(text) || _num(e['imp'], 1) >= 3;
      final bool sampled =
          sampleEvents &&
          (rate <= BigInt.one ||
              BigInt.parse(
                        sha256Hex(utf8.encode(text)).substring(0, 16),
                        radix: 16,
                      ) %
                      rate ==
                  BigInt.zero);
      if (risky || sampled || checkedEvents.contains('e$j'))
        items['e$j'] = ('event', text);
    }
    for (final (int j, Json a) in _rows(data['facts']).indexed) {
      if (_truth(a['value']))
        items['a$j'] = (
          'attr',
          "${names[pyStr(a['who'])] ?? '?'}｜${pyStr(a['key'])}：${a['value']}",
        );
    }
    for (final (int j, Json r) in _rows(data['rels']).indexed) {
      if (_truth(r['b_is']) && r['by'] != 'judge')
        items['r$j'] = (
          'rel',
          "${names[pyStr(r['b'])] ?? '?'} 是 ${names[pyStr(r['a'])] ?? '?'} 的${r['b_is']}",
        );
    }
    return items;
  }

  static bool validSupport(Object? answer) {
    const Set<String> choices = {'supported', 'not_in_passage', 'contradicted'};
    if (answer is! Json || !choices.contains(answer['choice'])) return false;
    bool valid(Object? v) => v is num && v.isFinite && v >= 0 && v <= 1;
    final Object? probs = answer['probs'];
    return valid(answer['p']) &&
        probs is Json &&
        probs.containsKey(answer['choice']) &&
        probs.entries.every((e) => choices.contains(e.key) && valid(e.value));
  }

  (Map<String, (String, String)>, Map<String, String>) pendingSupport(
    Json rec,
    int i,
  ) {
    rec.putIfAbsent(
      'support_sampling',
      () => rec['support'] == null ? 'sha256-v1' : 'legacy',
    );
    final Json support = rec['support'] is Json ? rec['support']! as Json : {};
    rec['support'] = support;
    final Json fingerprints =
        rec['support_fingerprints'] is Json
            ? rec['support_fingerprints']! as Json
            : {};
    rec['support_fingerprints'] = fingerprints;
    final Map<String, (String, String)> items = supportItems(
      _obj(rec['data']),
      sampleEvents: rec['support_sampling'] != 'legacy',
      checkedEvents: support.keys,
    );
    final Json questions = judge.recordQuestions(items);
    final String text = _cut(extraction.segText(book, segs[i]), 12000);
    final Map<String, String> wanted = {
      for (final String key in items.keys)
        key: sha256Hex(
          utf8.encode(
            PyJson.encode(
              [text, questions['v_$key']],
              ensureAscii: false,
              sortKeys: true,
            ),
          ),
        ),
    };
    for (final String key in {...support.keys, ...fingerprints.keys}) {
      if (!items.containsKey(key)) {
        support.remove(key);
        fingerprints.remove(key);
      }
    }
    final Map<String, (String, String)> pending = {};
    for (final e in items.entries) {
      final bool valid = validSupport(support[e.key]);
      if (valid && fingerprints[e.key] == wanted[e.key]) continue;
      final bool rewritten =
          e.key.startsWith('r') &&
          _truth(
            _rows(_obj(rec['data'])['rels'])[int.parse(
              e.key.substring(1),
            )]['fixed_by'],
          );
      if (valid && !fingerprints.containsKey(e.key) && !rewritten) {
        fingerprints[e.key] = wanted[e.key];
        final List<Object?> adopted =
            (rec.putIfAbsent('support_legacy_adopted', () => <Object?>[]))!
                as List<Object?>;
        if (!adopted.contains(e.key)) adopted.add(e.key);
        continue;
      }
      support.remove(e.key);
      fingerprints.remove(e.key);
      pending[e.key] = e.value;
    }
    if (pending.isNotEmpty) {
      rec['support_pending'] = _sorted(pending.keys);
    } else {
      rec.remove('support_pending');
    }
    return (pending, wanted);
  }

  void mergeSupport(
    Json rec,
    Map<String, (String, String)> items,
    Map<String, String> fingerprints,
    Object? answers,
  ) {
    final List<String> missing = [];
    for (final String key in items.keys) {
      final Object? answer = answers is Json ? answers[key] : null;
      if (validSupport(answer)) {
        _obj(rec['support'])[key] = answer;
        _obj(rec['support_fingerprints'])[key] = fingerprints[key];
      } else {
        missing.add(key);
      }
    }
    if (missing.isNotEmpty) {
      rec['support_pending'] = _sorted(missing);
      throw llm.LLMError('裁判缺少有效的核对结果：${missing.join(',')}');
    }
    rec.remove('support_pending');
    rec.remove('support_error');
  }

  Future<Map<(String, String), Json>> nameRelations(
    int i,
    String model,
    List<(String, String)> pairs,
    Json names,
    String text,
  ) async {
    final String rows = [
      for (final (int n, (String a, String b)) in pairs.indexed)
        '${n + 1}. A=${names[a] ?? a}｜B=${names[b] ?? b}',
    ].join('\n');
    Object? generated;
    try {
      final (Object? data, Json u) = await backend.generate(
        model,
        [
          {
            'role': 'user',
            'content': _fmt(prompts.relationWords, {
              'title': book['title'],
              'text': _cut(text, 12000),
              'pairs': rows,
            }),
          },
        ],
        jsonOutput: true,
        maxTokens: 600 * lang.scale(book),
        temperature: 0.2,
      );
      count(model, u);
      generated = data;
    } on Cancelled {
      rethrow;
    } catch (_) {
      return {};
    }
    final String flat = text.replaceAll(pyRe(r'\s+'), '');
    final Map<(String, String), Json> out = {};
    for (final (int n, (String a, String b)) in pairs.indexed) {
      final Json x = _obj(_obj(generated)['${n + 1}']);
      final String quote = _str(x['quote']).replaceAll(pyRe(r'\s+'), '');
      if (_truth(x['b_is']) && quote.isNotEmpty && flat.contains(quote))
        out[(a, b)] = x;
    }
    return out;
  }

  Future<Json> addRelations(Json rec, int i, [String model = '']) async {
    checkpoint();
    if ((environ['JUDGE_RELATIONS'] ?? '1') != '1' ||
        rec['judge_rels'] != null &&
            rec['relation_judge_revision'] == relationJudgeRevision)
      return rec;
    final Json data = _obj(rec['data']);
    final Json names = {
      for (final Json p in _rows(data['people']))
        pyStr(p['id']): _str(p['name']).replaceFirst(RegExp(r'^\*+'), ''),
    };
    final Set<(String, String)> seen = {};
    final List<(String, String)> pairs = [];
    final Map<(String, String), (Object?, Object?)> where = {};
    for (final Json e in _rows(data['events'])) {
      final List<String> who =
          _list(
            e['who'],
          ).where(names.containsKey).cast<String>().toSet().toList();
      for (int x = 0; x < who.length; x++) {
        for (int y = x + 1; y < who.length; y++) {
          final pair = (who[x], who[y]);
          if (!seen.contains(pair) && !seen.contains((pair.$2, pair.$1))) {
            seen.add(pair);
            pairs.add(pair);
            where[pair] = (e['para'], e['quote']);
          }
        }
      }
    }
    if (pairs.length > 12) pairs.removeRange(12, pairs.length);
    if (pairs.isEmpty) {
      rec['judge_rels'] = {};
      rec['relation_judge_revision'] = relationJudgeRevision;
      return rec;
    }
    final String language = lang.cardLang(book) == 'en' ? 'en' : 'zh',
        kind =
            ['nonfiction', 'reference'].contains(book['genre'])
                ? 'concept'
                : 'novel';
    final Json inverse = judge.trees(kind).$3;
    final Map<(String, String), Json> got;
    try {
      final String text = _cut(extraction.segText(book, segs[i]), 12000);
      final (items, fingerprints) = pendingSupport(rec, i);
      final Json context = _obj(rec['relation_context']);
      final (Json support, families) = await judge.checkAndFamilies(
        text,
        items,
        pairs,
        names,
        kind: kind,
        ctx: context,
      );
      if (items.isNotEmpty) mergeSupport(rec, items, fingerprints, support);
      checkpoint();
      got = await judge.relationsByJudge(
        text,
        pairs,
        names,
        fam: families,
        kind: kind,
        ctx: context,
      );
      usage['jev_calls'] =
          _int(usage['jev_calls']) +
          3 * ((pairs.length + items.length + 47) ~/ 48);
    } on Cancelled {
      rethrow;
    } catch (e) {
      rec['relation_check_error'] = _cut(_typedError(e), 300);
      writeJson(localPath(i), rec);
      rethrow;
    }
    (String, String) ordered(String a, String b) =>
        PyCompat.compare(a, b) <= 0 ? (a, b) : (b, a);
    final Map<(String, String), Json> have = {
      for (final Json r in _rows(data['rels']))
        ordered(pyStr(r['a']), pyStr(r['b'])): r,
    };
    int added = 0;
    final List<(String, String)> other = [
      for (final e in got.entries)
        if (_rows(e.value['ties']).any((t) => t['role'] == 'other') &&
            !have.containsKey(ordered(e.key.$1, e.key.$2)))
          e.key,
    ];
    checkpoint();
    final Map<(String, String), Json> worded =
        other.isEmpty
            ? {}
            : await nameRelations(
              i,
              model.isEmpty ? local.localModel : model,
              other,
              names,
              extraction.segText(book, segs[i]),
            );
    for (final entry in got.entries) {
      final (String a, String b) = entry.key;
      final Json v = entry.value;
      final List<Json> ties =
          _rows(v['ties']).where((t) => t['role'] != 'other').toList();
      final List<String> facets = [];
      for (final String f in ['state', 'stance']) {
        final Object? x = v[f];
        if (x is List && x.isNotEmpty && !['current', 'neutral'].contains(x[0]))
          facets.add(judge.label(x[0]! as String, language));
      }
      final String note = [
        ...facets,
        ...ties.skip(1).map((t) => judge.label(t['role']! as String, language)),
      ].join(language == 'en' ? '; ' : '；');
      final Object? state = v['state'];
      final bool ended =
          state is List && state.isNotEmpty && state[0] == 'former';
      final Json? x = worded[(a, b)], r = have[ordered(a, b)];
      final (Object? para, Object? quote) = where[(a, b)] ?? (null, '');
      if (r != null) {
        final String label = _str(r['b_is']);
        final bool same = pyStr(r['a']) == a;
        final String expectedB =
            ties.isEmpty
                ? ''
                : judge.label(
                  (same ? ties.first['role'] : inverse[ties.first['role']])!
                      as String,
                  language,
                );
        final String expectedA =
            ties.isEmpty
                ? ''
                : judge.label(
                  (same ? inverse[ties.first['role']] : ties.first['role'])!
                      as String,
                  language,
                );
        final Set<String> canonical = {
          for (final Object? table in judge.trees(kind).$2.values)
            for (final String role in (table! as Json).keys)
              judge.label(role, language),
        };
        final bool conflict =
            ties.isNotEmpty &&
            _num(ties.first['p']) >= 0.85 &&
            canonical.contains(label) &&
            label != expectedB;
        final bool bad =
            label.isEmpty ||
            _cp(label) > (language == 'en' ? 40 : 14) ||
            label.contains('而言') ||
            pyRe(r'^[abAB]\s*的').hasMatch(label) ||
            (ties.isNotEmpty &&
                _num(ties.first['p']) >= 0.7 &&
                _cp(label) > (language == 'en' ? 24 : 8)) ||
            conflict ||
            [
              names[a],
              names[b],
            ].any((n) => n is String && _cp(n) >= 2 && label.contains(n));
        if (bad && ties.isNotEmpty)
          r.addAll({'b_is': expectedB, 'a_is': expectedA, 'fixed_by': 'judge'});
        if (note.isNotEmpty && !_truth(r['desc'])) r['desc'] = note;
      } else if (x != null) {
        (data.putIfAbsent('rels', () => <Object?>[]))! as List<Object?>;
        _list(data['rels']).add({
          'a': a,
          'b': b,
          'b_is': _cut(pyStr(x['b_is']), 14),
          'a_is': _cut(_str(x['a_is']), 14),
          'desc': _cut(_str(x['desc'], note), 40),
          'para': para,
          'quote': _truth(x['quote']) ? x['quote'] : quote,
          'by': 'judge+llm',
        });
        added++;
      } else if (ties.isNotEmpty) {
        data.putIfAbsent('rels', () => <Object?>[]);
        final Json t = ties.first;
        _list(data['rels']).add({
          'a': a,
          'b': b,
          'b_is': judge.label(t['role']! as String, language),
          'a_is': judge.label(inverse[t['role']]! as String, language),
          'desc': note,
          'para': para,
          'quote': quote,
          'by': 'judge',
          'p': t['p'],
          'status': ended ? 'ended' : 'new',
        });
        added++;
      }
    }
    rec['judge_rels'] = {
      for (final entry in got.entries)
        '${entry.key.$1}|${entry.key.$2}': _relationJson(entry.value),
    };
    rec['relation_judge_revision'] = relationJudgeRevision;
    rec['judge_rels_added'] = added;
    rec.remove('relation_check_error');
    pendingSupport(rec, i);
    writeJson(localPath(i), rec);
    return rec;
  }

  Json _relationJson(Json value) => {
    for (final e in value.entries)
      e.key:
          e.value is (String, num)
              ? [(e.value as (String, num)).$1, (e.value as (String, num)).$2]
              : e.value,
  };
  Future<Json> addSupport(Json rec, int i) async {
    checkpoint();
    if ((environ['VERIFY_RECORDS'] ?? '1') != '1') return rec;
    final (items, fingerprints) = pendingSupport(rec, i);
    try {
      if (items.isNotEmpty) {
        final Json answers = await judge.verifyRecords(
          extraction.segText(book, segs[i]),
          items,
        );
        usage['jev_calls'] =
            _int(usage['jev_calls']) + (items.length + 47) ~/ 48;
        mergeSupport(rec, items, fingerprints, answers);
      }
      rec.remove('support_error');
    } on Cancelled {
      rethrow;
    } catch (e) {
      rec['support_error'] = _cut(_typedError(e), 300);
      writeJson(localPath(i), rec);
      rethrow;
    }
    writeJson(localPath(i), rec);
    return rec;
  }

  Future<Json> localJob(
    int i,
    String model, [
    String hint = '',
    Json? memory,
  ]) async {
    final File path = localPath(i);
    if (path.existsSync()) {
      final Json rec = _read(path);
      if (_truth(rec['empty']))
        throw llm.LLMError('第 $i 段缓存来自抽取失败，须先隔离失败缓存再重试');
      if (_truth(rec['refused'])) {
        refused.add(i);
        return addSupport(await addRelations(rec, i, model), i);
      }
      final Json p = _obj(rec['provenance']);
      if (p.isNotEmpty &&
          (p['input_sha256'] != inputSha256 ||
              p['extractor_revision'] != prompts.extractorRevision ||
              rec['model'] != model))
        throw const llm.LLMError('抽取缓存的输入、模型或提示版本已变更；请隔离旧缓存后重建');
      rec['data'] = local.sanitize(_obj(rec['data']));
      if (!_truth(rec['relation_context']))
        rec['relation_context'] = relationContext(i, _obj(rec['data']), memory);
      return addSupport(await addRelations(rec, i, model), i);
    }
    Json? rec;
    int refusals = 0;
    Object? lastError;
    for (int attempt = 0; attempt < 4; attempt++) {
      checkpoint();
      try {
        final double start = backend.now();
        final (Json data, Json tokens) = await backend.extractLocal(
          book,
          segs[i],
          i > 0 ? segs[i - 1] : null,
          model,
          hint,
        );
        final Json shown = {
          for (final String row in hint.split('\n'))
            if ('｜'.allMatches(row).length >= 2)
              row.split('｜')[0]: row.split('｜')[1],
        };
        for (final Json lp in _rows(data['people'])) {
          if (shown.containsKey(lp['known']))
            lp['known_name'] = shown[lp['known']];
        }
        rec = {
          'seg': i,
          'model': model,
          'data': data,
          'raw': tokens.remove('_raw'),
          'hint_size': _cp(hint),
          'relation_context': relationContext(i, data, memory),
          'provenance': {
            'schema': provenanceSchema,
            'input_sha256': inputSha256,
            'extractor_revision': prompts.extractorRevision,
          },
          'usage': {
            'prompt': tokens['prompt_tokens'],
            'completion': tokens['completion_tokens'],
          },
          'seconds': PyCompat.roundDigits(backend.now() - start, 1),
        };
        count(model, tokens);
        writeJson(path, rec);
        break;
      } on Cancelled {
        rethrow;
      } catch (e) {
        if (_error(e).startsWith('REFUSED:')) {
          refusals++;
          if (refusals >= 2) {
            final Json data = local.sanitize({});
            rec = {
              'seg': i,
              'model': model,
              'data': data,
              'refused': _trim(_error(e).substring(8)),
              'relation_context': relationContext(i, data, memory),
              'provenance': {
                'schema': provenanceSchema,
                'input_sha256': inputSha256,
                'extractor_revision': prompts.extractorRevision,
              },
              'usage': <String, Object?>{},
              'seconds': 0,
            };
            writeJson(path, rec);
            refused.add(i);
            break;
          }
          continue;
        }
        final String? reason = llm.explain(e);
        if (reason != null && reason.isNotEmpty) throw llm.LLMError(reason);
        lastError = e;
        notify('模型请求失败，正在重试（第 ${attempt + 1} 次）：${_cut(_error(e), 160)}');
        final bool rate =
            e is llm.LLMError &&
            pyRe(
              r'\b(429|5\d\d)\b|timed out|timeout',
              ignoreCase: true,
            ).hasMatch(_error(e));
        if (attempt < 3)
          await awaitFuture(
            backend.sleep(Duration(seconds: rate ? 15 * (attempt + 1) : 1)),
          );
      }
    }
    if (rec == null)
      throw llm.LLMError('第 $i 段连续四次请求模型都失败，已暂停：${_cut('$lastError', 200)}');
    checkpoint();
    return addSupport(await addRelations(rec, i, model), i);
  }

  String Function(String) describeFactory(Json data, Json plan) {
    final Map<Object?, Json> intro = {
      for (final Json np in _rows(data['new_people']))
        _obj(plan['refmap'])[np['ref']]: np,
    };
    return (String pid) {
      if (kg.people.containsKey(pid)) return kg.describe(pid);
      final Json np = intro[pid] ?? {};
      return "${np['name'] ?? ''}（${np['intro'] ?? '本段新出场'}）";
    };
  }

  Future<void> verifyCritical(
    Json data,
    Json localData,
    Json linkRec,
    String text,
    Json guard,
  ) async {
    final Json names = {}, role = {};
    for (final Json lp in _rows(localData['people'])) {
      final Json d = _obj(_obj(linkRec['decisions'])[pyStr(lp['id'])]);
      final String id = _str(d['to'], 'N${pyStr(lp['id'])}');
      names[id] = _str(lp['name']);
      role[id] = _str(lp['role']);
    }
    String nm(Object? x) =>
        _str(names[x], _str(kg.people[x]?['name'], pyStr(x)));
    final Json items = {};
    for (final (int i, Json e) in _rows(data['events']).indexed) {
      if (judge.critical.hasMatch(_str(e['text']))) items['e$i'] = e['text'];
    }
    for (final (int i, Json a) in _rows(data['attrs']).indexed) {
      if (lang.lifeKeys.contains(_str(a['key']).toLowerCase()) ||
          judge.critical.hasMatch(_str(a['value'])))
        items['a$i'] = '${nm(a['who'])}：${pyStr(a['value'])}';
    }
    for (final (int i, Json r) in _rows(data['rels']).indexed) {
      if (pyRe(
        '妻|夫|妾|姨娘|二房|wife|husband|spouse|fianc|betrothed|bride|groom',
        ignoreCase: true,
      ).hasMatch('${r['a_is'] ?? ''}${r['b_is'] ?? ''}'))
        items['r$i'] = "${nm(r['b'])}是${nm(r['a'])}的${pyStr(r['b_is'])}";
    }
    if (items.isNotEmpty) {
      final Json v = await judge.checkCritical(text, items);
      if (items.keys.any(
        (k) =>
            !v.containsKey(k) ||
            _obj(v[k])['fact'] is! num && _obj(v[k])['fact'] is! bool,
      ))
        throw const llm.LLMError('关键事实缺少有效验证结果');
      guard['critical'] = v;
      usage['jev_calls'] = _int(usage['jev_calls']) + 1;
      final Set<String> drop = {
        for (final entry in v.entries)
          if (_num(_obj(entry.value)['fact']) < 0.5) entry.key,
      };
      for (final (String field, String prefix) in [
        ('events', 'e'),
        ('attrs', 'a'),
        ('rels', 'r'),
      ]) {
        data[field] = [
          for (final (int i, Json r) in _rows(data[field]).indexed)
            if (!drop.contains('$prefix$i')) r,
        ];
      }
    }
    checkpoint();
    String known(Object? x) =>
        _str(kg.people[x]?['tagline'], _str(kg.people[x]?['intro']));
    final List<Json> merges = _rows(data['merges']);
    if (merges.isNotEmpty) {
      final Map<String, List<String>> pairs = {
        for (final (int i, Json m) in merges.indexed)
          '$i': [
            nm(m['from']),
            nm(m['into']),
            _str(known(m['from']), _str(role[m['from']])),
            _str(known(m['into']), _str(role[m['into']])),
          ],
      };
      final Json v = await judge.checkSame(text, pairs);
      guard['merges'] = v;
      usage['jev_calls'] = _int(usage['jev_calls']) + 1;
      data['merges'] = [
        for (final (int i, Json m) in merges.indexed)
          if (_num(_obj(v['$i'])['same']) >= 0.7) m,
      ];
    }
  }

  Future<Json> link(int i, Json localRec) async {
    final Json seg = segs[i];
    final String text = extraction.segText(book, seg);
    final double start = backend.now();
    final (Json localData, List<List<Object?>> dropped) = dropUnsupported(
      _obj(localRec['data']),
      _obj(localRec['support']),
    );
    final (Json data, Json linkRec) = await linking.linkSegment(
      kg,
      seg,
      localData,
      text,
      scopeStart: scopeStart(_int(seg['o0'])),
    );
    final Json guard = {
      'checks': <String, Object?>{},
      'rewrites': <String, Object?>{},
    };
    try {
      await verifyCritical(data, _obj(localRec['data']), linkRec, text, guard);
    } on Cancelled {
      rethrow;
    } catch (e) {
      guard['critical_error'] = _cut(_error(e), 200);
      writeJson(
        File('${work.path}/verification/${i.toString().padLeft(4, '0')}.json'),
        {
          'state': 'failed',
          'stage': 'critical',
          'error': _cut(_error(e), 300),
          'seg': i,
        },
      );
      throw llm.LLMError('第 $i 段关键事实尚未验证，已保留抽取缓存：${_error(e)}');
    }
    checkpoint();
    final Json plan = kg.plan(seg, data);
    final Json intros = {
      for (final Json np in _rows(data['new_people']))
        if (_truth(np['intro'])) np['ref']! as String: np['intro'],
    };
    if (intros.isNotEmpty) {
      try {
        final Json v = await judge.guardTexts(text, {}, {
          for (final entry in intros.entries) 'intro:${entry.key}': entry.value,
        });
        if (intros.keys.any(
          (k) => !['ok', 'flag'].contains(_obj(v['intro:$k'])['verdict']),
        ))
          throw const llm.LLMError('人物简介缺少有效验证结果');
        for (final entry in v.entries) {
          if (_obj(entry.value)['verdict'] == 'flag') {
            final String ref = entry.key.substring(entry.key.indexOf(':') + 1);
            _obj(guard['rewrites'])[entry.key] = intros[ref];
            for (final Json np in _rows(data['new_people'])) {
              if (np['ref'] == ref) np['intro'] = '';
            }
            data['profiles'] =
                _rows(
                  data['profiles'],
                ).where((pr) => pr['who'] != ref).toList();
          }
        }
        usage['jev_calls'] = _int(usage['jev_calls']) + 1;
      } on Cancelled {
        rethrow;
      } catch (e) {
        guard['error'] = _cut(_error(e), 200);
        writeJson(
          File(
            '${work.path}/verification/${i.toString().padLeft(4, '0')}.json',
          ),
          {
            'state': 'failed',
            'stage': 'intro',
            'error': _cut(_error(e), 300),
            'seg': i,
          },
        );
        throw llm.LLMError('第 $i 段人物简介尚未验证：${_error(e)}');
      }
    }
    checkpoint();
    Json decisions;
    Object? raw;
    try {
      (decisions, raw) = await judge.resolveMentions(
        book,
        seg,
        _rows(plan['occs']),
        describeFactory(data, plan),
      );
      usage['jev_calls'] =
          _int(usage['jev_calls']) +
          (_rows(plan['occs']).where((o) => _truth(o['ambiguous'])).length +
                  15) ~/
              16;
    } on Cancelled {
      rethrow;
    } catch (e) {
      decisions = {};
      raw = {'error': _cut(_error(e), 200)};
    }
    if (_rows(plan['occs']).every((o) => !_truth(o['ambiguous'])))
      raw = <Object?>[];
    final Json rec = {
      'seg': i,
      'o0': seg['o0'],
      'o1': seg['o1'],
      'mode': 'two-phase',
      'model': localRec['model'],
      'provenance': {'schema': provenanceSchema, 'input_sha256': inputSha256},
      'data': data,
      'link': linkRec,
      'decisions': decisions,
      'jev_raw': raw,
      'guard': guard,
      'dropped': dropped,
      'timing': {
        'local': localRec['seconds'],
        'link': PyCompat.roundDigits(backend.now() - start, 1),
      },
    };
    writeJson(segPath(i), rec);
    writeJson(
      File('${work.path}/verification/${i.toString().padLeft(4, '0')}.json'),
      {'state': 'complete', 'seg': i},
    );
    return rec;
  }

  Future<void> markTitles() async {
    final List<Json> chapters = _rows(book['chapters']);
    if ((environ['JUDGE_TITLES'] ?? '1') != '1' ||
        chapters.every((c) => c.containsKey('spoil')) &&
            !qualityPending.contains('chapter-titles'))
      return;
    final List<bool> spoils = await judge.titleSpoilers([
      for (int i = 0; i < chapters.length; i++) chapterName(i),
    ], _str(book['title']));
    if (spoils.length != chapters.length)
      throw const llm.LLMError('章节标题验证结果不完整');
    for (final (int i, Json c) in chapters.indexed) {
      c['spoil'] = spoils[i];
    }
    usage['jev_calls'] =
        _int(usage['jev_calls']) +
        (chapters.length + judge.batch - 1) ~/ judge.batch;
    qualityPending.remove('chapter-titles');
    writeJson(File('${root.path}/book.json'), book);
  }
}
