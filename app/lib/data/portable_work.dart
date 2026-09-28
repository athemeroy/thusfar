import 'dart:convert';

/// JSON work checkpoints that can resume book-local preparation. Paths are
/// relative to a book's `work` directory and never accept arbitrary files.
const int maxPortableWorkFiles = 12000;
const int maxPortableWorkBytes = 64 * 1024 * 1024;
const int maxPortableWorkFileBytes = 4 * 1024 * 1024;

const Set<String> portableWorkDirectories = <String>{
  'jobs',
  'drafts',
  'segs',
  'recaps',
  'bios',
  'sagas',
  'dedupe',
  'local',
  'classic_raw',
  'verification',
  'finalize',
  'judge',
};

const Set<String> portableWorkRootFiles = <String>{
  'usage.json',
  'repair-policy.json',
  'quality-retry.json',
  'cache-manifest.json',
  'activity.json',
  'worker-receipt.json',
};
const Set<String> _judgeFiles = <String>{
  'judge/paid-budget.json',
  'judge/model-budget.json',
};
final RegExp _judgeCachePath = RegExp(r'^judge/cache/([0-9a-f]{64})\.json$');

final RegExp _filename = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\.json$');
final RegExp _draft = RegExp(
  r'^drafts/[A-Za-z0-9][A-Za-z0-9_.-]*-([0-9a-f]{64})\.json$',
);
final RegExp _job = RegExp(
  r'^jobs/(bio|recap|classic-recap|saga)-([0-9]+)\.json$',
);
const Set<String> _jobFields = <String>{
  'kind',
  'key',
  'args',
  'state',
  'content_failures',
  'generation_attempt',
  'retry_requested',
  'failure_kind',
  'bio_review',
  'error',
};
const Set<String> _credentialKeys = <String>{
  'apikey',
  'auth',
  'headers',
  'bearer',
  'authorization',
  'password',
  'secret',
  'credential',
  'token',
  'clientsecret',
  'privatekey',
  'bearertoken',
};
final RegExp _credentialText = RegExp(
  r'\b(?:Bearer\s+\S{12,}|sk-[A-Za-z0-9_-]{12,}|gsk_[A-Za-z0-9_-]{12,}|AIza[A-Za-z0-9_-]{20,}|(?:api[_-]?key|access[_-]?token|refresh[_-]?token|authorization|client[_-]?secret|password)\s*[:=]\s*\S{8,})',
  caseSensitive: false,
);

bool isPortableWorkPath(String path) {
  if (portableWorkRootFiles.contains(path)) return true;
  if (path.startsWith('judge/cache/')) return _judgeCachePath.hasMatch(path);
  if (path.startsWith('judge/')) return _judgeFiles.contains(path);
  final List<String> parts = path.split('/');
  return parts.length == 2 &&
      portableWorkDirectories.contains(parts.first) &&
      _filename.hasMatch(parts.last);
}

