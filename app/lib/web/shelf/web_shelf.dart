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
    show HardwareKeyboard, KeyEvent, KeyUpEvent, LogicalKeyboardKey;
import 'package:thusfar_core/thusfar_core.dart' as knowledge;
import 'package:thusfar_core/chapter_verdicts.dart' show titleCheckPending;

import '../data/library_zip.dart';
import '../ui/theme.dart';

import '../web_ai_panel.dart';
import '../web_ai_engine.dart';
import '../web_ask_panel.dart';
import '../web_model_session.dart';
import '../web_storage.dart';
import '../webdav_sync.dart';
import 'reading_boundary.dart';
import 'common/web_common.dart';

const double _wideShelf = 1140;



class WebShelf extends StatefulWidget {
  const WebShelf({
    super.key,
    this.library,
    this.onOpenBook,
    this.refreshSignal,
    this.onRetryLibrary,
  });

  final Future<WebLibrary>? library;
  final ValueChanged<String>? onOpenBook;
  final Listenable? refreshSignal;
  final VoidCallback? onRetryLibrary;

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
  final TextEditingController _search = TextEditingController();
  String _filter = 'all';
  String _sort = 'recent';
  WebBookMeta? _importedBook;
  bool _offline = html.window.navigator.onLine == false;
  StreamSubscription<html.Event>? _onlineSubscription;
  StreamSubscription<html.Event>? _offlineSubscription;

  @override
  void initState() {
    super.initState();
    widget.refreshSignal?.addListener(_refreshRequested);
    _onlineSubscription = html.window.onOnline.listen((_) {
      if (mounted) setState(() => _offline = false);
    });
    _offlineSubscription = html.window.onOffline.listen((_) {
      if (mounted) setState(() => _offline = true);
    });
    unawaited(_start());
  }

  Future<void> _start() async {
    if (mounted) setState(() => _error = null);
    final Future<WebLibrary>? source = widget.library;
    try {
      final WebLibrary library = await (source ?? WebLibrary.open());
      if (!mounted || source != widget.library) {
        if (source == null) library.close();
        return;
      }
      _library = library;
      await _refresh();
    } on Object catch (error) {
      if (mounted && source == widget.library) {
        setState(() => _error = '$error');
      }
    }
  }

