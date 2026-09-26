import 'dart:async';
import 'dart:io';
import 'dart:ui' show DisplayFeature;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:thusfar_core/thusfar_core.dart' show PyException;

import 'data/backup.dart';
import 'data/library.dart';
import 'data/model_settings.dart';
import 'data/prefs.dart';
import 'data/processing.dart';
import 'data/seen.dart';
import 'reader/reader_screen.dart';
import 'screens/model_settings_screen.dart';
import 'screens/notes_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/shelf_screen.dart';
import 'sheets/book_sheet.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Let Android resize and rotate the window for folded, unfolded, and
  // tabletop postures. Reader pagination follows the available pane size.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  const String override = String.fromEnvironment('THUSFAR_DATA');
  // Same private directory the 1.7.x app used: files/yedu.
  final Directory root = override.isNotEmpty
      ? Directory(override)
      : Directory(
          '${await const MethodChannel('thusfar/paths').invokeMethod<String>('filesDir')}/yedu',
        );
  root.createSync(recursive: true);
  final AppModel model = AppModel(root);
  await model.initialize();
  runApp(ThusfarApp(model: model));
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
  /// reconciles abandoned state; it does not restart paid work.
  Future<void> initialize() async {
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
  Timer? _importFeedback;
  bool _readingShares = false;
  bool _sharesAgain = false;

  AppModel get m => widget.model;

  @override
  void initState() {
    super.initState();
    m.library.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    _paths.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'importsAvailable') await _takeSharedImports();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_takeSharedImports());
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
    WidgetsBinding.instance.removeObserver(this);
    _paths.setMethodCallHandler(null);
    _importFeedback?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshLibraryOnResume());
    }
    if (state == AppLifecycleState.detached) {
      unawaited(m.processing.close().catchError((Object _) {}));
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

  void _changed() {
    if (mounted) setState(() {});
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

  void _selectTab(int index) => setState(() => tab = index);

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
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (int index = 0; index < destinations.length; index++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Material(
                  color: index == tab ? t.qingSoft : Colors.transparent,
                  borderRadius: BorderRadius.circular(18),
                  child: InkWell(
                    key: ValueKey<String>('foldable-nav-$index'),
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => _selectTab(index),
                    child: SizedBox(
                      height: 60,
                      child: Row(
                        children: <Widget>[
                          const SizedBox(width: 20),
                          Icon(
                            destinations[index].$1,
                            color: index == tab ? t.qing : t.ink2,
                            size: 23,
                          ),
                          const SizedBox(width: 14),
                          Text(
                            destinations[index].$2,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: index == tab
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: index == tab ? t.qing : t.ink2,
                            ),
                          ),
                          const Spacer(),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
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
        final List<Object?> raw =
            await _paths.invokeListMethod<Object?>('takeImports') ??
            <Object?>[];
        final List<_ImportSource> sources = <_ImportSource>[];
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
              temporary: true,
            ),
          );
        }
        if (sources.isNotEmpty) await _enqueueImport(sources);
      }
    } on MissingPluginException {
      // Desktop widget fixtures do not register Android's incoming-file bridge.
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
    if (mounted) setState(() {});
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
          item.error = '这不是页读的备份文件（.yedu.json）';
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
    return AnnotatedRegion<SystemUiOverlayStyle>(
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
              return Row(
                children: <Widget>[
                  SizedBox(
                    width: leftWidth,
                    height: window.height,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: t.sheet,
                        border: Border(
                          right: BorderSide(color: t.rule, width: .5),
                        ),
                      ),
                      child: SafeArea(
                        child: Column(
                          children: <Widget>[
                            const SizedBox(height: 20),
                            Text(
                              '页读',
                              style: TextStyle(
                                fontFamily: display,
                                fontSize: 26,
                                color: t.ink,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '只读到你这一页',
                              style: TextStyle(fontSize: 12, color: t.ink3),
                            ),
                            Expanded(child: _foldableNavigation(t)),
                            const SizedBox(height: 20),
                          ],
                        ),
                      ),
                    ),
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
    );
  }
}