Map<String, Object?> validatedPortableWork(Object? raw) {
  if (raw == null) return <String, Object?>{};
  if (raw is! Map<String, Object?> || raw.length > maxPortableWorkFiles) {
    throw const FormatException('书籍整理缓存格式无效。');
  }
  int total = 0;
  final Map<String, Object?> result = <String, Object?>{};
  for (final MapEntry<String, Object?> row in raw.entries) {
    final String path = row.key;
    final Object? value = row.value;
    if (!isPortableWorkPath(path) ||
        value is! Map<String, Object?> && value is! List<Object?>) {
      throw const FormatException('书籍整理缓存路径或内容无效。');
    }
    _rejectCredentials(value, 0, source: path);
    final int size = utf8.encode(jsonEncode(value)).length;
    total += size;
    if (size > maxPortableWorkFileBytes || total > maxPortableWorkBytes) {
      throw const FormatException('书籍整理缓存超过备份上限。');
    }
    if (path == 'quality-retry.json' &&
        value is Map<String, Object?> &&
        const <String>{'archiving', 'rebuilding'}.contains(value['state'])) {
      throw const FormatException('质量重试正在归档或重建，请结束后再导出完整书库。');
    }
    if (_judgeFiles.contains(path)) {
      if (value is! Map<String, Object?>) {
        throw const FormatException('付费判断预算记录无效。');
      }
      final Set<String> allowed = path == 'judge/paid-budget.json'
          ? const <String>{
              'version',
              'calls',
              'chars',
              'questions',
              'top_up_calls',
              'top_up_chars',
              'max_calls',
              'max_chars',
            }
          : const <String>{
              'version',
              'calls',
              'chars',
              'questions',
              'model_calls',
              'model_prompt_tokens',
              'model_completion_tokens',
              'model_cost_low',
              'model_cost_high',
              'max_calls',
              'max_chars',
            };
      if (value.keys.any((String key) => !allowed.contains(key)) ||
          value['version'] != null && value['version'] != 1) {
        throw const FormatException('付费判断预算记录无效。');
      }
      for (final MapEntry<String, Object?> field in value.entries) {
        if (field.key == 'version') continue;
        if (const <String>{
          'model_cost_low',
          'model_cost_high',
        }.contains(field.key)) {
          if (field.value is! num ||
              !(field.value as num).isFinite ||
              (field.value as num) < 0) {
            throw const FormatException('付费判断费用记录无效。');
          }
        } else if (field.value is! int ||
            (field.value as int) < 0 ||
            (field.value as int) > 1000000000000000) {
          throw const FormatException('付费判断预算计数无效。');
        }
      }
    }
    if (path.startsWith('judge/cache/')) {
      final RegExpMatch? match = _judgeCachePath.firstMatch(path);
      if (match == null ||
          value is! Map<String, Object?> ||
          value.keys.toSet().difference(const <String>{
            'request_sha256',
            'answers',
            'route',
            'model',
          }).isNotEmpty ||
          value['request_sha256'] != match.group(1) ||
          value['answers'] is! Map<String, Object?> ||
          value['route'] is! String ||
          (value['route'] as String).isEmpty ||
          (value['route'] as String).length > 64 ||
          value['model'] is! String ||
          (value['model'] as String).length > 200) {
        throw const FormatException('模型判断缓存无效。');
      }
    }
    if (path == 'worker-receipt.json') {
      if (value is! Map<String, Object?> ||
          value.keys.toSet().difference(const <String>{
            'schema',
            'book',
            'request_id',
            'requested_at',
            'attempt',
            'phase',
            'updated',
            'pause_reason',
            'reason',
            'owner_pid',
            'error',
            'model',
            'local_model',
            'concurrency',
            'retry_quality',
            'exit_code',
            'finished_at',
          }).isNotEmpty ||
          value['schema'] != 1 ||
          value['request_id'] is! String ||
          (value['request_id'] as String).length > 128 ||
          value['phase'] is! String ||
          value['attempt'] is! int ||
          (value['attempt'] as int) < 0 ||
          (value['attempt'] as int) > 1000000) {
        throw const FormatException('书籍整理任务收据无效。');
      }
      result[path] = <String, Object?>{
        ...value,
        'owner_pid': null,
        if (const <String>{
          'queued',
          'running',
          'finalizing',
          'cancelling',
        }.contains(value['phase']))
          'phase': 'paused',
      };
      continue;
    }
    if (path.startsWith('jobs/')) {
      final RegExpMatch? match = _job.firstMatch(path);
      if (value is! Map<String, Object?> ||
          match == null ||
          value['kind'] != match.group(1) ||
          value['key'] is! int ||
          value['key'] != int.parse(match.group(2)!) ||
          value.keys.any((String field) => !_jobFields.contains(field)) ||
          value['args'] is! List<Object?> ||
          !const <String>{
            'pending',
            'deferred',
            'failed',
            'complete',
          }.contains(value['state'])) {
        throw const FormatException('书籍整理任务格式无效。');
      }
      final List<Object?> args = value['args'] as List<Object?>;
      final String kind = value['kind'] as String;
      if ((kind == 'classic-recap' ? args.length != 6 : args.length != 4) ||
          args[0] is! int ||
          args[0] != value['key'] ||
          (args[0] as int) < 0 ||
          (args[0] as int) > 1000000000 ||
          (kind == 'saga'
              ? args[1] is! List<Object?> ||
                    !(args[1] as List<Object?>).every(
                      (Object? x) => x is int && x >= 0 && x <= 1000000000,
                    )
              : args[1] is! int ||
                    (args[1] as int) < (args[0] as int) ||
                    (args[1] as int) > 1000000000) ||
          (kind == 'bio' &&
              (args[2] is! String ||
                  args[3] is! List<Object?> ||
                  !(args[3] as List<Object?>).every(
                    (Object? x) => x is String,
                  ))) ||
          ((kind == 'recap' || kind == 'classic-recap') &&
              (args[2] is! List<Object?> ||
                  args[3] is! Map<String, Object?>)) ||
          (kind == 'classic-recap' &&
              (args[4] is! List<Object?> || args[5] is! String)) ||
          (kind == 'saga' && (args[2] != null || args[3] is! String))) {
        throw const FormatException('书籍整理任务参数无效。');
      }
      for (final String key in const <String>['generation_attempt']) {
        final Object? count = value[key];
        if (count != null && (count is! int || count < 0 || count > 1000000)) {
          throw const FormatException('人物小传重试记录无效。');
        }
      }
      final Object? failures = value['content_failures'];
      if (failures != null &&
          (failures is! int || failures < 0 || failures > 2)) {
        throw const FormatException('人物小传重试记录无效。');
      }
      if (value['retry_requested'] != null &&
          value['retry_requested'] is! bool) {
        throw const FormatException('人物小传重试请求无效。');
      }
    }
    if (path.startsWith('drafts/')) {
      final RegExpMatch? match = _draft.firstMatch(path);
      if (match == null ||
          value is! Map<String, Object?> ||
          value.keys.any(
            (String key) =>
                !const <String>{'input_sha256', 'value'}.contains(key),
          ) ||
          value['input_sha256'] != match.group(1) ||
          !value.containsKey('value')) {
        throw const FormatException('书籍模型草稿校验信息无效。');
      }
    }
    result[path] = value;
  }
  return result;
}

