/// Native HTTP/1.1 reader service compatible with server/app.py.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../async_util.dart';
import '../errors.dart';
import '../pipeline/epub.dart';
import '../pipeline/lang.dart' as language;
import '../pipeline/models.dart' as models;
import '../pipeline/parse.dart' as parser;
import '../py/py_compat.dart';
import '../py/py_int.dart';
import '../py/py_json.dart';
import '../py/py_re.dart';
import '../py/py_repr.dart';
import 'ask.dart' as ask;
import 'jobs.dart';
import 'manual_entities.dart' as manual;
import 'marginalia.dart' as marginalia;
import 'model_settings.dart';
import 'notebook.dart' as notebook;
import 'reading_list.dart' as reading;
import 'storage.dart' as storage;
import 'temporal.dart' show foldEvidence;

part 'http_books.dart';
part 'http_transfer.dart';

typedef HttpJson = Map<String, Object?>;
typedef HttpMarginalia = Future<HttpJson> Function(Directory, HttpJson);
typedef HttpWho =
    Future<HttpJson> Function(HttpJson, List<HttpJson>, int, int, int);

bool _truth(Object? v) =>
    v != null &&
    v != false &&
    v != 0 &&
    (v is! String || v.isNotEmpty) &&
    (v is! List || v.isNotEmpty) &&
    (v is! Map || v.isNotEmpty);
HttpJson _map(Object? value) => value as HttpJson? ?? <String, Object?>{};
List<Object?> _list(Object? value) => value as List<Object?>? ?? <Object?>[];
List<HttpJson> _rows(Object? value) => _list(value).cast<HttpJson>();
String _message(Object error) =>
    error is PyException ? error.message : '$error';
String _hash(Object? value) =>
    sha256
        .convert(utf8.encode(PyJson.encode(value, ensureAscii: false)))
        .toString();
bool _same(Object? a, Object? b) {
  if (a is Map && b is Map)
    return a.length == b.length &&
        a.keys.every((Object? k) => b.containsKey(k) && _same(a[k], b[k]));
  if (a is List && b is List)
    return a.length == b.length &&
        List<int>.generate(
          a.length,
          (int i) => i,
        ).every((int i) => _same(a[i], b[i]));
  return a == b;
}

String _name(FileSystemEntity entity) =>
    entity.uri.pathSegments.where((String x) => x.isNotEmpty).last;
String _head(String value, int n) => String.fromCharCodes(value.runes.take(n));
int _queryInt(String? value, int fallback, String error) {
  if (value == null) return fallback;
  final BigInt? integer = tryPythonDecimal(value);
  if (integer == null ||
      integer < BigInt.from(-9223372036854775807) ||
      integer > BigInt.from(9223372036854775807))
    throw ValueError(error);
  return integer.toInt();
}

final class _JsonCache {
  final LinkedHashMap<String, (String, Object?, int)> entries =
      LinkedHashMap<String, (String, Object?, int)>();
  int bytes = 0;
  Object? get(File file) {
    if (!file.existsSync()) {
      evict(file.path);
      return null;
    }
    // Hash the bytes so a same-size atomic replacement or restored timestamp
    // cannot retain an old snapshot in a long-lived native service.
    final Uint8List raw = file.readAsBytesSync();
    final String fingerprint = sha256.convert(raw).toString();
    final (String, Object?, int)? hit = entries.remove(file.path);
    if (hit != null) {
      if (hit.$1 == fingerprint) {
        entries[file.path] = hit;
        return hit.$2;
      }
      bytes -= hit.$3;
    }
    final Object? value = jsonDecode(utf8.decode(raw));
    if (raw.length <= 64 * 1024 * 1024) {
      entries[file.path] = (fingerprint, value, raw.length);
      bytes += raw.length;
      while (entries.length > 128 || bytes > 96 * 1024 * 1024) {
        bytes -= entries.remove(entries.keys.first)!.$3;
      }
    }
    return value;
  }

  void evict(String path) {
    for (final String key in entries.keys.toList()) {
      if (key == path || key.startsWith(path + Platform.pathSeparator))
        bytes -= entries.remove(key)!.$3;
    }
  }
}

