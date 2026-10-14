import 'package:flutter/material.dart';
import '../ui/restore_report_view.dart';
import 'web_storage.dart';

class WebRecoveryPage extends StatefulWidget {
  const WebRecoveryPage({super.key, required this.library});
  final WebLibrary library;
  @override
  State<WebRecoveryPage> createState() => _WebRecoveryPageState();
}

class _WebRecoveryPageState extends State<WebRecoveryPage> {
  List<WebTrashEntry> _trash = [];
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _read();
  }

  Future<void> _read() async {
    try {
      final rows = await widget.library.listTrash();
      if (mounted) setState(() => _trash = rows);
    } on Object {
      if (mounted) setState(() => _error = '无法读取回收站，请刷新后重试。');
    }
  }

  Future<void> _act(WebTrashEntry book, {bool permanent = false}) async {
    if (_busy) return;
    if (permanent) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('永久删除这本书？'),
          content: Text('《${book.title}》的正文、阅读进度和摘记将从此浏览器永久删除，无法撤销。其他备份不受影响。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('永久删除'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (permanent) {
        await widget.library.permanentlyDeleteFromTrash(book.key);
      } else {
        await widget.library.restoreFromTrash(book.key);
      }
      await _read();
    } on Object {
      if (mounted) setState(() => _error = '操作未完成，请稍后重试。');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('回收站与恢复报告')),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        ListTile(
          leading: const Icon(Icons.fact_check_outlined),
          title: const Text('上次恢复报告'),
          subtitle: const Text('逐本查看导入结果、全部冲突与设置状态'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  RestoreReportView(report: widget.library.lastRestoreReport),
            ),
          ),
        ),
        const Divider(),
        const SizedBox(height: 12),
        Text('回收站', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('移除的书籍仍保存在此浏览器并占用空间，可随时恢复。清理浏览器站点数据也会清空回收站，请另存备份。'),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_error!),
          ),
        if (_trash.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('回收站是空的')),
          ),
        for (final book in _trash)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    '${book.removed.toLocal().toString().split('.').first} · ${(book.bytes / 1024 / 1024).toStringAsFixed(1)} MB',
                  ),
                  if (book.issue != null) const Text('这本书暂时无法恢复，请保留备份后重试。'),
                  Wrap(
                    spacing: 12,
                    children: [
                      FilledButton.tonal(
                        onPressed: _busy || book.issue != null
                            ? null
                            : () => _act(book),
                        child: const Text('恢复到书架'),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _act(book, permanent: true),
                        child: const Text('永久删除'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
