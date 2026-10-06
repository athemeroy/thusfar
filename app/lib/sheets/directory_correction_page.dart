import 'package:flutter/material.dart';

import '../data/library.dart';
import '../data/reader_directory.dart';
import '../data/seen.dart';
import '../ui/theme.dart';
import 'chapter_title.dart';
import 'common.dart';
import 'sheet_host.dart';

/// Local, reversible navigation repair. Preview never exposes unread titles.
class DirectoryCorrectionPage extends StatefulWidget {
  const DirectoryCorrectionPage({super.key, required this.link});
  final ReaderLink link;

  @override
  State<DirectoryCorrectionPage> createState() =>
      _DirectoryCorrectionPageState();
}

class _DirectoryCorrectionPageState extends State<DirectoryCorrectionPage> {
  late final ReaderDirectory _directory = widget.link.c.book.directory;
  late DirectoryRule _rule = _directory.rule;
  late final TextEditingController _prefix = TextEditingController(
    text: _directory.prefix,
  );
  DirectoryScan? _scan;
  DirectoryPreview? _preview;
  List<Chapter> _entries = <Chapter>[];
  String? _message;
  bool _confirmReset = false;
  final GlobalKey _previewHeading = GlobalKey();

  @override
  void dispose() {
    _scan?.cancel();
    _prefix.dispose();
    super.dispose();
  }

  void _clearPreview() {
    _scan?.cancel();
    _scan = null;
    _preview = null;
    _entries = <Chapter>[];
    _message = null;
    _confirmReset = false;
  }

