import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/backup.dart';
import '../data/library.dart';
import '../data/webdav.dart';

/// Manual, append-only WebDAV snapshots. Credentials stay in this route's
/// controllers and are never included in a book export or processing log.
class WebDavScreen extends StatefulWidget {
  const WebDavScreen({super.key, required this.library});

  final Library library;

  @override
  State<WebDavScreen> createState() => _WebDavScreenState();
}

class _WebDavScreenState extends State<WebDavScreen> {
  final TextEditingController _url = TextEditingController();
  final TextEditingController _user = TextEditingController();
  final TextEditingController _password = TextEditingController();
  List<WebDavSnapshot> _snapshots = const <WebDavSnapshot>[];
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _password.clear();
    _url.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  WebDavClient _client() => WebDavClient(
    collectionUrl: _url.text,
    username: _user.text,
    password: _password.text,
  );

  Future<void> _run(Future<String> Function(WebDavClient client) action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final WebDavClient client = _client();
      final String result = await action(client);
      if (mounted) setState(() => _message = result);
    } on WebDavException catch (error) {
      if (mounted) setState(() => _message = error.message);
    } on Object {
      if (mounted) setState(() => _message = '操作未完成。请检查 WebDAV 地址、权限和备份文件。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _list() => _run((WebDavClient client) async {
    if (mounted) setState(() => _snapshots = const <WebDavSnapshot>[]);
    final List<WebDavSnapshot> found = await client.list();
    if (mounted) setState(() => _snapshots = found);
    return found.isEmpty ? '这个文件夹还没有页读快照。' : '找到 ${found.length} 个快照。';
  });

  Future<void> _upload(BookEntry book) => _run((WebDavClient client) async {
    final Uint8List bytes = exportBookBytes(widget.library, book);
    final String name = await client.upload(bytes);
    try {
      final List<WebDavSnapshot> found = await client.list();
      if (mounted) setState(() => _snapshots = found);
    } on WebDavException {
      // Upload already succeeded. A failed follow-up listing must not make
      // the user upload the same large book again just to see confirmation.
    }
    return '《${book.title}》已上传为新快照：$name';
  });

  Future<void> _download(WebDavSnapshot snapshot) async {
    if (_busy) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('导入 WebDAV 快照？'),
        content: const Text('将下载完整书籍备份。已有同一本书时只合并可安全合并的阅读资料；资料冲突会停止导入，不会静默覆盖。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('下载并导入'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _run((WebDavClient client) async {
      final Uint8List bytes = await client.download(snapshot);
      final ImportResult result = restoreBackup(
        widget.library,
        snapshot.name,
        bytes,
      );
      if (result.error != null) throw WebDavException(result.error!);
      await widget.library.scan();
      return result.existed ? '同一本书的可合并资料已核对。' : '书籍和阅读资料已导入。';
    });
  }

  String _label(WebDavSnapshot snapshot) {
    final String name = snapshot.name;
    if (name.length < 19) return name;
    return '${name.substring(0, 4)}-${name.substring(4, 6)}-${name.substring(6, 8)} '
        '${name.substring(9, 11)}:${name.substring(11, 13)} UTC';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('WebDAV 同步')),
    body: ListView(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 36),
      children: <Widget>[
        const Text('把完整备份保存到你自己的 WebDAV 文件夹，再在另一台设备下载导入。每次上传生成新快照；遇到冲突会提示处理。'),
        const SizedBox(height: 18),
        TextField(
          controller: _url,
          enabled: !_busy,
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
          autofillHints: const <String>[AutofillHints.username],
          decoration: const InputDecoration(
            labelText: '用户名',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _password,
          enabled: !_busy,
          obscureText: true,
          autofillHints: const <String>[AutofillHints.password],
          decoration: const InputDecoration(
            labelText: '密码或应用专用密码',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 8),
        const Text('登录信息只在此页面使用；离开后清除。备份含原文、图片、阅读进度与整理资料，不含模型密钥。'),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _busy ? null : _list,
          icon: const Icon(Icons.cloud_download_outlined),
          label: const Text('查看云端快照'),
        ),
        if (_busy) ...<Widget>[
          const SizedBox(height: 12),
          const LinearProgressIndicator(),
        ],
        if (_message != null) ...<Widget>[
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
                title: Text(_label(snapshot)),
                subtitle: Text(
                  snapshot.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.download_outlined),
                enabled: !_busy,
                onTap: () => _download(snapshot),
              ),
            ),
      ],
    ),
  );
}
