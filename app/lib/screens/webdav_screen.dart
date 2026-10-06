import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../data/library.dart';
import '../data/restore_report.dart';
import '../data/webdav.dart';

/// Manual, append-only snapshots. Credentials live only in this route.
class WebDavScreen extends StatefulWidget {
  const WebDavScreen({super.key, required this.library, this.clientFactory});
  final Library library;
  final WebDavClient Function(String url, String user, String password)?
  clientFactory;
  @override
  State<WebDavScreen> createState() => _WebDavScreenState();
}

class _WebDavScreenState extends State<WebDavScreen> {
  final TextEditingController _url = TextEditingController();
  final TextEditingController _user = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final Map<String, BackupSummary> _previews = <String, BackupSummary>{};
  List<WebDavSnapshot> _snapshots = const <WebDavSnapshot>[];
  WebDavClient? _active;
  bool _busy = false;
  bool _committing = false;
  String? _activity;
  String? _message;

  @override
  void dispose() {
    _active?.dispose();
    _password.clear();
    _url.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  void _checkCurrent(WebDavClient client) {
    if (!mounted || !identical(_active, client)) {
      throw const WebDavException('WebDAV 操作已取消。');
    }
  }

  void _phase(WebDavClient client, String activity) {
    _checkCurrent(client);
    setState(() => _activity = activity);
  }

  Future<void> _run(
    String activity,
    Future<String> Function(WebDavClient client) action,
  ) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _activity = activity;
      _message = null;
    });
    WebDavClient? client;
    try {
      client =
          widget.clientFactory?.call(_url.text, _user.text, _password.text) ??
          WebDavClient(
            collectionUrl: _url.text,
            username: _user.text,
            password: _password.text,
          );
      _active = client;
      final String result = await action(client);
      _checkCurrent(client);
      setState(() => _message = result);
    } on WebDavException catch (error) {
      if (mounted && identical(_active, client)) {
        setState(() => _message = error.message);
      }
    } on Object {
      if (mounted && identical(_active, client)) {
        setState(() => _message = '操作未完成。请检查 WebDAV 地址、权限和备份文件。');
      }
    } finally {
      client?.dispose();
      if (mounted && identical(_active, client)) {
        setState(() {
          _active = null;
          _busy = false;
          _committing = false;
          _activity = null;
        });
      }
    }
  }

  Future<void> _cancel({bool leave = false}) async {
    if (!_busy || _committing) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(leave ? '停止当前任务并离开？' : '停止当前 WebDAV 任务？'),
        content: const Text(
          '停止等待与传输，不再导入本地资料。已经到达服务器的上传可能仍会完成；再次上传前，请先重新列出快照以免重复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续任务'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('停止任务'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _committing) return;
    _active?.dispose();
    setState(() {
      _active = null;
      _busy = false;
      _activity = null;
      _message = '已停止等待；本地未导入。若正在上传，请重新列出远端快照确认结果。';
    });
    if (leave) Navigator.of(context).pop();
  }

  Future<void> _list() => _run('正在读取云端快照', (client) async {
    final List<WebDavSnapshot> found = await client.list();
    _checkCurrent(client);
    setState(() => _snapshots = found);
    return found.isEmpty
        ? '这个文件夹还没有页读快照。'
        : '找到 ${found.length} 个快照。点击快照可先校验并预览。';
  });

  Future<void> _upload(BookEntry book) =>
      _run('正在准备《${book.title}》', (client) async {
        final Uint8List bytes = exportBookBytes(widget.library, book);
        _phase(client, '正在上传《${book.title}》的新快照');
        final String name = await client.upload(bytes);
        _checkCurrent(client);
        setState(() {
          _previews[name] = BackupSummary.read(bytes, fallback: book.title);
          _snapshots = [
            WebDavSnapshot(client.collection.resolve(name), name),
            ..._snapshots,
          ];
        });
        return '《${book.title}》已上传为新快照，含本书净化规则和 TXT 目录设置；全局规则请用整库备份。旧快照仍保留。';
      });

  Future<void> _download(WebDavSnapshot snapshot) => _run('正在下载快照以供校验和预览', (
    client,
  ) async {
    final Uint8List bytes = await client.download(snapshot);
    _phase(client, '正在校验原文和合并条件');
    final BackupSummary summary = BackupSummary.read(
      bytes,
      fallback: snapshot.name,
    );
    final ImportResult preview = restoreBackup(
      widget.library,
      snapshot.name,
      bytes,
      previewOnly: true,
    );
    _checkCurrent(client);
    setState(() {
      _previews[snapshot.name] = summary;
      _activity = '等待确认导入';
    });
    if (!mounted) return '页面已关闭。';
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('WebDAV 快照预览'),
        content: SingleChildScrollView(
          child: Text(
            '${summary.title}\n${summary.exported == null ? _label(snapshot) : summary.dateLabel}\n${summary.sizeLabel}\n${summary.customizationSummary ?? ''}\n\n${preview.error == null ? '已校验。${preview.existed ? '已有同一本书，将只合并兼容的阅读资料。' : '将导入为书架上的一本书。'}确认前不会修改本地。' : '未能通过校验：${preview.error}\n本地未改动，可取消后检查备份。'}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          if (preview.error == null)
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认导入'),
            ),
        ],
      ),
    );
    _checkCurrent(client);
    if (confirmed != true) return '已取消导入，本地书籍未改动。';
    _phase(client, '正在导入已校验的快照，完成后可离开');
    setState(() => _committing = true);
    // Revalidate at publication: local state may have changed during preview.
    final ImportResult result = restoreBackup(
      widget.library,
      snapshot.name,
      bytes,
    );
    if (result.error != null) throw WebDavException(result.error!);
    await widget.library.scan();
    _checkCurrent(client);
    return result.existed ? '同一本书的可合并资料已核对。' : '书籍和阅读资料已导入。';
  });

  String _label(WebDavSnapshot snapshot) {
    final String name = snapshot.name;
    if (name.length < 19) return name;
    return '${name.substring(0, 4)}-${name.substring(4, 6)}-${name.substring(6, 8)} ${name.substring(9, 11)}:${name.substring(11, 13)} UTC';
  }

  void _invalidate(String _) {
    setState(() {
      _snapshots = [];
      _previews.clear();
      _message = null;
    });
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: !_busy,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _busy) _cancel(leave: true);
    },
    child: Scaffold(
      appBar: AppBar(title: const Text('WebDAV 快照')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 36),
        children: [
          const Text(
            '手动上传完整书籍备份到你自己的 WebDAV 文件夹。每次生成独立快照，不会自动双向同步；旧快照保留。导入前会校验并预览书名、时间和大小。',
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _url,
            enabled: !_busy,
            onChanged: _invalidate,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'WebDAV 文件夹地址',
              hintText: 'https://dav.example.com/Thusfar/',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _user,
            enabled: !_busy,
            onChanged: _invalidate,
            autocorrect: false,
            autofillHints: const [AutofillHints.username],
            decoration: const InputDecoration(
              labelText: '用户名',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            enabled: !_busy,
            onChanged: _invalidate,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            autofillHints: const [AutofillHints.password],
            decoration: const InputDecoration(
              labelText: '密码或应用专用密码',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          const Text('登录信息只在此页面使用，离开后清除。备份含原文、图片、阅读进度与整理资料，不含模型密钥。'),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _list,
            icon: const Icon(Icons.cloud_download_outlined),
            label: const Text('查看云端快照'),
          ),
          if (_busy) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
            Text(_activity ?? '处理中…'),
            TextButton(
              onPressed: _committing ? null : _cancel,
              child: const Text('停止当前任务'),
            ),
          ],
          if (_message != null) ...[
            const SizedBox(height: 12),
            SelectableText(_message!),
          ],
          const SizedBox(height: 24),
          Text('上传本地书籍', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (widget.library.books.isEmpty)
            const Text('书架还没有书。')
          else
            for (final BookEntry book in widget.library.books)
              Card(
                child: ListTile(
                  title: Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: const Text('上传新的完整快照'),
                  trailing: const Icon(Icons.cloud_upload_outlined),
                  enabled: !_busy,
                  onTap: () => _upload(book),
                ),
              ),
          const SizedBox(height: 24),
          Text('云端快照', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_snapshots.isEmpty)
            const Text('填写地址后点击“查看云端快照”。')
          else
            for (final WebDavSnapshot snapshot in _snapshots)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.backup_outlined),
                  title: Text(
                    _previews[snapshot.name]?.title ?? _label(snapshot),
                  ),
                  subtitle: Text(switch (_previews[snapshot.name]) {
                    final BackupSummary summary =>
                      '${summary.dateLabel} · ${summary.sizeLabel}',
                    null => '点击下载、校验并预览书名和大小',
                  }),
                  trailing: const Icon(Icons.chevron_right),
                  enabled: !_busy,
                  onTap: () => _download(snapshot),
                ),
              ),
        ],
      ),
    ),
  );
}
