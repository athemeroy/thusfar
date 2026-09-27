// JavaScript-only Flutter Web entrypoint. Browser DOM APIs are intentionally
// confined here; native targets compile lib/main.dart instead.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart'
    show KeyEvent, KeyUpEvent, LogicalKeyboardKey;
import 'package:thusfar_core/title_spoilers.dart';

import '../ui/theme.dart';
import 'web_ai_panel.dart';
import 'web_ask_panel.dart';
import 'web_storage.dart';
import 'webdav_sync.dart';

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
  Map<String, Json?> _preparations = const <String, Json?>{};
  Set<String> _invalidPreparations = const <String>{};
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
    final List<(Json?, bool)> preparations =
        await Future.wait(<Future<(Json?, bool)>>[
          for (final WebBookMeta book in books)
            () async {
              try {
                return (await library.loadPreparation(book.id), false);
              } on Object {
                // A damaged AI draft must not hide an otherwise readable book.
                return (null, true);
              }
            }(),
        ]);
    if (!mounted) return;
    setState(() {
      _books = books;
      _states = <String, WebReadingState>{
        for (int i = 0; i < books.length; i++) books[i].id: states[i],
      };
      _preparations = <String, Json?>{
        for (int i = 0; i < books.length; i++) books[i].id: preparations[i].$1,
      };
      _invalidPreparations = <String>{
        for (int i = 0; i < books.length; i++)
          if (preparations[i].$2) books[i].id,
      };
      _error = null;
    });
  }

  Future<void> _import() async {
    final WebLibrary? library = _library;
    if (library == null || _busy) return;
    unawaited(WebLibrary.requestPersistence());
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

  Future<void> _openAi(WebBookMeta meta) async {
    final WebLibrary? library = _library;
    if (library == null || _busy) return;
    setState(() => _busy = true);
    try {
      final WebBook? book = await library.load(meta.id);
      final WebReadingState reading = await library.state(meta.id);
      if (!mounted) return;
      if (book == null) throw StateError('书籍内容已不存在');
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) =>
              WebAiPanel(book: book, reading: reading, library: library),
        ),
      );
      await _refresh();
    } on Object catch (error) {
      _message('打开整理失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openWebDav() async {
    final WebLibrary? library = _library;
    if (library == null || _busy) return;
    unawaited(WebLibrary.requestPersistence());
    setState(() => _busy = true);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => WebDavSyncPage(library: library, books: _books),
        ),
      );
      await _refresh();
    } on Object catch (error) {
      _message('打开 WebDAV 失败：$error');
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
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('整理人物与前情'),
              onTap: () => Navigator.pop(context, 'prepare'),
            ),
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
    if (choice == 'prepare') {
      await _openAi(book);
    } else if (choice == 'export') {
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
                              style: TextStyle(color: t.ink2, letterSpacing: 2),
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
                        IconButton(
                          onPressed: _busy || _library == null
                              ? null
                              : _openWebDav,
                          tooltip: 'WebDAV 快照',
                          icon: const Icon(Icons.cloud_sync_outlined),
                        ),
                        const SizedBox(width: 6),
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
                                '导入 TXT 或 EPUB，文件不会上传到 GitHub；书库保存在当前浏览器。只有你主动整理时，相关正文才会发给选定的模型服务商。',
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
                                  preparation: _preparations[book.id],
                                  preparationInvalid: _invalidPreparations
                                      .contains(book.id),
                                  onOpen: () => _open(book),
                                  onPrepare: () => _openAi(book),
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
                      style: TextStyle(color: t.ink2, fontSize: 12),
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
    required this.preparation,
    required this.preparationInvalid,
    required this.onOpen,
    required this.onPrepare,
    required this.onMenu,
  });

  final WebBookMeta book;
  final WebReadingState state;
  final Json? preparation;
  final bool preparationInvalid;
  final VoidCallback onOpen;
  final VoidCallback onPrepare;
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
    final int prepared =
        (preparation?['completed_count'] as num?)?.toInt() ?? 0;
    final int total = (preparation?['target_count'] as num?)?.toInt() ?? 0;
    final String aiStatus = switch (preparation?['phase']) {
      'complete' => '已完成',
      'error' => '遇到问题',
      'running' => '可继续',
      _ => '已暂停',
    };
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
                      style: TextStyle(fontSize: 12, color: t.ink2),
                    ),
                    if (total > 0 || preparationInvalid) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        preparationInvalid
                            ? '整理记录无法读取 · 点人物查看并清除'
                            : '人物整理 $prepared/$total 片 · $aiStatus',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: t.ink2),
                      ),
                    ],
                  ],
                ),
              ),
              Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: <Widget>[
                  IconButton(
                    tooltip: '整理人物与前情',
                    onPressed: onPrepare,
                    icon: const Icon(Icons.auto_awesome_outlined),
                  ),
                  IconButton(
                    tooltip: '书籍选项',
                    onPressed: onMenu,
                    icon: const Icon(Icons.more_vert),
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

class _WebPageFragment {
  const _WebPageFragment({
    required this.block,
    required this.kind,
    required this.startLine,
    required this.lines,
    required this.height,
    this.text = '',
  });

  final int block;
  final String kind;
  final int startLine;
  final int lines;
  final double height;
  final String text;
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
      pageMode = json['pageMode'] is bool ? json['pageMode'] as bool : true;
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
  bool pageMode = true;

  Color get paperColor => Tokens.paperColors[paper].$2;
  bool get dark => paper == Tokens.paperColors.length - 1;
  Color get ink => dark ? Tokens.night.ink : Tokens.light.ink;
  Color get muted => dark ? Tokens.night.ink2 : Tokens.light.ink2;
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
          'pageMode': pageMode,
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
  static final RegExp _chapterNumber = RegExp(
    r'^(第\s*[0-9零一二三四五六七八九十百千]+\s*[部章回卷节篇集]|(?:chapter|part|book)\s+[0-9ivxlcdm]+)',
    caseSensitive: false,
  );
  final ScrollController _scroll = ScrollController();
  final FocusNode _readerFocus = FocusNode();
  final Map<int, GlobalKey> _blockKeys = <int, GlobalKey>{};
  final WebReaderPrefs _prefs = WebReaderPrefs();
  List<List<_WebPageFragment>> _pages = const <List<_WebPageFragment>>[];
  int? _pageLayoutKey;
  int _pageIndex = 0;
  int _turnDirection = 1;
  bool _wheelLocked = false;
  Timer? _wheelTimer;
  Offset? _pointerStart;
  DateTime? _pointerStarted;
  bool _pointerStartedWithSelection = false;
  Timer? _saveTimer;
  Timer? _displayTimer;
  bool _controls = false;
  bool _restoring = true;
  String? _selectedText;
  late int _chapter;
  int? _jumpBlock;

  List<Json> get _chapters => widget.book.chapters;
  List<Json> get _blocks => widget.book.blocks;
  Json get _current => _chapters[_chapter];

  String _safeChapterTitle(int index) {
    final Json chapter = _chapters[index];
    final String title = '${chapter['title'] ?? '第 ${index + 1} 章'}';
    final Object? status = widget.book.nativeBackup?['status'];
    final Object? quality = status is Json ? status['quality'] : null;
    final Object? pending = quality is Json ? quality['pending'] : null;
    final bool checkPending =
        pending is List<Object?> && pending.contains('chapter-titles');
    if (index <= _chapter ||
        !titleSpoils(
          chapter['spoil'],
          title,
          checkPending: checkPending,
          checkedByModel: chapter['spoilSource'] == 'model',
        )) {
      return title;
    }
    return _chapterNumber.firstMatch(title.trim())?.group(0) ??
        '第 ${index + 1} 节';
  }

  @override
  void initState() {
    super.initState();
    _chapter = widget.state.chapter.clamp(0, math.max(0, _chapters.length - 1));
    _scroll.addListener(_scrolled);
    html.window.addEventListener('keydown', _domKey, true);
    html.window.addEventListener('wheel', _domWheel, true);
    if (!_prefs.pageMode) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _restoreFraction(widget.state.fraction),
      );
    }
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
    if (_prefs.pageMode) {
      if (_pages.isEmpty) return widget.state.fraction;
      return _pages.length == 1 ? 1 : _pageIndex / (_pages.length - 1);
    }
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
    _pageLayoutKey = null;
    _pages = const <List<_WebPageFragment>>[];
    _pageIndex = 0;
    setState(() {
      _chapter = chapter;
      widget.state.chapter = chapter;
      widget.state.fraction = fraction;
      widget.state.lastOpened = DateTime.now().millisecondsSinceEpoch;
      _controls = false;
    });
    unawaited(widget.library.saveState(widget.book.meta.id, widget.state));
    if (!_prefs.pageMode) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _restoreFraction(fraction),
      );
    }
  }

  void _bookmark() {
    final double fraction = _fraction;
    final int index = widget.state.bookmarks.indexWhere(
      (mark) =>
          mark.chapter == _chapter && (mark.fraction - fraction).abs() < 0.07,
    );
    setState(() {
      if (index >= 0) {
        widget.state.remove(widget.state.bookmarks[index]);
      } else {
        widget.state.addBookmark(_chapter, fraction);
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

  Future<void> _openAi() async {
    _saveTimer?.cancel();
    await widget.library.saveState(widget.book.meta.id, widget.state);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => WebAiPanel(
          book: widget.book,
          reading: widget.state,
          library: widget.library,
        ),
      ),
    );
  }

  int _askCutoffBlockExclusive() {
    final int first = (_current['b0'] as num?)?.toInt() ?? 0;
    final int last = (_current['b1'] as num?)?.toInt() ?? first;
    if (_prefs.pageMode && _pages.isNotEmpty) {
      for (int page = _pageIndex + 1; page < _pages.length; page++) {
        for (final _WebPageFragment fragment in _pages[page]) {
          if (fragment.block >= first && fragment.block < last) {
            // A paragraph continued on the next page is still unread in full.
            return fragment.block;
          }
        }
      }
      return last;
    }
    final double headingBottom = MediaQuery.paddingOf(context).top + 58;
    for (int i = first; i < last && i < _blocks.length; i++) {
      // The chapter heading can be rendered separately from the body.
      if (i == first &&
          _blocks[i]['k'] == 'h' &&
          _blocks[i]['t'] == _current['title']) {
        continue;
      }
      final BuildContext? blockContext = _blockKeys[i]?.currentContext;
      final RenderObject? render = blockContext?.findRenderObject();
      if (render is! RenderBox || !render.hasSize) return first;
      final double bottom = render
          .localToGlobal(Offset(0, render.size.height))
          .dy;
      if (bottom > headingBottom) return i;
    }
    return last;
  }

  Future<void> _openAsk({String? selectedText}) async {
    final int safeBlock = _askCutoffBlockExclusive();
    _saveTimer?.cancel();
    await widget.library.saveState(widget.book.meta.id, widget.state);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => WebAskPanel(
          book: widget.book,
          chapterIndex: _chapter,
          cutoffBlockExclusive: safeBlock,
          selectedText: selectedText,
          onCitationTap: (int blockIndex) {
            final int targetChapter = _chapters.indexWhere((Json chapter) {
              final int start = (chapter['b0'] as num?)?.toInt() ?? 0;
              final int end = (chapter['b1'] as num?)?.toInt() ?? start;
              return start <= blockIndex && blockIndex < end;
            });
            if (targetChapter < 0) return;
            Navigator.of(context).pop();
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _go(targetChapter, block: blockIndex);
            });
          },
        ),
      ),
    );
    _selectedText = null;
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
                    return ListTile(
                      selected: index == _chapter,
                      title: Text(_safeChapterTitle(index), maxLines: 2),
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
                            title: Text(_safeChapterTitle(mark.chapter)),
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
                                setState(() => widget.state.remove(mark));
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
                              '${_safeChapterTitle(note.chapter)} · 本章 ${(note.fraction * 100).round()}%',
                            ),
                            onTap: () {
                              Navigator.pop(context);
                              _go(note.chapter, fraction: note.fraction);
                            },
                            trailing: IconButton(
                              tooltip: '删除摘记',
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                setState(() => widget.state.remove(note));
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
    widget.state.addNote(_chapter, _fraction, note);
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
                                    _safeChapterTitle(row.chapter),
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
            final double fraction = _fraction;
            update(action);
            widget.state.fraction = fraction;
            _pageLayoutKey = null;
            _pages = const <List<_WebPageFragment>>[];
            _pageIndex = 0;
            _restoring = true;
            setState(() {});
            _prefs.save();
            _queueSave();
            if (!_prefs.pageMode) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _restoreFraction(fraction),
              );
            }
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
                  const SizedBox(height: 16),
                  const Text('阅读方式'),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: <Widget>[
                      ChoiceChip(
                        label: const Text('翻页'),
                        selected: _prefs.pageMode,
                        onSelected: (_) => change(() => _prefs.pageMode = true),
                      ),
                      ChoiceChip(
                        label: const Text('连续滚动'),
                        selected: !_prefs.pageMode,
                        onSelected: (_) =>
                            change(() => _prefs.pageMode = false),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _prefs.pageMode
                        ? '轻触左右侧、横滑、按方向键或空格翻页；鼠标滚轮每次翻一页。'
                        : '上下滑动连续阅读；需要翻页时可随时切换。',
                    style: TextStyle(
                      color: Theme.of(context).hintColor,
                      fontSize: 12,
                    ),
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
    _wheelTimer?.cancel();
    html.window.removeEventListener('keydown', _domKey, true);
    html.window.removeEventListener('wheel', _domWheel, true);
    unawaited(widget.library.saveState(widget.book.meta.id, widget.state));
    _readerFocus.dispose();
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
      leadingDistribution: TextLeadingDistribution.even,
    );
    return Scaffold(
      backgroundColor: paper,
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: Focus(
              focusNode: _readerFocus,
              autofocus: true,
              onKeyEvent: _readerKey,
              child: Listener(
                onPointerSignal: _wheel,
                onPointerDown: _readerPointerDown,
                onPointerUp: _readerPointerUp,
                onPointerCancel: (_) {
                  _pointerStart = null;
                  _pointerStarted = null;
                },
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (TapUpDetails details) {
                    if (_prefs.pageMode) return;
                    if (_selectedText?.isNotEmpty == true) return;
                    setState(() => _controls = !_controls);
                    _readerFocus.requestFocus();
                  },
                  onHorizontalDragEnd: (DragEndDetails details) {
                    if (_prefs.pageMode) return;
                    final double velocity = details.primaryVelocity ?? 0;
                    if (velocity < -350) _go(_chapter + 1);
                    if (velocity > 350) _go(_chapter - 1);
                  },
                  child: _prefs.pageMode
                      ? _pageBody(bodyStyle)
                      : Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: _prefs.columnWidth,
                            ),
                            child: SelectionArea(
                              onSelectionChanged: (SelectedContent? content) =>
                                  _selectedText = content?.plainText,
                              contextMenuBuilder:
                                  (
                                    BuildContext context,
                                    SelectableRegionState selectable,
                                  ) => AdaptiveTextSelectionToolbar.buttonItems(
                                    anchors: selectable.contextMenuAnchors,
                                    buttonItems: <ContextMenuButtonItem>[
                                      ...selectable.contextMenuButtonItems,
                                      ContextMenuButtonItem(
                                        label: '问书',
                                        onPressed: () {
                                          final String? selected =
                                              _selectedText;
                                          ContextMenuController.removeAny();
                                          unawaited(
                                            _openAsk(selectedText: selected),
                                          );
                                        },
                                      ),
                                    ],
                                  ),
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
                                    // Reserve the expanded toolbar's full height so the
                                    // chapter navigation stays reachable at scroll end.
                                    // Keep this space constant as controls open and close
                                    // to preserve the visible reading position.
                                    MediaQuery.paddingOf(context).bottom + 168,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
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
                                            _blocks[i]['t'] ==
                                                _current['title']))
                                          Padding(
                                            key: _blockKeys.putIfAbsent(
                                              i,
                                              GlobalKey.new,
                                            ),
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
                                              onPressed: () =>
                                                  _go(_chapter - 1),
                                              icon: const Icon(
                                                Icons.arrow_back,
                                              ),
                                              label: const Text('上一章'),
                                            ),
                                          const Spacer(),
                                          if (_chapter + 1 < _chapters.length)
                                            TextButton.icon(
                                              onPressed: () =>
                                                  _go(_chapter + 1),
                                              icon: const Icon(
                                                Icons.arrow_forward,
                                              ),
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
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: ColoredBox(
              color: paper,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
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
                children: <Widget>[
                  Expanded(child: _tool(Icons.list, '目录', _chaptersSheet)),
                  Expanded(
                    child: _tool(Icons.bookmark_outline, '书签', _bookmarksSheet),
                  ),
                  Expanded(
                    child: _tool(Icons.auto_awesome_outlined, '人物', _openAi),
                  ),
                  Expanded(
                    child: _tool(
                      Icons.chat_bubble_outline,
                      '问书',
                      () => _openAsk(),
                    ),
                  ),
                  Expanded(
                    child: _tool(Icons.edit_note_outlined, '摘记', _notesSheet),
                  ),
                  Expanded(
                    child: _tool(Icons.format_size, '排版', _typographySheet),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tool(IconData icon, String label, VoidCallback action) => TextButton(
    onPressed: action,
    style: TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(icon, size: 22),
        const SizedBox(height: 3),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    ),
  );

  TextStyle _fragmentStyle(_WebPageFragment fragment, TextStyle body) {
    if (fragment.kind == 'title') {
      return body.copyWith(
        fontSize: _prefs.fontSize * 1.36,
        fontWeight: FontWeight.w600,
      );
    }
    if (fragment.kind == 'h') {
      return body.copyWith(
        fontSize: _prefs.fontSize * 1.13,
        fontWeight: FontWeight.w600,
      );
    }
    return body;
  }

  String _fragmentText(_WebPageFragment fragment) {
    return fragment.text;
  }

  StrutStyle _bodyStrut() => StrutStyle(
    fontSize: _prefs.fontSize,
    height: _prefs.lineHeight,
    forceStrutHeight: true,
    leadingDistribution: TextLeadingDistribution.even,
  );

  List<List<_WebPageFragment>> _paginate(
    double width,
    double height,
    TextStyle bodyStyle,
  ) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final double capacity = math.max(1, height - 12);
    final List<List<_WebPageFragment>> pages = <List<_WebPageFragment>>[];
    List<_WebPageFragment> current = <_WebPageFragment>[];
    double used = 0;

    void flush() {
      if (current.isEmpty) return;
      pages.add(current);
      current = <_WebPageFragment>[];
      used = 0;
    }

    void gap(double space, double nextLine) {
      if (current.isNotEmpty && used + space + nextLine <= capacity) {
        current.add(
          _WebPageFragment(
            block: -1,
            kind: 'space',
            startLine: 0,
            lines: 0,
            height: space,
          ),
        );
        used += space;
      }
    }

    void addText(int block, String kind, String text, TextStyle style) {
      if (text.isEmpty) return;
      final TextPainter painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textAlign: kind == 'p' ? TextAlign.justify : TextAlign.left,
        strutStyle: kind == 'p' ? _bodyStrut() : null,
        textScaler: scaler,
      )..layout(maxWidth: width);
      final List<LineMetrics> metrics = painter.computeLineMetrics();
      final int totalLines = math.max(1, metrics.length);
      final double line = math.max(1, painter.height / totalLines);
      final List<int> lineStarts = <int>[0];
      for (int i = 1; i < totalLines; i++) {
        final LineMetrics metric = metrics[i];
        final double middle =
            metric.baseline - metric.ascent + metric.height / 2;
        final int start = painter
            .getLineBoundary(painter.getPositionForOffset(Offset(1, middle)))
            .start
            .clamp(lineStarts.last, text.length);
        lineStarts.add(start);
      }
      int from = 0;
      while (from < totalLines) {
        int fit = ((capacity - used) / line).floor();
        if (fit < 1 && current.isNotEmpty) {
          flush();
          continue;
        }
        fit = math.max(1, fit);
        final int take = math.min(fit, totalLines - from);
        final int start = from == 0 ? 0 : lineStarts[from];
        final int end = from + take >= totalLines
            ? text.length
            : lineStarts[from + take];
        current.add(
          _WebPageFragment(
            block: block,
            kind: kind,
            startLine: from,
            lines: take,
            height: take * line,
            text: text.substring(
              start.clamp(0, text.length),
              end.clamp(start, text.length),
            ),
          ),
        );
        used += take * line;
        from += take;
        if (from < totalLines) flush();
      }
      painter.dispose();
      gap(
        kind == 'title' ? _prefs.fontSize * 1.15 : _prefs.fontSize * 0.38,
        line,
      );
    }

    final String title = '${_current['title'] ?? ''}';
    addText(
      -1,
      'title',
      title,
      bodyStyle.copyWith(
        fontSize: _prefs.fontSize * 1.36,
        fontWeight: FontWeight.w600,
      ),
    );
    final int first = (_current['b0'] as num?)?.toInt() ?? 0;
    final int last = (_current['b1'] as num?)?.toInt() ?? first;
    for (int i = first; i < last && i < _blocks.length; i++) {
      final Json block = _blocks[i];
      final String kind = '${block['k'] ?? 'p'}';
      if (i == first && kind == 'h' && block['t'] == title) continue;
      if (kind == 'img') {
        final double imageHeight = math.min(capacity * 0.55, width * 0.8);
        if (current.isNotEmpty && used + imageHeight > capacity) flush();
        current.add(
          _WebPageFragment(
            block: i,
            kind: 'img',
            startLine: 0,
            lines: 0,
            height: imageHeight,
          ),
        );
        used += imageHeight;
        gap(_prefs.fontSize * 0.38, _prefs.fontSize * _prefs.lineHeight);
      } else {
        final String text = '${block['t'] ?? ''}';
        addText(
          i,
          kind == 'h' ? 'h' : 'p',
          kind == 'h' ? text : '　　$text',
          kind == 'h'
              ? bodyStyle.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: _prefs.fontSize * 1.13,
                )
              : bodyStyle,
        );
      }
    }
    flush();
    if (pages.isEmpty) pages.add(<_WebPageFragment>[]);
    return pages;
  }

  void _ensurePages(double width, double height, TextStyle bodyStyle) {
    final int key = Object.hash(
      _chapter,
      width.round(),
      height.round(),
      _prefs.fontSize,
      _prefs.lineHeight,
      _prefs.letterSpacing,
      _prefs.font,
      _prefs.margin,
      MediaQuery.textScalerOf(context).scale(10).toStringAsFixed(2),
    );
    if (_pageLayoutKey == key) return;
    _pages = _paginate(width, height, bodyStyle);
    int target = -1;
    if (_jumpBlock != null) {
      target = _pages.indexWhere(
        (List<_WebPageFragment> page) => page.any(
          (_WebPageFragment fragment) => fragment.block == _jumpBlock,
        ),
      );
    }
    if (target < 0) {
      target = _pages.length == 1
          ? 0
          : (widget.state.fraction * (_pages.length - 1)).round();
    }
    _pageIndex = target.clamp(0, _pages.length - 1);
    if (widget.state.fraction != _fraction) {
      widget.state.fraction = _fraction;
      _queueSave();
    }
    _jumpBlock = null;
    _pageLayoutKey = key;
    _restoring = false;
  }

  void _turnPage(int delta) {
    if (!_prefs.pageMode || _pages.isEmpty) return;
    final int next = _pageIndex + delta;
    if (next < 0) {
      _go(_chapter - 1, fraction: 1);
      return;
    }
    if (next >= _pages.length) {
      _go(_chapter + 1);
      return;
    }
    setState(() {
      _pageIndex = next;
      _turnDirection = delta.sign;
      _controls = false;
      _selectedText = null;
      widget.state.fraction = _fraction;
      widget.state.lastOpened = DateTime.now().millisecondsSinceEpoch;
    });
    _queueSave();
  }

  void _wheel(PointerSignalEvent event) {
    if (event is PointerScrollEvent) _wheelTurn(event.scrollDelta.dy);
  }

  void _wheelTurn(double dy) {
    if (!_prefs.pageMode || _wheelLocked) return;
    if (dy.abs() < 4) return;
    _wheelLocked = true;
    _wheelTimer?.cancel();
    _wheelTimer = Timer(const Duration(milliseconds: 350), () {
      _wheelLocked = false;
    });
    _turnPage(dy > 0 ? 1 : -1);
  }

  bool get _readerRouteActive =>
      mounted && ModalRoute.of(context)?.isCurrent == true;

  void _domWheel(html.Event event) {
    if (!_readerRouteActive || event is! html.WheelEvent) return;
    _wheelTurn(event.deltaY.toDouble());
  }

  void _domKey(html.Event event) {
    if (!_readerRouteActive ||
        !_prefs.pageMode ||
        _controls ||
        event is! html.KeyboardEvent) {
      return;
    }
    if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) {
      return;
    }
    final html.Element? active = html.document.activeElement;
    if (active is html.InputElement ||
        active is html.TextAreaElement ||
        active is html.SelectElement) {
      return;
    }
    final int direction = switch (event.key) {
      'ArrowRight' || 'ArrowDown' || 'PageDown' || ' ' || 'j' || 'l' => 1,
      'ArrowLeft' || 'ArrowUp' || 'PageUp' || 'k' || 'h' => -1,
      _ => 0,
    };
    if (direction == 0) return;
    event.preventDefault();
    event.stopPropagation();
    _turnPage(direction);
  }

  void _readerPointerDown(PointerDownEvent event) {
    if (!_prefs.pageMode || event.buttons != 1) return;
    _pointerStart = event.localPosition;
    _pointerStarted = DateTime.now();
    _pointerStartedWithSelection = _selectedText?.isNotEmpty == true;
  }

  void _readerPointerUp(PointerUpEvent event) {
    final Offset? start = _pointerStart;
    final DateTime? started = _pointerStarted;
    _pointerStart = null;
    _pointerStarted = null;
    if (!_prefs.pageMode || start == null || started == null) return;
    final Offset delta = event.localPosition - start;
    final int elapsed = DateTime.now().difference(started).inMilliseconds;
    if (elapsed > 900) return;
    // A normal short tap can dismiss a prior selection and turn the page.
    // Keep a dragged selection intact for copy or 问书.
    if (delta.distance > 14 &&
        (_pointerStartedWithSelection || _selectedText?.isNotEmpty == true)) {
      return;
    }
    _selectedText = null;
    _readerFocus.requestFocus();
    if (delta.dx.abs() > 55 && delta.dx.abs() > delta.dy.abs() * 1.3) {
      _turnPage(delta.dx < 0 ? 1 : -1);
      return;
    }
    if (delta.distance > 14 || elapsed > 600) return;
    final double x =
        event.localPosition.dx / math.max(1, MediaQuery.sizeOf(context).width);
    if (x < 1 / 3) {
      _turnPage(-1);
    } else if (x > 2 / 3) {
      _turnPage(1);
    } else {
      setState(() => _controls = !_controls);
    }
  }

  KeyEventResult _readerKey(FocusNode _, KeyEvent event) {
    if (!_prefs.pageMode || event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.keyJ ||
        key == LogicalKeyboardKey.keyL) {
      _turnPage(1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.keyK ||
        key == LogicalKeyboardKey.keyH) {
      _turnPage(-1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape && _controls) {
      setState(() => _controls = false);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _selectionArea(Widget child) => SelectionArea(
    onSelectionChanged: (SelectedContent? content) =>
        _selectedText = content?.plainText,
    contextMenuBuilder:
        (BuildContext context, SelectableRegionState selectable) =>
            AdaptiveTextSelectionToolbar.buttonItems(
              anchors: selectable.contextMenuAnchors,
              buttonItems: <ContextMenuButtonItem>[
                ...selectable.contextMenuButtonItems,
                ContextMenuButtonItem(
                  label: '问书',
                  onPressed: () {
                    final String? selected = _selectedText;
                    ContextMenuController.removeAny();
                    unawaited(_openAsk(selectedText: selected));
                  },
                ),
              ],
            ),
    child: child,
  );

  Widget _pageFragment(
    _WebPageFragment fragment,
    double width,
    TextStyle body,
  ) {
    if (fragment.kind == 'space') return SizedBox(height: fragment.height);
    if (fragment.kind == 'img') {
      final String? encoded =
          widget.book.images['${_blocks[fragment.block]['src']}'];
      return SizedBox(
        height: fragment.height,
        child: encoded == null
            ? Center(child: Text('[图片未保存]', style: body))
            : Image.memory(base64Decode(encoded), fit: BoxFit.contain),
      );
    }
    final TextStyle style = _fragmentStyle(fragment, body);
    final String text = _fragmentText(fragment);
    return SizedBox(
      height: fragment.height,
      child: ClipRect(
        child: SizedBox(
          width: width,
          child: Text(
            text,
            style: style,
            textAlign: fragment.kind == 'p'
                ? TextAlign.justify
                : TextAlign.left,
            strutStyle: fragment.kind == 'p' ? _bodyStrut() : null,
          ),
        ),
      ),
    );
  }

  Widget _pageBody(TextStyle bodyStyle) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints box) {
      final EdgeInsets safe = MediaQuery.paddingOf(context);
      final double top = safe.top + 58;
      final double bottom = safe.bottom + 70;
      final double width = math.min(box.maxWidth, _prefs.columnWidth);
      final double textWidth = math.max(1, width - _prefs.margin * 2);
      final double height = math.max(1, box.maxHeight - top - bottom);
      _ensurePages(textWidth, height, bodyStyle);
      final List<_WebPageFragment> page = _pages[_pageIndex];
      return Padding(
        padding: EdgeInsets.only(top: top, bottom: bottom),
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: width,
            height: height,
            child: ClipRect(
              child: AnimatedSwitcher(
                duration: MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 180),
                transitionBuilder:
                    (Widget child, Animation<double> animation) =>
                        SlideTransition(
                          position: Tween<Offset>(
                            begin: Offset(_turnDirection * 0.12, 0),
                            end: Offset.zero,
                          ).animate(animation),
                          child: FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                        ),
                child: Padding(
                  key: ValueKey<String>('$_chapter:$_pageIndex'),
                  padding: EdgeInsets.symmetric(horizontal: _prefs.margin),
                  child: _selectionArea(
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        for (final _WebPageFragment fragment in page)
                          _pageFragment(fragment, textWidth, bodyStyle),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
