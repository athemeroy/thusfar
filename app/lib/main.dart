import 'dart:async';
import 'dart:io';
import 'dart:ui' show DisplayFeature;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:thusfar_core/thusfar_core.dart' show PyException;
import 'package:url_launcher/url_launcher.dart';

import 'data/backup.dart';
import 'data/library.dart';
import 'data/model_settings.dart';
import 'data/prefs.dart';
import 'data/processing.dart';
import 'data/processing_notification_bridge.dart';
import 'data/seen.dart';
import 'data/update_checker.dart';
import 'reader/reader_screen.dart';
import 'screens/model_settings_screen.dart';
import 'screens/notes_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/webdav_screen.dart';
import 'screens/shelf_screen.dart';
import 'sheets/book_sheet.dart';
import 'ui/cover.dart';
import 'ui/theme.dart';

/// Books named on the command line ("打开方式" on Windows and Linux). They
/// are the reader's own files and are never deleted after import.
final List<String> launchFiles = <String>[];

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  launchFiles.addAll(args.where((String a) => !a.startsWith('-')));
  // Let Android resize and rotate the window for folded, unfolded, and
  // tabletop postures. Reader pagination follows the available pane size.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final Directory root = await dataRoot();
  root.createSync(recursive: true);
  final AppModel model = AppModel(root);
  await model.initialize();
  runApp(ThusfarApp(model: model));
}

/// Where the library lives. Android keeps the 1.7.x app's files/yedu; the
/// other platforms use their usual per-user application data directory
/// (inside the sandbox container on iOS and macOS).
Future<Directory> dataRoot() async {
  const String override = String.fromEnvironment('THUSFAR_DATA');
  if (override.isNotEmpty) return Directory(override);
  if (Platform.isAndroid) {
    final String? files = await const MethodChannel(
      'thusfar/paths',
    ).invokeMethod<String>('filesDir');
    return Directory('$files/yedu');
  }
  final Map<String, String> env = Platform.environment;
  if (Platform.isWindows) {
    return Directory('${env['APPDATA'] ?? env['USERPROFILE'] ?? '.'}\\Thusfar');
  }
  final String home = env['HOME'] ?? '.';
  if (Platform.isMacOS || Platform.isIOS) {
    return Directory('$home/Library/Application Support/Thusfar');
  }
  final String data = env['XDG_DATA_HOME'] ?? '$home/.local/share';
  return Directory('$data/thusfar');
}

/// Everything shared by the screens.
class AppModel {
  AppModel(
    this.root, {
    BookProcessing Function(Library library)? createProcessing,
  }) : library = Library(root),
       prefs = Prefs(File('${root.path}/app-prefs.json')),
       settings = ModelSettings(File('${root.path}/.model.env')) {
    SeenStore.instance.attach(File('${root.path}/seen.json'));
    applyModelEnvironment(settings);
    processing =
        createProcessing?.call(library) ?? ProcessingController(library);
  }

  final Directory root;
  final Library library;
  final Prefs prefs;
  final ModelSettings settings;
  late final BookProcessing processing;
  String? startupError;

  /// Worker startup stays deferred for widget fixtures. Production startup
  /// resumes an interrupted book only when its persisted auto flag permits it.
  Future<void> initialize() async {
    try {
      final int recovered = recoverPendingBackupMerges(root);
      if (recovered > 0) {
        startupError = '上次跨端合并中断，已恢复 $recovered 本书的本地记录。';
      }
    } on Object {
      startupError = '跨端合并恢复未完成。请保留书库和 sync-backups 备份，检查存储空间后重启。';
      await library.scan();
      return;
    }
    await library.scan();
    try {
      await processing.initialize();
    } on Object {
      startupError = '整理任务暂时无法启动，请检查书籍数据后重试。';
    }
  }

  void dispose() {
    processing.dispose();
    prefs.dispose();
    library.dispose();
  }
}

class ThusfarApp extends StatelessWidget {
  const ThusfarApp({super.key, required this.model});

