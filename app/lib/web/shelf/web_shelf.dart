part of '../web_app.dart';

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