/// Bind with [start], then close with [close]. Constructor defaults run only
/// explicit processing actions; the CLI can opt into persisted automatic work.
class YeduHttpServer {
  YeduHttpServer({
    required this.data,
    required this.web,
    this.passcode = '',
    this.localMode = false,
    this.autoProcess = false,
    this.cookieSecure = true,
    this.release = '2.0.0-dev.3',
    this.readTimeout = const Duration(seconds: 30),
    this.answerTimeout = const Duration(seconds: 180),
    this.maxUpload = 200 * 1024 * 1024,
    int httpConcurrency = 32,
    int askConcurrency = 2,
    Worker? worker,
    ModelSettings? settings,
    ask.AskService? askService,
    marginalia.MarginaliaService? marginaliaService,
    HttpMarginalia? marginaliaHandler,
    HttpWho? whoHandler,
    double Function()? clock,
    Future<void> Function(Duration)? sleep,
    this.onError,
  }) : books = Directory(data.path + '/books'),
       _httpGate = Semaphore(httpConcurrency),
       _askGate = Semaphore(askConcurrency),
       settings = settings ?? ModelSettings(File(data.path + '/.model.env')),
       askService = askService ?? ask.AskService(timeout: answerTimeout),
       marginaliaService =
           marginaliaService ??
           marginalia.MarginaliaService(timeout: const Duration(days: 1)),
       _marginalia = marginaliaHandler,
       _who =
           whoHandler ??
           ((HttpJson book, List<HttpJson> log, int pos, int start, int end) =>
               ask.whoIs(book, log, pos, start, end)),
       _clock = clock ?? (() => DateTime.now().microsecondsSinceEpoch / 1e6),
       _sleep = sleep ?? Future<void>.delayed {
    this.worker =
        worker ??
        Worker(
          books,
          enabled: autoProcess,
          settings: () {
            if (localMode) this.settings.applyEnvironment();
            return WorkerSettings.environment();
          },
        );
  }

  final Directory data, web, books;
  final String passcode, release;
  final bool localMode, autoProcess, cookieSecure;
  final Duration readTimeout, answerTimeout;
  final int maxUpload;
  final ModelSettings settings;
  final ask.AskService askService;
  final marginalia.MarginaliaService marginaliaService;
  final HttpMarginalia? _marginalia;
  final HttpWho _who;
  final double Function() _clock;
  final Future<void> Function(Duration) _sleep;
  final void Function(Object, StackTrace)? onError;
  late final Worker worker;
  final Semaphore _httpGate, _askGate;
  final Semaphore _imports = Semaphore(2);
  final _JsonCache _cache = _JsonCache();
  final LinkedHashMap<String, List<double>> _attempts =
      LinkedHashMap<String, List<double>>();
  HttpServer? _server;
  List<int>? _secret;
  bool get isListening => _server != null;
  int get port => _server!.port;
  InternetAddress get address => _server!.address;

  Future<void> start({Object host = '127.0.0.1', int port = 18770}) async {
    if (_server != null) throw StateError('服务器已启动');
    books.createSync(recursive: true);
    _cookieSecret();
    if (localMode) settings.applyEnvironment();
    _server = await HttpServer.bind(host, port);
    // Let the body reader report HTTP 408 before the transport idle timer
    // closes a stalled request without a response.
    _server!.idleTimeout = readTimeout * 2;
    await worker.start();
    _server!.listen(
      (HttpRequest request) {
        unawaited(_dispatch(request));
      },
      onError: (Object error, StackTrace stack) => onError?.call(error, stack),
    );
  }

  Future<void> close({bool force = false}) async {
    final HttpServer? server = _server;
    _server = null;
    worker.stop();
    await server?.close(force: force);
    await worker.close();
    await worker.waitIdle();
  }

  Object? read(File file) => _cache.get(file);
  Object? _read(Directory root, String path) =>
      read(File(root.path + '/' + path));
  HttpJson _jsonFile(Directory root, String path) => _map(_read(root, path));
  void write(File file, Object? value) {
    storage.writeJson(file, value);
    _cache.evict(file.path);
  }

