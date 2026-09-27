/// Book text is immutable across clients; spoiler verdicts are not. Title
/// checks may finish after a book has already been copied to another device.
typedef Json = Map<String, Object?>;

class ChapterVerdictConflict implements Exception {
  const ChapterVerdictConflict();
}

bool _same(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every(
          (Object? key) => b.containsKey(key) && _same(a[key], b[key]),
        );
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        Iterable<int>.generate(a.length).every((int i) => _same(a[i], b[i]));
  }
  return a == b;
}

Json _withoutVerdict(Json chapter) => <String, Object?>{
  for (final MapEntry<String, Object?> field in chapter.entries)
    if (field.key != 'spoil' && field.key != 'spoilSource')
      field.key: field.value,
};

bool sameChapterContent(Object? left, Object? right) {
  if (left is! List || right is! List || left.length != right.length) {
    return false;
  }
  for (int i = 0; i < left.length; i++) {
    if (left[i] is! Json || right[i] is! Json) return false;
    if (!_same(
      _withoutVerdict(left[i] as Json),
      _withoutVerdict(right[i] as Json),
    )) {
      return false;
    }
  }
  return true;
}

bool titleCheckPending(Object? status) {
  if (status is! Json || status['quality'] is! Json) return false;
  final Object? pending = (status['quality'] as Json)['pending'];
  return pending is List && pending.contains('chapter-titles');
}

bool _verified(Json chapter, bool pending) {
  final Object? verdict = chapter['spoil'];
  if (verdict is! bool) return false;
  // The old fallback inserted true for unchecked titles but never false.
  return verdict == false || chapter['spoilSource'] == 'model' || !pending;
}

/// Merge only verified title decisions into a copy of [localBook]. An old
/// blanket-hidden value from an unfinished check is discarded. Contradictory
/// verified decisions need a human choice; neither is silently overwritten.
Json mergeChapterVerdicts(
  Json localBook,
  Json incomingBook, {
  bool localCheckPending = false,
  bool incomingCheckPending = false,
}) {
  final Object? localRaw = localBook['chapters'];
  final Object? incomingRaw = incomingBook['chapters'];
  if (!sameChapterContent(localRaw, incomingRaw)) {
    throw const ChapterVerdictConflict();
  }
  final List<Object?> local = localRaw! as List<Object?>;
  final List<Object?> incoming = incomingRaw! as List<Object?>;
  final List<Json> merged = <Json>[];
  for (int i = 0; i < local.length; i++) {
    final Json old = local[i] as Json;
    final Json next = incoming[i] as Json;
    final bool oldVerified = _verified(old, localCheckPending);
    final bool nextVerified = _verified(next, incomingCheckPending);
    if (oldVerified && nextVerified && old['spoil'] != next['spoil']) {
      throw const ChapterVerdictConflict();
    }
    final Json result =
        <String, Object?>{...old}
          ..remove('spoil')
          ..remove('spoilSource');
    if (oldVerified || nextVerified) {
      result['spoil'] = oldVerified ? old['spoil'] : next['spoil'];
      result['spoilSource'] = 'model';
    }
    merged.add(result);
  }
  return <String, Object?>{...localBook, 'chapters': merged};
}
