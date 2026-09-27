import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/library.dart';
import '../data/seen.dart';
import '../ui/theme.dart';
import 'common.dart';
import 'preview_sheet.dart';
import 'note_editor.dart';
import 'sheet_host.dart';

final RegExp _chapterNumber = RegExp(
  r'^(第\s*[0-9零一二三四五六七八九十百千]+\s*[部章回卷节篇集]|(?:chapter|part|book)\s+[0-9ivxlcdm]+)',
  caseSensitive: false,
);

/// An unread chapter shows only its number, never a spoiling title.
String safeTitle(Chapter c, bool read) {
  if (read) return c.title;
  final RegExpMatch? m = _chapterNumber.firstMatch(c.title.trim());
  return m?.group(0) ?? '第 ${c.index + 1} 节';
}

String formatDate(num? seconds) {
  if (seconds == null) return '';
  final DateTime d = DateTime.fromMillisecondsSinceEpoch(
    (seconds * 1000).round(),
  );
  return '${d.month} 月 ${d.day} 日';
}

/// S08 目录 · 书签 · 摘记.
class TocPage extends StatefulWidget {
  const TocPage({super.key, required this.link, this.tab = 0});

  final ReaderLink link;
  final int tab;

  @override
  State<TocPage> createState() => _TocPageState();
}

class _TocPageState extends State<TocPage> {
  late int tab = widget.tab;
  bool showLater = false;
  int? confirm;
  final TextEditingController pageInput = TextEditingController();

