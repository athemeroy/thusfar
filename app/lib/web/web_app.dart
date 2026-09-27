// JavaScript-only Flutter Web entrypoint. Browser DOM APIs are intentionally
// confined here; native targets compile lib/main.dart instead.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../ui/theme.dart';
import 'web_storage.dart';

const double _wideShelf = 1140;

class WebShelf extends StatefulWidget {
  const WebShelf({super.key});

  @override
  State<WebShelf> createState() => _WebShelfState();
}

class _WebShelfState extends State<WebShelf> {
  WebLibrary? _library;
  List<WebBookMeta> _books = const <WebBookMeta>[];
  Map<String, WebReadingState> _states = const <String, WebReadingState>{};
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      final WebLibrary library = await WebLibrary.open();
      if (!mounted) {
        library.close();
        return;
      }
      _library = library;
      await _refresh();
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _refresh() async {
    final WebLibrary? library = _library;
    if (library == null) return;
    final List<WebBookMeta> books = await library.list();
    final List<WebReadingState> states = await Future.wait(
      <Future<WebReadingState>>[
        for (final WebBookMeta book in books) library.state(book.id),
      ],
    );
    if (!mounted) return;
    setState(() {
      _books = books;
      _states = <String, WebReadingState>{
        for (int i = 0; i < books.length; i++) books[i].id: states[i],
      };
      _error = null;
    });
  }

