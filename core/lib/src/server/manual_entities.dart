/// Python `server.manual_entities`: source-anchored personal knowledge.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import '../errors.dart';
import '../py/py_compat.dart';
import '../py/py_json.dart';
import 'storage.dart';

typedef Json = Map<String, Object?>;
const int manualMaxItems = 1000;
final RegExp _id = RegExp(r'^[A-Za-z0-9_-]{8,80}$');
bool _validId(String text) => _id.hasMatch(text) && !text.endsWith('\n');
bool _truth(Object? value) =>
    value != null &&
    value != false &&
    value != 0 &&
    value != '' &&
    !(value is List<Object?> && value.isEmpty) &&
    !(value is Json && value.isEmpty);
String _str(Object? value) =>
    value == null
        ? 'None'
        : value == true
        ? 'True'
        : value == false
        ? 'False'
        : '$value';
Json _obj(Object? raw, String message) {
  if (raw is! Json) throw ValueError(message);
  return raw;
}

List<T> _sorted<T>(Iterable<T> values, int Function(T, T) compare) {
  final List<(int, T)> indexed = <(int, T)>[];
  for (final T value in values) {
    indexed.add((indexed.length, value));
  }
  indexed.sort(((int, T) a, (int, T) b) {
    final int order = compare(a.$2, b.$2);
    return order == 0 ? a.$1.compareTo(b.$1) : order;
  });
  return <T>[for (final (int, T) row in indexed) row.$2];
}

/// Earliest exact source occurrence whose complete name precedes [cutoff].
int manualAnchor(Json book, String name, int cutoff) {
  for (final Json block in (book['blocks']! as List<Object?>).cast<Json>()) {
    final int offset = block['o']! as int;
    if (offset >= cutoff) break;
    if (block['k'] != 'p' && block['k'] != 'h') continue;
    final int found = (block['t']! as String).indexOf(name);
    if (found >= 0 && offset + found + name.length <= cutoff)
      return offset + found;
  }
  throw const ValueError('当前已读原文里没有找到这个完整名称，请检查文字或继续阅读');
}

(String, String, int, String) manualBase(Object? raw, Json book) {
  if (raw is! Json || !_validId(_str(raw['id'] ?? '')))
    throw const ValueError('手动条目编号无效');
  final Object? kind = raw['kind'];
  if (kind != 'person' && kind != 'concept') throw const ValueError('请选择人物或概念');
  final Object? name = raw['name'];
  if (name is! String ||
      PyCompat.strip(name).isEmpty ||
      PyCompat.strip(name).runes.length > 80 ||
      name.contains('\n')) {
    throw const ValueError('名称须为 1—80 字');
  }
  final int cutoff = integer(
    raw['knowledge_cutoff'],
    '已读范围',
    high: book['len']! as int,
  );
  final Object? note = raw.containsKey('note') ? raw['note'] : '';
  if (note is! String || note.runes.length > 3000)
    throw const ValueError('补充说明最多 3000 字');
  return (kind! as String, PyCompat.strip(name), cutoff, PyCompat.strip(note));
}

