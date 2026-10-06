import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:thusfar_core/thusfar_core.dart';

import '../data/library.dart';
import '../ui/theme.dart';
import 'paginator.dart';
import 'text_purification.dart';
import 'image_viewer.dart';

/// What the page needs to draw its AI and personal layers.
class PageLayers {
  const PageLayers({
    required this.world,
    required this.cutoff,
    required this.notes,
    this.selection,
    this.flash,
  });

  final World? world;
  final int cutoff;
  final List<Json> notes;

  /// Absolute (start, end) of the reader's current selection.
  final (int, int)? selection;

  /// Absolute (start, end) briefly highlighted after a jump.
  final (int, int)? flash;
}

typedef NameTap = void Function(String personId);

/// One laid-out page. Every fragment renders the whole paragraph clipped to
/// its lines, so justification and line breaks match the pagination exactly.
class PageBody extends StatelessWidget {
  const PageBody({
    super.key,
    required this.page,
    required this.pager,
    required this.layers,
    required this.onName,
    this.onLongPressAt,
  });

  final PageData page;
  final Paginator pager;
  final PageLayers layers;
  final NameTap onName;
  final void Function(int absoluteOffset)? onLongPressAt;

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final PageSpec spec = pager.spec;
    final BookData book = pager.book;
    return SizedBox(
      width: spec.width,
      height: spec.height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (page.frags.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('本章没有可显示的文字，可翻至下一章或在文本净化中停用规则'),
            ),
          for (final Frag f in page.frags)
            if (f.image)
              SizedBox(
                height: f.lines * spec.line,
                child: _image(context, book, book.blocks[f.block], t),
              )
            else
              _Fragment(
                frag: f,
                pager: pager,
                layers: layers,
                onName: onName,
                onLongPressAt: onLongPressAt,
                tokens: t,
              ),
        ],
      ),
    );
  }

  Widget _image(BuildContext context, BookData book, Block b, Tokens t) {
    final Object? rawAlt = b.raw['alt'];
    final String? alt = rawAlt is String && rawAlt.trim().isNotEmpty
        ? rawAlt
        : null;
    final File f = File('${book.entry.dir.path}/img/${b.src}');
    if (!f.existsSync()) {
      return Semantics(
        image: true,
        label: alt == null ? '图片未保存' : '图片未保存。$alt',
        child: ExcludeSemantics(
          child: Center(
            child: Icon(Icons.image_not_supported_outlined, color: t.ink3),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: InkWell(
        onTap: () => openReaderImage(context, FileImage(f), label: alt),
        child: Image.file(
          f,
          fit: BoxFit.contain,
          semanticLabel: alt,
          errorBuilder: (_, _, _) => Center(
            child: Text('图片无法加载', style: TextStyle(color: t.ink3)),
          ),
        ),
      ),
    );
  }
}

class _Fragment extends StatelessWidget {
  const _Fragment({
    required this.frag,
    required this.pager,
    required this.layers,
    required this.onName,
    required this.onLongPressAt,
    required this.tokens,
  });

  final Frag frag;
  final Paginator pager;
  final PageLayers layers;
  final NameTap onName;
  final void Function(int)? onLongPressAt;
  final Tokens tokens;

  @override
  Widget build(BuildContext context) {
    final PageSpec spec = pager.spec;
    final Block b = pager.book.blocks[frag.block];
    final bool heading = b.kind == 'h';
    final int shift = heading ? 0 : indentShift;
    final TextSpan span = buildSpan(b, heading, shift);
    final Widget text = RichText(
      text: span,
      textAlign: heading ? TextAlign.center : TextAlign.justify,
      strutStyle: heading ? null : spec.strut,
      textScaler: spec.textScaler,
    );
    return SizedBox(
      height: frag.lines * spec.line,
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minHeight: 0,
          maxHeight: double.infinity,
          child: Transform.translate(
            offset: Offset(0, -frag.top),
            child: SizedBox(width: spec.width, child: text),
          ),
        ),
      ),
    );
  }

  TextSpan buildSpan(Block b, bool heading, int shift) {
    final PageSpec spec = pager.spec;
    final PurifiedText mapped = pager.textFor(b);
    final String text = mapped.text;
    final int o = b.o;
    // Boundaries where any styling changes.
    final Set<int> cuts = <int>{
      0,
      frag.displayStart,
      frag.displayEnd,
      text.length,
    };
    final List<Mention> mentions = <Mention>[];
    final World? w = layers.world;
    if (w != null) {
      int last = -1;
      for (final Mention m in pager.book.mentions(pager.book.chapterAt(o))) {
        if (m.start < o || m.end > b.end || m.start < last) continue;
        final Person? p = w.person(m.id);
        if (p == null || m.start >= layers.cutoff) continue;
        mentions.add(m);
        last = m.end;
        cuts
          ..add(mapped.displayStart(m.start - o))
          ..add(mapped.displayEnd(m.end - o));
      }
    }
    final List<(int, int)> mine = <(int, int)>[];
    for (final Json n in layers.notes) {
      if (n['kind'] != 'note') continue;
      final int s = math.max((n['start']! as num).toInt(), o);
      final int e = math.min((n['end']! as num).toInt(), b.end);
      if (e > s) {
        mine.add((s, e));
        cuts
          ..add(mapped.displayStart(s - o))
          ..add(mapped.displayEnd(e - o));
      }
    }
    final (int, int)? sel = layers.selection;
    if (sel != null && sel.$2 > o && sel.$1 < b.end) {
      cuts
        ..add(mapped.displayStart(sel.$1 - o))
        ..add(mapped.displayEnd(sel.$2 - o));
    }
    final (int, int)? flash = layers.flash;
    if (flash != null && flash.$2 > o && flash.$1 < b.end) {
      cuts
        ..add(mapped.displayStart(flash.$1 - o))
        ..add(mapped.displayEnd(flash.$2 - o));
    }
    final List<int> points =
        cuts.where((int x) => x >= 0 && x <= text.length).toList()..sort();
    final List<InlineSpan> children = <InlineSpan>[];
    if (shift > 0) {
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: SizedBox(width: indentWidth(spec), height: 1),
        ),
      );
    }
    for (int i = 0; i + 1 < points.length; i++) {
      final int a = points[i];
      final int z = points[i + 1];
      if (z <= a) continue;
      final int absA = o + mapped.sourceStart(a);
      final int absZ = o + mapped.sourceEnd(z);
      Mention? m;
      for (final Mention x in mentions) {
        if (x.start < absZ && absA < x.end) {
          m = x;
          break;
        }
      }
      final bool isNote = mine.any(
        ((int, int) r) => r.$1 < absZ && absA < r.$2,
      );
      final bool isSel = sel != null && sel.$1 < absZ && absA < sel.$2;
      final bool isFlash = flash != null && flash.$1 < absZ && absA < flash.$2;
      Color? bg;
      if (isSel) {
        bg = tokens.qing.withValues(alpha: 0.30);
      } else if (isNote) {
        bg = tokens.qing.withValues(alpha: 0.18);
      } else if (isFlash) {
        bg = tokens.zhu.withValues(alpha: 0.12);
      }
      TextStyle? style;
      if (m != null || bg != null) {
        style = TextStyle(
          backgroundColor: bg,
          decoration: m != null ? TextDecoration.underline : null,
          decorationColor: tokens.zhu,
          decorationThickness: 1.6,
          decorationStyle: m != null && m.generic
              ? TextDecorationStyle.dashed
              : TextDecorationStyle.solid,
        );
      }
      final String id = m?.id ?? '';
      final bool visible = a >= frag.displayStart && z <= frag.displayEnd;
      children.add(
        TextSpan(
          text: text.substring(a, z),
          // The visual paragraph is clipped to its page lines. Screen readers
          // must receive the same range, rather than the rest of the paragraph.
          semanticsLabel: visible ? null : '',
          style: style,
          recognizer: m == null || !visible
              ? null
              : (TapGestureRecognizer()..onTap = () => onName(id)),
        ),
      );
    }
    return TextSpan(
      style: heading ? spec.heading : spec.body,
      children: children,
    );
  }
}