String _safeWorkSource(String? source) {
  if (source == null) return '数据';
  if (portableWorkRootFiles.contains(source) ||
      _judgeFiles.contains(source) ||
      _job.hasMatch(source) ||
      _judgeCachePath.hasMatch(source)) {
    return source;
  }
  // Other basenames can come from old work. Never display an untrusted name;
  // it might itself contain a credential-like token.
  final String directory = source.split('/').first;
  return portableWorkDirectories.contains(directory) ? '$directory/…' : '数据';
}

void _rejectCredentials(
  Object? value,
  int depth, {
  String? source,
  List<String> parents = const <String>[],
}) {
  if (depth > 64) throw const FormatException('书籍整理缓存嵌套过深。');
  if (value is Map<String, Object?>) {
    final bool judgeProbabilities =
        source != null &&
        _judgeCachePath.hasMatch(source) &&
        parents.length == 3 &&
        parents[0] == 'answers' &&
        parents[2] == 'probabilities';
    for (final MapEntry<String, Object?> row in value.entries) {
      if (judgeProbabilities) {
        // These keys are option IDs, not JSON field names. A legitimate
        // relation question has an option named "secret". Only finite numeric
        // probabilities are accepted here, and token-looking IDs still fail.
        final Object? probability = row.value;
        if (row.key.length > 200 ||
            _credentialText.hasMatch(row.key) ||
            probability is! num ||
            !probability.isFinite ||
            probability < 0 ||
            probability > 1) {
          throw const FormatException('模型判断缓存概率无效。');
        }
        continue;
      }
      final String normalized = row.key.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      if (_credentialKeys.contains(normalized) ||
          normalized.endsWith('apikey') ||
          normalized.endsWith('secret') ||
          normalized.endsWith('password') ||
          normalized.endsWith('credential') ||
          normalized.endsWith('token') ||
          normalized.endsWith('privatekey')) {
        throw FormatException(
          '整理缓存 ${_safeWorkSource(source)} 的字段名疑似包含密钥，未加入备份。',
        );
      }
      _rejectCredentials(
        row.value,
        depth + 1,
        source: source,
        parents: <String>[...parents, row.key],
      );
    }
  } else if (value is List<Object?>) {
    for (final Object? row in value) {
      _rejectCredentials(row, depth + 1, source: source, parents: parents);
    }
  } else if (value is String && _credentialText.hasMatch(value)) {
    throw FormatException('整理缓存 ${_safeWorkSource(source)} 的文本疑似包含密钥，未加入备份。');
  }
}

/// Reject accidentally embedded provider credentials in portable metadata.
/// Book text is deliberately checked by its own import path, not here.
void rejectPortableCredentials(Object? value) => _rejectCredentials(value, 0);

