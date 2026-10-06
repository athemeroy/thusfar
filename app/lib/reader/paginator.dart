import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../data/library.dart';
import 'text_purification.dart';

/// Page geometry and type, fixed for one layout pass.
class PageSpec {
  const PageSpec({
    required this.width,
    required this.height,
    required this.fontSize,
    required this.lineHeight,
    this.letterSpacing = 0,
    this.paragraphSpacing = 0,
    this.firstLineIndent = 2,
    required this.fontFamily,
    this.fontFamilyFallback,
    required this.color,
    required this.textScaler,
  });

  final double width;
  final double height;
  final double fontSize;
  final double lineHeight;
  final double letterSpacing;
  final double paragraphSpacing;
  final double firstLineIndent;
  final String? fontFamily;
  final List<String>? fontFamilyFallback;
  final Color color;
  final TextScaler textScaler;

  double get paragraphGap => paragraphSpacing * textScaler.scale(fontSize);

  double get line => textScaler.scale(fontSize) * lineHeight;
  int get linesPerPage => math.max(1, (height / line).floor());

  TextStyle get body => TextStyle(
    fontSize: fontSize,
    height: lineHeight,
    letterSpacing: letterSpacing,
    fontFamily: fontFamily,
    fontFamilyFallback:
        fontFamilyFallback ?? const <String>['NotoSerifSC', 'serif'],
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
      other.letterSpacing == letterSpacing &&
      other.paragraphSpacing == paragraphSpacing &&
      other.firstLineIndent == firstLineIndent &&
      other.fontFamily == fontFamily &&
      other.color == color &&
      listEquals(other.fontFamilyFallback, fontFamilyFallback) &&
      other.textScaler == textScaler;

  @override
  int get hashCode => Object.hash(
    width,
    height,
    fontSize,
    lineHeight,
    letterSpacing,
    paragraphSpacing,
    firstLineIndent,
    fontFamily,
    fontFamilyFallback == null ? null : Object.hashAll(fontFamilyFallback!),
    textScaler,
    color,
  );
}

/// Paragraph indent: one placeholder before the block text, even at zero width. A
/// placeholder occupies one UTF-16 unit (U+FFFC) in the laid-out text; unlike
/// ideographic spaces it is never squeezed by justification.
const int indentShift = 1;

double indentWidth(PageSpec spec) => math.min(
  spec.firstLineIndent * spec.textScaler.scale(spec.fontSize),
  // A narrow pane must still fit text beside the indent, rather than creating
  // an empty first line that consumes source offsets or a whole page.
  math.max(0, spec.width - spec.textScaler.scale(spec.fontSize)),
);

/// RichText scales WidgetSpan children using the surrounding font size. Keep
/// the child in unscaled units so its final dimensions match the explicit
/// placeholder dimensions used by TextPainter during pagination/hit testing.
WidgetSpan indentSpan(PageSpec spec, double width) {
  final double scale = spec.textScaler.scale(spec.fontSize) / spec.fontSize;
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: SizedBox(width: width / scale, height: 1 / scale),
  );
}

/// A run of whole lines of one block on one page.
class Frag {
  const Frag({
    required this.block,
    required this.start,
    required this.end,
    required this.top,
    required this.lines,
    required this.image,
    this.leading = 0,
    int? displayStart,
    int? displayEnd,
  }) : _displayStart = displayStart,
       _displayEnd = displayEnd;

  final int block;

  /// Immutable source UTF-16 offsets inside the block text.
  final int start;
  final int end;
  final int? _displayStart;
  final int? _displayEnd;
  int get displayStart => _displayStart ?? start;
  int get displayEnd => _displayEnd ?? end;

  /// Offset of the first line inside the laid-out paragraph.
  final double top;
  final int lines;
  final bool image;

  /// Extra visual space before this fragment; never part of the source text.
  final double leading;
  double height(PageSpec spec) => leading + lines * spec.line;
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
  Paginator(
    this.book,
    this.spec, {
    Iterable<PurificationRule> rules = const <PurificationRule>[],
  }) : _purifier = TextPurifier(rules);

  final TextPurifier _purifier;
  final Map<Block, PurifiedText> _text = <Block, PurifiedText>{};
  PurifiedText textFor(Block block) =>
      _text[block] ??= block.kind == 'p' || block.kind == 'h'
      ? _purifier.apply(block.text)
      : PurifiedText.original(block.text);

  final BookData book;
  final PageSpec spec;
  final Map<int, List<PageData>> _cache = <int, List<PageData>>{};

  bool isReady(int chapter) => _cache.containsKey(chapter);

  int get paginatedChapters => _cache.length;

  List<PageData> pages(int chapter) => _cache[chapter] ??= _layout(chapter);

  final Map<Block, double> _indents = <Block, double>{};

  /// Resolved per paragraph: a long first word may need the full line width.
  double indentFor(Block block) {
    if (!_indents.containsKey(block)) painterFor(block).dispose();
    return _indents[block] ?? 0;
  }

