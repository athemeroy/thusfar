import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A deliberately small, content-free snapshot of one book's processing.
///
/// Never copy whole source objects into this file. Status, activity and worker
/// receipts can contain provider errors, model URLs or book-derived text.
final class ProcessingDiagnostics {
  ProcessingDiagnostics._();

  static const Set<String> _states = <String>{
    'idle',
    'queued',
    'running',
    'finalizing',
    'cancelling',
    'paused',
    'done',
    'error',
  };
  static const Set<String> _phases = <String>{
    ..._states,
    'detect_kind',
    'classify_chapters',
    'check_titles',
    'check_titles_pending',
    'resume_final_jobs',
    'waiting_for_model',
    'stage_heartbeat',
    'model_attempt',
    'retry',
    'bio_generating',
    'bio_review',
    'bio_retry',
    'bio_deferred',
    'bio_complete',
    'bio_no_candidates',
    'bio_failed',
  };
  static const Set<String> _stages = <String>{
    'extract',
    'relation',
    'recap',
    'finalize',
  };
  static const Set<String> _pauseReasons = <String>{
    'user',
    'manual',
    'background_time_limit',
    'background_unavailable',
    'request_outcome_unknown',
    'reconciled',
    'interrupted',
    'worker_stopped',
    'scope_complete',
  };

  static const Set<String> _requestCodes = <String>{
    'network_interrupted',
    'timeout',
    'cancelled',
    'provider_outcome_unknown',
    'response_interrupted',
    'incomplete_response',
    'interrupted_before_commit',
    'previous_request_unknown',
    'socket_exception',
    'http_exception',
    'handshake_exception',
    'io_exception',
    'other_exception',
    'late_open_abandoned',
    'user',
    'background_time_limit',
    'background_unavailable',
    'worker_close',
    'unspecified',
  };

  static String fileName(DateTime now) {
    String two(int n) => n.toString().padLeft(2, '0');
    return 'yedu-processing-${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.json';
  }

  static String pauseReasonLabel(
    Directory bookDirectory,
    Map<String, Object?> status,
  ) {
    final Map<String, Object?> receipt = _object(
      _read(File('${bookDirectory.path}/work/worker-receipt.json')),
    );
    final String? code =
        _pauseReason(status['pause_reason']) ??
        _pauseReason(receipt['pause_reason']) ??
        _pauseReason(receipt['reason']);
    return switch (code) {
      'user' || 'manual' => '由你暂停',
      'background_time_limit' => '手机系统停止了后台整理，已完成的内容已保留',
      'background_unavailable' => '后台整理已停止，已完成的内容已保留',
      'request_outcome_unknown' => '没有收到完整结果，已完成的内容已保留。可以点“继续整理”再试',
      'reconciled' => '上次整理中断后已暂停',
      'interrupted' => '上次整理中断后已暂停',
      'worker_stopped' => '整理任务中断后已暂停',
      'scope_complete' => '本次范围已完成',
      _ => '整理已暂停，已完成的内容已保留',
    };
  }

  static bool autoEnabled(Directory bookDirectory) =>
      _object(_read(File('${bookDirectory.path}/meta.json')))['auto'] == true;

