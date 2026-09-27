import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/processing_diagnostics.dart';

void main() {
  late Directory root;
  late Directory book;

  setUp(() {
    root = Directory.systemTemp.createTempSync('yedu-diagnostics-test-');
    book = Directory('${root.path}/books/book-1')..createSync(recursive: true);
    Directory('${book.path}/work').createSync();
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('file name is stable and does not include a book title', () {
    expect(
      ProcessingDiagnostics.fileName(DateTime(2026, 9, 27, 16, 8, 9)),
      'yedu-processing-20260927-160809.json',
    );
  });

  test('diagnostic exports only allowlisted processing fields', () {
    const String privateText = 'PRIVATE-BOOK-TEXT';
    const String apiKey = 'PRIVATE-API-KEY';
    const String endpoint = 'https://private.example.invalid/v1';
    File('${book.path}/book.json').writeAsStringSync(privateText);
    File('${book.path}/notebook.json').writeAsStringSync(privateText);
    File('${book.path}/status.json').writeAsStringSync(
      jsonEncode(<String, Object?>{
        'state': 'paused',
        'done': 10,
        'total': 603,
        'updated': 1780000000,
        'pause_reason': 'manual',
        'error': '$privateText $endpoint',
        'notice': apiKey,
        'quality': <String, Object?>{
          'state': 'pending',
          'pending': <String>['chapter-titles', 'bio-$privateText'],
        },
      }),
    );
    File('${book.path}/meta.json').writeAsStringSync(
      jsonEncode(<String, Object?>{
        'auto': false,
        'title': privateText,
        'url': endpoint,
        'api_key': apiKey,
      }),
    );
    File('${book.path}/work/worker-receipt.json').writeAsStringSync(
      jsonEncode(<String, Object?>{
        'phase': 'paused',
        'attempt': 3,
        'reason': 'manual',
        'model': privateText,
        'error': endpoint,
        'request_id': apiKey,
      }),
    );
    File('${book.path}/work/activity.json').writeAsStringSync(
      jsonEncode(<Object?>[
        <String, Object?>{
          'at': 1780000000,
          'phase': 'stage_heartbeat',
          'stage': 'relation',
          'segment': 11,
          'started_at': 1779999900,
          'done': 10,
          'total': 603,
          'message': '$privateText $apiKey $endpoint',
        },
        <String, Object?>{
          'at': 1780000001,
          'phase': '$privateText unknown',
          'stage': '$apiKey unknown',
          'message': privateText,
        },
      ]),
    );

    final String content = utf8.decode(
      ProcessingDiagnostics.bytes(
        bookDirectory: book,
        workerHealth: <String, Object?>{
          'alive': true,
          'current': 'book-1',
          'queued': <String>['book-2'],
          'last_error': <String, Object?>{'message': privateText},
        },
        now: DateTime(2026, 9, 27, 16, 8, 9),
      ),
    );
    expect(content, isNot(contains(privateText)));
    expect(content, isNot(contains(apiKey)));
    expect(content, isNot(contains(endpoint)));
    expect(content, isNot(contains(book.path)));
    final Map<String, Object?> result =
        jsonDecode(content) as Map<String, Object?>;
    final Map<String, Object?> status =
        result['status']! as Map<String, Object?>;
    expect(status['done'], 10);
    expect(status['pending_titles'], 1);
    expect(status['pending_biographies'], 1);
    final List<Object?> activity = result['activity']! as List<Object?>;
    expect((activity.first! as Map<String, Object?>)['stage'], 'relation');
    expect((activity.first! as Map<String, Object?>)['segment'], 11);
    expect((activity.last! as Map<String, Object?>)['phase'], isNull);
    expect(
      ProcessingDiagnostics.pauseReasonLabel(book, <String, Object?>{
        'pause_reason': 'manual',
      }),
      '由你暂停',
    );
  });
}