  /// Lines of text a block uses at this spec, and its painter.
  TextPainter painterFor(Block b) {
    final bool heading = b.kind == 'h';
    final String text = textFor(b).text;
    TextPainter measure(double indent) {
      final TextPainter painter = TextPainter(
        text: heading
            ? TextSpan(text: text, style: spec.heading)
            : TextSpan(
                style: spec.body,
                children: <InlineSpan>[
                  indentSpan(spec, indent),
                  TextSpan(text: text),
                ],
              ),
        textAlign: heading ? TextAlign.center : TextAlign.justify,
        textDirection: TextDirection.ltr,
        strutStyle: heading ? null : spec.strut,
        textScaler: spec.textScaler,
      );
      if (!heading) {
        painter.setPlaceholderDimensions(<PlaceholderDimensions>[
          PlaceholderDimensions(
            size: Size(indent, 1),
            alignment: PlaceholderAlignment.middle,
          ),
        ]);
      }
      painter.layout(minWidth: spec.width, maxWidth: spec.width);
      return painter;
    }

    double indent = heading ? 0 : (_indents[b] ?? indentWidth(spec));
    TextPainter painter = measure(indent);
    if (!heading && !_indents.containsKey(b)) {
      // Flutter may break a CJK glyph with positive tracking, or an entire
      // English word, after the placeholder. Drop the indent in that paragraph
      // rather than creating a blank first line (or a source-empty page).
      if (indent > 0 &&
          text.isNotEmpty &&
          painter.getLineBoundary(const TextPosition(offset: 0)).end <=
              indentShift) {
        painter.dispose();
        indent = 0;
        painter = measure(indent);
      }
      _indents[b] = indent;
    }
    return painter;
  }

  int _imageLines() => math.min(
    spec.linesPerPage,
    math.max(1, (spec.linesPerPage * 0.55).floor()),
  );

  List<PageData> _layout(int c) {
    final Chapter ch = book.chapters[c];
    final int capacity = spec.linesPerPage;
    final double line = spec.line;
    final List<PageData> out = <PageData>[];
    List<Frag> current = <Frag>[];
    double used = 0;
    final double availableHeight = capacity * line;

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
        if (used + need * line > availableHeight + 0.000001) flush();
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
        used += need * line;
        continue;
      }
      final PurifiedText mapped = textFor(b);
      if (mapped.text.isEmpty) continue;
      Frag fragment(
        int a,
        int z,
        double top,
        int lines, {
        double leading = 0,
      }) => Frag(
        block: bi,
        start: mapped.sourceStart(a),
        end: mapped.sourceEnd(z),
        displayStart: a,
        displayEnd: z,
        top: top,
        lines: lines,
        image: false,
        leading: leading,
      );
      final TextPainter tp = painterFor(b);
      final bool heading = b.kind == 'h';
      final int shift = heading ? 0 : indentShift;
      final List<LineMetrics> metrics = tp.computeLineMetrics();
      // Headings can be longer than a short foldable viewport. Split them by
      // measured lines rather than letting one unbounded fragment overflow.
      if (heading) {
        final int textLines = math.max(1, (tp.height / line).ceil());
        if (textLines <= capacity) {
          if (used + (textLines + (current.isEmpty ? 0 : 1)) * line >
              availableHeight + 0.000001) {
            flush();
          }
          final int extra = current.isEmpty ? 0 : 1;
          current.add(
            fragment(0, mapped.text.length, -extra * line, textLines + extra),
          );
          used += (textLines + extra) * line;
          tp.dispose();
          continue;
        }
        int from = 0;
        if (current.isNotEmpty) flush();
        while (from < metrics.length) {
          final double top = metrics[from].baseline - metrics[from].ascent;
          int to = from;
          double bottom = top;
          while (to < metrics.length) {
            final LineMetrics metric = metrics[to];
            final double nextBottom = metric.baseline + metric.descent;
            if (to > from && nextBottom - top > capacity * line) break;
            bottom = nextBottom;
            to++;
          }
          int boundary(int index) => tp
              .getLineBoundary(
                tp.getPositionForOffset(
                  Offset(
                    1,
                    metrics[index].baseline -
                        metrics[index].ascent +
                        metrics[index].height / 2,
                  ),
                ),
              )
              .start;
          current.add(
            fragment(
              from == 0 ? 0 : boundary(from),
              to == metrics.length ? mapped.text.length : boundary(to),
              top,
              math.min(capacity, math.max(1, ((bottom - top) / line).ceil())),
            ),
          );
          used = current.last.height(spec);
          from = to;
          if (from < metrics.length) flush();
        }
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
        double leading = from == 0 && current.isNotEmpty
            ? spec.paragraphGap
            : 0;
        // Keep the gap with its first line and omit it after a page break.
        // Continuations use every available line without repeating the gap.
        if (availableHeight - used - leading < line - 0.000001) {
          flush();
          leading = 0;
        }
        final int room = math.max(
          1,
          ((availableHeight - used - leading + 0.000001) / line).floor(),
        );
        final int take = math.min(room, total - from);
        final int a = from == 0 ? 0 : starts[from];
        final int z = from + take >= total
            ? mapped.text.length
            : starts[from + take];
        current.add(fragment(a, z, from * line, take, leading: leading));
        used += take * line + leading;
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
    // Expanded replacements may share one source range across several pages.
    // Enter at the first containing page, never skip to its last occurrence.
    // Half-open ranges retain normal next-page behavior at an exact boundary.
    for (int i = 0; i < ps.length; i++) {
      if (ps[i].start <= offset && offset < ps[i].end) return i;
    }
    // A fully removed paragraph/heading leaves a gap in visible source ranges.
    // Enter at the next visible text rather than jumping backward to a page
    // that ends before the requested source. At a hidden chapter tail, keep
    // the last page. The containing-page pass above still wins for expansions.
    for (int i = 0; i < ps.length; i++) {
      if (ps[i].start > offset) return i;
    }
    return ps.length - 1;
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
    return math.max(1.0, chars / count);
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
