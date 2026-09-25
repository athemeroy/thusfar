import 'dart:io';

import 'package:flutter/material.dart';

import '../data/library.dart';
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

  List<Json> _items(BookEntry b) {
    final List<Object?> raw =
        (readJson(File('${b.dir.path}/notebook.json')) as List<Object?>?) ??
        const <Object?>[];
    final List<Json> out = <Json>[
      for (final Object? x in raw)
        if (x is Json && x['deleted'] != true) x,
    ];
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

  void _delete(BookEntry b, Json item) {
    final File f = File('${b.dir.path}/notebook.json');
    final List<Object?> raw = (readJson(f) as List<Object?>?) ?? <Object?>[];
    final Json gone = <String, Object?>{
      ...item,
      'deleted': true,
      'revision': ((item['revision'] as num?) ?? 0) + 1,
      'updated': DateTime.now().millisecondsSinceEpoch / 1000,
    };
    writeJson(f, <Object?>[
      ...raw.where((Object? x) => (x! as Json)['id'] != item['id']),
      gone,
    ]);
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('已删除'),
        action: SnackBarAction(
          label: '撤销',
          onPressed: () {
            final List<Object?> now =
                (readJson(f) as List<Object?>?) ?? <Object?>[];
            writeJson(f, <Object?>[
              ...now.where((Object? x) => (x! as Json)['id'] != item['id']),
              item,
            ]);
            setState(() {});
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
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
                    decoration: const InputDecoration(
                      hintText: '搜索摘记',
                      border: InputBorder.none,
                    ),
                  )
                : Text(
                    '摘记',
                    style: TextStyle(fontFamily: display, color: t.ink),
                  ),
            actions: <Widget>[
              IconButton(
                icon: Icon(searching ? Icons.close : Icons.search),
                onPressed: () => setState(() {
                  searching = !searching;
                  query = '';
                }),
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
          if (groups.isEmpty)
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
                    onDismissed: (_) => _delete(b, item),
                    child: NoteTile(
                      item: item,
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
