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
    show HardwareKeyboard, KeyEvent, KeyUpEvent, LogicalKeyboardKey;
import 'package:thusfar_core/thusfar_core.dart' as knowledge;
import 'package:thusfar_core/chapter_verdicts.dart' show titleCheckPending;

import '../data/library_zip.dart';
import '../data/restore_report.dart';
import '../data/shelf_organization.dart';
import '../data/reading_activity.dart';
import '../screens/reading_activity_screen.dart';
import '../reading/read_aloud.dart';
import '../reading/auto_page_turner.dart';
import '../ui/restore_report_view.dart';
import '../ui/theme.dart';
import '../ui/workspace_navigation.dart';
import 'web_notes_center.dart';
import 'web_activity_route.dart';
import '../reader/image_viewer.dart';
import '../reader/source_selection.dart';
import 'reading_boundary.dart';
import 'web_ai_panel.dart';
import 'web_ai_engine.dart';
import 'web_ask_panel.dart';
import 'web_model_session.dart';
import 'web_storage.dart';
import 'web_reader_search.dart';
import 'web_recovery_page.dart';
import 'webdav_sync.dart';

const double _wideShelf = 1140;

double _savedBookProgress(WebBookMeta book, WebReadingState state) {
  if (state.sourceOffset != null && book.length > 0) {
    return (state.sourceOffset! / book.length).clamp(0.0, 1.0);
  }
  return book.chapters <= 0
      ? 0
      : ((state.chapter + state.fraction) / book.chapters).clamp(0.0, 1.0);
}

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
  bool _listView = false;
  int _tab = 0;
  ShelfOrganization _organization = ShelfOrganization();
  ShelfOrganization _savedOrganization = ShelfOrganization();
  String _collection = 'all';
  WebBookMeta? _importedBook;
  bool _offline = html.window.navigator.onLine == false;
  StreamSubscription<html.Event>? _onlineSubscription;
  StreamSubscription<html.Event>? _offlineSubscription;

  @override
  void initState() {
    super.initState();
    try {
      final raw = html.window.localStorage['thusfar-web-shelf-prefs'];
      final saved = raw == null ? null : jsonDecode(raw);
      if (saved is Map) {
        _sort =
            const [
              'recent',
              'progress',
              'title',
              'added',
            ].contains(saved['sort'])
            ? saved['sort'] as String
            : 'recent';
        _listView = saved['list'] == true;
      }
    } on Object {
      /* Use the default view if optional preferences are damaged. */
    }
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
    } on Object {
      if (mounted && source == widget.library) {
        setState(() => _error = '暂时无法读取书库，请检查浏览器剩余空间后重试。');
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
    try {
      _organization = WebLibrary.shelfOrganization();
      _savedOrganization = ShelfOrganization.fromJson(_organization.toJson());
    } on Object {
      _message('书架分类暂时无法读取，请先导出备份。');
    }

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
            content: SingleChildScrollView(
              child: Text(
                '${archive.books.map((bytes) => '• ${BackupSummary.read(bytes).title}').join('\n')}\n\n这份 ZIP 含 ${archive.books.length} 本书。相同书籍会安全合并；冲突不会覆盖本地。'
                '服务密钥需要重新填写，请妥善保管备份。'
                '已有书籍会保留当前的整理和付费设置。'
                '${archive.customizations == null ? '' : '使用备份设置也会保留整库净化规则及其顺序供安装版使用；网页版只保留这些自定义，不应用净化或修正目录。'}'
                '是否同时使用备份里的阅读清单、排版和模型设置？',
              ),
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
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              duration: const Duration(seconds: 10),
              content: Text(
                '${restored.report.summary}。${restored.reportError ?? '完整结果已保存，可从回收站与恢复报告查看。'}',
              ),
              action: SnackBarAction(
                label: '查看报告',
                onPressed: () {
                  if (!mounted) return;
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          RestoreReportView(report: restored.report),
                    ),
                  );
                },
              ),
            ),
          );
        }
        return;
      } else if (file.name.toLowerCase().endsWith('.json')) {
        final BackupSummary summary = BackupSummary.read(bytes);
        if (summary.customizationSummary != null) {
          await library.importBackup(bytes, previewOnly: true);
          if (!mounted) return;
          final bool? confirmed = await showDialog<bool>(
            context: context,
            builder: (BuildContext dialogContext) => AlertDialog(
              title: const Text('保留安装版阅读自定义'),
              content: SingleChildScrollView(
                child: Text(
                  '${summary.title}\n\n网页版只保留净化规则和修正目录，不应用到正文或导航。'
                  '已有自定义冲突时会停止导入。\n\n'
                  '导回安装版时：${summary.customizationSummary}',
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('导入并保留'),
                ),
              ],
            ),
          );
          if (confirmed != true) return;
        }
        final String id = await library.importBackup(bytes);
        final WebBook? imported = await library.load(id);
        _importedBook = imported?.meta;
      } else {
        _importedBook = await library.importFile(file.name, bytes);
      }
      await _refresh();
      if (mounted) {
        _search.clear();
        setState(() {
          _filter = 'all';
          _collection = 'all';
        });
      }
      if (_importedBook == null) {
        _message('已导入到此浏览器的本地书库');
      }
    } on Object {
      if (zipRestoreStarted) {
        try {
          await _refresh();
        } on Object {
          // The original restore error remains the actionable message.
        }
      }
      _message('无法导入，请检查文件是否完整及浏览器剩余空间。');
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
      _message('书库备份已下载。服务密钥需要重新填写，请妥善保管备份。');
    } on Object {
      _message('书库未能导出，请检查浏览器剩余空间后重试。');
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
    } on Object {
      _message('暂时无法打开这本书，请重试。');
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
          builder: (_) => WebAiPanel(
            book: book,
            reading: reading,
            library: library,
            readingBuilder: (_, _) =>
                WebReader(book: book, state: reading, library: library),
          ),
        ),
      );
      await _refresh();
    } on Object {
      _message('暂时无法打开整理页面，请重试。');
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
    } on Object {
      _message('暂时无法打开云端备份，请重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openRecovery() async {
    final WebLibrary? library = _library;
    if (library == null || _busy) return;
    setState(() => _busy = true);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => WebRecoveryPage(library: library),
        ),
      );
      await _refresh();
    } on Object {
      _message('暂时无法打开恢复记录，请重试。');
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
                title: const Text('智能梳理'),
                onTap: () => Navigator.pop(context, 'prepare'),
              ),
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('移入分类'),
                onTap: () => Navigator.pop(context, 'collection'),
              ),
              ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: Text(_isFinished(book) ? '标为重读' : '标记读完'),
                subtitle: const Text('不改变阅读位置与人物资料范围'),
                onTap: () => Navigator.pop(context, 'finished'),
              ),
              ListTile(
                leading: const Icon(Icons.bookmark_add_outlined),
                title: Text(
                  WebLibrary.readingQueue().contains(book.id) ? '移出在读' : '加入在读',
                ),
                onTap: () => Navigator.pop(context, 'queue'),
              ),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('导出本书'),
                onTap: () => Navigator.pop(context, 'export'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('移到回收站'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == 'collection') {
      await _chooseCollection(book);
    } else if (choice == 'finished') {
      _organization.books[book.id] = ShelfBookState(
        collection: _organization.books[book.id]?.collection,
        finished: !_isFinished(book),
      );
      _saveOrganization();
    } else if (choice == 'queue') {
      try {
        WebLibrary.setInReadingQueue(
          book.id,
          !WebLibrary.readingQueue().contains(book.id),
        );
        if (mounted) setState(() {});
      } on Object {
        _message('在读清单未能保存，请重试。');
      }
    } else if (choice == 'prepare') {
      await _openAi(book);
    } else if (choice == 'export') {
      try {
        await library.exportBackup(book.id);
      } on Object {
        _message('未能导出，请检查浏览器剩余空间后重试。');
      }
    } else if (choice == 'remove' && mounted) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('移到回收站？'),
          content: const Text('书籍与阅读记录会保留，可从设置中的回收站恢复。仍占用浏览器空间。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('移到回收站'),
            ),
          ],
        ),
      );
      if (confirmed == true && mounted) {
        setState(() => _busy = true);
        try {
          await library.remove(book.id);
          if (_importedBook?.id == book.id) _importedBook = null;
          await _refresh();
          _message('已移到回收站，书籍和阅读记录可恢复');
        } on Object {
          _message('未能移到回收站，请重试。');
        } finally {
          if (mounted) setState(() => _busy = false);
        }
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
    if (state == null) return 0;
    return _savedBookProgress(book, state);
  }

  bool _isFinished(WebBookMeta book) =>
      _organization.books[book.id]?.finished ?? _bookProgress(book) >= .995;

  bool _matchesFilter(WebBookMeta book) {
    if (_collection != 'all' &&
        (_organization.books[book.id]?.collection ?? '') != _collection) {
      return false;
    }
    final double progress = _bookProgress(book);
    return switch (_filter) {
      'unread' => progress == 0 && !_isFinished(book),
      'reading' => progress > 0 && !_isFinished(book),
      'finished' => _isFinished(book),
      _ => true,
    };
  }

  void _resetFilters() {
    _search.clear();
    setState(() => _filter = 'all');
  }

  void _saveOrganization() {
    try {
      WebLibrary.saveShelfOrganization(_organization);
      _savedOrganization = ShelfOrganization.fromJson(_organization.toJson());
      if (mounted) setState(() {});
    } on Object {
      _organization = ShelfOrganization.fromJson(_savedOrganization.toJson());
      if (_collection != 'all' &&
          !_organization.collections.contains(_collection)) {
        _collection = 'all';
      }
      if (mounted) setState(() {});
      _message('分类未能保存，请检查浏览器剩余空间。');
    }
  }

  Future<String?> _collectionName({String? current}) async {
    if (current == null && _organization.collections.length >= 100) {
      _message('最多可建立 100 个分类。');
      return null;
    }
    final input = TextEditingController(text: current ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(current == null ? '新建分类' : '分类改名'),
        content: TextField(
          controller: input,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(labelText: '分类名称'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, input.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    input.dispose();
    if (result == null || result.isEmpty || result == current) return null;
    if (_organization.collections.contains(result)) {
      _message('已有同名分类。');
      return null;
    }
    return result;
  }

  Future<void> _chooseCollection(WebBookMeta book) async {
    final String? result = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            const ListTile(title: Text('移入分类')),
            ListTile(
              title: const Text('未分类'),
              onTap: () => Navigator.pop(context, ''),
            ),
            for (final name in _organization.collections)
              ListTile(
                title: Text(name),
                onTap: () => Navigator.pop(context, name),
              ),
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('新建分类'),
              onTap: () => Navigator.pop(context, '__new__'),
            ),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    String? name = result;
    if (result == '__new__') {
      name = await _collectionName();
      if (name == null) return;
      _organization.collections.add(name);
    }
    _organization.books[book.id] = ShelfBookState(
      collection: name.isEmpty ? null : name,
      finished: _organization.books[book.id]?.finished,
    );
    _saveOrganization();
  }

  void _manageCollections() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: StatefulBuilder(
          builder: (context, update) => ListView(
            shrinkWrap: true,
            children: <Widget>[
              ListTile(
                title: const Text('管理分类'),
                trailing: IconButton(
                  tooltip: '关闭分类',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(sheetContext),
                ),
              ),
              for (final name in List<String>.of(_organization.collections))
                ListTile(
                  title: Text(name),
                  trailing: Wrap(
                    children: <Widget>[
                      IconButton(
                        tooltip: '改名',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () async {
                          final next = await _collectionName(current: name);
                          if (next == null || !mounted) return;
                          _organization.collections[_organization.collections
                                  .indexOf(name)] =
                              next;
                          for (final entry
                              in _organization.books.entries.toList()) {
                            if (entry.value.collection == name) {
                              _organization.books[entry.key] = ShelfBookState(
                                collection: next,
                                finished: entry.value.finished,
                              );
                            }
                          }
                          if (_collection == name) _collection = next;
                          _saveOrganization();
                          if (context.mounted) update(() {});
                        },
                      ),
                      IconButton(
                        tooltip: '移除分类，保留书籍',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _organization.collections.remove(name);
                          for (final entry
                              in _organization.books.entries.toList()) {
                            if (entry.value.collection == name) {
                              _organization.books[entry.key] = ShelfBookState(
                                finished: entry.value.finished,
                              );
                            }
                          }
                          if (_collection == name) _collection = 'all';
                          _saveOrganization();
                          update(() {});
                        },
                      ),
                    ],
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('新建分类'),
                onTap: () async {
                  final name = await _collectionName();
                  if (name == null || !mounted) return;
                  _organization.collections.add(name);
                  _saveOrganization();
                  if (context.mounted) update(() {});
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _saveShelfPrefs() {
    try {
      html.window.localStorage['thusfar-web-shelf-prefs'] = jsonEncode({
        'sort': _sort,
        'list': _listView,
      });
    } on Object {
      _message('显示偏好未能保存，下次打开将使用默认设置。');
    }
  }

  Future<void> _openNote(WebBookMeta book, WebPersonalItem item) async {
    final WebLibrary? library = _library;
    if (library == null) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('翻回原文'),
        content: const Text('人物与前情会跟随阅读位置更新。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('留在原地'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认前往'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final WebReadingState reading = await library.state(book.id);
      reading.returnChapter = reading.chapter;
      reading.returnFraction = reading.fraction;
      reading.returnOffset = null;
      reading.chapter = item.chapter;
      reading.fraction = item.fraction;
      await library.saveState(book.id, reading);
      if (mounted) await _open(book);
    } on Object {
      _message('暂时无法打开原文，请重试。');
    }
  }

  Widget _settingsPage() => ListView(
    padding: const EdgeInsets.all(20),
    children: <Widget>[
      Text(
        '设置',
        style: TextStyle(
          fontFamily: display,
          fontSize: 32,
          color: context.tk.ink,
        ),
      ),
      const SizedBox(height: 6),
      Text('偏好与数据管理。', style: TextStyle(color: context.tk.ink2)),
      const SizedBox(height: 24),
      ListTile(
        leading: const Icon(Icons.insights_outlined),
        title: const Text('阅读记录'),
        subtitle: const Text('看看阅读时光，设定每日目标'),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ReadingActivityScreen(
              store: ReadingActivityStore.forRoot('web'),
            ),
          ),
        ),
      ),
      const SizedBox(height: 20),
      const Text('书库与备份'),
      const SizedBox(height: 8),
      ListTile(
        leading: const Icon(Icons.upload_file_outlined),
        title: const Text('导入备份'),
        subtitle: const Text('恢复书籍、进度与想法'),
        onTap: _busy ? null : _import,
      ),
      ListTile(
        leading: const Icon(Icons.archive_outlined),
        title: const Text('整库备份'),
        subtitle: const Text('把书籍和阅读记录一起带走'),
        onTap: _busy ? null : _exportLibrary,
      ),
      ListTile(
        leading: const Icon(Icons.cloud_sync_outlined),
        title: const Text('云端备份'),
        subtitle: const Text('手动保存或恢复 WebDAV 快照'),
        onTap: _busy ? null : _openWebDav,
      ),
      ListTile(
        leading: const Icon(Icons.restore_from_trash_outlined),
        title: const Text('回收站'),
        subtitle: const Text('找回移出的书与阅读记录'),
        onTap: _busy ? null : _openRecovery,
      ),
      const SizedBox(height: 24),
      const Text('阅读与隐私'),
      const SizedBox(height: 8),
      ListTile(
        leading: const Icon(Icons.format_size),
        title: const Text('排版'),
        subtitle: const Text('阅读时轻点中央，再打开排版。'),
      ),
      ListTile(
        leading: const Icon(Icons.auto_awesome_outlined),
        title: const Text('智能梳理'),
        subtitle: const Text('从本书详情选择服务并开始梳理。相关原文会发送给所选服务，可能产生费用。'),
      ),
      ListTile(
        leading: const Icon(Icons.offline_bolt_outlined),
        title: const Text('离线阅读'),
        subtitle: Text(
          _offline ? '当前离线，本地书籍仍可阅读。' : '书籍保存在此浏览器。定期备份可避免浏览器清理后丢失。',
        ),
      ),
    ],
  );

  Widget _card(WebBookMeta book, {bool tile = false}) => _ShelfBookCard(
    book: book,
    state: _states[book.id] ?? WebReadingState(),
    preparation: _preparations[book.id],
    preparationInvalid: _invalidPreparations.contains(book.id),
    onOpen: () => _open(book),
    onPrepare: () => _openAi(book),
    onMenu: () => _bookMenu(book),
    tile: tile,
  );

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final String query = _search.text.trim().toLowerCase();
    final List<WebBookMeta> books =
        _books
            .where(
              (book) =>
                  _matchesFilter(book) &&
                  (query.isEmpty ||
                      '${book.title} ${book.author}'.toLowerCase().contains(
                        query,
                      )),
            )
            .toList()
          ..sort((a, b) {
            if (_sort == 'title') return a.title.compareTo(b.title);
            if (_sort == 'added') return b.added.compareTo(a.added);
            if (_sort == 'progress') {
              return _bookProgress(b).compareTo(_bookProgress(a));
            }
            return (_states[b.id]?.lastOpened ?? b.added).compareTo(
              _states[a.id]?.lastOpened ?? a.added,
            );
          });
    final List<String> queue = WebLibrary.readingQueue();
    final List<WebBookMeta> recent =
        _books
            .where(
              (book) =>
                  queue.contains(book.id) ||
                  ((_states[book.id]?.lastOpened ?? 0) > 0 &&
                      _bookProgress(book) < .995),
            )
            .toList()
          ..sort((a, b) {
            final ai = queue.indexOf(a.id), bi = queue.indexOf(b.id);
            if (ai >= 0 || bi >= 0) {
              return (ai < 0 ? queue.length : ai).compareTo(
                bi < 0 ? queue.length : bi,
              );
            }
            return (_states[b.id]?.lastOpened ?? 0).compareTo(
              _states[a.id]?.lastOpened ?? 0,
            );
          });
    final Widget body = _tab == 1
        ? WebNotesCenter(books: _books, states: _states, onOpen: _openNote)
        : _tab == 2
        ? _settingsPage()
        : CustomScrollView(
            slivers: <Widget>[
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              '页读',
                              style: TextStyle(
                                fontFamily: display,
                                fontSize: 36,
                                color: t.ink,
                              ),
                            ),
                          ),
                          FilledButton.icon(
                            onPressed: _busy || _library == null
                                ? null
                                : _import,
                            icon: const Icon(Icons.add),
                            label: const Text('添书'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text('翻到哪页，就懂到哪页。', style: TextStyle(color: t.ink2)),
                      if (_busy)
                        const Padding(
                          padding: EdgeInsets.only(top: 16),
                          child: LinearProgressIndicator(),
                        ),
                      if (_offline)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            '当前离线，可继续读书。',
                            style: TextStyle(color: t.ink2, fontSize: 12),
                          ),
                        ),
                      if (_importedBook != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Card(
                            child: ListTile(
                              title: Text('已添入 · ${_importedBook!.title}'),
                              subtitle: const Text('轻点开始阅读。'),
                              onTap: () => _open(_importedBook!),
                              trailing: IconButton(
                                tooltip: '收起提示',
                                icon: const Icon(Icons.close),
                                onPressed: () =>
                                    setState(() => _importedBook = null),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (_error != null)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Text('暂时无法打开书库，请重试。'),
                        TextButton(
                          onPressed: widget.onRetryLibrary ?? _start,
                          child: const Text('重新打开'),
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
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(
                            Icons.auto_stories_outlined,
                            size: 64,
                            color: t.qing,
                          ),
                          const SizedBox(height: 20),
                          Text(
                            '书架空空',
                            style: TextStyle(
                              fontFamily: serif,
                              fontSize: 26,
                              color: t.ink,
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            '放几本好书进来。支持 TXT 与 EPUB。',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 20),
                          FilledButton.icon(
                            onPressed: _busy ? null : _import,
                            icon: const Icon(Icons.add),
                            label: const Text('添加书籍'),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else ...<Widget>[
                if (query.isEmpty && _filter == 'all' && recent.isNotEmpty)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                    sliver: SliverToBoxAdapter(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Expanded(
                                child: Text(
                                  '在读清单',
                                  style: TextStyle(
                                    fontFamily: serif,
                                    fontSize: 21,
                                    color: t.ink,
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: () => _readingQueueSheet(recent),
                                child: const Text('查看全部'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          _card(recent.first),
                        ],
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          '全部藏书',
                          style: TextStyle(
                            fontFamily: serif,
                            fontSize: 23,
                            color: t.ink,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '共 ${_books.length} 本好书。',
                          style: TextStyle(color: t.ink2, fontSize: 12),
                        ),
                        const SizedBox(height: 16),
                        TextField(
                          controller: _search,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            labelText: '搜书',
                            hintText: '搜索书名或作者。',
                            prefixIcon: const Icon(Icons.search),
                            suffixIcon: query.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: '清空书架搜索',
                                    icon: const Icon(Icons.close),
                                    onPressed: () {
                                      _search.clear();
                                      setState(() {});
                                    },
                                  ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
                            for (final (value, label) in const [
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
                              tooltip: '书架分类',
                              onSelected: (value) {
                                if (value == 'manage') {
                                  _manageCollections();
                                } else {
                                  setState(() => _collection = value);
                                }
                              },
                              itemBuilder: (_) => <PopupMenuEntry<String>>[
                                const PopupMenuItem(
                                  value: 'all',
                                  child: Text('全部分类'),
                                ),
                                const PopupMenuItem(
                                  value: '',
                                  child: Text('未分类'),
                                ),
                                for (final name in _organization.collections)
                                  PopupMenuItem(value: name, child: Text(name)),
                                const PopupMenuItem(
                                  value: 'manage',
                                  child: Text('管理分类'),
                                ),
                              ],
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text(
                                  _collection == 'all'
                                      ? '分类'
                                      : _collection.isEmpty
                                      ? '未分类'
                                      : _collection,
                                ),
                              ),
                            ),
                            PopupMenuButton<String>(
                              tooltip: '排序方式',
                              initialValue: _sort,
                              onSelected: (value) {
                                setState(() => _sort = value);
                                _saveShelfPrefs();
                              },
                              itemBuilder: (_) =>
                                  const <PopupMenuEntry<String>>[
                                    PopupMenuItem(
                                      value: 'recent',
                                      child: Text('最近翻开'),
                                    ),
                                    PopupMenuItem(
                                      value: 'progress',
                                      child: Text('阅读进度'),
                                    ),
                                    PopupMenuItem(
                                      value: 'title',
                                      child: Text('书名先后'),
                                    ),
                                    PopupMenuItem(
                                      value: 'added',
                                      child: Text('最近添入'),
                                    ),
                                  ],
                              icon: const Icon(Icons.sort),
                            ),
                            IconButton(
                              tooltip: _listView ? '平铺' : '列表',
                              onPressed: () {
                                setState(() => _listView = !_listView);
                                _saveShelfPrefs();
                              },
                              icon: Icon(
                                _listView
                                    ? Icons.grid_view
                                    : Icons.view_list_outlined,
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
                          Text(query.isEmpty ? '这个分类还没有书。' : '没有找到这本书。'),
                          TextButton(
                            onPressed: _resetFilters,
                            child: const Text('查看全部'),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                    sliver: SliverLayoutBuilder(
                      builder: (context, constraints) {
                        final int columns = _listView
                            ? 1
                            : (constraints.crossAxisExtent / 170).floor().clamp(
                                1,
                                5,
                              );
                        return SliverList.separated(
                          itemCount: (books.length / columns).ceil(),
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 16),
                          itemBuilder: (context, row) => Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              for (
                                int column = 0;
                                column < columns;
                                column++
                              ) ...<Widget>[
                                if (column > 0) const SizedBox(width: 14),
                                Expanded(
                                  child: row * columns + column >= books.length
                                      ? const SizedBox.shrink()
                                      : _card(
                                          books[row * columns + column],
                                          tile: !_listView,
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
            ],
          );
    return Scaffold(
      backgroundColor: t.paper,
      body: SafeArea(
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _wideShelf),
            child: body,
          ),
        ),
      ),
      bottomNavigationBar: WorkspaceNavigation(
        selectedIndex: _tab,
        onSelected: (value) {
          FocusScope.of(context).unfocus();
          setState(() => _tab = value);
        },
      ),
    );
  }

  void _readingQueueSheet(List<WebBookMeta> books) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .7,
          child: Column(
            children: <Widget>[
              ListTile(
                title: const Text('在读清单'),
                trailing: IconButton(
                  tooltip: '关闭在读清单',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(sheetContext),
                ),
              ),
              Expanded(
                child: ListView(
                  children: <Widget>[
                    for (final book in books)
                      ListTile(
                        title: Text(book.title),
                        subtitle: Text(
                          '已读 ${(_bookProgress(book) * 100).round()}%',
                        ),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          _open(book);
                        },
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
    this.tile = false,
  });
  final WebBookMeta book;
  final WebReadingState state;
  final Json? preparation;
  final bool preparationInvalid;
  final VoidCallback onOpen, onPrepare, onMenu;
  final bool tile;

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final double pct = _savedBookProgress(book, state) * 100;
    final int prepared =
        (preparation?['completed_count'] as num?)?.toInt() ?? 0;
    final int total = (preparation?['target_count'] as num?)?.toInt() ?? 0;
    final String status = preparationInvalid
        ? '梳理受阻'
        : switch (preparation?['phase']) {
            'complete' => '梳理完成',
            'error' => '梳理受阻',
            'running' => '正在梳理',
            _ => '梳理暂停',
          };
    final Widget details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          book.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: serif,
            fontSize: 18,
            height: 1.4,
            color: t.ink,
          ),
        ),
        const SizedBox(height: 5),
        Text(
          book.author.isEmpty ? '佚名' : book.author,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: t.ink2, fontSize: 12),
        ),
        const SizedBox(height: 14),
        LinearProgressIndicator(
          value: pct / 100,
          minHeight: 3,
          backgroundColor: t.rule,
          color: t.qing,
          borderRadius: BorderRadius.circular(3),
        ),
        const SizedBox(height: 8),
        Text(
          '已读 ${pct.round()}%，共 ${book.chapters} 章。',
          style: TextStyle(color: t.ink2, fontSize: 12),
        ),
        if (total > 0 || preparationInvalid)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: InkWell(
              onTap: onPrepare,
              borderRadius: BorderRadius.circular(20),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  '$status${total > 0 && status == '正在梳理' ? ' · ${(prepared / total * 100).round()}%' : ''}',
                  style: TextStyle(
                    color: preparationInvalid || status == '梳理受阻'
                        ? t.amber
                        : t.qing,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    return Material(
      color: t.sheet,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (tile) ...<Widget>[
                Stack(
                  children: <Widget>[
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 20),
                        child: _WebCover(title: book.title, id: book.id),
                      ),
                    ),
                    Align(
                      alignment: Alignment.topRight,
                      child: IconButton(
                        tooltip: '《${book.title}》本书详情',
                        onPressed: onMenu,
                        icon: const Icon(Icons.more_horiz),
                      ),
                    ),
                  ],
                ),
                details,
              ] else ...<Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _WebCover(title: book.title, id: book.id, compact: true),
                    const SizedBox(width: 16),
                    Expanded(child: details),
                    IconButton(
                      tooltip: '《${book.title}》本书详情',
                      onPressed: onMenu,
                      icon: const Icon(Icons.more_horiz),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _WebCover extends StatelessWidget {
  const _WebCover({
    required this.title,
    required this.id,
    this.compact = false,
  });

  final String title;
  final String id;
  final bool compact;

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
      width: compact ? 72 : 100,
      height: compact ? 104 : 138,
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
    this.sourceStart = 0,
    this.sourceEnd = 0,
  });

  final int block;
  final String kind;
  final int startLine;
  final int lines;
  final double height;
  final String text;

  /// Offsets in the original block, excluding the reader's visual indent.
  final int sourceStart;
  final int sourceEnd;
}

class _WebPersonMention {
  const _WebPersonMention(this.start, this.end, this.id);

  final int start;
  final int end;
  final String id;
}

class _WebPersonLink {
  const _WebPersonLink(this.start, this.end, this.name, this.id);

  final int start;
  final int end;
  final String name;
  final String? id;
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
      columnWidth = ((json['columnWidth'] as num?)?.toDouble() ?? 640).clamp(
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
  double columnWidth = 640;
  int paper = 0;
  int font = 0;
  bool pageMode = true;

  Color get paperColor => Tokens.paperColors[paper].$2;
  bool get dark => paper == Tokens.paperColors.length - 1;
  Color get ink => dark ? Tokens.night.ink : Tokens.light.ink;
  Color get muted => dark ? Tokens.night.ink2 : Tokens.light.ink2;
  String get family =>
      const <String>['NotoSerifSC', 'LXGWWenKaiScreen', 'NotoSansSC'][font];

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

class _WebReaderState extends State<WebReader>
    with WidgetsBindingObserver, RouteAware {
  final ReadAloudController _speech = ReadAloudController();
  final AutoPageTurner _autoPage = AutoPageTurner();
  late final ReadingActivitySession _activity;
  int? _speechCutoff;
  bool _foreground = true;
  bool _covered = false;
  ModalRoute<dynamic>? _activityRoute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _activityRoute) {
      webReadingRoutes.unsubscribe(this);
      _activityRoute = route;
      if (route != null) webReadingRoutes.subscribe(this, route);
    }
  }

  @override
  void didPushNext() {
    _covered = true;
    _activity.setActive(false);
    _autoPage.stop();
  }

  @override
  void didPopNext() {
    _covered = false;
    _activity.setActive(_foreground);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _activity.setActive(_foreground && !_covered);
  }

  void _stopListening() {
    if (_speech.hasSession) unawaited(_speech.stop());
    _speechCutoff = null;
  }

  Future<void> _listen() async {
    _autoPage.stop();
    final int start =
        _speechCutoff ??
        _readingSourceOffset() ??
        (_current['o0'] as num).toInt();
    final int first = (_current['b0'] as num).toInt();
    final int last = (_current['b1'] as num).toInt();
    final List<ReadAloudPassage> passages = <ReadAloudPassage>[];
    for (int i = first; i < last; i++) {
      final block = _blocks[i];
      if (block['k'] == 'img') continue;
      final String text = '${block['t'] ?? ''}';
      final int origin = (block['o'] as num).toInt();
      if (origin + text.length <= start) continue;
      final int from = math.max(0, start - origin);
      passages.add(
        ReadAloudPassage(text: text.substring(from), start: origin + from),
      );
    }
    await openReadAloud(
      context,
      _speech,
      passages: passages,
      onProgress: (heard) {
        if (!mounted) return;
        _activity.touch();
        setState(() {
          _speechCutoff = heard;
          if (_prefs.pageMode) {
            final int page = _pages.indexWhere(
              (fragments) => fragments.any((fragment) {
                if (fragment.block < 0 ||
                    fragment.kind == 'space' ||
                    fragment.kind == 'img') {
                  return false;
                }
                final int origin = (_blocks[fragment.block]['o'] as num)
                    .toInt();
                return heard > origin + fragment.sourceStart &&
                    heard <= origin + fragment.sourceEnd;
              }),
            );
            if (page >= 0 && page != _pageIndex) {
              _pageIndex = page;
              _reflowAnchor = null;
            }
            widget.state.fraction = _fraction;
          }
        });
        if (!_prefs.pageMode) {
          final int index = _blocks.indexWhere((block) {
            final int origin = (block['o'] as num).toInt();
            return heard > origin &&
                heard <= origin + '${block['t'] ?? ''}'.length;
          });
          final BuildContext? target = _blockKeys[index]?.currentContext;
          final RenderParagraph? paragraph = index < 0
              ? null
              : _sourceParagraph(index);
          if (paragraph != null && paragraph.hasSize && _scroll.hasClients) {
            final Json block = _blocks[index];
            final int offset = (heard - (block['o'] as num).toInt()).clamp(
              0,
              '${block['t'] ?? ''}'.length,
            );
            final Offset caret = paragraph.getOffsetForCaret(
              TextPosition(offset: offset + (block['k'] == 'p' ? 2 : 0)),
              Rect.zero,
            );
            final double y = paragraph.localToGlobal(caret).dy;
            final double top = MediaQuery.paddingOf(context).top + 70;
            final double bottom = _readerVisibleBottom();
            if (y < top || y + _prefs.fontSize * _prefs.lineHeight > bottom) {
              unawaited(
                _scroll.animateTo(
                  (_scroll.offset + y - top).clamp(
                    0.0,
                    _scroll.position.maxScrollExtent,
                  ),
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                ),
              );
            }
          } else if (target != null) {
            unawaited(
              Scrollable.ensureVisible(
                target,
                alignment: .15,
                duration: const Duration(milliseconds: 180),
              ),
            );
          }
        }
        _queueSave();
      },
    );
  }

  Future<void> _automaticReading() async {
    _stopListening();
    await openAutoPageTurner(
      context,
      _autoPage,
      nextPage: () {
        if (!mounted || _covered || !_foreground || _restoring) return false;
        if (_prefs.pageMode) {
          if (_pageIndex >= _pages.length - 1 &&
              _chapter >= _chapters.length - 1) {
            return false;
          }
          _turnPage(1, automatic: true);
        } else {
          if (!_scroll.hasClients) return false;
          final double next =
              _scroll.offset + _scroll.position.viewportDimension * .8;
          if (_scroll.offset >= _scroll.position.maxScrollExtent) {
            if (_chapter >= _chapters.length - 1) return false;
            _go(_chapter + 1, keepAuto: true);
          } else {
            _scroll.animateTo(
              math.min(next, _scroll.position.maxScrollExtent),
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOut,
            );
          }
        }
        return true;
      },
    );
  }

  void _readerDetails() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            _sheetHeader(sheetContext, '本书详情'),
            Text(
              widget.book.meta.title,
              style: TextStyle(
                fontFamily: serif,
                fontSize: 24,
                color: context.tk.ink,
              ),
            ),
            if (widget.book.meta.author.isNotEmpty)
              Text(widget.book.meta.author),
            const SizedBox(height: 8),
            Text('已读 ${(_progress * 100).round()}%，共 ${_chapters.length} 章。'),
            ListTile(
              leading: const Icon(Icons.slow_motion_video_outlined),
              title: const Text('自动翻页'),
              subtitle: const Text('按阅读节奏逐页前进'),
              onTap: () {
                Navigator.pop(sheetContext);
                _automaticReading();
              },
            ),
            ListTile(
              leading: const Icon(Icons.headphones_outlined),
              title: const Text('听书'),
              subtitle: const Text('从当前位置听到本章末尾'),
              onTap: () {
                Navigator.pop(sheetContext);
                _listen();
              },
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('智能梳理'),
              subtitle: const Text('人物小传与关系脉络'),
              onTap: () {
                Navigator.pop(sheetContext);
                _openReaderPanel(
                  (reading) => WebAiPanel(
                    book: widget.book,
                    reading: reading,
                    library: widget.library,
                    cutoffOffset: _visibleCutoffOffset(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.bookmark_outline),
              title: const Text('书签'),
              onTap: () {
                Navigator.pop(sheetContext);
                _bookmarksSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_note_outlined),
              title: const Text('想法'),
              onTap: () {
                Navigator.pop(sheetContext);
                _notesSheet();
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('导出本书'),
              subtitle: const Text('包含进度与想法的完整单书'),
              onTap: () async {
                Navigator.pop(sheetContext);
                try {
                  await widget.library.exportBackup(widget.book.meta.id);
                } on Object {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('导出未完成，请稍后重试。')),
                    );
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  static final RegExp _asciiWord = RegExp(r'[A-Za-z0-9]');
  final ScrollController _scroll = ScrollController();
  final FocusNode _readerFocus = FocusNode();
  final Map<int, GlobalKey> _blockKeys = <int, GlobalKey>{};
  final GlobalKey _bottomToolbarKey = GlobalKey();
  final WebReaderPrefs _prefs = WebReaderPrefs();
  List<List<_WebPageFragment>> _pages = const <List<_WebPageFragment>>[];
  int? _pageLayoutKey;
  int? _pageGeometryKey;
  // Keep the same source character through repeated viewport/font changes.
  // A percentage is only a fallback for an initial load or a deliberate jump.
  ({int block, int offset})? _reflowAnchor;
  int _pageIndex = 0;
  int _turnDirection = 1;
  bool _wheelLocked = false;
  Timer? _wheelTimer;
  Timer? _pageTapTimer;
  Timer? _selectionTimer;
  Timer? _selectionCaptureTimer;
  Offset? _pointerStart;
  DateTime? _pointerStarted;
  bool _pointerStartedWithSelection = false;
  Timer? _saveTimer;
  Timer? _displayTimer;
  bool _controls = false;
  bool _restoring = true;
  bool _openingPanel = false;
  int _navigationEpoch = 0;
  VoidCallback? _returnToAsk;
  String? _selectedText;
  String? _selectionActionQuote;
  Map<String, int> _draftPersonNames = const <String, int>{};
  int? _draftNamesChapter;
  List<String> _currentDraftNames = const <String>[];
  final Map<String, TapGestureRecognizer> _personRecognizers =
      <String, TapGestureRecognizer>{};
  bool _personTapConsumed = false;
  late final List<Json> _nativePersonLog = _readNativePersonLog();
  // A full graph fold for each page turn becomes expensive in long books.
  // The reader only needs to know whether an identity exists by this page;
  // the detail panel folds the graph at the same cutoff after a deliberate tap.
  late final Map<String, int> _nativePersonFirst = _readNativePersonFirst();
  late final Map<int, List<_WebPersonMention>> _nativePersonMentions =
      _readNativePersonMentions();
  ({int chapter, double fraction})? get _returnPosition {
    final int? chapter = widget.state.returnChapter;
    final double? fraction = widget.state.returnFraction;
    if (chapter == null ||
        fraction == null ||
        chapter < 0 ||
        chapter >= _chapters.length) {
      return null;
    }
    return (chapter: chapter, fraction: fraction);
  }

  set _returnPosition(({int chapter, double fraction})? value) {
    widget.state.returnChapter = value?.chapter;
    widget.state.returnFraction = value?.fraction;
    if (value == null) widget.state.returnOffset = null;
  }

  void _rememberPosition() {
    if (_returnPosition != null) return;
    _returnPosition = (chapter: _chapter, fraction: _fraction);
    widget.state.returnOffset = _readingSourceOffset();
    // Persist the return anchor before scroll-mode seeks enter their debounce.
    unawaited(widget.library.saveState(widget.book.meta.id, widget.state));
  }

  double? _seekPreview;
  late int _chapter;
  int? _jumpBlock;
  int? _jumpOffset;

  List<Json> get _chapters => widget.book.chapters;
  List<Json> get _blocks => widget.book.blocks;
  Json get _current => _chapters[_chapter];

  String _safeChapterTitle(int index) => webChapterTitle(
    _chapters,
    index,
    _chapter,
    checkPending: titleCheckPending(widget.book.nativeBackup?['status']),
  );

  @override
  void initState() {
    super.initState();
    _activity = ReadingActivityStore.forRoot(
      'web',
    ).startSession(bookId: widget.book.meta.id, title: widget.book.meta.title);
    WidgetsBinding.instance.addObserver(this);

    _chapter = widget.state.chapter.clamp(0, math.max(0, _chapters.length - 1));
    _jumpOffset = widget.state.sourceOffset;
    _scroll.addListener(_scrolled);
    unawaited(_loadPersonPreparation());
    html.window.addEventListener('keydown', _domKey, true);
    html.window.addEventListener('wheel', _domWheel, true);
    if (!_prefs.pageMode) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _restoreFraction(widget.state.fraction, epoch: 0),
      );
    }
  }

  Future<void> _loadPersonPreparation() async {
    try {
      final Json? saved = await widget.library.loadPreparation(
        widget.book.meta.id,
      );
      if (!mounted) return;
      final Object? results = saved?['results'];
      if (results is! Map || results.isEmpty) {
        setState(() {
          _draftPersonNames = const <String, int>{};
          _draftNamesChapter = null;
        });
        return;
      }
      final Map<String, WebAiChunk> chunks = <String, WebAiChunk>{
        for (final WebAiChunk chunk in WebAiEngine.chunks(widget.book))
          '${chunk.chapterIndex}:${chunk.chunkIndex}': chunk,
      };
      final Map<String, int> names = <String, int>{};
      for (final MapEntry<Object?, Object?> entry in results.entries) {
        final WebAiChunk? chunk = chunks[entry.key];
        if (chunk == null || entry.value is! Json) continue;
        final Json record = entry.value as Json;
        if (record['chapter_index'] != chunk.chapterIndex ||
            record['chunk_index'] != chunk.chunkIndex ||
            record['result'] is! Json) {
          continue;
        }
        final Object? facts = (record['result'] as Json)['character_facts'];
        if (facts is! List) continue;
        for (final Object? value in facts) {
          if (value is! Json) continue;
          final String name = '${value['name'] ?? ''}'.trim();
          final String evidence = '${value['evidence'] ?? ''}';
          if (name.runes.length < 2 ||
              name.runes.length > 24 ||
              knowledge.generic.contains(name) ||
              !evidence.contains(name) ||
              !chunk.text.contains(evidence)) {
            continue;
          }
          final int? knownAt = names[name];
          if (knownAt == null || chunk.chapterIndex < knownAt) {
            names[name] = chunk.chapterIndex;
          }
        }
      }
      setState(() {
        _draftPersonNames = names;
        _draftNamesChapter = null;
      });
    } on Object {
      // Damaged optional AI drafts never interrupt reading or native cards.
    }
  }

  List<Json> _readNativePersonLog() {
    final Object? graph = widget.book.nativeBackup?['kg'];
    final Object? raw = graph is Json ? graph['log'] : null;
    if (raw is! List) return const <Json>[];
    return <Json>[
      for (final Object? row in raw)
        if (row is Json) row,
    ];
  }

  Map<int, List<_WebPersonMention>> _readNativePersonMentions() {
    final Json? native = widget.book.nativeBackup;
    final Object? raw = native?['mentions'];
    final Object? status = native?['status'];
    if (raw is! Json || status is! Json) {
      return const <int, List<_WebPersonMention>>{};
    }
    final Object? rawFrontier = status['frontier'];
    final int frontier = rawFrontier is num ? rawFrontier.toInt() : 0;
    final Map<int, List<_WebPersonMention>> byChapter =
        <int, List<_WebPersonMention>>{};
    for (final MapEntry<String, Object?> chapter in raw.entries) {
      final int? index = int.tryParse(chapter.key);
      if (index == null ||
          index < 0 ||
          index >= _chapters.length ||
          chapter.value is! List) {
        continue;
      }
      for (final Object? value in chapter.value as List) {
        if (value is! List ||
            value.length < 3 ||
            value[0] is! num ||
            value[1] is! num ||
            value[2] is! String) {
          continue;
        }
        final int start = (value[0] as num).toInt();
        final int end = (value[1] as num).toInt();
        if (start < 0 || end <= start || end > frontier) continue;
        byChapter
            .putIfAbsent(index, () => <_WebPersonMention>[])
            .add(_WebPersonMention(start, end, value[2] as String));
      }
    }
    return byChapter;
  }

  Map<String, int> _readNativePersonFirst() {
    final Map<String, int> first = <String, int>{};
    for (final Json row in _nativePersonLog) {
      if (row['t'] != 'person' || row['id'] is! String || row['p'] is! int) {
        continue;
      }
      final String id = row['id'] as String;
      final int position = row['p'] as int;
      final int? known = first[id];
      if (known == null || position < known) first[id] = position;
    }
    return first;
  }

  List<String> _draftNamesAtCurrentChapter() {
    if (_draftNamesChapter == _chapter) return _currentDraftNames;
    _draftNamesChapter = _chapter;
    _currentDraftNames = <String>[
      for (final MapEntry<String, int> entry in _draftPersonNames.entries)
        if (entry.value < _chapter) entry.key,
    ]..sort((String a, String b) => b.length.compareTo(a.length));
    return _currentDraftNames;
  }

  /// The last original character already on the visible page. Scroll mode
  /// stops before the first paragraph that extends below the visible area.
  int _visibleCutoffOffset() {
    if (_speechCutoff != null) return _speechCutoff!;
    final int chapterStart = (_current['o0'] as num?)?.toInt() ?? 0;
    final int chapterEnd = (_current['o1'] as num?)?.toInt() ?? chapterStart;
    if (_prefs.pageMode) {
      if (_pages.isEmpty) return chapterStart;
      for (int page = _pageIndex; page >= 0; page--) {
        int cutoff = chapterStart;
        bool hasText = false;
        for (final _WebPageFragment fragment in _pages[page]) {
          if (fragment.block < 0 ||
              fragment.block >= _blocks.length ||
              fragment.kind == 'img' ||
              fragment.kind == 'space') {
            continue;
          }
          hasText = true;
          final Json block = _blocks[fragment.block];
          final int origin = (block['o'] as num?)?.toInt() ?? chapterStart;
          cutoff = math.max(cutoff, origin + fragment.sourceEnd);
        }
        if (hasText) return cutoff.clamp(chapterStart, chapterEnd);
      }
      return chapterStart;
    }
    final int first = (_current['b0'] as num?)?.toInt() ?? 0;
    final int last = (_current['b1'] as num?)?.toInt() ?? 0;
    final double visibleBottom = _readerVisibleBottom();
    for (int i = first; i < last && i < _blocks.length; i++) {
      if (i == first &&
          _blocks[i]['k'] == 'h' &&
          _blocks[i]['t'] == _current['title']) {
        continue;
      }
      final RenderObject? render = _blockKeys[i]?.currentContext
          ?.findRenderObject();
      if (render is! RenderBox || !render.hasSize) return chapterStart;
      final double bottom = render
          .localToGlobal(Offset(0, render.size.height))
          .dy;
      if (bottom > visibleBottom) {
        return ((_blocks[i]['o'] as num?)?.toInt() ?? chapterStart).clamp(
          chapterStart,
          chapterEnd,
        );
      }
    }
    return chapterEnd;
  }

  double _readerVisibleBottom() {
    final RenderObject? toolbar = _bottomToolbarKey.currentContext
        ?.findRenderObject();
    if (_controls && toolbar is RenderBox && toolbar.hasSize) {
      return toolbar.localToGlobal(Offset.zero).dy;
    }
    return MediaQuery.sizeOf(context).height -
        MediaQuery.paddingOf(context).bottom -
        70;
  }

  int _savedSourceOffset() {
    final int start = (_current['o0'] as num).toInt();
    final int end = (_current['o1'] as num).toInt();
    if (_speechCutoff != null) return _speechCutoff!.clamp(start, end);
    if (_fraction >= 1) return end;
    return (_readingSourceOffset() ?? start).clamp(start, end);
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
    if (_chapters.isNotEmpty && !_restoring) {
      widget.state.sourceOffset = _savedSourceOffset();
    }
    _saveTimer?.cancel();
    if (_prefs.pageMode) {
      // Page turns are discrete actions. Publish the position immediately so
      // browser Back or a reload cannot lose the last turn to the debounce.
      unawaited(widget.library.saveState(widget.book.meta.id, widget.state));
      return;
    }
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(widget.library.saveState(widget.book.meta.id, widget.state));
    });
  }

  int? _readingSourceOffset() {
    if (_prefs.pageMode) {
      final anchor = _pageSourceAnchor();
      return anchor == null || anchor.block < 0
          ? null
          : (_blocks[anchor.block]['o'] as num).toInt() + anchor.offset;
    }
    final List<SourceSlice> slices = _visibleSourceSlices();
    return slices.isEmpty ? null : slices.first.start;
  }

  RenderParagraph? _sourceParagraph(int block) {
    final RenderObject? root = _blockKeys[block]?.currentContext
        ?.findRenderObject();
    RenderParagraph? result;
    void visit(RenderObject node) {
      if (node is RenderParagraph) {
        result ??= node;
      } else {
        node.visitChildren(visit);
      }
    }

    if (root != null) visit(root);
    return result;
  }

  Future<void> _restoreFraction(double fraction, {required int epoch}) async {
    if (!mounted || epoch != _navigationEpoch) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        epoch != _navigationEpoch ||
        !_scroll.hasClients ||
        _prefs.pageMode) {
      return;
    }
    final int? source = _jumpOffset;
    int? block = _jumpBlock;
    if (source != null) {
      final int found = _blocks.lastIndexWhere(
        (Json raw) => ((raw['o'] as num?)?.toInt() ?? 0) <= source,
      );
      if (found >= 0) block = found;
    }
    final RenderParagraph? paragraph = block == null
        ? null
        : _sourceParagraph(block);
    if (source != null &&
        block != null &&
        paragraph != null &&
        paragraph.hasSize) {
      final Json raw = _blocks[block];
      final int offset = (source - (raw['o'] as num).toInt()).clamp(
        0,
        '${raw['t'] ?? ''}'.length,
      );
      final Offset caret = paragraph.getOffsetForCaret(
        TextPosition(offset: offset + (raw['k'] == 'p' ? 2 : 0)),
        Rect.zero,
      );
      final double top = MediaQuery.paddingOf(context).top + 58;
      _scroll.jumpTo(
        (_scroll.offset + paragraph.localToGlobal(caret).dy - top).clamp(
          0.0,
          _scroll.position.maxScrollExtent,
        ),
      );
    } else {
      final BuildContext? target = block == null
          ? null
          : _blockKeys[block]?.currentContext;
      if (target != null && target.mounted) {
        // Instant positioning cannot keep animating after a newer navigation.
        await Scrollable.ensureVisible(target, alignment: 0.12);
      } else {
        _scroll.jumpTo(
          (_scroll.position.maxScrollExtent * fraction).clamp(
            0.0,
            _scroll.position.maxScrollExtent,
          ),
        );
      }
    }
    if (!mounted || epoch != _navigationEpoch) return;
    _jumpBlock = null;
    _jumpOffset = null;
    _restoring = false;
    widget.state.fraction = _fraction;
    _queueSave();
    setState(() {});
  }

  Future<void> _go(
    int chapter, {
    double fraction = 0,
    int? block,
    int? sourceOffset,
    bool remember = false,
    bool keepAuto = false,
  }) async {
    if (chapter < 0 || chapter >= _chapters.length) return;
    if (remember) {
      final Json target = _chapters[chapter];
      final int start = (target['o0'] as num).toInt();
      final int end = (target['o1'] as num).toInt();
      final int position =
          sourceOffset ??
          (block != null
              ? (_blocks[block]['o'] as num).toInt()
              : start + ((end - start) * fraction).round());
      if (!await _confirmJump(position)) return;
    }
    _stopListening();
    if (!keepAuto) {
      _autoPage.stop();
      _activity.touch();
    }
    if (remember) _rememberPosition();
    final int epoch = ++_navigationEpoch;
    _selectionCaptureTimer?.cancel();
    _selectionTimer?.cancel();
    _pageTapTimer?.cancel();
    html.window.getSelection()?.removeAllRanges();
    _saveTimer?.cancel();
    _restoring = true;
    _jumpBlock = block;
    _jumpOffset = sourceOffset;
    _seekPreview = null;
    _blockKeys.clear();
    _pageLayoutKey = null;
    _reflowAnchor = null;
    _pages = const <List<_WebPageFragment>>[];
    _pageIndex = 0;
    setState(() {
      _chapter = chapter;
      widget.state.chapter = chapter;
      widget.state.fraction = fraction;
      widget.state.sourceOffset =
          sourceOffset ??
          ((_chapters[chapter]['o0'] as num).toInt() +
              (((_chapters[chapter]['o1'] as num).toInt() -
                          (_chapters[chapter]['o0'] as num).toInt()) *
                      fraction)
                  .round());
      widget.state.lastOpened = DateTime.now().millisecondsSinceEpoch;
      _controls = false;
      _selectedText = null;
    });
    unawaited(widget.library.saveState(widget.book.meta.id, widget.state));
    if (!_prefs.pageMode) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _restoreFraction(fraction, epoch: epoch),
      );
    }
  }

  void _returnToReadingPosition() {
    final ({int chapter, double fraction})? target = _returnPosition;
    if (target == null) return;
    final int? source = widget.state.returnOffset;
    _returnPosition = null;
    final VoidCallback? reopen = _returnToAsk;
    _returnToAsk = null;
    _go(target.chapter, fraction: target.fraction, sourceOffset: source);
    final int epoch = _navigationEpoch;
    if (reopen != null) {
      Future<void> reopenWhenPositioned() async {
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || epoch != _navigationEpoch) return;
        if (_restoring) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => reopenWhenPositioned(),
          );
        } else {
          reopen();
        }
      }

      unawaited(reopenWhenPositioned());
    }
  }

  void _selectionChanged(SelectedContent? content) {
    final String? next = content?.plainText.trim();
    final String? selected = next == null || next.isEmpty
        ? null
        : _boundedSelection(next);
    _selectionTimer?.cancel();
    if (selected == null) {
      if (_selectedText == null) return;
      if (_selectionActionQuote != null) return;
      // Clicking a selection action clears browser selection on pointer-down.
      // Keep the quote long enough for the button's pointer-up to activate.
      _selectionTimer = Timer(const Duration(milliseconds: 350), () {
        _selectionTimer = null;
        if (mounted) setState(() => _selectedText = null);
      });
      return;
    }
    if (_selectedText == selected) return;
    _selectedText = selected;
    _selectionTimer = Timer(const Duration(milliseconds: 60), () {
      _selectionTimer = null;
      if (mounted) setState(() {});
    });
  }

  void _captureBrowserSelection() {
    _selectionCaptureTimer?.cancel();
    _selectionCaptureTimer = Timer(const Duration(milliseconds: 40), () {
      _selectionCaptureTimer = null;
      if (!mounted || _selectedText?.isNotEmpty == true) return;
      final String? selected = _browserSelectionText();
      if (selected != null) setState(() => _selectedText = selected);
    });
  }

  // Keep the original selection intact; Ask validates length explicitly.
  String _boundedSelection(String text) => text;

  String? _browserSelectionText() {
    final html.Selection? selection = html.window.getSelection();
    if (selection == null || selection.rangeCount == 0) return null;
    final String text =
        selection.getRangeAt(0).cloneContents().text?.trim() ?? '';
    if (text.isEmpty || text.startsWith("Instance of '")) return null;
    return _boundedSelection(text);
  }

  void _clearSelectedText() {
    _selectionCaptureTimer?.cancel();
    _selectionTimer?.cancel();
    _selectionActionQuote = null;
    html.window.getSelection()?.removeAllRanges();
    setState(() => _selectedText = null);
  }

  void _selectionActionPointerEnd() {
    if (_selectionActionQuote == null) return;
    _selectionTimer?.cancel();
    _selectionTimer = Timer(const Duration(milliseconds: 350), () {
      _selectionTimer = null;
      _selectionActionQuote = null;
      if (mounted) setState(() => _selectedText = null);
    });
  }

  void _selectedAction({required bool ask}) {
    final String? quote = _selectionActionQuote ?? _selectedText;
    if (quote == null || quote.isEmpty) return;
    _clearSelectedText();
    if (ask) {
      unawaited(_openAsk(selectedText: quote));
    } else {
      unawaited(_addNote(selectedText: quote));
    }
  }

  void _selectedPerson() {
    final String? name = (_selectionActionQuote ?? _selectedText)?.trim();
    if (name == null || name.isEmpty || name.runes.length > 24) return;
    _clearSelectedText();
    unawaited(_openPerson(name: name));
  }

  Future<void> _seekFraction(double fraction) async {
    _activity.touch();
    _autoPage.stop();
    final int start = (_current['o0'] as num).toInt();
    final int end = (_current['o1'] as num).toInt();
    final int nextPage = _pages.isEmpty
        ? 0
        : (fraction * (_pages.length - 1)).round().clamp(0, _pages.length - 1);
    int target = start + ((end - start) * fraction).round();
    if (_prefs.pageMode && _pages.isNotEmpty) {
      if (nextPage == _pageIndex) return;
      for (final fragment in _pages[nextPage]) {
        if (fragment.block >= 0 && fragment.kind != 'space') {
          target =
              (_blocks[fragment.block]['o'] as num).toInt() +
              fragment.sourceStart;
          break;
        }
      }
    } else if ((fraction - _fraction).abs() < 0.001) {
      return;
    }
    if (!await _confirmJump(target)) return;
    _stopListening();
    if (_prefs.pageMode) {
      if (_pages.length < 2) return;
      final int next = (fraction * (_pages.length - 1)).round().clamp(
        0,
        _pages.length - 1,
      );
      if (next == _pageIndex) return;
      final int direction = next > _pageIndex ? 1 : -1;
      setState(() {
        _rememberPosition();
        _reflowAnchor = null;
        _pageIndex = next;
        _turnDirection = direction;
        widget.state.fraction = _fraction;
        widget.state.lastOpened = DateTime.now().millisecondsSinceEpoch;
      });
      _queueSave();
      return;
    }
    if ((fraction - _fraction).abs() < 0.001) return;
    if (!_scroll.hasClients || _scroll.position.maxScrollExtent <= 0) return;
    setState(() {
      _rememberPosition();
    });
    _scroll.jumpTo(_scroll.position.maxScrollExtent * fraction);
  }

  Future<bool> _confirmJump(int target) async {
    final int current =
        _readingSourceOffset() ?? (_current['o0'] as num).toInt();
    if (target == current) return true;
    final int epoch = _navigationEpoch;
    final bool forward = target > _visibleCutoffOffset();
    final bool rewind = target < current;
    if (!forward && !rewind) return true;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(forward ? '注意剧透' : '回到前文'),
        content: Text(forward ? '将跳至未读位置，可能提前知晓后续。' : '人物与前情将同步收窄至该页。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('留在原地'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认前往'),
          ),
        ],
      ),
    );
    return confirmed == true && mounted && epoch == _navigationEpoch;
  }

  void _bookmark() {
    final double fraction = _fraction;
    final WebPersonalItem? existing = widget.state.bookmarks
        .where((mark) => mark.chapter == _chapter && mark.fraction == fraction)
        .firstOrNull;
    setState(() {
      if (existing == null) {
        widget.state.addBookmark(_chapter, fraction);
      } else {
        widget.state.remove(existing);
      }
    });
    unawaited(widget.library.saveState(widget.book.meta.id, widget.state));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(existing == null ? '已添加书签' : '已取消书签'),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  Future<void> _openReaderPanel(
    Widget Function(WebReadingState reading) builder,
  ) async {
    if (_openingPanel || !mounted) return;
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (route?.isCurrent != true) return;
    final WebReadingState reading = WebReadingState.fromJson(
      widget.state.toJson(),
    );
    final int cutoff = _visibleCutoffOffset();
    final int epoch = _navigationEpoch;
    _openingPanel = true;
    _saveTimer?.cancel();
    try {
      await widget.library.saveState(widget.book.meta.id, widget.state);
      // A slow save must not reopen a dismissed route, duplicate a rapid tap,
      // or pair an earlier page's cutoff with a newer reading position.
      if (!mounted ||
          !route!.isCurrent ||
          reading.chapter != _chapter ||
          reading.fraction != widget.state.fraction ||
          cutoff != _visibleCutoffOffset()) {
        return;
      }
      await Navigator.of(
        context,
      ).push<void>(MaterialPageRoute<void>(builder: (_) => builder(reading)));
      if (!mounted) return;
      final WebReadingState latest = await widget.library.state(
        widget.book.meta.id,
      );
      if (!mounted || epoch != _navigationEpoch) return;
      widget.state.items
        ..clear()
        ..addAll(latest.items);
      widget.state.returnChapter = latest.returnChapter;
      widget.state.returnFraction = latest.returnFraction;
      widget.state.returnOffset = latest.returnOffset;
      if (latest.chapter != widget.state.chapter ||
          latest.fraction != widget.state.fraction) {
        _go(latest.chapter, fraction: latest.fraction);
      } else {
        setState(() {});
      }
    } on Object {
      if (mounted && route?.isCurrent == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前阅读位置暂未保存，请检查浏览器存储空间后重试。')),
        );
      }
    } finally {
      _openingPanel = false;
    }
  }

  Future<void> _openAi() => _openPerson();

  Future<void> _openPerson({
    String? id,
    String? name,
    int initialTab = 0,
  }) async {
    final int cutoff = _visibleCutoffOffset();
    await _openReaderPanel(
      (WebReadingState reading) => WebAiPanel(
        book: widget.book,
        reading: reading,
        library: widget.library,
        cutoffOffset: cutoff,
        initialTab: initialTab,
        showPreparation: false,
        focusPersonId: id,
        focusPersonName: name,
        readingBuilder: (_, _) => WebReader(
          book: widget.book,
          state: reading,
          library: widget.library,
        ),
      ),
    );
    if (mounted) unawaited(_loadPersonPreparation());
  }

  int _askCutoffBlockExclusive() {
    final int first = (_current['b0'] as num?)?.toInt() ?? 0;
    final int last = (_current['b1'] as num?)?.toInt() ?? first;
    if (_speechCutoff != null) {
      for (int i = first; i < last && i < _blocks.length; i++) {
        final Json block = _blocks[i];
        if ((block['o'] as num).toInt() + '${block['t'] ?? ''}'.length >
            _speechCutoff!) {
          return i;
        }
      }
      return last;
    }
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

  List<SourceSlice> _visibleSourceSlices() {
    final List<SourceSlice> slices = <SourceSlice>[];
    void add(int block, int start, int end) {
      if (block < 0 || block >= _blocks.length) return;
      final Json raw = _blocks[block];
      if (raw['k'] != 'p' && raw['k'] != 'h') return;
      final String text = '${raw['t'] ?? ''}';
      start = start.clamp(0, text.length);
      end = end.clamp(start, text.length);
      if (start < end) {
        slices.add(
          SourceSlice(
            text: text.substring(start, end),
            start: (raw['o'] as num).toInt() + start,
          ),
        );
      }
    }

    if (_prefs.pageMode && _pages.isNotEmpty) {
      for (final _WebPageFragment fragment in _pages[_pageIndex]) {
        add(fragment.block, fragment.sourceStart, fragment.sourceEnd);
      }
    } else {
      final double top = MediaQuery.paddingOf(context).top + 58;
      final double bottom = _readerVisibleBottom();
      for (final MapEntry<int, GlobalKey> entry in _blockKeys.entries) {
        final RenderObject? root = entry.value.currentContext
            ?.findRenderObject();
        RenderParagraph? paragraph;
        void visit(RenderObject node) {
          if (node is RenderParagraph) {
            paragraph = node;
            return;
          }
          node.visitChildren(visit);
        }

        if (root == null) continue;
        visit(root);
        final RenderParagraph? render = paragraph;
        if (render == null || !render.hasSize) continue;
        final double y = render.localToGlobal(Offset.zero).dy;
        if (y >= bottom || y + render.size.height <= top) continue;
        final String text = '${_blocks[entry.key]['t'] ?? ''}';
        final int indent = _blocks[entry.key]['k'] == 'p' ? 2 : 0;
        final int start = y >= top
            ? 0
            : render.getPositionForOffset(Offset(0, top - y)).offset - indent;
        final int end = y + render.size.height <= bottom
            ? text.length
            : render.getPositionForOffset(Offset(0, bottom - y)).offset -
                  indent;
        add(entry.key, start, end);
      }
    }
    return slices;
  }

  Future<void> _openAsk({
    String? selectedText,
    SourceSelection? restoredSelection,
    bool restoreDraft = false,
  }) async {
    final int safeBlock = _askCutoffBlockExclusive();
    final SourceSelection? selected = restoreDraft && restoredSelection != null
        ? restoredSelection
        : selectedText == null
        ? null
        : resolveSourceSelection(selectedText, _visibleSourceSlices());
    if (selectedText?.trim().isNotEmpty == true && selected == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这段选文的位置不够明确，请缩小选择范围后再问书。')));
      return;
    }
    await _openReaderPanel(
      (WebReadingState reading) => WebAskPanel(
        book: widget.book,
        chapterIndex: reading.chapter,
        cutoffBlockExclusive: safeBlock,
        selectedText: selected?.text,
        selectedStart: selected?.start,
        selectedEnd: selected?.end,
        restoreDraft: restoreDraft,
        onCitationTap: (int blockIndex) {
          final int targetChapter = _chapters.indexWhere((Json chapter) {
            final int start = (chapter['b0'] as num?)?.toInt() ?? 0;
            final int end = (chapter['b1'] as num?)?.toInt() ?? start;
            return start <= blockIndex && blockIndex < end;
          });
          if (targetChapter < 0) return;
          _returnToAsk = () => _openAsk(
            selectedText: selected?.text,
            restoredSelection: selected,
            restoreDraft: true,
          );
          Navigator.of(context).pop();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              _go(targetChapter, block: blockIndex, remember: true);
            }
          });
        },
      ),
    );
    _selectedText = null;
  }

  double get _progress {
    if (_chapters.isEmpty) return 0;
    return (_savedSourceOffset() / math.max(1, widget.book.meta.length)).clamp(
      0.0,
      1.0,
    );
  }

  Widget _sheetHeader(BuildContext sheetContext, String title) => ListTile(
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
    trailing: IconButton(
      tooltip: '关闭$title',
      onPressed: () => Navigator.pop(sheetContext),
      icon: const Icon(Icons.close),
    ),
  );

  void _chaptersSheet({int initialTab = 0}) {
    final TextEditingController pageInput = TextEditingController();
    final ScrollController chapterScroll = ScrollController(
      initialScrollOffset: _chapter * 64.0,
    );
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (sheetContext) => DefaultTabController(
        length: 3,
        initialIndex: initialTab,
        child: SafeArea(
          child: SizedBox(
            height: math.min(MediaQuery.sizeOf(context).height * .82, 730),
            child: StatefulBuilder(
              builder: (context, update) => Column(
                children: <Widget>[
                  _sheetHeader(sheetContext, '目录'),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20),
                    child: TabBar(
                      tabs: <Tab>[
                        Tab(text: '目录'),
                        Tab(text: '书签'),
                        Tab(text: '想法'),
                      ],
                    ),
                  ),
                  if (_prefs.pageMode && _pages.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: TextField(
                              controller: pageInput,
                              keyboardType: TextInputType.number,
                              decoration: InputDecoration(
                                labelText: '跳页',
                                hintText: '本章页码 1–${_pages.length}',
                              ),
                              onSubmitted: (_) =>
                                  _jumpFromToc(sheetContext, pageInput.text),
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () =>
                                _jumpFromToc(sheetContext, pageInput.text),
                            child: const Text('前往'),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: TabBarView(
                      children: <Widget>[
                        ListView.builder(
                          controller: chapterScroll,
                          itemCount: _chapters.length,
                          itemExtent: 64,
                          itemBuilder: (context, index) => ListTile(
                            selected: index == _chapter,
                            title: Text(
                              _safeChapterTitle(index),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: index > _chapter
                                ? const Text(
                                    '未读章节 · 标题读到后再揭晓。',
                                    style: TextStyle(fontSize: 12),
                                  )
                                : null,
                            leading: SizedBox(
                              width: 30,
                              child: Text('${index + 1}'),
                            ),
                            onTap: () {
                              Navigator.pop(sheetContext);
                              _go(index, remember: true);
                            },
                          ),
                        ),
                        widget.state.bookmarks.isEmpty
                            ? const Center(
                                child: Padding(
                                  padding: EdgeInsets.all(20),
                                  child: Text('随手折起精彩书页。点顶部书签即可保存。'),
                                ),
                              )
                            : ListView(
                                children: <Widget>[
                                  for (final mark in widget.state.bookmarks)
                                    ListTile(
                                      leading: const Icon(
                                        Icons.bookmark_outline,
                                      ),
                                      title: Text(
                                        _safeChapterTitle(mark.chapter),
                                      ),
                                      subtitle: Text(
                                        '本章 ${(mark.fraction * 100).round()}%',
                                      ),
                                      onTap: () {
                                        Navigator.pop(sheetContext);
                                        _go(
                                          mark.chapter,
                                          fraction: mark.fraction,
                                          remember: true,
                                        );
                                      },
                                      trailing: IconButton(
                                        tooltip: '删除书签',
                                        icon: const Icon(Icons.close),
                                        onPressed: () async {
                                          widget.state.remove(mark);
                                          await widget.library.saveState(
                                            widget.book.meta.id,
                                            widget.state,
                                          );
                                          if (context.mounted) update(() {});
                                          if (mounted) setState(() {});
                                        },
                                      ),
                                    ),
                                ],
                              ),
                        ListView(
                          children: <Widget>[
                            Padding(
                              padding: const EdgeInsets.all(20),
                              child: OutlinedButton.icon(
                                onPressed: () {
                                  Navigator.pop(sheetContext);
                                  _addNote();
                                },
                                icon: const Icon(Icons.edit_outlined),
                                label: const Text('写想法'),
                              ),
                            ),
                            if (widget.state.notes.isEmpty)
                              const Padding(
                                padding: EdgeInsets.all(20),
                                child: Text('笔墨未动。长按句子，留存心中感动。'),
                              ),
                            for (final note in widget.state.notes)
                              ListTile(
                                title: Text(
                                  note.text,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Text(
                                  '${note.style == 'highlight' ? '划线' : '想法'} · ${_safeChapterTitle(note.chapter)}',
                                ),
                                onTap: () {
                                  Navigator.pop(sheetContext);
                                  _go(
                                    note.chapter,
                                    fraction: note.fraction,
                                    sourceOffset: note.sourceStart,
                                    remember: true,
                                  );
                                },
                                trailing: IconButton(
                                  tooltip: '删除想法',
                                  icon: const Icon(Icons.close),
                                  onPressed: () async {
                                    widget.state.remove(note);
                                    await widget.library.saveState(
                                      widget.book.meta.id,
                                      widget.state,
                                    );
                                    if (context.mounted) update(() {});
                                    if (mounted) setState(() {});
                                  },
                                ),
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
      ),
    ).whenComplete(() {
      pageInput.dispose();
      chapterScroll.dispose();
    });
  }

  void _jumpFromToc(BuildContext sheetContext, String value) {
    final int? page = int.tryParse(value.trim());
    if (page == null || page < 1 || page > _pages.length) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('请输入 1–${_pages.length} 的页码。')));
      return;
    }
    Navigator.pop(sheetContext);
    if (_pages.length > 1) _seekFraction((page - 1) / (_pages.length - 1));
  }

  void _bookmarksSheet() => _chaptersSheet(initialTab: 1);
  void _notesSheet() => _chaptersSheet(initialTab: 2);

  bool get _chapterHasFootnotes {
    final int first = (_current['b0'] as num?)?.toInt() ?? 0;
    final int last = (_current['b1'] as num?)?.toInt() ?? first;
    for (int i = first; i < last && i < _blocks.length; i++) {
      if ((_blocks[i]['fn'] as List<Object?>?)?.isNotEmpty == true) return true;
    }
    return false;
  }

  List<String> _visibleFootnoteIds() {
    final Object? rawNotes = widget.book.data['notes'];
    if (rawNotes is! Json || rawNotes.isEmpty) return const <String>[];
    final List<String> result = <String>[];

    void collect(int blockIndex, int start, int end) {
      final Object? raw = _blocks[blockIndex]['fn'];
      if (raw is! List<Object?>) return;
      for (final Object? item in raw) {
        if (item is! List<Object?> || item.length != 2) continue;
        final int offset = item[0] as int;
        final String id = item[1] as String;
        if ((offset > start || (start == 0 && offset == 0)) &&
            offset <= end &&
            rawNotes[id] is String) {
          result.add(id);
        }
      }
    }

    if (_prefs.pageMode) {
      final Map<int, int> consumed = <int, int>{};
      for (
        int pageIndex = 0;
        pageIndex <= _pageIndex && pageIndex < _pages.length;
        pageIndex++
      ) {
        for (final _WebPageFragment fragment in _pages[pageIndex]) {
          if (fragment.block < 0 ||
              fragment.kind == 'space' ||
              fragment.kind == 'img') {
            continue;
          }
          final int displayedStart = consumed[fragment.block] ?? 0;
          final int displayedEnd = displayedStart + fragment.text.length;
          consumed[fragment.block] = displayedEnd;
          if (pageIndex != _pageIndex) continue;
          final int indent = fragment.kind == 'p' ? 2 : 0;
          final int textLength = '${_blocks[fragment.block]['t'] ?? ''}'.length;
          final int sourceStart = (displayedStart - indent).clamp(
            0,
            textLength,
          );
          final int sourceEnd = (displayedEnd - indent).clamp(0, textLength);
          collect(fragment.block, sourceStart, sourceEnd);
        }
      }
      return result;
    }

    // Only expose notes from complete paragraphs above the visible bottom edge.
    final double visibleBottom =
        MediaQuery.sizeOf(context).height -
        MediaQuery.paddingOf(context).bottom -
        64;
    final int first = (_current['b0'] as num?)?.toInt() ?? 0;
    final int last = (_current['b1'] as num?)?.toInt() ?? first;
    for (int i = first; i < last && i < _blocks.length; i++) {
      if (i == first &&
          _blocks[i]['k'] == 'h' &&
          _blocks[i]['t'] == _current['title']) {
        continue;
      }
      final RenderObject? render = _blockKeys[i]?.currentContext
          ?.findRenderObject();
      if (render is! RenderBox || !render.hasSize) break;
      if (render.localToGlobal(Offset(0, render.size.height)).dy >
          visibleBottom) {
        break;
      }
      collect(i, 0, '${_blocks[i]['t'] ?? ''}'.length);
    }
    return result;
  }

  void _footnotesSheet() {
    final List<String> ids = _visibleFootnoteIds();
    final Json notes = widget.book.data['notes'] is Json
        ? widget.book.data['notes'] as Json
        : <String, Object?>{};
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (BuildContext context) => SafeArea(
        child: SizedBox(
          height: math.min(MediaQuery.sizeOf(context).height * 0.72, 620),
          child: Column(
            children: <Widget>[
              ListTile(
                title: Text(_prefs.pageMode ? '本页注释' : '已读注释'),
                subtitle: Text('共 ${ids.length} 条'),
                trailing: IconButton(
                  tooltip: '关闭注释',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ),
              Expanded(
                child: ids.isEmpty
                    ? const Center(child: Text('这里还没有可查看的注释'))
                    : ListView.builder(
                        itemCount: ids.length,
                        itemBuilder: (BuildContext context, int index) =>
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                              child: Card(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text('注 ${index + 1}'),
                                      const SizedBox(height: 8),
                                      SelectableText('${notes[ids[index]]}'),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _highlight(String quote) async {
    if (quote.trim().isEmpty) return;
    final SourceSelection? selected = resolveSourceSelection(
      quote,
      _visibleSourceSlices(),
    );
    if (selected == null || selected.text.runes.length > 4000) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请选择不超过 4000 字的原文。')));
      return;
    }
    widget.state.addNote(
      _chapter,
      _fraction,
      selected.text,
      highlight: true,
      sourceStart: selected.start,
      sourceEnd: selected.end,
    );
    _clearSelectedText();
    try {
      await widget.library.saveState(widget.book.meta.id, widget.state);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已存入书摘')));
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('划线未能保存，请检查浏览器空间。')));
      }
    }
  }

  Future<void> _addNote({String? selectedText}) async {
    final TextEditingController controller = TextEditingController();
    final String quote = selectedText?.trim() ?? '';
    if (quote.isNotEmpty) {
      final String excerpt = quote.length > 1500
          ? '${quote.substring(0, 1500)}…'
          : quote;
      controller.text = '「$excerpt」\n\n';
      controller.selection = TextSelection.collapsed(
        offset: controller.text.length,
      );
    }
    final String? note = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('写想法'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 3,
          maxLines: 7,
          maxLength: 2000,
          decoration: InputDecoration(
            hintText: quote.isEmpty ? '这一页让你想到了什么？' : '在引文后写下想法',
          ),
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
    final SourceSelection? selected = quote.isEmpty
        ? null
        : resolveSourceSelection(quote, _visibleSourceSlices());
    widget.state.addNote(
      _chapter,
      _fraction,
      note,
      sourceStart: selected?.start,
      sourceEnd: selected?.end,
    );
    await widget.library.saveState(widget.book.meta.id, widget.state);
    if (mounted) setState(() {});
  }

  void _searchSheet() {
    final int cutoff = _visibleCutoffOffset();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (BuildContext sheetContext) => WebReaderSearch(
        book: widget.book,
        cutoff: cutoff,
        chapterTitle: _safeChapterTitle,
        onHit: (hit) {
          Navigator.pop(sheetContext);
          _go(
            hit.chapter,
            block: hit.block,
            sourceOffset: hit.start,
            remember: true,
          );
        },
      ),
    );
  }

  void _typographySheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter update) {
          void change(void Function() action) {
            final double fraction = _fraction;
            final int? source = _readingSourceOffset();
            final int epoch = ++_navigationEpoch;
            final bool wasPageMode = _prefs.pageMode;
            update(action);
            widget.state.fraction = fraction;
            _pageLayoutKey = null;
            if (!wasPageMode || !_prefs.pageMode) {
              _reflowAnchor = null;
              _pages = const <List<_WebPageFragment>>[];
              _pageIndex = 0;
            }
            _restoring = true;
            // Page-to-page reflow must keep the original source anchor. The
            // current page can start earlier after a font change; using that
            // new start as an explicit jump makes repeated changes drift.
            _jumpOffset = wasPageMode && _prefs.pageMode ? null : source;
            setState(() {});
            _prefs.save();
            _queueSave();
            if (!_prefs.pageMode) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => _restoreFraction(fraction, epoch: epoch),
              );
            }
          }

          return SafeArea(
            child: SizedBox(
              height: math.min(MediaQuery.sizeOf(context).height * 0.82, 670),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
                children: <Widget>[
                  _sheetHeader(context, '排版'),
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
                        label: const Text('滚动'),
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
                  TextButton.icon(
                    onPressed: () => change(() {
                      _prefs.fontSize = 21;
                      _prefs.lineHeight = 1.75;
                      _prefs.letterSpacing = 0;
                      _prefs.margin = 24;
                      _prefs.columnWidth = 640;
                      _prefs.font = 0;
                      _prefs.paper = 0;
                    }),
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('重置排版'),
                  ),
                  _metric(
                    '字号大小',
                    _prefs.fontSize,
                    14,
                    34,
                    (double v) => change(() => _prefs.fontSize = v),
                    'px',
                  ),
                  _metric(
                    '行间高度',
                    _prefs.lineHeight,
                    1.2,
                    2.4,
                    (double v) => change(() => _prefs.lineHeight = v),
                    '×',
                  ),
                  _metric(
                    '字符间距',
                    _prefs.letterSpacing,
                    -0.5,
                    2.5,
                    (double v) => change(() => _prefs.letterSpacing = v),
                    'px',
                  ),
                  _metric(
                    '页边留白',
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
                  const Text('正文字体'),
                  Wrap(
                    spacing: 8,
                    children: <Widget>[
                      for (int i = 0; i < 3; i++)
                        ChoiceChip(
                          label: Text(const <String>['文宋', '文楷', '黑体'][i]),
                          selected: _prefs.font == i,
                          onSelected: (_) => change(() => _prefs.font = i),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('纸张质感'),
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
        child: Semantics(
          label: label,
          child: Slider(value: value, min: min, max: max, onChanged: change),
        ),
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
    webReadingRoutes.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _activity.dispose();
    _speech.dispose();
    _autoPage.dispose();

    _saveTimer?.cancel();
    _displayTimer?.cancel();
    _wheelTimer?.cancel();
    _pageTapTimer?.cancel();
    _selectionTimer?.cancel();
    _selectionCaptureTimer?.cancel();
    for (final TapGestureRecognizer recognizer in _personRecognizers.values) {
      recognizer.dispose();
    }
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
      return Scaffold(
        appBar: AppBar(title: Text(widget.book.meta.title)),
        body: const Center(child: Text('这本书没有可阅读的章节。')),
      );
    }
    final Color paper = _prefs.paperColor;
    final Color ink = _prefs.ink;
    final int first = (_current['b0'] as num?)?.toInt() ?? 0;
    final int last = (_current['b1'] as num?)?.toInt() ?? first;
    final int scrollCutoff = _prefs.pageMode ? 0 : _visibleCutoffOffset();
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
                    if (_personTapConsumed) {
                      _personTapConsumed = false;
                      return;
                    }
                    if (_selectedText?.isNotEmpty == true) return;
                    setState(() => _controls = !_controls);
                    _readerFocus.requestFocus();
                  },
                  onHorizontalDragEnd: (DragEndDetails details) {
                    if (_prefs.pageMode) return;
                    final double velocity = details.primaryVelocity ?? 0;
                    if (velocity < -350) _go(_chapter + 1, remember: true);
                    if (velocity > 350) _go(_chapter - 1, remember: true);
                  },
                  child: _prefs.pageMode
                      ? _pageBody(bodyStyle)
                      : Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: _prefs.columnWidth,
                            ),
                            child: SelectionArea(
                              onSelectionChanged: _selectionChanged,
                              contextMenuBuilder:
                                  (
                                    BuildContext context,
                                    SelectableRegionState selectable,
                                  ) => AdaptiveTextSelectionToolbar.buttonItems(
                                    anchors: selectable.contextMenuAnchors,
                                    buttonItems: <ContextMenuButtonItem>[
                                      ...selectable.contextMenuButtonItems,
                                      if (_selectedText?.trim().isNotEmpty ==
                                              true &&
                                          _selectedText!.trim().runes.length <=
                                              24)
                                        ContextMenuButtonItem(
                                          label: '这是谁',
                                          onPressed: () {
                                            final String name = _selectedText!
                                                .trim();
                                            ContextMenuController.removeAny();
                                            _clearSelectedText();
                                            unawaited(_openPerson(name: name));
                                          },
                                        ),
                                      ContextMenuButtonItem(
                                        label: '划线',
                                        onPressed: () {
                                          final quote = _selectedText;
                                          ContextMenuController.removeAny();
                                          if (quote != null) _highlight(quote);
                                        },
                                      ),
                                      ContextMenuButtonItem(
                                        label: '问这段',
                                        onPressed: () {
                                          final String? selected =
                                              _selectedText;
                                          ContextMenuController.removeAny();
                                          unawaited(
                                            _openAsk(selectedText: selected),
                                          );
                                        },
                                      ),
                                      if (_selectedText?.trim().isNotEmpty ==
                                          true)
                                        ContextMenuButtonItem(
                                          label: '写想法',
                                          onPressed: () {
                                            final String? selected =
                                                _selectedText;
                                            ContextMenuController.removeAny();
                                            unawaited(
                                              _addNote(selectedText: selected),
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
                                            child: _paragraph(
                                              i,
                                              bodyStyle,
                                              scrollCutoff,
                                            ),
                                          ),
                                      const SizedBox(height: 42),
                                      Row(
                                        children: <Widget>[
                                          if (_chapter > 0)
                                            TextButton.icon(
                                              onPressed: () => _go(
                                                _chapter - 1,
                                                remember: true,
                                              ),
                                              icon: const Icon(
                                                Icons.arrow_back,
                                              ),
                                              label: const Text('上一章'),
                                            ),
                                          const Spacer(),
                                          if (_chapter + 1 < _chapters.length)
                                            TextButton.icon(
                                              onPressed: () => _go(
                                                _chapter + 1,
                                                remember: true,
                                              ),
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
          if (_controls)
            const Positioned.fill(
              child: IgnorePointer(child: ColoredBox(color: Color(0x0A000000))),
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
            top: 0,
            left: 0,
            right: 0,
            child: ExcludeSemantics(
              excluding: !_controls,
              child: IgnorePointer(
                ignoring: !_controls,
                child: AnimatedSlide(
                  offset: _controls ? Offset.zero : const Offset(0, -1),
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 160),
                  child: _topToolbar(),
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
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : const Duration(milliseconds: 180),
                  child: _toolbar(),
                ),
              ),
            ),
          ),
          if (!_controls && _selectedText?.isNotEmpty == true)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                top: false,
                child: Center(
                  child: Listener(
                    onPointerDown: (_) {
                      _selectionActionQuote = _selectedText;
                      _selectionTimer?.cancel();
                    },
                    onPointerUp: (_) => _selectionActionPointerEnd(),
                    onPointerCancel: (_) => _selectionActionPointerEnd(),
                    child: Material(
                      color: ink,
                      borderRadius: BorderRadius.circular(18),
                      elevation: 4,
                      child: Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          if (_selectedText!.trim().runes.length <= 24)
                            TextButton.icon(
                              onPressed: _selectedPerson,
                              icon: Icon(
                                Icons.person_search_outlined,
                                color: paper,
                              ),
                              label: Text(
                                '这是谁',
                                style: TextStyle(color: paper),
                              ),
                            ),
                          TextButton.icon(
                            onPressed: () => _selectedAction(ask: false),
                            icon: Icon(Icons.edit_note, color: paper),
                            label: Text('写想法', style: TextStyle(color: paper)),
                          ),
                          TextButton.icon(
                            onPressed: () => _selectedAction(ask: true),
                            icon: Icon(Icons.auto_awesome, color: paper),
                            label: Text('问这段', style: TextStyle(color: paper)),
                          ),
                          IconButton(
                            tooltip: '取消选择',
                            onPressed: _clearSelectedText,
                            icon: Icon(Icons.close, color: paper),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (!_controls &&
              _selectedText?.isNotEmpty != true &&
              _returnPosition != null)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                top: false,
                child: Row(
                  children: <Widget>[
                    const SizedBox(width: 48),
                    Expanded(
                      child: Center(
                        child: Material(
                          color: ink,
                          shape: const StadiumBorder(),
                          elevation: 3,
                          child: InkWell(
                            customBorder: const StadiumBorder(),
                            onTap: _returnToReadingPosition,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 10,
                              ),
                              child: Text(
                                '↩ 回到跳转前的位置',
                                style: TextStyle(color: paper),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '打开阅读工具',
                      onPressed: () => setState(() => _controls = true),
                      icon: Icon(Icons.keyboard_arrow_up, color: ink),
                    ),
                  ],
                ),
              ),
            ),
          if (!_controls &&
              _selectedText?.isNotEmpty != true &&
              _returnPosition == null)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: 64 + MediaQuery.paddingOf(context).bottom,
              child: SafeArea(
                top: false,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: IconButton(
                    tooltip: '打开阅读工具',
                    onPressed: () => setState(() => _controls = true),
                    style: IconButton.styleFrom(
                      minimumSize: const Size(44, 44),
                      backgroundColor: ink.withValues(alpha: 0.08),
                      foregroundColor: _prefs.muted,
                    ),
                    icon: const Icon(Icons.keyboard_arrow_up),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  TapGestureRecognizer _personRecognizer(_WebPersonLink link) {
    final String key = link.id == null
        ? 'draft:${link.name}'
        : 'native:${link.id}';
    return _personRecognizers.putIfAbsent(
      key,
      () => TapGestureRecognizer()
        ..onTap = () {
          _personTapConsumed = true;
          unawaited(_openPerson(id: link.id, name: link.name));
        },
    );
  }

  Widget _personText(
    String text,
    TextStyle style, {
    required int blockIndex,
    required int sourceStart,
    required int sourceEnd,
    required int cutoff,
    required bool paragraph,
    StrutStyle? strutStyle,
  }) {
    final int origin = (_blocks[blockIndex]['o'] as num?)?.toInt() ?? 0;
    final int absoluteStart = origin + sourceStart;
    final int absoluteEnd = origin + sourceEnd;
    final int indent = paragraph && sourceStart == 0 && text.startsWith('　　')
        ? 2
        : 0;
    final List<_WebPersonLink> candidates = <_WebPersonLink>[];
    for (final _WebPersonMention mention
        in _nativePersonMentions[_chapter] ?? const <_WebPersonMention>[]) {
      // Neither the link label nor its eligibility may rely on a future KG
      // record. A name split across pages is left as ordinary text.
      final int? firstPerson = _nativePersonFirst[mention.id];
      if (firstPerson == null ||
          firstPerson > cutoff ||
          mention.end > cutoff ||
          mention.start < absoluteStart ||
          mention.end > absoluteEnd) {
        continue;
      }
      final int start = (mention.start - absoluteStart + indent).clamp(
        0,
        text.length,
      );
      final int end = (mention.end - absoluteStart + indent).clamp(
        0,
        text.length,
      );
      if (end > start) {
        candidates.add(
          _WebPersonLink(start, end, text.substring(start, end), mention.id),
        );
      }
    }
    for (final String name in _draftNamesAtCurrentChapter()) {
      int at = 0;
      while (at < text.length) {
        final int found = text.indexOf(name, at);
        if (found < 0) break;
        final int end = found + name.length;
        final bool beforeWord =
            found > 0 && _asciiWord.hasMatch(text[found - 1]);
        final bool afterWord =
            end < text.length && _asciiWord.hasMatch(text[end]);
        if (!beforeWord && !afterWord) {
          candidates.add(_WebPersonLink(found, end, name, null));
        }
        at = end;
      }
    }
    final List<(int, int)> highlights = <(int, int)>[
      for (final note in widget.state.notes)
        if (note.style == 'highlight' &&
            note.sourceStart != null &&
            note.sourceEnd != null &&
            note.sourceStart! < absoluteEnd &&
            note.sourceEnd! > absoluteStart)
          (
            (note.sourceStart! - absoluteStart + indent).clamp(
              indent,
              text.length,
            ),
            (note.sourceEnd! - absoluteStart + indent).clamp(
              indent,
              text.length,
            ),
          ),
    ];
    if (candidates.isEmpty && highlights.isEmpty) {
      return Text(
        text,
        style: style,
        textAlign: paragraph ? TextAlign.justify : TextAlign.left,
        strutStyle: strutStyle,
      );
    }
    candidates.sort((_WebPersonLink a, _WebPersonLink b) {
      final int at = a.start.compareTo(b.start);
      if (at != 0) return at;
      if (a.id != null && b.id == null) return -1;
      if (a.id == null && b.id != null) return 1;
      return (b.end - b.start).compareTo(a.end - a.start);
    });
    final List<_WebPersonLink> links = <_WebPersonLink>[];
    int cursor = 0;
    for (final link in candidates) {
      if (link.start < cursor || link.end > text.length) continue;
      links.add(link);
      cursor = link.end;
    }
    final List<int> edges = <int>{
      0,
      text.length,
      for (final link in links) ...<int>[link.start, link.end],
      for (final range in highlights) ...<int>[range.$1, range.$2],
    }.toList()..sort();
    final List<InlineSpan> spans = <InlineSpan>[];
    for (int i = 0; i + 1 < edges.length; i++) {
      final int start = edges[i], end = edges[i + 1];
      if (start == end) continue;
      final _WebPersonLink? link = links
          .where((link) => link.start <= start && link.end >= end)
          .firstOrNull;
      final bool marked = highlights.any(
        (range) => range.$1 < end && range.$2 > start,
      );
      spans.add(
        TextSpan(
          text: text.substring(start, end),
          style: TextStyle(
            backgroundColor: marked
                ? (_prefs.dark ? Tokens.night.qingSoft : Tokens.light.qingSoft)
                : null,
            decoration: link != null ? TextDecoration.underline : null,
            decorationStyle: link?.id == null
                ? TextDecorationStyle.dotted
                : TextDecorationStyle.solid,
            decorationColor: _prefs.dark
                ? Tokens.night.qing
                : Tokens.light.qing,
            decorationThickness: 1.4,
          ),
          recognizer: link == null ? null : _personRecognizer(link),
        ),
      );
    }
    return Text.rich(
      TextSpan(children: spans),
      style: style,
      textAlign: paragraph ? TextAlign.justify : TextAlign.left,
      strutStyle: strutStyle,
    );
  }

  String? _imageSemanticLabel(Json block) {
    final Object? alt = block['alt'];
    return alt is String && alt.trim().isNotEmpty ? alt : null;
  }

  Widget _bookImage(Json block, String? encoded, TextStyle style) {
    if (encoded == null) return Center(child: Text('[图片未保存]', style: style));
    try {
      final MemoryImage image = MemoryImage(base64Decode(encoded));
      final String? label = _imageSemanticLabel(block);
      return InkWell(
        onTap: () => openReaderImage(context, image, label: label),
        child: Image(
          image: image,
          fit: BoxFit.contain,
          semanticLabel: label,
          errorBuilder: (_, _, _) =>
              Center(child: Text('图片无法加载', style: style)),
        ),
      );
    } on FormatException {
      return Center(child: Text('图片无法加载', style: style));
    }
  }

  Widget _paragraph(int index, TextStyle style, int cutoff) {
    final Json block = _blocks[index];
    final String kind = '${block['k'] ?? 'p'}';
    if (kind == 'img') {
      final String? encoded = widget.book.images['${block['src']}'];
      return _bookImage(block, encoded, style.copyWith(color: _prefs.muted));
    }
    final String text = '${block['t'] ?? ''}';
    if (kind == 'h') {
      return _personText(
        text,
        style.copyWith(
          fontWeight: FontWeight.w600,
          fontSize: style.fontSize! * 1.13,
        ),
        blockIndex: index,
        sourceStart: 0,
        sourceEnd: text.length,
        cutoff: cutoff,
        paragraph: false,
      );
    }
    return _personText(
      '　　$text',
      style,
      blockIndex: index,
      sourceStart: 0,
      sourceEnd: text.length,
      cutoff: cutoff,
      paragraph: true,
    );
  }

  Widget _topToolbar() {
    final Tokens t = _prefs.dark ? Tokens.night : Tokens.light;
    final List<Widget> actions = <Widget>[
      IconButton(
        tooltip: '书签',
        onPressed: _bookmark,
        icon: Icon(
          widget.state.bookmarks.any(
                (mark) =>
                    mark.chapter == _chapter && mark.fraction == _fraction,
              )
              ? Icons.bookmark
              : Icons.bookmark_border,
        ),
      ),
      IconButton(
        tooltip: '搜原文',
        onPressed: _searchSheet,
        icon: const Icon(Icons.search),
      ),
      if (_chapterHasFootnotes)
        IconButton(
          tooltip: '查看注释',
          onPressed: _footnotesSheet,
          icon: const Icon(Icons.notes_outlined),
        ),
      IconButton(
        tooltip: '本书详情',
        onPressed: _readerDetails,
        icon: const Icon(Icons.more_horiz),
      ),
    ];
    return Material(
      color: t.sheet,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: LayoutBuilder(
            builder: (context, box) {
              final bool compact =
                  box.maxWidth < 360 ||
                  MediaQuery.textScalerOf(context).scale(14) > 22;
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      IconButton(
                        tooltip: '书架',
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
                      if (!compact) ...actions,
                      IconButton(
                        tooltip: '收起工具',
                        onPressed: () => setState(() => _controls = false),
                        icon: const Icon(Icons.keyboard_arrow_down),
                      ),
                    ],
                  ),
                  if (compact)
                    Row(
                      children: <Widget>[
                        for (final action in actions) Expanded(child: action),
                      ],
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _toolbar() {
    final Tokens t = _prefs.dark ? Tokens.night : Tokens.light;
    return Material(
      key: _bottomToolbarKey,
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
                  Flexible(
                    child: TextButton(
                      onPressed: _chapter > 0
                          ? () => _go(_chapter - 1, remember: true)
                          : null,
                      child: const Text(
                        '上一章',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      _prefs.pageMode
                          ? '本章第 ${((_seekPreview ?? _fraction) * math.max(0, _pages.length - 1)).round() + 1} / ${math.max(1, _pages.length)} 页'
                          : '本章 ${((_seekPreview ?? _fraction) * 100).round()}%',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: t.ink2),
                    ),
                  ),
                  Flexible(
                    child: TextButton(
                      onPressed: _chapter + 1 < _chapters.length
                          ? () => _go(_chapter + 1, remember: true)
                          : null,
                      child: const Text(
                        '下一章',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
              Semantics(
                label: '本章阅读进度',
                child: Slider(
                  value: (_seekPreview ?? _fraction).clamp(0.0, 1.0),
                  min: 0,
                  max: 1,
                  onChanged:
                      (_prefs.pageMode
                          ? _pages.length > 1
                          : _scroll.hasClients &&
                                _scroll.position.maxScrollExtent > 0)
                      ? (double value) => setState(() => _seekPreview = value)
                      : null,
                  onChangeEnd: (double value) {
                    setState(() => _seekPreview = null);
                    _seekFraction(value);
                  },
                ),
              ),
              Row(
                children: <Widget>[
                  Expanded(child: _tool(Icons.list, '目录', _chaptersSheet)),
                  Expanded(
                    child: _tool(Icons.auto_awesome_outlined, '人物', _openAi),
                  ),
                  Expanded(
                    child: _tool(
                      Icons.history,
                      '前情',
                      () => _openPerson(initialTab: 1),
                    ),
                  ),
                  Expanded(
                    child: _tool(
                      Icons.chat_bubble_outline,
                      '问书',
                      () => _openAsk(),
                    ),
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
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
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
            sourceStart: (start - (kind == 'p' ? 2 : 0)).clamp(
              0,
              text.length - (kind == 'p' ? 2 : 0),
            ),
            sourceEnd: (end - (kind == 'p' ? 2 : 0)).clamp(
              0,
              text.length - (kind == 'p' ? 2 : 0),
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

  ({int block, int offset})? _pageSourceAnchor() {
    if (_pages.isEmpty || _pageIndex >= _pages.length) return null;
    for (final _WebPageFragment fragment in _pages[_pageIndex]) {
      if (fragment.kind == 'img' || fragment.sourceEnd > fragment.sourceStart) {
        return (block: fragment.block, offset: fragment.sourceStart);
      }
    }
    return null;
  }

  void _ensurePages(double width, double height, TextStyle bodyStyle) {
    final int geometry = Object.hash(
      width.round(),
      height.round(),
      _prefs.fontSize,
      _prefs.lineHeight,
      _prefs.letterSpacing,
      _prefs.font,
      _prefs.margin,
      MediaQuery.textScalerOf(context).scale(10).toStringAsFixed(2),
    );
    final int key = Object.hash(_chapter, geometry);
    if (_pageLayoutKey == key) return;
    _pageGeometryKey = geometry;
    final anchor = _reflowAnchor ?? _pageSourceAnchor();
    _pages = _paginate(width, height, bodyStyle);
    int target = -1;
    if (_jumpOffset != null) {
      target = _pages.indexWhere(
        (List<_WebPageFragment> page) => page.any((fragment) {
          if (fragment.block < 0) return false;
          final int origin = (_blocks[fragment.block]['o'] as num).toInt();
          return origin + fragment.sourceStart <= _jumpOffset! &&
              _jumpOffset! < origin + fragment.sourceEnd;
        }),
      );
    }
    if (target < 0 && _jumpBlock != null) {
      target = _pages.indexWhere(
        (List<_WebPageFragment> page) => page.any(
          (_WebPageFragment fragment) => fragment.block == _jumpBlock,
        ),
      );
    }
    if (target < 0 && anchor != null) {
      target = _pages.indexWhere(
        (List<_WebPageFragment> page) => page.any(
          (_WebPageFragment fragment) =>
              fragment.block == anchor.block &&
              (fragment.kind == 'img' ||
                  (fragment.sourceStart <= anchor.offset &&
                      anchor.offset < fragment.sourceEnd)),
        ),
      );
    }
    if (target < 0) {
      target = _pages.length == 1
          ? 0
          : (widget.state.fraction * (_pages.length - 1)).round();
    }
    _pageIndex = target.clamp(0, _pages.length - 1);
    _reflowAnchor = anchor ?? _pageSourceAnchor();
    widget.state.fraction = _fraction;
    _jumpBlock = null;
    _jumpOffset = null;
    _pageLayoutKey = key;
    _restoring = false;
    _queueSave();
  }

  void _turnPage(int delta, {bool automatic = false}) {
    if (!automatic) {
      _autoPage.pause();
      _activity.touch();
    }
    _stopListening();
    if (!_prefs.pageMode || _pages.isEmpty) return;
    _selectionCaptureTimer?.cancel();
    html.window.getSelection()?.removeAllRanges();
    final int next = _pageIndex + delta;
    if (next < 0) {
      _go(_chapter - 1, fraction: 1, keepAuto: automatic);
      return;
    }
    if (next >= _pages.length) {
      _go(_chapter + 1, keepAuto: automatic);
      return;
    }
    setState(() {
      _reflowAnchor = null;
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
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed) {
      return;
    }
    if (!_readerRouteActive ||
        !_prefs.pageMode ||
        _wheelLocked ||
        _controls ||
        _selectedText?.isNotEmpty == true) {
      return;
    }
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
    if (!_readerRouteActive ||
        event is! html.WheelEvent ||
        event.ctrlKey ||
        event.metaKey ||
        event.altKey ||
        event.shiftKey) {
      return;
    }
    _wheelTurn(event.deltaY.toDouble());
  }

  void _domKey(html.Event event) {
    if (!_readerRouteActive || event is! html.KeyboardEvent) {
      return;
    }
    if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) {
      return;
    }
    final html.Element? active = html.document.activeElement;
    if (active is html.InputElement ||
        active is html.TextAreaElement ||
        active is html.SelectElement ||
        active?.getAttribute('contenteditable') == 'true') {
      return;
    }
    if (event.key == 'Escape' && _selectedText?.isNotEmpty == true) {
      _clearSelectedText();
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    if ((event.key == 'Escape' && _controls) || event.key == 't') {
      setState(() => _controls = !_controls);
      event.preventDefault();
      event.stopPropagation();
      return;
    }
    if (_controls || !_prefs.pageMode) return;
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
    _autoPage.pause();
    _activity.touch();
    if (event.buttons != 1) return;
    _pageTapTimer?.cancel();
    _personTapConsumed = false;
    _pointerStart = event.localPosition;
    _pointerStarted = DateTime.now();
    _pointerStartedWithSelection = _selectedText?.isNotEmpty == true;
  }

  void _readerPointerUp(PointerUpEvent event) {
    final Offset? start = _pointerStart;
    final DateTime? started = _pointerStarted;
    _pointerStart = null;
    _pointerStarted = null;
    if (start == null || started == null) return;
    final Offset delta = event.localPosition - start;
    final int elapsed = DateTime.now().difference(started).inMilliseconds;
    if (delta.distance > 14 || elapsed > 600) _captureBrowserSelection();
    if (!_prefs.pageMode) return;
    if (elapsed > 900) return;
    // A normal short tap can dismiss a prior selection and turn the page.
    // Keep a dragged selection intact for copy or 问书.
    if (delta.distance > 14 &&
        (_pointerStartedWithSelection || _selectedText?.isNotEmpty == true)) {
      return;
    }
    final double x =
        event.localPosition.dx / math.max(1, MediaQuery.sizeOf(context).width);
    // TextSpan.onTap resolves in the gesture arena after the outer Listener's
    // pointer-up. Defer the page turn until that callback can claim this tap.
    _pageTapTimer?.cancel();
    _pageTapTimer = Timer(Duration.zero, () {
      _pageTapTimer = null;
      if (!_readerRouteActive || _personTapConsumed) {
        _personTapConsumed = false;
        return;
      }
      html.window.getSelection()?.removeAllRanges();
      _selectedText = null;
      _readerFocus.requestFocus();
      if (delta.dx.abs() > 55 && delta.dx.abs() > delta.dy.abs() * 1.3) {
        _turnPage(delta.dx < 0 ? 1 : -1);
        return;
      }
      if (delta.distance > 14 || elapsed > 600) return;
      if (x < 1 / 3) {
        _turnPage(-1);
      } else if (x > 2 / 3) {
        _turnPage(1);
      } else {
        setState(() => _controls = !_controls);
      }
    });
  }

  KeyEventResult _readerKey(FocusNode _, KeyEvent event) {
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    if (!_readerRouteActive ||
        event is KeyUpEvent ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape && _selectedText?.isNotEmpty == true) {
      _clearSelectedText();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyT ||
        (key == LogicalKeyboardKey.escape && _controls)) {
      setState(() => _controls = !_controls);
      return KeyEventResult.handled;
    }
    if (_controls || !_prefs.pageMode) return KeyEventResult.ignored;
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
    return KeyEventResult.ignored;
  }

  Widget _selectionArea(Widget child) => SelectionArea(
    onSelectionChanged: _selectionChanged,
    contextMenuBuilder:
        (BuildContext context, SelectableRegionState selectable) =>
            AdaptiveTextSelectionToolbar.buttonItems(
              anchors: selectable.contextMenuAnchors,
              buttonItems: <ContextMenuButtonItem>[
                ...selectable.contextMenuButtonItems,
                if (_selectedText?.trim().isNotEmpty == true &&
                    _selectedText!.trim().runes.length <= 24)
                  ContextMenuButtonItem(
                    label: '这是谁',
                    onPressed: () {
                      final String name = _selectedText!.trim();
                      ContextMenuController.removeAny();
                      _clearSelectedText();
                      unawaited(_openPerson(name: name));
                    },
                  ),
                ContextMenuButtonItem(
                  label: '问这段',
                  onPressed: () {
                    final String? selected = _selectedText;
                    ContextMenuController.removeAny();
                    unawaited(_openAsk(selectedText: selected));
                  },
                ),
                if (_selectedText?.trim().isNotEmpty == true)
                  ContextMenuButtonItem(
                    label: '划线',
                    onPressed: () {
                      final quote = _selectedText;
                      ContextMenuController.removeAny();
                      if (quote != null) _highlight(quote);
                    },
                  ),
                ContextMenuButtonItem(
                  label: '写想法',
                  onPressed: () {
                    final String? selected = _selectedText;
                    ContextMenuController.removeAny();
                    unawaited(_addNote(selectedText: selected));
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
    int cutoff,
  ) {
    if (fragment.kind == 'space') return SizedBox(height: fragment.height);
    if (fragment.kind == 'img') {
      final String? encoded =
          widget.book.images['${_blocks[fragment.block]['src']}'];
      return SizedBox(
        height: fragment.height,
        child: _bookImage(_blocks[fragment.block], encoded, body),
      );
    }
    final TextStyle style = _fragmentStyle(fragment, body);
    final String text = _fragmentText(fragment);
    return SizedBox(
      key: ValueKey<String>(
        'web-page-fragment:${fragment.block}:${fragment.sourceStart}:${fragment.sourceEnd}',
      ),
      height: fragment.height,
      child: ClipRect(
        child: SizedBox(
          width: width,
          child: fragment.block < 0
              ? Text(text, style: style)
              : _personText(
                  text,
                  style,
                  blockIndex: fragment.block,
                  sourceStart: fragment.sourceStart,
                  sourceEnd: fragment.sourceEnd,
                  cutoff: cutoff,
                  paragraph: fragment.kind == 'p',
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
      final int cutoff = _visibleCutoffOffset();
      return Padding(
        padding: EdgeInsets.only(top: top, bottom: bottom),
        child: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            width: width,
            height: height,
            child: ClipRect(
              child: AnimatedSwitcher(
                // Reflow replaces page geometry rather than turning a page.
                // Do not lay out an outgoing tall page in the new short box.
                key: ValueKey<int?>(_pageGeometryKey),
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
                          _pageFragment(fragment, textWidth, bodyStyle, cutoff),
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