  void _write(Directory root, String path, Object? value) =>
      write(File(root.path + '/' + path), value);

  List<int> _cookieSecret() {
    if (_secret != null) return _secret!;
    data.createSync(recursive: true);
    final File file = File(data.path + '/.cookie-secret');
    final RandomAccessFile creation = File(
      data.path + '/.cookie-secret.lock',
    ).openSync(mode: FileMode.append);
    try {
      creation.lockSync(FileLock.blockingExclusive);
      if (!file.existsSync()) writePrivateFile(file, _randomHex(32));
      final String secret = file.readAsStringSync().trim();
      if (secret.length < 32) throw const ValueError('登录密钥文件无效，请检查数据目录');
    } finally {
      creation.unlockSync();
      creation.closeSync();
    }
    return _secret = utf8.encode(file.readAsStringSync().trim());
  }

  String _randomHex(int length) =>
      List<int>.generate(
        length,
        (_) => Random.secure().nextInt(256),
      ).map((int n) => n.toRadixString(16).padLeft(2, '0')).join();
  String _token() {
    final String payload =
        'v1.' + _clock().floor().toString() + '.' + _randomHex(12);
    return payload +
        '.' +
        Hmac(
          sha256,
          _cookieSecret(),
        ).convert(utf8.encode('$payload:$passcode')).toString();
  }

  bool _constantEqual(String a, String b) {
    final List<int> left = utf8.encode(a), right = utf8.encode(b);
    int difference = left.length ^ right.length;
    for (int i = 0; i < max(left.length, right.length); i++)
      difference |=
          (i < left.length ? left[i] : 0) ^ (i < right.length ? right[i] : 0);
    return difference == 0;
  }

  bool _authed(HttpRequest request) {
    if (passcode.isEmpty) return true;
    final String cookie = request.headers.value('cookie') ?? '';
    final RegExpMatch? match = RegExp(
      r'(?:^|;\s*)yedu=(v1\.([0-9]+)\.[a-f0-9]{24})\.([a-f0-9]{64})(?:;|$)',
    ).firstMatch(cookie);
    if (match == null) return false;
    final double age = _clock() - (int.tryParse(match[2]!) ?? -1);
    if (age < 0 || age > 7 * 86400) return false;
    final String expected =
        Hmac(
          sha256,
          _cookieSecret(),
        ).convert(utf8.encode(match[1]! + ':' + passcode)).toString();
    return _constantEqual(match[3]!, expected);
  }

  Future<void> _dispatch(HttpRequest request) async {
    if (!_httpGate.tryAcquire()) {
      request.response.statusCode = 503;
      request.response.persistentConnection = false;
      request.response.headers.set('retry-after', '5');
      request.response.contentLength = 0;
      await request.response.close();
      return;
    }
    final _Exchange exchange = _Exchange(this, request);
    try {
      await _route(exchange);
    } on TimeoutException {
      if (!exchange.sent) await exchange.error(408, '请求超时');
    } on BusyBook catch (error) {
      if (!exchange.sent) await exchange.error(409, error.message);
    } on ValueError catch (error) {
      if (!exchange.sent) await exchange.error(400, error.message);
    } on FormatException catch (error) {
      if (!exchange.sent) await exchange.error(400, '请求格式无效：' + error.message);
    } on SocketException {
      // A disconnected client cannot cause a second response.
    } on HttpException {
      // dart:io owns HTTP framing and reports a closed transport here.
    } on Object catch (error, stack) {
      onError?.call(error, stack);
      if (!exchange.sent) await exchange.error(500, '服务器出错了');
    } finally {
      if (!exchange.bodyRead) {
        try {
          await request.drain<void>().timeout(readTimeout);
        } on Object {
          /* connection closes */
        }
      }
      _httpGate.release();
    }
  }

