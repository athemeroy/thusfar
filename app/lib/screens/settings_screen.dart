import 'dart:io';

import 'package:flutter/material.dart';

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
    final (String url, String model, String key) = settings.read();
    final String host = Uri.tryParse(url)?.host ?? url;
    final String provider = host.contains('xiaojingai')
        ? '小鲸'
        : host.contains('deepseek')
        ? 'DeepSeek'
        : host;
    Widget group(String title, List<Widget> rows) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(title, style: TextStyle(fontSize: 13, color: t.ink3)),
          ),
          Material(
            color: t.raised,
            borderRadius: BorderRadius.circular(14),
            clipBehavior: Clip.antiAlias,
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
                    subtitle: Text('$provider · ${model.split('+').first}'),
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
                    trailing: Text('2.0.0-dev'),
                  ),
                  const ListTile(
                    title: Text('开源地址'),
                    subtitle: Text('github.com/athemeroy/thusfar'),
                  ),
                  ListTile(
                    title: const Text('隐私'),
                    subtitle: Text(
                      '书和笔记只存在这台手机。只有你点整理或问书时，才会连接你填写的接口。',
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