  static Uint8List bytes({
    required Directory bookDirectory,
    required Map<String, Object?> workerHealth,
    Map<String, Object?> backgroundRuntime = const <String, Object?>{},
    DateTime? now,
  }) {
    final DateTime created = now ?? DateTime.now();
    final Map<String, Object?> status = _object(
      _read(File('${bookDirectory.path}/status.json')),
    );
    final Map<String, Object?> meta = _object(
      _read(File('${bookDirectory.path}/meta.json')),
    );
    final Map<String, Object?> receipt = _object(
      _read(File('${bookDirectory.path}/work/worker-receipt.json')),
    );
    final Map<String, Object?> modelBudget = _object(
      _read(File('${bookDirectory.path}/work/judge/model-budget.json')),
    );
    final Map<String, Object?> jevBudget = _object(
      _read(File('${bookDirectory.path}/work/judge/paid-budget.json')),
    );
    final Object? rawActivity = _read(
      File('${bookDirectory.path}/work/activity.json'),
    );
    final List<Object?> activity = rawActivity is List<Object?>
        ? rawActivity
        : const <Object?>[];
    final List<Object?> pending =
        _object(status['quality'])['pending'] is List<Object?>
        ? _object(status['quality'])['pending']! as List<Object?>
        : const <Object?>[];
    final List<Object?> queue = workerHealth['queued'] is List<Object?>
        ? workerHealth['queued']! as List<Object?>
        : const <Object?>[];
    final String bookId = bookDirectory.uri.pathSegments
        .where((String value) => value.isNotEmpty)
        .last;
    final int queuedAt = queue.indexOf(bookId);
    final Map<String, Object?> snapshot = <String, Object?>{
      'schema': 1,
      'created_at': created.toIso8601String(),
      'status': <String, Object?>{
        'state': _code(status['state'], _states),
        'done': _number(status['done']),
        'total': _number(status['total']),
        'frontier': _number(status['frontier']),
        'people': _number(status['people']),
        'updated': _number(status['updated']),
        'pause_reason': _pauseReason(status['pause_reason']),
        'retryable': _boolean(status['retryable']),
        'retry_count': _number(status['retry_count']),
        'retry_at': _number(status['retry_at']),
        'error_code': _errorCode(status['error']),
        'failure_code': _code(status['failure_code'], _requestCodes),
        'quality_state': _code(
          _object(status['quality'])['state'],
          const <String>{'pending', 'verified'},
        ),
        'pending_count': pending.length,
        'pending_titles': pending
            .where((Object? item) => item == 'chapter-titles')
            .length,
        'pending_biographies': pending
            .where((Object? item) => item is String && item.startsWith('bio-'))
            .length,
        'refused_count': status['refused'] is List<Object?>
            ? (status['refused']! as List<Object?>).length
            : 0,
      },
      'meta': <String, Object?>{
        'auto': _boolean(meta['auto']),
        'judge_route': _code(meta['judge_fallback_route'], const <String>{
          'model',
          'jev',
          'model-direct',
          'jev-direct',
        }),
      },
      'last_model_judge_failure': _modelJudgeFailure(bookDirectory),
      'judge_usage': <String, Object?>{
        'model_calls': _number(modelBudget['calls']),
        'model_call_limit': _number(modelBudget['max_calls']),
        'jev_calls': _number(jevBudget['calls']),
        'jev_call_limit': _number(jevBudget['max_calls']),
      },
      'worker': <String, Object?>{
        'alive': _boolean(workerHealth['alive']),
        'running_this_book': workerHealth['current'] == bookId,
        'queued_position': queuedAt < 0 ? null : queuedAt + 1,
        'queued_count': queue.length,
        'stopping': _boolean(workerHealth['stopping']),
      },
      'worker_receipt': <String, Object?>{
        'phase': _code(receipt['phase'], _phases),
        'reason': _pauseReason(receipt['reason']),
        'pause_reason': _pauseReason(receipt['pause_reason']),
        'attempt': _number(receipt['attempt']),
        'exit_code': _number(receipt['exit_code']),
        'retry_quality': _boolean(receipt['retry_quality']),
        'concurrency': _number(receipt['concurrency']),
        'requested_at': _number(receipt['requested_at']),
        'updated': _number(receipt['updated']),
        'finished_at': _number(receipt['finished_at']),
      },
      'activity': <Map<String, Object?>>[
        for (final Object? raw in activity.skip(
          activity.length > 64 ? activity.length - 64 : 0,
        ))
          if (raw is Map<String, Object?>)
            <String, Object?>{
              'at': _number(raw['at']),
              'phase': _code(raw['phase'], _phases),
              'done': _number(raw['done']),
              'total': _number(raw['total']),
              'segment': _number(raw['segment']),
              'attempt': _number(raw['attempt']),
              'stage': _code(raw['stage'], _stages),
              'started_at': _number(raw['started_at']),
              'last_at': _number(raw['last_at']),
            },
      ],
      'biography_jobs': _biographyJobs(bookDirectory),
      'model_requests': _modelRequests(bookDirectory),
      'worker_heartbeats': _workerHeartbeats(bookDirectory),
      if (backgroundRuntime.isNotEmpty)
        'android_runtime': _runtime(backgroundRuntime),
    };
    return Uint8List.fromList(
      utf8.encode('${const JsonEncoder.withIndent('  ').convert(snapshot)}\n'),
    );
  }

