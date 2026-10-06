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

  test('bounded completion has its own pause explanation', () {
    expect(
      ProcessingDiagnostics.pauseReasonLabel(book, <String, Object?>{
        'pause_reason': 'scope_complete',
      }),
      '本次范围已完成',
    );
  });

  test('native runtime export is bounded and rejects private fields', () {
    const String secret = 'PRIVATE-BOOK-API-URL';
    final String encoded = utf8.decode(
      ProcessingDiagnostics.bytes(
        bookDirectory: book,
        workerHealth: const <String, Object?>{},
        backgroundRuntime: <String, Object?>{
          'sdk': 35,
          'pid': 123,
          'device_idle': true,
          'private': secret,
          'service': <String, Object?>{
            'running': true,
            'wake_lock_held': true,
            'title': secret,
          },
          'events': <Object?>[
            for (int i = 0; i < 80; i++)
              <String, Object?>{
                'event': i == 79 ? secret : 'foreground_started',
                'error_type': secret,
                'message': secret,
                'at_ms': i,
                'elapsed_ms': i,
                'uptime_ms': i,
              },
          ],
        },
      ),
    );
    expect(encoded, isNot(contains(secret)));
    final Map<String, Object?> decoded =
        jsonDecode(encoded) as Map<String, Object?>;
    final Map<String, Object?> native =
        decoded['android_runtime']! as Map<String, Object?>;
    expect(native['device_idle'], isTrue);
    expect(
      (native['service']! as Map<String, Object?>)['wake_lock_held'],
      isTrue,
    );
    expect(native['events'], hasLength(64));
  });

  test('judge failure export keeps structural codes and counts only', () {
    const String secret = 'PRIVATE-QUESTION-RESPONSE-URL-KEY';
    final File failure = File(
      '${book.path}/work/judge/model-answer-failure.json',
    );
    failure.parent.createSync(recursive: true);
    failure.writeAsStringSync(
      jsonEncode(<String, Object?>{
        'at': 1234,
        'attempts': 2,
        'question_count': 3,
        'unresolved_count': 1,
        'raw': secret,
        'question_id': secret,
        'reasons': <String, Object?>{
          'inconsistent_sum': 1,
          'invalid_choice': secret,
          secret: 1,
        },
      }),
    );
    File('${book.path}/status.json').writeAsStringSync(
      jsonEncode(<String, Object?>{
        'state': 'paused',
        'pause_reason': 'request_outcome_unknown',
        'error': '已配置模型的判断回答不完整或概率无效：$secret',
      }),
    );
    final String encoded = utf8.decode(
      ProcessingDiagnostics.bytes(
        bookDirectory: book,
        workerHealth: const <String, Object?>{},
      ),
    );
    expect(encoded, isNot(contains(secret)));
    final Map<String, Object?> output =
        jsonDecode(encoded) as Map<String, Object?>;
    expect(output['last_model_judge_failure'], <String, Object?>{
      'at': 1234,
      'attempts': 2,
      'question_count': 3,
      'unresolved_count': 1,
      'reasons': <String, int>{'inconsistent_sum': 1},
    });
    expect(
      (output['status'] as Map<String, Object?>)['error_code'],
      'model_judge_invalid_answer',
    );
  });

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
        'judge_fallback_route': 'jev-direct',
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
    Directory('${book.path}/work/judge').createSync(recursive: true);
    File('${book.path}/work/judge/paid-budget.json').writeAsStringSync(
      jsonEncode(<String, Object?>{
        'calls': 2,
        'max_calls': 1000,
        'api_key': apiKey,
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
    Directory('${book.path}/work/jobs').createSync();
    File('${book.path}/work/jobs/bio-1.json').writeAsStringSync(
      jsonEncode(<String, Object?>{
        'kind': 'bio',
        'state': 'deferred',
        'generation_attempt': 2,
        'args': <String>[privateText, apiKey],
        'error': endpoint,
        'bio_review': <String, Object?>{
          'candidates': 2,
          'passed': 0,
          'blocked': 2,
          'missing': 0,
          'rejection_reasons': <String, Object?>{
            'beyond_text': 1,
            'contradicted': 1,
            privateText: 999,
          },
        },
      }),
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
    expect(
      (result['meta'] as Map<String, Object?>)['judge_route'],
      'jev-direct',
    );
    expect((result['judge_usage'] as Map<String, Object?>)['jev_calls'], 2);
    final List<Object?> activity = result['activity']! as List<Object?>;
    expect((activity.first! as Map<String, Object?>)['stage'], 'relation');
    expect((activity.first! as Map<String, Object?>)['segment'], 11);
    expect((activity.last! as Map<String, Object?>)['phase'], isNull);
    final List<Object?> biographyJobs =
        result['biography_jobs']! as List<Object?>;
    expect(biographyJobs, hasLength(1));
    final Map<String, Object?> biographyJob =
        biographyJobs.first! as Map<String, Object?>;
    expect(biographyJob['chapter'], 2);
    expect(biographyJob['state'], 'deferred');
    expect(biographyJob['blocked'], 2);
    expect(biographyJob['rejection_reasons'], <String, Object?>{
      'beyond_text': 1,
      'contradicted': 1,
    });
    expect(
      ProcessingDiagnostics.pauseReasonLabel(book, <String, Object?>{
        'pause_reason': 'manual',
      }),
      '由你暂停',
    );
  });

  test('diagnostic identifies an unverified judge-format biography', () {
    const String privateText = 'PRIVATE-BOOK-TEXT';
    Directory('${book.path}/work/jobs').createSync();
    File('${book.path}/work/jobs/bio-1.json').writeAsStringSync(
      jsonEncode(<String, Object?>{
        'state': 'deferred',
        'failure_kind': 'bio_judge_format',
        'error': privateText,
        'bio_review': <String, Object?>{
          'candidates': 2,
          'passed': 0,
          'verification_pending': true,
          'draft': privateText,
        },
      }),
    );
    final String content = utf8.decode(
      ProcessingDiagnostics.bytes(
        bookDirectory: book,
        workerHealth: <String, Object?>{},
      ),
    );
    expect(content, isNot(contains(privateText)));
    final Map<String, Object?> result =
        jsonDecode(content) as Map<String, Object?>;
    final List<Object?> jobs = result['biography_jobs']! as List<Object?>;
    expect(jobs.single, containsPair('failure_kind', 'bio_judge_format'));
    expect(jobs.single, containsPair('verification_pending', true));
  });
}
