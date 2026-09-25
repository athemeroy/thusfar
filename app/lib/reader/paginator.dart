import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../data/library.dart';

/// Page geometry and type, fixed for one layout pass.
class PageSpec {
  const PageSpec({
    required this.width,
    required this.height,
    required this.fontSize,
    required this.lineHeight,
    required this.fontFamily,
    required this.color,
    required this.textScaler,
  });

  final double width;
  final double height;
  final double fontSize;
  final double lineHeight;
  final String? fontFamily;
  final Color color;
  final TextScaler textScaler;

  double get line => textScaler.scale(fontSize) * lineHeight;
  int get linesPerPage => math.max(1, (height / line).floor());

  TextStyle get body => TextStyle(
    fontSize: fontSize,
    height: lineHeight,
    fontFamily: fontFamily,
    fontFamilyFallback: const <String>['NotoSerifSC', 'serif'],
    color: color,
    leadingDistribution: TextLeadingDistribution.even,
  );

  TextStyle get heading =>
      body.copyWith(fontSize: fontSize * 1.2, fontWeight: FontWeight.w600);

  StrutStyle get strut => StrutStyle(
    fontSize: fontSize,
    height: lineHeight,
    forceStrutHeight: true,
    leadingDistribution: TextLeadingDistribution.even,
  );

  @override
  bool operator ==(Object other) =>
      other is PageSpec &&
      other.width == width &&
      other.height == height &&
      other.fontSize == fontSize &&
      other.lineHeight == lineHeight &&
      other.fontFamily == fontFamily &&
      other.textScaler == textScaler;

  @override
  int get hashCode =>
      Object.hash(width, height, fontSize, lineHeight, fontFamily, textScaler);
}

/// Paragraph indent: a two-character placeholder before the block text. A
/// placeholder occupies one UTF-16 unit (U+FFFC) in the laid-out text; unlike
/// ideographic spaces it is never squeezed by justification.
const int indentShift = 1;

double indentWidth(PageSpec spec) => 2 * spec.textScaler.scale(spec.fontSize);

/// A run of whole lines of one block on one page.
class Frag {
  const Frag({
    required this.block,
    required this.start,
    required this.end,
    required this.top,
    required this.lines,
    required this.image,
  });

  final int block;

  /// UTF-16 offsets inside the block text.
  final int start;
  final int end;

  /// Offset of the first line inside the laid-out paragraph.
  final double top;
  final int lines;
  final bool image;
}

class PageData {
  PageData({
    required this.chapter,
    required this.index,
    required this.frags,
    required this.start,
    required this.end,
  });

  final int chapter;
  final int index;
  final List<Frag> frags;

  /// Absolute UTF-16 offset of the first character on this page.
  final int start;

  /// Absolute offset just after the last character: the knowledge cutoff.
  final int end;
}

/// Lays out chapters into pages on demand and caches them.
class Paginator {
  Paginator(this.book, this.spec);

  final BookData book;
  final PageSpec spec;
  final Map<int, List<PageData>> _cache = <int, List<PageData>>{};

  bool isReady(int chapter) => _cache.containsKey(chapter);

  int get paginatedChapters => _cache.length;

  List<PageData> pages(int chapter) => _cache[chapter] ??= _layout(chapter);

