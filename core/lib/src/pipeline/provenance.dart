/// Stable cache inputs and durable, conservative paid-request reservations.
library;

import 'dart:convert';
import 'dart:io';

import '../env.dart';
import '../errors.dart';
import '../py/py_hash.dart';
import '../py/py_json.dart';
import 'judge_context.dart';

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
    throw const RuntimeError('付费裁判预算已达上限；已保留缓存，可在书籍详情追加额度后继续');
  }
  return <String, Object?>{
    ...value,
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
  final String? scoped = scopedJudgeDirectory();
  if (scoped != null) return File('$scoped/paid-budget.json');
  final String? directory = selectedJudgeDirectory();
  // Native app settings require a visible per-book ledger. A legacy global
  // override must not silently move this book's paid usage elsewhere.
  if (environ['LLM_SETTINGS_AUTHORITY'] == '1' &&
      directory != null &&
      directory.isNotEmpty) {
    return File('$directory/paid-budget.json');
  }
  final String? configured = environ['JEV_BUDGET_FILE'];
  if (configured != null && configured.isNotEmpty) return File(configured);
  if (directory != null && directory.isNotEmpty) {
    return File('$directory/paid-budget.json');
  }
  return File('${environ['DATA_DIR'] ?? 'data'}/paid-budget.json');
}

/// Reserve before sending, including retries; concurrent processes share a
/// ledger. A failed or ambiguous request is deliberately not refunded.
const int paidJudgeDefaultCalls = 1000;
const int paidJudgeDefaultChars = 5000000;
const int paidJudgeTopUpCalls = 500;
const int paidJudgeTopUpChars = 2500000;

int _paidCallsLimit(Map<String, Object?> saved) =>
    _envInt('JEV_PAID_MAX_CALLS', '$paidJudgeDefaultCalls') +
    _count(saved, 'top_up_calls');

int _paidCharsLimit(Map<String, Object?> saved) =>
    _envInt('JEV_PAID_MAX_CHARS', '$paidJudgeDefaultChars') +
    _count(saved, 'top_up_chars');

/// Show the same effective limits that [reservePaid] enforces, including any
/// explicitly configured environment limits.
Map<String, Object?> readPaidJudgeBudget(File file) {
  final Map<String, Object?> saved =
      file.existsSync()
          ? jsonDecode(file.readAsStringSync()) as Map<String, Object?>
          : <String, Object?>{};
  return <String, Object?>{
    'version': 1,
    'calls': _count(saved, 'calls'),
    'chars': _count(saved, 'chars'),
    'questions': _count(saved, 'questions'),
    'max_calls': _paidCallsLimit(saved),
    'max_chars': _paidCharsLimit(saved),
  };
}

Map<String, Object?> reservePaid(int chars, int questions) {
  final File path = paidBudgetFile();
  return _updatePaidBudget(path, (current) {
    final int callsLimit = _paidCallsLimit(current);
    final int charsLimit = _paidCharsLimit(current);
    if (callsLimit < 0 || charsLimit < 0) {
      throw const ValueError('付费裁判预算必须是非负整数');
    }
    return reservePaidUpdate(current, chars, questions, callsLimit, charsLimit);
  });
}

/// Each extra allowance requires a separate book-detail action. The saved
/// increments survive restarts and remain independent of environment defaults.
Map<String, Object?> extendPaidJudgeBudget(File file) =>
    _updatePaidBudget(file, (current) {
      final Map<String, Object?> updated = <String, Object?>{
        ...current,
        'version': 1,
        'top_up_calls': _count(current, 'top_up_calls') + paidJudgeTopUpCalls,
        'top_up_chars': _count(current, 'top_up_chars') + paidJudgeTopUpChars,
      };
      updated['max_calls'] = _paidCallsLimit(updated);
      updated['max_chars'] = _paidCharsLimit(updated);
      return updated;
    });

