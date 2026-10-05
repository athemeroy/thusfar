/// Verify a UI selection against the book's UTF-16 source coordinates before
/// allowing it to extend Ask's conservative scroll prefix. No DOM/user text
/// becomes evidence without an exact source match.
library;

typedef AskSourceJson = Map<String, Object?>;

class VerifiedAskFragment {
  const VerifiedAskFragment(this.blockIndex, this.start, this.end, this.text);
  final int blockIndex;
  final int start;
  final int end;
  final String text;
}

List<VerifiedAskFragment> verifyAskSelection({
  required List<AskSourceJson> blocks,
  required int chapterStart,
  required int chapterEnd,
  required String? text,
  required int? start,
  required int? end,
}) {
  if (text == null ||
      text.trim().isEmpty ||
      start == null ||
      end == null ||
      start < 0 ||
      end <= start ||
      chapterStart < 0 ||
      chapterEnd > blocks.length ||
      chapterStart >= chapterEnd) {
    return const <VerifiedAskFragment>[];
  }
  final List<VerifiedAskFragment> result = <VerifiedAskFragment>[];
  for (int i = chapterStart; i < chapterEnd; i++) {
    final AskSourceJson block = blocks[i];
    final int offset = (block['o'] as num?)?.toInt() ?? -1;
    final String source = block['t'] as String? ?? '';
    if (offset < 0 || offset >= end || offset + source.length <= start) {
      continue;
    }
    if (block['k'] != 'p') return const <VerifiedAskFragment>[];
    final int a = (start - offset).clamp(0, source.length);
    final int z = (end - offset).clamp(a, source.length);
    bool low(int at) =>
        at < source.length &&
        source.codeUnitAt(at) >= 0xdc00 &&
        source.codeUnitAt(at) <= 0xdfff;
    if (low(a) || low(z)) return const <VerifiedAskFragment>[];
    result.add(
      VerifiedAskFragment(i, offset + a, offset + z, source.substring(a, z)),
    );
  }
  if (result.isEmpty ||
      result.first.start != start ||
      result.last.end != end ||
      result.map((VerifiedAskFragment row) => row.text).join('\n').trim() !=
          text.trim()) {
    return const <VerifiedAskFragment>[];
  }
  return result;
}