bool _sameValue(Object? a, Object? b) {
  if (a is Map<String, Object?> && b is Map<String, Object?>) {
    return a.length == b.length &&
        a.keys.every(
          (String key) => b.containsKey(key) && _sameValue(a[key], b[key]),
        );
  }
  if (a is List<Object?> && b is List<Object?>) {
    return a.length == b.length &&
        Iterable<int>.generate(
          a.length,
        ).every((int i) => _sameValue(a[i], b[i]));
  }
  return a == b;
}

bool _usageFollows(Object? old, Object? newer) {
  if (_sameValue(old, newer)) return true;
  if (old is num && newer is num) {
    return old.isFinite && newer.isFinite && old >= 0 && newer >= old;
  }
  if (old is Map<String, Object?> && newer is Map<String, Object?>) {
    return old.entries.every(
      (MapEntry<String, Object?> row) =>
          newer.containsKey(row.key) &&
          _usageFollows(row.value, newer[row.key]),
    );
  }
  return false;
}

bool _activityFollows(Object? old, Object? newer) {
  if (_sameValue(old, newer)) return true;
  if (old is! List<Object?> ||
      newer is! List<Object?> ||
      old.isEmpty ||
      newer.isEmpty) {
    return false;
  }
  for (
    int overlap = old.length < newer.length ? old.length : newer.length;
    overlap > 0;
    overlap--
  ) {
    if (Iterable<int>.generate(
      overlap,
    ).every((int i) => _sameValue(old[old.length - overlap + i], newer[i]))) {
      return newer.length > overlap;
    }
  }
  return false;
}

bool _receiptFollows(Object? old, Object? newer) {
  if (old is! Map<String, Object?> ||
      newer is! Map<String, Object?> ||
      old['book'] != newer['book'] ||
      old['request_id'] != newer['request_id']) {
    return false;
  }
  final Object? oldUpdated = old['updated'];
  final Object? newUpdated = newer['updated'];
  return oldUpdated is num &&
      newUpdated is num &&
      newUpdated.isFinite &&
      newUpdated >= oldUpdated &&
      (newer['attempt'] as int? ?? 0) >= (old['attempt'] as int? ?? 0);
}

bool _jobFollows(Object? oldRaw, Object? newRaw) {
  if (oldRaw is! Map<String, Object?> ||
      newRaw is! Map<String, Object?> ||
      oldRaw['kind'] != newRaw['kind'] ||
      oldRaw['key'] != newRaw['key'] ||
      !_sameValue(oldRaw['args'], newRaw['args'])) {
    return false;
  }
  final int oldAttempt = oldRaw['generation_attempt'] as int? ?? 0;
  final int newAttempt = newRaw['generation_attempt'] as int? ?? 0;
  final int oldFailures = oldRaw['content_failures'] as int? ?? 0;
  final int newFailures = newRaw['content_failures'] as int? ?? 0;
  if (newAttempt < oldAttempt) return false;
  final bool oldRetry = oldRaw['retry_requested'] == true;
  final bool newRetry = newRaw['retry_requested'] == true;
  final String oldState = oldRaw['state'] as String;
  final String newState = newRaw['state'] as String;
  final bool consumedRetry =
      oldRetry &&
      !newRetry &&
      (newState == 'pending' ||
          newState == 'complete' ||
          newAttempt > oldAttempt);
  if (newFailures < oldFailures && !consumedRetry) return false;
  if (oldRaw['kind'] == 'bio' &&
      newFailures > oldFailures &&
      newAttempt <= oldAttempt) {
    return false;
  }
  if (oldRetry && !newRetry && !consumedRetry) return false;
  if (!oldRetry &&
      newRetry &&
      !(oldState == 'deferred' && newState == 'deferred')) {
    return false;
  }
  if (oldState == 'complete' && newState != 'complete') return false;
  if (oldState == 'deferred' && newState == 'pending' && !oldRetry) {
    return false;
  }
  if (oldState == 'pending' &&
      newState == 'deferred' &&
      newFailures == oldFailures &&
      newAttempt == oldAttempt) {
    return false;
  }
  if (oldState == 'failed' && newState == 'pending') return false;
  if (oldState == newState &&
      newAttempt == oldAttempt &&
      newFailures == oldFailures &&
      oldRetry == newRetry) {
    return false;
  }
  return true;
}