  @override
  void dispose() {
    pageInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ReaderLink link = widget.link;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[link.c, link.c.book.notes]),
      builder: (BuildContext context, _) => SheetPage(
        title: link.c.book.entry.title,
        headerExtraHeight: tab == 0 ? 96 : 44,
        headerExtra: Column(
          children: <Widget>[
            Segmented(
              labels: const <String>['目录', '书签', '摘记'],
              index: tab,
              onChanged: (int i) => setState(() => tab = i),
            ),
            if (tab == 0) _jumpBox(context),
          ],
        ),
        slivers: <Widget>[
          if (tab != 0 && link.c.book.notes.error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(
                  link.c.book.notes.error!,
                  style: TextStyle(color: context.tk.danger),
                ),
              ),
            ),
          ...switch (tab) {
            0 => _toc(context),
            1 => _bookmarks(context),
            _ => _notes(context),
          },
        ],
      ),
    );
  }

  Widget _jumpBox(BuildContext context) {
    final Tokens t = context.tk;
    final (int total, bool exact) = widget.link.c.pager!.totalPages();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: SizedBox(
        height: 40,
        child: ListenableBuilder(
          listenable: pageInput,
          builder: (BuildContext context, _) {
            final bool hasText = pageInput.text.isNotEmpty;
            return TextField(
              controller: pageInput,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.go,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
              onSubmitted: (String v) {
                final int? n = int.tryParse(v);
                if (n == null) return;
                HapticFeedback.lightImpact();
                widget.link.jump(_offsetOfPage(n.clamp(1, total)));
              },
              decoration: InputDecoration(
                hintText: '跳到第 __ 页（共${exact ? '' : '约 '}$total 页）',
                filled: true,
                fillColor: t.paper,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: hasText
                    ? IconButton(
                        tooltip: '跳转到该页',
                        icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                        onPressed: () {
                          final int? n = int.tryParse(pageInput.text);
                          if (n == null) return;
                          HapticFeedback.lightImpact();
                          widget.link.jump(_offsetOfPage(n.clamp(1, total)));
                        },
                      )
                    : null,
              ),
            );
          },
        ),
      ),
    );
  }

  int _offsetOfPage(int n) {
    final BookData book = widget.link.c.book;
    for (int c = book.chapters.length - 1; c >= 0; c--) {
      final (int first, _) = widget.link.c.pager!.globalPage(c, 0);
      if (first <= n) {
        final int idx = n - first;
        final pages = widget.link.c.pager!.pages(c);
        return pages[idx.clamp(0, pages.length - 1)].start;
      }
    }
    return 0;
  }

  List<Widget> _toc(BuildContext context) {
    final Tokens t = context.tk;
    final ReaderLink link = widget.link;
    final BookData book = link.c.book;
    final int read = SeenStore.instance.maxRead(book.id, link.c.cutoff);
    return <Widget>[
      SliverList.builder(
        itemCount: book.chapters.length,
        itemBuilder: (BuildContext context, int i) {
          final Chapter c = book.chapters[i];
          final bool current = i == link.c.chapter;
          final bool isRead = c.o0 < read;
          final int page = link.pageNo(c.o0);
          return Column(
            children: <Widget>[
              InkWell(
                onTap: () {
                  HapticFeedback.lightImpact();
                  if (isRead) {
                    link.jump(c.o0);
                  } else {
                    setState(() => confirm = confirm == i ? null : i);
                  }
                },
                child: Container(
                  constraints: const BoxConstraints(minHeight: 52),
                  padding: EdgeInsets.fromLTRB(20.0 + 14 * c.depth, 8, 20, 8),
                  child: Row(
                    children: <Widget>[
                      Container(
                        width: 3,
                        height: 18,
                        color: current ? t.zhu : Colors.transparent,
                        margin: const EdgeInsets.only(right: 10),
                      ),
                      Expanded(
                        child: Row(
                          children: <Widget>[
                            Text(
                              safeTitle(c, isRead),
                              style: TextStyle(
                                fontSize: 15,
                                color: current
                                    ? t.zhu
                                    : (isRead ? t.ink : t.ink2),
                                fontWeight: current
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                            if (!isRead) ...<Widget>[
                              const SizedBox(width: 10),
                              Expanded(
                                child: Container(height: 1, color: t.rule),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '$page',
                        style: TextStyle(
                          fontSize: 13,
                          color: t.ink3,
                          fontFeatures: const <FontFeature>[
                            FontFeature.tabularFigures(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (confirm == i)
                Padding(
                  padding: const EdgeInsets.fromLTRB(34, 0, 20, 10),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Row(
                          children: <Widget>[
                            Icon(
                              Icons.warning_amber_rounded,
                              size: 14,
                              color: t.amber,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '会看到后面的内容',
                              style: TextStyle(fontSize: 13, color: t.amber),
                            ),
                          ],
                        ),
                      ),
                      Pill(
                        label: '跳过去',
                        dense: true,
                        onTap: () {
                          HapticFeedback.lightImpact();
                          link.jump(c.o0);
                        },
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    ];
  }

  List<Widget> _bookmarks(BuildContext context) {
    final Tokens t = context.tk;
    final ReaderLink link = widget.link;
    final NoteStore notes = link.c.book.notes;
    final List<Json> marks = notes.bookmarks;
    if (marks.isEmpty) {
      return <Widget>[emptyState(context, '点工具栏的书签按钮，把这一页记下来')];
    }
    return <Widget>[
      SliverList.list(
        children: <Widget>[
          for (final Json m in marks)
            Dismissible(
              key: ValueKey<Object?>(m['id']),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                decoration: BoxDecoration(
                  color: t.danger,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(Icons.delete_outline, color: Colors.white, size: 20),
                    SizedBox(width: 4),
                    Text(
                      '删除',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              confirmDismiss: (_) async {
                HapticFeedback.mediumImpact();
                try {
                  final Json receipt = notes.delete(m);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('已删除'),
                      action: SnackBarAction(
                        label: '撤销',
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          final NoteStore current = NoteStore(
                            notes.file,
                            notes.book,
                          );
                          try {
                            current.restore(receipt);
                            if (context.mounted) notes.refresh();
                          } on Object catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(
                                context,
                              ).showSnackBar(SnackBar(content: Text('$e')));
                            }
                          } finally {
                            current.dispose();
                          }
                        },
                      ),
                    ),
                  );
                  return true;
                } on Object catch (e) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('$e')));
                  return false;
                }
              },
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                onTap: () {
                  HapticFeedback.lightImpact();
                  link.jump((m['start']! as num).toInt());
                },
                leading: Icon(Icons.bookmark, color: t.qing),
                title: Text(
                  _firstSentence((m['start']! as num).toInt()),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: serif,
                    fontSize: 15,
                    color: t.ink,
                  ),
                ),
                subtitle: Text(
                  '第 ${link.pageNo((m['start']! as num).toInt())} 页 · ${formatDate(m['created'] as num?)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: t.ink3,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    ];
  }

  String _firstSentence(int at) {
    final String s = widget.link.c.book.textBetween(at, at + 60);
    final int cut = s.indexOf(RegExp('[。！？!?]'));
    return cut > 0 ? s.substring(0, cut + 1) : s;
  }

  List<Widget> _notes(BuildContext context) {
    final Tokens t = context.tk;
    final ReaderLink link = widget.link;
    final NoteStore store = link.c.book.notes;
    final List<Json> all = store.notes;
    final List<Json> shown = showLater
        ? all
        : all
              .where(
                (Json n) =>
                    (n['end']! as int) <= link.c.cutoff &&
                    (n['knowledge_cutoff']! as int) <= link.c.cutoff,
              )
              .toList();
    return <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
          child: Row(
            children: <Widget>[
              Text('也显示后面的', style: TextStyle(fontSize: 13, color: t.ink2)),
              Switch(
                value: showLater,
                onChanged: (bool v) => setState(() => showLater = v),
                activeThumbColor: t.qing,
              ),
              const Spacer(),
              TextButton(
                onPressed: () {
                  HapticFeedback.lightImpact();
                  Clipboard.setData(
                    ClipboardData(text: notesMarkdown(link.c.book)),
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('摘记已复制为 Markdown')),
                  );
                },
                child: Text('导出', style: TextStyle(color: t.qing)),
              ),
            ],
          ),
        ),
      ),
      if (shown.isEmpty)
        emptyState(context, '读书时长按一句话，就能摘录或写笔记')
      else
        SliverList.list(
          children: <Widget>[
            for (final Json n in shown)
              NoteTile(
                item: n,
                pageLabel: '第 ${link.pageNo((n['start']! as num).toInt())} 页',
                onEdit: () => NoteEditor.open(
                  context,
                  book: link.c.book,
                  start: n['start']! as int,
                  end: n['end']! as int,
                  cutoff: (n['knowledge_cutoff']! as int) > link.c.cutoff
                      ? n['knowledge_cutoff']! as int
                      : link.c.cutoff,
                  existing: n,
                ),
                onTap: () => SheetScope.of(context).state.push(
                  PreviewPage(
                    link: link,
                    start: (n['start']! as num).toInt(),
                    end: (n['end']! as num).toInt(),
                    mine: true,
                  ),
                ),
              ),
          ],
        ),
    ];
  }
}

/// A personal excerpt or note: 石青 quote mark, serif quote, my words.
class NoteTile extends StatelessWidget {
  const NoteTile({
    super.key,
    required this.item,
    required this.pageLabel,
    this.onTap,
    this.onEdit,
  });

  final Json item;
  final String pageLabel;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final String quote = '${item['quote'] ?? ''}';
    final String text = '${item['text'] ?? ''}';
    final bool bookmark = item['kind'] == 'bookmark';
    final bool writtenNote = text.isNotEmpty;
    final Color accent = writtenNote ? t.qing : (bookmark ? t.amber : t.zhu);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      child: Material(
        color: t.sheet,
        borderRadius: BorderRadius.circular(18),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap == null
              ? null
              : () {
                  HapticFeedback.lightImpact();
                  onTap!();
                },
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: t.rule.withValues(alpha: .72)),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 3,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(18),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Padding(
                        padding: EdgeInsets.fromLTRB(
                          14,
                          12,
                          onEdit == null ? 16 : 4,
                          12,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Icon(
                                  bookmark
                                      ? Icons.bookmark_outline
                                      : writtenNote
                                      ? Icons.format_quote_rounded
                                      : Icons.short_text_rounded,
                                  size: 16,
                                  color: accent,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  bookmark
                                      ? '书签'
                                      : writtenNote
                                      ? '我的笔记'
                                      : '摘录',
                                  style: TextStyle(
                                    fontSize: 11,
                                    letterSpacing: .5,
                                    fontWeight: FontWeight.w700,
                                    color: accent,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    '$pageLabel · ${formatDate(item['created'] as num?)}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.end,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: t.ink3,
                                      fontFeatures: const <FontFeature>[
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (quote.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 8),
                              Text(
                                quote,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: serif,
                                  fontSize: 15,
                                  height: 1.7,
                                  color: t.ink,
                                ),
                              ),
                            ],
                            if (text.isNotEmpty) ...<Widget>[
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.only(left: 10),
                                decoration: BoxDecoration(
                                  border: Border(
                                    left: BorderSide(color: t.qing, width: 2),
                                  ),
                                ),
                                child: Text(
                                  text,
                                  maxLines: 6,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 14,
                                    height: 1.6,
                                    color: t.qing,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (onEdit != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 36, right: 8),
                    child: IconButton(
                      tooltip: '编辑笔记',
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        onEdit!();
                      },
                      icon: Icon(Icons.edit_outlined, size: 19, color: t.qing),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `/notebook.md` in the same shape as 1.7.x.
String notesMarkdown(BookData book) {
  final List<String> lines = <String>[
    '# ${book.entry.title}',
    '',
    '个人摘记（包含全书已保存的摘记）',
    '',
  ];
  for (final Json item in book.notes.live) {
    lines.addAll(<String>[
      '## ${item['kind'] == 'bookmark' ? '书签' : '摘记'} · 原文位置 ${item['start']}',
      '',
    ]);
    lines.addAll(<String>[
      for (final String l in '${item['quote']}'.split('\n')) '> $l',
    ]);
    lines.addAll(<String>['', '${item['text']}', '']);
  }
  return lines.join('\n');
}
