import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../data/library.dart';
import '../data/prefs.dart';
import '../ui/cover.dart';
import '../ui/device.dart';
import '../ui/theme.dart';

/// One item in the import progress bar (S03.2).
class ImportItem {
  ImportItem(this.name);

  final String name;
  double progress = 0;
  String? error;
  String? bookId;
  bool existed = false;
  bool get done => progress >= 1 || error != null;
}

/// S01 书架 and S01b 首次启动.
class ShelfScreen extends StatefulWidget {
  const ShelfScreen({
    super.key,
    required this.library,
    required this.prefs,
    required this.imports,
    required this.onOpen,
    required this.onDrawer,
    required this.onImport,
    required this.onRestore,
    required this.onModelSettings,
    this.flashId,
  });

  final Library library;
  final Prefs prefs;
  final List<ImportItem> imports;
  final void Function(BookEntry) onOpen;
  final void Function(BookEntry, {bool focus}) onDrawer;
  final VoidCallback onImport;
  final VoidCallback onRestore;
  final VoidCallback onModelSettings;
  final String? flashId;

  @override
  State<ShelfScreen> createState() => _ShelfScreenState();
}

class _ShelfScreenState extends State<ShelfScreen> {
  int filter = 0;
  bool searching = false;
  String query = '';
  String? collection;
  final TextEditingController _search = TextEditingController();
  final Set<ImportItem> _dismissedImports = <ImportItem>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

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

  bool get _showImports => widget.imports.any(
    (ImportItem item) => !item.done || !_dismissedImports.contains(item),
  );

  static const List<String> sorts = <String>['最近翻开', '书名先后', '阅读进度', '最近加入'];

  List<BookEntry> _visible() {
    final Library lib = widget.library;
    List<BookEntry> list = List<BookEntry>.of(lib.books);
    double pct(BookEntry b) => lib.progressOf(b.id)?.pct ?? 0;
    list = switch (filter) {
      1 =>
        list
            .where(
              (BookEntry b) =>
                  !lib.isFinished(b.id) &&
                  (pct(b) > 0 ||
                      lib.readingList.contains(b.id) ||
                      lib.organization.books[b.id]?.finished == false),
            )
            .toList(),
      2 =>
        list
            .where(
              (BookEntry b) =>
                  !lib.isFinished(b.id) &&
                  pct(b) <= 0 &&
                  !lib.readingList.contains(b.id) &&
                  lib.organization.books[b.id]?.finished != false,
            )
            .toList(),
      3 => list.where((BookEntry b) => lib.isFinished(b.id)).toList(),
      _ => list,
    };
    if (collection != null) {
      list = list
          .where(
            (BookEntry b) => collection == ''
                ? lib.collectionOf(b.id) == null
                : lib.collectionOf(b.id) == collection,
          )
          .toList();
    }
    if (query.isNotEmpty) {
      final String q = query.toLowerCase();
      list = list
          .where(
            (BookEntry b) =>
                b.title.toLowerCase().contains(q) ||
                b.author.toLowerCase().contains(q),
          )
          .toList();
    }
    switch (widget.prefs.sort) {
      case 1:
        list.sort((BookEntry a, BookEntry b) => a.title.compareTo(b.title));
      case 2:
        list.sort((BookEntry a, BookEntry b) => pct(b).compareTo(pct(a)));
      case 3:
        list.sort((BookEntry a, BookEntry b) => b.added.compareTo(a.added));
      default:
        list.sort(
          (BookEntry a, BookEntry b) => (lib.progressOf(b.id)?.t ?? b.added)
              .compareTo(lib.progressOf(a.id)?.t ?? a.added),
        );
    }
    return list;
  }