  Future<void> _detect() async {
    FocusManager.instance.primaryFocus?.unfocus();
    _clearPreview();
    final DirectoryScan scan = DirectoryScan(
      widget.link.c.book.entry.dir.path,
      _rule,
      _prefix.text,
    );
    setState(() => _scan = scan);
    try {
      final DirectoryPreview? preview = await scan.result;
      if (!mounted || _scan != scan || preview == null) return;
      final List<Chapter> entries = preview.rows.isEmpty
          ? <Chapter>[]
          : _directory.previewEntries(preview.rows);
      setState(() {
        _preview = preview;
        _entries = entries;
        _message = preview.rows.isEmpty
            ? '没有找到标题。试试其他规则或固定前缀；只识别原文中的独立短段落'
            : null;
      });
      if (entries.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final BuildContext? heading = _previewHeading.currentContext;
          if (mounted && _preview == preview && heading != null) {
            Scrollable.ensureVisible(heading, alignment: .35);
          }
        });
      }
    } on Object catch (e) {
      if (mounted && _scan == scan) setState(() => _message = '$e');
    } finally {
      if (mounted && _scan == scan) setState(() => _scan = null);
    }
  }

  void _apply() {
    final DirectoryPreview? preview = _preview;
    if (preview == null) return;
    try {
      _directory.apply(preview);
      setState(() {
        _clearPreview();
        _message = '已应用到本书目录和章节查找';
      });
    } on FormatException catch (error) {
      setState(() => _message = error.message);
    } on Object catch (_) {
      setState(() => _message = '保存失败，当前目录未更改。请检查存储空间后重试');
    }
  }

  void _reset() {
    try {
      _directory.reset();
      setState(() {
        _clearPreview();
        _rule = DirectoryRule.automatic;
        _prefix.clear();
        _message = '已恢复导入时的原目录';
      });
    } on Object catch (_) {
      setState(() => _message = '恢复失败，现有目录未更改。请检查存储空间后重试');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[widget.link.c, _directory]),
    builder: (BuildContext context, _) {
      final Tokens t = context.tk;
      final BookData book = widget.link.c.book;
      final int read = SeenStore.instance.maxRead(
        book.id,
        widget.link.c.cutoff,
      );
      final bool busy = _scan != null;
      return SheetPage(
        title: '修正 TXT 目录',
        bottom: _preview == null
            ? null
            : Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 8,
                children: <Widget>[
                  TextButton(
                    onPressed: () => setState(_clearPreview),
                    child: const Text('取消预览'),
                  ),
                  if (_entries.isNotEmpty)
                    FilledButton(onPressed: _apply, child: const Text('应用目录')),
                ],
              ),
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    '修正本书的目录与章节查找，仅保存在本机。原文、阅读位置、摘记和人物资料保留；AI 整理仍按原章节进行，不会重新调用模型。',
                    style: TextStyle(fontSize: 14, height: 1.6, color: t.ink2),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '修正目录随单书导出、书库 ZIP 和 WebDAV 快照保存；恢复时核对原文，保留本机冲突目录',
                    style: TextStyle(fontSize: 12, height: 1.5, color: t.ink3),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _directory.enabled ? '当前使用：修正目录' : '当前使用：原目录',
                    style: TextStyle(color: t.ink, fontWeight: FontWeight.w600),
                  ),
                  if (_directory.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        _directory.error!,
                        style: TextStyle(color: t.danger),
                      ),
                    ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<DirectoryRule>(
                    key: const ValueKey<String>('directory-rule'),
                    initialValue: _rule,
                    isExpanded: true,
                    isDense: false,
                    itemHeight: null,
                    decoration: const InputDecoration(labelText: '识别规则'),
                    items: <DropdownMenuItem<DirectoryRule>>[
                      for (final DirectoryRule rule in DirectoryRule.values)
                        DropdownMenuItem(
                          value: rule,
                          child: Text(
                            rule.label,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (DirectoryRule? value) {
                            if (value == null) return;
                            setState(() {
                              _clearPreview();
                              _rule = value;
                            });
                          },
                  ),
                  if (_rule == DirectoryRule.prefix) ...<Widget>[
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey<String>('directory-prefix'),
                      controller: _prefix,
                      maxLength: 32,
                      enabled: !busy,
                      onChanged: (_) => setState(_clearPreview),
                      decoration: const InputDecoration(
                        labelText: '标题的固定前缀',
                        hintText: '例如：正文 第',
                        helperText: '按文字原样匹配，不支持正则表达式',
                        helperMaxLines: 3,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    '只检查不超过 120 字的独立段落，最多识别 10000 个标题。未读且未经核对的标题在预览和搜索中使用中性序号。',
                    style: TextStyle(fontSize: 12, height: 1.5, color: t.ink3),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton.icon(
                        onPressed: busy || !_directory.supportsCorrection
                            ? null
                            : _detect,
                        icon: const Icon(Icons.manage_search),
                        label: Text(busy ? '正在识别…' : '预览目录'),
                      ),
                      if (busy)
                        TextButton(
                          onPressed: () => setState(_clearPreview),
                          child: const Text('停止扫描'),
                        ),
                      if (_directory.enabled || _directory.error != null)
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => setState(() => _confirmReset = true),
                          child: const Text('恢复原目录'),
                        ),
                    ],
                  ),
                  if (_confirmReset) ...<Widget>[
                    const SizedBox(height: 8),
                    const Text('恢复导入时的目录？原文和阅读记录保持不变'),
                    Wrap(
                      spacing: 12,
                      children: <Widget>[
                        TextButton(
                          onPressed: _reset,
                          child: const Text('确认恢复'),
                        ),
                        TextButton(
                          onPressed: () =>
                              setState(() => _confirmReset = false),
                          child: const Text('取消恢复'),
                        ),
                      ],
                    ),
                  ],
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _message!,
                        key: const ValueKey<String>('directory-message'),
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: t.ink2,
                        ),
                      ),
                    ),
                  if (_entries.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: Text(
                        '预览共 ${_entries.length} 项 · ${_preview!.rule.label}',
                        key: _previewHeading,
                        style: TextStyle(
                          color: t.ink,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  TextButton(
                    onPressed: () => SheetScope.of(context).state.pop(),
                    child: const Text('返回目录'),
                  ),
                ],
              ),
            ),
          ),
          SliverList.builder(
            itemCount: _entries.length,
            itemBuilder: (BuildContext context, int i) {
              final Chapter chapter = _entries[i];
              return ListTile(
                key: ValueKey<String>('directory-preview-$i'),
                title: Text(
                  safeTitle(chapter, tocTitleRead(chapter, read)),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('目录第 ${i + 1} 项 · 原文位置 ${chapter.o0}'),
              );
            },
          ),
        ],
      );
    },
  );
}
