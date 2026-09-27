import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/webdav.dart';

void main() {
  test('WebDAV writes immutable snapshot and reads it back', () async {
    final Map<String, Uint8List> files = <String, Uint8List>{};
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => server.close(force: true));
    server.listen((HttpRequest request) async {
      final HttpResponse response = request.response;
      try {
        expect(
          request.headers.value(HttpHeaders.authorizationHeader),
          'Basic ${base64Encode(utf8.encode('reader:secret'))}',
        );
        if (request.method == 'PUT') {
          expect(request.headers.value('If-None-Match'), '*');
          expect(request.uri.path.startsWith('/books/'), isTrue);
          final String name = request.uri.pathSegments.last;
          if (files.containsKey(name)) {
            response.statusCode = HttpStatus.preconditionFailed;
          } else {
            files[name] = Uint8List.fromList(
              await request.fold<List<int>>(
                <int>[],
                (List<int> all, List<int> chunk) => all..addAll(chunk),
              ),
            );
            response.statusCode = HttpStatus.created;
          }
        } else if (request.method == 'PROPFIND') {
          expect(request.headers.value('Depth'), '1');
          response.statusCode = 207;
          response.headers.contentType = ContentType(
            'application',
            'xml',
            charset: 'utf-8',
          );
          response.write('<D:multistatus xmlns:D="DAV:">');
          response.write('<D:response><D:href>/books/</D:href></D:response>');
          for (final String name in files.keys) {
            response.write(
              '<D:response><D:href>/books/$name</D:href></D:response>',
            );
          }
          response.write('</D:multistatus>');
        } else if (request.method == 'GET') {
          final Uint8List? bytes = files[request.uri.pathSegments.last];
          if (bytes == null) {
            response.statusCode = HttpStatus.notFound;
          } else {
            response.add(bytes);
          }
        } else {
          response.statusCode = HttpStatus.methodNotAllowed;
        }
      } finally {
        await response.close();
      }
    });

    final WebDavClient client = WebDavClient(
      collectionUrl: 'http://127.0.0.1:${server.port}/books/',
      username: 'reader',
      password: 'secret',
    );
    final Uint8List backup = Uint8List.fromList(
      utf8.encode('{"format":"yedu-book/2"}'),
    );
    final String name = await client.upload(backup);
    expect(
      name,
      matches(RegExp(r'^\d{8}T\d{9}Z-[0-9a-f]{12}\.thusfar\.json$')),
    );
    expect(files.keys, contains(name));
    final List<WebDavSnapshot> found = await client.list();
    expect(found.length, 1);
    expect(found.single.name, name);
    expect(await client.download(found.single), backup);
  });

  test('WebDAV refuses plain HTTP outside loopback', () {
    expect(
      () => WebDavClient(
        collectionUrl: 'http://example.com/books/',
        username: 'reader',
        password: 'secret',
      ),
      throwsA(isA<WebDavException>()),
    );
  });

  test('WebDAV rejects a snapshot outside the exact collection path', () async {
    final WebDavClient client = WebDavClient(
      collectionUrl: 'http://127.0.0.1:1/books/',
      username: 'reader',
      password: 'secret',
    );
    const String name = '20260928T010203004Z-abcdef123456.thusfar.json';
    await expectLater(
      client.download(
        WebDavSnapshot(
          Uri.parse('http://127.0.0.1:1/books/nested/$name'),
          name,
        ),
      ),
      throwsA(isA<WebDavException>()),
    );
  });
}