/// Optimistic per-item writes with operation receipts; no inference or worker lease.
(List<Json>, Json?, bool) manualApply(
  List<Json> items,
  Json payload,
  Json book,
  Json graph, {
  double Function()? clock,
}) {
  final (String kind, String name, int cutoff, String note) = manualBase(
    payload,
    book,
  );
  final Object? operation = payload['operation'];
  if (operation is! String || !_validId(operation))
    throw const ValueError('操作编号无效');
  final Object? id = payload['id'];
  final int expected = integer(
    payload.containsKey('expected_revision') ? payload['expected_revision'] : 0,
    '条目版本',
    high: 1000000000,
  );
  final bool deleted = payload['deleted'] == true;
  final String hash =
      crypto.sha256
          .convert(
            utf8.encode(
              PyJson.encode(
                <Object?>[id, kind, name, cutoff, note, expected, deleted],
                ensureAscii: false,
                compact: true,
              ),
            ),
          )
          .toString();
  final Json? old = items.where((Json row) => row['id'] == id).firstOrNull;
  if (old != null && old['operation'] == operation) {
    if (_truth(old['operation_hash']) && old['operation_hash'] != hash) {
      throw const ValueError('上次操作的内容已经变化；请重新打开资料，核对保存结果后再修改');
    }
    return (items, old, false);
  }
  if (expected != (old?['revision'] ?? 0)) return (items, old, true);
  final int source;
  final List<Object?> versions;
  if (old != null) {
    if (kind != old['kind'] || name != old['name'])
      throw const ValueError('已有条目的名称和类型不可改；可以删除后重新补充');
    if (cutoff < (old['knowledge_cutoff']! as int))
      throw const ValueError('不能把后来补充的资料移到之前的阅读位置');
    source = old['source_start']! as int;
    versions = List<Object?>.of(old['versions']! as List<Object?>);
    if (!deleted) versions.add(<String, Object?>{'p': cutoff, 'note': note});
  } else {
    if (deleted) throw const ValueError('没有这条可删除的资料');
    if (items.length >= manualMaxItems) throw const ValueError('本书手动条目已达上限');
    source = manualAnchor(book, name, cutoff);
    for (final Json row
        in ((graph['log'] as List<Object?>?) ?? <Object?>[]).cast<Json>()) {
      if ((row['p']! as int) > cutoff) break;
      if (row['t'] == 'person' &&
          PyCompat.casefold(row['name'] as String? ?? '') ==
              PyCompat.casefold(name)) {
        throw const ValueError('资料里已有这个名称；请在“全部”中搜索，不要重复创建');
      }
    }
    if (items.any(
      (Json row) =>
          !_truth(row['deleted']) &&
          PyCompat.casefold(row['name']! as String) == PyCompat.casefold(name),
    )) {
      throw const ValueError('已有同名的手动条目');
    }
    versions = <Object?>[
      <String, Object?>{'p': cutoff, 'note': note},
    ];
  }
  final double now =
      clock?.call() ?? DateTime.now().millisecondsSinceEpoch / 1000;
  final Json clean = <String, Object?>{
    'id': id,
    'kind': kind,
    'name': name,
    'source_start': source,
    'knowledge_cutoff':
        deleted && old != null ? old['knowledge_cutoff'] : cutoff,
    'versions': versions,
    'deleted': deleted,
    'revision': expected + 1,
    'operation': operation,
    'operation_hash': hash,
    'created': old != null && old.containsKey('created') ? old['created'] : now,
    'updated': now,
  };
  return (
    <Json>[...items.where((Json row) => row['id'] != id), clean],
    clean,
    false,
  );
}

List<Json> manualRows(List<Json> items) {
  final List<Json> result = <Json>[];
  for (final Json item in items) {
    if (_truth(item['deleted'])) continue;
    final List<Json> versions =
        (item['versions']! as List<Object?>).cast<Json>();
    final String id = 'U${item['id']}';
    result.add(<String, Object?>{
      't': 'person',
      'id': id,
      'name': item['name'],
      'p': versions.first['p'],
      's': item['source_start'],
      'intro': '',
      'imp': 1,
      'manual': true,
      'entity_kind': item['kind'],
    });
    for (final Json version in versions) {
      result.add(<String, Object?>{
        't': 'profile',
        'id': id,
        'p': version['p'],
        's': item['source_start'],
        'bio': version['note'],
        'manual': true,
      });
    }
  }
  return _sorted(
    result,
    (Json a, Json b) => (a['p']! as int).compareTo(b['p']! as int),
  );
}