  final AppModel model;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model.prefs,
      builder: (BuildContext context, _) => MaterialApp(
        title: '页读',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: switch (model.prefs.night) {
          NightMode.always => ThemeMode.dark,
          NightMode.never => ThemeMode.light,
          NightMode.system => ThemeMode.system,
        },
        home: HomeShell(model: model),
      ),
    );
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.model});

  final AppModel model;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _ImportSource {
  const _ImportSource({
    required this.name,
    this.path,
    this.bytes,
    this.error,
    this.temporary = false,
  });

  final String name;
  final String? path;
  final Uint8List? bytes;
  final String? error;
  final bool temporary;
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  static const MethodChannel _paths = MethodChannel('thusfar/paths');
  int tab = 0;
  final List<ImportItem> imports = <ImportItem>[];
  String? flashId;
  Future<void> _importTail = Future<void>.value();
  Future<void>? _resumeRefresh;
  Future<void>? _backgroundResume;
  Timer? _importFeedback;
  Timer? _updatePromptRetry;
  final Set<String> _notifiedBooks = <String>{};
  final Map<String, String> _notificationStamps = <String, String>{};
  bool _notificationSyncBusy = false;
  bool _notificationSyncPending = false;
  bool _appResumed = true;
  bool _readingShares = false;
  bool _sharesAgain = false;
  bool _checkingUpdates = false;
  ReleaseUpdate? _pendingUpdate;

  AppModel get m => widget.model;

  @override
  void initState() {
    super.initState();
    m.library.addListener(_changed);
    m.processing.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    ProcessingNotificationBridge.onOpenBook(_openProcessingNotification);
    ProcessingNotificationBridge.onBackgroundTimeLimit(
      _handleBackgroundTimeLimit,
    );
    _paths.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'importsAvailable') await _takeSharedImports();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_takeSharedImports());
      if (mounted) unawaited(_checkForUpdates());
      if (mounted) unawaited(_takeProcessingNotification());
      if (mounted) {
        unawaited(
          _takeBackgroundTimeLimit().whenComplete(
            _resumeBackgroundLimitedBooks,
          ),
        );
      }
    });
    if (m.startupError != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(m.startupError!)));
        }
      });
    }
  }

  @override
  void dispose() {
    m.library.removeListener(_changed);
    m.processing.removeListener(_changed);
    WidgetsBinding.instance.removeObserver(this);
    ProcessingNotificationBridge.onOpenBook(null);
    ProcessingNotificationBridge.onBackgroundTimeLimit(null);
    _paths.setMethodCallHandler(null);
    _importFeedback?.cancel();
    _updatePromptRetry?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      unawaited(
        _refreshLibraryOnResume().then((_) => _resumeBackgroundLimitedBooks()),
      );
      unawaited(_checkForUpdates());
      _queueNotificationSync();
    }
    if (state == AppLifecycleState.detached) {
      unawaited(m.processing.close().catchError((Object _) {}));
    }
  }

  Future<void> _checkForUpdates({bool manual = false}) async {
    if (_checkingUpdates) return;
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (!manual && now - m.prefs.updateCheckedAt < 24 * 60 * 60 * 1000) {
      return;
    }
    _checkingUpdates = true;
    try {
      final String? installed = await installedAppVersion();
      if (!mounted) return;
      if (installed == null) {
        if (manual) _updateMessage('无法读取当前安装版本');
        return;
      }
      final ReleaseUpdate? update = await checkForUpdate(installed);
      if (!mounted) return;
      m.prefs.update((Prefs p) {
        p.updateCheckedAt = DateTime.now().millisecondsSinceEpoch;
      });
      if (update == null) {
        if (manual) _updateMessage('当前已经是最新正式版');
        return;
      }
      if (!manual && m.prefs.dismissedUpdateTag == update.tag) return;
      _pendingUpdate = update;
      WidgetsBinding.instance.addPostFrameCallback((_) => _presentUpdate());
    } on Object {
      if (manual && mounted) _updateMessage('暂时无法检查更新，请稍后再试');
    } finally {
      _checkingUpdates = false;
    }
  }

  void _updateMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  void _presentUpdate() {
    final ReleaseUpdate? update = _pendingUpdate;
    if (!mounted || update == null) {
      return;
    }
    if (ModalRoute.of(context)?.isCurrent != true) {
      _updatePromptRetry?.cancel();
      _updatePromptRetry = Timer(const Duration(seconds: 1), _presentUpdate);
      return;
    }
    _updatePromptRetry?.cancel();
    _pendingUpdate = null;
    unawaited(_showUpdate(update));
  }

  Future<void> _showUpdate(ReleaseUpdate update) async {
    final bool? open = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('发现新版本'),
        content: Text('GitHub 已发布页读 ${update.tag}。现在查看更新内容吗？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('查看发布页'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (open != true) return;
    m.prefs.update((Prefs p) => p.dismissedUpdateTag = update.tag);
    try {
      if (!await launchUrl(update.page, mode: LaunchMode.externalApplication)) {
        throw const FormatException('No browser available');
      }
    } on Object {
      await Clipboard.setData(ClipboardData(text: update.page.toString()));
      if (mounted) _updateMessage('无法打开浏览器，发布页地址已复制');
    }
  }

  Future<void> _refreshLibraryOnResume() => _resumeRefresh ??= (() async {
    try {
      // Another activity or an external restore may have changed durable data
      // while this widget retained its old shelf. Finish this activity's import
      // first, then refresh existing entry objects so open readers stay attached.
      await _importTail;
      if (mounted) await m.library.scan();
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('书架暂时无法刷新，请检查书籍文件后重新打开应用。')),
        );
      }
    }
  })().whenComplete(() => _resumeRefresh = null);

  /// A dataSync background time limit pauses requests. Once the app is
  /// foreground again, the saved pause cause shows that the user did not ask
  /// to stop, so the original processing intent can be resumed safely.
  Future<void> _resumeBackgroundLimitedBooks() =>
      _backgroundResume ??= Future<void>.microtask(() async {
        if (!mounted || !_appResumed || !m.settings.hasKey) return;
        for (final BookEntry book in List<BookEntry>.of(m.library.books)) {
          if (!mounted || !_appResumed) return;
          m.library.refreshStatus(book);
          if (!book.status.isPaused ||
              book.status.raw['pause_reason'] != 'background_time_limit') {
            continue;
          }
          try {
            await m.processing.startBook(book);
          } on Object {
            // The visible task state retains the reason if startup fails.
          }
        }
      }).whenComplete(() => _backgroundResume = null);

  void _changed() {
    if (mounted) {
      setState(() {});
      _queueNotificationSync();
      // Cancellation can settle after the first foreground scan. The worker
      // refresh is the authoritative transition from cancelling to paused.
      if (_appResumed &&
          _backgroundResume == null &&
          m.library.books.any(
            (BookEntry book) =>
                book.status.isPaused &&
                book.status.raw['pause_reason'] == 'background_time_limit',
          )) {
        unawaited(_resumeBackgroundLimitedBooks());
      }
    }
  }

  Future<void> _openProcessingNotification(String bookId) async {
    if (!mounted) return;
    final BookEntry? book = m.library.byId(bookId);
    if (book != null) openDrawer(book, focus: true);
  }

  Future<void> _takeProcessingNotification() async {
    try {
      final String? bookId =
          await ProcessingNotificationBridge.takeOpenedBookId();
      if (bookId != null) await _openProcessingNotification(bookId);
    } on Object {
      // A notification may arrive while the Android channel is being set up.
    }
  }

  Future<void> _takeBackgroundTimeLimit() async {
    try {
      final List<String> ids =
          await ProcessingNotificationBridge.takeBackgroundTimeLimitBookIds();
      if (ids.isNotEmpty) await _handleBackgroundTimeLimit(ids);
    } on Object {
      // The task state remains visible from the library if Android is offline.
    }
  }

  Future<void> _handleBackgroundTimeLimit(List<String> bookIds) async {
    bool affected = false;
    for (final String id in bookIds.toSet()) {
      final BookEntry? book = m.library.byId(id);
      if (book == null) continue;
      m.library.refreshStatus(book);
      if (!book.status.isRunning) continue;
      affected = true;
      try {
        await m.processing.pauseForBackgroundLimit(book);
      } on Object {
        // The worker may already have stopped; its durable status is read below.
      }
      m.library.refreshStatus(book);
    }
    if (mounted && affected) {
      _queueNotificationSync();
      _updateMessage('系统后台整理时段已结束。请打开整理任务查看状态后继续。');
    }
  }

  void _queueNotificationSync() {
    _notificationSyncPending = true;
    if (_notificationSyncBusy) return;
    unawaited(_syncNotifications());
  }

  Future<void> _syncNotifications() async {
    _notificationSyncBusy = true;
    try {
      while (_notificationSyncPending && mounted) {
        _notificationSyncPending = false;
        final Map<String, Object?> health = m.processing.health;
        final Set<String> owned = <String>{
          if (health['current'] is String) health['current']! as String,
          for (final Object? id
              in (health['queued'] as List<Object?>?) ?? const [])
            if (id is String) id,
        };
        final Map<String, BookEntry> active = <String, BookEntry>{
          if (health['alive'] == true)
            for (final BookEntry book in m.library.books)
              if (book.status.isActive && owned.contains(book.id))
                book.id: book,
        };
        for (final String id in _notifiedBooks.toList()) {
          if (active.containsKey(id)) continue;
          await ProcessingNotificationBridge.stop(id);
          _notifiedBooks.remove(id);
          _notificationStamps.remove(id);
        }
        for (final BookEntry book in active.values) {
          final ProcessStatus status = book.status;
          final String notice = status.notice ?? '';
          final String phase = status.state == 'queued'
              ? 'queued'
              : status.state == 'finalizing'
              ? 'finalizing'
              : notice.contains('等待') || notice.contains('模型')
              ? 'waiting'
              : status.done == 0
              ? 'preparing'
              : 'running';
          final String stamp =
              '$phase/${status.done}/${status.total}/${book.title}';
          if (_notificationStamps[book.id] == stamp) continue;
          try {
            if (_notifiedBooks.contains(book.id)) {
              final bool present = await ProcessingNotificationBridge.update(
                bookId: book.id,
                title: book.title,
                phase: phase,
                done: status.done,
                total: status.total,
              );
              if (!present) {
                _notifiedBooks.remove(book.id);
                _notificationStamps.remove(book.id);
                continue;
              }
            } else if (_appResumed) {
              await ProcessingNotificationBridge.start(
                bookId: book.id,
                title: book.title,
                phase: phase,
                done: status.done,
                total: status.total,
              );
              _notifiedBooks.add(book.id);
              // Permission approval can outlive the task that requested it.
              // Re-read durable status before leaving any notification up.
              _notificationSyncPending = true;
            } else {
              continue;
            }
            _notificationStamps[book.id] = stamp;
          } on Object {
            _notifiedBooks.remove(book.id);
            _notificationStamps.remove(book.id);
          }
        }
      }
    } finally {
      _notificationSyncBusy = false;
    }
  }

  static const List<NavigationDestination> _destinations =
      <NavigationDestination>[
        NavigationDestination(
          icon: Icon(Icons.auto_stories_outlined),
          selectedIcon: Icon(Icons.auto_stories),
          label: '书架',
        ),
        NavigationDestination(
          icon: Icon(Icons.edit_note_outlined),
          selectedIcon: Icon(Icons.edit_note),
          label: '摘记',
        ),
        NavigationDestination(
          icon: Icon(Icons.tune_outlined),
          selectedIcon: Icon(Icons.tune),
          label: '设置',
        ),
      ];

  void _selectTab(int index) {
    if (tab != index) HapticFeedback.selectionClick();
    setState(() => tab = index);
  }

  Widget _navigationRail(Tokens t) => NavigationRail(
    backgroundColor: t.sheet,
    selectedIndex: tab,
    onDestinationSelected: _selectTab,
    labelType: NavigationRailLabelType.all,
    indicatorColor: t.qingSoft,
    selectedIconTheme: IconThemeData(color: t.qing, size: 24),
    unselectedIconTheme: IconThemeData(color: t.ink3, size: 22),
    selectedLabelTextStyle: TextStyle(
      color: t.qing,
      fontSize: 12,
      fontWeight: FontWeight.w700,
    ),
    unselectedLabelTextStyle: TextStyle(color: t.ink3, fontSize: 11),
    destinations: const <NavigationRailDestination>[
      NavigationRailDestination(
        icon: Icon(Icons.auto_stories_outlined),
        selectedIcon: Icon(Icons.auto_stories),
        label: Text('书架'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.edit_note_outlined),
        selectedIcon: Icon(Icons.edit_note),
        label: Text('摘记'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.tune_outlined),
        selectedIcon: Icon(Icons.tune),
        label: Text('设置'),
      ),
    ],
  );

  Widget _foldableNavigation(Tokens t) {
    const List<(IconData, String)> destinations = <(IconData, String)>[
      (Icons.auto_stories_outlined, '书架'),
      (Icons.edit_note_outlined, '摘记'),
      (Icons.tune_outlined, '设置'),
    ];
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int index = 0; index < destinations.length; index++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Material(
                color: index == tab ? t.qingSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  key: ValueKey<String>('foldable-nav-$index'),
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _selectTab(index),
                  child: SizedBox(
                    width: 68,
                    height: 68,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Icon(
                          destinations[index].$1,
                          color: index == tab ? t.qing : t.ink2,
                          size: 24,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          destinations[index].$2,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: index == tab
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: index == tab ? t.qing : t.ink2,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _foldableShelfCompanion(Tokens t) {
    BookEntry? featured;
    Progress? progress;
    double latest = -1;
    for (final BookEntry book in m.library.books) {
      final Progress? candidate = m.library.progressOf(book.id);
      if (candidate != null && candidate.pct < 99.5 && candidate.t > latest) {
        latest = candidate.t;
        featured = book;
        progress = candidate;
      }
    }
    if (featured == null && m.library.books.isNotEmpty) {
      featured = m.library.books.first;
    }
    final BookEntry? book = featured;
    return ColoredBox(
      color: t.paper,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                progress == null ? '从这里开始' : '正在阅读',
                style: TextStyle(fontSize: 13, color: t.ink3),
              ),
              const SizedBox(height: 14),
              if (book != null)
                Material(
                  color: t.sheet,
                  borderRadius: BorderRadius.circular(20),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    key: const ValueKey<String>('foldable-featured-book'),
                    onTap: () => openBook(book),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Center(child: BookCover(entry: book, width: 132)),
                          const SizedBox(height: 18),
                          Text(
                            book.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: display,
                              fontSize: 21,
                              color: t.ink,
                            ),
                          ),
                          if (book.author.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 4),
                            Text(
                              book.author,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 12, color: t.ink3),
                            ),
                          ],
                          if (progress != null) ...<Widget>[
                            const SizedBox(height: 16),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: LinearProgressIndicator(
                                value: progress.pct / 100,
                                minHeight: 5,
                                color: t.zhu,
                                backgroundColor: t.rule,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              '已读 ${progress.pct.round()}%',
                              style: TextStyle(fontSize: 12, color: t.ink3),
                            ),
                          ],
                          const SizedBox(height: 16),
                          Row(
                            children: <Widget>[
                              Text(
                                progress == null ? '开始阅读' : '继续阅读',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: t.qing,
                                ),
                              ),
                              const Spacer(),
                              Icon(
                                Icons.arrow_forward,
                                size: 18,
                                color: t.qing,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else ...<Widget>[
                Text(
                  '选一本书，开始专注阅读。',
                  style: TextStyle(fontSize: 18, color: t.ink),
                ),
                const SizedBox(height: 20),
                OutlinedButton.icon(
                  onPressed: pickAndImport,
                  icon: const Icon(Icons.add),
                  label: const Text('导入书籍'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _takeSharedImports() async {
    _sharesAgain = true;
    if (_readingShares || !mounted) return;
    _readingShares = true;
    try {
      while (_sharesAgain && mounted) {
        _sharesAgain = false;
        List<Object?> raw = <Object?>[];
        try {
          raw =
              await _paths.invokeListMethod<Object?>('takeImports') ??
              <Object?>[];
        } on MissingPluginException {
          // Windows, Linux and widget fixtures have no native bridge.
        }
        final List<_ImportSource> sources = <_ImportSource>[
          for (final String path in launchFiles)
            _ImportSource(
              name: path.split(RegExp(r'[\\/]')).last,
              path: path,
              temporary: false,
            ),
        ];
        launchFiles.clear();
        for (final Object? value in raw) {
          if (value is! Map<Object?, Object?> ||
              value['name'] is! String ||
              (value['path'] is! String && value['error'] is! String)) {
            throw const FormatException('分享文件信息不完整');
          }
          sources.add(
            _ImportSource(
              name: value['name']! as String,
              path: value['path'] as String?,
              error: value['error'] as String?,
              // Android copies shares into its cache; a Finder-opened book
              // is the reader's own file.
              temporary: value['temporary'] as bool? ?? true,
            ),
          );
        }
        if (sources.isNotEmpty) await _enqueueImport(sources);
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('无法接收分享的文件，请重新分享或从书架导入。')));
      }
    } finally {
      _readingShares = false;
    }
  }

  Future<void> _enqueueImport(
    List<_ImportSource> sources, {
    bool backupsOnly = false,
  }) {
    final Future<void> task = _importTail.then(
      (_) => _importBatch(sources, backupsOnly: backupsOnly),
    );
    // A failed batch must not block the next explicit import.
    _importTail = task.catchError((Object _) {});
    return task;
  }

  Future<void> openBook(BookEntry b, {int? at, bool notes = false}) async {
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (BuildContext context, _, _) => ReaderScreen(
          library: m.library,
          entry: b,
          prefs: m.prefs,
          settings: m.settings,
          processing: m.processing,
          onModelSettings: openModelSettings,
          onExport: exportBook,
          openAt: at,
          openNotes: notes,
        ),
        transitionsBuilder:
            (BuildContext context, Animation<double> a, _, Widget child) =>
                FadeTransition(
                  opacity: CurvedAnimation(parent: a, curve: Curves.easeOut),
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.96, end: 1).animate(
                      CurvedAnimation(parent: a, curve: Curves.easeOutCubic),
                    ),
                    child: child,
                  ),
                ),
      ),
    );
    if (mounted) {
      setState(() {});
      WidgetsBinding.instance.addPostFrameCallback((_) => _presentUpdate());
    }
  }

  Future<void> openModelSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (_) => ModelSettingsScreen(settings: m.settings),
      ),
    );
    applyModelEnvironment(m.settings);
    if (mounted) setState(() {});
  }

  Future<void> openWebDav() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => WebDavScreen(library: m.library)),
    );
    if (mounted) setState(() {});
  }

  void openDrawer(BookEntry b, {bool focus = false}) {
    BookSheet.open(
      context,
      BookSheet(
        library: m.library,
        entry: b,
        settings: m.settings,
        processing: m.processing,
        onRead: () {
          Navigator.of(context).pop();
          openBook(b);
        },
        onNotes: () {
          Navigator.of(context).pop();
          openBook(b, notes: true);
        },
        onModelSettings: openModelSettings,
        onExport: () => exportBook(b),
        focusProcessing: focus,
      ),
    );
  }

  Future<void> exportBook(BookEntry b) async {
    String message;
    try {
      final Uint8List bytes = exportBook0(b);
      final String? path = await FilePicker.platform.saveFile(
        dialogTitle: '导出完整备份',
        fileName: '${b.title}.yedu.json',
        bytes: bytes,
      );
      message = path == null ? '没有导出' : '已导出《${b.title}》';
    } on PyException catch (error) {
      message = error.message;
    } on Object {
      message = '导出没有完成，请检查书籍文件和可用存储空间后重试。';
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Uint8List exportBook0(BookEntry b) => exportBookBytes(m.library, b);

  Future<void> exportAll() async {
    for (final BookEntry b in m.library.books) {
      await exportBook(b);
    }
  }

  Future<void> pickAndImport({bool backupsOnly = false}) async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
      type: FileType.any,
    );
    if (result == null || result.files.isEmpty) return;
    await _enqueueImport(<_ImportSource>[
      for (final PlatformFile file in result.files)
        _ImportSource(name: file.name, path: file.path, bytes: file.bytes),
    ], backupsOnly: backupsOnly);
  }

  Future<void> _importBatch(
    List<_ImportSource> sources, {
    bool backupsOnly = false,
  }) async {
    if (!mounted) return;
    _importFeedback?.cancel();
    final List<ImportItem> batch = <ImportItem>[
      for (final _ImportSource f in sources) ImportItem(f.name),
    ];
    setState(() {
      imports
        ..clear()
        ..addAll(batch);
    });
    for (int i = 0; i < sources.length; i++) {
      final _ImportSource f = sources[i];
      final ImportItem item = batch[i];
      final String lower = f.name.toLowerCase();
      try {
        if (f.error != null) {
          item.error = f.error;
          continue;
        }
        final Uint8List? bytes =
            f.bytes ??
            (f.path == null ? null : File(f.path!).readAsBytesSync());
        if (bytes == null || bytes.isEmpty) {
          item.error = '文件是空的';
        } else if (lower.endsWith('.json')) {
          final ImportResult r = restoreBackup(m.library, f.name, bytes);
          item
            ..error = r.error
            ..bookId = r.id
            ..existed = r.existed
            ..progress = 1;
        } else if (lower.endsWith('.mobi') ||
            lower.endsWith('.azw3') ||
            lower.endsWith('.azw')) {
          item.error = 'MOBI 请先转成 EPUB';
        } else if (backupsOnly) {
          item.error = '这不是页读的 JSON 备份文件';
        } else if (lower.endsWith('.txt') || lower.endsWith('.epub')) {
          item.progress = 0.3;
          if (mounted) setState(() {});
          final ImportResult r = await importBookFile(m.library, f.name, bytes);
          item
            ..error = r.error
            ..bookId = r.id
            ..existed = r.existed
            ..progress = 1;
        } else {
          item.error = '支持 TXT、EPUB';
        }
      } on PyException catch (error) {
        item.error = error.message;
      } on Object {
        item.error = '无法导入这个文件，请检查文件内容和存储空间后重试。';
      } finally {
        if (f.temporary && f.path != null) {
          try {
            final File cached = File(f.path!);
            if (cached.existsSync()) cached.deleteSync();
          } on FileSystemException {
            // Import outcome is independent of temporary cache cleanup.
          }
        }
        if (mounted) setState(() {});
      }
    }
    await m.library.scan();
    final ImportItem? firstNew = batch
        .where(
          (ImportItem i) => i.error == null && !i.existed && i.bookId != null,
        )
        .firstOrNull;
    if (!mounted) return;
    if (firstNew != null) HapticFeedback.mediumImpact();
    setState(() => flashId = firstNew?.bookId);
    _importFeedback = Timer(const Duration(seconds: 3), () {
      if (mounted &&
          batch.every((ImportItem i) => i.error == null && !i.existed)) {
        setState(imports.clear);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final List<Widget> pages = <Widget>[
      ShelfScreen(
        library: m.library,
        prefs: m.prefs,
        imports: imports,
        onOpen: (BookEntry b) => openBook(b),
        onDrawer: openDrawer,
        onImport: pickAndImport,
        onRestore: () => pickAndImport(backupsOnly: true),
        onModelSettings: openModelSettings,
        flashId: flashId,
      ),
      NotesScreen(
        library: m.library,
        onOpenAt: (BookEntry b, int at) => openBook(b, at: at),
      ),
      SettingsScreen(
        library: m.library,
        prefs: m.prefs,
        settings: m.settings,
        onModel: openModelSettings,
        onExportAll: exportAll,
        onRestore: () => pickAndImport(backupsOnly: true),
        onWebDav: () => openWebDav(),
        onCheckUpdate: () => unawaited(_checkForUpdates(manual: true)),
      ),
    ];
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final MediaQueryData media = MediaQuery.of(context);
    final bool verticalSplit = media.displayFeatures.any(
      (DisplayFeature feature) =>
          feature.bounds.height >= media.size.height * .85 &&
          feature.bounds.width < media.size.width * .4,
    );
    final bool horizontalSplit = media.displayFeatures.any(
      (DisplayFeature feature) =>
          feature.bounds.width >= media.size.width * .85 &&
          feature.bounds.height < media.size.height * .4,
    );
    final Widget pageStack = IndexedStack(index: tab, children: pages);
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.digit1, control: true): () =>
            _selectTab(0),
        const SingleActivator(LogicalKeyboardKey.digit1, meta: true): () =>
            _selectTab(0),
        const SingleActivator(LogicalKeyboardKey.digit2, control: true): () =>
            _selectTab(1),
        const SingleActivator(LogicalKeyboardKey.digit2, meta: true): () =>
            _selectTab(1),
        const SingleActivator(LogicalKeyboardKey.digit3, control: true): () =>
            _selectTab(2),
        const SingleActivator(LogicalKeyboardKey.digit3, meta: true): () =>
            _selectTab(2),
        const SingleActivator(LogicalKeyboardKey.comma, control: true): () =>
            _selectTab(2),
        const SingleActivator(LogicalKeyboardKey.comma, meta: true): () =>
            _selectTab(2),
        const SingleActivator(LogicalKeyboardKey.keyO, control: true):
            pickAndImport,
        const SingleActivator(LogicalKeyboardKey.keyO, meta: true):
            pickAndImport,
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          statusBarColor: t.paper,
          statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
          systemNavigationBarColor: t.sheet,
          systemNavigationBarIconBrightness: dark
              ? Brightness.light
              : Brightness.dark,
          systemNavigationBarDividerColor: t.rule,
          systemStatusBarContrastEnforced: false,
          systemNavigationBarContrastEnforced: false,
        ),
        child: Scaffold(
          body: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final Size window = Size(
                constraints.maxWidth,
                constraints.maxHeight,
              );
              final DisplayFeature? verticalHinge = media.displayFeatures
                  .where(
                    (DisplayFeature feature) =>
                        feature.bounds.height >= window.height * .85 &&
                        feature.bounds.width < window.width * .4,
                  )
                  .firstOrNull;
              final DisplayFeature? horizontalHinge = media.displayFeatures
                  .where(
                    (DisplayFeature feature) =>
                        feature.bounds.width >= window.width * .85 &&
                        feature.bounds.height < window.height * .4,
                  )
                  .firstOrNull;
              if (verticalHinge != null && window.width >= 600) {
                final double leftWidth = verticalHinge.bounds.left
                    .clamp(0, window.width)
                    .toDouble();
                final double hingeRight = verticalHinge.bounds.right
                    .clamp(leftWidth, window.width)
                    .toDouble();
                final double rightWidth = window.width - hingeRight;
                final double railWidth = (leftWidth >= 300 ? 80.0 : 68.0)
                    .clamp(0, leftWidth)
                    .toDouble();
                final double companionWidth = leftWidth - railWidth;
                return Row(
                  children: <Widget>[
                    SizedBox(
                      width: railWidth,
                      height: window.height,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: t.sheet,
                          border: Border(
                            right: BorderSide(color: t.rule, width: .5),
                          ),
                        ),
                        child: SafeArea(child: _foldableNavigation(t)),
                      ),
                    ),
                    SizedBox(
                      width: companionWidth,
                      height: window.height,
                      child: companionWidth >= 220
                          ? _foldableShelfCompanion(t)
                          : ColoredBox(color: t.paper),
                    ),
                    SizedBox(width: verticalHinge.bounds.width),
                    SizedBox(
                      width: rightWidth,
                      height: window.height,
                      child: MediaQuery(
                        data: media.copyWith(
                          size: Size(rightWidth, window.height),
                          displayFeatures: const <DisplayFeature>[],
                        ),
                        child: pageStack,
                      ),
                    ),
                  ],
                );
              }
              if (horizontalHinge != null) {
                // Keep the active page on the upper display. The navigation bar
                // remains at the bottom, in the lower display, for tabletop use.
                final double upperHeight = horizontalHinge.bounds.top
                    .clamp(0, window.height)
                    .toDouble();
                return Align(
                  alignment: Alignment.topCenter,
                  child: SizedBox(
                    width: window.width,
                    height: upperHeight,
                    child: MediaQuery(
                      data: media.copyWith(
                        size: Size(window.width, upperHeight),
                        displayFeatures: const <DisplayFeature>[],
                      ),
                      child: pageStack,
                    ),
                  ),
                );
              }
              if (window.width >= 720) {
                return Row(
                  children: <Widget>[
                    SafeArea(child: _navigationRail(t)),
                    VerticalDivider(width: 1, color: t.rule),
                    Expanded(child: pageStack),
                  ],
                );
              }
              return pageStack;
            },
          ),
          bottomNavigationBar:
              verticalSplit || (media.size.width >= 720 && !horizontalSplit)
              ? null
              : NavigationBar(
                  height: 72,
                  backgroundColor: t.sheet,
                  selectedIndex: tab,
                  onDestinationSelected: _selectTab,
                  destinations: _destinations,
                ),
        ),
      ),
    );
  }
}
