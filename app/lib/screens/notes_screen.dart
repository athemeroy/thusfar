import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:thusfar_core/notebook.dart' as notebook;

import '../data/library.dart';
import '../sheets/note_editor.dart';
import '../sheets/toc_sheet.dart';
import '../ui/cover.dart';
import '../ui/theme.dart';

/// S16 摘记: everything the reader left, grouped by book.
class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key, required this.library, required this.onOpenAt});

  final Library library;
  final void Function(BookEntry book, int offset) onOpenAt;

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  int filter = 0;
  String query = '';
  bool searching = false;

  final Map<String, String> _errors = <String, String>{};

  List<Json> _items(BookEntry b) {
    final File file = File('${b.dir.path}/notebook.json');
    if (!file.existsSync()) return <Json>[];
    late List<Json> out;
    try {
      final Json book =
          jsonDecode(File('${b.dir.path}/book.json').readAsStringSync())
              as Json;
      out = notebook
          .restore(jsonDecode(file.readAsStringSync()), book)
          .where((Json item) => item['deleted'] != true)
          .toList();
    } on Object catch (e) {
      _errors[b.id] = '${b.title}：摘记读取失败，原文件已保留。$e';
      return <Json>[];
    }
    return out
        .where(
          (Json x) => switch (filter) {
            1 => x['kind'] == 'note' && '${x['text']}'.isEmpty,
            2 => x['kind'] == 'note' && '${x['text']}'.isNotEmpty,
            3 => x['kind'] == 'bookmark',
            _ => true,
          },
        )
        .where(
          (Json x) =>
              query.isEmpty || '${x['quote']}${x['text']}'.contains(query),
        )
        .toList()
      ..sort(
        (Json a, Json b) => (a['start']! as num).compareTo(b['start']! as num),
      );
  }

  void _error(Object error) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  void _disposeBook(BookData book) {
    book.notes.dispose();
    book.dispose();
  }

  Future<void> _edit(BookEntry entry, Json item) async {
    HapticFeedback.lightImpact();
    BookData? book;
    try {
      book = BookData.open(entry);
      await NoteEditor.open(
        context,
        book: book,
        start: item['start']! as int,
        end: item['end']! as int,
        cutoff: item['knowledge_cutoff']! as int,
        existing: item,
      );
      if (mounted) setState(() {});
    } on Object catch (e) {
      _error(e);
    } finally {
      if (book != null) _disposeBook(book);
    }
  }

  bool _delete(BookEntry entry, Json item) {
    HapticFeedback.mediumImpact();
    BookData? book;
    try {
      book = BookData.open(entry);
      final Json receipt = book.notes.delete(item);
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('已删除'),
          action: SnackBarAction(
            label: '撤销',
            onPressed: () {
              HapticFeedback.lightImpact();
              BookData? current;
              try {
                current = BookData.open(entry);
                current.notes.restore(receipt);
                if (mounted) setState(() {});
              } on Object catch (e) {
                _error(e);
              } finally {
                if (current != null) _disposeBook(current);
              }
            },
          ),
        ),
      );
      return true;
    } on Object catch (e) {
      _error(e);
      return false;
    } finally {
      if (book != null) _disposeBook(book);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    _errors.clear();
    final List<(BookEntry, List<Json>)> groups = <(BookEntry, List<Json>)>[
      for (final BookEntry b in widget.library.books) (b, _items(b)),
    ].where(((BookEntry, List<Json>) g) => g.$2.isNotEmpty).toList();
    const List<String> labels = <String>['全部', '摘录', '笔记', '书签'];
    return Scaffold(
      backgroundColor: t.paper,
      body: CustomScrollView(
        slivers: <Widget>[
          SliverAppBar.large(
            backgroundColor: t.paper,
            surfaceTintColor: Colors.transparent,
            title: searching
                ? TextField(
                    autofocus: true,
                    onChanged: (String v) => setState(() => query = v.trim()),
                    decoration: InputDecoration(
                      hintText: '搜索摘记',
                      border: InputBorder.none,
                      suffixIcon: query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清空搜索',
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () {
                                HapticFeedback.selectionClick();
                                setState(() => query = '');
                              },
                            ),
                    ),
                  )
                : Text(
                    '摘记',
                    style: TextStyle(fontFamily: display, color: t.ink),
                  ),
            actions: <Widget>[
              IconButton(
                icon: Icon(searching ? Icons.close : Icons.search),
                onPressed: () {
                  HapticFeedback.selectionClick();
                  setState(() {
                    searching = !searching;
                    query = '';
                  });
                },
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 6,
                ),
                children: <Widget>[
                  for (int i = 0; i < labels.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Pill(
                        label: labels[i],
                        dense: true,
                        filled: filter == i,
                        onTap: () => setState(() => filter = i),
                      ),
                    ),
                ],
              ),
            ),
          ),
          for (final String error in _errors.values)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Text(error, style: TextStyle(color: t.danger)),
              ),
            ),
          if (groups.isEmpty && _errors.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(
                  '读书时长按一句话，就能摘录或写笔记',
                  style: TextStyle(color: t.ink3),
                ),
              ),
            ),
          for (final (BookEntry b, List<Json> items) in groups) ...<Widget>[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
                child: Row(
                  children: <Widget>[
                    BookCover(entry: b, width: 26),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        b.title,
                        style: TextStyle(
                          fontSize: 15,
                          color: t.ink,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text('${items.length}', style: TextStyle(color: t.ink3)),
                  ],
                ),
              ),
            ),
            SliverList.list(
              children: <Widget>[
                for (final Json item in items)
                  Dismissible(
                    key: ValueKey<Object?>('${b.id}${item['id']}'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      color: t.danger,
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 24),
                      child: const Icon(
                        Icons.delete_outline,
                        color: Colors.white,
                      ),
                    ),
                    confirmDismiss: (_) async => _delete(b, item),
                    child: NoteTile(
                      item: item,
                      onEdit: item['kind'] == 'note'
                          ? () => _edit(b, item)
                          : null,
                      pageLabel: item['kind'] == 'bookmark'
                          ? '书签'
                          : '原文位置 ${item['start']}',
                      onTap: () =>
                          widget.onOpenAt(b, (item['start']! as num).toInt()),
                    ),
                  ),
              ],
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }
}
