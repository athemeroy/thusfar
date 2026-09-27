import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/ask.dart' as ask;
import 'package:thusfar_core/http_server.dart';
import 'package:thusfar_core/jobs.dart';
import 'package:thusfar_core/marginalia.dart' as marginalia;
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/pipeline/llm.dart' as llm;

typedef Json = Map<String, Object?>;

class NoNetwork implements llm.ChatTransport {
  int calls = 0;
  @override
  Future<llm.ChatResponse> post(llm.ChatRequest r, Duration timeout) async {
    calls++;
    throw StateError('No model network is permitted in HTTP tests');
  }
}

class ProbeTransport implements llm.ChatTransport {
  final List<llm.ChatRequest> calls = <llm.ChatRequest>[];
  @override
  Future<llm.ChatResponse> post(
    llm.ChatRequest request,
    Duration timeout,
  ) async {
    calls.add(request);
    return llm.ChatResponse(
      200,
      'text/event-stream',
      Stream<List<int>>.value(
        utf8.encode(
          'data: {"choices":[{"delta":{"content":"可以"}}]}\n\ndata: [DONE]\n\n',
        ),
      ),
    );
  }
}

class DormantWorker extends Worker {
  DormantWorker(super.books) : super(enabled: false, clock: () => 1750000000);
  @override
  Future<void> start() async {}
}

class OfflineAsk extends ask.AskService {
  @override
  Future<Json> answer(
    Directory root,
    String question,
    int pos, {
    ask.AskEvent? onEvent,
    ask.AskCancellation? cancellation,
    void Function()? onSettled,
  }) async {
    onEvent?.call('stage', <String, Object?>{'text': '检索已读原文'});
    final Json result = <String, Object?>{
      'answer': '只根据已经读过的内容。',
      'citations': <Object?>[],
    };
    onEvent?.call('answer', result);
    onSettled?.call();
    return result;
  }
}

class NativeAskBackend extends ask.AskBackend {
  NativeAskBackend({this.pending});
  final Completer<String>? pending;
  int calls = 0, guards = 0;
  @override
  Future<(String, Json)> route(String question) async => (
    'other',
    <String, Object?>{},
  );
  @override
  Future<String> complete(
    String model,
    List<Map<String, String>> messages, {
    required int maxTokens,
    required double temperature,
    required double timeout,
  }) async {
    calls++;
    return pending == null ? '阿 Q 在原文里已经出现。[1]' : pending!.future;
  }

  @override
  Future<Json> guard(String material, String text) async {
    guards++;
    return <String, Object?>{
      'a': <String, Object?>{'verdict': 'ok', 'p': .9},
    };
  }
}

class PendingMarginaliaBackend extends marginalia.MarginaliaBackend {
  final Completer<String> pending = Completer<String>();
  int calls = 0, guards = 0;
  @override
  Future<String> complete(
    String model,
    List<Map<String, String>> messages, {
    required int maxTokens,
    required double temperature,
    required double timeout,
    required int retries,
  }) {
    calls++;
    return pending.future;
  }

  @override
  Future<Json> guard(String passage, Json items) async {
    guards++;
    return <String, Object?>{};
  }
}

class Reply {
  Reply(this.code, this.headers, this.bytes, this.connection);
  final int code;
  final Map<String, String> headers;
  final List<int> bytes;
  final HttpConnectionInfo? connection;
  Object? get json => jsonDecode(utf8.decode(bytes));
  String get text => utf8.decode(bytes);
}

void copyTree(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final FileSystemEntity entity in from.listSync(
    recursive: true,
    followLinks: false,
  )) {
    final String suffix = entity.path.substring(from.path.length);
    if (entity is Directory) {
      Directory(to.path + suffix).createSync(recursive: true);
    } else if (entity is File) {
      File(to.path + suffix).parent.createSync(recursive: true);
      entity.copySync(to.path + suffix);
    } else {
      throw StateError('Unexpected link in fixture');
    }
  }
}

Object? stable(Object? value) {
  if (value is List) return value.map(stable).toList();
  if (value is Map)
    return <String, Object?>{
      for (final MapEntry<Object?, Object?> e in value.entries)
        if (!<String>{
          'updated',
          'created',
          'added',
          'exported',
          't',
          'version',
        }.contains(e.key))
          e.key! as String: stable(e.value),
    };
  return value;
}