  /// Lines of text a block uses at this spec, and its painter.
  TextPainter painterFor(Block b) {
    final bool heading = b.kind == 'h';
    final TextPainter tp = TextPainter(
      text: heading
          ? TextSpan(text: b.text, style: spec.heading)
          : TextSpan(
              style: spec.body,
              children: <InlineSpan>[
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: SizedBox(width: indentWidth(spec), height: 1),
                ),
                TextSpan(text: b.text),
              ],
            ),
      textAlign: heading ? TextAlign.center : TextAlign.justify,
      textDirection: TextDirection.ltr,
      strutStyle: heading ? null : spec.strut,
      textScaler: spec.textScaler,
    );
    if (!heading) {
      tp.setPlaceholderDimensions(<PlaceholderDimensions>[
        PlaceholderDimensions(
          size: Size(indentWidth(spec), 1),
          alignment: PlaceholderAlignment.middle,
        ),
      ]);
    }
    tp.layout(minWidth: spec.width, maxWidth: spec.width);
    return tp;
  }

  int _imageLines() => math.max(3, (spec.linesPerPage * 0.55).floor());

  List<PageData> _layout(int c) {
    final Chapter ch = book.chapters[c];
    final int capacity = spec.linesPerPage;
    final double line = spec.line;
    final List<PageData> out = <PageData>[];
    List<Frag> current = <Frag>[];
    int used = 0;

    void flush() {
      if (current.isEmpty) return;
      final Frag first = current.first;
      final Frag last = current.last;
      out.add(
        PageData(
          chapter: c,
          index: out.length,
          frags: current,
          start: book.blocks[first.block].o + first.start,
          end: book.blocks[last.block].o + last.end,
        ),
      );
      current = <Frag>[];
      used = 0;
    }

    for (int bi = ch.b0; bi < ch.b1; bi++) {
      final Block b = book.blocks[bi];
      if (b.kind == 'img') {
        final int need = _imageLines();
        if (used + need > capacity) flush();
        current.add(
          Frag(
            block: bi,
            start: 0,
            end: b.text.length,
            top: 0,
            lines: need,
            image: true,
          ),
        );
        used += need;
        continue;
      }
      final TextPainter tp = painterFor(b);
      final bool heading = b.kind == 'h';
      final int shift = heading ? 0 : indentShift;
      final List<LineMetrics> metrics = tp.computeLineMetrics();
      // Headings use their own line height; count them in body lines.
      final double headingHeight = tp.height;
      if (heading) {
        final int need =
            math.max(1, (headingHeight / line).ceil()) +
            (current.isEmpty ? 0 : 1);
        if (used + need > capacity) flush();
        final int extra = current.isEmpty ? 0 : 1;
        current.add(
          Frag(
            block: bi,
            start: 0,
            end: b.text.length,
            top: -extra * line,
            lines: need,
            image: false,
          ),
        );
        used += need;
        tp.dispose();
        continue;
      }
      final int total = metrics.length;
      final List<int> starts = <int>[
        for (int i = 0; i < total; i++)
          math.max(
            0,
            tp
                    .getLineBoundary(
                      tp.getPositionForOffset(Offset(1, i * line + line / 2)),
                    )
                    .start -
                shift,
          ),
      ];
      int from = 0;
      while (from < total) {
        if (used >= capacity) flush();
        final int take = math.min(capacity - used, total - from);
        final int a = from == 0 ? 0 : starts[from];
        final int z = from + take >= total
            ? b.text.length
            : starts[from + take];
        current.add(
          Frag(
            block: bi,
            start: a,
            end: z,
            top: from * line,
            lines: take,
            image: false,
          ),
        );
        used += take;
        from += take;
      }
      tp.dispose();
    }
    flush();
    if (out.isEmpty) {
      out.add(
        PageData(
          chapter: c,
          index: 0,
          frags: const <Frag>[],
          start: ch.o0,
          end: ch.o0,
        ),
      );
    }
    return out;
  }

  /// Page index inside [chapter] containing absolute [offset].
  int pageOf(int chapter, int offset) {
    final List<PageData> ps = pages(chapter);
    for (int i = ps.length - 1; i >= 0; i--) {
      if (ps[i].start <= offset) return i;
    }
    return 0;
  }

  /// Characters per page, from what has been laid out so far.
  double charsPerPage() {
    int chars = 0;
    int count = 0;
    for (final List<PageData> ps in _cache.values) {
      for (final PageData p in ps) {
        chars += p.end - p.start;
        count++;
      }
    }
    if (count == 0) {
      return spec.linesPerPage *
          math.max(1, spec.width / (spec.textScaler.scale(spec.fontSize))) *
          0.9;
    }
    return chars / count;
  }

  /// Global page number of chapter page, exact when every earlier chapter is laid out.
  (int, bool) globalPage(int chapter, int index) {
    double n = 0;
    bool exact = true;
    for (int c = 0; c < chapter; c++) {
      final List<PageData>? ps = _cache[c];
      if (ps != null) {
        n += ps.length;
      } else {
        exact = false;
        final Chapter ch = book.chapters[c];
        n += math.max(1, ((ch.o1 - ch.o0) / charsPerPage()).ceil());
      }
    }
    return (n.round() + index + 1, exact);
  }

  (int, bool) totalPages() {
    final (int n, bool exact) = globalPage(book.chapters.length - 1, 0);
    final int last = book.chapters.length - 1;
    final List<PageData>? ps = _cache[last];
    final Chapter ch = book.chapters[last];
    final int lastCount =
        ps?.length ?? math.max(1, ((ch.o1 - ch.o0) / charsPerPage()).ceil());
    return (n - 1 + lastCount, exact && ps != null);
  }

  /// Global page number of an absolute offset (for 「第 N 页」 labels).
  int pageNumberOf(int offset) {
    final int c = book.chapterAt(offset);
    if (_cache.containsKey(c)) return globalPage(c, pageOf(c, offset)).$1;
    final Chapter ch = book.chapters[c];
    final (int base, _) = globalPage(c, 0);
    return base + ((offset - ch.o0) / charsPerPage()).floor();
  }
}
