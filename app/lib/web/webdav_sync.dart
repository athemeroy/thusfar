import '../ui/reader_message.dart';
import '../ui/info_button.dart';
// Browser-only WebDAV snapshot transfer. Credentials are kept in this route's
// memory and are never written to IndexedDB, backups, or localStorage.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../ui/theme.dart';
import '../data/restore_report.dart';
import 'web_storage.dart';

const int _maxSnapshotBytes = 144 * 1024 * 1024;
final RegExp _snapshotName = RegExp(
  r'^\d{8}T\d{9}Z-[0-9a-f]{12}\.thusfar\.json$',
);

class WebDavException implements Exception {
  const WebDavException(this.message);
  final String message;
  @override
  String toString() => message;
}

class WebDavSnapshot {
  const WebDavSnapshot(this.name, this.url);
  final String name;
  final Uri url;

  String get label {
    final String stamp = name.substring(0, 18);
    return '${stamp.substring(0, 4)}-${stamp.substring(4, 6)}-'
        '${stamp.substring(6, 8)} ${stamp.substring(9, 11)}:'
        '${stamp.substring(11, 13)}:${stamp.substring(13, 15)} UTC';
  }
}

class WebDavClient {
  WebDavClient._(this.collection, this._authorization);

  final Uri collection;
  final String _authorization;
  final Set<html.HttpRequest> _active = <html.HttpRequest>{};
  bool _disposed = false;

  factory WebDavClient(String url, String username, String password) {
    final Uri? parsed = Uri.tryParse(url.trim());
    if (parsed == null ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasQuery ||
        parsed.hasFragment ||
        !parsed.path.endsWith('/') ||
        (parsed.scheme != 'https' &&
            !(parsed.scheme == 'http' &&
                const <String>{
                  'localhost',
                  '127.0.0.1',
                  '::1',
                }.contains(parsed.host.toLowerCase())))) {
      throw const WebDavException('请填写云端服务提供的文件夹地址。');
    }
    if (username.trim().isEmpty || password.isEmpty) {
      throw const WebDavException('请填写 WebDAV 用户名和密码。');
    }
    return WebDavClient._(
      parsed,
      'Basic ${base64Encode(utf8.encode('$username:$password'))}',
    );
  }

  void dispose() {
    _disposed = true;
    for (final html.HttpRequest request in _active.toList()) {
      request.abort();
    }
    _active.clear();
  }

  Future<(int, Uint8List)> _request(
    String method,
    Uri url, {
    Uint8List? body,
    Map<String, String> headers = const <String, String>{},
    void Function(int sent, int total)? onProgress,
  }) async {
    if (_disposed) throw const WebDavException('页面已关闭，请重新打开 WebDAV。');
    final html.HttpRequest request = html.HttpRequest();
    final Completer<(int, Uint8List)> done = Completer<(int, Uint8List)>();
    _active.add(request);
    void fail(String message) {
      if (!done.isCompleted) done.completeError(WebDavException(message));
    }

    request.onLoad.listen((_) {
      if (done.isCompleted) return;
      try {
        final int status = request.status ?? 0;
        // Error pages can be arbitrarily large and may include server details.
        // The caller only needs the status to show a safe, actionable message.
        if (status < 200 || status >= 300) {
          done.complete((status, Uint8List(0)));
          return;
        }
        final Object? response = request.response;
        final Uint8List bytes = response is ByteBuffer
            ? response.asUint8List()
            : response is Uint8List
            ? response
            : Uint8List(0);
        if (bytes.length > _maxSnapshotBytes) {
          fail('远端文件超过 144 MB，浏览器没有导入。');
          return;
        }
        done.complete((status, bytes));
      } on Object {
        fail('浏览器无法读取 WebDAV 响应；本地书籍未改动，请重试。');
      }
    });
    request.onError.listen((_) {
      fail('浏览器无法连接云端。请检查地址和网络，或使用安装版。');
    });
    request.onTimeout.listen((_) => fail('WebDAV 请求超时，请检查网络后手动重试。'));
    request.onAbort.listen((_) => fail('WebDAV 操作已取消。'));
    request.onProgress.listen((html.ProgressEvent event) {
      if ((event.loaded ?? 0) > _maxSnapshotBytes) {
        request.abort();
        fail('远端文件超过 144 MB，浏览器没有导入。');
      }
    });
    request.upload.onProgress.listen((html.ProgressEvent event) {
      onProgress?.call(event.loaded ?? 0, event.total ?? 0);
    });
    final Timer completionGuard = Timer(const Duration(seconds: 190), () {
      fail('WebDAV 响应处理超时；本地书籍未改动，请重试。');
      request.abort();
    });
    try {
      request.open(method, url.toString());
      request.responseType = 'arraybuffer';
      request.timeout = 180000;
      request.setRequestHeader('Authorization', _authorization);
      for (final MapEntry<String, String> header in headers.entries) {
        request.setRequestHeader(header.key, header.value);
      }
      request.send(body);
      return await done.future;
    } on Object catch (error) {
      if (error is WebDavException) rethrow;
      throw const WebDavException('浏览器无法发起 WebDAV 请求，请检查地址和服务设置。');
    } finally {
      completionGuard.cancel();
      _active.remove(request);
    }
  }

