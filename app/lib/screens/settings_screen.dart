import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/library.dart';
import '../data/model_settings.dart';
import '../data/prefs.dart';
import '../ui/theme.dart';

/// S18 设置.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    required this.library,
    required this.prefs,
    required this.settings,
    required this.onModel,
    required this.onExportAll,
    required this.onRestore,
  });

  final Library library;
  final Prefs prefs;
  final ModelSettings settings;
  final VoidCallback onModel;
  final VoidCallback onExportAll;
  final VoidCallback onRestore;

  int _size(Directory d) {
    int n = 0;
    if (!d.existsSync()) return 0;
    for (final FileSystemEntity e in d.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (e is File) n += e.lengthSync();
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final (_, String model, String key) = settings.read();
    final String provider = settings.protocolLabel;
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
      body: ListenableBuilder(
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
                    onTap: onModel,
                  ),
                ]),
                group('阅读', <Widget>[
                  ListTile(
                    title: const Text('默认字号'),
                    trailing: DropdownButton<int>(
                      value: prefs.fontSize.round(),
                      underline: const SizedBox.shrink(),
                      items: <DropdownMenuItem<int>>[
                        for (int s = 16; s <= 26; s++)
                          DropdownMenuItem<int>(value: s, child: Text('$s')),
                      ],
                      onChanged: (int? v) => prefs.update(
                        (Prefs p) => p.fontSize = (v ?? 19).toDouble(),
                      ),
                    ),
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
                      onChanged: (int? v) => prefs.update(
                        (Prefs p) => p.anim = PageAnim.values[v ?? 0],
                      ),
                    ),
                  ),
                  SwitchListTile(
                    title: const Text('音量键翻页'),
                    value: prefs.volumeKeys,
                    activeThumbColor: t.ink,
                    onChanged: (bool v) =>
                        prefs.update((Prefs p) => p.volumeKeys = v),
                  ),
                  ListTile(
                    title: const Text('夜间模式'),
                    trailing: DropdownButton<int>(
                      value: prefs.night.index,
                      underline: const SizedBox.shrink(),
                      items: const <DropdownMenuItem<int>>[
                        DropdownMenuItem<int>(value: 0, child: Text('跟随系统')),
                        DropdownMenuItem<int>(value: 1, child: Text('总是')),
                        DropdownMenuItem<int>(value: 2, child: Text('从不')),
                      ],
                      onChanged: (int? v) => prefs.update(
                        (Prefs p) => p.night = NightMode.values[v ?? 0],
                      ),
                    ),
                  ),
                ]),
                group('数据', <Widget>[
                  ListTile(
                    title: const Text('导出全部备份'),
                    trailing: Icon(Icons.chevron_right, color: t.ink3),
                    onTap: onExportAll,
                  ),
                  ListTile(
                    title: const Text('恢复备份'),
                    trailing: Icon(Icons.chevron_right, color: t.ink3),
                    onTap: onRestore,
                  ),
                  ListTile(
                    title: const Text('占用空间'),
                    trailing: Text(
                      '${(_size(library.root) / 1024 / 1024).toStringAsFixed(1)} MB · ${library.books.length} 本书',
                      style: TextStyle(color: t.ink3),
                    ),
                  ),
                ]),
                group('关于', <Widget>[
                  const ListTile(
                    title: Text('版本'),
                    trailing: _InstalledVersion(),
                  ),
                  const ListTile(
                    title: Text('开源地址'),
                    subtitle: Text('github.com/athemeroy/thusfar'),
                  ),
                  ListTile(
                    title: const Text('隐私'),
                    subtitle: Text(
                      '书和笔记保存在这台手机。整理、问书和 AI 批注会把所需原文发送到你配置的接口；测试连接会发送一条测试消息。导出和分享由你选择保存位置或接收方。',
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
    builder: (context, snapshot) => Text(snapshot.data ?? '读取中…'),
  );
}