  Future<void> _import() async {
    final WebLibrary? library = _library;
    if (library == null || _busy) return;
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['txt', 'epub', 'json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final PlatformFile file = result.files.single;
    final Uint8List? bytes = file.bytes;
    if (bytes == null) {
      _message('浏览器没有交付文件内容，请重新选择。');
      return;
    }
    setState(() => _busy = true);
    try {
      if (file.name.toLowerCase().endsWith('.json')) {
        await library.importBackup(bytes);
      } else {
        await library.importFile(file.name, bytes);
      }
      await _refresh();
      _message('已导入到此浏览器的本地书库');
    } on Object catch (error) {
      _message('导入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }

  Future<void> _open(WebBookMeta meta) async {
    final WebLibrary? library = _library;
    if (library == null) return;
    setState(() => _busy = true);
    try {
      final WebBook? book = await library.load(meta.id);
      final WebReadingState state = await library.state(meta.id);
      if (!mounted) return;
      if (book == null) throw StateError('书籍内容已不存在');
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => WebReader(book: book, state: state, library: library),
        ),
      );
      await _refresh();
    } on Object catch (error) {
      _message('打开失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _bookMenu(WebBookMeta book) async {
    final WebLibrary? library = _library;
    if (library == null) return;
    final String? choice = await showModalBottomSheet<String>(
      context: context,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(title: Text(book.title), subtitle: const Text('存放在此浏览器')),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('导出书籍与阅读记录'),
              onTap: () => Navigator.pop(context, 'export'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('从此浏览器移除'),
              onTap: () => Navigator.pop(context, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (choice == 'export') {
      try {
        await library.exportBackup(book.id);
      } on Object catch (error) {
        _message('导出失败：$error');
      }
    } else if (choice == 'remove' && mounted) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('移除这本书？'),
          content: const Text('浏览器里的书籍、进度、书签和摘记会一起删除。建议先导出备份。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('移除'),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await library.remove(book.id);
        await _refresh();
      }
    }
  }

  @override
  void dispose() {
    _library?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final List<WebBookMeta> books = List<WebBookMeta>.of(_books)
      ..sort((WebBookMeta a, WebBookMeta b) {
        final int aTime = _states[a.id]?.lastOpened ?? a.added;
        final int bTime = _states[b.id]?.lastOpened ?? b.added;
        return bTime.compareTo(aTime);
      });
    return Scaffold(
      backgroundColor: t.paper,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _wideShelf),
            child: CustomScrollView(
              slivers: <Widget>[
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
                  sliver: SliverToBoxAdapter(
                    child: Row(
                      children: <Widget>[
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '正在阅读',
                              style: TextStyle(color: t.ink3, letterSpacing: 2),
                            ),
                            Text(
                              '页读',
                              style: TextStyle(
                                fontFamily: display,
                                color: t.ink,
                                fontSize: 38,
                              ),
                            ),
                          ],
                        ),
                        const Spacer(),
                        FilledButton.icon(
                          onPressed: _busy || _library == null ? null : _import,
                          icon: const Icon(Icons.add),
                          label: Text(_busy ? '处理中…' : '导入书籍'),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_error != null)
                  SliverPadding(
                    padding: const EdgeInsets.all(24),
                    sliver: SliverToBoxAdapter(
                      child: Text(_error!, style: TextStyle(color: t.danger)),
                    ),
                  )
                else if (_library == null)
                  const SliverFillRemaining(
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (books.isEmpty)
                  SliverFillRemaining(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 430),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.auto_stories_outlined,
                                size: 70,
                                color: t.qing,
                              ),
                              const SizedBox(height: 20),
                              Text(
                                '从一本书开始',
                                style: TextStyle(
                                  fontFamily: display,
                                  fontSize: 27,
                                  color: t.ink,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '导入 TXT 或 EPUB，在浏览器里直接阅读。书籍只保存在当前浏览器。',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: t.ink2, height: 1.6),
                              ),
                              const SizedBox(height: 24),
                              OutlinedButton.icon(
                                onPressed: _import,
                                icon: const Icon(Icons.upload_file_outlined),
                                label: const Text('选择书籍或页读网页备份'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  )
                else ...<Widget>[
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
                    sliver: SliverToBoxAdapter(
                      child: Text(
                        '我的书架  ${books.length}',
                        style: TextStyle(fontSize: 18, color: t.ink2),
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                    sliver: SliverLayoutBuilder(
                      builder:
                          (
                            BuildContext context,
                            SliverConstraints constraints,
                          ) {
                            final int columns =
                                constraints.crossAxisExtent < 650 ? 1 : 2;
                            return SliverGrid.builder(
                              itemCount: books.length,
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: columns,
                                    mainAxisSpacing: 14,
                                    crossAxisSpacing: 14,
                                    mainAxisExtent: 178,
                                  ),
                              itemBuilder: (BuildContext context, int index) {
                                final WebBookMeta book = books[index];
                                return _ShelfBookCard(
                                  book: book,
                                  state: _states[book.id] ?? WebReadingState(),
                                  onOpen: () => _open(book),
                                  onMenu: () => _bookMenu(book),
                                );
                              },
                            );
                          },
                    ),
                  ),
                ],
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 30),
                  sliver: SliverToBoxAdapter(
                    child: Text(
                      '本地阅读 · 无需账号 · 导出备份可带走书与进度',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: t.ink3, fontSize: 12),
                    ),
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

class _ShelfBookCard extends StatelessWidget {
  const _ShelfBookCard({
    required this.book,
    required this.state,
    required this.onOpen,
    required this.onMenu,
  });

  final WebBookMeta book;
  final WebReadingState state;
  final VoidCallback onOpen;
  final VoidCallback onMenu;

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final double pct = book.chapters <= 0
        ? 0
        : ((state.chapter + state.fraction) / book.chapters * 100).clamp(
            0.0,
            100.0,
          );
    return Material(
      color: t.sheet,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: <Widget>[
              _WebCover(title: book.title, id: book.id),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: t.ink,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      book.author.isEmpty ? '${book.chapters} 章' : book.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: t.ink2),
                    ),
                    const Spacer(),
                    LinearProgressIndicator(
                      value: pct / 100,
                      minHeight: 3,
                      backgroundColor: t.rule,
                      color: t.qing,
                    ),
                    const SizedBox(height: 9),
                    Text(
                      pct == 0
                          ? '尚未开始'
                          : '读到 ${pct.toStringAsFixed(pct < 1 ? 1 : 0)}%',
                      style: TextStyle(fontSize: 12, color: t.ink3),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '书籍选项',
                onPressed: onMenu,
                icon: const Icon(Icons.more_vert),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WebCover extends StatelessWidget {
  const _WebCover({required this.title, required this.id});

  final String title;
  final String id;

  @override
  Widget build(BuildContext context) {
    const List<Color> colors = <Color>[
      Color(0xFF6D4A3A),
      Color(0xFF35507A),
      Color(0xFF4F7A5A),
      Color(0xFF8A5A2B),
      Color(0xFF3D5D6B),
    ];
    final int color =
        id.codeUnits.fold<int>(0, (int a, int b) => a + b) % colors.length;
    return Container(
      width: 100,
      height: 138,
      padding: const EdgeInsets.fromLTRB(13, 17, 13, 13),
      decoration: BoxDecoration(
        color: colors[color],
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(3),
          bottomLeft: Radius.circular(3),
          topRight: Radius.circular(9),
          bottomRight: Radius.circular(9),
        ),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x30000000),
            blurRadius: 7,
            offset: Offset(1, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Text(
              title,
              maxLines: 5,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: display,
                color: Color(0xFFF6EDE2),
                fontSize: 15,
                height: 1.3,
              ),
            ),
          ),
          Container(height: 1, color: const Color(0x99FFFFFF)),
        ],
      ),
    );
  }
}

class WebReaderPrefs {
  WebReaderPrefs() {
    try {
      final String? raw = html.window.localStorage['thusfar-web-prefs'];
      if (raw == null) return;
      final Json json = jsonDecode(raw) as Json;
      fontSize = ((json['fontSize'] as num?)?.toDouble() ?? 21).clamp(
        14.0,
        34.0,
      );
      lineHeight = ((json['lineHeight'] as num?)?.toDouble() ?? 1.75).clamp(
        1.2,
        2.4,
      );
      letterSpacing = ((json['letterSpacing'] as num?)?.toDouble() ?? 0).clamp(
        -0.5,
        2.5,
      );
      margin = ((json['margin'] as num?)?.toDouble() ?? 24).clamp(8.0, 90.0);
      columnWidth = ((json['columnWidth'] as num?)?.toDouble() ?? 960).clamp(
        520.0,
        1400.0,
      );
      paper = ((json['paper'] as num?)?.toInt() ?? 0).clamp(
        0,
        Tokens.paperColors.length - 1,
      );
      font = ((json['font'] as num?)?.toInt() ?? 0).clamp(0, 2);
    } on Object {
      // A malformed preference must never prevent the book from opening.
    }
  }

  double fontSize = 21;
  double lineHeight = 1.75;
  double letterSpacing = 0;
  double margin = 24;
  double columnWidth = 960;
  int paper = 0;
  int font = 0;

  Color get paperColor => Tokens.paperColors[paper].$2;
  bool get dark => paper == Tokens.paperColors.length - 1;
  Color get ink => dark ? Tokens.night.ink : Tokens.light.ink;
  Color get muted => dark ? Tokens.night.ink3 : Tokens.light.ink3;
  String get family =>
      const <String>['NotoSerifSC', 'LXGWWenKaiScreen', 'sans-serif'][font];

  void save() {
    html.window.localStorage['thusfar-web-prefs'] =
        jsonEncode(<String, Object?>{
          'fontSize': fontSize,
          'lineHeight': lineHeight,
          'letterSpacing': letterSpacing,
          'margin': margin,
          'columnWidth': columnWidth,
          'paper': paper,
          'font': font,
        });
  }
}

class WebReader extends StatefulWidget {
  const WebReader({
    super.key,
    required this.book,
    required this.state,
    required this.library,
  });

  final WebBook book;
  final WebReadingState state;
  final WebLibrary library;

  @override
  State<WebReader> createState() => _WebReaderState();
}

class _WebReaderState extends State<WebReader> {
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _blockKeys = <int, GlobalKey>{};
  final WebReaderPrefs _prefs = WebReaderPrefs();
  Timer? _saveTimer;
  Timer? _displayTimer;
  bool _controls = false;
  bool _restoring = true;
  late int _chapter;
  int? _jumpBlock;

  List<Json> get _chapters => widget.book.chapters;
  List<Json> get _blocks => widget.book.blocks;
  Json get _current => _chapters[_chapter];

  @override
  void initState() {
    super.initState();
    _chapter = widget.state.chapter.clamp(0, math.max(0, _chapters.length - 1));
    _scroll.addListener(_scrolled);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _restoreFraction(widget.state.fraction),
    );
  }

  void _scrolled() {
    if (_restoring || !_scroll.hasClients) return;
    widget.state.fraction = _fraction;
    widget.state.lastOpened = DateTime.now().millisecondsSinceEpoch;
    _queueSave();
    _displayTimer ??= Timer(const Duration(milliseconds: 120), () {
      _displayTimer = null;
      if (mounted) setState(() {});
    });
  }

  double get _fraction {
    if (!_scroll.hasClients || _scroll.position.maxScrollExtent <= 0) return 0;
    return (_scroll.offset / _scroll.position.maxScrollExtent).clamp(0.0, 1.0);
  }

  void _queueSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(widget.library.saveState(widget.book.meta.id, widget.state));
    });
  }

  Future<void> _restoreFraction(double fraction) async {
    if (!mounted) return;
    // Lay out the selected chapter first. A second frame accounts for fonts.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_scroll.hasClients) return;
    final int? jumpBlock = _jumpBlock;
    final BuildContext? target = jumpBlock == null
        ? null
        : _blockKeys[jumpBlock]?.currentContext;
    if (target != null && target.mounted) {
      await Scrollable.ensureVisible(
        target,
        duration: const Duration(milliseconds: 250),
        alignment: 0.12,
      );
    } else {
      _scroll.jumpTo(
        (_scroll.position.maxScrollExtent * fraction).clamp(
          0.0,
          _scroll.position.maxScrollExtent,
        ),
      );
    }
    _jumpBlock = null;
    _restoring = false;
  }

  void _go(int chapter, {double fraction = 0, int? block}) {
    if (chapter < 0 || chapter >= _chapters.length) return;
    _saveTimer?.cancel();
    _restoring = true;
    _jumpBlock = block;
    _blockKeys.clear();
    setState(() {
      _chapter = chapter;
      widget.state.chapter = chapter;
      widget.state.fraction = fraction;
      widget.state.lastOpened = DateTime.now().millisecondsSinceEpoch;
      _controls = false;
    });
    unawaited(widget.library.saveState(widget.book.meta.id, widget.state));
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _restoreFraction(fraction),
    );
  }

  void _bookmark() {
    final double fraction = _fraction;
    final int index = widget.state.bookmarks.indexWhere(
      (mark) =>
          mark.chapter == _chapter && (mark.fraction - fraction).abs() < 0.07,
    );
    setState(() {
      if (index >= 0) {
        widget.state.bookmarks.removeAt(index);
      } else {
        widget.state.bookmarks.add((chapter: _chapter, fraction: fraction));
      }
    });
    unawaited(widget.library.saveState(widget.book.meta.id, widget.state));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(index >= 0 ? '已移除书签' : '已添加书签'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  double get _progress {
    final int start = (_current['o0'] as num?)?.toInt() ?? 0;
    final int end = (_current['o1'] as num?)?.toInt() ?? start;
    final int total = math.max(1, widget.book.meta.length);
    return ((start + (end - start) * _fraction) / total).clamp(0.0, 1.0);
  }

  void _chaptersSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) => SafeArea(
        child: SizedBox(
          height: math.min(MediaQuery.sizeOf(context).height * 0.8, 730),
          child: Column(
            children: <Widget>[
              const ListTile(title: Text('目录')),
              Expanded(
                child: ListView.builder(
                  itemCount: _chapters.length,
                  itemBuilder: (BuildContext context, int index) {
                    final Json chapter = _chapters[index];
                    return ListTile(
                      selected: index == _chapter,
                      title: Text(
                        '${chapter['title'] ?? '第 ${index + 1} 章'}',
                        maxLines: 2,
                      ),
                      leading: SizedBox(width: 40, child: Text('${index + 1}')),
                      onTap: () {
                        Navigator.pop(context);
                        _go(index);
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
  }

  void _bookmarksSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) => SafeArea(
        child: SizedBox(
          height: math.min(MediaQuery.sizeOf(context).height * 0.7, 630),
          child: Column(
            children: <Widget>[
              const ListTile(title: Text('书签')),
              Expanded(
                child: widget.state.bookmarks.isEmpty
                    ? const Center(child: Text('还没有书签。在阅读页点书签图标即可保存位置。'))
                    : ListView.builder(
                        itemCount: widget.state.bookmarks.length,
                        itemBuilder: (BuildContext context, int index) {
                          final mark = widget.state.bookmarks[index];
                          return ListTile(
                            leading: const Icon(Icons.bookmark_outline),
                            title: Text('${_chapters[mark.chapter]['title']}'),
                            subtitle: Text(
                              '本章 ${(mark.fraction * 100).round()}%',
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              _go(mark.chapter, fraction: mark.fraction);
                            },
                            trailing: IconButton(
                              tooltip: '删除书签',
                              onPressed: () {
                                setState(
                                  () => widget.state.bookmarks.removeAt(index),
                                );
                                unawaited(
                                  widget.library.saveState(
                                    widget.book.meta.id,
                                    widget.state,
                                  ),
                                );
                                Navigator.pop(context);
                                _bookmarksSheet();
                              },
                              icon: const Icon(Icons.close),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _notesSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) => SafeArea(
        child: SizedBox(
          height: math.min(MediaQuery.sizeOf(context).height * 0.7, 650),
          child: Column(
            children: <Widget>[
              ListTile(
                title: const Text('我的摘记'),
                trailing: IconButton(
                  tooltip: '添加摘记',
                  icon: const Icon(Icons.add),
                  onPressed: () {
                    Navigator.pop(context);
                    _addNote();
                  },
                ),
              ),
              Expanded(
                child: widget.state.notes.isEmpty
                    ? const Center(child: Text('记下这一页的想法，随书一起备份。'))
                    : ListView.builder(
                        itemCount: widget.state.notes.length,
                        itemBuilder: (BuildContext context, int index) {
                          final note = widget.state.notes[index];
                          return ListTile(
                            title: Text(
                              note.text,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${_chapters[note.chapter]['title']} · 本章 ${(note.fraction * 100).round()}%',
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              _go(note.chapter, fraction: note.fraction);
                            },
                            trailing: IconButton(
                              tooltip: '删除摘记',
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                setState(
                                  () => widget.state.notes.removeAt(index),
                                );
                                unawaited(
                                  widget.library.saveState(
                                    widget.book.meta.id,
                                    widget.state,
                                  ),
                                );
                                Navigator.pop(context);
                                _notesSheet();
                              },
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _addNote() async {
    final TextEditingController controller = TextEditingController();
    final String? note = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('添加摘记'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 3,
          maxLines: 7,
          maxLength: 2000,
          decoration: const InputDecoration(hintText: '这一页让你想到了什么？'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (note == null || note.isEmpty) return;
    widget.state.notes.add((
      chapter: _chapter,
      fraction: _fraction,
      text: note,
      created: DateTime.now().millisecondsSinceEpoch,
    ));
    await widget.library.saveState(widget.book.meta.id, widget.state);
    if (mounted) setState(() {});
  }

  void _searchSheet() {
    final TextEditingController search = TextEditingController();
    List<({int chapter, int block, String snippet})> results = const [];
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter update) {
          void run(String value) {
            final String query = value.trim().toLowerCase();
            if (query.isEmpty) {
              update(() => results = const []);
              return;
            }
            final List<({int chapter, int block, String snippet})> found = [];
            for (int ci = 0; ci < _chapters.length && found.length < 80; ci++) {
              final Json chapter = _chapters[ci];
              for (
                int bi = (chapter['b0'] as num).toInt();
                bi < (chapter['b1'] as num).toInt() && found.length < 80;
                bi++
              ) {
                final String body = '${_blocks[bi]['t'] ?? ''}';
                final int at = body.toLowerCase().indexOf(query);
                if (at < 0) continue;
                final int start = math.max(0, at - 24);
                final int end = math.min(body.length, at + query.length + 50);
                found.add((
                  chapter: ci,
                  block: bi,
                  snippet: body.substring(start, end),
                ));
              }
            }
            update(() => results = found);
          }

          return SafeArea(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: SizedBox(
                height: math.min(MediaQuery.sizeOf(context).height * 0.78, 700),
                child: Column(
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: TextField(
                        controller: search,
                        autofocus: true,
                        onChanged: run,
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          hintText: '在这本书里搜索',
                        ),
                      ),
                    ),
                    Expanded(
                      child: search.text.trim().isEmpty
                          ? const Center(child: Text('输入人物、地点或一句话'))
                          : results.isEmpty
                          ? const Center(child: Text('没有找到'))
                          : ListView.builder(
                              itemCount: results.length,
                              itemBuilder: (BuildContext context, int index) {
                                final row = results[index];
                                return ListTile(
                                  title: Text(
                                    row.snippet,
                                    maxLines: 3,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    '${_chapters[row.chapter]['title']}',
                                  ),
                                  onTap: () {
                                    Navigator.pop(context);
                                    _go(row.chapter, block: row.block);
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
        },
      ),
    ).whenComplete(search.dispose);
  }

  void _typographySheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter update) {
          void change(void Function() action) {
            update(action);
            setState(() {});
            _prefs.save();
          }

          return SafeArea(
            child: SizedBox(
              height: math.min(MediaQuery.sizeOf(context).height * 0.82, 670),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
                children: <Widget>[
                  const Text(
                    '阅读排版',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 18),
                  _metric(
                    '字号',
                    _prefs.fontSize,
                    14,
                    34,
                    (double v) => change(() => _prefs.fontSize = v),
                    'px',
                  ),
                  _metric(
                    '行距',
                    _prefs.lineHeight,
                    1.2,
                    2.4,
                    (double v) => change(() => _prefs.lineHeight = v),
                    '×',
                  ),
                  _metric(
                    '字距',
                    _prefs.letterSpacing,
                    -0.5,
                    2.5,
                    (double v) => change(() => _prefs.letterSpacing = v),
                    'px',
                  ),
                  _metric(
                    '页边距',
                    _prefs.margin,
                    8,
                    90,
                    (double v) => change(() => _prefs.margin = v),
                    'px',
                  ),
                  _metric(
                    '正文宽度',
                    _prefs.columnWidth,
                    520,
                    1400,
                    (double v) => change(() => _prefs.columnWidth = v),
                    'px',
                  ),
                  const SizedBox(height: 12),
                  const Text('字体'),
                  Wrap(
                    spacing: 8,
                    children: <Widget>[
                      for (int i = 0; i < 3; i++)
                        ChoiceChip(
                          label: Text(const <String>['宋体', '楷体', '黑体'][i]),
                          selected: _prefs.font == i,
                          onSelected: (_) => change(() => _prefs.font = i),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('纸张'),
                  Wrap(
                    spacing: 8,
                    children: <Widget>[
                      for (int i = 0; i < Tokens.paperColors.length; i++)
                        ChoiceChip(
                          label: Text(Tokens.paperColors[i].$1),
                          selected: _prefs.paper == i,
                          onSelected: (_) => change(() => _prefs.paper = i),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _metric(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> change,
    String unit,
  ) => Row(
    children: <Widget>[
      SizedBox(width: 74, child: Text(label)),
      Expanded(
        child: Slider(value: value, min: min, max: max, onChanged: change),
      ),
      SizedBox(
        width: 58,
        child: Text(
          '${value.toStringAsFixed(1)}$unit',
          textAlign: TextAlign.right,
        ),
      ),
    ],
  );

  @override
  void dispose() {
    _saveTimer?.cancel();
    _displayTimer?.cancel();
    unawaited(widget.library.saveState(widget.book.meta.id, widget.state));
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_chapters.isEmpty) {
      return const Scaffold(body: Center(child: Text('这本书没有可阅读的章节。')));
    }
    final Color paper = _prefs.paperColor;
    final Color ink = _prefs.ink;
    final int first = (_current['b0'] as num?)?.toInt() ?? 0;
    final int last = (_current['b1'] as num?)?.toInt() ?? first;
    final double pct = _progress * 100;
    final TextStyle bodyStyle = TextStyle(
      fontFamily: _prefs.family,
      fontFamilyFallback: const <String>['NotoSerifSC', 'serif'],
      color: ink,
      fontSize: _prefs.fontSize,
      height: _prefs.lineHeight,
      letterSpacing: _prefs.letterSpacing,
    );
    return Scaffold(
      backgroundColor: paper,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: GestureDetector(
              onTap: () => setState(() => _controls = !_controls),
              onHorizontalDragEnd: (DragEndDetails details) {
                final double velocity = details.primaryVelocity ?? 0;
                if (velocity < -350) _go(_chapter + 1);
                if (velocity > 350) _go(_chapter - 1);
              },
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: _prefs.columnWidth),
                  child: SelectionArea(
                    child: NotificationListener<ScrollEndNotification>(
                      onNotification: (ScrollEndNotification _) {
                        if (!_restoring) {
                          _saveTimer?.cancel();
                          unawaited(
                            widget.library.saveState(
                              widget.book.meta.id,
                              widget.state,
                            ),
                          );
                        }
                        return false;
                      },
                      child: SingleChildScrollView(
                        controller: _scroll,
                        padding: EdgeInsets.fromLTRB(
                          _prefs.margin,
                          MediaQuery.paddingOf(context).top + 58,
                          _prefs.margin,
                          MediaQuery.paddingOf(context).bottom + 90,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Text(
                              '${_current['title'] ?? ''}',
                              style: bodyStyle.copyWith(
                                fontSize: _prefs.fontSize * 1.36,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SizedBox(height: _prefs.fontSize * 1.5),
                            for (
                              int i = first;
                              i < last && i < _blocks.length;
                              i++
                            )
                              if (!(i == first &&
                                  _blocks[i]['k'] == 'h' &&
                                  _blocks[i]['t'] == _current['title']))
                                Padding(
                                  key: _blockKeys.putIfAbsent(i, GlobalKey.new),
                                  padding: EdgeInsets.only(
                                    bottom: _prefs.fontSize * 0.65,
                                  ),
                                  child: _paragraph(i, bodyStyle),
                                ),
                            const SizedBox(height: 42),
                            Row(
                              children: <Widget>[
                                if (_chapter > 0)
                                  TextButton.icon(
                                    onPressed: () => _go(_chapter - 1),
                                    icon: const Icon(Icons.arrow_back),
                                    label: const Text('上一章'),
                                  ),
                                const Spacer(),
                                if (_chapter + 1 < _chapters.length)
                                  TextButton.icon(
                                    onPressed: () => _go(_chapter + 1),
                                    icon: const Icon(Icons.arrow_forward),
                                    label: const Text('下一章'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '${_current['title'] ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: _prefs.muted, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Text(
                      '${pct.toStringAsFixed(pct < 1 ? 1 : 0)}%',
                      style: TextStyle(color: _prefs.muted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: ExcludeSemantics(
              excluding: !_controls,
              child: IgnorePointer(
                ignoring: !_controls,
                child: AnimatedSlide(
                  offset: _controls ? Offset.zero : const Offset(0, 1),
                  duration: const Duration(milliseconds: 180),
                  child: _toolbar(),
                ),
              ),
            ),
          ),
          if (!_controls)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: 64 + MediaQuery.paddingOf(context).bottom,
              child: Semantics(
                button: true,
                label: '打开阅读工具',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _controls = true),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: EdgeInsets.only(
                        bottom: MediaQuery.paddingOf(context).bottom + 9,
                      ),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: ink.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(99),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 22,
                            vertical: 4,
                          ),
                          child: Icon(
                            Icons.keyboard_arrow_up,
                            size: 21,
                            color: _prefs.muted,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _paragraph(int index, TextStyle style) {
    final Json block = _blocks[index];
    final String kind = '${block['k'] ?? 'p'}';
    if (kind == 'img') {
      final String? encoded = widget.book.images['${block['src']}'];
      return encoded == null
          ? Text('[图片未保存]', style: style.copyWith(color: _prefs.muted))
          : Image.memory(base64Decode(encoded), fit: BoxFit.contain);
    }
    final String text = '${block['t'] ?? ''}';
    if (kind == 'h') {
      return Text(
        text,
        style: style.copyWith(
          fontWeight: FontWeight.w600,
          fontSize: style.fontSize! * 1.13,
        ),
      );
    }
    return Text('　　$text', style: style, textAlign: TextAlign.justify);
  }

  Widget _toolbar() {
    final Tokens t = _prefs.dark ? Tokens.night : Tokens.light;
    return Material(
      color: t.sheet,
      elevation: 12,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  IconButton(
                    tooltip: '返回书架',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  Expanded(
                    child: Text(
                      widget.book.meta.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: t.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '添加书签',
                    onPressed: _bookmark,
                    icon: const Icon(Icons.bookmark_add_outlined),
                  ),
                  IconButton(
                    tooltip: '搜索',
                    onPressed: _searchSheet,
                    icon: const Icon(Icons.search),
                  ),
                  IconButton(
                    tooltip: '收起工具',
                    onPressed: () => setState(() => _controls = false),
                    icon: const Icon(Icons.keyboard_arrow_down),
                  ),
                ],
              ),
              Row(
                children: <Widget>[
                  TextButton(
                    onPressed: _chapter > 0 ? () => _go(_chapter - 1) : null,
                    child: const Text('上一章'),
                  ),
                  Expanded(
                    child: Slider(
                      value: _chapter.toDouble().clamp(
                        0.0,
                        math.max(0, _chapters.length - 1).toDouble(),
                      ),
                      min: 0,
                      max: math.max(1, _chapters.length - 1).toDouble(),
                      divisions: _chapters.length > 1 && _chapters.length < 1000
                          ? _chapters.length - 1
                          : null,
                      onChanged: (double value) =>
                          _go(value.round().clamp(0, _chapters.length - 1)),
                    ),
                  ),
                  TextButton(
                    onPressed: _chapter + 1 < _chapters.length
                        ? () => _go(_chapter + 1)
                        : null,
                    child: const Text('下一章'),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: <Widget>[
                  _tool(Icons.list, '目录', _chaptersSheet),
                  _tool(Icons.bookmark_outline, '书签', _bookmarksSheet),
                  _tool(Icons.edit_note_outlined, '摘记', _notesSheet),
                  _tool(Icons.format_size, '排版', _typographySheet),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tool(IconData icon, String label, VoidCallback action) =>
      TextButton.icon(
        onPressed: action,
        icon: Icon(icon, size: 22),
        label: Text(label),
      );
}
