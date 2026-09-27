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
    'reconciled',
    'interrupted',
    'worker_stopped',
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
      'background_time_limit' => '系统后台整理时段已结束',
      'reconciled' => '上次整理中断后已暂停',
      'interrupted' => '上次整理中断后已暂停',
      'worker_stopped' => '整理任务中断后已暂停',
      _ => '暂停原因未记录',
    };
  }

  static bool autoEnabled(Directory bookDirectory) =>
      _object(_read(File('${bookDirectory.path}/meta.json')))['auto'] == true;

  static Uint8List bytes({
    required Directory bookDirectory,
    required Map<String, Object?> workerHealth,
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
      'meta': <String, Object?>{'auto': _boolean(meta['auto'])},
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
    };
    return Uint8List.fromList(
      utf8.encode('${const JsonEncoder.withIndent('  ').convert(snapshot)}\n'),
    );
  }

  static Object? _read(File file) {
    try {
      if (!file.existsSync() || file.lengthSync() > 1024 * 1024) return null;
      return jsonDecode(file.readAsStringSync());
    } on Object {
      return null;
    }
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
