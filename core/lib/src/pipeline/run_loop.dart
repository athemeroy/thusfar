part of 'run.dart';

/// Judge routes wrap transport errors before title classification sees them.
/// Match only their known wrappers, never arbitrary text from a chapter title
/// or an invalid model answer.
bool _retryableTitleError(Object error) {
  if (llm.transientFailure(error)) return true;
  if (error is! llm.LLMError) return false;
  String detail = error.message;
  if (detail.startsWith('免费裁判处于冷却期，未调用付费接口') ||
      detail.startsWith('classifier.dev 暂时跳过（连续失败，冷却中）')) {
    return true;
  }
  const List<String> wrappers = <String>[
    '免费裁判暂不可用，未调用付费接口：',
    'classifier.dev 调用失败：',
    'Jev 调用失败：',
    '本地裁判失败，未调用付费接口：',
  ];
  bool wrapped = false;
  for (int depth = 0; depth < 3; depth++) {
    if (detail.startsWith('LLMError: ')) {
      detail = detail.substring('LLMError: '.length);
      continue;
    }
    final String? wrapper = wrappers.where(detail.startsWith).firstOrNull;
    if (wrapper == null) break;
    wrapped = true;
    detail = detail.substring(wrapper.length);
  }
  if (!wrapped) return false;
  return RegExp(
    r'^(?:(?:classifier\.dev|Jev) HTTP (?:408|429|5\d\d)\b|HTTP (?:408|429|5\d\d)\b|TimeoutError\b|TimeoutException\b|ConnectionError\b|SocketException\b|HandshakeException\b|HttpException\b|OSError: (?:HttpException|HandshakeException)\b)',
    caseSensitive: false,
  ).hasMatch(detail);
}

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
    } on llm.UnknownOutcomeLLMError {
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
        } on llm.UnknownOutcomeLLMError {
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
    } on llm.UnknownOutcomeLLMError {
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
    } on llm.UnknownOutcomeLLMError {
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
    replayReadOnly = limit == 0;
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
    status(completedState(done), done);
    int processed = 0;
    for (int i = done; i < targetSegments; i++) {
      checkpoint();
      if (limit != null && processed >= limit) break;
      Json? rec;
      for (int attempt = 0; attempt < 3; attempt++) {
        try {
          rec = await process(i);
          break;
        } on Cancelled {
          rethrow;
        } on llm.UnknownOutcomeLLMError {
          rethrow;
        } on FileSystemException {
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
      status(completedState(done), done);
    }
  }

  Future<void> run2({int? limit, int concurrency = 12, String? model}) async {
    replayReadOnly = limit == 0;
    if (concurrency < 1) throw const ValueError('并发数必须大于 0');
    if (limit != 0 && _truth(repairPolicy['identity_taint']))
      throw const llm.LLMError('人物关联结果已隔离，请显式重试质量检查后继续处理');
    final String extractionModel = model ?? local.localModel;
    twoPhase = true;
    Future<void> waitForFinalJobs(
      Iterable<Future<Object?>> jobs,
      int completed,
    ) async {
      final List<Future<Object?>> remaining = jobs.toList();
      if (remaining.isEmpty) return;
      final double startedAt = backend.now();
      final Stopwatch waiting = Stopwatch()..start();
      void heartbeat() {
        if (!activity) return;
        recordBookActivity(
          root,
          'stage_heartbeat',
          '正在核对人物与章节资料，已 ${waiting.elapsed.inMinutes} 分钟',
          done: completed,
          total: segs.length,
          stage: 'finalize',
          startedAt: startedAt,
          at: backend.now(),
        );
      }

      heartbeat();
      final Timer timer = Timer.periodic(
        const Duration(minutes: 1),
        (_) => heartbeat(),
      );
      try {
        for (final Future<Object?> job in remaining) {
          await awaitFuture(job);
        }
      } finally {
        timer.cancel();
      }
    }

    try {
      if (limit != 0) await markTitles();
    } on Cancelled {
      rethrow;
    } on llm.UnknownOutcomeLLMError {
      rethrow;
    } catch (error) {
      qualityPending.add('chapter-titles');
      writeJson(File('${root.path}/book.json'), book);
      if (activity) {
        recordBookActivity(
          root,
          'check_titles_pending',
          '章节标题核对未完成，仅明显剧透的标题暂时隐藏；继续整理时将重试',
        );
      }
      // A temporary provider or network outage must keep the task eligible
      // for the worker's durable retry. The UI applies a local fallback to
      // unknown titles without treating the fallback as a model verdict.
      if (_retryableTitleError(error)) {
        if (llm.transientFailure(error)) rethrow;
        throw llm.TransientLLMError(
          error is llm.LLMError ? error.message : '$error',
        );
      }
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
      if (activity && pending.isNotEmpty) {
        recordBookActivity(root, 'resume_final_jobs', '正在恢复未完成的章节资料');
      }
      resumeFinalJobs();
      if (pending.isNotEmpty) status('finalizing', done);
      await waitForFinalJobs(pending, done);
    }
    int finalized = pending.length;
    publish();
    status(
      done < targetSegments
          ? 'running'
          : pending.isNotEmpty
          ? 'finalizing'
          : completedState(done),
      done,
    );
    final int end =
        limit == null ? targetSegments : math.min(targetSegments, done + limit);
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
      String stage = 'extract';
      double stageStarted = backend.now();
      final Stopwatch stageClock = Stopwatch()..start();
      void heartbeat() {
        if (!activity) return;
        final String action = switch (stage) {
          'relation' => '关联人物',
          'recap' => '整理前情',
          'finalize' => '核对章节资料',
          _ => '等待模型抽取',
        };
        recordBookActivity(
          root,
          'stage_heartbeat',
          '第 ${i + 1} 段正在$action，已 ${stageClock.elapsed.inMinutes} 分钟',
          done: i,
          total: segs.length,
          segment: i + 1,
          stage: stage,
          startedAt: stageStarted,
          at: backend.now(),
        );
      }

      void nextStage(String value) {
        stage = value;
        stageStarted = backend.now();
        stageClock.reset();
        heartbeat();
      }

      heartbeat();
      final Timer timer = Timer.periodic(
        const Duration(minutes: 1),
        (_) => heartbeat(),
      );
      try {
        final Json localRec = await awaitFuture(futures[i]!);
        checkpoint();
        nextStage('relation');
        final Json rec = await link(i, localRec);
        checkpoint();
        apply(rec);
        nextStage('recap');
        await maybeRecap(i);
        nextStage('finalize');
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
          retryable: llm.transientFailure(e),
        );
        localPool!.stopped = true;
        rethrow;
      } finally {
        timer.cancel();
      }
      done = i + 1;
      if (done % 3 == 0 || done == end) publish();
      status(done < targetSegments ? 'running' : 'finalizing', done);
    }
    await localPool!.close();
    await waitForFinalJobs(pending.skip(finalized), done);
    publish();
    if (done == segs.length && limit != 0) finishQualityRetry();
    status(completedState(done), done);
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
  final RunCancellation token = cancellation ?? RunCancellation();
  final ModelRequestScope scope = ModelRequestScope(root);
  await token.run(
    () => scope.run(
      () => _runBook(
        root,
        model: model,
        limit: limit,
        classic: classic,
        retryQuality: retryQuality,
        localModel: localModel,
        concurrency: concurrency,
        cancellation: token,
        backend: backend,
        onProgress: onProgress,
      ),
    ),
  );
}

