import '../ui/reader_message.dart';
import '../ui/info_button.dart';
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
        setState(
          () => _message = readerMessage(
            error.message,
            fallback: '操作未完成，请检查云端地址、账户和网络。',
          ),
        );
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
          '停止等待与传输，不再导入本地资料。已经到达服务器的上传可能仍会完成；再次上传前，请先重新列出备份以免重复。',
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
      _message = '已停止等待；本地未导入。若正在上传，请重新列出远端备份确认结果。';
    });
    if (leave) Navigator.of(context).pop();
  }

  Future<void> _list() => _run('正在读取云端备份', (client) async {
    final List<WebDavSnapshot> found = await client.list();
    _checkCurrent(client);
    setState(() => _snapshots = found);
    return found.isEmpty ? '这个文件夹还没有页读备份。' : '找到 ${found.length} 个备份。点击查看备份内容。';
  });

  Future<void> _upload(BookEntry book) =>
      _run('正在准备《${book.title}》', (client) async {
        final Uint8List bytes = exportBookBytes(widget.library, book);
        _phase(client, '正在上传《${book.title}》的新备份');
        final String name = await client.upload(bytes);
        _checkCurrent(client);
        setState(() {
          _previews[name] = BackupSummary.read(bytes, fallback: book.title);
          _snapshots = [
            WebDavSnapshot(client.collection.resolve(name), name),
            ..._snapshots,
          ];
        });
        return '《${book.title}》已上传为新备份。旧备份仍保留。';
      });

  Future<void> _download(WebDavSnapshot snapshot) => _run('正在下载备份…', (
    client,
  ) async {
    final Uint8List bytes = await client.download(snapshot);
    _phase(client, '正在检查备份…');
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
        title: const Text('WebDAV 备份预览'),
        content: SingleChildScrollView(
          child: Text(
            '${summary.title}\n${summary.exported == null ? _label(snapshot) : summary.dateLabel}\n${summary.sizeLabel}\n\n${preview.error == null ? '${preview.existed ? '已有同一本书，会保留已有阅读记录。' : '将导入为书架上的一本书。'}确认前不会修改本地。' : '${readerMessage(preview.error, fallback: '这份备份暂时无法恢复。')}\n现有书籍未改变。'}',
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
    _phase(client, '正在恢复书籍，请稍候…');
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
      appBar: AppBar(title: const Text('WebDAV 备份')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 36),
        children: [
          const Text('将书籍备份到自己的云端，再到其他设备恢复。需要手动上传，旧备份会保留。'),
          const Align(
            alignment: Alignment.centerLeft,
            child: InfoButton(
              title: '云端备份',
              message:
                  '备份包含原文、图片、阅读进度和整理资料，不包含模型密钥。导入前可以查看书名、时间和大小。上传完成后，可在其他设备恢复。',
            ),
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
          const Text('登录信息不会保存，离开后需重新填写。'),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _list,
            icon: const Icon(Icons.cloud_download_outlined),
            label: const Text('查看云端备份'),
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
                  subtitle: const Text('上传新的完整备份'),
                  trailing: const Icon(Icons.cloud_upload_outlined),
                  enabled: !_busy,
                  onTap: () => _upload(book),
                ),
              ),
          const SizedBox(height: 24),
          Text('云端备份', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_snapshots.isEmpty)
            const Text('填写地址后点击“查看云端备份”。')
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
                    null => '点击查看备份内容',
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