List<List<Object?>> manualMentions(
  List<Json> blocks,
  List<Json> items,
  List<List<Object?>> existing,
) {
  final List<Json> active =
      items.where((Json row) => !_truth(row['deleted'])).toList();
  if (active.isEmpty) return existing;
  final List<(int, int)> occupied = <(int, int)>[
    for (final List<Object?> row in existing) (row[0]! as int, row[1]! as int),
  ]..sort(
    ((int, int) a, (int, int) b) =>
        a.$1 == b.$1 ? a.$2.compareTo(b.$2) : a.$1.compareTo(b.$1),
  );
  final List<(int, int, String)> candidates = <(int, int, String)>[];
  for (final Json block in blocks) {
    if (block['k'] != 'p' && block['k'] != 'h') continue;
    final String source = block['t']! as String;
    for (final Json item in active) {
      final String name = item['name']! as String;
      if (name.isEmpty) throw const ValueError('名称须为 1—80 字');
      int at = source.indexOf(name);
      while (at >= 0) {
        final int offset = block['o']! as int;
        candidates.add((
          offset + at,
          offset + at + name.length,
          'U${item['id']}',
        ));
        at = source.indexOf(name, at + 1);
      }
    }
  }
  final List<List<Object?>> result = List<List<Object?>>.of(existing);
  for (final (int start, int end, String id) in _sorted(
    candidates,
    ((int, int, String) a, (int, int, String) b) =>
        a.$1 == b.$1
            ? (b.$2 - b.$1).compareTo(a.$2 - a.$1)
            : a.$1.compareTo(b.$1),
  )) {
    int lo = 0, hi = occupied.length;
    while (lo < hi) {
      final int mid = (lo + hi) ~/ 2;
      if (occupied[mid].$1 < start) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if ((lo > 0 && occupied[lo - 1].$2 > start) ||
        (lo < occupied.length && occupied[lo].$1 < end))
      continue;
    occupied.insert(lo, (start, end));
    result.add(<Object?>[start, end, id]);
  }
  return _sorted(
    result,
    (List<Object?> a, List<Object?> b) =>
        a[0] == b[0]
            ? (a[1]! as int).compareTo(b[1]! as int)
            : (a[0]! as int).compareTo(b[0]! as int),
  );
}

List<Json> manualRestore(Object? raw, Json book) {
  if (raw is! List<Object?> || raw.length > manualMaxItems)
    throw const ValueError('手动条目备份无效');
  final Set<Object?> seen = <Object?>{};
  final List<Json> result = <Json>[];
  for (final Object? value in raw) {
    final (String kind, String name, int cutoff, _) = manualBase(value, book);
    final Json item = value! as Json;
    if (!seen.add(item['id'])) throw const ValueError('手动条目编号重复');
    final Object? versions = item['versions'];
    if (versions is! List<Object?> ||
        versions.isEmpty ||
        versions.length > 1000)
      throw const ValueError('手动条目版本无效');
    int previous = -1;
    final List<Json> cleanVersions = <Json>[];
    for (final Object? v in versions) {
      final Json row = _obj(v, '手动条目版本无效');
      final int p = integer(row['p'], '补充位置', high: book['len']! as int);
      final Object? note = row['note'];
      if (p < previous || note is! String || note.runes.length > 3000)
        throw const ValueError('手动条目版本无效');
      previous = p;
      cleanVersions.add(<String, Object?>{'p': p, 'note': note});
    }
    if (cutoff != previous) throw const ValueError('手动条目已读范围无效');
    final int source = manualAnchor(
      book,
      name,
      cleanVersions.first['p']! as int,
    );
    if (source != item['source_start']) throw const ValueError('手动条目原文位置无效');
    final int revision = integer(
      item['revision'],
      '条目版本',
      low: 1,
      high: 1000000000,
    );
    final Object? op = item['operation'];
    if (op is! String || !_validId(op)) throw const ValueError('手动条目操作编号无效');
    final Object? hash = item['operation_hash'];
    if (hash != null &&
        (hash is! String ||
            hash.length != 64 ||
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)))
      throw const ValueError('手动条目操作摘要无效');
    result.add(<String, Object?>{
      'id': item['id'],
      'kind': kind,
      'name': name,
      'source_start': source,
      'knowledge_cutoff': cutoff,
      'versions': cleanVersions,
      'deleted': item['deleted'] == true,
      'revision': revision,
      'operation': op,
      'created': item.containsKey('created') ? item['created'] : 0,
      'updated': item.containsKey('updated') ? item['updated'] : 0,
      if (_truth(hash)) 'operation_hash': hash,
    });
  }
  return result;
}

/// Validated persistent storage for native UI callers. HTTP can use the pure
/// functions above under its existing request lock instead.
class ManualEntityStore {
  ManualEntityStore(this.file);
  final File file;

  List<Json> read(Json book) {
    if (!file.existsSync()) return <Json>[];
    try {
      return manualRestore(jsonDecode(file.readAsStringSync()), book);
    } on FormatException {
      throw const ValueError('手动条目文件已损坏，未覆盖现有资料');
    }
  }

  (List<Json>, Json?, bool) apply(
    Json payload,
    Json book,
    Json graph, {
    double Function()? clock,
  }) {
    final List<Json> items = read(book);
    final (List<Json> updated, Json? item, bool conflict) = manualApply(
      items,
      payload,
      book,
      graph,
      clock: clock,
    );
    if (!conflict && !identical(updated, items)) writeJson(file, updated);
    return (updated, item, conflict);
  }
}
