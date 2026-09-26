import 'package:flutter/material.dart';

import '../data/library.dart';
import '../ui/theme.dart';
import 'common.dart';
import 'preview_sheet.dart';
import 'sheet_host.dart';

class _Hit {
  const _Hit(this.chapter, this.at, this.before, this.match, this.after);

  final int chapter;
  final int at;
  final String before;
  final String match;
  final String after;
}

/// S13 搜索原文: defaults to what has been read.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.link});

  final ReaderLink link;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  String query = '';
  bool whole = false;

  List<_Hit> _search() {
    final BookData book = widget.link.c.book;
    final String q = query.toLowerCase();
    if (q.isEmpty) return const <_Hit>[];
    final int limit = whole ? book.length : widget.link.c.cutoff;
    final List<_Hit> out = <_Hit>[];
    for (final Block b in book.blocks) {
      if (b.o >= limit) break;
      if (b.kind == 'img') continue;
      final String lower = b.text.toLowerCase();
      int from = 0;
      while (true) {
        final int i = lower.indexOf(q, from);
        if (i < 0 || b.o + i + q.length > limit) break;
        final int s = (i - 24).clamp(0, b.text.length);
        final int e = (i + q.length + 36).clamp(
          0,
          (limit - b.o).clamp(0, b.text.length),
        );
        out.add(
          _Hit(
            book.chapterAt(b.o + i),
            b.o + i,
            book.textBetween(b.o + s, b.o + i),
            b.text.substring(i, i + q.length),
            book.textBetween(b.o + i + q.length, b.o + e),
          ),
        );
        if (out.length >= 500) return out;
        from = i + q.length;
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final List<_Hit> hits = _search();
    final BookData book = widget.link.c.book;
    final List<Widget> rows = <Widget>[];
    int? lastChapter;
    for (final _Hit h in hits) {
      if (h.chapter != lastChapter) {
        lastChapter = h.chapter;
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
            child: Text(
              book.chapters[h.chapter].title,
              style: TextStyle(fontSize: 12, color: t.ink3, letterSpacing: 0.6),
            ),
          ),
        );
      }
      rows.add(
        InkWell(
          onTap: () => SheetScope.of(context).state.push(
            PreviewPage(
              link: widget.link,
              start: h.at,
              end: h.at + h.match.length,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(text: h.before.isEmpty ? '' : '…${h.before}'),
                  TextSpan(
                    text: h.match,
                    style: TextStyle(fontWeight: FontWeight.w700, color: t.ink),
                  ),
                  TextSpan(text: '${h.after}…'),
                ],
              ),
              style: TextStyle(
                fontFamily: serif,
                fontSize: 15,
                height: 1.6,
                color: t.ink2,
              ),
            ),
          ),
        ),
      );
    }
    return SheetPage(
      title: query.isEmpty
          ? '搜索原文'
          : '找到 ${hits.length}${hits.length >= 500 ? '+' : ''} 处',
      headerExtraHeight: whole ? 126 : 104,
      headerExtra: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: SizedBox(
              height: 44,
              child: TextField(
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: (String v) => setState(() => query = v.trim()),
                decoration: InputDecoration(
                  hintText: '搜索书里的一句话',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清空搜索',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => setState(() => query = ''),
                        ),
                  filled: true,
                  fillColor: t.paper,
                  contentPadding: EdgeInsets.zero,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
          Segmented(
            labels: const <String>['读到这里', '全书'],
            index: whole ? 1 : 0,
            onChanged: (int i) => setState(() => whole = i == 1),
          ),
          if (whole)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(Icons.warning_amber_rounded, size: 14, color: t.amber),
                  const SizedBox(width: 4),
                  Text(
                    '会搜到还没读的内容',
                    style: TextStyle(color: t.amber, fontSize: 12),
                  ),
                ],
              ),
            ),
        ],
      ),
      slivers: <Widget>[
        if (query.isNotEmpty && hits.isEmpty)
          emptyState(
            context,
            whole ? '全书没有找到' : '读到这里的部分没有找到。要搜全书吗？',
            action: whole
                ? null
                : Pill(label: '搜全书', onTap: () => setState(() => whole = true)),
          )
        else
          SliverList.list(children: rows),
      ],
    );
  }
}
