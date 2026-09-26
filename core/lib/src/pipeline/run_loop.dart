part of 'run.dart';

extension RunnerLoops on Runner {
  Future<Json> process(int i) async {
    final Json seg = segs[i], state = kg.promptState();
    final double start = backend.now();
    final File path = File(
      '${work.path}/classic_raw/${i.toString().padLeft(4, '0')}.json',
    );
    final Json data, tokens;
    if (path.existsSync()) {
      final Json cached = _read(path);
      if (cached['input_sha256'] != inputSha256 || cached['model'] != model)
        throw const llm.LLMError('经典抽取缓存来源不符');
      data = _obj(cached['data']);
      tokens = _obj(cached['usage']);
    } else {
      (data, tokens) = await backend.extractClassic(book, state, seg, model);
      count(model, tokens);
      writeJson(path, {
        'model': model,
        'input_sha256': inputSha256,
        'data': data,
        'usage': tokens,
      });
    }
    checkpoint();
    final double extracted = backend.now();
    final Json plan = kg.plan(seg, data);
    final String text = extraction.segText(book, seg);
    final Json items = {}, earlier = {};
    final Json intros = {
      for (final Json p in _rows(data['new_people']))
        pyStr(p['ref']): p['intro'],
    };
    for (final Json p in _rows(data['profiles'])) {
      final String who = pyStr(p['who']);
      items[who] = '${p['tagline'] ?? ''}。${p['bio'] ?? ''}';
      final String? id = kg.lookup(who, _obj(plan['refmap']));
      if (kg.people.containsKey(id) && _truth(kg.people[id]!['bio']))
        earlier[who] = kg.people[id]!['bio'];
    }
    for (final e in intros.entries) {
      if (_truth(e.value) && !items.containsKey('intro:${e.key}'))
        items['intro:${e.key}'] = e.value;
    }
    final Json guard = {
          'checks': <String, Object?>{},
          'rewrites': <String, Object?>{},
        },
        verdicts;
    try {
      verdicts = await judge.guardTexts(text, earlier, items);
      usage['jev_calls'] = _int(usage['jev_calls']) + 1;
    } on Cancelled {
      rethrow;
    } catch (e) {
      throw llm.LLMError('第 $i 段人物描述验证失败，已保留抽取缓存：${_error(e)}');
    }
    checkpoint();
    if (items.keys.any(
      (k) => !['ok', 'flag'].contains(_obj(verdicts[k])['verdict']),
    ))
      throw const llm.LLMError('人物描述缺少有效验证结果');
    for (final Json p in _rows(data['profiles'])) {
      final String who = pyStr(p['who']);
      final Json v = _obj(verdicts[who]);
      if (v.isEmpty) continue;
      _obj(guard['checks'])[who] = {'jev': v['p'], 'verdict': v['verdict']};
      if (v['verdict'] == 'flag') {
        try {
          final Json fixed = _obj(
            await cachedGeneration(
              'rewrite-$i-$who',
              model,
              [
                {
                  'role': 'user',
                  'content': _fmt(prompts.rewrite, {
                    'old': _str(earlier[who], '（无）'),
                    'text': text,
                    'tagline': p['tagline'] ?? '',
                    'bio': p['bio'] ?? '',
                  }),
                },
              ],
              maxTokens: 1500,
              temperature: 0.1,
              jsonOutput: true,
            ),
          );
          _obj(guard['rewrites'])[who] = {
            'before': {'tagline': p['tagline'], 'bio': p['bio']},
          };
          p['tagline'] =
              _truth(fixed['tagline']) ? fixed['tagline'] : p['tagline'];
          p['bio'] = _truth(fixed['bio']) ? fixed['bio'] : p['bio'];
          final Json again = _obj(
            (await judge.guardTexts(text, earlier, {
              who: '${p['tagline']}。${p['bio']}',
            }))[who],
          );
          if (!['ok', 'flag'].contains(again['verdict']))
            throw const llm.LLMError('重写后的人物描述缺少有效验证结果');
          _obj(guard['checks'])[who] = {
            'jev': again['p'],
            'verdict': again['verdict'] == 'ok' ? 'rewritten' : 'withheld',
            'first': v['p'],
            'after_verdict': again['verdict'],
            'verified': true,
          };
          if (again['verdict'] == 'flag') p['_withheld'] = true;
        } on Cancelled {
          rethrow;
        } catch (e) {
          throw llm.LLMError('人物描述重写尚未验证：${_error(e)}');
        }
      }
    }
    checkpoint();
    data['profiles'] =
        _rows(
          data['profiles'],
        ).where((p) => p.remove('_withheld') != true).toList();
    for (final String ref in intros.keys) {
      if (_obj(verdicts['intro:$ref'])['verdict'] == 'flag') {
        for (final Json p in _rows(data['new_people'])) {
          if (p['ref'] == ref) {
            _obj(guard['rewrites'])['intro:$ref'] = p['intro'];
            p['intro'] = '';
          }
        }
      }
    }
    try {
      final Json names = {
            for (final Json p in _rows(data['new_people']))
              pyStr(p['ref']): p['name'],
          },
          newIntros = {
            for (final Json p in _rows(data['new_people']))
              pyStr(p['ref']): p['intro'],
          };
      (String, String) whoOf(Object? w) {
        if (names.containsKey(w))
          return (_str(names[w]), _str(newIntros[w], '本段新出场的人物'));
        final Json p = kg.people[kg.lookup(w, _obj(plan['refmap']))] ?? {};
        return (
          _str(p['name'], pyStr(w)),
          _str(p['tagline'], _str(p['intro'])),
        );
      }

      guard['attrs'] = await checkAttrs(text, data, whoOf);
      usage['jev_calls'] = _int(usage['jev_calls']) + 1;
    } on Cancelled {
      rethrow;
    } catch (e) {
      guard['attrs_error'] = _cut(_error(e), 200);
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
    final Json record = {
      'seg': i,
      'o0': seg['o0'],
      'o1': seg['o1'],
      'model': model,
      'data': data,
      'raw': tokens['_raw'],
      'decisions': decisions,
      'jev_raw': raw,
      'guard': guard,
      'timing': {
        'llm': PyCompat.roundDigits(extracted - start, 1),
        'total': PyCompat.roundDigits(backend.now() - start, 1),
      },
      'usage': {
        'prompt': tokens['prompt_tokens'],
        'completion': tokens['completion_tokens'],
      },
    };
    writeJson(segPath(i), record);
    return record;
  }

  Future<void> run({int? limit}) async {
    if (limit != 0 && _truth(repairPolicy['identity_taint']))
      throw const llm.LLMError('人物关联结果已隔离，请显式重试质量检查后继续处理');
    int done = 0;
    replaying = true;
    for (int i = 0; i < segs.length; i++) {
      checkpoint();
      final File path = segPath(i);
      if (!path.existsSync()) break;
      apply(_read(path));
      await maybeRecap(i);
      done = i + 1;
    }
    replaying = false;
    if (limit != 0) {
      resumeFinalJobs();
      for (final Future<Object?> f in pending) {
        await awaitFuture(f);
      }
    }
    int finalized = pending.length;
    if (done == segs.length && limit != 0) finishQualityRetry();
    publish();
    status(done < segs.length ? 'running' : 'done', done);
    int processed = 0;
    for (int i = done; i < segs.length; i++) {
      checkpoint();
      if (limit != null && processed >= limit) break;
      Json? rec;
      for (int attempt = 0; attempt < 3; attempt++) {
        try {
          rec = await process(i);
          break;
        } on Cancelled {
          rethrow;
        } catch (e) {
          status('running', i, error: _cut(_error(e), 300));
          await awaitFuture(
            backend.sleep(Duration(seconds: 20 * (attempt + 1))),
          );
        }
      }
      if (rec == null) {
        status('error', i, error: '连续失败，已暂停');
        return;
      }
      checkpoint();
      apply(rec);
      await maybeRecap(i);
      for (final Future<Object?> f in pending.skip(finalized)) {
        await awaitFuture(f);
      }
      finalized = pending.length;
      publish();
      done = i + 1;
      processed++;
      if (done == segs.length) finishQualityRetry();
      status(done < segs.length ? 'running' : 'done', done);
    }
  }

  Future<void> run2({int? limit, int concurrency = 12, String? model}) async {
    if (concurrency < 1) throw const ValueError('并发数必须大于 0');
    if (limit != 0 && _truth(repairPolicy['identity_taint']))
      throw const llm.LLMError('人物关联结果已隔离，请显式重试质量检查后继续处理');
    final String extractionModel = model ?? local.localModel;
    twoPhase = true;
    try {
      if (limit != 0) await markTitles();
    } on Cancelled {
      rethrow;
    } catch (_) {
      for (final Json chapter in _rows(book['chapters'])) {
        chapter.putIfAbsent('spoil', () => true);
      }
      qualityPending.add('chapter-titles');
      writeJson(File('${root.path}/book.json'), book);
    }
    int done = 0;
    replaying = true;
    for (int i = 0; i < segs.length; i++) {
      checkpoint();
      final File path = segPath(i);
      if (!path.existsSync()) break;
      apply(_read(path));
      await maybeRecap(i);
      done = i + 1;
    }
    replaying = false;
    if (limit != 0) {
      resumeFinalJobs();
      for (final Future<Object?> f in pending) {
        await awaitFuture(f);
      }
    }
    int finalized = pending.length;
    publish();
    status(
      done < segs.length
          ? 'running'
          : pending.isNotEmpty
          ? 'finalizing'
          : 'done',
      done,
    );
    final int end =
        limit == null ? segs.length : math.min(segs.length, done + limit);
    localPool = _RunPool(concurrency);
    final Map<int, Future<Json>> futures = {};
    int nextJob = done;
    void submitUpto(int k, int current) {
      checkpoint();
      int cap = math.min(end, k + 1);
      for (int j = current + 1; j < cap; j++) {
        if (segs[j]['chapter'] != segs[current]['chapter']) {
          cap = j;
          break;
        }
      }
      if (nextJob >= cap) return;
      final String hint = castHint();
      final Json memory = relationMemory();
      while (nextJob < cap) {
        final int j = nextJob;
        futures[j] = localPool!.submit(
          () => localJob(j, extractionModel, hint, memory),
        );
        nextJob++;
      }
    }

    if (done < end) {
      submitUpto(done + concurrency - 1, done);
      notify(
        '已把 ${nextJob - done} 段发给 ${extractionModel.split('+').first}，正在等它回复；每整理完一段，进度会更新',
      );
    }
    for (int i = done; i < end; i++) {
      checkpoint();
      submitUpto(i + concurrency - 1, i);
      try {
        final Json localRec = await awaitFuture(futures[i]!);
        checkpoint();
        final Json rec = await link(i, localRec);
        checkpoint();
        apply(rec);
        await maybeRecap(i);
        for (final Future<Object?> f in pending.skip(finalized)) {
          await awaitFuture(f);
        }
        finalized = pending.length;
      } on Cancelled {
        localPool!.stopped = true;
        rethrow;
      } catch (e) {
        status(
          'error',
          i,
          error: _cut(e is llm.LLMError ? _error(e) : _typedError(e), 300),
        );
        localPool!.stopped = true;
        rethrow;
      }
      done = i + 1;
      if (done % 3 == 0 || done == end) publish();
      status(done < segs.length ? 'running' : 'finalizing', done);
    }
    await localPool!.close();
    for (final Future<Object?> f in pending) {
      await awaitFuture(f);
    }
    publish();
    if (done == segs.length && limit != 0) finishQualityRetry();
    status(done < segs.length ? 'running' : 'done', done);
  }
}

Future<void> runBook(
  Directory root, {
  String? model,
  int? limit,
  bool classic = false,
  bool retryQuality = false,
  String? localModel,
  int concurrency = 12,
  RunCancellation? cancellation,
  RunBackend backend = const RunBackend(),
  void Function(Json)? onProgress,
}) async {
  final RunLease lease = await RunLease.acquire(root);
  Runner? runner;
  bool cancelled = false;
  bool failed = false;
  try {
    cancellation?.checkpoint();
    runner = await Runner.create(
      root,
      model: model,
      cancellation: cancellation,
      backend: backend,
      onProgress: onProgress,
    );
    final bool useClassic =
        classic ||
        (runner.segPath(0).existsSync() &&
            _read(runner.segPath(0))['mode'] != 'two-phase');
    final File retry = File('${runner.work.path}/quality-retry.json');
    if (retryQuality ||
        retry.existsSync() && _read(retry)['state'] == 'archiving')
      runner.prepareQualityRetry();
    if (useClassic) {
      await runner.run(limit: limit);
    } else {
      await runner.run2(
        limit: limit,
        concurrency: concurrency,
        model: localModel,
      );
    }
    final Json state = _read(File('${root.path}/status.json'));
    if (state['state'] == 'error')
      throw StateError(_str(state['error'], '书籍处理失败'));
  } on Cancelled {
    cancelled = true;
    if (runner != null) {
      final File path = File('${root.path}/status.json');
      final Json state = path.existsSync() ? _read(path) : {};
      state.addAll({
        'state': 'paused',
        'updated': backend.now(),
        'error': null,
      });
      writeJson(path, state, compact: false);
      onProgress?.call(state);
    }
    rethrow;
  } catch (e) {
    failed = true;
    final File path = File('${root.path}/status.json');
    final Json state = path.existsSync() ? _read(path) : {};
    state.addAll({
      'state': 'error',
      'error': _cut(e is llm.LLMError ? _error(e) : _typedError(e), 300),
      'notice': null,
      'updated': backend.now(),
    });
    writeJson(path, state, compact: false);
    onProgress?.call(state);
    rethrow;
  } finally {
    try {
      if (runner != null) {
        await runner.close(cancelled: cancelled);
        // Requests already in flight retain their successful draft and usage
        // while draining. Publish that final accounting before releasing the
        // lease; the paused/error state and reading frontier remain unchanged.
        if (cancelled || failed) {
          runner.usage['jev'] = {...jevClient.jevStats};
          final Json usage = _clone(runner.usage)! as Json;
          writeJson(runner.usagePath, usage, compact: false);
          final File path = File('${root.path}/status.json');
          final Json state = path.existsSync() ? _read(path) : {};
          state['usage'] = usage;
          state['updated'] = backend.now();
          writeJson(path, state, compact: false);
          onProgress?.call(state);
        }
      }
    } finally {
      lease.release();
    }
  }
}
