import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/library.dart';
import '../data/model_settings.dart';
import '../data/prefs.dart';
import '../sheets/typography_sheet.dart';
import '../ui/device.dart';
import '../ui/theme.dart';
import 'recovery_screen.dart';
import 'background_processing_screen.dart';

/// S18 设置.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.library,
    required this.prefs,
    required this.settings,
    required this.onModel,
    required this.onExportAll,
    required this.onRestore,
    required this.onWebDav,
    required this.onCheckUpdate,
  });

  final Library library;
  final Prefs prefs;
  final ModelSettings settings;
  final VoidCallback onModel;
  final VoidCallback onExportAll;
  final VoidCallback onRestore;
  final VoidCallback onWebDav;
  final VoidCallback onCheckUpdate;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  Library get library => widget.library;
  Prefs get prefs => widget.prefs;
  ModelSettings get settings => widget.settings;
  VoidCallback get onModel => widget.onModel;
  VoidCallback get onExportAll => widget.onExportAll;
  VoidCallback get onRestore => widget.onRestore;
  VoidCallback get onWebDav => widget.onWebDav;
  VoidCallback get onCheckUpdate => widget.onCheckUpdate;

  int? _storageSize;
  bool _measuring = false;
  String? _storageError;
  Timer? _sizeRefresh;
  DateTime? _lastSizeRead;

  @override
  void initState() {
    super.initState();
    library.addListener(_queueSizeRefresh);
    unawaited(_readSize());
  }

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.library != library) {
      oldWidget.library.removeListener(_queueSizeRefresh);
      library.addListener(_queueSizeRefresh);
      _storageSize = null;
      _lastSizeRead = null;
      _queueSizeRefresh();
    }
  }

  @override
  void dispose() {
    library.removeListener(_queueSizeRefresh);
    _sizeRefresh?.cancel();
    super.dispose();
  }

  void _queueSizeRefresh() {
    // Processing updates can arrive many times a second. Keep its disk usage
    // current without walking the whole library for every UI notification.
    if (_sizeRefresh?.isActive ?? false) return;
    final Duration elapsed = _lastSizeRead == null
        ? const Duration(seconds: 30)
        : DateTime.now().difference(_lastSizeRead!);
    final Duration delay = elapsed >= const Duration(seconds: 30)
        ? const Duration(milliseconds: 400)
        : const Duration(seconds: 30) - elapsed;
    _sizeRefresh = Timer(delay, () => unawaited(_readSize()));
  }

  Future<void> _readSize() async {
    if (_measuring) {
      _queueSizeRefresh();
      return;
    }
    _measuring = true;
    final String path = library.root.path;
    try {
      final int size = await _measureStorage(path);
      if (mounted && path == library.root.path) {
        setState(() {
          _storageSize = size;
          _storageError = null;
          _lastSizeRead = DateTime.now();
        });
      }
    } on Object {
      if (mounted) setState(() => _storageError = '暂时无法计算，点击重试');
    } finally {
      _measuring = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final (_, String model, String key) = settings.read();
    // The first-run model form shows Gemini before anything is saved. Keep
    // this summary aligned with that visible starting choice.
    final String provider = settings.file.existsSync()
        ? settings.protocolLabel
        : 'Google Gemini';
    Widget group(String title, List<Widget> rows) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Row(
              children: <Widget>[
                Container(
                  width: 5,
                  height: 16,
                  decoration: BoxDecoration(
                    color: t.zhu,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: display,
                    fontSize: 15,
                    color: t.qing,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Material(
            color: t.sheet,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: BorderSide(color: t.rule.withValues(alpha: .75)),
            ),
            child: Column(
              children: <Widget>[
                for (int i = 0; i < rows.length; i++) ...<Widget>[
                  if (i > 0) Divider(height: 1, indent: 16, color: t.rule),
                  rows[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
    return Scaffold(
      backgroundColor: t.paper,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 840),
          child: ListenableBuilder(
            listenable: prefs,
            builder: (BuildContext context, _) => CustomScrollView(
              slivers: <Widget>[
                SliverAppBar.large(
                  backgroundColor: t.paper,
                  surfaceTintColor: Colors.transparent,
                  title: Text(
                    '设置',
                    style: TextStyle(fontFamily: display, color: t.ink),
                  ),
                ),
                SliverList.list(
                  children: <Widget>[
                    group('模型', <Widget>[
                      ListTile(
                        title: const Text('模型接口'),
                        subtitle: Text(
                          model.isEmpty
                              ? '$provider · 未配置模型'
                              : '$provider · ${model.split('+').first}',
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: key.isEmpty ? t.ink3 : t.ok,
                                shape: BoxShape.circle,
                              ),
                            ),
                            Icon(Icons.chevron_right, color: t.ink3),
                          ],
                        ),
                        onTap: () {
                          HapticFeedback.lightImpact();
                          onModel();
                        },
                      ),
                    ]),
                    if (Platform.isAndroid)
                      group('整理', <Widget>[
                        ListTile(
                          title: const Text('切到后台继续整理'),
                          subtitle: const Text('允许后台运行，查看手机的耗电设置'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) =>
                                  const BackgroundProcessingScreen(),
                            ),
                          ),
                        ),
                      ]),
                    group('阅读', <Widget>[
                      ListTile(
                        title: const Text('阅读排版'),
                        subtitle: Text(
                          '字号 ${prefs.fontSize.toStringAsFixed(1)} pt · '
                          '行距 ${prefs.lineHeight.toStringAsFixed(2)}×',
                        ),
                        trailing: Icon(Icons.chevron_right, color: t.ink3),
                        onTap: () {
                          HapticFeedback.selectionClick();
                          openTypography(context, prefs);
                        },
                      ),
                      ListTile(
                        title: const Text('翻页动画'),
                        trailing: DropdownButton<int>(
                          value: prefs.anim.index,
                          underline: const SizedBox.shrink(),
                          items: const <DropdownMenuItem<int>>[
                            DropdownMenuItem<int>(value: 0, child: Text('平移')),
                            DropdownMenuItem<int>(value: 1, child: Text('覆盖')),
                            DropdownMenuItem<int>(value: 2, child: Text('无')),
                          ],
                          onChanged: (int? v) {
                            HapticFeedback.selectionClick();
                            prefs.update(
                              (Prefs p) => p.anim = PageAnim.values[v ?? 0],
                            );
                          },
                        ),
                      ),
                      SwitchListTile(
                        title: const Text('音量键翻页'),
                        value: prefs.volumeKeys,
                        activeThumbColor: t.ink,
                        onChanged: (bool v) {
                          HapticFeedback.selectionClick();
                          prefs.update((Prefs p) => p.volumeKeys = v);
                        },
                      ),
                      ListTile(
                        title: const Text('夜间模式'),
                        trailing: DropdownButton<int>(
                          value: prefs.night.index,
                          underline: const SizedBox.shrink(),
                          items: const <DropdownMenuItem<int>>[
                            DropdownMenuItem<int>(
                              value: 0,
                              child: Text('跟随系统'),
                            ),
                            DropdownMenuItem<int>(value: 1, child: Text('总是')),
                            DropdownMenuItem<int>(value: 2, child: Text('从不')),
                          ],
                          onChanged: (int? v) {
                            HapticFeedback.selectionClick();
                            prefs.update(
                              (Prefs p) => p.night = NightMode.values[v ?? 0],
                            );
                          },
                        ),
                      ),
                    ]),
                    group('数据', <Widget>[
                      ListTile(
                        title: const Text('回收站'),
                        subtitle: const Text('恢复移除的书籍，或确认永久删除以释放空间'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => TrashScreen(library: library),
                          ),
                        ),
                      ),
                      ListTile(
                        title: const Text('未保存笔记草稿'),
                        subtitle: const Text('继续上次未保存的笔记或修改'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => NoteDraftsScreen(library: library),
                          ),
                        ),
                      ),
                      ListTile(
                        title: const Text('上次恢复报告'),
                        subtitle: const Text('逐本查看导入、合并、冲突与设置结果'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => RestoreReportView(
                              report: library.lastRestoreReport,
                            ),
                          ),
                        ),
                      ),
                      ListTile(
                        title: const Text('导出整个书库 ZIP'),
                        subtitle: const Text('一本文件带走书籍、摘记、阅读进度和设置'),
                        trailing: Icon(Icons.chevron_right, color: t.ink3),
                        onTap: () {
                          HapticFeedback.lightImpact();
                          onExportAll();
                        },
                      ),
                      ListTile(
                        title: const Text('导入书库或单书备份'),
                        subtitle: const Text('同一本书安全合并；独立 API 密钥需在新设备重填'),
                        trailing: Icon(Icons.chevron_right, color: t.ink3),
                        onTap: () {
                          HapticFeedback.lightImpact();
                          onRestore();
                        },
                      ),
                      ListTile(
                        title: const Text('WebDAV 同步'),
                        subtitle: const Text('将书籍快照上传到自己的云端，在其他设备导入'),
                        trailing: Icon(Icons.chevron_right, color: t.ink3),
                        onTap: onWebDav,
                      ),
                      ListTile(
                        title: const Text('占用空间'),
                        onTap: _readSize,
                        subtitle: Text(
                          _storageError ??
                              (_storageSize == null
                                  ? '正在计算…'
                                  : '${(_storageSize! / 1024 / 1024).toStringAsFixed(1)} MB · ${library.books.length} 本书'),
                          style: TextStyle(
                            color: t.ink3,
                            fontFeatures: const <FontFeature>[
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ),
                    ]),
                    group('关于', <Widget>[
                      const ListTile(
                        title: Text('版本'),
                        trailing: _InstalledVersion(),
                      ),
                      ListTile(
                        title: const Text('检查更新'),
                        subtitle: const Text('查看 GitHub 最新正式版'),
                        trailing: Icon(Icons.chevron_right, color: t.ink3),
                        onTap: onCheckUpdate,
                      ),
                      ListTile(
                        title: const Text('开源地址'),
                        subtitle: const Text('github.com/athemeroy/thusfar'),
                        trailing: Tooltip(
                          message: '复制开源地址',
                          child: Icon(
                            Icons.copy_outlined,
                            size: 16,
                            color: t.ink3,
                          ),
                        ),
                        onTap: () {
                          HapticFeedback.lightImpact();
                          Clipboard.setData(
                            const ClipboardData(
                              text: 'https://github.com/athemeroy/thusfar',
                            ),
                          );
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制开源地址')),
                          );
                        },
                      ),
                      ListTile(
                        title: const Text('字体授权'),
                        subtitle: const Text('霞鹜文楷屏幕阅读版 · SIL OFL 1.1'),
                        trailing: Icon(Icons.chevron_right, color: t.ink3),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const _FontLicenseScreen(),
                          ),
                        ),
                      ),
                      ListTile(
                        title: const Text('隐私'),
                        subtitle: Text(
                          '书和笔记保存在这台$deviceWord。整理、问书和 AI 批注会把所需原文发送到你配置的接口；测试连接会发送一条测试消息。导出和分享由你选择保存位置或接收方。',
                          style: TextStyle(color: t.ink2, height: 1.5),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 40),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<int> _measureStorage(String path) => Isolate.run(() {
  final Directory directory = Directory(path);
  if (!directory.existsSync()) return 0;
  int size = 0;
  for (final FileSystemEntity entity in directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is File) size += entity.lengthSync();
  }
  return size;
});

class _FontLicenseScreen extends StatelessWidget {
  const _FontLicenseScreen();

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    return Scaffold(
      backgroundColor: t.paper,
      appBar: AppBar(title: const Text('字体授权')),
      body: FutureBuilder<String>(
        future: rootBundle.loadString('assets/fonts/OFL-LXGWWenKaiScreen.txt'),
        builder: (BuildContext context, AsyncSnapshot<String> snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('暂时无法读取字体授权'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: SelectableText(
              snapshot.data!,
              style: TextStyle(color: t.ink, fontSize: 13, height: 1.5),
            ),
          );
        },
      ),
    );
  }
}

/// Read the installed package metadata so overridden build numbers stay honest.
class _InstalledVersion extends StatefulWidget {
  const _InstalledVersion();
  @override
  State<_InstalledVersion> createState() => _InstalledVersionState();
}

class _InstalledVersionState extends State<_InstalledVersion> {
  late final Future<String> version = _read();
  Future<String> _read() async {
    // Desktop and iOS builds get the exact version from the build command.
    const String built = String.fromEnvironment('THUSFAR_VERSION');
    if (built.isNotEmpty) return built;
    try {
      return await const MethodChannel(
            'thusfar/paths',
          ).invokeMethod<String>('appVersion') ??
          '版本未知';
    } on MissingPluginException {
      return '开发预览';
    } on PlatformException {
      return '版本未知';
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<String>(
    future: version,
    builder: (context, snapshot) => Text(
      snapshot.data ?? '读取中…',
      style: TextStyle(
        color: context.tk.ink3,
        fontSize: 13,
        fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
      ),
    ),
  );
}
