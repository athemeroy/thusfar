/// Durable dispatch evidence. Contains no prompts, responses or credentials.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef _Json = Map<String, Object?>;

File _journal(Directory root) =>
    File('${root.path}/work/model-request-journal.json');

/// Any receipt left by a dead process requires an explicit reader decision.
/// Even a received response may not yet have reached its higher-level cache.
bool hasUnsettledModelRequests(Directory root) {
  final File file = _journal(root);
  if (!file.existsSync()) return false;
  try {
    final _Json data = jsonDecode(file.readAsStringSync()) as _Json;
    return (data['requests'] as List<Object?>).isNotEmpty;
  } on Object {
    // Damaged dispatch evidence must never authorize another paid request.
    return true;
  }
}

/// Called only by explicit reader resume, never by startup reconciliation.
void acknowledgeUnsettledModelRequests(Directory root) {
  final File file = _journal(root);
  if (file.existsSync()) file.deleteSync();
}

final class ModelRequestScope {
  ModelRequestScope(this.root);
  static final Object _zoneKey = Object();
  static ModelRequestScope? get current =>
      Zone.current[_zoneKey] as ModelRequestScope?;

  final Directory root;
  final Map<int, _Json> _requests = <int, _Json>{};
  int _next = 0;
  bool _touched = false;
  bool get hasUnknown => _requests.values.any((r) => r['phase'] == 'unknown');

  T run<T>(T Function() operation) =>
      runZoned(operation, zoneValues: <Object, Object>{_zoneKey: this});

  ModelRequestReceipt begin() {
    _touched = true;
    final int id = ++_next;
    _requests[id] = <String, Object?>{'id': id, 'phase': 'inflight'};
    _save(); // Must succeed before dispatch, otherwise there is no request.
    return ModelRequestReceipt._(this, id);
  }

  void _save() {
    final File file = _journal(root);
    file.parent.createSync(recursive: true);
    final File temp = File('${file.path}.$pid.tmp');
    temp.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'version': 1,
        'requests': _requests.values.toList(),
      }),
      flush: true,
    );
    temp.renameSync(file.path);
  }

  /// The runner has drained every accepted task and committed received drafts.
  /// Keep ambiguous receipts; a restart cannot infer their server outcome.
  void settle({bool receivedCommitted = false}) {
    if (!_touched) return;
    if (receivedCommitted) {
      _requests.removeWhere((_, value) => value['phase'] == 'received');
    }
    if (_requests.isEmpty) {
      acknowledgeUnsettledModelRequests(root);
    } else {
      _save();
    }
  }
}

final class ModelRequestReceipt {
  ModelRequestReceipt._(this._scope, this._id);
  final ModelRequestScope _scope;
  final int _id;
  bool _settled = false;

  void received() {
    if (_settled) return;
    _settled = true;
    _scope._requests[_id]!['phase'] = 'received';
    _scope._save();
  }

  void rejected() {
    if (_settled) return;
    _settled = true;
    _scope._requests.remove(_id);
    _scope._save();
  }

  void unknown(String code) {
    if (_settled) return;
    _settled = true;
    _scope._requests[_id]!.addAll(<String, Object?>{
      'phase': 'unknown',
      'code': code,
    });
    _scope._save();
  }
}