  Future<List<WebDavSnapshot>> list() async {
    final (int status, Uint8List data) = await _request(
      'PROPFIND',
      collection,
      headers: const <String, String>{'Depth': '1'},
    );
    if (status == 401 || status == 403) {
      throw WebDavException('WebDAV 认证或文件夹权限失败。');
    }
    if (status != 207) {
      throw WebDavException('无法读取云端文件列表，请检查文件夹地址和访问权限。');
    }
    final html.Document document = html.DomParser().parseFromString(
      utf8.decode(data),
      'application/xml',
    );
    final List<WebDavSnapshot> snapshots = <WebDavSnapshot>[];
    final Set<String> seen = <String>{};
    for (final html.Node node in document.getElementsByTagName('*')) {
      if (node is! html.Element || node.localName.toLowerCase() != 'href') {
        continue;
      }
      final String href = node.text?.trim() ?? '';
      final Uri? supplied = Uri.tryParse(href);
      if (supplied == null) continue;
      final String path = supplied.path;
      if (!path.startsWith(collection.path)) continue;
      final String name = path.substring(collection.path.length);
      if (!_snapshotName.hasMatch(name) || !seen.add(name)) continue;
      // Use the user's validated origin, never an origin from server XML.
      snapshots.add(WebDavSnapshot(name, collection.resolve(name)));
    }
    snapshots.sort(
      (WebDavSnapshot a, WebDavSnapshot b) => b.name.compareTo(a.name),
    );
    return snapshots;
  }

  Future<WebDavSnapshot> upload(
    Uint8List bytes, {
    void Function(int sent, int total)? onProgress,
  }) async {
    if (bytes.length > _maxSnapshotBytes) {
      throw const WebDavException('单个备份超过 144 MB，请使用安装版或缩小书籍图片。');
    }
    final DateTime now = DateTime.now().toUtc();
    String two(int value) => value.toString().padLeft(2, '0');
    final String timestamp =
        '${now.year.toString().padLeft(4, '0')}${two(now.month)}${two(now.day)}'
        'T${two(now.hour)}${two(now.minute)}${two(now.second)}'
        '${now.millisecond.toString().padLeft(3, '0')}Z';
    final math.Random random = math.Random.secure();
    final String nonce = List<String>.generate(
      6,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final String name = '$timestamp-$nonce.thusfar.json';
    final Uri target = collection.resolve(name);
    final (int status, _) = await _request(
      'PUT',
      target,
      body: bytes,
      headers: const <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
        'If-None-Match': '*',
      },
      onProgress: onProgress,
    );
    if (status == 412 || status == 409) {
      throw const WebDavException('远端备份文件冲突，未覆盖；请重新点击上传生成新备份。');
    }
    if (status == 401 || status == 403) {
      throw WebDavException('WebDAV 认证或写入权限失败。');
    }
    if (status < 200 || status >= 300) {
      throw WebDavException('WebDAV 上传失败，本地书籍未改动。');
    }
    return WebDavSnapshot(name, target);
  }