  @override
  void didUpdateWidget(WebShelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshSignal != widget.refreshSignal) {
      oldWidget.refreshSignal?.removeListener(_refreshRequested);
      widget.refreshSignal?.addListener(_refreshRequested);
    }
    if (oldWidget.library != widget.library) {
      _library = null;
      unawaited(_start());
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
    final List<(Json?, bool)> preparations = await Future.wait(
      <Future<(Json?, bool)>>[
        for (final WebBookMeta book in books)
          () async {
            try {
              final Json? preparation = await library.loadPreparation(book.id);
              // The shelf shows only status. Retaining every cited draft here
              // otherwise duplicates the whole prepared library in memory.
              return (
                preparation == null
                    ? null
                    : <String, Object?>{
                        'completed_count': preparation['completed_count'],
                        'target_count': preparation['target_count'],
                        'phase': preparation['phase'],
                      },
                false,
              );
            } on Object {
              // A damaged AI draft must not hide an otherwise readable book.
              return (null, true);
            }
          }(),
      ],
    );
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

  void _refreshRequested() => unawaited(_refresh());

  Future<void> _import() async {
    final WebLibrary? library = _library;
    if (library == null || _busy) return;
    unawaited(WebLibrary.requestPersistence());
    setState(() => _busy = true);
    final FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['txt', 'epub', 'json', 'zip'],
        withData: true,
      );
    } on Object {
      if (mounted) setState(() => _busy = false);
      _message('无法打开文件选择器，请重新选择。');
      return;
    }
    if (!mounted) return;
    if (result == null || result.files.isEmpty) {
      setState(() => _busy = false);
      return;
    }
    final PlatformFile file = result.files.single;
    final Uint8List? bytes = file.bytes;
    if (bytes == null) {
      setState(() => _busy = false);
      _message('浏览器没有交付文件内容，请重新选择。');
      return;
    }
    bool zipRestoreStarted = false;
    try {
      if (file.name.toLowerCase().endsWith('.zip')) {
        final LibraryZipData archive = LibraryZipCodec.decode(bytes);
        if (!mounted) return;
        final bool? applySettings = await showDialog<bool>(
          context: context,
          builder: (BuildContext dialogContext) => AlertDialog(
            title: const Text('恢复整个书库'),
            content: Text(
              '这份 ZIP 含 ${archive.books.length} 本书。相同书籍会安全合并；冲突不会覆盖本地。'
              '独立填写的 API 密钥不在备份中；自定义模型地址可能含敏感路径，请妥善保管 ZIP。'
              '已有书籍保留此浏览器的逐书整理和付费路由，继续前请核对。'
              '是否同时使用备份里的阅读清单、排版和模型设置？',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('保留当前设置'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('使用备份设置'),
              ),
            ],
          ),
        );
        if (applySettings == null) return;
        zipRestoreStarted = true;
        final WebLibraryZipRestoreResult restored = await library
            .importLibraryZipData(archive, applySettings: applySettings);
        if (restored.complete && applySettings) {
          WebModelSession.current.clear();
        }
        await _refresh();
        _message(
          restored.settingsError != null
              ? '已导入 ${restored.imported} 本、合并 ${restored.existing} 本；${restored.settingsError}'
              : restored.complete
              ? '已恢复 ${restored.total} 本书；'
                    '${applySettings ? '设置已导入，模型密钥需重填' : '保留了当前设置'}'
              : '已导入 ${restored.imported} 本、合并 ${restored.existing} 本；'
                    '${restored.failures.length} 本有冲突。${restored.failures.first}',
        );
        return;
      } else if (file.name.toLowerCase().endsWith('.json')) {
        final String id = await library.importBackup(bytes);
        final WebBook? imported = await library.load(id);
        _importedBook = imported?.meta;
      } else {
        _importedBook = await library.importFile(file.name, bytes);
      }
      await _refresh();
      if (mounted) {
        _search.clear();
        setState(() => _filter = 'all');
      }
      if (_importedBook == null) {
        _message('已导入到此浏览器的本地书库');
      }
    } on Object catch (error) {
      if (zipRestoreStarted) {
        try {
          await _refresh();
        } on Object {
          // The original restore error remains the actionable message.
        }
      }
      _message('导入失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportLibrary() async {
    final WebLibrary? library = _library;
    if (library == null || _busy) return;
    setState(() => _busy = true);
    try {
      await library.exportLibraryZip();
      _message('已下载整个书库 ZIP；含书籍、摘记与设置，独立 API 密钥未包含，请妥善保管。');
    } on Object catch (error) {
      _message('导出书库失败：$error');
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
    if (library == null || _busy) return;
    setState(() => _busy = true);
    try {
      if (widget.onOpenBook != null) {
        FocusScope.of(context).unfocus();
        widget.onOpenBook!(meta.id);
        return;
      }
      final WebBook? book = await library.load(meta.id);
      final WebReadingState state = await library.state(meta.id);
      if (!mounted) return;
      if (book == null) throw StateError('书籍内容已不存在');
      FocusScope.of(context).unfocus();
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
    if (library == null || _busy) return;
    final String? choice = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (BuildContext context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              ListTile(
                title: Text(book.title),
                subtitle: const Text('存放在此浏览器'),
                trailing: IconButton(
                  tooltip: '关闭书籍选项',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
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
        if (_importedBook?.id == book.id) _importedBook = null;
        await _refresh();
      }
    }
  }

  @override
  void dispose() {
    widget.refreshSignal?.removeListener(_refreshRequested);
    _search.dispose();
    unawaited(_onlineSubscription?.cancel());
    unawaited(_offlineSubscription?.cancel());
    if (widget.library == null) _library?.close();
    super.dispose();
  }

  double _bookProgress(WebBookMeta book) {
    final WebReadingState? state = _states[book.id];
    if (state == null || book.chapters <= 0) return 0;
    return ((state.chapter + state.fraction) / book.chapters).clamp(0.0, 1.0);
  }

  bool _matchesFilter(WebBookMeta book) {
    final double progress = _bookProgress(book);
    return switch (_filter) {
      'unread' => progress == 0,
      'reading' => progress > 0 && progress < 0.995,
      'finished' => progress >= 0.995,
      _ => true,
    };
  }

  void _resetFilters() {
    _search.clear();
    setState(() => _filter = 'all');
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final String query = _search.text.trim().toLowerCase();
    final List<WebBookMeta> books =
        _books.where((WebBookMeta book) {
          return _matchesFilter(book) &&
              (query.isEmpty ||
                  '${book.title} ${book.author}'.toLowerCase().contains(query));
        }).toList()..sort((WebBookMeta a, WebBookMeta b) {
          if (_sort == 'title') return a.title.compareTo(b.title);
          if (_sort == 'added') return b.added.compareTo(a.added);
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
                  padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
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
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: <Widget>[
                            FilledButton.icon(
                              onPressed: _busy || _library == null
                                  ? null
                                  : _import,
                              icon: const Icon(Icons.add),
                              label: const Text('导入书籍'),
                            ),
                            OutlinedButton.icon(
                              onPressed: _busy || _library == null
                                  ? null
                                  : _exportLibrary,
                              icon: const Icon(Icons.archive_outlined),
                              label: const Text('整库备份'),
                            ),
                            IconButton(
                              onPressed: _busy || _library == null
                                  ? null
                                  : _openWebDav,
                              tooltip: 'WebDAV 快照',
                              icon: const Icon(Icons.cloud_sync_outlined),
                            ),
                          ],
                        ),
                        if (_busy) ...<Widget>[
                          const SizedBox(height: 12),
                          const LinearProgressIndicator(),
                        ],
                        if (_offline) ...<Widget>[
                          const SizedBox(height: 12),
                          Text(
                            '当前离线 · 本地书籍可继续阅读，联网后再整理或同步。',
                            style: TextStyle(color: t.ink2, height: 1.5),
                          ),
                        ],
                        if (_importedBook != null) ...<Widget>[
                          const SizedBox(height: 16),
                          Semantics(
                            container: true,
                            liveRegion: true,
                            child: Card(
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                      '已导入 · ${_importedBook!.title}',
                                      style: TextStyle(color: t.ink),
                                    ),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: <Widget>[
                                        FilledButton.icon(
                                          onPressed: _busy
                                              ? null
                                              : () => _open(_importedBook!),
                                          icon: const Icon(
                                            Icons.menu_book_outlined,
                                          ),
                                          label: const Text('开始阅读'),
                                        ),
                                        TextButton(
                                          onPressed: () {
                                            final ScaffoldMessengerState
                                            messenger = ScaffoldMessenger.of(
                                              context,
                                            );
                                            messenger.clearSnackBars();
                                            messenger.removeCurrentSnackBar();
                                            setState(
                                              () => _importedBook = null,
                                            );
                                          },
                                          child: const Text('收起提示'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (_error != null)
                  SliverPadding(
                    padding: const EdgeInsets.all(20),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            '暂时无法打开本地书库：$_error',
                            style: TextStyle(color: t.danger),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: widget.onRetryLibrary ?? _start,
                            icon: const Icon(Icons.refresh),
                            label: const Text('重试打开书库'),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (_library == null)
                  const SliverFillRemaining(
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_books.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
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
                                onPressed: _busy ? null : _import,
                                icon: const Icon(Icons.upload_file_outlined),
                                label: const Text('选择书籍或页读备份'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  )
                else ...<Widget>[
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Text(
                            '我的书架  ${books.length} / ${_books.length}',
                            style: TextStyle(fontSize: 18, color: t.ink2),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _search,
                            onChanged: (_) => setState(() {}),
                            decoration: InputDecoration(
                              labelText: '搜索书名或作者',
                              prefixIcon: const Icon(Icons.search),
                              suffixIcon: query.isEmpty
                                  ? null
                                  : IconButton(
                                      tooltip: '清空书架搜索',
                                      onPressed: () {
                                        _search.clear();
                                        setState(() {});
                                      },
                                      icon: const Icon(Icons.close),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: <Widget>[
                              for (final (String value, String label)
                                  in const <(String, String)>[
                                    ('all', '全部'),
                                    ('reading', '在读'),
                                    ('unread', '未读'),
                                    ('finished', '读完'),
                                  ])
                                ChoiceChip(
                                  label: Text(label),
                                  selected: _filter == value,
                                  onSelected: (_) =>
                                      setState(() => _filter = value),
                                ),
                              PopupMenuButton<String>(
                                tooltip: '书架排序',
                                initialValue: _sort,
                                onSelected: (String value) =>
                                    setState(() => _sort = value),
                                itemBuilder: (_) =>
                                    const <PopupMenuEntry<String>>[
                                      PopupMenuItem(
                                        value: 'recent',
                                        child: Text('最近阅读'),
                                      ),
                                      PopupMenuItem(
                                        value: 'added',
                                        child: Text('最近导入'),
                                      ),
                                      PopupMenuItem(
                                        value: 'title',
                                        child: Text('书名排序'),
                                      ),
                                    ],
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      Text(switch (_sort) {
                                        'title' => '书名排序',
                                        'added' => '最近导入',
                                        _ => '最近阅读',
                                      }),
                                      const SizedBox(width: 4),
                                      const Icon(
                                        Icons.arrow_drop_down,
                                        size: 18,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (books.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          children: <Widget>[
                            const Text('没有符合条件的书籍'),
                            TextButton(
                              onPressed: _resetFilters,
                              child: const Text('显示全部书籍'),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                      sliver: SliverLayoutBuilder(
                        builder:
                            (
                              BuildContext context,
                              SliverConstraints constraints,
                            ) {
                              final int columns =
                                  constraints.crossAxisExtent < 720 ? 1 : 2;
                              return SliverList.separated(
                                itemCount: (books.length / columns).ceil(),
                                separatorBuilder: (_, index) =>
                                    const SizedBox(height: 14),
                                itemBuilder: (BuildContext context, int row) => Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    for (
                                      int column = 0;
                                      column < columns;
                                      column++
                                    ) ...<Widget>[
                                      if (column > 0) const SizedBox(width: 14),
                                      Expanded(
                                        child:
                                            row * columns + column >=
                                                books.length
                                            ? const SizedBox.shrink()
                                            : _ShelfBookCard(
                                                book:
                                                    books[row * columns +
                                                        column],
                                                state:
                                                    _states[books[row *
                                                                columns +
                                                            column]
                                                        .id] ??
                                                    WebReadingState(),
                                                preparation:
                                                    _preparations[books[row *
                                                                columns +
                                                            column]
                                                        .id],
                                                preparationInvalid:
                                                    _invalidPreparations
                                                        .contains(
                                                          books[row * columns +
                                                                  column]
                                                              .id,
                                                        ),
                                                onOpen: () => _open(
                                                  books[row * columns + column],
                                                ),
                                                onPrepare: () => _openAi(
                                                  books[row * columns + column],
                                                ),
                                                onMenu: () => _bookMenu(
                                                  books[row * columns + column],
                                                ),
                                              ),
                                      ),
                                    ],
                                  ],
                                ),
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
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final bool compact = box.maxWidth < 400;
        return Material(
          color: t.sheet,
          borderRadius: BorderRadius.circular(18),
          child: InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: onOpen,
            child: Padding(
              padding: EdgeInsets.all(compact ? 14 : 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _WebCover(
                        title: book.title,
                        id: book.id,
                        compact: compact,
                      ),
                      SizedBox(width: compact ? 12 : 18),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              book.title,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: t.ink,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              book.author.isEmpty
                                  ? '${book.chapters} 章'
                                  : book.author,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: t.ink2),
                            ),
                            const SizedBox(height: 18),
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
                              const SizedBox(height: 5),
                              Text(
                                preparationInvalid
                                    ? '整理记录无法读取 · 点人物查看并清除'
                                    : '人物整理 $prepared/$total 片 · $aiStatus',
                                style: TextStyle(fontSize: 11, color: t.ink2),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    alignment: WrapAlignment.end,
                    children: <Widget>[
                      TextButton.icon(
                        onPressed: onOpen,
                        icon: const Icon(Icons.menu_book_outlined, size: 18),
                        label: const Text('继续阅读'),
                      ),
                      IconButton(
                        tooltip: '整理《${book.title}》的人物与前情',
                        onPressed: onPrepare,
                        icon: const Icon(Icons.auto_awesome_outlined),
                      ),
                      IconButton(
                        tooltip: '《${book.title}》书籍选项',
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
      },
    );
  }
}