void main() {
  late Directory data;
  late YeduHttpServer server;
  late HttpClient client;
  late Map<String, String> savedEnv;
  late llm.ChatTransport savedTransport;
  late NoNetwork network;
  final List<Object> serverErrors = <Object>[];
  setUp(() {
    data = Directory.systemTemp.createTempSync('thusfar-http-');
    Directory(data.path + '/books').createSync();
    copyTree(
      Directory('../oracle/corpus/snapshots/aq_complete'),
      Directory(data.path + '/books/aq_complete'),
    );
    savedEnv = Map<String, String>.of(environ);
    savedTransport = llm.transport;
    llm.transport = network = NoNetwork();
    client = HttpClient()..autoUncompress = false;
    serverErrors.clear();
  });
  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
    llm.transport = savedTransport;
    environ
      ..clear()
      ..addAll(savedEnv);
    if (data.existsSync()) data.deleteSync(recursive: true);
    expect(network.calls, 0, reason: 'HTTP acceptance is fully offline');
  });
  Future<void> start({
    String passcode = '',
    bool localMode = true,
    int askConcurrency = 2,
    HttpMarginalia? marginaliaHandler,
    Duration answerTimeout = const Duration(seconds: 180),
    Duration readTimeout = const Duration(seconds: 30),
    ask.AskService? askService,
    marginalia.MarginaliaService? marginaliaService,
    double Function()? clock,
    bool dormant = true,
  }) async {
    server = YeduHttpServer(
      data: data,
      web: Directory('../web'),
      passcode: passcode,
      localMode: localMode,
      cookieSecure: false,
      release: '1.7.5',
      clock: clock ?? () => 1750000000,
      sleep: (_) async {},
      worker: dormant ? DormantWorker(Directory(data.path + '/books')) : null,
      askService: askService ?? OfflineAsk(),
      marginaliaService: marginaliaService,
      askConcurrency: askConcurrency,
      marginaliaHandler: marginaliaHandler,
      answerTimeout: answerTimeout,
      readTimeout: readTimeout,
      onError: (Object e, StackTrace _) {
        serverErrors.add(e);
      },
    );
    await server.start(port: 0);
  }

  Future<Reply> request(
    String method,
    String path, {
    Object? json,
    List<int>? raw,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final HttpClientRequest req = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:' + server.port.toString() + path),
    );
    req.headers.set('accept-encoding', 'identity');
    headers.forEach(req.headers.set);
    final List<int> bytes =
        raw ?? (json == null ? <int>[] : utf8.encode(jsonEncode(json)));
    req.contentLength = bytes.length;
    if (bytes.isNotEmpty) req.add(bytes);
    final HttpClientResponse response = await req.close().timeout(
      const Duration(seconds: 5),
    );
    final HttpConnectionInfo? connection = response.connectionInfo;
    final Map<String, String> out = <String, String>{};
    response.headers.forEach((String key, List<String> values) {
      out[key] = values.join(', ');
    });
    return Reply(
      response.statusCode,
      out,
      await response
          .fold<List<int>>(
            <int>[],
            (List<int> previous, List<int> next) => previous..addAll(next),
          )
          .timeout(const Duration(seconds: 5)),
      connection,
    );
  }

  test(
    'the 60 recorded Python HTTP cases preserve routing and durable book behavior',
    () async {
      await start();
      final List<Json> fixtures =
          File('../oracle/goldens/http/aq_complete.jsonl')
              .readAsLinesSync()
              .map((String line) => jsonDecode(line) as Json)
              .toList();
      final Map<String, Reply> replies = <String, Reply>{};
      for (final Json fixture in fixtures) {
        final String name = fixture['route']! as String;
        final Json req = fixture['request']! as Json,
            expected = fixture['response']! as Json;
        final Map<String, String> headers =
            (req['headers']! as Map<String, Object?>).cast<String, String>();
        if (name == 'static-304')
          headers['If-None-Match'] = replies['static-root']!.headers['etag']!;
        if (name == 'book-process-post') {
          server.settings.save(<String, Object?>{
            'protocol': 'openai',
            'base_url': 'https://example.invalid/v1',
            'model': 'offline-fixture',
            'api_key': 'offline-test-only',
          });
        }
        final Reply response = await request(
          req['method']! as String,
          req['path']! as String,
          json: req['body_json'],
          raw:
              req['body_base64'] == null
                  ? null
                  : base64Decode(req['body_base64']! as String),
          headers: headers,
        );
        replies[name] = response;
        expect(response.code, expected['status'], reason: name);
        final Map<String, Object?> eh = (expected['headers']! as Json);
        if (eh.containsKey('content-type'))
          expect(
            response.headers['content-type'],
            eh['content-type'],
            reason: name,
          );
        if (eh.containsKey('cache-control'))
          expect(
            response.headers['cache-control'],
            eh['cache-control'],
            reason: name,
          );
        if (expected.containsKey('body_json')) {
          final Object? actual = response.json;
          if (<String>{
            'health',
            'settings-get',
            'settings-put',
            'settings-test',
            'book-marginalia-empty-cues',
            'book-marginalia-empty-cues-cached',
          }.contains(name)) {
            if (name.startsWith('settings-')) {
              if (name == 'settings-test') {
                expect((actual as Json)['ok'], false);
              } else {
                expect((actual as Json)['protocol'], 'openai');
                expect(actual.containsKey('api_key'), false);
              }
            } else if (name.startsWith('book-marginalia')) {
              final Json result = actual as Json;
              expect(result['items'], isEmpty);
              expect(result['cached'], name.endsWith('-cached'));
            } else {
              expect(
                (actual as Json).keys.toSet(),
                (expected['body_json']! as Json).keys.toSet(),
              );
            }
          } else {
            // Cost estimates follow the currently configured model; tests switch
            // to an explicit offline model before the process endpoint.
            Object? normalize(Object? value) {
              final Object? result = stable(value);
              void removeEstimate(Object? row) {
                if (row is Json) {
                  row.remove('est');
                  for (final Object? v in row.values) {
                    removeEstimate(v);
                  }
                } else if (row is List) {
                  for (final Object? v in row) {
                    removeEstimate(v);
                  }
                }
              }

              if (name.startsWith('books-import')) removeEstimate(result);
              return result;
            }

            expect(
              normalize(actual),
              normalize(expected['body_json']),
              reason: name,
            );
          }
        } else if (!<String>{'static-gzip', 'static-root'}.contains(name)) {
          expect(
            response.bytes,
            base64Decode(expected['body_base64'] as String? ?? ''),
            reason: name,
          );
        }
      }
      expect(fixtures, hasLength(60));
      expect(serverErrors, isEmpty);
      expect(
        Directory(data.path + '/trash').listSync().whereType<Directory>(),
        hasLength(3),
      );
    },
  );

  test(
    'login cookies enforce signature expiry, passcode and same-origin writes',
    () async {
      await start(passcode: 'local-test-passcode');
      expect((await request('GET', '/api/books')).code, 401);
      expect(
        (await request(
          'POST',
          '/api/login',
          json: <String, Object?>{'code': 'wrong'},
        )).code,
        401,
      );
      final Reply login = await request(
        'POST',
        '/api/login',
        json: <String, Object?>{'code': 'local-test-passcode'},
      );
      final String cookie = login.headers['set-cookie']!.split(';').first;
      expect(login.headers['set-cookie'], contains('HttpOnly'));
      expect(login.headers['set-cookie'], contains('SameSite=Lax'));
      expect(
        (await request(
          'GET',
          '/api/books',
          headers: <String, String>{'Cookie': cookie},
        )).code,
        200,
      );
      expect(
        (await request(
          'GET',
          '/api/books',
          headers: <String, String>{'Cookie': cookie + '0'},
        )).code,
        401,
      );
      expect(
        (await request(
          'PUT',
          '/api/reading-list',
          json: <String, Object?>{},
          headers: <String, String>{
            'Cookie': cookie,
            'Origin': 'https://foreign.invalid',
          },
        )).code,
        403,
      );
      for (int i = 0; i < 8; i++) {
        await request(
          'POST',
          '/api/login',
          json: <String, Object?>{'code': 'wrong'},
        );
      }
      final Reply limited = await request(
        'POST',
        '/api/login',
        json: <String, Object?>{'code': 'wrong'},
      );
      expect(limited.code, 429);
      expect(limited.headers['retry-after'], '60');
      expect(
        (await request(
          'POST',
          '/api/login',
          json: <String, Object?>{'code': 'wrong'},
        )).code,
        429,
      );
    },
  );

  test(
    'SSE publishes staged answers and invalid body errors before opening the stream',
    () async {
      await start();
      final Reply invalid = await request(
        'POST',
        '/api/books/aq_complete/ask',
        json: <String, Object?>{'q': 3, 'pos': 900},
      );
      expect(invalid.code, 400);
      expect(invalid.json, <String, Object?>{'error': '问题必须是文字'});
      final Reply reply = await request(
        'POST',
        '/api/books/aq_complete/ask',
        json: <String, Object?>{'q': '读到这里发生了什么', 'pos': 900},
      );
      expect(reply.code, 200);
      expect(reply.headers['content-type'], 'text/event-stream; charset=utf-8');
      expect(reply.text, contains('event: stage\n'));
      expect(reply.text, contains('event: answer\n'));
      expect(reply.text, contains('只根据已经读过的内容。'));
    },
  );

  test(
    'shared AI permit remains owned after an HTTP timeout until work settles',
    () async {
      final Completer<Json> pending = Completer<Json>();
      await start(
        askConcurrency: 1,
        answerTimeout: const Duration(milliseconds: 5),
        marginaliaHandler: (_, __) => pending.future,
      );
      final Reply timed = await request(
        'POST',
        '/api/books/aq_complete/marginalia',
        json: <String, Object?>{},
      );
      expect(timed.code, 408);
      final Reply busy = await request(
        'POST',
        '/api/books/aq_complete/marginalia',
        json: <String, Object?>{},
      );
      expect(busy.code, 429);
      pending.complete(<String, Object?>{'ok': true});
      await Future<void>.delayed(Duration.zero);
      final Reply available = await request(
        'POST',
        '/api/books/aq_complete/marginalia',
        json: <String, Object?>{},
      );
      expect(available.code, 200);
    },
  );

  test(
    'nonlocal mode hides settings and graph cutoffs never return future rows',
    () async {
      await start(localMode: false);
      expect((await request('GET', '/api/settings')).code, 404);
      final Reply result = await request(
        'GET',
        '/api/books/aq_complete/kg?from=-1&to=900',
      );
      expect(result.code, 200);
      for (final Object? row
          in (result.json as Json)['records']! as List<Object?>) {
        expect((row! as Json)['p']! as num, lessThanOrEqualTo(900));
      }
      expect(
        (await request('GET', '/api/books/aq_complete/kg?to=wrong')).code,
        400,
      );
      expect((await request('GET', '/../server/app.py')).code, 404);
      expect(
        (await request(
          'POST',
          '/api/books/aq_complete/progress',
          json: <Object?>[],
        )).code,
        400,
      );
    },
  );

  test(
    'connection test uses unsaved protocol settings without changing active configuration',
    () async {
      await start();
      final Json saved = server.settings.read();
      final Map<String, String> active = Map<String, String>.of(environ);
      final ProbeTransport probe = ProbeTransport();
      llm.transport = probe;
      final Reply reply = await request(
        'POST',
        '/api/settings/test',
        json: <String, Object?>{
          'protocol': 'openai',
          'base_url': 'https://preview.invalid/v1',
          'model': 'preview-model',
          'api_key': 'test-only-unsaved',
        },
      );
      expect(reply.code, 200);
      expect((reply.json! as Json)['ok'], true);
      expect(probe.calls, hasLength(1));
      expect(probe.calls.single.url.host, 'preview.invalid');
      expect(
        (jsonDecode(probe.calls.single.body) as Json)['model'],
        'preview-model',
      );
      expect(server.settings.read(), saved);
      expect(environ, active);
      expect(File(data.path + '/.model.env').existsSync(), false);
      expect(
        (await request('POST', '/api/settings/test', json: <Object?>[])).code,
        400,
      );
      expect(probe.calls, hasLength(1));
    },
  );

  test(
    'local browser shell advertises settings without changing remote shell or cache validators',
    () async {
      await start();
      final Reply local = await request('GET', '/');
      expect(
        local.text,
        contains('<meta name="yedu-local-settings" content="true">'),
      );
      final Reply cached = await request(
        'GET',
        '/',
        headers: <String, String>{'If-None-Match': local.headers['etag']!},
      );
      expect(cached.code, 304);
      await server.close(force: true);
      await start(localMode: false);
      final Reply remote = await request(
        'GET',
        '/',
        headers: <String, String>{'If-None-Match': local.headers['etag']!},
      );
      expect(remote.code, 200);
      expect(remote.text, isNot(contains('name="yedu-local-settings"')));
      expect(remote.headers['etag'], isNot(local.headers['etag']));
    },
  );

  test(
    'native ask runs through source retrieval, guard, SSE and response cache offline',
    () async {
      final NativeAskBackend backend = NativeAskBackend();
      await start(askService: ask.AskService(backend: backend));
      environ['QUERY_TRANSLATION'] = '0';
      environ['JUDGE_RETRIEVAL'] = '0';
      final Json payload = <String, Object?>{'q': '阿 Q 是谁', 'pos': 900};
      final Reply first = await request(
        'POST',
        '/api/books/aq_complete/ask',
        json: payload,
      );
      expect(first.code, 200);
      expect(first.text, contains('event: route\n'));
      expect(first.text, contains('检查有没有剧透'));
      expect(first.text, contains('阿 Q 在原文里已经出现。'));
      final Reply cached = await request(
        'POST',
        '/api/books/aq_complete/ask',
        json: payload,
      );
      expect(cached.text, contains('"cached": true'));
      expect(backend.calls, 1);
      expect(backend.guards, 1);
      expect(serverErrors, isEmpty);
    },
  );

  test(
    'SSE deadline suppresses late answers while retaining the shared AI permit',
    () async {
      final Completer<String> pending = Completer<String>();
      final NativeAskBackend backend = NativeAskBackend(pending: pending);
      await start(
        askConcurrency: 1,
        answerTimeout: const Duration(milliseconds: 20),
        askService: ask.AskService(
          backend: backend,
          timeout: const Duration(milliseconds: 5),
        ),
      );
      environ['QUERY_TRANSLATION'] = '0';
      environ['JUDGE_RETRIEVAL'] = '0';
      final Reply timed = await request(
        'POST',
        '/api/books/aq_complete/ask',
        json: <String, Object?>{'q': '阿 Q 是谁', 'pos': 900},
      );
      expect(timed.code, 200);
      expect(timed.text, contains('event: error\n'));
      expect(timed.text, isNot(contains('event: answer\n')));
      expect(
        (await request(
          'POST',
          '/api/books/aq_complete/marginalia',
          json: <String, Object?>{},
        )).code,
        429,
      );
      pending.complete('这条迟到的回答不得发布');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(backend.guards, 0);
      expect(
        (await request(
          'POST',
          '/api/books/aq_complete/ask',
          json: <String, Object?>{'q': ''},
        )).code,
        400,
      );
    },
  );

  test(
    'native marginalia cancellation suppresses cache writes until the real request settles',
    () async {
      final PendingMarginaliaBackend backend = PendingMarginaliaBackend();
      await start(
        askConcurrency: 1,
        answerTimeout: const Duration(milliseconds: 20),
        marginaliaService: marginalia.MarginaliaService(
          backend: backend,
          timeout: const Duration(days: 1),
        ),
      );
      final File cache = File(data.path + '/books/aq_complete/marginalia.json');
      final String? before =
          cache.existsSync() ? cache.readAsStringSync() : null;
      final Reply timed = await request(
        'POST',
        '/api/books/aq_complete/marginalia',
        json: <String, Object?>{
          'mode': 'manual',
          'pos': 900,
          'start': 820,
          'end': 847,
          'persona': 'empathy',
        },
      );
      expect(timed.code, 408);
      expect(backend.calls, 1);
      expect(
        (await request(
          'POST',
          '/api/books/aq_complete/ask',
          json: <String, Object?>{'q': '阿 Q 是谁', 'pos': 900},
        )).code,
        429,
      );
      backend.pending.complete('不应该发布这条迟到的批注。');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(backend.guards, 0);
      expect(cache.existsSync() ? cache.readAsStringSync() : null, before);
      for (int i = 0; i < 2; i++) {
        expect(
          (await request(
            'POST',
            '/api/books/aq_complete/marginalia',
            json: <String, Object?>{},
          )).code,
          400,
        );
      }
    },
  );

  test(
    'unread process bodies are drained before the same TCP connection is reused',
    () async {
      await start(localMode: false);
      final Reply process = await request(
        'POST',
        '/api/books/aq_complete/process',
        json: <String, Object?>{},
      );
      final Reply next = await request('GET', '/api/books');
      expect(process.code, 200);
      expect(next.code, 200);
      expect(process.connection, isNotNull);
      expect(next.connection!.localPort, process.connection!.localPort);
      expect(next.json, isA<List<Object?>>());
    },
  );

  test(
    'persisted cookies survive service restart and expire after seven days',
    () async {
      double now = 1750000000;
      await start(passcode: 'restart-pass', clock: () => now);
      final Reply login = await request(
        'POST',
        '/api/login',
        json: <String, Object?>{'code': 'restart-pass'},
      );
      final String cookie = login.headers['set-cookie']!.split(';').first;
      final List<int> secret =
          File(data.path + '/.cookie-secret').readAsBytesSync();
      if (!Platform.isWindows)
        expect(File(data.path + '/.cookie-secret').statSync().mode & 511, 384);
      await server.close(force: true);
      await start(passcode: 'restart-pass', clock: () => now);
      expect(File(data.path + '/.cookie-secret').readAsBytesSync(), secret);
      expect(
        (await request(
          'GET',
          '/api/books',
          headers: <String, String>{'Cookie': cookie},
        )).code,
        200,
      );
      now += 7 * 86400 + 1;
      expect(
        (await request(
          'GET',
          '/api/books',
          headers: <String, String>{'Cookie': cookie},
        )).code,
        401,
      );
    },
  );

  test(
    'native default startup reconciles interrupted work without requesting a model',
    () async {
      final File state = File(data.path + '/books/aq_complete/status.json');
      state.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'state': 'running',
          'frontier': 100,
          'done': 1,
          'total': 9,
        }),
      );
      final File meta = File(data.path + '/books/aq_complete/meta.json');
      meta.writeAsStringSync(jsonEncode(<String, Object?>{'auto': true}));
      await start(dormant: false);
      await server.worker.waitIdle();
      final Json health = server.worker.health();
      expect(health['enabled'], false);
      expect(health['current'], isNull);
      expect((jsonDecode(state.readAsStringSync()) as Json)['state'], 'paused');
      expect(network.calls, 0);
    },
  );

  test(
    'backup conflicts and duplicate chapter indexes leave existing data intact',
    () async {
      await start();
      final Json exported =
          (await request('GET', '/api/books/aq_complete/export')).json! as Json;
      final Reply imported = await request(
        'POST',
        '/api/books/import',
        json: exported,
      );
      expect(imported.code, 200);
      final String id = (imported.json! as Json)['id']! as String;
      final File original = File(data.path + '/books/$id/kg.json');
      final List<int> bytes = original.readAsBytesSync();
      final Json changed = jsonDecode(jsonEncode(exported)) as Json;
      (changed['kg']! as Json)['log'] = <Object?>[];
      changed['mentions'] = <String, Object?>{};
      expect(
        (await request('POST', '/api/books/import', json: changed)).code,
        409,
      );
      expect(original.readAsBytesSync(), bytes);
      final Json duplicate = jsonDecode(jsonEncode(exported)) as Json;
      duplicate['mentions'] = <String, Object?>{
        '0': <Object?>[],
        '00': <Object?>[],
      };
      expect(
        (await request('POST', '/api/books/import', json: duplicate)).code,
        400,
      );
      expect(
        Directory(data.path + '/books').listSync().whereType<Directory>().where(
          (Directory d) => d.uri.pathSegments
              .where((String x) => x.isNotEmpty)
              .last
              .startsWith('.'),
        ),
        isEmpty,
      );
      expect(original.readAsBytesSync(), bytes);
    },
  );

  test(
    'partial request bodies time out without invoking a route or model',
    () async {
      await start(readTimeout: const Duration(milliseconds: 50));
      final Socket socket = await Socket.connect('127.0.0.1', server.port);
      final Future<String> reply = utf8.decoder
          .bind(socket)
          .join()
          .timeout(const Duration(seconds: 3));
      socket.write(
        'POST /api/login HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\nContent-Length: 25\r\nConnection: close\r\n\r\n{',
      );
      await socket.flush();
      final String received = await reply;
      expect(received, startsWith('HTTP/1.1 408'));
      expect(received, contains('请求超时'));
      socket.destroy();
    },
  );
}
