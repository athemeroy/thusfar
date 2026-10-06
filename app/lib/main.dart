import 'dart:async';
import 'dart:io';
import 'dart:ui' show DisplayFeature, DisplayFeatureType, DisplayFeatureState;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:thusfar_core/thusfar_core.dart' show PyException;
import 'package:thusfar_core/jobs.dart' show hasUnsettledModelRequests;
import 'package:url_launcher/url_launcher.dart';

import 'data/backup.dart';
import 'reader/tap_layout.dart';
import 'data/restore_report.dart';
import 'ui/restore_report_view.dart';
import 'data/library_zip.dart';
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
    _paths.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'importsAvailable') await _takeSharedImports();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_takeSharedImports());
      if (mounted) unawaited(_checkForUpdates());
      if (mounted) unawaited(_takeProcessingNotification());
      if (mounted) {
        unawaited(_resumeBackgroundLimitedBooks());
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
    _paths.setMethodCallHandler(null);
    _importFeedback?.cancel();
    _updatePromptRetry?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appResumed = state == AppLifecycleState.resumed;
    unawaited(ProcessingNotificationBridge.recordLifecycle(state.name));
    if (state == AppLifecycleState.resumed) {
      unawaited(
        _refreshLibraryOnResume().then((_) => _resumeBackgroundLimitedBooks()),
      );
      unawaited(_checkForUpdates());
    }
    // Android's app-owned engine can outlive every Activity/view. Detached
    // is not an instruction to cancel an authorized worker or its requests.
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
              hasUnsettledModelRequests(book.dir) ||
              !<String>{
                'background_time_limit',
                'background_unavailable',
              }.contains(book.status.raw['pause_reason'])) {
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
      // Cancellation can settle after the first foreground scan. The worker
      // refresh is the authoritative transition from cancelling to paused.
      if (_appResumed &&
          _backgroundResume == null &&
          m.library.books.any(
            (BookEntry book) =>
                book.status.isPaused &&
                !hasUnsettledModelRequests(book.dir) &&
                <String>{
                  'background_time_limit',
                  'background_unavailable',
                }.contains(book.status.raw['pause_reason']),
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

  Widget _bottomNavigation(Tokens t) => NavigationBar(
    height: 72,
    backgroundColor: t.sheet,
    selectedIndex: tab,
    onDestinationSelected: _selectTab,
    destinations: _destinations,
  );

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
      message = path == null
          ? '没有导出'
          : '已导出《${b.title}》，含本书规则和目录设置；全局规则请用整库 ZIP 或单独导出';
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

  Map<String, Object?> _libraryArchiveSettings() {
    final Prefs p = m.prefs;
    Map<String, Object?> transfer = <String, Object?>{};
    try {
      transfer = LibraryZipCodec.validatedSettings(
        readJson(File('${m.root.path}/library-settings-transfer.json')),
      );
    } on Object {
      // Optional cross-platform preferences never block the book archive.
    }
    final Map<String, Object?> oldReader =
        transfer['reader'] as Map<String, Object?>? ?? <String, Object?>{};
    final Map<String, Object?> settings = <String, Object?>{
      'reader': <String, Object?>{
        'fontSize': p.fontSize,
        'lineHeight': p.lineHeight,
        'letterSpacing': p.letterSpacing,
        'margin': p.pageHorizontalMargin,
        'paper': p.paper,
        'font': p.font,
        'pageMode': oldReader['pageMode'] ?? true,
        'columnWidth': oldReader['columnWidth'] ?? 960,
      },
      'native': <String, Object?>{
        'spacing': p.spacing,
        'pageHorizontalMargin': p.pageHorizontalMargin,
        'pageVerticalMargin': p.pageVerticalMargin,
        'anim': p.anim.index,
        'volumeKeys': p.volumeKeys,
        'tapLayout': p.tapLayout.toJson(),
        'paragraphSpacing': p.paragraphSpacing,
        'firstLineIndent': p.firstLineIndent,
        'night': p.night.index,
        'sort': p.sort,
        'listView': p.listView,
      },
      if (transfer['web'] is Map<String, Object?>) 'web': transfer['web'],
      'shelf': <String, Object?>{
        'readingQueue': <int>[
          ...<int>{
            for (final String id in m.library.readingList)
              if (m.library.books.indexWhere(
                    (BookEntry book) => book.id == id,
                  ) >=
                  0)
                m.library.books.indexWhere((BookEntry book) => book.id == id),
          },
        ],
      },
    };
    try {
      final (String url, String model, _) = m.settings.read();
      if (model.isNotEmpty) {
        settings['model'] =
            LibraryZipCodec.validatedModelProfile(<String, Object?>{
              'protocol': m.settings.protocol,
              'base_url': url,
              'model': model,
              'jev_route': m.settings.judgeRoute,
              'judge_url': m.settings.judgeUrl,
              'judge_model': m.settings.judgeModel,
            });
      }
    } on Object {
      // A private or invalid endpoint never prevents exporting the books.
    }
    return settings;
  }

  String? _applyLibraryArchiveSettings(Map<String, Object?> settings) {
    final Object? model = settings['model'];
    if (model is Map<String, Object?> && model.isNotEmpty) {
      final String? error = m.settings.save(
        url: model['base_url']! as String,
        model: model['model']! as String,
        key: '',
        clearKey: true,
        protocol: model['protocol']! as String,
        judgeRoute: model['jev_route'] as String?,
        judgeUrl: model['judge_url'] as String? ?? '',
        judgeModel: model['judge_model'] as String? ?? '',
        clearJudgeKey: true,
      );
      if (error != null) return error;
      applyModelEnvironment(m.settings);
    }
    final Map<String, Object?> reader =
        settings['reader'] as Map<String, Object?>? ?? <String, Object?>{};
    final Map<String, Object?> native =
        settings['native'] as Map<String, Object?>? ?? <String, Object?>{};
    m.prefs.update((Prefs p) {
      if (reader['fontSize'] is num) {
        p.fontSize = (reader['fontSize']! as num).toDouble().clamp(14, 32);
      }
      if (reader['lineHeight'] is num) {
        p.lineHeightOverride = (reader['lineHeight']! as num).toDouble();
      }
      if (reader['letterSpacing'] is num) {
        p.letterSpacing = (reader['letterSpacing']! as num).toDouble();
      }
      if (reader['font'] is num) p.font = (reader['font']! as num).toInt();
      if (reader['paper'] is num) p.paper = (reader['paper']! as num).toInt();
      if (native['spacing'] is num) {
        p.spacing = (native['spacing']! as num).toInt();
      }
      if (native['pageHorizontalMargin'] is num) {
        p.pageHorizontalMargin = (native['pageHorizontalMargin']! as num)
            .toDouble();
      } else if (reader['margin'] is num) {
        p.pageHorizontalMargin = (reader['margin']! as num).toDouble();
      }
      if (native['pageVerticalMargin'] is num) {
        p.pageVerticalMargin = (native['pageVerticalMargin']! as num)
            .toDouble();
      }
      if (native['anim'] is num) {
        p.anim = PageAnim.values[(native['anim']! as num).toInt()];
      }
      if (native['volumeKeys'] is bool) {
        p.volumeKeys = native['volumeKeys']! as bool;
      }
      if (native['paragraphSpacing'] is num) {
        p.paragraphSpacing = (native['paragraphSpacing']! as num).toDouble();
      }
      if (native['firstLineIndent'] is num) {
        p.firstLineIndent = (native['firstLineIndent']! as num).toDouble();
      }
      if (native['tapLayout'] != null) {
        p.tapLayout = ReaderTapLayout.fromJson(native['tapLayout']);
      }
      if (native['night'] is num) {
        p.night = NightMode.values[(native['night']! as num).toInt()];
      }
      if (native['sort'] is num) p.sort = (native['sort']! as num).toInt();
      if (native['listView'] is bool) {
        p.listView = native['listView']! as bool;
      }
    });
    try {
      writeJson(
        File('${m.root.path}/library-settings-transfer.json'),
        LibraryZipCodec.validatedSettings(settings),
      );
    } on Object {
      return '书籍与本机排版已恢复，跨端设置未能保存；请检查存储空间';
    }
    return null;
  }

  Future<void> exportAll() async {
    String message;
    try {
      final Uint8List bytes = exportLibraryZipBytes(
        m.library,
        _libraryArchiveSettings(),
      );
      final String date = DateTime.now().toIso8601String().substring(0, 10);
      final String? path = await FilePicker.platform.saveFile(
        dialogTitle: '导出整个书库 ZIP',
        fileName: '页读书库-$date.zip',
        bytes: bytes,
      );
      message = path == null
          ? '没有导出'
          : '已导出 ${m.library.books.length} 本书及设置；独立 API 密钥未包含，请妥善保管 ZIP';
    } on PyException catch (error) {
      message = error.message;
    } on Object catch (error) {
      message = error is FormatException
          ? error.message
          : '书库 ZIP 未能导出，请检查书籍文件和可用存储空间。';
    }
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
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
        } else if (lower.endsWith('.zip')) {
          final LibraryZipData archive = LibraryZipCodec.decode(bytes);
          final bool? applySettings = await showDialog<bool>(
            context: context,
            builder: (BuildContext dialogContext) => AlertDialog(
              title: const Text('恢复整个书库'),
              content: SingleChildScrollView(
                child: Text(
                  '${archive.books.map((bytes) => '• ${BackupSummary.read(bytes).title}').join('\n')}\n\n这份 ZIP 含 ${archive.books.length} 本书。相同书籍会安全合并；冲突不会覆盖本地。'
                  '独立填写的 API 密钥不在备份中；自定义模型地址可能含敏感路径，请妥善保管 ZIP。'
                  '已有书籍保留本机逐书整理和付费路由，继续前请核对。'
                  '本书规则和 TXT 修正目录随书恢复，现有规则顺序和启用选择保留；目录或规则冲突会停止该项。'
                  '${archive.customizations == null ? '' : '使用备份设置时，还会追加整库全局净化规则（影响所有书）；保留当前设置则不导入全局规则。'}'
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
          if (applySettings == null) {
            item.error = '已取消恢复';
          } else {
            final LibraryZipRestoreResult restored = restoreLibraryZipData(
              m.library,
              archive,
              applyRuleSettings: applySettings,
            );
            item
              ..bookId = restored.firstNewId
              ..existed = restored.imported == 0
              ..progress = 1;
            String settingsStatus = applySettings
                ? '因书籍冲突而跳过，当前设置保留；可处理冲突后重试'
                : '按你的选择保留当前设置';
            if (restored.failures.isNotEmpty) {
              item.error =
                  '已导入 ${restored.imported} 本，合并 ${restored.existing} 本；'
                  '${restored.failures.length} 本未导入。${applySettings ? '设置因存在冲突而未导入。' : '保留当前设置。'}详见设置 → 上次恢复报告。';
            } else if (restored.customizationError != null) {
              item.error = restored.customizationError;
              settingsStatus = '${restored.customizationError} 其他设置未更改。';
            } else {
              String? settingError;
              if (applySettings) {
                try {
                  settingError = _applyLibraryArchiveSettings(
                    restored.settings,
                  );
                  if (settingError == null) {
                    final Map<String, Object?> shelf =
                        restored.settings['shelf'] as Map<String, Object?>? ??
                        <String, Object?>{};
                    final List<int> queue =
                        (shelf['readingQueue'] as List<int>?) ?? <int>[];
                    if (queue.isNotEmpty) {
                      final List<String> incoming = <String>[
                        for (final int index in queue)
                          if (restored.ids[index] != null) restored.ids[index]!,
                      ];
                      m.library.setReadingList(
                        <String>{
                          ...incoming,
                          ...m.library.readingList,
                        }.toList(),
                      );
                    }
                  }
                } on Object {
                  settingError = '部分设置未能保存；请检查可用存储空间后重试';
                }
              }
              settingsStatus = settingError != null
                  ? '未完整恢复：$settingError'
                  : applySettings
                  ? '已导入阅读清单、排版、净化规则和模型设置；模型密钥需重填'
                  : '按你的选择保留当前设置';
              if (settingError != null) {
                item.error = '书籍已恢复 ${restored.total} 本，但设置未恢复：$settingError';
              }
            }
            final RestoreReport report = RestoreReport(
              created: DateTime.now(),
              entries: restored.entries,
              settingsStatus: settingsStatus,
            );
            bool reportSaved = true;
            try {
              m.library.saveRestoreReport(report);
            } on Object {
              reportSaved = false;
              item.error =
                  '${item.error ?? '书籍恢复已处理'}；恢复报告未能保存，请查看并保留完整结果，再检查存储空间。\n${restored.failures.join('\n')}';
            }
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  duration: const Duration(seconds: 10),
                  content: Text(
                    '${report.summary}。${reportSaved ? '完整报告可在设置中再次查看。' : '报告未能保存，请查看并保留结果。'}',
                  ),
                  action: SnackBarAction(
                    label: '查看报告',
                    onPressed: () {
                      if (!mounted) return;
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => RestoreReportView(report: report),
                        ),
                      );
                    },
                  ),
                ),
              );
            }
          }
        } else if (lower.endsWith('.json')) {
          final BackupSummary summary = BackupSummary.read(
            bytes,
            fallback: f.name,
          );
          if (summary.customizationSummary != null) {
            final ImportResult preview = restoreBackup(
              m.library,
              f.name,
              bytes,
              previewOnly: true,
            );
            if (preview.error != null) {
              item.error = preview.error;
              continue;
            }
            if (!mounted) return;
            final bool? confirmed = await showDialog<bool>(
              context: context,
              builder: (dialog) => AlertDialog(
                title: const Text('恢复单书备份'),
                content: SingleChildScrollView(
                  child: Text(
                    '${summary.title}\n\n${summary.customizationSummary}\n\n确认前不会修改本地。',
                  ),
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.pop(dialog, false),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(dialog, true),
                    child: const Text('确认恢复'),
                  ),
                ],
              ),
            );
            if (confirmed != true) {
              item.error = '已取消恢复';
              continue;
            }
          }
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
          item.error = '请选择页读 ZIP 书库或 JSON 单书备份';
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
          item.error = '支持 TXT、EPUB、ZIP 或 JSON 备份';
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
    bool separates(DisplayFeature feature) =>
        feature.type == DisplayFeatureType.hinge ||
        (feature.type == DisplayFeatureType.fold &&
            feature.state == DisplayFeatureState.postureHalfOpened);
    final bool verticalSplit = media.displayFeatures.any(
      (DisplayFeature feature) =>
          separates(feature) &&
          feature.bounds.height >= media.size.height * .85 &&
          feature.bounds.width < media.size.width * .4,
    );
    final bool horizontalSplit = media.displayFeatures.any(
      (DisplayFeature feature) =>
          separates(feature) &&
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
                        separates(feature) &&
                        feature.bounds.height >= window.height * .85 &&
                        feature.bounds.width < window.width * .4,
                  )
                  .firstOrNull;
              final DisplayFeature? horizontalHinge = media.displayFeatures
                  .where(
                    (DisplayFeature feature) =>
                        separates(feature) &&
                        feature.bounds.width >= window.width * .85 &&
                        feature.bounds.height < window.height * .4,
                  )
                  .firstOrNull;
              if (verticalHinge != null) {
                final double leftWidth = verticalHinge.bounds.left
                    .clamp(0, window.width)
                    .toDouble();
                final double hingeRight = verticalHinge.bounds.right
                    .clamp(leftWidth, window.width)
                    .toDouble();
                final double rightWidth = window.width - hingeRight;
                if (window.width < 600 || leftWidth < 80 || rightWidth < 240) {
                  // A narrow window or edge hinge cannot fit a separate rail.
                  // Keep the active page and all destinations in the larger pane.
                  final bool useRight = rightWidth >= leftWidth;
                  final double paneWidth = useRight ? rightWidth : leftWidth;
                  return Align(
                    alignment: useRight
                        ? Alignment.topRight
                        : Alignment.topLeft,
                    child: SizedBox(
                      key: const ValueKey<String>('foldable-compact-pane'),
                      width: paneWidth,
                      height: window.height,
                      child: ClipRect(
                        child: MediaQuery(
                          data: media.copyWith(
                            size: Size(paneWidth, window.height),
                            displayFeatures: const <DisplayFeature>[],
                            padding: media.padding.copyWith(
                              left: useRight ? 0 : media.padding.left,
                              right: useRight ? media.padding.right : 0,
                            ),
                            viewPadding: media.viewPadding.copyWith(
                              left: useRight ? 0 : media.viewPadding.left,
                              right: useRight ? media.viewPadding.right : 0,
                            ),
                          ),
                          child: Column(
                            children: <Widget>[
                              Expanded(child: pageStack),
                              _bottomNavigation(t),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }
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
              : _bottomNavigation(t),
        ),
      ),
    );
  }
}
