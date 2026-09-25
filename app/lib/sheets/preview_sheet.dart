import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/library.dart';
import '../ui/theme.dart';
import 'common.dart';
import 'sheet_host.dart';

/// S14 原文预览: look at the source before deciding to jump.
class PreviewPage extends StatefulWidget {
  const PreviewPage({
    super.key,
    required this.link,
    required this.start,
    required this.end,
    this.mine = false,
  });

  final ReaderLink link;
  final int start;
  final int end;

  /// Underline in 石青 (my note) instead of 朱 (AI source).
  final bool mine;

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  bool reveal = false;

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final BookData book = widget.link.c.book;
    final int page = widget.link.pageNo(widget.start);
    final Chapter ch = book.chapters[book.chapterAt(widget.start)];
    final bool ahead = widget.start >= widget.link.c.cutoff;
    final int from = math.max(0, widget.start - 300);
    final int to = math.min(
      book.length,
      math.max(widget.end, widget.start + 1) + 300,
    );
    final String before = book.textBetween(from, widget.start);
    final String target = book.textBetween(
      widget.start,
      math.max(widget.end, widget.start),
    );
    final String after = book.textBetween(
      math.max(widget.end, widget.start),
      to,
    );
    final Color mark = widget.mine ? t.qing : t.zhu;
    return SheetPage(
      title: '第 $page 页 · ${ahead && !reveal ? '后面的章节' : ch.title}',
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            child: ahead && !reveal
                ? Column(
                    children: <Widget>[
                      const SizedBox(height: 24),
                      Text(
                        '这段在第 $page 页，你还没读到',
                        style: TextStyle(fontSize: 16, color: t.ink2),
                      ),
                      const SizedBox(height: 16),
                      Pill(
                        label: '仍然跳过去',
                        onTap: () => setState(() => reveal = true),
                      ),
                    ],
                  )
                : Text.rich(
                    TextSpan(
                      style: TextStyle(
                        fontFamily: serif,
                        fontSize: 17,
                        height: 1.85,
                        color: t.ink2,
                      ),
                      children: <InlineSpan>[
                        TextSpan(text: before.isEmpty ? '' : '…$before'),
                        TextSpan(
                          text: target,
                          style: TextStyle(
                            color: t.ink,
                            decoration: TextDecoration.underline,
                            decorationColor: mark,
                            decorationThickness: 1.6,
                          ),
                        ),
                        TextSpan(text: after.isEmpty ? '' : '$after…'),
                      ],
                    ),
                    textAlign: TextAlign.justify,
                  ),
          ),
        ),
      ],
      bottom: Row(
        children: <Widget>[
          Expanded(
            child: Pill(
              label: '关闭',
              onTap: () => SheetScope.of(context).state.pop(),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: Pill(
              label: '跳到这里',
              filled: true,
              onTap: () => widget.link.jump(
                widget.start,
                highlight: (
                  widget.start,
                  math.max(widget.end, widget.start + 1),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
