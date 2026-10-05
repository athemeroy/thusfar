import 'dart:math' as math;

class SourceSearchBlock {
  const SourceSearchBlock({
    required this.chapter,
    required this.block,
    required this.start,
    required this.text,
  });
  final int chapter;
  final int block;
  final int start;
  final String text;
}

class SourceSearchHit {
  const SourceSearchHit({
    required this.chapter,
    required this.block,
    required this.start,
    required this.match,
    required this.before,
    required this.after,
  });
  final int chapter;
  final int block;
  final int start;
  final String match;
  final String before;
  final String after;
}

/// Enumerates every occurrence, bounded by the current reading position.
/// Case-insensitive matching uses original-string match offsets, avoiding
/// Unicode lowercase expansions shifting saved/jumped source coordinates.
Future<List<SourceSearchHit>> searchSourceText(
  List<SourceSearchBlock> blocks,
  String query,
  int cutoff, {
  bool Function()? cancelled,
}) async {
  if (query.trim().isEmpty) return const <SourceSearchHit>[];
  final RegExp pattern = RegExp(
    RegExp.escape(query.trim()),
    caseSensitive: false,
  );
  final List<SourceSearchHit> hits = <SourceSearchHit>[];
  int scanned = 0;
  for (final SourceSearchBlock block in blocks) {
    if (block.start >= cutoff) break;
    if (++scanned % 32 == 0) {
      await Future<void>.delayed(Duration.zero);
      if (cancelled?.call() == true) return const <SourceSearchHit>[];
    }
    final int length = (cutoff - block.start).clamp(0, block.text.length);
    final String visible = block.text.substring(0, length);
    for (final RegExpMatch match in pattern.allMatches(visible)) {
      int a = math.max(0, match.start - 24);
      int z = math.min(length, match.end + 50);
      if (a > 0 && _low(visible.codeUnitAt(a))) a++;
      if (z > 0 && _high(visible.codeUnitAt(z - 1))) z--;
      hits.add(
        SourceSearchHit(
          chapter: block.chapter,
          block: block.block,
          start: block.start + match.start,
          match: match.group(0)!,
          before: visible.substring(a, match.start),
          after: visible.substring(match.end, z),
        ),
      );
      if (hits.length % 128 == 0) {
        await Future<void>.delayed(Duration.zero);
        if (cancelled?.call() == true) return const <SourceSearchHit>[];
      }
    }
  }
  return hits;
}

bool _low(int code) => code >= 0xdc00 && code <= 0xdfff;
bool _high(int code) => code >= 0xd800 && code <= 0xdbff;