Future<void> _runBook(
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
  bool drained = false;
  try {
    cancellation?.checkpoint();
    if (hasUnsettledModelRequests(root)) {
      throw const llm.UnknownOutcomeLLMError('interrupted_before_commit');
    }
    runner = await Runner.create(
      root,
      model: model,
      cancellation: cancellation,
      backend: backend,
      onProgress: onProgress,
      activity: limit != 0,
    );
    final bool useClassic =
        classic ||
        (runner.segPath(0).existsSync() &&
            _read(runner.segPath(0))['mode'] != 'two-phase');
    final File retry = File('${runner.work.path}/quality-retry.json');
    final bool rebuildingQuality =
        retryQuality ||
        retry.existsSync() &&
            <String>{'archiving', 'rebuilding'}.contains(_read(retry)['state']);
    if (rebuildingQuality &&
        runner.planEndOffset != null &&
        runner.planEndOffset! < _int(runner.book['len'])) {
      throw const llm.LLMError('当前范围不能重建全书关联；请扩大范围后再重试质量检查');
    }
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
        'quality': {
          'state': runner.qualityPending.isNotEmpty ? 'pending' : 'verified',
          'pending': _sorted(runner.qualityPending),
        },
      });
      writeJson(path, state, compact: false);
      onProgress?.call(state);
    }
    rethrow;
  } catch (e) {
    failed = true;
    final File path = File('${root.path}/status.json');
    final Json state = path.existsSync() ? _read(path) : {};
    if (runner != null) {
      state['quality'] = {
        'state': runner.qualityPending.isNotEmpty ? 'pending' : 'verified',
        'pending': _sorted(runner.qualityPending),
      };
    }
    state.addAll({
      'state': 'error',
      'error': _cut(e is llm.LLMError ? _error(e) : _typedError(e), 300),
      'retryable':
          e is! llm.UnknownOutcomeLLMError &&
          !(ModelRequestScope.current?.hasUnknown ?? false) &&
          (state['retryable'] == true || llm.transientFailure(e)),
      if (e is llm.UnknownOutcomeLLMError) 'failure_code': e.code,
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
        drained = true;
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
          state['quality'] = {
            'state': runner.qualityPending.isNotEmpty ? 'pending' : 'verified',
            'pending': _sorted(runner.qualityPending),
          };
          state['updated'] = backend.now();
          writeJson(path, state, compact: false);
          onProgress?.call(state);
        }
      }
    } finally {
      try {
        final ModelRequestScope? scope = ModelRequestScope.current;
        scope?.settle(receivedCommitted: drained && !failed && !cancelled);
        if (hasUnsettledModelRequests(root)) {
          final File path = File('${root.path}/status.json');
          final Json state = path.existsSync() ? _read(path) : {};
          state.addAll(<String, Object?>{
            'state': 'paused',
            'pause_reason': 'request_outcome_unknown',
            'retryable': false,
            'request_outcome': 'unknown',
            // A received but uncommitted response still requires explicit
            // resume, but must not hide the validation/storage failure.
            'error':
                _truth(state['error'])
                    ? state['error']
                    : const llm.UnknownOutcomeLLMError(
                      'interrupted_before_commit',
                    ).message,
            'updated': backend.now(),
          });
          state.remove('retry_at');
          writeJson(path, state, compact: false);
          onProgress?.call(state);
        }
      } finally {
        lease.release();
      }
    }
  }
}
