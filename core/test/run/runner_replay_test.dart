import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:thusfar_core/run.dart';
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/pipeline/jev.dart' as jev;
import 'package:thusfar_core/src/pipeline/llm.dart' as llm;
import 'package:thusfar_core/src/py/py_hash.dart';
import 'package:thusfar_core/src/py/py_json.dart';

import '../support/cassette_transport.dart';

const Set<String> timeKeys = {
  'updated',
  'started',
  'finished',
  'created',
  'exported',
  '_secs',
  '_ttft',
  'seconds',
  'timing',
};
Object? withoutTimes(
  Object? value,
  String artifact, [
  List<String> path = const [],
]) {
  bool omit(String key) =>
      timeKeys.contains(key) ||
      key == 'retry_wait_seconds' &&
          (artifact == 'status.json' && path.join('/') == 'usage/jev' ||
              artifact == 'work/usage.json' && path.join('/') == 'jev');
  if (value is Json)
    return {
      for (final e in value.entries)
        if (!omit(e.key))
          e.key: withoutTimes(e.value, artifact, [...path, e.key]),
    };
  if (value is List)
    return value.map((v) => withoutTimes(v, artifact, path)).toList();
  return value;
}

String canonical(Object? value) =>
    PyJson.encode(value, ensureAscii: false, compact: true, allowNan: false)
        .replaceAll('\u0085', r'\u0085')
        .replaceAll('\u2028', r'\u2028')
        .replaceAll('\u2029', r'\u2029');
Json read(File path) => jsonDecode(path.readAsStringSync()) as Json;
Map<String, String> artifacts(Directory root) {
  final List<File> files = [
    for (final String name in ['book.json', 'kg.json', 'status.json'])
      File('${root.path}/$name'),
    for (final String name in ['work', 'mentions'])
      ...Directory(
        '${root.path}/$name',
      ).listSync(recursive: true).whereType<File>(),
  ];
  return {
    for (final File file in files)
      file.path.substring(root.path.length + 1): sha256Hex(
        file.path.endsWith('.json')
            ? utf8.encode(
              '${canonical(withoutTimes(jsonDecode(file.readAsStringSync()), file.path.substring(root.path.length + 1)))}\n',
            )
            : file.readAsBytesSync(),
      ),
  };
}

void copyTree(Directory source, Directory target) {
  target.createSync(recursive: true);
  for (final FileSystemEntity entity in source.listSync(recursive: true)) {
    final String destination =
        '${target.path}/${entity.path.substring(source.path.length + 1)}';
    if (entity is File) {
      File(destination).parent.createSync(recursive: true);
      entity.copySync(destination);
    } else if (entity is Directory) {
      Directory(destination).createSync(recursive: true);
    } else {
      throw StateError('Unexpected fixture entity');
    }
  }
}

class CountingTape implements llm.ChatTransport {
  CountingTape(this.tape);
  final CassetteTransport tape;
  int models = 0, judges = 0;
  @override
  Future<llm.ChatResponse> post(llm.ChatRequest request, Duration timeout) {
    if (request.url.host == 'classifier.dev') {
      judges++;
    } else {
      models++;
    }
    return tape.post(request, timeout);
  }
}

void configure(Directory root) {
  environ
    ..clear()
    ..addAll({
      'LLM_BASE_URL': 'https://open.xiaojingai.com/v1',
      'LLM_BASE_URL_OPENAI': 'https://open.xiaojingai.com/v1',
      'LLM_PROTOCOL': 'openai',
      'LLM_PROTOCOL_MAP': 'deepseek-flash=openai',
      'LLM_KEY_NAME': 'ORACLE_REPLAY_KEY',
      'LLM_KEY_MAP': 'deepseek-flash=ORACLE_REPLAY_KEY',
      'ORACLE_REPLAY_KEY': 'oracle-placeholder',
      'JEV_ROUTE': 'free-only',
      'CLASSIFIER_URL': 'https://classifier.dev/v1/classify',
      'CLASSIFIER_KEY': '',
      'JUDGE_LOG_DIR': '${root.path}/work/judge',
      'JUDGE_LOG': '0',
      'EXTRACT_MODEL': 'deepseek-flash+nothink',
      'LOCAL_MODEL': 'deepseek-flash+nothink',
      'RECAP_MODEL': 'deepseek-flash+nothink',
      'JUDGE_MODEL': 'deepseek-flash+nothink',
      'CLASSIFY_MODEL': 'deepseek-flash+nothink',
    });
  llm.resetEnvCache();
  jev.resetJevStats();
}

void main() {
  late CassetteTransport tape;
  late CountingTape counting;
  late Directory root;
  late Map<String, String> originalEnvironment;
  late llm.ChatTransport originalTransport;
  final Json reference = read(
    File('../oracle/goldens/books/aq_deepseek/provenance.json'),
  );
  final Json resumeReceipt = read(
    File('../oracle/goldens/resume/aq_paused_annotated.json'),
  );
  setUpAll(
    () => tape = CassetteTransport(Directory('../oracle/cassettes/live')),
  );
  setUp(() {
    root = Directory.systemTemp.createTempSync('thusfar-full-replay-');
    originalEnvironment = {...environ};
    originalTransport = llm.transport;
    tape.offsets.clear();
    tape.requests.clear();
    tape.misses.clear();
    llm.transport = counting = CountingTape(tape);
    configure(root);
  });
  tearDown(() {
    llm.transport = originalTransport;
    environ
      ..clear()
      ..addAll(originalEnvironment);
    llm.resetEnvCache();
    root.deleteSync(recursive: true);
  });
  for (final int concurrency in [1, 12]) {
    test(
      'fresh Aq at concurrency $concurrency matches all 154 Python artifacts',
      () async {
        File(
          '../oracle/corpus/snapshots/aq_complete/book.json',
        ).copySync('${root.path}/book.json');
        await runBook(root, concurrency: concurrency);
        final Json state = read(File('${root.path}/status.json'));
        expect(
          [state['state'], state['done'], state['total'], state['frontier']],
          ['done', 9, 9, 21733],
        );
        expect(tape.misses, isEmpty);
        expect([counting.models, counting.judges], [21, 82]);
        final Map<String, String> actual = artifacts(root);
        final Map<String, String> expected =
            (reference['artifact_sha256']! as Json).cast<String, String>();
        expect(actual.keys.toSet(), expected.keys.toSet());
        for (final String name in expected.keys) {
          expect(
            actual[name],
            expected[name],
            reason: 'Python normalized artifact differs: $name',
          );
        }
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
  test(
    'paused Aq resumes with exact Python artifacts and preserves prefix caches and notebook',
    () async {
      copyTree(
        Directory('../oracle/corpus/snapshots/aq_paused_annotated'),
        root,
      );
      final Json resumed =
          ((resumeReceipt['runs']! as Json)['resume']! as Json);
      final Map<String, String> preserved =
          (resumed['preserved_sha256']! as Json).cast<String, String>();
      await runBook(root, concurrency: 1);
      expect(tape.misses, isEmpty);
      expect([counting.models, counting.judges], [13, 46]);
      final Map<String, String> actual = artifacts(root),
          expected =
              (resumed['artifact_sha256']! as Json).cast<String, String>();
      expect(actual.keys.toSet(), expected.keys.toSet());
      for (final String name in expected.keys) {
        expect(
          actual[name],
          expected[name],
          reason: 'Resumed artifact differs: $name',
        );
      }
      for (final String name in preserved.keys) {
        expect(
          sha256Hex(File('${root.path}/$name').readAsBytesSync()),
          preserved[name],
          reason: 'Existing cache or notebook was rewritten: $name',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