bool _workFollows(
  Map<String, Object?> older,
  Map<String, Object?> newer, {
  required bool allowOtherChanges,
}) {
  bool jobAdvanced = false;
  for (final MapEntry<String, Object?> row in older.entries) {
    if (!newer.containsKey(row.key)) {
      if (row.key.startsWith('drafts/') || row.key.startsWith('judge/cache/')) {
        continue;
      }
      return false;
    }
    final Object? next = newer[row.key];
    if (_sameValue(row.value, next)) continue;
    if (row.key.startsWith('jobs/')) {
      if (!_jobFollows(row.value, next)) return false;
      jobAdvanced = true;
    } else if (row.key == 'usage.json') {
      if (!_usageFollows(row.value, next)) return false;
    } else if (row.key == 'activity.json') {
      if (!_activityFollows(row.value, next)) return false;
    } else if (row.key == 'worker-receipt.json') {
      if (!_receiptFollows(row.value, next)) return false;
    } else if (!allowOtherChanges ||
        row.key.startsWith('judge/cache/') ||
        const <String>{
          'repair-policy.json',
          'cache-manifest.json',
          'quality-retry.json',
          'judge/paid-budget.json',
          'judge/model-budget.json',
        }.contains(row.key)) {
      return false;
    }
  }
  for (final String path in newer.keys) {
    if (!older.containsKey(path) && path.startsWith('jobs/')) {
      jobAdvanced = true;
    }
  }
  return allowOtherChanges || jobAdvanced;
}

/// Choose one complete processing timeline only when book progress proves a
/// direction. At equal progress, conflicting jobs, usage, or retry requests
/// require the user to keep both snapshots; summed usage cannot be inferred.
Map<String, Object?> mergePortableWork(
  Object? localRaw,
  Object? incomingRaw, {
  required bool incomingWins,
  required bool localWins,
}) {
  final Map<String, Object?> local = validatedPortableWork(localRaw);
  final Map<String, Object?> incoming = validatedPortableWork(incomingRaw);
  bool hasSpentBudget(Map<String, Object?> work) {
    for (final String path in _judgeFiles) {
      final Object? ledger = work[path];
      if (ledger is Map<String, Object?> &&
          ((ledger['calls'] as int? ?? 0) > 0 ||
              (ledger['model_calls'] as int? ?? 0) > 0)) {
        return true;
      }
    }
    return false;
  }

  if (local.isNotEmpty &&
      incoming.isNotEmpty &&
      (hasSpentBudget(local) || hasSpentBudget(incoming)) &&
      !_sameValue(local, incoming)) {
    throw const FormatException('两端已有付费或模型判断记录，整理状态不同，未合并预算。');
  }
  if (incomingWins && localWins) {
    throw const FormatException('两端整理进度分叉，未覆盖整理缓存。');
  }
  if (incomingWins || localWins) {
    final Map<String, Object?> winner = incomingWins ? incoming : local;
    final Map<String, Object?> loser = incomingWins ? local : incoming;
    if (!_workFollows(loser, winner, allowOtherChanges: true)) {
      throw const FormatException('两端整理任务或用量分叉，未覆盖。');
    }
    final Map<String, Object?> merged = <String, Object?>{...winner};
    for (final MapEntry<String, Object?> row in loser.entries) {
      if ((row.key.startsWith('drafts/') ||
              row.key.startsWith('judge/cache/')) &&
          !merged.containsKey(row.key)) {
        merged[row.key] = row.value;
      }
    }
    return validatedPortableWork(merged);
  }
  final bool incomingFollows = _workFollows(
    local,
    incoming,
    allowOtherChanges: false,
  );
  final bool localFollows = _workFollows(
    incoming,
    local,
    allowOtherChanges: false,
  );
  if (incomingFollows != localFollows) {
    return mergePortableWork(
      local,
      incoming,
      incomingWins: incomingFollows,
      localWins: localFollows,
    );
  }
  final Map<String, Object?> merged = <String, Object?>{...local};
  for (final MapEntry<String, Object?> row in incoming.entries) {
    if (!merged.containsKey(row.key)) {
      merged[row.key] = row.value;
    } else if (!_sameValue(merged[row.key], row.value)) {
      throw const FormatException('两端整理任务、用量或草稿不同，未覆盖。');
    }
  }
  return validatedPortableWork(merged);
}
