import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:thusfar_core/thusfar_core.dart';

import '../data/library.dart';
import '../ui/theme.dart';
import 'common.dart';
import 'preview_sheet.dart';
import 'sheet_host.dart';

/// S11 前情: the story so far, this chapter's events, chapter summaries.
class RecapPage extends StatelessWidget {
  const RecapPage({super.key, required this.link});

  final ReaderLink link;

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final World? w = link.c.world;
    final int cutoff = link.c.cutoff;
    final int page = link.pageNo(cutoff > 0 ? cutoff - 1 : 0);
    final BookData book = link.c.book;
    final Chapter ch = book.chapters[link.c.chapter];
    if (w == null || (w.saga == null && w.recaps.isEmpty && w.events.isEmpty)) {
      return SheetPage(
        title: '前情 · 截至第 $page 页',
        slivers: <Widget>[emptyState(context, '读完第一章后，这里会有前情提要')],
      );
    }
    final List<Json> here = <Json>[
      for (final Json e in w.events)
        if (((e['s'] ?? e['p'])! as num) >= ch.o0) e,
    ];
    final String? saga = w.saga == null ? null : '${w.saga!['text']}';
    return SheetPage(
      title: '前情 · 截至第 $page 页',
      slivers: <Widget>[
        if (saga != null) ...<Widget>[
          const SliverToBoxAdapter(child: SectionTitle('到上一章为止')),
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 20),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: t.paper,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: t.rule.withValues(alpha: 0.6)),
              ),
              child: Text(
                saga,
                style: TextStyle(
                  fontFamily: serif,
                  fontSize: 15,
                  height: 1.8,
                  color: t.ink,
                ),
              ),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SectionTitle('本章到这里')),
        if (here.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                '本章还没有整理出的事件',
                style: TextStyle(color: t.ink3, fontSize: 14),
              ),
            ),
          )
        else
          SliverList.list(
            children: <Widget>[
              for (final Json e in here)
                InkWell(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    final int at = ((e['s'] ?? e['p'])! as num).toInt();
                    SheetScope.of(context).state.push(
                      PreviewPage(
                        link: link,
                        start: at,
                        end: (e['p']! as num).toInt(),
                      ),
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.only(top: 7, right: 12),
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              color: t.zhu,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            '${e['text']}',
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.6,
                              color: t.ink,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Tag(
                          '第 ${link.pageNo(((e['s'] ?? e['p'])! as num).toInt())} 页',
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        if (w.recaps.isNotEmpty) ...<Widget>[
          const SliverToBoxAdapter(child: SectionTitle('各章梗概')),
          SliverList.list(
            children: <Widget>[
              for (final Json r in w.recaps)
                ExpansionTile(
                  tilePadding: const EdgeInsets.symmetric(horizontal: 20),
                  childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  shape: const Border(),
                  onExpansionChanged: (bool _) =>
                      HapticFeedback.selectionClick(),
                  title: Text(
                    _chapterTitle(book, r),
                    style: TextStyle(fontSize: 15, color: t.ink),
                  ),
                  children: <Widget>[
                    Text(
                      '${r['text']}',
                      style: TextStyle(
                        fontFamily: serif,
                        fontSize: 15,
                        height: 1.75,
                        color: t.ink2,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ],
    );
  }

  String _chapterTitle(BookData book, Json r) {
    final int at = (r['p']! as num).toInt();
    final int c = book.chapterAt(at > 0 ? at - 1 : 0);
    return book.chapters[c].title;
  }
}
