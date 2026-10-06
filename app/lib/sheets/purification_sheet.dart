import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/purification_store.dart';
import '../reader/text_purification.dart';
import 'sheet_host.dart';

const String _help =
    '只改变阅读显示，原书、摘记和引用保留原文。关闭或删除规则即可恢复。按原文从左到右匹配，同一位置优先使用靠前的规则，替换结果不会再次匹配。不跨段落，仅支持普通文字，不支持正则表达式。';

class PurificationPage extends StatelessWidget {
  const PurificationPage({
    super.key,
    required this.store,
    required this.bookId,
    required this.samples,
  });
  final PurificationStore store;
  final String bookId;
  final List<String> samples;

  void _notice(BuildContext context, String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _change(BuildContext context, VoidCallback action) {
    try {
      action();
    } on StateError catch (error) {
      _notice(context, error.message);
    } on Object {
      _notice(context, '规则未能保存，请检查存储空间后重试');
    }
  }

  Future<void> _export(BuildContext context) async {
    try {
      final String? path = await FilePicker.platform.saveFile(
        dialogTitle: '导出净化规则',
        fileName: 'thusfar-purification.json',
        type: FileType.custom,
        allowedExtensions: <String>['json'],
        bytes: Uint8List.fromList(utf8.encode(store.exportForBook(bookId))),
      );
      if (context.mounted && path != null) _notice(context, '规则已导出');
    } on Object {
      if (context.mounted) _notice(context, '规则未能导出，请检查存储空间后重试');
    }
  }

  Future<void> _import(BuildContext context) async {
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: <String>['json'],
        withData: false,
        withReadStream: true,
      );
      if (result == null || !context.mounted) return;
      final PlatformFile file = result.files.single;
      final Stream<List<int>> stream =
          file.readStream ?? File(file.path!).openRead();
      final String data = await readPurificationImport(
        stream,
        reportedSize: file.size,
      );
      final List<PurificationRule> rules = store.previewImport(data, bookId);
      if (!context.mounted) return;
      if (rules.isEmpty) {
        _notice(context, '没有新规则，相同规则已跳过');
        return;
      }
      final int global = rules.where((r) => r.bookId == null).length;
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (dialog) => AlertDialog(
          title: Text('导入 ${rules.length} 条规则？'),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    '追加到现有规则末尾，相同规则已跳过。本书规则用于当前这本书。${global > 0 ? '其中 $global 条全局规则会影响所有书籍。' : ''}',
                  ),
                  const SizedBox(height: 12),
                  for (final PurificationRule rule in rules)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        '${rule.enabled ? '' : '已停用 · '}${rule.bookId == null ? '全局' : '本书'}：${rule.find} → ${rule.replacement.isEmpty ? '删除' : rule.replacement}',
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('导入'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
      final int count = store.importForBook(data, bookId);
      _notice(context, '已导入 $count 条规则');
    } on FormatException catch (error) {
      if (context.mounted) _notice(context, error.message);
    } on Object {
      if (context.mounted) _notice(context, '规则未能导入，现有规则未更改');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final List<PurificationRule> rules = store.forBook(bookId);
      return SheetPage(
        title: '文本净化',
        slivers: <Widget>[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            sliver: SliverList.list(
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Expanded(child: Text('隐藏广告或修正错字。原书和摘记不变，停用规则即可恢复。')),
                    IconButton(
                      tooltip: '净化规则说明',
                      icon: const Icon(Icons.info_outline),
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (dialog) => AlertDialog(
                          title: const Text('净化规则说明'),
                          content: const Text(_help),
                          actions: <Widget>[
                            TextButton(
                              onPressed: () => Navigator.pop(dialog),
                              child: const Text('知道了'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (store.error != null) Text(store.error!),
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    FilledButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('添加规则'),
                      onPressed: store.error != null
                          ? null
                          : () => SheetScope.of(context).state.push(
                              PurificationEditor(
                                store: store,
                                bookId: bookId,
                                samples: samples,
                              ),
                            ),
                    ),
                    TextButton(
                      onPressed: store.error != null
                          ? null
                          : () => _import(context),
                      child: const Text('导入规则'),
                    ),
                    TextButton(
                      onPressed: rules.isEmpty ? null : () => _export(context),
                      child: const Text('导出规则'),
                    ),
                  ],
                ),
                const Text('单书备份含本书规则；全局规则请用整库 ZIP 或单独导出。独立规则文件仍可导入到另一本书。'),
                const SizedBox(height: 16),
                if (rules.isEmpty) const Text('还没有本书或全局规则。也可以长按选中文字，点“净化”添加。'),
                for (int i = 0; i < rules.length; i++)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              rules[i].find,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${rules[i].bookId == null ? '所有书籍' : '仅本书'} · ${rules[i].replacement.isEmpty ? '删除匹配文字' : '替换为：${rules[i].replacement}'}',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            value: rules[i].enabled,
                            onChanged: (enabled) => _change(
                              context,
                              () => store.put(
                                rules[i].copyWith(enabled: enabled),
                              ),
                            ),
                          ),
                          Wrap(
                            children: <Widget>[
                              TextButton(
                                onPressed: () =>
                                    SheetScope.of(context).state.push(
                                      PurificationEditor(
                                        store: store,
                                        bookId: bookId,
                                        samples: samples,
                                        rule: rules[i],
                                      ),
                                    ),
                                child: const Text('编辑与预览'),
                              ),
                              IconButton(
                                tooltip: '上移规则',
                                onPressed: i == 0
                                    ? null
                                    : () => _change(
                                        context,
                                        () =>
                                            store.move(rules[i].id, -1, bookId),
                                      ),
                                icon: const Icon(Icons.arrow_upward),
                              ),
                              IconButton(
                                tooltip: '下移规则',
                                onPressed: i + 1 == rules.length
                                    ? null
                                    : () => _change(
                                        context,
                                        () =>
                                            store.move(rules[i].id, 1, bookId),
                                      ),
                                icon: const Icon(Icons.arrow_downward),
                              ),
                              IconButton(
                                tooltip: '删除规则',
                                onPressed: () async {
                                  final PurificationRule rule = rules[i];
                                  final bool? confirmed =
                                      await showDialog<bool>(
                                        context: context,
                                        builder: (dialog) => AlertDialog(
                                          title: const Text('删除这条规则？'),
                                          content: Text(rule.find),
                                          actions: <Widget>[
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(dialog, false),
                                              child: const Text('取消'),
                                            ),
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(dialog, true),
                                              child: const Text('删除'),
                                            ),
                                          ],
                                        ),
                                      );
                                  if (confirmed == true && context.mounted) {
                                    _change(
                                      context,
                                      () => store.remove(rule.id),
                                    );
                                  }
                                },
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      );
    },
  );
}

class PurificationEditor extends StatefulWidget {
  const PurificationEditor({
    super.key,
    required this.store,
    required this.bookId,
    required this.samples,
    this.rule,
    this.initialFind = '',
  });
  final PurificationStore store;
  final String bookId;
  final List<String> samples;
  final PurificationRule? rule;
  final String initialFind;

  @override
  State<PurificationEditor> createState() => _PurificationEditorState();
}

class _PurificationEditorState extends State<PurificationEditor> {
  late final TextEditingController _find = TextEditingController(
    text: widget.rule?.find ?? widget.initialFind,
  );
  late final TextEditingController _replacement = TextEditingController(
    text: widget.rule?.replacement ?? '',
  );
  late bool _global = widget.rule != null && widget.rule!.bookId == null;
  late final String _id = widget.rule?.id ?? PurificationStore.newRuleId();
  String? _saveError;

  @override
  void dispose() {
    _find.dispose();
    _replacement.dispose();
    super.dispose();
  }

  PurificationRule get _rule => PurificationRule(
    id: _id,
    find: _find.text,
    replacement: _replacement.text,
    bookId: _global ? null : widget.bookId,
    enabled: widget.rule?.enabled ?? true,
  );

  @override
  Widget build(BuildContext context) {
    final PurificationRule draft = _rule;
    final String? error =
        draft.error ??
        (widget.rule == null &&
                widget.store.rules.length >= PurificationRule.maxRules
            ? '最多保存 64 条规则，请先删除不再使用的规则'
            : null);
    final List<PurificationRule> previewRules = <PurificationRule>[
      for (final PurificationRule rule in widget.store.forBook(widget.bookId))
        rule.id == draft.id ? draft.copyWith(enabled: true) : rule,
      if (widget.rule == null) draft,
    ];
    final TextPurifier? purifier = error == null
        ? TextPurifier(previewRules)
        : null;
    final List<String> after = purifier == null
        ? <String>[]
        : widget.samples.map((text) => purifier.apply(text).text).toList();
    return SheetPage(
      title: widget.rule == null ? '添加净化规则' : '编辑净化规则',
      slivers: <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          sliver: SliverList.list(
            children: <Widget>[
              TextField(
                key: const ValueKey<String>('purification-find'),
                controller: _find,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '匹配原文',
                  hintText: '例如：请收藏本站',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey<String>('purification-replacement'),
                controller: _replacement,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '替换为',
                  hintText: '留空即删除匹配文字',
                  helperText: '留空即删除匹配文字',
                ),
                onChanged: (_) => setState(() {}),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('用于所有书籍'),
                subtitle: Text(_global ? '保存后会改变所有书籍的阅读显示' : '默认仅用于当前这本书'),
                value: _global,
                onChanged: (value) => setState(() => _global = value),
              ),
              if (error != null) Text(error),
              if (_saveError != null) Text(_saveError!),
              const SizedBox(height: 12),
              const Text(
                '当前页预览',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const Text('预览包含本书已启用的其他规则，不展示未读内容。摘记与引用仍使用原文。'),
              if (!draft.enabled) const Text('预览展示启用后的效果，保存后仍保持停用'),
              if (purifier != null) ...<Widget>[
                const SizedBox(height: 12),
                const Text('原文'),
                Text(widget.samples.join('\n\n')),
                const SizedBox(height: 12),
                const Text('净化后'),
                Text(
                  after.every((text) => text.isEmpty)
                      ? '本页文字已隐藏'
                      : after.join('\n\n'),
                  key: const ValueKey<String>('purification-preview'),
                ),
              ],
              const SizedBox(height: 12),
              FilledButton(
                onPressed: error != null
                    ? null
                    : () {
                        try {
                          widget.store.put(draft);
                          SheetScope.of(context).state.pop();
                        } on FormatException catch (error) {
                          setState(() => _saveError = error.message);
                        } on StateError catch (error) {
                          setState(() => _saveError = error.message);
                        } on Object {
                          setState(() => _saveError = '规则未能保存，请检查存储空间后重试');
                        }
                      },
                child: const Text('保存规则'),
              ),
              const SizedBox(height: 12),
              const Text(_help),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ],
    );
  }
}