  static Map<String, Object?> _runtime(Map<String, Object?> raw) {
    Map<String, Object?> object(Object? value) => value is Map
        ? Map<String, Object?>.from(value)
        : const <String, Object?>{};
    final Map<String, Object?> service = object(raw['service']);
    final List<Object?> events = raw['events'] is List
        ? List<Object?>.from(raw['events']! as List)
        : const [];
    const Set<String> kinds = <String>{
      'engine_started',
      'activity_resumed',
      'activity_paused',
      'activity_stopped',
      'activity_destroyed',
      'activity_configuration_changed',
      'native_heartbeat',
      'worker_heartbeat',
      'dart_resumed',
      'dart_inactive',
      'dart_hidden',
      'dart_paused',
      'dart_detached',
      'service_created',
      'service_destroyed',
      'task_stopped',
      'foreground_started',
      'foreground_start_requested',
      'foreground_start_failed',
      'foreground_start_rejected',
      'foreground_start_timeout',
      'foreground_command_failed',
      'foreground_time_limit',
      'cpu_lease_acquired',
      'cpu_lease_released',
      'notification_permission_failed',
    };
    const Set<String> failures = <String>{
      'SecurityException',
      'IllegalStateException',
      'IllegalArgumentException',
      'ForegroundServiceStartNotAllowedException',
      'ForegroundServiceTypeNotAllowedException',
      'InvalidForegroundServiceTypeException',
      'MissingForegroundServiceTypeException',
      'RuntimeException',
    };
    List<Map<String, Object?>> exportEvents(List<Object?> input) =>
        <Map<String, Object?>>[
          for (final Object? event in input.skip(
            input.length > 64 ? input.length - 64 : 0,
          ))
            <String, Object?>{
              'event': _code(object(event)['event'], kinds),
              'error_type': _code(object(event)['error_type'], failures),
              for (final String key in <String>[
                'at_ms',
                'elapsed_ms',
                'uptime_ms',
                'pid',
                'process_importance',
                'worker_at_ms',
                'worker_elapsed_ms',
                'worker_gap_ms',
                'worker_sequence',
                'ui_at_ms',
              ])
                key: _number(object(event)[key]),
            },
        ];
    return <String, Object?>{
      for (final String key in <String>[
        'sdk',
        'background_data_restriction',
        'pid',
        'elapsed_ms',
        'uptime_ms',
      ])
        key: _number(raw[key]),
      for (final String key in <String>[
        'available',
        'interactive',
        'device_idle',
        'power_save',
        'battery_optimization_exempt',
        'background_restricted',
        'notifications_enabled',
        'network_available',
        'network_validated',
        'network_metered',
      ])
        key: _boolean(raw[key]),
      'service': <String, Object?>{
        'running': _boolean(service['running']),
        'start_pending': _boolean(service['start_pending']),
        'wake_lock_held': _boolean(service['wake_lock_held']),
        'task_count': _number(service['task_count']),
      },
      'events': exportEvents(events),
      'heartbeats': exportEvents(
        raw['heartbeats'] is List
            ? List<Object?>.from(raw['heartbeats']! as List)
            : const <Object?>[],
      ),
    };
  }

