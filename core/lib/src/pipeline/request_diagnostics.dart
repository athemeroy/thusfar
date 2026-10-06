/// Best-effort, bounded, content-free request timing. Never authorizes a retry.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'run_lease.dart';

typedef _Json = Map<String, Object?>;

/// Local IDs deliberately are not provider IDs and are never sent over HTTP.
final class ModelRequestDiagnostics {
  ModelRequestDiagnostics(Directory root)
    : _file = File('${root.path}/work/model-request-diagnostics.json'),
      runId = DateTime.now().microsecondsSinceEpoch {
    try {
      // Retain only our allowlisted scalar schema, never arbitrary stored text.
      if (_file.existsSync() && _file.lengthSync() <= 256 * 1024) {
        final Object? raw = jsonDecode(_file.readAsStringSync());
        if (raw is _Json && raw['attempts'] is List) {
          for (final Object? row in (raw['attempts']! as List).reversed.take(
            32,
          )) {
            final _Json? safe = _safeAttempt(row);
            if (safe != null) _attempts.insert(0, safe);
          }
        }
      }
    } on Object {
      // Missing/damaged diagnostics never change the safety journal or request.
    }
  }

  // Late cleanup from a cancelled run must not overwrite a newer run's trace.
  static final Map<String, int> _owners = <String, int>{};
  bool _active = false;
  final File _file;
  final int runId;
  final List<_Json> _attempts = <_Json>[];

  static const Set<String> phases = {
    'inflight',
    'received',
    'rejected',
    'unknown',
  };
  static const Set<String> events = {
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
  };
  static const Set<String> codes = {
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

  ModelRequestTrace begin(int id) {
    if (!_active) {
      _active = true;
      _owners.remove(_file.path);
      _owners[_file.path] = runId;
      if (_owners.length > 32) _owners.remove(_owners.keys.first);
    }
    final _Json row = {
      'run_id': runId,
      'id': id,
      'phase': 'inflight',
      'started_at_ms': DateTime.now().millisecondsSinceEpoch,
      'elapsed_ms': 0,
      'bytes_received': 0,
      'events': <_Json>[],
    };
    _attempts.add(row);
    if (_attempts.length > 32) _attempts.removeAt(0);
    return ModelRequestTrace._(this, row)..record('dispatch');
  }

  void flush() => _save();

  void _save() {
    if (_owners[_file.path] != runId) return;
    try {
      _file.parent.createSync(recursive: true);
      final File temp = File('${_file.path}.$pid.tmp');
      temp.writeAsStringSync(
        jsonEncode({
          'version': 1,
          'id_scope': 'local_only',
          'attempts': _attempts,
        }),
        flush: true,
      );
      temp.renameSync(_file.path);
    } on Object {
      // Diagnostic persistence cannot fail, cancel or replay paid work.
    }
  }

  static _Json? _safeAttempt(Object? raw) {
    if (raw is! _Json ||
        !phases.contains(raw['phase']) ||
        raw['id'] is! int ||
        raw['run_id'] is! int)
      return null;
    final _Json row = {'phase': raw['phase']};
    for (final String key in const [
      'run_id',
      'id',
      'started_at_ms',
      'elapsed_ms',
      'bytes_received',
      'last_byte_at_ms',
      'last_byte_elapsed_ms',
    ]) {
      final Object? value = raw[key];
      if (value is int && value >= 0) row[key] = value;
    }
    if (codes.contains(raw['code'])) row['code'] = raw['code'];
    row['events'] = <_Json>[
      if (raw['events'] is List)
        for (final Object? event in (raw['events']! as List).take(16))
          if (event is _Json && events.contains(event['event']))
            {
              'event': event['event'],
              for (final String key in const ['at_ms', 'elapsed_ms'])
                if (event[key] is int && (event[key]! as int) >= 0)
                  key: event[key],
              if (codes.contains(event['code'])) 'code': event['code'],
              if (event['http_status'] is int &&
                  (event['http_status']! as int) >= 100 &&
                  (event['http_status']! as int) <= 599)
                'http_status': event['http_status'],
              if (event['received_committed'] is bool)
                'received_committed': event['received_committed'],
            },
    ];
    return row;
  }
}

final class ModelRequestTrace {
  ModelRequestTrace._(this._owner, this._row) {
    final RunCancellation? cancellation = RunCancellation.current;
    _removeCancel = cancellation?.onCancel(() {
      record('cancel_requested', code: cancellation.reason);
    });
  }
  static final Object _zoneKey = Object();
  static ModelRequestTrace? get current =>
      Zone.current[_zoneKey] as ModelRequestTrace?;
  final ModelRequestDiagnostics _owner;
  final _Json _row;
  final Stopwatch _clock = Stopwatch()..start();
  void Function()? _removeCancel;
  int _lastByteSaveMs = -5000;

  T run<T>(T Function() operation) =>
      runZoned(operation, zoneValues: <Object, Object>{_zoneKey: this});

  void record(
    String event, {
    String? code,
    int? httpStatus,
    bool? receivedCommitted,
    bool persist = true,
  }) {
    if (!ModelRequestDiagnostics.events.contains(event)) return;
    final int elapsed = _clock.elapsedMilliseconds;
    final List<_Json> events = _row['events']! as List<_Json>;
    events.add({
      'event': event,
      'at_ms': DateTime.now().millisecondsSinceEpoch,
      'elapsed_ms': elapsed,
      if (ModelRequestDiagnostics.codes.contains(code)) 'code': code,
      if (httpStatus != null && httpStatus >= 100 && httpStatus <= 599)
        'http_status': httpStatus,
      if (receivedCommitted != null) 'received_committed': receivedCommitted,
    });
    if (events.length > 16) events.removeAt(0);
    _row['elapsed_ms'] = elapsed;
    if (persist) _owner._save();
  }

  void bytes(int count) {
    if (count <= 0) return;
    final int elapsed = _clock.elapsedMilliseconds;
    _row['bytes_received'] = (_row['bytes_received']! as int) + count;
    _row['last_byte_at_ms'] = DateTime.now().millisecondsSinceEpoch;
    _row['last_byte_elapsed_ms'] = elapsed;
    _row['elapsed_ms'] = elapsed;
    if (elapsed - _lastByteSaveMs >= 5000) {
      _lastByteSaveMs = elapsed;
      _owner._save();
    }
  }

  void finish(String phase, {String? code}) {
    _removeCancel?.call();
    _removeCancel = null;
    if (ModelRequestDiagnostics.phases.contains(phase)) _row['phase'] = phase;
    if (ModelRequestDiagnostics.codes.contains(code)) _row['code'] = code;
    record(phase, code: code);
  }

  static String exceptionCode(Object error) => switch (error) {
    Cancelled() => 'cancelled',
    TimeoutException() => 'timeout',
    SocketException() => 'socket_exception',
    HttpException() => 'http_exception',
    HandshakeException() => 'handshake_exception',
    IOException() => 'io_exception',
    _ => 'other_exception',
  };
}
