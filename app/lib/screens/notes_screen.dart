import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
  final Map<String, List<Json>> _notes = <String, List<Json>>{};
  final Map<String, String> _stamps = <String, String>{};
  final TextEditingController _search = TextEditingController();
  bool _loading = true;
  bool _refreshing = false;
  bool _refreshAgain = false;
  int _refreshVersion = 0;

  void _invalidateNotes([String? id]) {
    _refreshVersion++;
    if (id == null) {
      _stamps.clear();
    } else {
      _stamps.remove(id);
    }
  }

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_libraryChanged);
    unawaited(_refreshNotes());
  }

  @override
  void didUpdateWidget(covariant NotesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != widget.library) {
      oldWidget.library.removeListener(_libraryChanged);
      widget.library.addListener(_libraryChanged);
      _invalidateNotes();
      _notes.clear();
      _errors.clear();
      _loading = true;
    }
    // Returning from the reader also rebuilds the shell. Check file stamps so
    // its new notes appear without rereading every book on every keystroke.
    unawaited(_refreshNotes());
  }

  @override
  void dispose() {
    widget.library.removeListener(_libraryChanged);
    _search.dispose();
    super.dispose();
  }

  void _libraryChanged() => unawaited(_refreshNotes());

  void _clearSearch() {
    _search.clear();
    setState(() => query = '');
  }

  void _closeSearch() {
    _search.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      searching = false;
      query = '';
    });
  }

  Future<void> _refreshNotes() async {
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshAgain = false;
        final int version = _refreshVersion;
        final Library library = widget.library;
        final List<BookEntry> books = List<BookEntry>.of(library.books);
        final Map<String, String> stamps = <String, String>{};
        await Future.wait(
          books.map((BookEntry book) async {
            final List<FileStat> stats = await Future.wait(<Future<FileStat>>[
              File('${book.dir.path}/book.json').stat(),
              File('${book.dir.path}/notebook.json').stat(),
            ]);
            stamps[book.id] = stats
                .map(
                  (FileStat stat) =>
                      '${stat.type}:${stat.size}:${stat.modified.microsecondsSinceEpoch}',
                )
                .join('|');
          }),
        );
        if (!mounted || library != widget.library) continue;
        final Map<String, String> changed = <String, String>{
          for (final BookEntry book in books)
            if (_stamps[book.id] != stamps[book.id]) book.id: book.dir.path,
        };
        final Map<String, (List<Json>, String?)> loaded = changed.isEmpty
            ? <String, (List<Json>, String?)>{}
            : await _loadNotebooks(changed);
        if (!mounted || library != widget.library) continue;
        if (version != _refreshVersion) {
          _refreshAgain = true;
          continue;
        }
        setState(() {
          _notes.removeWhere((String id, _) => !stamps.containsKey(id));
          _errors.removeWhere((String id, _) => !stamps.containsKey(id));
          _stamps.removeWhere((String id, _) => !stamps.containsKey(id));
          for (final BookEntry book in books) {
            final (List<Json>, String?)? result = loaded[book.id];
            if (result == null) continue;
            _notes[book.id] = result.$1;
            _stamps[book.id] = stamps[book.id]!;
            if (result.$2 == null) {
              _errors.remove(book.id);
            } else {
              _errors[book.id] = '${book.title}：摘记读取失败，原文件已保留。${result.$2}';
            }
          }
          _errors.remove('_load');
          _loading = false;
        });
      } while (_refreshAgain && mounted);
    } on Object {
      if (mounted) {
        setState(() {
          _loading = false;
          _errors['_load'] = '暂时无法读取摘记，请稍后重试。';
        });
      }
    } finally {
      _refreshing = false;
    }
  }

  List<Json> _items(BookEntry b) {
    final List<Json> out = _notes[b.id] ?? const <Json>[];
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
              query.isEmpty ||
              '${x['quote']}${x['text']}'.toLowerCase().contains(
                query.toLowerCase(),
              ),
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
      _invalidateNotes(entry.id);
      if (mounted) await _refreshNotes();
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
      setState(
        () => _notes[entry.id]?.removeWhere(
          (Json note) => note['id'] == item['id'],
        ),
      );
      _invalidateNotes(entry.id);
      unawaited(_refreshNotes());
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
                _invalidateNotes(entry.id);
                if (mounted) unawaited(_refreshNotes());
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
    final List<(BookEntry, List<Json>)> groups = <(BookEntry, List<Json>)>[
      for (final BookEntry b in widget.library.books) (b, _items(b)),
    ].where(((BookEntry, List<Json>) g) => g.$2.isNotEmpty).toList();
    const List<String> labels = <String>['全部', '摘录', '笔记', '书签'];
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (searching) _closeSearch();
        },
      },
      child: Scaffold(
        backgroundColor: t.paper,
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: RefreshIndicator(
              onRefresh: _refreshNotes,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: <Widget>[
                  if (searching)
                    SliverAppBar(
                      pinned: true,
                      backgroundColor: t.paper,
                      surfaceTintColor: Colors.transparent,
                      title: TextField(
                        key: const ValueKey<String>('notes-search-input'),
                        controller: _search,
                        autofocus: true,
                        onChanged: (String value) =>
                            setState(() => query = value.trim()),
                        decoration: InputDecoration(
                          hintText: '搜索摘记',
                          border: InputBorder.none,
                          suffixIcon: query.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: '清空搜索',
                                  icon: const Icon(Icons.close),
                                  onPressed: _clearSearch,
                                ),
                        ),
                      ),
                      actions: <Widget>[
                        IconButton(
                          tooltip: '关闭搜索',
                          icon: const Icon(Icons.close),
                          onPressed: _closeSearch,
                        ),
                      ],
                    )
                  else
                    SliverAppBar.large(
                      backgroundColor: t.paper,
                      surfaceTintColor: Colors.transparent,
                      title: Text(
                        '摘记',
                        style: TextStyle(fontFamily: display, color: t.ink),
                      ),
                      actions: <Widget>[
                        IconButton(
                          tooltip: '搜索摘记',
                          icon: const Icon(Icons.search),
                          onPressed: () => setState(() => searching = true),
                        ),
                      ],
                    ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height:
                          60 +
                          (MediaQuery.textScalerOf(context).scale(12) - 12)
                              .clamp(0, double.infinity),
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
                                selected: filter == i,
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  setState(() => filter = i);
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (_loading)
                    const SliverToBoxAdapter(
                      child: Padding(
                        key: ValueKey<String>('notes-loading'),
                        padding: EdgeInsets.all(24),
                        child: Text('正在读取摘记…'),
                      ),
                    ),
                  for (final String error in _errors.values)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(error, style: TextStyle(color: t.danger)),
                            TextButton(
                              onPressed: () {
                                _invalidateNotes();
                                unawaited(_refreshNotes());
                              },
                              child: const Text('重试读取'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (!_loading && groups.isEmpty && _errors.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Container(
                                width: 52,
                                height: 52,
                                decoration: BoxDecoration(
                                  color: (searching ? t.ink3 : t.qing)
                                      .withValues(alpha: 0.1),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  searching
                                      ? Icons.search_off_rounded
                                      : Icons.edit_note_rounded,
                                  size: 28,
                                  color: searching ? t.ink3 : t.qing,
                                ),
                              ),
                              const SizedBox(height: 16),
                              if (searching && query.isNotEmpty) ...<Widget>[
                                Text(
                                  '未找到匹配的摘记',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: t.ink,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '换个关键词试试，或清空搜索',
                                  style: TextStyle(fontSize: 13, color: t.ink3),
                                ),
                                const SizedBox(height: 12),
                                TextButton(
                                  onPressed: () {
                                    HapticFeedback.selectionClick();
                                    _clearSearch();
                                  },
                                  child: const Text('清空搜索'),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '读书时长按一句话，就能摘录或写笔记',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: t.ink3.withValues(alpha: 0.7),
                                  ),
                                ),
                              ] else if (filter != 0) ...<Widget>[
                                Text(
                                  '还没有${labels[filter]}',
                                  style: TextStyle(fontSize: 16, color: t.ink2),
                                ),
                                const SizedBox(height: 12),
                                TextButton(
                                  onPressed: () => setState(() => filter = 0),
                                  child: const Text('查看全部摘记'),
                                ),
                              ] else ...<Widget>[
                                Text(
                                  '读书时长按一句话，就能摘录或写笔记',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: t.ink3,
                                    height: 1.5,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  for (final (BookEntry b, List<Json> items)
                      in groups) ...<Widget>[
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
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: t.rule.withValues(alpha: 0.5),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                '${items.length}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: t.ink2,
                                  fontFeatures: const <FontFeature>[
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
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
                              alignment: Alignment.centerRight,
                              padding: const EdgeInsets.only(right: 20),
                              decoration: BoxDecoration(
                                color: t.danger,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Icon(
                                    Icons.delete_outline,
                                    color: Colors.white,
                                    size: 20,
                                  ),
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
                            confirmDismiss: (_) async => _delete(b, item),
                            child: NoteTile(
                              item: item,
                              onEdit: item['kind'] == 'note'
                                  ? () => _edit(b, item)
                                  : null,
                              pageLabel: item['kind'] == 'bookmark'
                                  ? '书签'
                                  : '原文位置 ${item['start']}',
                              onTap: () {
                                HapticFeedback.lightImpact();
                                widget.onOpenAt(
                                  b,
                                  (item['start']! as num).toInt(),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                  ],
                  const SliverToBoxAdapter(child: SizedBox(height: 40)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Restore and validate notebook records away from the UI isolate. Only the
/// changed books are read; originals are never rewritten by this projection.
Future<Map<String, (List<Json>, String?)>> _loadNotebooks(
  Map<String, String> paths,
) => Isolate.run(() {
  final Map<String, (List<Json>, String?)> results =
      <String, (List<Json>, String?)>{};
  for (final MapEntry<String, String> entry in paths.entries) {
    try {
      final File file = File('${entry.value}/notebook.json');
      if (!file.existsSync()) {
        results[entry.key] = (<Json>[], null);
        continue;
      }
      final Json book =
          jsonDecode(File('${entry.value}/book.json').readAsStringSync())
              as Json;
      results[entry.key] = (
        notebook
            .restore(jsonDecode(file.readAsStringSync()), book)
            .where((Json item) => item['deleted'] != true)
            .toList(),
        null,
      );
    } on Object catch (error) {
      results[entry.key] = (<Json>[], '$error');
    }
  }
  return results;
});