  Future<void> _route(_Exchange x) async {
    final String path = x.request.uri.path, method = x.method;
    if (path == '/healthz' && method == 'GET') {
      final HttpJson state = worker.health();
      final bool healthy = state['enabled'] != true || state['alive'] == true;
      return x.json(<String, Object?>{
        'ok': healthy,
        'release': release,
      }, code: healthy ? 200 : 503);
    }
    if (!path.startsWith('/api/')) return _static(x, path);
    if (<String>['POST', 'PUT', 'DELETE'].contains(method)) {
      final String? origin = x.request.headers.value('origin');
      if (origin != null &&
          Uri.tryParse(origin)?.authority != x.request.headers.value('host'))
        return x.error(403, '只接受本站请求');
    }
    if (path == '/api/login' && method == 'POST') {
      final HttpJson payload = await x.object();
      final double now = _clock();
      final String key = x.request.connectionInfo?.remoteAddress.address ?? '';
      final List<double> attempts =
          (_attempts.remove(key) ?? <double>[])
              .where((double t) => now - t < 60)
              .toList();
      _attempts[key] = attempts;
      if (attempts.length >= 10)
        return x.json(
          <String, Object?>{'error': '尝试次数过多，请一分钟后重试'},
          code: 429,
          headers: <String, String>{'Retry-After': '60'},
        );
      _attempts[key] = <double>[...attempts, now];
      while (_attempts.length > 256) {
        _attempts.remove(_attempts.keys.first);
      }
      if (passcode.isNotEmpty &&
          !_constantEqual(pyStr(payload['code'] ?? ''), passcode)) {
        await _sleep(const Duration(seconds: 1));
        return x.error(401, '口令不对');
      }
      return x.json(
        <String, Object?>{'ok': true},
        headers: <String, String>{
          'Set-Cookie':
              'yedu=' +
              _token() +
              '; Path=/; Max-Age=604800; HttpOnly; SameSite=Lax' +
              (cookieSecure ? '; Secure' : ''),
        },
      );
    }
    if (path == '/api/me')
      return x.json(<String, Object?>{
        'ok': _authed(x.request),
        'passcode': passcode.isNotEmpty,
      });
    if (!_authed(x.request)) return x.error(401, '需要口令');
    if (path == '/api/logout' && method == 'POST')
      return x.json(
        <String, Object?>{'ok': true},
        headers: <String, String>{
          'Set-Cookie':
              'yedu=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax' +
              (cookieSecure ? '; Secure' : ''),
        },
      );
    if (path == '/api/health' && method == 'GET')
      return x.json(<String, Object?>{
        'release': release,
        'worker': worker.health(),
        'cache': <String, Object?>{
          'entries': _cache.entries.length,
          'serialized_bytes': _cache.bytes,
        },
      });
    if (path == '/api/settings' &&
        localMode &&
        <String>['GET', 'PUT'].contains(method)) {
      if (method == 'GET') return x.json(settings.public());
      final HttpJson payload = await x.object();
      if (worker.health()['current'] != null &&
          payload.containsKey('model') &&
          payload['model'] != settings.read()['model'])
        return x.error(409, '正在整理书籍，换模型前请先暂停整理；密钥和接口地址可以直接修改');
      return x.json(settings.save(payload));
    }
    if (path == '/api/settings/test' && localMode && method == 'POST') {
      final HttpJson payload = await x.object();
      return x.json(
        await settings.test(payload: payload.isEmpty ? null : payload),
      );
    }
    if (path == '/api/reading-list' &&
        <String>['GET', 'PUT'].contains(method)) {
      final HttpJson? payload = method == 'PUT' ? await x.object() : null;
      final HttpJson current =
          _read(data, 'reading-list.json') as HttpJson? ?? reading.empty();
      if (payload == null) return x.json(current);
      final (
        HttpJson updated,
        bool conflict,
      ) = reading.apply(current, payload, (String id) {
        final Directory? root = bookDirectory(id);
        return root != null && !_truth(_jsonFile(root, 'meta.json')['hidden']);
      }, now: _clock);
      if (conflict)
        return x.json(<String, Object?>{
          'error': '另一台设备更新了书单，请选择要保留的顺序',
          'list': current,
        }, code: 409);
      if (!identical(updated, current))
        _write(data, 'reading-list.json', updated);
      return x.json(updated);
    }
    if (path == '/api/books' && method == 'GET') {
      final List<HttpJson> result = <HttpJson>[];
      for (final Directory root
          in books.listSync(followLinks: false).whereType<Directory>()) {
        if (_name(root).startsWith('.') ||
            !File(root.path + '/book.json').existsSync() ||
            _truth(_jsonFile(root, 'meta.json')['hidden']))
          continue;
        result.add(bookSummary(_name(root), root));
      }
      result.sort(
        (HttpJson a, HttpJson b) => max(
          (_map(b['progress'])['t'] as num?) ?? 0,
          (b['added'] as num?) ?? 0,
        ).compareTo(
          max(
            (_map(a['progress'])['t'] as num?) ?? 0,
            (a['added'] as num?) ?? 0,
          ),
        ),
      );
      return x.json(result);
    }
    if (method == 'POST' &&
        <String>['/api/books', '/api/books/import'].contains(path)) {
      if (!_imports.tryAcquire()) return x.error(429, '正在导入其他书籍，请稍后重试');
      try {
        if (path.endsWith('/import')) {
          await _restore(x);
        } else {
          await _upload(x);
        }
      } finally {
        _imports.release();
      }
      return;
    }
    final RegExpMatch? match = RegExp(
      r'^/api/books/([A-Za-z0-9_-]+)(/.*)?$',
    ).firstMatch(path);
    if (match == null) return x.error(404, '没有这个接口');
    final String id = match[1]!, rest = match[2] ?? '';
    final Directory? root = bookDirectory(id);
    if (root == null) return x.error(404, '没有这本书');
    return _bookRoute(x, id, root, rest);
  }

