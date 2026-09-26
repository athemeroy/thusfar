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
        child: TextField(
          controller: pageInput,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.go,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
          ],
          onSubmitted: (String v) {
            final int? n = int.tryParse(v);
            if (n == null) return;
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
          ),
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
                onTap: () => isRead
                    ? link.jump(c.o0)
                    : setState(() => confirm = confirm == i ? null : i),
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
                        child: Text(
                          '会看到后面的内容',
                          style: TextStyle(fontSize: 13, color: t.amber),
                        ),
                      ),
                      Pill(
                        label: '跳过去',
                        dense: true,
                        onTap: () => link.jump(c.o0),
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
                color: t.danger,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 24),
                child: const Icon(Icons.delete_outline, color: Colors.white),
              ),
              confirmDismiss: (_) async {
                try {
                  final Json receipt = notes.delete(m);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('已删除'),
                      action: SnackBarAction(
                        label: '撤销',
                        onPressed: () {
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
                onTap: () => link.jump((m['start']! as num).toInt()),
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
                  style: TextStyle(fontSize: 12, color: t.ink3),
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
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '“',
              style: TextStyle(
                fontFamily: serif,
                fontSize: 28,
                height: 1,
                color: t.qing,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (quote.isNotEmpty)
                    Text(
                      quote,
                      style: TextStyle(
                        fontFamily: serif,
                        fontSize: 15,
                        height: 1.7,
                        color: t.ink,
                      ),
                    ),
                  if (text.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        text,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.6,
                          color: t.qing,
                        ),
                      ),
                    ),
                  const SizedBox(height: 6),
                  Text(
                    '$pageLabel · ${formatDate(item['created'] as num?)}',
                    style: TextStyle(fontSize: 12, color: t.ink3),
                  ),
                ],
              ),
            ),
            if (onEdit != null)
              IconButton(
                tooltip: '编辑笔记',
                onPressed: onEdit,
                icon: Icon(Icons.edit_outlined, size: 20, color: t.qing),
              ),
          ],
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