  static List<Map<String, Object?>> _workerHeartbeats(Directory book) {
    final Object? raw = _object(
      _read(File('${book.path}/work/worker-heartbeat.json')),
    )['samples'];
    final List<Object?> rows = raw is List<Object?> ? raw : const <Object?>[];
    return <Map<String, Object?>>[
      for (final Object? row in rows.skip(
        rows.length > 64 ? rows.length - 64 : 0,
      ))
        <String, Object?>{
          for (final String key in <String>[
            'pid',
            'sequence',
            'at_ms',
            'elapsed_ms',
            'gap_ms',
          ])
            key: _number(_object(row)[key]),
          'finished': _boolean(_object(row)['finished']),
        },
    ];
  }

  static Map<String, Object?> _modelRequests(Directory book) {
    final Map<String, Object?> journal = _object(
      _read(File('${book.path}/work/model-request-journal.json')),
    );
    final Map<String, Object?> diagnostics = _object(
      _read(File('${book.path}/work/model-request-diagnostics.json')),
    );
    List<Object?> rows(Object? value) =>
        value is List<Object?> ? value : const <Object?>[];
    const Set<String> phases = <String>{
      'inflight',
      'received',
      'rejected',
      'unknown',
    };
    final List<Object?> attempts = rows(diagnostics['attempts']);
    return <String, Object?>{
      'id_scope': 'local_only',
      'unsettled': <Map<String, Object?>>[
        for (final Object? item in rows(journal['requests']).take(32))
          <String, Object?>{
            'id': _number(_object(item)['id']),
            'phase': _code(_object(item)['phase'], phases),
            'code': _code(_object(item)['code'], _requestCodes),
          },
      ],
      'attempts': <Map<String, Object?>>[
        for (final Object? item in attempts.skip(
          attempts.length > 32 ? attempts.length - 32 : 0,
        ))
          <String, Object?>{
            for (final String key in <String>[
              'run_id',
              'id',
              'started_at_ms',
              'elapsed_ms',
              'bytes_received',
              'last_byte_at_ms',
              'last_byte_elapsed_ms',
            ])
              key: _number(_object(item)[key]),
            'phase': _code(_object(item)['phase'], phases),
            'code': _code(_object(item)['code'], _requestCodes),
            'events': <Map<String, Object?>>[
              for (final Object? event in rows(
                _object(item)['events'],
              ).take(16))
                <String, Object?>{
                  'event': _code(_object(event)['event'], const <String>{
                    'dispatch',
                    'send_started',
                    'headers',
                    'cancel_requested',
                    'abort_requested',
                    'transport_error',
                    'body_error',
                    'body_done',
                    'body_cancel_requested',
                    'body_cancelled',
                    'body_cancel_error',
                    'received',
                    'rejected',
                    'unknown',
                    'run_settled',
                  }),
                  'code': _code(_object(event)['code'], _requestCodes),
                  'at_ms': _number(_object(event)['at_ms']),
                  'elapsed_ms': _number(_object(event)['elapsed_ms']),
                  'http_status': _number(_object(event)['http_status']),
                  'received_committed': _boolean(
                    _object(event)['received_committed'],
                  ),
                },
            ],
          },
      ],
    };
  }

  static Object? _read(File file) {
    try {
      if (!file.existsSync() || file.lengthSync() > 1024 * 1024) return null;
      return jsonDecode(file.readAsStringSync());
    } on Object {
      return null;
    }
  }

