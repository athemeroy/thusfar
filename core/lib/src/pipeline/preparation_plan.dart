/// A durable, absolute authorization boundary for one preparation task.
library;

import '../errors.dart';

typedef Json = Map<String, Object?>;

Json validatePreparationPlan(Object? raw, Json book) {
  if (raw is! Json || raw['version'] != 1) {
    throw const ValueError('整理范围格式无效，请重新选择范围');
  }
  final Object? end = raw['end_offset'];
  final Object? length = book['len'];
  if (end is! int || end <= 0 || length is! int || end > length) {
    throw const ValueError('整理终点超出正文范围，请重新选择范围');
  }
  final Object? scope = raw['scope'];
  if (!const <String>{
    'first',
    'read',
    'through',
    'range',
    'all',
  }.contains(scope)) {
    throw const ValueError('整理范围类型无效，请重新选择范围');
  }
  final int count = (book['chapters'] as List<Object?>?)?.length ?? 0;
  final Json result = <String, Object?>{
    'version': 1,
    'end_offset': end,
    'scope': scope,
  };
  for (final String key in <String>['goal_start_chapter', 'goal_end_chapter']) {
    final Object? value = raw[key];
    if (value == null) continue;
    if (value is! int || value < 0 || value >= count) {
      throw const ValueError('整理章节超出范围，请重新选择范围');
    }
    result[key] = value;
  }
  final int? first = result['goal_start_chapter'] as int?;
  final int? last = result['goal_end_chapter'] as int?;
  if (first != null && last != null && first > last) {
    throw const ValueError('整理起始章节不能晚于结束章节');
  }
  final List<Json> chapters =
      (book['chapters'] as List<Object?>? ?? const <Object?>[])
          .whereType<Json>()
          .toList();
  final Json? firstBody =
      chapters
          .where(
            (Json chapter) =>
                (chapter['kind'] ?? 'body') == 'body' &&
                chapter['o0'] is int &&
                chapter['o1'] is int &&
                (chapter['o1']! as int) > (chapter['o0']! as int),
          )
          .firstOrNull;
  if ((scope == 'all' && end != length) ||
      (scope == 'first' && end != firstBody?['o1']) ||
      (scope == 'range' &&
          (first == null ||
              last == null ||
              last >= chapters.length ||
              end != chapters[last]['o1']))) {
    throw const ValueError('整理终点与所选章节不一致，请重新选择范围');
  }
  return result;
}

/// A model-safe prefix for genre detection. Chapter indices are rebuilt only
/// in this temporary view; the canonical source and segment geometry stay fixed.
Json preparationBookPrefix(Json book, int end) {
  final List<Json> blocks = <Json>[];
  final List<int> originals = <int>[];
  final List<Object?> source = book['blocks']! as List<Object?>;
  for (int i = 0; i < source.length; i++) {
    final Json block = source[i]! as Json;
    final int offset = block['o']! as int;
    if (offset >= end) break;
    final String text = block['t']! as String;
    int take = (end - offset).clamp(0, text.length);
    if (take > 0 &&
        take < text.length &&
        text.codeUnitAt(take - 1) >= 0xd800 &&
        text.codeUnitAt(take - 1) <= 0xdbff &&
        text.codeUnitAt(take) >= 0xdc00 &&
        text.codeUnitAt(take) <= 0xdfff) {
      take--;
    }
    if (take == 0) continue;
    blocks.add(<String, Object?>{...block, 't': text.substring(0, take)});
    originals.add(i);
  }
  final List<Json> chapters = <Json>[];
  for (final Object? raw in book['chapters']! as List<Object?>) {
    final Json chapter = raw! as Json;
    if ((chapter['o1']! as int) > end) continue;
    final int b0 = chapter['b0']! as int;
    final int b1 = chapter['b1']! as int;
    final int start = originals.indexWhere((i) => i >= b0);
    final int stop = originals.indexWhere((i) => i >= b1);
    if (start < 0) continue;
    chapters.add(<String, Object?>{
      ...chapter,
      'b0': start,
      'b1': stop < 0 ? blocks.length : stop,
    });
  }
  return <String, Object?>{
    ...book,
    'len': end,
    'blocks': blocks,
    'chapters': chapters,
  };
}
