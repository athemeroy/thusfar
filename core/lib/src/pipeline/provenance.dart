/// Stable cache inputs and durable, conservative paid-request reservations.
library;

import 'dart:convert';
import 'dart:io';

import '../env.dart';
import '../errors.dart';
import '../py/py_hash.dart';
import '../py/py_json.dart';

const int provenanceSchema = 2;

/// SHA-256 of `json.dumps(value, ensure_ascii=False, sort_keys=True,
/// separators=(',', ':'))`.
String digest(Object? value) => sha256Hex(
  utf8.encode(
    PyJson.encode(value, ensureAscii: false, sortKeys: true, compact: true),
  ),
);

const List<String> _chapterKeys = <String>[
  'title',
  'parent',
  'b0',
  'b1',
  'o0',
  'o1',
  'kind',
];

String sourceFingerprint(Map<String, Object?> book, List<Object?> segs) =>
    digest(<String, Object?>{
      'blocks': book['blocks'],
      'chapters': <Object?>[
        for (final Object? c in book['chapters']! as List<Object?>)
          <String, Object?>{
            for (final String k in _chapterKeys)
              k: (c! as Map<String, Object?>)[k],
          },
      ],
      'lang': book['lang'],
      'genre': book['genre'],
      'segments': segs,
    });

int _envInt(String key, String fallback) {
  final String raw = (environ[key] ?? fallback).trim();
  final int? value = int.tryParse(raw.replaceAll('_', ''));
  if (value == null) {
    throw ValueError("invalid literal for int() with base 10: '$raw'");
  }
  return value;
}

int _count(Map<String, Object?> value, String key) => (value[key] as int?) ?? 0;

/// The pure ledger step of [reservePaid]: the next ledger value, or a
/// refusal when either cap would be exceeded.
Map<String, Object?> reservePaidUpdate(
  Map<String, Object?> value,
  int chars,
  int questions,
  int callsLimit,
  int charsLimit,
) {
  if (_count(value, 'calls') + 1 > callsLimit ||
      _count(value, 'chars') + chars > charsLimit) {
    throw const RuntimeError('付费裁判预算已达上限；已保留缓存，可调整显式预算后继续');
  }
  return <String, Object?>{
    'version': 1,
    'calls': _count(value, 'calls') + 1,
    'chars': _count(value, 'chars') + chars,
    'questions': _count(value, 'questions') + questions,
    'max_calls': callsLimit,
    'max_chars': charsLimit,
  };
}

/// Where the paid-judge ledger lives, following the Python lookup order.
File paidBudgetFile() {
  final String? directory = environ['JUDGE_LOG_DIR'];
  final String? configured = environ['JEV_BUDGET_FILE'];
  if (configured != null && configured.isNotEmpty) return File(configured);
  if (directory != null && directory.isNotEmpty) {
    return File('$directory/paid-budget.json');
  }
  return File('${environ['DATA_DIR'] ?? 'data'}/paid-budget.json');
}

/// Reserve before sending, including retries; concurrent processes share a
/// ledger. A failed or ambiguous request is deliberately not refunded.
Map<String, Object?> reservePaid(int chars, int questions) {
  final int callsLimit = _envInt('JEV_PAID_MAX_CALLS', '1000');
  final int charsLimit = _envInt('JEV_PAID_MAX_CHARS', '5000000');
  if (callsLimit < 0 || charsLimit < 0) {
    throw const ValueError('付费裁判预算必须是非负整数');
  }
  final File path = paidBudgetFile();
  path.parent.createSync(recursive: true);
  final RandomAccessFile lock = File(
    '${path.path}.lock',
  ).openSync(mode: FileMode.append);
  try {
    lock.lockSync(FileLock.blockingExclusive);
    final Map<String, Object?> current =
        path.existsSync()
            ? jsonDecode(path.readAsStringSync()) as Map<String, Object?>
            : <String, Object?>{};
    final Map<String, Object?> value = reservePaidUpdate(
      current,
      chars,
      questions,
      callsLimit,
      charsLimit,
    );
    final File tmp = File('${path.path}.$pid.tmp');
    final RandomAccessFile out = tmp.openSync(mode: FileMode.write);
    try {
      out.writeStringSync(PyJson.encode(value));
      out.flushSync();
    } finally {
      out.closeSync();
    }
    tmp.renameSync(path.path);
    return value;
  } finally {
    lock.unlockSync();
    lock.closeSync();
  }
}