Map<String, Object?> _updatePaidBudget(
  File path,
  Map<String, Object?> Function(Map<String, Object?>) update,
) {
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
    final Map<String, Object?> value = update(current);
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

/// A separate, per-book limit for using the reader's configured chat model as
/// a judge. It never spends the independent Jev gateway allowance.
const int modelJudgeInitialCalls = 3000;
const int modelJudgeInitialChars = 12000000;
const int modelJudgeTopUpCalls = 1000;
const int modelJudgeTopUpChars = 4000000;

File modelJudgeBudgetFile() {
  final String? directory = selectedJudgeDirectory();
  if (directory == null || directory.isEmpty) {
    throw const RuntimeError('模型判断缺少书籍预算目录');
  }
  return File('$directory/model-budget.json');
}

Map<String, Object?> readModelJudgeBudget(File file) {
  final Map<String, Object?> saved =
      file.existsSync()
          ? jsonDecode(file.readAsStringSync()) as Map<String, Object?>
          : <String, Object?>{};
  return <String, Object?>{
    'version': 1,
    'calls': _count(saved, 'calls'),
    'chars': _count(saved, 'chars'),
    'questions': _count(saved, 'questions'),
    'model_calls': _count(saved, 'model_calls'),
    'model_prompt_tokens': _count(saved, 'model_prompt_tokens'),
    'model_completion_tokens': _count(saved, 'model_completion_tokens'),
    'model_cost_low': (saved['model_cost_low'] as num?) ?? 0,
    'model_cost_high': (saved['model_cost_high'] as num?) ?? 0,
    'max_calls':
        _count(saved, 'max_calls') == 0
            ? modelJudgeInitialCalls
            : _count(saved, 'max_calls'),
    'max_chars':
        _count(saved, 'max_chars') == 0
            ? modelJudgeInitialChars
            : _count(saved, 'max_chars'),
  };
}

Map<String, Object?> _updateModelJudgeBudget(
  File path,
  Map<String, Object?> Function(Map<String, Object?> current) update,
) {
  path.parent.createSync(recursive: true);
  final RandomAccessFile lock = File(
    '${path.path}.lock',
  ).openSync(mode: FileMode.append);
  try {
    lock.lockSync(FileLock.blockingExclusive);
    final Map<String, Object?> next = update(readModelJudgeBudget(path));
    final File tmp = File('${path.path}.$pid.tmp');
    final RandomAccessFile out = tmp.openSync(mode: FileMode.write);
    try {
      out.writeStringSync(PyJson.encode(next));
      out.flushSync();
    } finally {
      out.closeSync();
    }
    tmp.renameSync(path.path);
    return next;
  } finally {
    lock.unlockSync();
    lock.closeSync();
  }
}

/// Reserve before every model call, including a repair attempt. A failed or
/// ambiguous request is deliberately counted, as it may still be billed.
Map<String, Object?> reserveModelJudge(int chars, int questions) =>
    _updateModelJudgeBudget(modelJudgeBudgetFile(), (current) {
      if (_count(current, 'calls') + 1 > _count(current, 'max_calls') ||
          _count(current, 'chars') + chars > _count(current, 'max_chars')) {
        throw const RuntimeError('模型判断额度已达上限；已保留整理缓存，可在书籍详情追加额度后继续');
      }
      return <String, Object?>{
        ...current,
        'calls': _count(current, 'calls') + 1,
        'chars': _count(current, 'chars') + chars,
        'questions': _count(current, 'questions') + questions,
      };
    });

/// Keep successful response usage across worker restarts. Reservations remain
/// the authoritative upper bound; failed requests may have unknown usage.
Map<String, Object?> recordModelJudgeUsage(
  int promptTokens,
  int completionTokens,
  double costLow,
  double costHigh,
) => _updateModelJudgeBudget(
  modelJudgeBudgetFile(),
  (current) => <String, Object?>{
    ...current,
    'model_calls': _count(current, 'model_calls') + 1,
    'model_prompt_tokens':
        _count(current, 'model_prompt_tokens') + promptTokens,
    'model_completion_tokens':
        _count(current, 'model_completion_tokens') + completionTokens,
    'model_cost_low': ((current['model_cost_low'] as num?) ?? 0) + costLow,
    'model_cost_high': ((current['model_cost_high'] as num?) ?? 0) + costHigh,
  },
);

/// Called only by an explicit reader action on a book's budget card.
Map<String, Object?> extendModelJudgeBudget(File file) =>
    _updateModelJudgeBudget(
      file,
      (current) => <String, Object?>{
        ...current,
        'max_calls': _count(current, 'max_calls') + modelJudgeTopUpCalls,
        'max_chars': _count(current, 'max_chars') + modelJudgeTopUpChars,
      },
    );
