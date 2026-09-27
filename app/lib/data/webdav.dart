import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// One immutable backup on a user-owned WebDAV collection. Both the installed
/// app and the browser use this filename so they can discover each other's
/// snapshots without a server-side index or a destructive last-writer-wins PUT.
class WebDavSnapshot {
  const WebDavSnapshot(this.uri, this.name);

  final Uri uri;
  final String name;
}

class WebDavException implements Exception {
  const WebDavException(this.message);
  final String message;

  @override
  String toString() => message;
}

class WebDavClient {
  WebDavClient({
    required String collectionUrl,
    required this.username,
    required this.password,
  }) : collection = _collectionUri(collectionUrl);

  final Uri collection;
  final String username;
  final String password;

  static const int maxBackupBytes = 144 * 1024 * 1024;
  static const int _maxListingBytes = 2 * 1024 * 1024;
  static final RegExp _snapshotName = RegExp(
    r'^\d{8}T\d{9}Z-[0-9a-f]{12}\.thusfar\.json$',
  );

  static Uri _collectionUri(String raw) {
    final Uri? uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' &&
                (uri.host == 'localhost' ||
                    uri.host == '127.0.0.1' ||
                    uri.host == '::1')))) {
      throw const WebDavException('请输入 HTTPS WebDAV 文件夹地址；本机地址可用 HTTP。');
    }
    return uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');
  }

  static String newSnapshotName() {
    final String stamp = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().millisecondsSinceEpoch,
      isUtc: true,
    ).toIso8601String().replaceAll(RegExp(r'[-:.]'), '');
    final Random random = Random.secure();
    final String nonce = List<int>.generate(
      6,
      (_) => random.nextInt(256),
    ).map((int n) => n.toRadixString(16).padLeft(2, '0')).join();
    return '$stamp-$nonce.thusfar.json';
  }

  Future<String> upload(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxBackupBytes) {
      throw const WebDavException('备份为空或超过 144 MB，未上传。');
    }
    final String name = newSnapshotName();
    final (int status, _) = await _send(
      'PUT',
      collection.resolve(name),
      body: bytes,
      headers: const <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
        'If-None-Match': '*',
      },
      maxResponseBytes: 4096,
    );
    if (status != 200 && status != 201 && status != 204) {
      throw WebDavException(_statusMessage(status, '上传'));
    }
    return name;
  }

  Future<List<WebDavSnapshot>> list() async {
    final (int status, Uint8List bytes) = await _send(
      'PROPFIND',
      collection,
      body: Uint8List.fromList(
        utf8.encode(
          '<d:propfind xmlns:d="DAV:"><d:prop><d:displayname/></d:prop></d:propfind>',
        ),
      ),
      headers: const <String, String>{
        'Depth': '1',
        'Content-Type': 'application/xml; charset=utf-8',
      },
      maxResponseBytes: _maxListingBytes,
    );
    if (status != 207) {
      throw WebDavException(_statusMessage(status, '列出备份'));
    }
    final String xml;
    try {
      xml = utf8.decode(bytes);
    } on FormatException {
      throw const WebDavException('WebDAV 返回的文件列表编码无效。');
    }
    final RegExp hrefs = RegExp(
      r'<(?:[A-Za-z0-9_-]+:)?href(?:\s[^>]*)?>([^<]*)</(?:[A-Za-z0-9_-]+:)?href\s*>',
      caseSensitive: false,
    );
    final Map<String, WebDavSnapshot> found = <String, WebDavSnapshot>{};
    for (final RegExpMatch match in hrefs.allMatches(xml)) {
      final String raw = _xmlText(match.group(1)!);
      final Uri? href = Uri.tryParse(raw);
      if (href == null) continue;
      final Uri absolute = collection.resolveUri(href);
      if (absolute.scheme != collection.scheme ||
          absolute.host != collection.host ||
          absolute.port != collection.port ||
          !absolute.path.startsWith(collection.path)) {
        continue;
      }
      final String name = absolute.pathSegments.last;
      if (!_snapshotName.hasMatch(name) ||
          absolute.path != '${collection.path}$name') {
        continue;
      }
      found[name] = WebDavSnapshot(absolute, name);
    }
    final List<WebDavSnapshot> snapshots = found.values.toList()
      ..sort((WebDavSnapshot a, WebDavSnapshot b) => b.name.compareTo(a.name));
    return snapshots;
  }

  Future<Uint8List> download(WebDavSnapshot snapshot) async {
    if (snapshot.uri.scheme != collection.scheme ||
        snapshot.uri.host != collection.host ||
        snapshot.uri.port != collection.port ||
        snapshot.uri.path != '${collection.path}${snapshot.name}' ||
        !_snapshotName.hasMatch(snapshot.name)) {
      throw const WebDavException('备份地址不属于当前 WebDAV 文件夹。');
    }
    final (int status, Uint8List bytes) = await _send(
      'GET',
      snapshot.uri,
      maxResponseBytes: maxBackupBytes,
    );
    if (status != 200) {
      throw WebDavException(_statusMessage(status, '下载'));
    }
    if (bytes.isEmpty) throw const WebDavException('远端备份为空。');
    return bytes;
  }

  Future<(int, Uint8List)> _send(
    String method,
    Uri uri, {
    Uint8List? body,
    Map<String, String> headers = const <String, String>{},
    required int maxResponseBytes,
  }) async {
    final HttpClient client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final HttpClientRequest request = await client
          .openUrl(method, uri)
          .timeout(const Duration(seconds: 25));
      request.followRedirects = false;
      request.persistentConnection = false;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('$username:$password'))}',
      );
      for (final MapEntry<String, String> header in headers.entries) {
        request.headers.set(header.key, header.value);
      }
      if (body != null) {
        request.contentLength = body.length;
        request.add(body);
      }
      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 120),
      );
      if (response.statusCode != 200 &&
          response.statusCode != 201 &&
          response.statusCode != 204 &&
          response.statusCode != 207) {
        // Error pages can be arbitrarily large and may echo server details.
        // The status is all the UI needs; closing the client ends the stream.
        return (response.statusCode, Uint8List(0));
      }
      final BytesBuilder buffer = BytesBuilder(copy: false);
      await for (final List<int> chunk in response.timeout(
        const Duration(seconds: 45),
      )) {
        if (buffer.length + chunk.length > maxResponseBytes) {
          throw const WebDavException('WebDAV 返回的数据超过允许大小，已停止下载。');
        }
        buffer.add(chunk);
      }
      return (response.statusCode, buffer.takeBytes());
    } on WebDavException {
      rethrow;
    } on TimeoutException {
      throw const WebDavException('连接 WebDAV 超时。');
    } on HandshakeException {
      throw const WebDavException('WebDAV HTTPS 证书验证失败。');
    } on SocketException {
      throw const WebDavException('无法连接 WebDAV，请检查地址和网络。');
    } on HttpException {
      throw const WebDavException('WebDAV 连接异常。');
    } finally {
      client.close(force: true);
    }
  }

  static String _xmlText(String raw) => raw
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'");

  static String _statusMessage(int code, String action) {
    if (code == 401 || code == 403) return 'WebDAV 登录或访问权限被拒绝（HTTP $code）。';
    if (code == 404) return 'WebDAV 文件夹或备份不存在（HTTP 404）。';
    if (code == 405 || code == 501) {
      return 'WebDAV 服务不支持$action所需的方法（HTTP $code）。';
    }
    if (code == 409) return 'WebDAV 文件夹不存在或无法写入（HTTP 409）。';
    if (code == 412) return '远端已有同名快照，未覆盖（HTTP 412）。';
    if (code == 507) return 'WebDAV 空间不足（HTTP 507）。';
    return 'WebDAV $action失败（HTTP $code）。';
  }
}
