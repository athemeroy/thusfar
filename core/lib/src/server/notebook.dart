/// Personal records remain independent of generated graph and model output.
library;

import '../errors.dart';
import '../py/py_compat.dart';
import '../py/py_re.dart';
import 'storage.dart';

typedef Json = Map<String, Object?>;

const int maxItems = 5000;
final RegExp _id = pyRe(r'[A-Za-z0-9_-]{8,80}\Z');
double _now() => DateTime.now().microsecondsSinceEpoch / 1000000;

String _string(Object? value) => switch (value) {
  null => 'None',
  true => 'True',
  false => 'False',
  _ => '$value',
};

/// Reader coordinates use UTF-16; a quote must fit one textual block and may
/// not split a surrogate pair. Empty bookmarks are valid at any checked offset.
String sourceQuote(Json book, int start, int end) {
  if (start == end) return '';
  for (final Object? value in book['blocks']! as List<Object?>) {
    final Json block = value! as Json;
    final int offset = block['o']! as int;
    if (offset > start) break;
    final String text = block['t']! as String;
    if ((block['k'] == 'p' || block['k'] == 'h') &&
        offset <= start &&
        start < end &&
        end <= offset + text.length) {
      final String quote = text.substring(start - offset, end - offset);
      bool valid = true;
      for (int i = 0; i < quote.length; i++) {
        final int c = quote.codeUnitAt(i);
        if (c >= 0xd800 && c <= 0xdbff) {
          if (++i >= quote.length ||
              quote.codeUnitAt(i) < 0xdc00 ||
              quote.codeUnitAt(i) > 0xdfff) {
            valid = false;
            break;
          }
        } else if (c >= 0xdc00 && c <= 0xdfff) {
          valid = false;
          break;
        }
      }
      if (valid) return quote;
      break;
    }
  }
  throw const ValueError('摘录位置已变化，请重新选择原文');
}

Json validate(Object? item, Json book) {
  if (item is! Json || pyFullmatch(_id, _string(item['id'] ?? '')) == null) {
    throw const ValueError('摘记编号无效');
  }
  final Object? kind = item['kind'];
  if (kind != 'bookmark' && kind != 'note') {
    throw const ValueError('摘记类型无效');
  }
  final int length = book['len']! as int;
  final int start = integer(item['start'], '摘记位置', high: length);
  final int end = integer(item['end'], '摘录终点', low: start, high: length);
  final Object? quote = item.containsKey('quote') ? item['quote'] : '';
  final Object? text = item.containsKey('text') ? item['text'] : '';
  if (quote is! String ||
      text is! String ||
      quote.runes.length > 4000 ||
      text.runes.length > 10000) {
    throw const ValueError('摘录限 4000 字，想法限 10000 字');
  }
  if (sourceQuote(book, start, end) != quote) {
    throw const ValueError('摘录与原文不一致，未保存到错误位置');
  }
  if (kind == 'note' &&
      PyCompat.strip(quote).isEmpty &&
      PyCompat.strip(text).isEmpty) {
    throw const ValueError('请先写下想法或选择原文');
  }
  return <String, Object?>{
    'id': item['id'],
    'kind': kind,
    'start': start,
    'end': end,
    'quote': quote,
    'text': text,
    'deleted': item['deleted'] == true,
    'knowledge_cutoff': integer(
      item.containsKey('knowledge_cutoff') ? item['knowledge_cutoff'] : end,
      '摘记已读范围',
      low: end,
      high: length,
    ),
  };
}

/// `(items, item, conflict)`. A repeated operation returns its original receipt
/// without revising timestamps or overwriting a later independent note.
(List<Object?>, Json?, bool) apply(
  List<Object?> items,
  Json item,
  Json book, {
  double Function()? now,
}) {
  final Json clean = validate(item, book);
  final Object? op = item['operation'];
  if (op is! String || pyFullmatch(_id, op) == null) {
    throw const ValueError('摘记操作编号无效');
  }
  Json? old;
  for (final Object? row in items) {
    if ((row! as Json)['id'] == clean['id']) {
      old = row as Json;
      break;
    }
  }
  if (old != null && old['operation'] == op) return (items, old, false);
  final int expected = integer(
    item.containsKey('expected_revision') ? item['expected_revision'] : 0,
    '摘记版本',
    high: 1000000000,
  );
  if (expected != (old?['revision'] ?? 0)) return (items, old, true);
  if (old == null && items.length >= maxItems) {
    throw const ValueError('本书摘记已达上限，请先导出留存');
  }
  final double stamp = (now ?? _now)();
  clean.addAll(<String, Object?>{
    'revision': expected + 1,
    'operation': op,
    'created':
        old != null && old.containsKey('created') ? old['created'] : stamp,
    'updated': stamp,
  });
  return (
    <Object?>[
      for (final Object? row in items)
        if ((row! as Json)['id'] != clean['id']) row,
      clean,
    ],
    clean,
    false,
  );
}

List<Json> restore(Object? items, Json book, {double Function()? now}) {
  if (items is! List<Object?> || items.length > maxItems) {
    throw const ValueError('摘记备份无效');
  }
  final List<Json> result = <Json>[];
  final Set<Object?> seen = <Object?>{};
  for (final Object? item in items) {
    final Json clean = validate(item, book);
    final Json raw = item! as Json;
    if (!seen.add(clean['id'])) throw const ValueError('摘记编号重复');
    clean['revision'] = integer(
      raw.containsKey('revision') ? raw['revision'] : 1,
      '摘记版本',
      low: 1,
      high: 1000000000,
    );
    clean['operation'] = PyCompat.slice(
      _string(raw.containsKey('operation') ? raw['operation'] : clean['id']),
      0,
      80,
    );
    for (final String key in <String>['created', 'updated']) {
      final Object? value = raw.containsKey(key) ? raw[key] : (now ?? _now)();
      if (value is! num || !(value >= 0 && value <= 1000000000000)) {
        throw const ValueError('摘记时间无效');
      }
      clean[key] = value;
    }
    result.add(clean);
  }
  return result;
}
