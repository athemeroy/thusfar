/// Reading intent is separate from measured progress and book availability.
library;

import '../errors.dart';
import '../py/py_re.dart';
import 'storage.dart';

typedef Json = Map<String, Object?>;
const int maxItems = 200;
final RegExp _bookId = pyRe(r'[A-Za-z0-9_-]{1,160}\Z');
final RegExp _operation = pyRe(r'[A-Za-z0-9_-]{8,80}\Z');

Json empty() => <String, Object?>{
  'revision': 0,
  'items': <Object?>[],
  'operation': null,
  'updated': 0,
};

/// The caller serializes read/modify/write. Existing unavailable slots may be
/// retained; introducing a missing/hidden book requires a fresh visible entry.
(Json, bool) apply(
  Json current,
  Json payload,
  bool Function(String) visible, {
  double Function()? now,
}) {
  final Object? items = payload['items'];
  if (items is! List<Object?> ||
      items.length > maxItems ||
      items.any(
        (Object? x) => x is! String || pyFullmatch(_bookId, x) == null,
      ) ||
      items.toSet().length != items.length) {
    throw const ValueError('书单最多保留 200 本书，书籍编号不可重复');
  }
  final Object? operation = payload['operation'];
  if (operation is! String || pyFullmatch(_operation, operation) == null) {
    throw const ValueError('书单操作编号无效');
  }
  final int expected = integer(
    payload['expected_revision'],
    '书单版本',
    high: 1000000000,
  );
  final List<Object?> previous = current['items']! as List<Object?>;
  if (operation == current['operation']) {
    if (items.length != previous.length ||
        List<int>.generate(
          items.length,
          (int i) => i,
        ).any((int i) => items[i] != previous[i])) {
      throw const ValueError('同一个书单操作不能提交不同内容');
    }
    return (current, false);
  }
  if (expected != current['revision']) return (current, true);
  final Set<Object?> old = previous.toSet();
  if (items.any((Object? x) => !old.contains(x) && !visible(x! as String))) {
    throw const ValueError('有书籍已不在书架，请刷新书架后重新选择');
  }
  return (
    <String, Object?>{
      'revision': expected + 1,
      'items': List<Object?>.of(items),
      'operation': operation,
      'updated': now?.call() ?? DateTime.now().microsecondsSinceEpoch / 1000000,
    },
    false,
  );
}
