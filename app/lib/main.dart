import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'data/backup.dart';
import 'data/library.dart';
import 'data/model_settings.dart';
import 'data/prefs.dart';
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
  const String override = String.fromEnvironment('THUSFAR_DATA');
  // Same private directory the 1.7.x app used: files/yedu.
  final Directory root = override.isNotEmpty
      ? Directory(override)
      : Directory('${(await getApplicationSupportDirectory()).path}/yedu');
  root.createSync(recursive: true);
  final AppModel model = AppModel(root);
  await model.library.scan();
  runApp(ThusfarApp(model: model));
}

/// Everything shared by the screens.
class AppModel {
  AppModel(this.root)
    : library = Library(root),
      prefs = Prefs(File('${root.path}/app-prefs.json')),
      settings = ModelSettings(File('${root.path}/.model.env')) {
    SeenStore.instance.attach(File('${root.path}/seen.json'));
    applyModelEnvironment(settings);
  }

  final Directory root;
  final Library library;
  final Prefs prefs;
  final ModelSettings settings;
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

class _HomeShellState extends State<HomeShell> {
  int tab = 0;
  final List<ImportItem> imports = <ImportItem>[];
  String? flashId;

  AppModel get m => widget.model;

  @override
  void initState() {
    super.initState();
    m.library.addListener(_changed);
  }

  @override
  void dispose() {
    m.library.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> openBook(BookEntry b, {int? at}) async {
    await Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (BuildContext context, _, _) => ReaderScreen(
          library: m.library,
          entry: b,
          prefs: m.prefs,
          settings: m.settings,
          onModelSettings: openModelSettings,
          onExport: exportBook,
          openAt: at,
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
        onRead: () {
          Navigator.of(context).pop();
          openBook(b);
        },
        onModelSettings: openModelSettings,
        onExport: () => exportBook(b),
        focusProcessing: focus,
      ),
    );
  }

  Future<void> exportBook(BookEntry b) async {
    final Uint8List bytes = exportBook0(b);
    final String? path = await FilePicker.platform.saveFile(
      dialogTitle: '导出完整备份',
      fileName: '${b.title}.yedu.json',
      bytes: bytes,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(path == null ? '没有导出' : '已导出《${b.title}》')),
    );
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
    final List<ImportItem> batch = <ImportItem>[
      for (final PlatformFile f in result.files) ImportItem(f.name),
    ];
    setState(() {
      imports
        ..clear()
        ..addAll(batch);
    });
    for (int i = 0; i < result.files.length; i++) {
      final PlatformFile f = result.files[i];
      final ImportItem item = batch[i];
      final String lower = f.name.toLowerCase();
      final Uint8List? bytes =
          f.bytes ?? (f.path == null ? null : File(f.path!).readAsBytesSync());
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
        item.error = '这一版的 TXT/EPUB 解析器还在移植，先用备份导入';
      } else {
        item.error = '支持 TXT、EPUB';
      }
      setState(() {});
    }
    await m.library.scan();
    final ImportItem? firstNew = batch
        .where(
          (ImportItem i) => i.error == null && !i.existed && i.bookId != null,
        )
        .firstOrNull;
    setState(() => flashId = firstNew?.bookId);
    await Future<void>.delayed(const Duration(seconds: 3));
    if (mounted &&
        batch.every((ImportItem i) => i.error == null && !i.existed)) {
      setState(imports.clear);
    }
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
    return Scaffold(
      body: IndexedStack(index: tab, children: pages),
      bottomNavigationBar: NavigationBar(
        height: 64,
        backgroundColor: t.sheet,
        indicatorColor: t.zhuSoft.withValues(alpha: 0.6),
        selectedIndex: tab,
        onDestinationSelected: (int i) => setState(() => tab = i),
        destinations: const <NavigationDestination>[
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
        ],
      ),
    );
  }
}