  Future<void> _static(_Exchange x, String incoming) async {
    String path = Uri.decodeComponent(incoming);
    if (path.isEmpty || path == '/' || !_name(File(path)).contains('.'))
      path = '/index.html';
    if (path == '/favicon.ico') path = '/icon.svg';
    File file = File(web.path + '/' + path.replaceFirst(RegExp(r'^/+'), ''));
    try {
      final String base = web.resolveSymbolicLinksSync(),
          resolved = file.resolveSymbolicLinksSync();
      if (!resolved.startsWith(base + Platform.pathSeparator) ||
          !File(resolved).existsSync())
        return await x.send(404, utf8.encode('not found'), 'text/plain');
      file = File(resolved);
    } on FileSystemException {
      return x.send(404, utf8.encode('not found'), 'text/plain');
    }
    final FileStat stat = file.statSync();
    final String name = _name(file).toLowerCase();
    final bool localShell = localMode && name == 'index.html';
    final String etag =
        '"' +
        (stat.modified.microsecondsSinceEpoch * 1000).toRadixString(16) +
        '-' +
        stat.size.toRadixString(16) +
        (localShell ? '-local-settings' : '') +
        '"';
    final String cache =
        <String>['.html', '.js', '.css', '.webmanifest'].any(name.endsWith)
            ? 'no-cache'
            : 'public, max-age=2592000';
    final Map<String, String> headers = <String, String>{
      'Cache-Control': cache,
      'ETag': etag,
    };
    if ((x.request.headers.value('if-none-match') ?? '')
        .replaceAll('W/', '')
        .split(', ')
        .contains(etag))
      return x.send(304, <int>[], '', headers: headers);
    final List<int> bytes =
        localShell
            ? utf8.encode(
              file.readAsStringSync().replaceFirst(
                RegExp('</head>', caseSensitive: false),
                '<meta name="yedu-local-settings" content="true">\n</head>',
              ),
            )
            : file.readAsBytesSync();
    return x.send(200, bytes, _mime(name), headers: headers);
  }
}