  BookEntry? _continue() {
    BookEntry? best;
    double t = -1;
    for (final BookEntry b in widget.library.books) {
      final Progress? p = widget.library.progressOf(b.id);
      if (p != null && !widget.library.isFinished(b.id) && p.t > t) {
        t = p.t;
        best = b;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final Library lib = widget.library;
    _dismissedImports.removeWhere(
      (ImportItem item) => !widget.imports.contains(item),
    );
    if (lib.loaded && lib.books.isEmpty && !_showImports) {
      return _empty(context);
    }
    if (collection != null &&
        collection!.isNotEmpty &&
        !lib.organization.collections.contains(collection)) {
      collection = null;
    }
    final List<BookEntry> books = _visible();
    final BookEntry? cont = _continue();
    final List<BookEntry> queue = <BookEntry>[
      for (final String id in lib.readingList)
        if (id != cont?.id) ?lib.byId(id),
    ];
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (searching) _closeSearch();
        },
      },
      child: Scaffold(
        backgroundColor: t.paper,
        body: Stack(
          children: <Widget>[
            RefreshIndicator(
              color: t.zhu,
              onRefresh: lib.scan,
              child: CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                semanticChildCount: books.length,
                slivers: <Widget>[
                  _appBar(context),
                  if (_showImports)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                        child: _importBar(context),
                      ),
                    ),
                  if ((cont != null || queue.isNotEmpty) &&
                      query.isEmpty &&
                      collection == null &&
                      filter == 0) ...<Widget>[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    '在读清单',
                                    style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w600,
                                      color: t.ink,
                                    ),
                                  ),
                                  Text(
                                    '随时接着读。',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: t.ink3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (lib.readingList.isNotEmpty)
                              TextButton(
                                onPressed: () => _editQueue(context),
                                child: const Text('编辑'),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (cont != null)
                      SliverToBoxAdapter(child: _continueCard(context, cont)),
                    if (queue.isNotEmpty)
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: 124,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            itemCount: queue.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(width: 12),
                            itemBuilder: (BuildContext context, int i) =>
                                GestureDetector(
                                  onTap: () {
                                    HapticFeedback.lightImpact();
                                    widget.onOpen(queue[i]);
                                  },
                                  child: BookCover(entry: queue[i], width: 82),
                                ),
                          ),
                        ),
                      ),
                  ],
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 22, 20, 4),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              collection == null
                                  ? '全部藏书'
                                  : collection!.isEmpty
                                  ? '未分类'
                                  : collection!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 15,
                                color: t.ink,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          Text(
                            '${collection == null ? lib.books.length : books.length} 本',
                            style: TextStyle(fontSize: 15, color: t.ink3),
                          ),
                          const SizedBox(width: 8),
                          _collectionMenu(context),
                          _sortMenu(context),
                        ],
                      ),
                    ),
                  ),
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _FilterBar(
                      filter: filter,
                      onChanged: (int i) => setState(() => filter = i),
                      color: t.paper,
                      height:
                          60 +
                          (MediaQuery.textScalerOf(context).scale(12) - 12)
                              .clamp(0, double.infinity),
                    ),
                  ),
                  if (books.isEmpty &&
                      (query.isNotEmpty || filter != 0 || collection != null))
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: _emptyResults(context),
                    )
                  else if (widget.prefs.listView)
                    SliverList.builder(
                      itemCount: books.length,
                      itemBuilder: (BuildContext context, int i) =>
                          _listRow(context, books[i]),
                    )
                  else
                    SliverLayoutBuilder(
                      builder:
                          (
                            BuildContext context,
                            SliverConstraints constraints,
                          ) {
                            final double extent = constraints.crossAxisExtent;
                            final bool compact = extent < 600;
                            const double inset = 20;
                            final double gap = extent < 360
                                ? 8
                                : compact
                                ? 12
                                : 20;
                            final int columns = compact
                                ? (extent < 500 ? 2 : 3)
                                : (extent / 168).floor().clamp(3, 6);
                            final double tileWidth =
                                (extent - inset * 2 - gap * (columns - 1)) /
                                columns;
                            final double textScale =
                                MediaQuery.textScalerOf(context).scale(16) / 16;
                            final double tileHeight =
                                (tileWidth - 24) * 4 / 3 + 90 + 56 * textScale;
                            return SliverPadding(
                              padding: EdgeInsets.fromLTRB(inset, 8, inset, 32),
                              // Each row grows with its text instead of
                              // squeezing scaled font metrics into a fixed
                              // grid extent. Keep the existing minimum height
                              // and spacing for the default-size shelf.
                              sliver: SliverList.separated(
                                addSemanticIndexes: false,
                                // Preserve per-card layers, including their
                                // fractional-pixel painting at default scale.
                                addRepaintBoundaries: false,
                                itemCount: (books.length / columns).ceil(),
                                separatorBuilder: (_, _) =>
                                    SizedBox(height: compact ? 18 : 22),
                                itemBuilder: (BuildContext context, int row) =>
                                    Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        for (
                                          int column = 0;
                                          column < columns;
                                          column++
                                        ) ...<Widget>[
                                          if (column > 0) SizedBox(width: gap),
                                          Expanded(
                                            child:
                                                row * columns + column <
                                                    books.length
                                                ? IndexedSemantics(
                                                    index:
                                                        row * columns + column,
                                                    child: RepaintBoundary(
                                                      child: ConstrainedBox(
                                                        constraints:
                                                            BoxConstraints(
                                                              minHeight:
                                                                  tileHeight,
                                                            ),
                                                        child: _gridCell(
                                                          context,
                                                          books[row * columns +
                                                              column],
                                                        ),
                                                      ),
                                                    ),
                                                  )
                                                : const SizedBox(),
                                          ),
                                        ],
                                      ],
                                    ),
                              ),
                            );
                          },
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _appBar(BuildContext context) {
    final Tokens t = context.tk;
    if (searching) {
      return SliverAppBar(
        pinned: true,
        backgroundColor: t.paper,
        surfaceTintColor: Colors.transparent,
        automaticallyImplyLeading: false,
        title: TextField(
          controller: _search,
          autofocus: true,
          onChanged: (String v) => setState(() => query = v.trim()),
          decoration: InputDecoration(
            hintText: '搜索书名或作者',
            border: InputBorder.none,
            suffixIcon: query.isEmpty
                ? null
                : IconButton(
                    tooltip: '清空搜索',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      _clearSearch();
                    },
                  ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () {
              HapticFeedback.lightImpact();
              _closeSearch();
            },
            child: Text('取消', style: TextStyle(color: t.ink2)),
          ),
        ],
      );
    }
    final double scale = MediaQuery.textScalerOf(context).scale(13) / 13;
    return SliverAppBar(
      pinned: true,
      expandedHeight: 112 + (scale - 1).clamp(0, double.infinity) * 48,
      toolbarHeight: 56 + (scale - 1).clamp(0, double.infinity) * 20,
      backgroundColor: t.paper,
      surfaceTintColor: Colors.transparent,
      titleSpacing: 20,
      title: Text(
        '页读',
        style: TextStyle(fontFamily: display, fontSize: 28, color: t.ink),
      ),
      actions: <Widget>[
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: '搜书',
          onPressed: () {
            HapticFeedback.lightImpact();
            setState(() => searching = true);
          },
        ),
        TextButton.icon(
          onPressed: widget.onImport,
          icon: const Icon(Icons.add, size: 20),
          label: const Text('添书'),
          style: TextButton.styleFrom(
            foregroundColor: t.qing,
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
        ),
        const SizedBox(width: 12),
      ],
      flexibleSpace: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final double available =
              box.maxHeight - MediaQuery.paddingOf(context).top;
          final double opacity = ((available - 80 * scale) / 30).clamp(0, 1);
          return Opacity(
            opacity: opacity,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  '翻到哪页，就懂到哪页。',
                  style: TextStyle(fontSize: 13, color: t.ink2),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _emptyResults(BuildContext context) {
    final Tokens t = context.tk;
    final bool hasQuery = query.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              hasQuery ? Icons.search_off_rounded : Icons.auto_stories_outlined,
              size: 38,
              color: t.ink3,
            ),
            const SizedBox(height: 14),
            Text(
              hasQuery ? '没有找到' : '这里还空着',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: t.ink2,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hasQuery ? '换个书名或作者关键词试试' : '换个分类，看看你的全部藏书。',
              textAlign: TextAlign.center,
              style: TextStyle(color: t.ink3, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
              onPressed: () {
                HapticFeedback.lightImpact();
                setState(() {
                  if (hasQuery) {
                    _search.clear();
                    query = '';
                  } else {
                    filter = 0;
                    collection = null;
                  }
                });
              },
              icon: Icon(hasQuery ? Icons.close : Icons.menu_book_outlined),
              label: Text(hasQuery ? '清空搜索' : '全部藏书'),
            ),
          ],
        ),
      ),
    );
  }

  void _shelfAction(VoidCallback action) {
    try {
      action();
      if (mounted) setState(() {});
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error is FormatException ? error.message : '没有保存成功，请稍后重试。',
          ),
        ),
      );
    }
  }

  Future<String?> _nameCollection({String? current}) {
    String draft = current ?? '';
    return showDialog<String>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        title: Text(current == null ? '新建分类' : '分类改名'),
        content: TextFormField(
          initialValue: current,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(hintText: '例如：小说、历史、想重读'),
          onChanged: (String value) => draft = value,
          onFieldSubmitted: (String value) {
            if (value.trim().isNotEmpty) Navigator.pop(dialog, value.trim());
          },
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              if (draft.trim().isNotEmpty) Navigator.pop(dialog, draft.trim());
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Widget _collectionMenu(BuildContext context) => PopupMenuButton<String>(
    tooltip: '书架分类',
    icon: Icon(
      Icons.folder_outlined,
      color: collection == null ? context.tk.ink2 : context.tk.qing,
    ),
    onSelected: (String value) async {
      if (value == '#new') {
        final String? name = await _nameCollection();
        if (!mounted || name == null) return;
        _shelfAction(() {
          widget.library.createCollection(name);
          collection = name;
        });
      } else if (value == '#rename') {
        final String oldName = collection!;
        final String? name = await _nameCollection(current: oldName);
        if (!mounted || name == null) return;
        _shelfAction(() {
          widget.library.renameCollection(oldName, name);
          collection = name;
        });
      } else if (value == '#remove') {
        final String name = collection!;
        _shelfAction(() {
          widget.library.removeCollection(name);
          collection = null;
        });
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('分类已移除，书籍仍在书架。')));
        }
      } else {
        setState(
          () => collection = value == '#all'
              ? null
              : value == '#none'
              ? ''
              : value.substring(1),
        );
      }
    },
    itemBuilder: (_) => <PopupMenuEntry<String>>[
      CheckedPopupMenuItem<String>(
        value: '#all',
        checked: collection == null,
        child: const Text('全部分类'),
      ),
      CheckedPopupMenuItem<String>(
        value: '#none',
        checked: collection == '',
        child: const Text('未分类'),
      ),
      for (final String name in widget.library.organization.collections)
        CheckedPopupMenuItem<String>(
          value: '@$name',
          checked: collection == name,
          child: Text(name),
        ),
      const PopupMenuDivider(),
      const PopupMenuItem<String>(value: '#new', child: Text('新建分类')),
      if (collection != null &&
          collection!.isNotEmpty) ...<PopupMenuEntry<String>>[
        const PopupMenuItem<String>(value: '#rename', child: Text('分类改名')),
        const PopupMenuItem<String>(value: '#remove', child: Text('移除分类')),
      ],
    ],
  );

  Future<void> _assignCollection(BookEntry book) async {
    final String? selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheet) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheet).height * .7,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(20),
            children: <Widget>[
              Text(
                '放入分类',
                style: TextStyle(
                  fontFamily: display,
                  fontSize: 22,
                  color: context.tk.ink,
                ),
              ),
              const SizedBox(height: 8),
              ListTile(
                title: const Text('未分类'),
                selected: widget.library.collectionOf(book.id) == null,
                onTap: () => Navigator.pop(sheet, '#none'),
              ),
              for (final String name in widget.library.organization.collections)
                ListTile(
                  title: Text(name),
                  selected: widget.library.collectionOf(book.id) == name,
                  onTap: () => Navigator.pop(sheet, '@$name'),
                ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('新建分类'),
                onTap: () => Navigator.pop(sheet, '#new'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || selected == null) return;
    if (selected == '#new') {
      final String? name = await _nameCollection();
      if (!mounted || name == null) return;
      _shelfAction(() {
        widget.library.createCollection(name);
        widget.library.setBookCollection(book.id, name);
      });
    } else {
      _shelfAction(
        () => widget.library.setBookCollection(
          book.id,
          selected == '#none' ? null : selected.substring(1),
        ),
      );
    }
  }

  Widget _bookMenu(BuildContext context, BookEntry book) =>
      PopupMenuButton<String>(
        tooltip: '管理《${book.title}》',
        icon: Icon(Icons.more_horiz, color: context.tk.ink3),
        onSelected: (String value) {
          if (value == 'collection') {
            _assignCollection(book);
            return;
          }
          if (value == 'details') {
            widget.onDrawer(book);
            return;
          }
          _shelfAction(() {
            if (value == 'finished') {
              final bool finished = !widget.library.isFinished(book.id);
              widget.library.setBookFinished(book.id, finished);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    finished ? '已标记读完，阅读位置保持不变。' : '已放回在读，阅读位置保持不变。',
                  ),
                ),
              );
            } else if (value == 'queue') {
              final List<String> queue = List<String>.of(
                widget.library.readingList,
              );
              if (queue.contains(book.id)) {
                queue.remove(book.id);
              } else {
                queue.add(book.id);
              }
              widget.library.setReadingList(queue);
            }
          });
        },
        itemBuilder: (_) => <PopupMenuEntry<String>>[
          const PopupMenuItem<String>(value: 'collection', child: Text('放入分类')),
          PopupMenuItem<String>(
            value: 'finished',
            child: Text(widget.library.isFinished(book.id) ? '标为在读' : '标记读完'),
          ),
          PopupMenuItem<String>(
            value: 'queue',
            child: Text(
              widget.library.readingList.contains(book.id) ? '移出在读' : '加入在读',
            ),
          ),
          const PopupMenuItem<String>(value: 'details', child: Text('本书详情')),
        ],
      );

  Widget _sortMenu(BuildContext context) {
    final Tokens t = context.tk;
    return PopupMenuButton<int>(
      tooltip: '排序方式',
      onSelected: (int i) {
        HapticFeedback.lightImpact();
        if (i == 6) {
          _openProcessingList();
          return;
        }
        widget.prefs.update((Prefs p) {
          if (i < 4) {
            p.sort = i;
          } else {
            p.listView = i == 5;
          }
        });
      },
      itemBuilder: (_) => <PopupMenuEntry<int>>[
        for (int i = 0; i < sorts.length; i++)
          CheckedPopupMenuItem<int>(
            value: i,
            checked: widget.prefs.sort == i,
            child: Text(sorts[i]),
          ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem<int>(
          value: 4,
          checked: !widget.prefs.listView,
          child: const Text('平铺'),
        ),
        CheckedPopupMenuItem<int>(
          value: 5,
          checked: widget.prefs.listView,
          child: const Text('列表'),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<int>(value: 6, child: Text('梳理进度')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('排序', style: TextStyle(fontSize: 13, color: t.ink2)),
            Icon(Icons.arrow_drop_down, size: 18, color: t.ink2),
          ],
        ),
      ),
    );
  }

  String _statusLine(BookEntry b) {
    final ProcessStatus s = b.status;
    if (s.state == 'queued') return '等待梳理';
    if (s.isCancelling) return '正在暂停';
    if (s.state == 'finalizing') return '即将完成';
    if (s.isRunning) {
      return s.total == 0
          ? '正在梳理'
          : '正在梳理 · ${(s.done / s.total * 100).round().clamp(0, 100)}%';
    }
    if (s.isDone) return '梳理完成';
    if (s.isPaused) return '梳理暂停';
    if (s.isError) return '梳理受阻';
    return '尚未梳理';
  }

  String _processingLabel(ProcessStatus s) {
    if (s.state == 'queued') return '等待梳理';
    if (s.isCancelling) return '正在暂停';
    if (s.state == 'finalizing') return '即将完成';
    if (s.isActive) return '正在梳理';
    if (s.isPaused) return '继续梳理';
    if (s.isError) return '梳理受阻';
    if (s.isDone) return '梳理完成';
    return '智能梳理';
  }

  IconData _processingIcon(ProcessStatus s) {
    if (s.isActive) return Icons.hourglass_top_rounded;
    if (s.isPaused) return Icons.play_arrow_rounded;
    if (s.isError) return Icons.error_outline_rounded;
    if (s.isDone) return Icons.check_rounded;
    return Icons.auto_awesome_rounded;
  }

  Widget _coverProcessingAction(BuildContext context, BookEntry b) {
    final Tokens t = context.tk;
    final ProcessStatus s = b.status;
    final String label = _processingLabel(s);
    return Semantics(
      button: true,
      label: '$label《${b.title}》',
      excludeSemantics: true,
      child: Material(
        color: t.sheet.withValues(alpha: .96),
        borderRadius: BorderRadius.circular(12),
        elevation: 2,
        child: InkWell(
          key: ValueKey<String>('process-${b.id}'),
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            HapticFeedback.lightImpact();
            widget.onDrawer(b, focus: true);
          },
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 104 * MediaQuery.textScalerOf(context).scale(11) / 11,
              minHeight: 44,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(_processingIcon(s), size: 16, color: t.zhu),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                        color: t.ink,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openProcessingList() async {
    HapticFeedback.lightImpact();
    final Tokens t = context.tk;
    final BookEntry? selected = await showModalBottomSheet<BookEntry>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => SafeArea(
        child: SizedBox(
          height: (MediaQuery.sizeOf(sheetContext).height * .58).clamp(
            300.0,
            520.0,
          ),
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Row(
                  children: <Widget>[
                    const Expanded(
                      child: Text(
                        '梳理进度',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭整理任务',
                      onPressed: () => Navigator.of(sheetContext).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListenableBuilder(
                  listenable: widget.library,
                  builder: (BuildContext context, _) {
                    final List<BookEntry> tasks =
                        <BookEntry>[
                          for (final BookEntry b in widget.library.books)
                            if (b.status.isActive ||
                                b.status.isPaused ||
                                b.status.isError)
                              b,
                        ]..sort((BookEntry a, BookEntry b) {
                          final int aRank = a.status.isActive ? 0 : 1;
                          final int bRank = b.status.isActive ? 0 : 1;
                          return aRank.compareTo(bRank);
                        });
                    if (tasks.isEmpty) {
                      return const Center(child: Text('目前没有等待梳理的书'));
                    }
                    return ListView.builder(
                      itemCount: tasks.length,
                      itemBuilder: (BuildContext context, int index) {
                        final BookEntry b = tasks[index];
                        return ListTile(
                          leading: Icon(
                            _processingIcon(b.status),
                            color: t.zhu,
                          ),
                          title: Text(b.title),
                          subtitle: Text(_statusLine(b)),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Navigator.of(sheetContext).pop(b),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (mounted && selected != null) widget.onDrawer(selected, focus: true);
  }

  Widget _continueCard(BuildContext context, BookEntry b) {
    final Tokens t = context.tk;
    final Progress p = widget.library.progressOf(b.id)!;
    final String chapter = widget.library
        .chapterTitleAt(b, p.pos)
        .replaceFirst(RegExp(r' · $'), '');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: Material(
        color: t.sheet,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: t.rule),
        ),
        child: InkWell(
          onTap: () => widget.onOpen(b),
          onLongPress: () => widget.onDrawer(b),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    BookCover(entry: b, width: 64),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            b.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: display,
                              fontSize: 20,
                              color: t.ink,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '已读 ${p.pct.round()}%',
                            style: TextStyle(fontSize: 13, color: t.ink2),
                          ),
                          if (chapter.isNotEmpty)
                            Text(
                              chapter,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: t.ink3),
                            ),
                          const SizedBox(height: 10),
                          LinearProgressIndicator(
                            value: (p.pct / 100).clamp(0, 1),
                            minHeight: 3,
                            color: t.qing,
                            backgroundColor: t.rule,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextButton(
                        onPressed: () => widget.onDrawer(b, focus: true),
                        style: TextButton.styleFrom(
                          alignment: Alignment.centerLeft,
                          padding: EdgeInsets.zero,
                        ),
                        child: Text(
                          _statusLine(b),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: b.status.isError || b.status.isPaused
                                ? t.amber
                                : t.qing,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '更多操作：${b.title}',
                      icon: Icon(Icons.more_horiz, color: t.ink3),
                      onPressed: () => widget.onDrawer(b),
                    ),
                    Pill(
                      label: '继续',
                      filled: true,
                      dense: true,
                      onTap: () => widget.onOpen(b),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _gridCell(BuildContext context, BookEntry b) {
    final Tokens t = context.tk;
    final double pct = widget.library.progressOf(b.id)?.pct ?? 0;
    final double textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) =>
          TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: widget.flashId == b.id ? 1 : 0, end: 0),
            duration: const Duration(milliseconds: 600),
            builder: (BuildContext context, double k, Widget? child) =>
                Container(
                  decoration: BoxDecoration(
                    color: t.zhu.withValues(alpha: 0.10 * k),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: child,
                ),
            child: Material(
              color: t.sheet,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: BorderSide(color: t.rule.withValues(alpha: .7)),
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () {
                  HapticFeedback.lightImpact();
                  widget.onOpen(b);
                },
                onLongPress: () {
                  HapticFeedback.mediumImpact();
                  widget.onDrawer(b);
                },
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Stack(
                        children: <Widget>[
                          BookCover(entry: b, width: box.maxWidth - 24),
                          Positioned(
                            top: 4,
                            right: 4,
                            child: Material(
                              color: t.sheet.withValues(alpha: .94),
                              shape: const CircleBorder(),
                              child: _bookMenu(context, b),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 9),
                      ConstrainedBox(
                        constraints: BoxConstraints(minHeight: 42 * textScale),
                        child: Text(
                          b.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: display,
                            fontSize: 16,
                            height: 1.28,
                            color: t.ink,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${widget.library.isFinished(b.id) ? '读完' : '已读 ${pct.round()}%'}${widget.library.collectionOf(b.id) == null ? '' : ' · ${widget.library.collectionOf(b.id)}'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: t.ink3),
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          value: (pct / 100).clamp(0, 1),
                          minHeight: 3,
                          color: t.zhu,
                          backgroundColor: t.rule.withValues(alpha: 0.6),
                        ),
                      ),
                      const SizedBox(height: 8),
                      _coverProcessingAction(context, b),
                    ],
                  ),
                ),
              ),
            ),
          ),
    );
  }

  Widget _listRow(BuildContext context, BookEntry b) {
    final Tokens t = context.tk;
    final double pct = widget.library.progressOf(b.id)?.pct ?? 0;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: BookCover(entry: b, width: 44),
      title: Text(
        b.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontFamily: display, fontSize: 16, color: t.ink),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SizedBox(height: 2),
          Text(
            '${b.author.isEmpty ? '' : '${b.author} · '}${widget.library.isFinished(b.id) ? '读完' : '已读 ${pct.round()}%'}${widget.library.collectionOf(b.id) == null ? '' : ' · ${widget.library.collectionOf(b.id)}'}',
            style: TextStyle(color: t.ink3, fontSize: 12),
          ),
          if (pct > 0) ...<Widget>[
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: (pct / 100).clamp(0, 1),
                minHeight: 2.5,
                color: t.zhu,
                backgroundColor: t.rule.withValues(alpha: 0.6),
              ),
            ),
          ],
          const SizedBox(height: 4),
          _coverProcessingAction(context, b),
        ],
      ),
      trailing: _bookMenu(context, b),
      onTap: () {
        HapticFeedback.lightImpact();
        widget.onOpen(b);
      },
      onLongPress: () {
        HapticFeedback.mediumImpact();
        widget.onDrawer(b);
      },
    );
  }

  Widget _importBar(BuildContext context) {
    final Tokens t = context.tk;
    final List<ImportItem> items = widget.imports
        .where(
          (ImportItem item) => !item.done || !_dismissedImports.contains(item),
        )
        .toList();
    final bool allDone = items.every((ImportItem i) => i.done);
    final String text = allDone
        ? '已导入 ${items.where((ImportItem i) => i.error == null).length} 本'
        : '正在导入 ${items.length} 本 · ${items.map((ImportItem i) => i.error != null
              ? '${i.name} ✕'
              : i.done
              ? '${i.name} ✓'
              : '${i.name} ${(i.progress * 100).round()}%').join(' · ')}';
    final double avg = items.isEmpty
        ? 0.0
        : items
                  .map((ImportItem i) => i.progress)
                  .reduce((double a, double b) => a + b) /
              items.length;
    return Semantics(
      liveRegion: true,
      child: Material(
        color: t.ink,
        borderRadius: BorderRadius.circular(14),
        elevation: 4,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.sheet, fontSize: 14),
                    ),
                  ),
                  if (allDone)
                    IconButton(
                      tooltip: '关闭导入结果',
                      color: t.sheet,
                      onPressed: () =>
                          setState(() => _dismissedImports.addAll(items)),
                      icon: const Icon(Icons.close),
                    ),
                ],
              ),
              if (!allDone) ...<Widget>[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: avg > 0 ? avg : null,
                    minHeight: 3,
                    color: t.zhu,
                    backgroundColor: t.sheet.withValues(alpha: 0.22),
                  ),
                ),
              ],
              for (final ImportItem i in items.where(
                (ImportItem i) => i.error != null || i.existed,
              ))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '${i.name}：${i.error ?? '已在书架上'}',
                          style: TextStyle(
                            color: i.error != null
                                ? const Color(0xFFF2B8A8)
                                : t.sheet.withValues(alpha: 0.8),
                            fontSize: 13,
                          ),
                        ),
                      ),
                      if (i.existed && i.bookId != null)
                        TextButton(
                          onPressed: () {
                            HapticFeedback.lightImpact();
                            final BookEntry? b = widget.library.byId(i.bookId!);
                            if (b != null) widget.onOpen(b);
                          },
                          child: Text('打开', style: TextStyle(color: t.zhuSoft)),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _editQueue(BuildContext context) async {
    final Library lib = widget.library;
    await showModalBottomSheet<void>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheet) {
          final List<String> items = List<String>.of(lib.readingList);
          return SafeArea(
            child: ReorderableListView(
              shrinkWrap: true,
              header: const Padding(
                padding: EdgeInsets.all(20),
                child: Text(
                  '在读清单',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ),
              onReorderItem: (int a, int b) {
                HapticFeedback.selectionClick();
                final String x = items.removeAt(a);
                items.insert(b, x);
                lib.setReadingList(items);
                setSheet(() {});
              },
              children: <Widget>[
                for (final String id in items)
                  ListTile(
                    key: ValueKey<String>(id),
                    title: Text(lib.byId(id)?.title ?? '已不在书架'),
                    trailing: IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      tooltip: '从在读清单移除《${lib.byId(id)?.title ?? '已不在书架'}》',
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        final int removedIndex = items.indexOf(id);
                        final String removedId = id;
                        final String title = lib.byId(id)?.title ?? '书目';
                        items.remove(id);
                        lib.setReadingList(items);
                        setSheet(() {});
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('已从在读清单移除《$title》'),
                            action: SnackBarAction(
                              label: '撤销',
                              onPressed: () {
                                HapticFeedback.lightImpact();
                                final List<String> current = List<String>.of(
                                  lib.readingList,
                                );
                                if (!current.contains(removedId) &&
                                    lib.byId(removedId) != null) {
                                  current.insert(
                                    removedIndex.clamp(0, current.length),
                                    removedId,
                                  );
                                  lib.setReadingList(current);
                                }
                                if (context.mounted) setSheet(() {});
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
    if (mounted) setState(() {});
  }

  Widget _empty(BuildContext context) {
    final Tokens t = context.tk;
    Widget line(String a, InlineSpan sample) => Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Text.rich(
        TextSpan(
          children: <InlineSpan>[
            sample,
            TextSpan(text: a),
          ],
        ),
        style: TextStyle(fontSize: 14, height: 1.6, color: t.ink2),
      ),
    );
    return Scaffold(
      backgroundColor: t.paper,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '页读',
                  style: TextStyle(
                    fontFamily: display,
                    fontSize: 28,
                    color: t.ink,
                  ),
                ),
                Text(
                  '翻到哪页，就懂到哪页。',
                  style: TextStyle(fontSize: 13, color: t.ink3),
                ),
                const SizedBox(height: 28),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: t.raised,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: t.rule),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '书架空空',
                        style: TextStyle(
                          fontFamily: display,
                          fontSize: 22,
                          color: t.ink,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        isPhone
                            ? '支持 TXT、EPUB。也可以在文件管理器或微信里选「用页读打开」'
                            : '支持 TXT、EPUB。',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.6,
                          color: t.ink2,
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: Pill(
                          label: '添加书籍',
                          filled: true,
                          onTap: () {
                            HapticFeedback.lightImpact();
                            widget.onImport();
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: Pill(
                          label: '恢复备份',
                          onTap: () {
                            HapticFeedback.lightImpact();
                            widget.onRestore();
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),
                line(
                  '：读到哪，人物资料就只到哪',
                  TextSpan(
                    text: '阿Q',
                    style: TextStyle(
                      color: t.ink,
                      decoration: TextDecoration.underline,
                      decorationColor: t.zhu,
                      decorationThickness: 1.6,
                    ),
                  ),
                ),
                line('往回翻，资料也会回退', const TextSpan(text: '')),
                line(
                  '：划线与想法保存在这台$deviceWord，可随书备份。',
                  TextSpan(
                    text: '心动字句',
                    style: TextStyle(
                      color: t.ink,
                      backgroundColor: t.qing.withValues(alpha: 0.18),
                    ),
                  ),
                ),
                const SizedBox(height: 28),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '添书即可阅读。开启智能梳理，可查看人物与前情。',
                        style: TextStyle(fontSize: 12, color: t.ink3),
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        HapticFeedback.lightImpact();
                        widget.onModelSettings();
                      },
                      child: Text('智能梳理', style: TextStyle(color: t.ink)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterBar extends SliverPersistentHeaderDelegate {
  _FilterBar({
    required this.filter,
    required this.onChanged,
    required this.color,
    required this.height,
  });

  final int filter;
  final ValueChanged<int> onChanged;
  final Color color;
  final double height;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    const List<String> labels = <String>['全部', '在读', '未读', '读完'];
    return Container(
      color: color,
      alignment: Alignment.centerLeft,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        children: <Widget>[
          for (int i = 0; i < labels.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Pill(
                label: labels[i],
                dense: true,
                filled: i == filter,
                selected: i == filter,
                onTap: () {
                  HapticFeedback.selectionClick();
                  onChanged(i);
                },
              ),
            ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_FilterBar old) =>
      old.filter != filter || old.color != color || old.height != height;
}
