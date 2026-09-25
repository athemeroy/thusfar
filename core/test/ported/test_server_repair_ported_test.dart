// Contracts translated from tests/test_server_repair.py. The multi-step
// adapters are test-only harnesses for the eventual Dart service and worker.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'contract_invoker.dart';

typedef Json = Map<String, Object?>;

Json bookFixture({bool image = false}) => {
  'title': 'Fixture',
  'author': 'Tester',
  'len': 12,
  'lang': 'en',
  'notes': <String, Object?>{},
  'blocks': [
    {'k': 'p', 't': 'Alice came.', 'o': 0, 'fn': <Object?>[]},
    if (image) {'k': 'img', 't': '', 'o': 11, 'src': 'cover.png'},
  ],
  'cover': image ? 'cover.png' : null,
  'chapters': [
    {
      'title': 'One',
      'b0': 0,
      'b1': image ? 2 : 1,
      'o0': 0,
      'o1': 12,
      'kind': 'body',
    },
  ],
};

Json bookDirectory({bool image = false, String state = 'done'}) => {
  'book.json': bookFixture(image: image),
  'meta.json': {'auto': false},
  'status.json': {'state': state, 'frontier': 12},
  'kg.json': {
    'log': [
      {'t': 'person', 'p': 1, 'id': 'p1', 'name': 'Alice'},
    ],
  },
  'mentions/0000.json': [
    [0, 5, 'p1'],
  ],
  if (image)
    'img/cover.png': {'base64': base64Encode(utf8.encode('fixture-image'))},
};

/// Runs an isolated service using only synthetic files and recorded operations.
/// `steps` accepts request, parallel, writeJson, writeText, set, lease, and
/// patchedRequest operations. A request may use `bodyFromResponse` and
/// `bodyPatch` (JSON-path set/remove/append), or `{response:N:key}` in its path.
/// `responses` contains status, headers, decoded json/text/bodyBytes in request
/// order; `files` is the final relative-path snapshot. `calls` captures parse,
/// judge and worker invocations. Model/network calls are forbidden by default.
Json httpRun(
  List<Json> steps, {
  Json? fixture,
  Json? books,
  Json dataFiles = const {},
  Json options = const {},
}) =>
    callPorted('server.app.Handler#scripted_http', {
          'books': books ?? {'fixture': fixture ?? bookDirectory()},
          'dataFiles': dataFiles,
          'web': {'index.html': 'fixture'},
          'steps': steps,
          'options': {
            'workerEnabled': false,
            'forbidModelCalls': true,
            ...options,
          },
        })
        as Json;

Json req(String method, String path, {Object? body, Json headers = const {}}) =>
    {
      'request': {
        'method': method,
        'path': path,
        if (body != null) 'body': body,
        if (headers.isNotEmpty) 'headers': headers,
      },
    };

Json obj(Object? value) => value as Json;
List<Object?> array(Object? value) => value as List<Object?>;
List<Json> responses(Json run) => array(run['responses']).cast<Json>();
Json at(Json run, int index) => responses(run)[index];
Json body(Json response) => obj(response['json']);
Json files(Json run) => obj(run['files']);
List<Object?> tuple(Object? value) => array(obj(value)[r'$tuple']);

/// Captures ordered stream events and mocked callback calls of the real ask
/// owner. `replies` is a deterministic script for route/retrieve/chat/guard.
Json answerRun(Json input, Json replies) =>
    callPorted('server.ask.answer#scripted', {
          'input': input,
          'replies': replies,
        })
        as Json;

/// Runs a real cache or worker with synthetic files, fixed timing, and
/// injected read/spawn outcomes; returns state snapshots and call counts.
Json stateRun(String id, Json input) => callPorted(id, input) as Json;

