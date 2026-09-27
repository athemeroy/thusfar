/// Test-only wire replay. This transport has no socket or live fallback.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:thusfar_core/llm.dart';
import 'package:thusfar_core/src/pipeline/provenance.dart';
import 'package:thusfar_core/src/py/py_hash.dart';
import 'package:thusfar_core/src/py/py_json.dart';

typedef Json = Map<String, Object?>;

class MissingCassette extends Error {
  MissingCassette(this.key);
  final String key;
  @override
  String toString() => 'No offline cassette for request $key';
}

/// Normalize JSON serialization only: every URL, safe header, payload value and
/// message byte remains significant. Python and Dart HTTP clients serialize
/// object separators differently, which does not alter the upstream request.
String _key(
  String method,
  String url,
  Map<String, String> headers,
  String body,
) {
  final Json safe = <String, Object?>{
    for (final MapEntry<String, String> e in headers.entries)
      if (<String>['accept', 'content-type'].contains(e.key.toLowerCase()))
        e.key.toLowerCase(): e.value,
  };
  return digest(<String, Object?>{
    'method': method,
    'url': url,
    'headers': safe,
    'body': jsonDecode(body),
  });
}

Json _read(File file) => jsonDecode(file.readAsStringSync()) as Json;
String _canonical(Object? value) =>
    PyJson.encode(value, sortKeys: true, ensureAscii: false, compact: true);

class CassetteTransport implements ChatTransport {
  CassetteTransport(Directory directory, {this.diagnostics}) {
    for (final File file in directory.listSync().whereType<File>()) {
      if (!file.path.endsWith('.json')) continue;
      final Json tape = _read(file);
      if (tape['request'] is! Json) continue;
      final Json envelope = tape['request']! as Json;
      final String stored = sha256Hex(
        utf8.encode(
          PyJson.encode(
                envelope,
                ensureAscii: false,
                compact: true,
                allowNan: false,
              )
              .replaceAll('\u0085', r'\u0085')
              .replaceAll('\u2028', r'\u2028')
              .replaceAll('\u2029', r'\u2029'),
        ),
      );
      if (tape['request_sha256'] != stored ||
          !file.path.endsWith('/$stored.json')) {
        throw StateError(
          'Cassette integrity failed: ${file.uri.pathSegments.last}',
        );
      }
      final String key = _key(
        envelope['method']! as String,
        envelope['url']! as String,
        (envelope['headers']! as Json).cast<String, String>(),
        envelope['body_utf8']! as String,
      );
      final File? existing = _files[key];
      if (existing != null &&
          _canonical(_read(existing)['attempts']) !=
              _canonical(tape['attempts'])) {
        throw StateError('Ambiguous normalized cassette key $key');
      }
      _files[key] = file;
    }
  }

  final Directory? diagnostics;
  final Map<String, File> _files = <String, File>{};
  final Map<String, int> offsets = <String, int>{};
  final List<String> requests = <String>[];
  final List<String> misses = <String>[];
  int get calls => requests.length;
  int get available => _files.length;

  @override
  Future<ChatResponse> post(ChatRequest request, Duration timeout) async {
    final String key = _key(
      'POST',
      request.url.toString(),
      request.headers,
      request.body,
    );
    final File? file = _files[key];
    if (file == null) {
      misses.add(key);
      if (diagnostics != null) {
        diagnostics!.createSync(recursive: true);
        File('${diagnostics!.path}/missing-$key.json').writeAsStringSync(
          jsonEncode(<String, Object?>{
            'url': request.url.toString(),
            'body': jsonDecode(request.body),
          }),
        );
      }
      throw MissingCassette(key);
    }
    final Json tape = _read(file);
    final List<Json> attempts =
        (tape['attempts']! as List<Object?>).cast<Json>();
    if (attempts.any((Json a) => a['kind'] == 'pending'))
      throw StateError('Unsettled cassette $key');
    final List<Object?>? groups =
        (tape['overlap_groups'] ??
                (tape['overlap_slots'] == null
                    ? null
                    : <Object?>[tape['overlap_slots']]))
            as List<Object?>?;
    if (groups == null &&
        attempts.length > 1 &&
        attempts
            .skip(1)
            .any((Json a) => _canonical(a) != _canonical(attempts.first))) {
      throw StateError('Unknown duplicate overlap $key');
    }
    for (final Object? value in groups ?? <Object?>[]) {
      final List<int> group = (value! as List<Object?>).cast<int>();
      if (group.isEmpty || group.any((int n) => n < 0 || n >= attempts.length))
        throw StateError('Invalid overlap $key');
      if (group
          .skip(1)
          .any(
            (int n) =>
                _canonical(attempts[n]) != _canonical(attempts[group.first]),
          )) {
        throw StateError('Ambiguous concurrent replay $key');
      }
    }
    final int index = offsets[key] ?? 0;
    if (index >= attempts.length)
      throw StateError('Cassette exhausted: $key, attempts=$index');
    offsets[key] = index + 1;
    requests.add(key);
    final Json attempt = attempts[index];
    if (attempt['kind'] == 'error') _throwError(attempt['error']! as Json);
    final Map<String, String> headers = <String, String>{
      for (final MapEntry<String, Object?> h
          in (attempt['headers']! as Json).entries)
        h.key.toLowerCase(): h.value! as String,
    };
    if (attempt['kind'] == 'http_error') {
      return ChatResponse(
        attempt['status']! as int,
        headers['content-type'] ?? '',
        Stream<List<int>>.value(
          base64.decode(attempt['body_base64']! as String),
        ),
        headers: headers,
      );
    }
    if (attempt['kind'] != 'response')
      throw StateError('Unsupported attempt in $key');
    return ChatResponse(
      attempt['status']! as int,
      headers['content-type'] ?? '',
      _body(attempt),
      headers: headers,
    );
  }
}

Stream<List<int>> _body(Json attempt) async* {
  for (final Object? encoded in attempt['chunks_base64']! as List<Object?>) {
    yield base64.decode(encoded! as String);
  }
  if (attempt['read_error'] is Json)
    _throwError(attempt['read_error']! as Json);
}

Never _throwError(Json error) {
  final String text = error['message']! as String;
  switch (error['type']) {
    case 'TimeoutError':
    case 'socket.timeout':
      throw TimeoutException(text);
    case 'URLError':
    case 'ConnectionError':
    case 'ConnectionResetError':
    case 'BrokenPipeError':
      throw SocketException(text);
    case 'OSError':
      throw HttpException(text);
    default:
      throw StateError('Unsupported recorded error ${error['type']}');
  }
}