  static List<Map<String, Object?>> _biographyJobs(Directory bookDirectory) {
    final Directory jobs = Directory('${bookDirectory.path}/work/jobs');
    if (!jobs.existsSync()) return const <Map<String, Object?>>[];
    final List<File> files;
    try {
      files = jobs
          .listSync(followLinks: false)
          .whereType<File>()
          .where(
            (File file) =>
                RegExp(r'^bio-\d+\.json$').hasMatch(file.uri.pathSegments.last),
          )
          .take(512)
          .toList();
    } on Object {
      return const <Map<String, Object?>>[];
    }
    final List<Map<String, Object?>> result = <Map<String, Object?>>[];
    for (final File file in files) {
      final Map<String, Object?> job = _object(_read(file));
      final Map<String, Object?> review = _object(job['bio_review']);
      if (review.isEmpty) continue;
      final String stem = file.uri.pathSegments.last;
      final int? chapterIndex = int.tryParse(
        stem.substring(4, stem.length - 5),
      );
      if (chapterIndex == null || chapterIndex < 0) continue;
      final Map<String, Object?> reasons = _object(review['rejection_reasons']);
      result.add(<String, Object?>{
        'chapter': chapterIndex + 1,
        'state': _code(job['state'], const <String>{
          'pending',
          'deferred',
          'failed',
          'complete',
        }),
        'failure_kind': _code(job['failure_kind'], const <String>{
          'bio_content',
          'bio_judge_format',
        }),
        'generation_attempt': _number(job['generation_attempt']),
        'content_failures': _number(job['content_failures']),
        'retry_requested': _boolean(job['retry_requested']),
        'candidates': _number(review['candidates']),
        'passed': _number(review['passed']),
        'verification_pending': _boolean(review['verification_pending']),
        'blocked': _number(review['blocked']),
        'missing': _number(review['missing']),
        'rejection_reasons': <String, Object?>{
          for (final String reason in const <String>[
            'beyond_text',
            'contradicted',
            'insufficient_confidence',
          ])
            if (_number(reasons[reason]) != null)
              reason: _number(reasons[reason]),
        },
      });
    }
    result.sort(
      (Map<String, Object?> a, Map<String, Object?> b) =>
          (a['chapter']! as int).compareTo(b['chapter']! as int),
    );
    return result;
  }

  static Map<String, Object?> _modelJudgeFailure(Directory book) {
    final Map<String, Object?> raw = _object(
      _read(File('${book.path}/work/judge/model-answer-failure.json')),
    );
    if (raw.isEmpty) return const <String, Object?>{};
    final Map<String, Object?> reasons = _object(raw['reasons']);
    return <String, Object?>{
      'at': _number(raw['at']),
      'attempts': _number(raw['attempts']),
      'question_count': _number(raw['question_count']),
      'unresolved_count': _number(raw['unresolved_count']),
      'reasons': <String, Object?>{
        for (final String code in const <String>[
          'invalid_json',
          'missing_answer',
          'invalid_choice',
          'incomplete_probabilities',
          'non_numeric_probability',
          'non_finite_probability',
          'probability_out_of_range',
          'inconsistent_sum',
          'zero_choice_probability',
        ])
          if (_number(reasons[code]) != null) code: _number(reasons[code]),
      },
    };
  }

  static Map<String, Object?> _object(Object? value) =>
      value is Map<String, Object?> ? value : const <String, Object?>{};

  static String? _code(Object? value, Set<String> allowed) =>
      value is String && allowed.contains(value) ? value : null;

  static String? _pauseReason(Object? value) => _code(value, _pauseReasons);

  static num? _number(Object? value) =>
      value is num && value.isFinite ? value : null;

  static bool? _boolean(Object? value) => value is bool ? value : null;

  static String? _errorCode(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    final String error = value.toLowerCase();
    if (error.contains('判断回答不完整或概率无效')) return 'model_judge_invalid_answer';
    if (error.contains('人物小传') &&
        (error.contains('通过 0/') ||
            error.contains('没有返回可核对') ||
            error.contains('返回格式无效'))) {
      return 'bio_content_rejected';
    }
    if (RegExp(r'\b(?:401|403)\b').hasMatch(error) ||
        error.contains('unauthorized') ||
        error.contains('invalid api key')) {
      return 'auth';
    }
    if (RegExp(r'\b429\b').hasMatch(error) || error.contains('rate limit')) {
      return 'http429';
    }
    if (RegExp(r'\b5\d\d\b').hasMatch(error)) return 'http5xx';
    if (error.contains('timeout') ||
        error.contains('timed out') ||
        error.contains('deadline')) {
      return 'timeout';
    }
    if (error.contains('socket') ||
        error.contains('connection') ||
        error.contains('handshake') ||
        error.contains('network')) {
      return 'network';
    }
    return 'unknown';
  }
}