  Future<Uint8List> download(WebDavSnapshot snapshot) async {
    if (!_snapshotName.hasMatch(snapshot.name) ||
        snapshot.url.origin != collection.origin ||
        snapshot.url.path != '${collection.path}${snapshot.name}') {
      throw const WebDavException('远端备份地址无效，未下载。');
    }
    final (int status, Uint8List data) = await _request('GET', snapshot.url);
    if (status == 401 || status == 403) {
      throw WebDavException('WebDAV 认证或读取权限失败。');
    }
    if (status != 200) {
      throw WebDavException('WebDAV 下载失败，本地书籍未改动。');
    }
    return data;
  }
}

class WebDavSyncPage extends StatefulWidget {
  const WebDavSyncPage({
    super.key,
    required this.library,
    required this.books,
    this.clientFactory,
  });

  final WebLibrary library;
  final List<WebBookMeta> books;
  final WebDavClient Function(String url, String username, String password)?
  clientFactory;

  @override
  State<WebDavSyncPage> createState() => _WebDavSyncPageState();
}

class _WebDavSyncPageState extends State<WebDavSyncPage> {
  final TextEditingController _url = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();
  WebDavClient? _client;
  List<WebDavSnapshot> _snapshots = const <WebDavSnapshot>[];
  String? _selectedBook;
  String? _error;
  String? _activity;
  bool _busy = false;
  bool _committing = false;
  int _operation = 0;
  int _sent = 0;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    if (widget.books.isNotEmpty) _selectedBook = widget.books.first.id;
  }

  void _invalidateConnection() {
    _client?.dispose();
    _client = null;
    if (mounted) setState(() => _snapshots = const <WebDavSnapshot>[]);
  }

  WebDavClient _connection() {
    return _client ??=
        widget.clientFactory?.call(_url.text, _username.text, _password.text) ??
        WebDavClient(_url.text, _username.text, _password.text);
  }

  void _checkCurrent(WebDavClient client) {
    if (!mounted || !identical(_client, client)) {
      throw const WebDavException('WebDAV 操作已取消。');
    }
  }

  Future<void> _cancel({bool leave = false}) async {
    if (!_busy || _committing) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(leave ? '停止当前任务并离开？' : '停止当前 WebDAV 任务？'),
        content: const Text(
          '停止等待与传输，不再导入本地资料。已经到达服务器的上传可能仍会完成；再次上传前，请重新列出备份以免重复。',
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
    _operation++;
    _client?.dispose();
    _client = null;
    setState(() {
      _busy = false;
      _activity = '已停止等待；本地未导入。若正在上传，请重新列出远端备份确认结果。';
      _error = null;
    });
    if (leave) Navigator.of(context).pop();
  }

  Future<void> _run(
    String activity,
    Future<void> Function(WebDavClient client) action,
  ) async {
    if (_busy) return;
    final int operation = ++_operation;
    setState(() {
      _busy = true;
      _activity = activity;
      _error = null;
      _sent = 0;
      _total = 0;
    });
    try {
      await action(_connection());
    } on Object catch (error) {
      if (mounted && operation == _operation) {
        setState(
          () => _error = error is WebDavException
              ? readerMessage(error.message, fallback: '操作未完成，请检查云端地址、账户和备份文件。')
              : error is WebBackupConflict
              ? readerMessage(error.message, fallback: '操作未完成，请检查云端地址、账户和备份文件。')
              : error is FormatException
              ? '这份备份无法读取，现有书籍未改变。'
              : '操作失败；本地书籍未被覆盖。',
        );
      }
    } finally {
      if (mounted && operation == _operation) {
        setState(() {
          _busy = false;
          _committing = false;
          if (_error != null) _activity = '任务未完成';
        });
      }
    }
  }

  Future<void> _list() => _run('读取远端备份', (WebDavClient client) async {
    final List<WebDavSnapshot> snapshots = await client.list();
    _checkCurrent(client);
    setState(() {
      _snapshots = snapshots;
      _activity = snapshots.isEmpty
          ? '云端文件夹中没有备份。'
          : '找到 ${snapshots.length} 个备份。点击查看备份内容。';
    });
  });

  Future<void> _upload() => _run('上传新的完整备份', (WebDavClient client) async {
    final String? id = _selectedBook;
    if (id == null) throw const WebDavException('请先选择本地书籍。');
    final Uint8List bytes = await widget.library.exportBackupBytes(id);
    _checkCurrent(client);
    final WebDavSnapshot uploaded = await client.upload(
      bytes,
      onProgress: (int sent, int total) {
        if (mounted && identical(_client, client)) {
          setState(() {
            _sent = sent;
            _total = total;
          });
        }
      },
    );
    _checkCurrent(client);
    setState(() {
      _snapshots = <WebDavSnapshot>[uploaded, ..._snapshots];
      _activity = '已上传新备份 ${uploaded.name}；远端旧备份未被覆盖。';
    });
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已上传独立备份；旧版本仍保留在 WebDAV。')));
  });

  Future<void> _openSnapshot(WebDavSnapshot snapshot) => _run('下载远端备份', (
    WebDavClient client,
  ) async {
    final Uint8List bytes = await client.download(snapshot);
    _checkCurrent(client);
    setState(() => _activity = '正在检查备份');
    final BackupSummary summary = BackupSummary.read(
      bytes,
      fallback: snapshot.name,
    );
    String? previewError;
    try {
      await widget.library.importBackup(bytes, previewOnly: true);
    } on Object catch (error) {
      previewError = error is WebBackupConflict
          ? readerMessage(error.message, fallback: '这份备份与现有内容不同，请先分别保存两个版本。')
          : error is FormatException
          ? '这份备份无法读取，请重新下载后再试。'
          : '无法读取备份，请检查浏览器剩余空间。';
    }
    _checkCurrent(client);
    setState(() => _activity = '等待确认');
    if (!mounted) return;
    final String? choice = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('远端书籍备份'),
        content: Text(
          '${summary.title}\n${summary.exported == null ? snapshot.label : summary.dateLabel}\n${summary.sizeLabel}\n\n'
          '${previewError ?? '恢复时会保留已有阅读记录。确认前不会修改现有书籍。'}',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, 'cancel'),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, 'download'),
            child: const Text('另存文件'),
          ),
          if (previewError == null)
            FilledButton(
              onPressed: () => Navigator.pop(context, 'import'),
              child: const Text('导入到此浏览器'),
            ),
        ],
      ),
    );
    _checkCurrent(client);
    if (choice == 'download') {
      final html.Blob blob = html.Blob(<Object>[bytes], 'application/json');
      final String url = html.Url.createObjectUrlFromBlob(blob);
      final html.AnchorElement anchor = html.AnchorElement(href: url)
        ..download = snapshot.name;
      html.document.body?.append(anchor);
      anchor.click();
      anchor.remove();
      Future<void>.delayed(
        const Duration(seconds: 2),
        () => html.Url.revokeObjectUrl(url),
      );
      setState(() => _activity = '已请求浏览器另存备份，请检查下载列表。');
    } else if (choice == 'import') {
      setState(() {
        _committing = true;
        _activity = '正在合并本地资料，完成后可离开';
      });
      await widget.library.importBackup(bytes);
      _checkCurrent(client);
      setState(() => _activity = '备份已导入，可继续阅读。');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('备份已导入；本地原书和记录已安全保留或合并。')));
      }
    } else {
      setState(() => _activity = '已取消导入，本地书籍未改动。');
    }
  });

  @override
  void dispose() {
    _client?.dispose();
    _password.clear();
    _url.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    return PopScope<void>(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _busy) _cancel(leave: true);
      },
      child: Scaffold(
        backgroundColor: t.paper,
        appBar: AppBar(title: const Text('WebDAV 备份')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 20, 18, 36),
              children: <Widget>[
                Text(
                  '手动上传和导入完整书籍备份',
                  style: TextStyle(
                    color: t.ink,
                    fontSize: 23,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '上传会把书籍正文、图片、阅读记录和已有整理结果发送到你填写的 WebDAV 文件夹。每次生成新文件，旧版本保留；关闭页面后不会自动同步。',
                  style: TextStyle(color: t.ink2, height: 1.5),
                ),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: InfoButton(
                    title: '云端备份',
                    message:
                        '备份包含书籍、图片、阅读记录和整理资料，不包含模型密钥。需要手动上传。如果浏览器无法连接云端，请使用安装版，或手动下载备份后导入。',
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: _url,
                  enabled: !_busy,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '云端文件夹地址',
                    hintText: 'https://example.com/dav/books/',
                  ),
                  onChanged: (_) => _invalidateConnection(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _username,
                  enabled: !_busy,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: '用户名'),
                  onChanged: (_) => _invalidateConnection(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  enabled: !_busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: '密码或应用专用密码'),
                  onChanged: (_) => _invalidateConnection(),
                ),
                const SizedBox(height: 8),
                Text(
                  '登录信息不会保存，离开后需重新填写。',
                  style: TextStyle(color: t.ink2, fontSize: 12, height: 1.5),
                ),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: InfoButton(
                    title: '云端备份',
                    message:
                        '备份包含书籍、图片、阅读记录和整理资料，不包含模型密钥。需要手动上传。如果浏览器无法连接云端，请使用安装版，或手动下载备份后导入。',
                  ),
                ),
                const SizedBox(height: 20),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: _selectedBook,
                  decoration: const InputDecoration(labelText: '本地要上传的书'),
                  items: <DropdownMenuItem<String>>[
                    for (final WebBookMeta book in widget.books)
                      DropdownMenuItem<String>(
                        value: book.id,
                        child: Text(
                          book.title,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _busy
                      ? null
                      : (String? value) =>
                            setState(() => _selectedBook = value),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 8,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: _busy || _selectedBook == null
                          ? null
                          : _upload,
                      icon: const Icon(Icons.cloud_upload_outlined),
                      label: const Text('上传新备份'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _list,
                      icon: const Icon(Icons.refresh),
                      label: const Text('列出远端备份'),
                    ),
                  ],
                ),
                if (_busy) ...<Widget>[
                  const SizedBox(height: 15),
                  LinearProgressIndicator(
                    value: _total > 0 ? (_sent / _total).clamp(0.0, 1.0) : null,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _total > 0
                        ? '$_activity · ${(_sent / _total * 100).clamp(0, 100).round()}%'
                        : (_activity ?? '处理中…'),
                    style: TextStyle(color: t.ink2, fontSize: 12),
                  ),
                ],
                if (_busy)
                  TextButton(
                    onPressed: _committing ? null : _cancel,
                    child: const Text('停止当前任务'),
                  ),
                if (!_busy && _activity != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_activity!),
                  ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 15),
                  Text(_error!, style: TextStyle(color: t.danger, height: 1.5)),
                ],
                const SizedBox(height: 26),
                Text(
                  '远端备份  ${_snapshots.length}',
                  style: TextStyle(
                    color: t.ink,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                if (_snapshots.isEmpty)
                  Text(
                    '先点击“列出远端备份”。如果文件夹为空，这里不会显示书籍。',
                    style: TextStyle(color: t.ink2),
                  )
                else
                  for (final WebDavSnapshot snapshot in _snapshots)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.history_edu_outlined),
                        title: Text(snapshot.label),
                        subtitle: Text(snapshot.name),
                        trailing: const Icon(Icons.chevron_right),
                        enabled: !_busy,
                        onTap: _busy ? null : () => _openSnapshot(snapshot),
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