String _mime(String name) {
  final String extension = name.toLowerCase().split('.').last;
  return <String, String>{
        'html': 'text/html; charset=utf-8',
        'css': 'text/css; charset=utf-8',
        'js': 'text/javascript; charset=utf-8',
        'json': 'application/json; charset=utf-8',
        'webmanifest': 'application/manifest+json',
        'svg': 'image/svg+xml',
        'png': 'image/png',
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'gif': 'image/gif',
        'webp': 'image/webp',
        'ico': 'image/vnd.microsoft.icon',
        'woff2': 'font/woff2',
        'woff': 'font/woff',
        'ttf': 'font/ttf',
        'txt': 'text/plain; charset=utf-8',
        'epub': 'application/epub+zip',
      }[extension] ??
      'application/octet-stream';
}

final class _Exchange {
  _Exchange(this.server, this.request);
  final YeduHttpServer server;
  final HttpRequest request;
  bool sent = false, bodyRead = false;
  String get method => request.method == 'HEAD' ? 'GET' : request.method;
  Future<Uint8List> body([int limit = 1 << 20]) async {
    if (bodyRead) throw const ValueError('请求正文已经读取');
    bodyRead = true;
    if (request.headers.value('transfer-encoding') != null ||
        (request.headers['content-length']?.length ?? 0) > 1)
      throw const ValueError('请求长度格式无效');
    final int length = request.contentLength < 0 ? 0 : request.contentLength;
    if (length > limit) throw const ValueError('请求太大');
    final BytesBuilder bytes = BytesBuilder(copy: false);
    final Completer<Uint8List> received = Completer<Uint8List>();
    Timer? timer;
    void fail(Object error, [StackTrace? trace]) {
      timer?.cancel();
      if (!received.isCompleted) received.completeError(error, trace);
    }

    void arm() {
      timer?.cancel();
      timer = Timer(server.readTimeout, () => fail(TimeoutException('请求正文超时')));
    }

    arm();
    // Keep listening until the response closes the failed connection. Cancelling
    // HttpRequest's stream first also closes the socket and loses the 408 body.
    request.listen(
      (List<int> chunk) {
        if (received.isCompleted) return;
        bytes.add(chunk);
        if (bytes.length > limit) {
          fail(const ValueError('请求太大'));
        } else {
          arm();
        }
      },
      onError: fail,
      onDone: () {
        timer?.cancel();
        if (received.isCompleted) return;
        if (bytes.length != length) {
          fail(const ValueError('请求没有完整传输'));
        } else {
          received.complete(bytes.takeBytes());
        }
      },
    );
    return received.future;
  }

  Future<HttpJson> object() async {
    final Uint8List bytes = await body();
    final Object? value =
        bytes.isEmpty ? <String, Object?>{} : jsonDecode(utf8.decode(bytes));
    if (value is! HttpJson) throw const ValueError('请求必须是 JSON 对象');
    return value;
  }

  Future<void> error(int code, String message) {
    request.response.persistentConnection = false;
    return json(<String, Object?>{'error': message}, code: code);
  }

  Future<void> json(
    Object? value, {
    int code = 200,
    Map<String, String> headers = const <String, String>{},
  }) => send(
    code,
    utf8.encode(PyJson.encode(value, ensureAscii: false, compact: true)),
    'application/json; charset=utf-8',
    headers: <String, String>{'Cache-Control': 'no-store', ...headers},
  );
  Future<void> send(
    int code,
    List<int> input,
    String type, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    if (sent) return;
    sent = true;
    final HttpResponse response = request.response;
    response.statusCode = code;
    if (type.isNotEmpty) response.headers.set('Content-Type', type);
    response.headers.set('X-Content-Type-Options', 'nosniff');
    response.headers.set('X-Yedu-Release', server.release);
    headers.forEach(response.headers.set);
    List<int> bytes = input;
    if (input.length > 2048 &&
        (type.startsWith('text/') ||
            type.contains('json') ||
            type.contains('javascript') ||
            type.contains('svg')) &&
        (request.headers.value('accept-encoding') ?? '').contains('gzip') &&
        !headers.containsKey('Content-Encoding')) {
      bytes = gzip.encode(input);
      response.headers.set('Content-Encoding', 'gzip');
      response.headers.set('Vary', 'Accept-Encoding');
    }
    if (code != 304) response.contentLength = bytes.length;
    if (request.method != 'HEAD' && code != 304) response.add(bytes);
    await response.close();
  }
}
