import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../data/library.dart';
import '../data/prefs.dart';
import '../ui/cover.dart';
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
  bool fabWide = true;

  static const List<String> sorts = <String>['最近阅读', '书名', '阅读进度', '最近加入'];

  List<BookEntry> _visible() {
    final Library lib = widget.library;
    List<BookEntry> list = List<BookEntry>.of(lib.books);
    double pct(BookEntry b) => lib.progressOf(b.id)?.pct ?? 0;
    list = switch (filter) {
      1 => list.where((BookEntry b) => pct(b) > 0 && pct(b) < 99).toList(),
      2 => list.where((BookEntry b) => lib.progressOf(b.id) == null).toList(),
      3 => list.where((BookEntry b) => pct(b) >= 99).toList(),
      _ => list,
    };
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
      if (p != null && p.pct < 99.5 && p.t > t) {
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
    if (lib.loaded && lib.books.isEmpty && widget.imports.isEmpty) {
      return _empty(context);
    }
    final List<BookEntry> books = _visible();
    final BookEntry? cont = _continue();
    final List<BookEntry> queue = <BookEntry>[
      for (final String id in lib.readingList) ?lib.byId(id),
    ];
    return Scaffold(
      backgroundColor: t.paper,
      floatingActionButton: Padding(
        padding: EdgeInsets.only(bottom: widget.imports.isEmpty ? 0 : 52),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 200),
          child: fabWide
              ? FloatingActionButton.extended(
                  heroTag: 'import',
                  onPressed: widget.onImport,
                  backgroundColor: t.ink,
                  foregroundColor: t.sheet,
                  shape: const StadiumBorder(),
                  icon: const Icon(Icons.add),
                  label: const Text('导入'),
                )
              : FloatingActionButton(
                  heroTag: 'import',
                  onPressed: widget.onImport,
                  backgroundColor: t.ink,
                  foregroundColor: t.sheet,
                  shape: const CircleBorder(),
                  child: const Icon(Icons.add),
                ),
        ),
      ),
      body: Stack(
        children: <Widget>[
          NotificationListener<UserScrollNotification>(
            onNotification: (UserScrollNotification n) {
              final bool wide = n.direction != ScrollDirection.reverse;
              if (wide != fabWide) setState(() => fabWide = wide);
              return false;
            },
            child: RefreshIndicator(
              color: t.zhu,
              onRefresh: lib.scan,
              child: CustomScrollView(
                slivers: <Widget>[
                  _appBar(context),
                  if (cont != null && query.isEmpty)
                    SliverToBoxAdapter(child: _continueCard(context, cont)),
                  if (queue.isNotEmpty && query.isEmpty) ...<Widget>[
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 12, 8),
                        child: Row(
                          children: <Widget>[
                            Text(
                              '接下来读',
                              style: TextStyle(
                                fontSize: 15,
                                color: t.ink,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const Spacer(),
                            Tooltip(
                              message: '编辑接下来读',
                              child: TextButton(
                                onPressed: () => _editQueue(context),
                                child: Text(
                                  '编辑',
                                  style: TextStyle(color: t.ink2),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: 124,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          itemCount: queue.length,
                          separatorBuilder: (_, _) => const SizedBox(width: 12),
                          itemBuilder: (BuildContext context, int i) =>
                              GestureDetector(
                                onTap: () => widget.onOpen(queue[i]),
                                child: BookCover(entry: queue[i], width: 82),
                              ),
                        ),
                      ),
                    ),
                  ],
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 22, 8, 4),
                      child: Row(
                        children: <Widget>[
                          Text(
                            '全部书籍 ',
                            style: TextStyle(
                              fontSize: 15,
                              color: t.ink,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '${lib.books.length}',
                            style: TextStyle(fontSize: 15, color: t.ink3),
                          ),
                          const Spacer(),
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
                    ),
                  ),
                  if (widget.prefs.listView)
                    SliverList.builder(
                      itemCount: books.length,
                      itemBuilder: (BuildContext context, int i) =>
                          _listRow(context, books[i]),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
                      sliver: SliverGrid.builder(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 3,
                              crossAxisSpacing: 16,
                              mainAxisSpacing: 18,
                              childAspectRatio: 0.52,
                            ),
                        itemCount: books.length,
                        itemBuilder: (BuildContext context, int i) =>
                            _gridCell(context, books[i]),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (widget.imports.isNotEmpty)
            Positioned(
              left: 16,
              right: 16,
              bottom: 12,
              child: _importBar(context),
            ),
        ],
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
          autofocus: true,
          onChanged: (String v) => setState(() => query = v.trim()),
          decoration: const InputDecoration(
            hintText: '书名或作者',
            border: InputBorder.none,
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => setState(() {
              searching = false;
              query = '';
            }),
            child: Text('取消', style: TextStyle(color: t.ink2)),
          ),
        ],
      );
    }
    return SliverAppBar(
      pinned: true,
      expandedHeight: 112,
      collapsedHeight: 56,
      backgroundColor: t.paper,
      surfaceTintColor: Colors.transparent,
      actions: <Widget>[
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: '搜索',
          onPressed: () => setState(() => searching = true),
        ),
        const SizedBox(width: 8),
      ],
      flexibleSpace: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final double k =
              ((box.maxHeight - 56 - MediaQuery.of(context).padding.top) / 56)
                  .clamp(0, 1);
          return Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              MediaQuery.of(context).padding.top,
              60,
              0,
            ),
            child: Align(
              alignment: Alignment(-1, k > 0.5 ? 0.3 : 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '页读',
                    style: TextStyle(
                      fontFamily: display,
                      fontSize: 20 + 8 * k,
                      color: t.ink,
                      height: 1.1,
                    ),
                  ),
                  if (k > 0.4)
                    Opacity(
                      opacity: k,
                      child: Text(
                        '只读到你这一页',
                        style: TextStyle(fontSize: 13, color: t.ink3),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _sortMenu(BuildContext context) {
    final Tokens t = context.tk;
    return PopupMenuButton<int>(
      onSelected: (int i) => widget.prefs.update((Prefs p) {
        if (i < 4) {
          p.sort = i;
        } else {
          p.listView = i == 5;
        }
      }),
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
          child: const Text('封面'),
        ),
        CheckedPopupMenuItem<int>(
          value: 5,
          checked: widget.prefs.listView,
          child: const Text('列表'),
        ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              sorts[widget.prefs.sort],
              style: TextStyle(fontSize: 13, color: t.ink2),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: t.ink2),
          ],
        ),
      ),
    );
  }

  String _statusLine(BookEntry b) {
    final ProcessStatus s = b.status;
    if (s.isRunning) {
      return '整理中 ${s.total == 0 ? 0 : (100 * s.done / s.total).round()}%';
    }
    if (s.isDone) return '人物已整理 · ${s.people} 位';
    if (s.isPaused) return '整理已暂停';
    if (s.isError) return '整理停下了，点开看原因';
    return '人物还没整理';
  }

  Widget _continueCard(BuildContext context, BookEntry b) {
    final Tokens t = context.tk;
    final Progress p = widget.library.progressOf(b.id)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
      child: Material(
        color: t.raised,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => widget.onOpen(b),
          onLongPress: () => widget.onDrawer(b),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
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
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: display,
                          fontSize: 20,
                          color: t.ink,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '读到 ${p.pct.round()}%',
                        style: TextStyle(fontSize: 13, color: t.ink2),
                      ),
                      const SizedBox(height: 8),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: p.pct / 100,
                          minHeight: 3,
                          color: t.ink2,
                          backgroundColor: t.rule,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          StatusDot(status: b.status, size: 7),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              _statusLine(b),
                              style: TextStyle(fontSize: 12, color: t.ink3),
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
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
            child: GestureDetector(
              onTap: () => widget.onOpen(b),
              onLongPress: () => widget.onDrawer(b),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  BookCover(
                    entry: b,
                    width: box.maxWidth,
                    statusDot: true,
                    onDot: () => widget.onDrawer(b, focus: true),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    b.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, height: 1.35, color: t.ink),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    height: 2,
                    width: box.maxWidth * math.min(1, pct / 100),
                    color: t.ink3,
                  ),
                ],
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
      leading: BookCover(entry: b, width: 40),
      title: Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${b.author.isEmpty ? '' : '${b.author} · '}读到 ${pct.round()}% · ${_statusLine(b)}',
        style: TextStyle(color: t.ink3, fontSize: 12),
      ),
      onTap: () => widget.onOpen(b),
      onLongPress: () => widget.onDrawer(b),
    );
  }

  Widget _importBar(BuildContext context) {
    final Tokens t = context.tk;
    final List<ImportItem> items = widget.imports;
    final bool allDone = items.every((ImportItem i) => i.done);
    final String text = allDone
        ? '已导入 ${items.where((ImportItem i) => i.error == null).length} 本'
        : '正在导入 ${items.length} 本 · ${items.map((ImportItem i) => i.error != null
              ? '${i.name} ✕'
              : i.done
              ? '${i.name} ✓'
              : '${i.name} ${(i.progress * 100).round()}%').join(' · ')}';
    return Material(
      color: t.ink,
      borderRadius: BorderRadius.circular(14),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.sheet, fontSize: 14),
            ),
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
                  '接下来读',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ),
              onReorderItem: (int a, int b) {
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
                      tooltip: '从接下来读移除《${lib.byId(id)?.title ?? '已不在书架'}》',
                      onPressed: () {
                        lib.setReadingList(items..remove(id));
                        setSheet(() {});
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
    setState(() {});
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
              Text('只读到你这一页', style: TextStyle(fontSize: 13, color: t.ink3)),
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
                      '把第一本书放进来',
                      style: TextStyle(
                        fontFamily: display,
                        fontSize: 22,
                        color: t.ink,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '支持 TXT、EPUB。也可以在文件管理器或微信里选「用页读打开」',
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
                        label: '从手机选择书',
                        filled: true,
                        onTap: widget.onImport,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: Pill(label: '恢复备份', onTap: widget.onRestore),
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
                '：你的摘录和笔记用石青色，永远只存在这台手机',
                TextSpan(
                  text: '一句摘录',
                  style: TextStyle(
                    color: t.ink,
                    backgroundColor: t.qing.withValues(alpha: 0.18),
                  ),
                ),
              ),
              const Spacer(),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '整理人物需要一个模型 API 密钥，导入以后再填也可以。',
                      style: TextStyle(fontSize: 12, color: t.ink3),
                    ),
                  ),
                  TextButton(
                    onPressed: widget.onModelSettings,
                    child: Text('去填写', style: TextStyle(color: t.ink)),
                  ),
                ],
              ),
            ],
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
  });

  final int filter;
  final ValueChanged<int> onChanged;
  final Color color;

  @override
  double get minExtent => 52;

  @override
  double get maxExtent => 52;

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
                onTap: () => onChanged(i),
              ),
            ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_FilterBar old) =>
      old.filter != filter || old.color != color;
}