void main() {
  test(
    "tests.test_server_repair.HTTPRepair.test_old_epub_without_language_gets_english_shelf_estimate",
    () {
      final book = bookFixture()..remove('lang');
      obj(array(book['blocks']).first)['t'] =
          List.filled(20, 'Alice met Bob at the old house. ').join();
      final fixture = {...bookDirectory(), 'book.json': book};
      final run = httpRun([
        {
          'prepareShelf': {
            'book': {'title': 'Fixture', 'len': 12, 'lang': null},
          },
        },
        req('GET', '/api/books'),
      ], fixture: fixture);
      expect(obj(run['shelfMetadata'])['lang'], 'en');
      expect(at(run, 0)['status'], 200);
      expect(obj(array(at(run, 0)['json']).first)['lang'], 'en');
    },
    skip:
        "Dart owner server.app.Handler#scripted_http, server.storage and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_upload_never_calls_judge_and_concurrent_same_upload_is_idempotent",
    () {
      final upload = req(
        'POST',
        '/api/books',
        body: utf8.encode('Alice came.\nBob left.'),
        headers: {'X-Filename': 'fixture.txt'},
      );
      final run = httpRun([
        {
          'parallel': [upload['request'], upload['request']],
          'barrier': 'parse_file',
        },
      ], books: {});
      expect(responses(run).map((r) => r['status']).toList(), [200, 200]);
      final id = body(at(run, 0))['id'];
      expect(body(at(run, 1))['id'], id);
      final imported = obj(obj(files(run)['books'])['$id']);
      expect(obj(imported['book.json'])['genre_provisional'], isTrue);
      expect(body(at(run, 0))['auto'], isFalse);
      expect(array(run['temporaryBookPaths']), isEmpty);
      expect(obj(run['calls'])['judge'], 0);
    },
    skip:
        "Dart owner server.app.Handler#scripted_http, server.jobs.Worker and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_export_import_preserves_images_graph_progress_and_snapshot_state",
    () {
      final run = httpRun(
        [
          req('GET', '/api/books/fixture/export'),
          {
            'request': {
              'method': 'POST',
              'path': '/api/books/import',
              'bodyFromResponse': 0,
            },
          },
          {
            'request': {
              'method': 'GET',
              'path': '/api/books/{response:1:id}/img/cover.png',
            },
          },
        ],
        fixture: bookDirectory(image: true, state: 'running'),
        dataFiles: {
          'progress.json': {
            'fixture': {'pos': 7, 'cutoff': 12, 't': 1},
          },
        },
      );
      expect(at(run, 0)['status'], 200);
      expect(body(at(run, 0))['format'], 'yedu-book/2');
      expect(at(run, 1)['status'], 200);
      final restored = body(at(run, 1));
      expect(obj(restored['status'])['state'], 'paused');
      final progress = obj(restored['progress']);
      expect(
        [progress['pos'], progress['cutoff'], progress['pct']],
        [7, 12, 100],
      );
      expect(at(run, 2)['status'], 200);
      expect(array(at(run, 2)['bodyBytes']), utf8.encode('fixture-image'));
      final imported = obj(obj(files(run)['books'])['${restored['id']}']);
      expect(imported['mentions/0000.json'], [
        [0, 5, 'p1'],
      ]);
    },
    skip:
        "Dart owner server.app.Handler#scripted_http and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_import_rejects_bad_hash_and_unsorted_graph_without_publication",
    () {
      final run = httpRun([
        req('GET', '/api/books/fixture/export'),
        {
          'request': {
            'method': 'POST',
            'path': '/api/books/import',
            'bodyFromResponse': 0,
            'bodyPatch': [
              {
                'op': 'set',
                'path': ['assets', 'cover.png', 'sha256'],
                'value': List.filled(64, '0').join(),
              },
            ],
          },
        },
        {
          'request': {
            'method': 'POST',
            'path': '/api/books/import',
            'bodyFromResponse': 0,
            'bodyPatch': [
              {
                'op': 'append',
                'path': ['kg', 'log'],
                'value': {'t': 'person', 'p': 0, 'id': 'p2', 'name': 'Bob'},
              },
            ],
          },
        },
      ], fixture: bookDirectory(image: true));
      expect([at(run, 1)['status'], at(run, 2)['status']], [400, 400]);
      expect(obj(files(run)['books']).keys.toList(), ['fixture']);
    },
    skip:
        "Dart owner server.app.Handler#scripted_http and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_legacy_text_export_import_works_but_missing_images_are_explicit",
    () {
      final legacy = [
        {
          'op': 'set',
          'path': ['format'],
          'value': 'yedu-book/1',
        },
        {
          'op': 'remove',
          'path': ['assets'],
        },
      ];
      final run = httpRun([
        req('GET', '/api/books/fixture/export'),
        {
          'request': {
            'method': 'POST',
            'path': '/api/books/import',
            'bodyFromResponse': 0,
            'bodyPatch': legacy,
          },
        },
        {
          'request': {
            'method': 'POST',
            'path': '/api/books/import',
            'bodyFromResponse': 0,
            'bodyPatch': [
              ...legacy,
              {
                'op': 'set',
                'path': ['book'],
                'value': bookFixture(image: true),
              },
            ],
          },
        },
      ]);
      expect([at(run, 1)['status'], at(run, 2)['status']], [200, 400]);
    },
    skip:
        "Dart owner server.app.Handler#scripted_http and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_conflicting_snapshot_is_not_silently_reused_or_overwritten",
    () {
      final run = httpRun([
        req('GET', '/api/books/fixture/export'),
        {
          'request': {
            'method': 'POST',
            'path': '/api/books/import',
            'bodyFromResponse': 0,
          },
        },
        {'captureSha256': 'books/{response:1:id}/kg.json'},
        {
          'request': {
            'method': 'POST',
            'path': '/api/books/import',
            'bodyFromResponse': 0,
            'bodyPatch': [
              {
                'op': 'append',
                'path': ['kg', 'log'],
                'value': {'t': 'person', 'p': 2, 'id': 'p2', 'name': 'Bob'},
              },
            ],
          },
        },
        {'captureSha256': 'books/{response:1:id}/kg.json'},
      ]);
      expect(at(run, 2)['status'], 409);
      final captures = array(run['sha256Captures']);
      expect(captures, hasLength(2));
      expect(captures[1], captures[0]);
    },
    skip:
        "Dart owner server.app.Handler#scripted_http and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_negative_length_and_transfer_encoding_rejected",
    () {
      final run = httpRun([
        req(
          'POST',
          '/api/login',
          body: <int>[],
          headers: {'Content-Length': '-1'},
        ),
        req(
          'POST',
          '/api/login',
          body: <int>[],
          headers: {'Transfer-Encoding': 'chunked'},
        ),
      ], books: {});
      expect(responses(run).map((r) => r['status']).toList(), [400, 400]);
    },
    skip:
        "Dart owner server.app.Handler#scripted_http and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_malformed_json_shape_and_expensive_request_admission",
    () {
      final run = httpRun([
        req('POST', '/api/login', body: [1, 2]),
        req(
          'POST',
          '/api/books/fixture/ask',
          body: {'q': <Object?>[], 'pos': 2},
        ),
        {
          'patchedRequest': {
            'patch': {'askGatePermits': 0},
            'request': {
              'method': 'POST',
              'path': '/api/books/fixture/ask',
              'body': {'q': 'Who?', 'pos': 2},
            },
          },
        },
      ]);
      expect(responses(run).map((r) => r['status']).toList(), [400, 400, 429]);
      expect(obj(run['calls'])['model'], 0);
    },
    skip:
        "Dart owner server.app.Handler#scripted_http and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_slow_incomplete_body_has_deadline",
    () {
      final run = httpRun([
        {
          'patchedRequest': {
            'patch': {'readTimeoutSeconds': 0.1},
            'request': {
              'method': 'POST',
              'path': '/api/login',
              'body': utf8.encode('{}'),
              'headers': {'Content-Length': '20'},
            },
          },
        },
      ], books: {});
      expect(at(run, 0)['status'], 408);
    },
    skip:
        "Dart owner server.app.Handler#scripted_http and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_static_sibling_cannot_escape_root",
    () {
      final run = httpRun(
        [
          req('GET', '/../web-private/secret.txt'),
          req('GET', '/%2e%2e/web-private/secret.txt'),
        ],
        books: {},
        options: {
          'siblingWebFiles': {'secret.txt': 'fixture-only'},
        },
      );
      expect(responses(run).map((r) => r['status']).toList(), [404, 404]);
    },
    skip:
        "Dart owner server.app.Handler#scripted_http and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_static_revalidation_and_compression",
    () {
      final source = List.filled(400, 'export const x = 1;\n').join();
      final run = httpRun([
        {
          'writeText': {'path': 'web/a.js', 'value': source},
        },
        req('GET', '/a.js', headers: {'Accept-Encoding': 'gzip'}),
        {
          'request': {
            'method': 'GET',
            'path': '/a.js',
            'headersFromResponse': {
              'If-None-Match': {'response': 0, 'header': 'ETag'},
            },
          },
        },
        req('GET', '/a.js'),
        {
          'writeText': {'path': 'web/a.js', 'value': '$source// changed\n'},
        },
        {
          'request': {
            'method': 'GET',
            'path': '/a.js',
            'headersFromResponse': {
              'If-None-Match': {'response': 0, 'header': 'ETag'},
            },
          },
        },
      ], books: {});
      final first = at(run, 0);
      final etag = obj(first['headers'])['ETag'];
      expect(
        [first['status'], obj(first['headers'])['Content-Encoding']],
        [200, 'gzip'],
      );
      expect(
        utf8.decode(gzip.decode(array(first['bodyBytes']).cast<int>())),
        source,
      );
      expect(
        [
          at(run, 1)['status'],
          array(at(run, 1)['bodyBytes']),
          obj(at(run, 1)['headers'])['ETag'],
        ],
        [304, <int>[], etag],
      );
      expect(at(run, 2)['text'], source);
      expect(at(run, 3)['status'], 200);
      expect(obj(at(run, 3)['headers'])['ETag'], isNot(etag));
      expect(at(run, 3)['text'], endsWith('// changed\n'));
    },
    skip:
        "Dart owner server.app.Handler#scripted_http and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_byline_in_file_name_is_shown_as_title_and_author",
    () {
      for (final row in [
        ['术师手册 作者：听日', '', '术师手册', '听日'],
        ['瑜伽师地论 作者：', '', '瑜伽师地论', ''],
        ['哈佛幸福课 作者：ePUBw.COM', '', '哈佛幸福课', ''],
        ['老千 作者：马小虎', '别人', '老千', '别人'],
        ['红楼梦', '曹雪芹', '红楼梦', '曹雪芹'],
      ]) {
        expect(
          tuple(
            callPorted('server.storage.display_title', {
              'title': row[0],
              'author': row[1],
            }),
          ),
          row.sublist(2),
        );
      }
      final book = bookFixture()..addAll({'title': '术师手册 作者：听日', 'author': ''});
      final run = httpRun(
        [req('GET', '/api/books'), req('GET', '/api/books/fixture')],
        fixture: {...bookDirectory(), 'book.json': book},
      );
      final shelf = obj(array(at(run, 0)['json']).first);
      final detail = body(at(run, 1));
      expect([shelf['title'], shelf['author']], ['术师手册', '听日']);
      expect([detail['title'], detail['author']], ['术师手册', '听日']);
    },
    skip:
        "Dart owner server.app.Handler#scripted_http, server.storage and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_optimistic_progress_does_not_overwrite_other_device",
    () {
      final run = httpRun([
        req(
          'PUT',
          '/api/books/fixture/progress',
          body: {'pos': 3, 'expected_t': null},
        ),
        req(
          'PUT',
          '/api/books/fixture/progress',
          body: {'pos': 6, 'expected_t': null},
        ),
        req('PUT', '/api/books/fixture/progress', body: {'pos': 13}),
      ]);
      expect(responses(run).map((r) => r['status']).toList(), [200, 409, 400]);
      expect(body(at(run, 1))['progress'], body(at(run, 0))['progress']);
    },
    skip:
        "Dart owner server.app.Handler#scripted_http and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_explicit_process_queues_completed_pending_quality",
    () {
      final quality = {
        'state': 'pending',
        'pending': ['quarantined-derived-cache'],
      };
      final run = httpRun(
        [
          req('POST', '/api/books/fixture/process'),
          {'captureJson': 'books/fixture/meta.json'},
          req('DELETE', '/api/books/fixture/process'),
        ],
        fixture: {
          ...bookDirectory(),
          'status.json': {'state': 'done', 'frontier': 12, 'quality': quality},
        },
      );
      expect(at(run, 0)['status'], 200);
      expect(obj(body(at(run, 0))['status'])['state'], 'queued');
      expect(obj(body(at(run, 0))['status'])['quality'], quality);
      expect(obj(array(run['jsonCaptures']).single)['retry_quality'], isTrue);
      expect(at(run, 1)['status'], 200);
      expect(
        obj(
          obj(obj(files(run)['books'])['fixture'])['meta.json'],
        ).containsKey('retry_quality'),
        isFalse,
      );
    },
    skip:
        "Dart owner server.app.Handler#scripted_http, server.jobs.Worker and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_progress_end_cutoff_reaches_100_without_losing_resume_anchor",
    () {
      final run = httpRun([
        req(
          'PUT',
          '/api/books/fixture/progress',
          body: {'pos': 7, 'cutoff': 12},
        ),
        for (final cutoff in <Object?>[6, 13, -1, 9.5, true, '12'])
          req(
            'PUT',
            '/api/books/fixture/progress',
            body: {'pos': 7, 'cutoff': cutoff},
          ),
        req('PUT', '/api/books/fixture/progress', body: {'pos': 6}),
      ]);
      expect(at(run, 0)['status'], 200);
      final progress = obj(body(at(run, 0))['progress']);
      expect(
        [progress['pos'], progress['cutoff'], progress['pct']],
        [7, 12, 100],
      );
      expect(
        responses(run).skip(1).take(6).map((r) => r['status']).toList(),
        List.filled(6, 400),
      );
      final legacy = obj(body(at(run, 7))['progress']);
      expect([legacy['pos'], legacy['cutoff'], legacy['pct']], [6, 6, 50]);
    },
    skip:
        "Dart owner server.app.Handler#scripted_http and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_cookie_is_secure_expiring_and_authentication_required",
    () {
      final run = httpRun(
        [
          req('GET', '/api/books'),
          req('POST', '/api/login', body: {'code': 'fixture-pass'}),
          {
            'request': {
              'method': 'GET',
              'path': '/api/books',
              'headersFromResponse': {
                'Cookie': {
                  'response': 1,
                  'header': 'Set-Cookie',
                  'before': ';',
                },
              },
            },
          },
          {
            'set': {'advanceClockSeconds': 8 * 86400},
          },
          {
            'request': {
              'method': 'GET',
              'path': '/api/books',
              'headersFromResponse': {
                'Cookie': {
                  'response': 1,
                  'header': 'Set-Cookie',
                  'before': ';',
                },
              },
            },
          },
        ],
        books: {},
        options: {
          'passcode': 'fixture-pass',
          'cookieSecure': true,
          'nowEpoch': 1000,
        },
      );
      expect(at(run, 0)['status'], 401);
      expect(at(run, 1)['status'], 200);
      final cookie = obj(at(run, 1)['headers'])['Set-Cookie']! as String;
      expect(cookie, contains('Secure'));
      expect(cookie, contains('HttpOnly'));
      expect([at(run, 2)['status'], at(run, 3)['status']], [200, 401]);
    },
    skip:
        "Dart owner server.app.Handler#scripted_http and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_health_disabled_worker_and_manifest_revision",
    () {
      final run = httpRun([
        req('GET', '/healthz'),
        req('GET', '/api/books/fixture/offline-manifest'),
        req('GET', '/api/books/fixture'),
        {
          'writeJson': {
            'path': 'books/fixture/status.json',
            'value': {'state': 'done', 'frontier': 11},
          },
        },
        req('GET', '/api/books/fixture/offline-manifest'),
        {
          'set': {'workerEnabled': true},
        },
        req('GET', '/healthz'),
      ], fixture: bookDirectory(image: true));
      expect(at(run, 0)['status'], 200);
      expect(body(at(run, 0))['ok'], isTrue);
      expect(obj(at(run, 0)['headers']).containsKey('X-Yedu-Release'), isTrue);
      final manifest = body(at(run, 1));
      expect(obj(manifest['book'])['id'], 'fixture');
      expect(obj(manifest['book'])['version'], body(at(run, 2))['version']);
      expect(obj(manifest['graph'])['to'], 12);
      expect(
        array(manifest['assets']),
        contains('/api/books/fixture/img/cover.png'),
      );
      expect(body(at(run, 3))['version'], isNot(manifest['version']));
      expect(at(run, 4)['status'], 503);
    },
    skip:
        "Dart owner server.app.Handler#scripted_http and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_delete_busy_external_book_refuses_and_keeps_content",
    () {
      final run = httpRun([
        {
          'lease': {
            'book': 'fixture',
            'request': {'method': 'DELETE', 'path': '/api/books/fixture'},
          },
        },
      ], fixture: bookDirectory(state: 'running'));
      expect(at(run, 0)['status'], 409);
      expect(
        obj(obj(files(run)['books'])['fixture']).containsKey('book.json'),
        isTrue,
      );
    },
    skip:
        "Dart owner server.app.Handler#scripted_http, server.jobs.Worker and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_delete_archives_data_and_clears_progress",
    () {
      final run = httpRun(
        [req('DELETE', '/api/books/fixture')],
        dataFiles: {
          'progress.json': {
            'fixture': {'pos': 2},
          },
        },
      );
      expect(at(run, 0)['status'], 200);
      expect(obj(files(run)['books']).containsKey('fixture'), isFalse);
      final trash = obj(files(run)['trash']);
      final archived = trash.entries.singleWhere(
        (entry) => entry.key.startsWith('fixture-'),
      );
      expect(obj(archived.value).containsKey('book.json'), isTrue);
      expect(run['progressAll'], <String, Object?>{});
    },
    skip:
        "Dart owner server.app.Handler#scripted_http and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.HTTPRepair.test_shelf_uses_small_metadata_and_reflects_book_updates",
    () {
      final updated = bookFixture()..['title'] = 'Updated';
      final run = httpRun([
        req('GET', '/api/books'),
        {
          'patchedRequest': {
            'patch': {
              'denyReadText': ['books/fixture/book.json'],
            },
            'request': {'method': 'GET', 'path': '/api/books'},
          },
        },
        {
          'writeJson': {'path': 'books/fixture/book.json', 'value': updated},
        },
        req('GET', '/api/books'),
      ]);
      expect(
        obj(obj(files(run)['books'])['fixture']).containsKey('shelf.json'),
        isTrue,
      );
      expect(at(run, 1)['status'], 200);
      expect(obj(array(at(run, 2)['json']).first)['title'], 'Updated');
    },
    skip:
        "Dart owner server.app.Handler#scripted_http, server.storage and isolated synthetic HTTP/filesystem harness with deterministic request and state capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_shared_temporal_contract",
    () {
      final fixture =
          jsonDecode(File('../tests/temporal-fixtures.json').readAsStringSync())
              as Map<String, Object?>;
      for (final rawCase in fixture['cases']! as List<Object?>) {
        final caseData = rawCase! as Map<String, Object?>;
        final result =
            callPorted('server.temporal.fold', {
                  'log': caseData['records'],
                  'pos': caseData['cutoff'],
                })
                as Map<String, Object?>;
        final rels =
            (result['rels']! as Map<String, Object?>).values
                .cast<Map<String, Object?>>()
                .toList();
        final expected =
            (caseData['expected_rels']! as List<Object?>)
                .cast<Map<String, Object?>>();
        expect(
          rels.length,
          expected.length,
          reason: caseData['name'] as String,
        );
        for (var i = 0; i < expected.length; i++) {
          expect(
            {for (final key in expected[i].keys) key: rels[i][key]},
            expected[i],
            reason: caseData['name'] as String,
          );
        }
      }
    },
    skip:
        "Dart implementation of server.temporal.fold is pending (A1/A6, A5, A6); required to check 'shared temporal contract'.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_early_and_merged_latest_attributes_preserved",
    () {
      final log = [
        {'t': 'attr', 'p': 1, 'id': 'a', 'key': 'job', 'value': 'teacher'},
        {'t': 'person', 'p': 2, 'id': 'a', 'name': 'Alice'},
        {'t': 'person', 'p': 3, 'id': 'b', 'name': 'Alias'},
        {'t': 'attr', 'p': 4, 'id': 'b', 'key': 'job', 'value': 'writer'},
        {'t': 'merge', 'p': 5, 'from': 'b', 'into': 'a'},
      ];
      Object? jobAt(int pos) {
        final result =
            callPorted('server.temporal.fold', {'log': log, 'pos': pos})
                as Map<String, Object?>;
        final people = result['people']! as Map<String, Object?>;
        final alice = people['a']! as Map<String, Object?>;
        final attrs = alice['attrs']! as Map<String, Object?>;
        return attrs['job'];
      }

      expect(jobAt(2), 'teacher');
      expect(jobAt(5), 'writer');
    },
    skip:
        "Dart implementation of server.temporal.fold is pending (A1/A6, A5, A6); required to check 'early and merged latest attributes preserved'.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_failed_guard_never_publishes_rejected_prose",
    () {
      final book = bookFixture()..['lang'] = 'zh';
      final input = <String, Object?>{
        'book': book,
        'kg': {'log': <Object?>[]},
        'status': <String, Object?>{},
        'question': '发生了什么？',
        'pos': 12,
      };
      for (final guard in <Object?>[
        [
          {
            'a': {'verdict': 'flag', 'p': 0.01},
          },
          {
            'a': {'verdict': 'flag', 'p': 0.01},
          },
        ],
        {
          'error': {'type': 'RuntimeError', 'message': 'fixture outage'},
        },
      ]) {
        final run = answerRun(input, {
          'route': ['other', <String, Object?>{}],
          'retrieve': <Object?>[],
          'chat': [
            ['REJECTED FIRST', <String, Object?>{}],
            ['REJECTED SECOND', <String, Object?>{}],
          ],
          'guard': guard,
        });
        final event = array(
          run['events'],
        ).map(obj).firstWhere((e) => e['kind'] == 'answer');
        final answer = obj(event['value']);
        expect(jsonEncode(answer), isNot(contains('REJECTED')));
        expect(obj(answer['guard'])['verdict'], 'withheld');
        expect(answer['cites'], <Object?>[]);
      }
    },
    skip:
        "Dart owner server.ask.answer#scripted and scripted route/retrieve/chat/guard callbacks and emitted-event capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_ended_relationship_is_explicitly_historical_in_answer_evidence",
    () {
      final log = [
        {'t': 'person', 'p': 0, 'id': 'a', 'name': 'Alice'},
        {'t': 'person', 'p': 0, 'id': 'b', 'name': 'Bob'},
        {
          't': 'rel',
          'p': 3,
          'a': 'a',
          'b': 'b',
          'a_is': 'wife',
          'b_is': 'husband',
          'status': 'ended',
        },
      ];
      final run = answerRun(
        {
          'book': bookFixture(),
          'kg': {'log': log},
          'status': <String, Object?>{},
          'question': 'How are Alice and Bob related?',
          'pos': 12,
        },
        {
          'route': ['relation', <String, Object?>{}],
          'retrieve': <Object?>[],
          'chat': ['They were married.', <String, Object?>{}],
          'guard': {
            'a': {'verdict': 'ok', 'p': 0.95},
          },
        },
      );
      final messages = array(
        obj(array(obj(run['calls'])['chat']).single)['messages'],
      );
      expect(obj(messages[1])['content'], contains('过去的关系，已结束'));
    },
    skip:
        "Dart owner server.ask.answer#scripted and scripted route/retrieve/chat/guard callbacks and emitted-event capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_multilingual_fallback_and_query_translation",
    () {
      final book = bookFixture();
      final broad = stateRun('server.ask.retrieve#scripted', {
        'book': book,
        'query': '她为什么来了？',
        'previous': <Object?>[],
        'pos': 12,
        'files': {'book.json': book},
      });
      expect(array(broad['result']), isNotEmpty);
      final translated = stateRun('server.ask.retrieval_query#scripted', {
        'question': '她为什么来了？',
        'book': book,
        'chatReply': ['Why did she come?', <String, Object?>{}],
      });
      expect(translated['result'], contains('Why did she come?'));
      expect(array(translated['chatCalls']), hasLength(1));
      final narrow = stateRun('server.ask.retrieve#scripted', {
        'book': book,
        'query': 'Alice',
        'previous': <Object?>[],
        'pos': 5,
        'files': {'book.json': book},
      });
      expect(
        array(narrow['result']).every((raw) {
          final passage = obj(raw);
          return (passage['o']! as int) + (passage['t']! as String).length <= 5;
        }),
        isTrue,
      );
    },
    skip:
        "Dart owner server.ask.retrieve#scripted, server.ask.retrieval_query#scripted and synthetic book and chat-reply capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_pronoun_exact_span_and_local_candidate",
    () {
      final log = <Json>[
        for (var i = 0; i < 20; i++)
          {'t': 'person', 'p': 0, 'id': 'p$i', 'name': 'Person$i'},
        {
          't': 'cnt',
          'p': 0,
          'c': {for (var i = 0; i < 20; i++) 'p$i': i < 19 ? 100 : 1},
        },
      ];
      final run = stateRun('server.ask.who_is#scripted', {
        'book': {
          'blocks': [
            {'o': 0, 't': 'Person19 arrived. He sat down.'},
          ],
        },
        'log': log,
        'pos': 29,
        'start': 18,
        'end': 20,
        'jevAnswer': {
          'w': {
            'choice': 'p19',
            'probabilities': {'p19': 0.9},
          },
        },
      });
      expect(obj(run['result'])['ok'], isTrue);
      final call = obj(array(run['jevCalls']).single);
      expect(
        obj(obj(obj(call['questions'])['w'])['criteria']).containsKey('p19'),
        isTrue,
      );
      expect(
        obj(call['state'])['this_passage'],
        contains('<selected>He</selected>'),
      );
    },
    skip:
        "Dart owner server.ask.who_is#scripted and synthetic graph, exact-span and judge-call capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_cache_budget_and_corruption_visibility",
    () {
      final run = stateRun('server.storage.JsonCache#scripted', {
        'count': 2,
        'budget': 1000,
        'itemLimit': 1000,
        'steps': [
          for (var i = 0; i < 3; i++) ...[
            {
              'writeJson': {
                'path': '$i.json',
                'value': {'n': i},
              },
            },
            {'get': '$i.json'},
          ],
          {'capture': 'entries'},
          {
            'writeText': {'path': '2.json', 'value': 'not json'},
          },
          {'get': '2.json'},
        ],
      });
      expect(obj(array(run['captures']).single)['entryCount'], 2);
      expect(obj(run['error'])['type'], 'FormatException');
    },
    skip:
        "Dart owner server.storage.JsonCache#scripted and isolated cache/filesystem and read-count capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_concurrent_cache_read_parses_one_body",
    () {
      final run = stateRun('server.storage.JsonCache#scripted', {
        'files': {'book.json': bookFixture()},
        'steps': [
          {
            'concurrentGet': {
              'path': 'book.json',
              'workers': 2,
              'readDelayMillis': 50,
            },
          },
        ],
      });
      expect(run['identicalResults'], isTrue);
      expect(run['readTextCalls'], 1);
    },
    skip:
        "Dart owner server.storage.JsonCache#scripted and isolated cache/filesystem and read-count capture are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_worker_cancel_owned_process_and_spawn_error_cleanup",
    () {
      final run = stateRun('server.jobs.Worker#scripted', {
        'book': bookDirectory(state: 'queued')..['meta.json'] = {'auto': true},
        'steps': [
          {
            'one': {
              'spawn': {'error': 'fixture spawn failure'},
            },
          },
          {
            'oneAndCancel': {
              'spawn': {'kind': 'sleeping'},
              'timeoutSeconds': 2,
            },
          },
          {'setAuto': true},
          {
            'oneAndCancel': {
              'spawn': {'kind': 'sleeping'},
              'stopFirst': true,
              'timeoutSeconds': 2,
              'preserveAuto': true,
            },
          },
        ],
      });
      final snapshots = array(run['snapshots']).map(obj).toList();
      expect(obj(snapshots[0]['error'])['type'], 'OSError');
      expect([snapshots[0]['current'], snapshots[0]['process']], [null, null]);
      expect(snapshots[1]['threadAlive'], isFalse);
      expect(snapshots[1]['processExited'], isTrue);
      expect(obj(snapshots[1]['status'])['state'], 'paused');
      expect(obj(snapshots[1]['files']).containsKey('book.json'), isTrue);
      expect(snapshots[3]['threadAlive'], isFalse);
      expect(obj(snapshots[3]['meta'])['auto'], isTrue);
      expect(obj(snapshots[3]['status'])['state'], 'queued');
    },
    skip:
        "Dart owner server.jobs.Worker#scripted and isolated worker/process fault injection and state snapshots are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_worker_loop_survives_spawn_failure",
    () {
      final run = stateRun('server.jobs.Worker#scripted', {
        'book': bookDirectory()..['meta.json'] = {'auto': true},
        'steps': [
          {
            'startWithSpawnError': {
              'message': 'fixture spawn failure',
              'wake': true,
            },
          },
        ],
      });
      expect(run['lastError'], isNotNull);
      expect(run['workerAlive'], isTrue);
      expect(run['current'], isNull);
    },
    skip:
        "Dart owner server.jobs.Worker#scripted and isolated worker/process fault injection and state snapshots are pending (A5/A6); translated assertions remain skipped.",
  );
  test(
    "tests.test_server_repair.QualityRepair.test_quality_retry_requires_explicit_request_and_survives_launch_failure",
    () {
      final run = stateRun('server.jobs.Worker#scripted', {
        'book':
            bookDirectory()..addAll({
              'meta.json': {'auto': true},
              'status.json': {
                'state': 'done',
                'quality': {
                  'state': 'pending',
                  'pending': ['unsafe-summary'],
                },
              },
            }),
        'steps': [
          {
            'one': {
              'spawn': {'kind': 'capture'},
            },
          },
          {'setAuto': true},
          {
            'one': {
              'spawn': {'error': 'fixture spawn failure'},
            },
          },
          {
            'one': {
              'spawn': {'exitCode': 75},
            },
          },
          {
            'one': {
              'spawn': {'exitCode': 1},
            },
          },
          {'setAuto': true},
          {
            'one': {
              'spawn': {
                'exitCode': 0,
                'beforeExitFiles': {
                  'work/quality-retry.json': {
                    'state': 'complete',
                    'archive': 'work/retry-archive/fixture',
                  },
                  'status.json': {
                    'state': 'done',
                    'quality': {'state': 'verified', 'pending': <Object?>[]},
                  },
                },
              },
            },
          },
        ],
      });
      final snapshots = array(run['snapshots']).map(obj).toList();
      expect(obj(run['calls'])['spawnBeforeExplicitRetry'], 0);
      expect(obj(snapshots[2]['error'])['type'], 'OSError');
      for (final index in [2, 3, 4]) {
        expect(obj(snapshots[index]['meta'])['retry_quality'], isTrue);
      }
      expect(
        array(obj(snapshots[6]['launch'])['args']),
        contains('--retry-quality'),
      );
      expect(obj(snapshots[6]['meta']).containsKey('retry_quality'), isFalse);
      expect(obj(obj(snapshots[6]['status'])['quality'])['state'], 'verified');
    },
    skip:
        "Dart owner server.jobs.Worker#scripted and isolated worker/process fault injection and state snapshots are pending (A5/A6); translated assertions remain skipped.",
  );
}
