/// A textual fragment actually displayed by the reader, in UTF-16 coordinates.
class SourceSlice {
  const SourceSlice({required this.text, required this.start});
  final String text;
  final int start;
  int get end => start + text.length;
}

class SourceSelection {
  const SourceSelection(this.start, this.end, this.text);
  final int start;
  final int end;
  final String text;
}

/// Flutter selection may add layout indentation/newlines. Map normalized
/// whitespace back to source, but reject repeated or non-contiguous matches.
/// Never find a quote in the hidden remainder of a paragraph/chapter.
SourceSelection? resolveSourceSelection(
  String selected,
  List<SourceSlice> slices,
) {
  final RegExp space = RegExp(r'\s|\u3000');
  String normalize(String value) =>
      value.replaceAll(RegExp(r'[\s\u3000]+'), ' ').trim();
  final String query = normalize(selected);
  if (query.isEmpty) return null;
  final StringBuffer buffer = StringBuffer();
  final List<int?> offsets = <int?>[];
  bool lastSpace = false;
  for (final SourceSlice slice in slices) {
    if (buffer.isNotEmpty && !lastSpace) {
      buffer.write(' ');
      offsets.add(null);
      lastSpace = true;
    }
    for (int i = 0; i < slice.text.length; i++) {
      final String char = slice.text[i];
      if (space.hasMatch(char)) {
        if (!lastSpace) {
          buffer.write(' ');
          offsets.add(slice.start + i);
        }
        lastSpace = true;
      } else {
        buffer.write(char);
        offsets.add(slice.start + i);
        lastSpace = false;
      }
    }
  }
  final String haystack = buffer.toString();
  final int at = haystack.indexOf(query);
  if (at < 0 || haystack.indexOf(query, at + 1) >= 0) return null;
  final int? start = offsets[at];
  final int? last = offsets[at + query.length - 1];
  if (start == null || last == null || last < start) return null;
  final int end = last + 1;
  final List<String> parts = <String>[];
  int covered = start;
  for (final SourceSlice slice in slices) {
    if (slice.end <= start || slice.start >= end) continue;
    if (slice.start > covered + (parts.isEmpty ? 0 : 1)) return null;
    final int a = (start - slice.start).clamp(0, slice.text.length);
    final int z = (end - slice.start).clamp(a, slice.text.length);
    parts.add(slice.text.substring(a, z));
    covered = slice.start + z;
  }
  if (covered != end) return null;
  final String text = parts.join('\n');
  if (text.isEmpty || _splitsSurrogate(text)) return null;
  return SourceSelection(start, end, text);
}

bool _splitsSurrogate(String text) {
  for (int i = 0; i < text.length; i++) {
    final int code = text.codeUnitAt(i);
    if (code >= 0xd800 && code <= 0xdbff) {
      if (++i >= text.length ||
          text.codeUnitAt(i) < 0xdc00 ||
          text.codeUnitAt(i) > 0xdfff) {
        return true;
      }
    } else if (code >= 0xdc00 && code <= 0xdfff) {
      return true;
    }
  }
  return false;
}
