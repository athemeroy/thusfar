/// Durable browser scopes. Chapter ranges are independent cited drafts; a
/// read boundary is frozen to the exact visible source end, never a high-water mark.
library;

bool validPreparationScope(Object? raw) {
  if (raw is! String) return false;
  if (const <String>{'first', 'read', 'all'}.contains(raw)) return true;
  final RegExpMatch? range = RegExp(
    r'^range:(\d{1,7}):(\d{1,7})$',
  ).firstMatch(raw);
  if (range != null) return int.parse(range[1]!) <= int.parse(range[2]!);
  return RegExp(r'^read:\d{1,10}$').hasMatch(raw);
}

class PreparationScope {
  const PreparationScope(
    this.kind, {
    this.fromChapter = 0,
    this.toChapter = 0,
    this.cutoff,
  });
  factory PreparationScope.parse(String raw) {
    if (!validPreparationScope(raw)) return const PreparationScope('first');
    final List<String> parts = raw.split(':');
    return PreparationScope(
      parts.first,
      fromChapter: parts.first == 'range' ? int.parse(parts[1]) : 0,
      toChapter: parts.first == 'range' ? int.parse(parts[2]) : 0,
      cutoff: parts.first == 'read' && parts.length > 1
          ? int.parse(parts[1])
          : null,
    );
  }
  final String kind;
  final int fromChapter;
  final int toChapter;
  final int? cutoff;
  String get encoded => switch (kind) {
    'range' => 'range:$fromChapter:$toChapter',
    'read' when cutoff != null => 'read:$cutoff',
    _ => kind,
  };
  String get label => switch (kind) {
    'range' => '第 ${fromChapter + 1}–${toChapter + 1} 章',
    'all' => '整本书',
    'read' => '到本次阅读位置',
    _ => '第一章试整理',
  };
}
