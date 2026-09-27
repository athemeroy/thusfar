import 'dart:convert';
import 'dart:io';
import 'package:thusfar_core/run.dart';
import 'package:thusfar_core/src/env.dart';
import 'package:thusfar_core/src/pipeline/jev.dart' as jev;
import 'package:thusfar_core/src/pipeline/llm.dart' as llm;
import '../support/cassette_transport.dart';

class ReplayBackend extends RunBackend {
  const ReplayBackend();
  @override
  Future<void> sleep(Duration duration) async {}
}

Future<void> main(List<String> args) async {
  final Directory root = Directory(
    args.isEmpty ? '/tmp/thusfar-dart-aq' : args.first,
  );
  final int concurrency = args.length > 1 ? int.parse(args[1]) : 12;
  root.createSync(recursive: true);
  if (!File('${root.path}/book.json').existsSync())
    File(
      '../oracle/corpus/snapshots/aq_complete/book.json',
    ).copySync('${root.path}/book.json');
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
  final CassetteTransport tape = CassetteTransport(
    Directory('../oracle/cassettes/live'),
    diagnostics: Directory('${root.path}/diagnostics'),
  );
  llm.resetEnvCache();
  llm.transport = tape;
  jev.resetJevStats();
  try {
    await runBook(
      root,
      model: 'deepseek-flash+nothink',
      localModel: 'deepseek-flash+nothink',
      concurrency: concurrency,
      backend: const ReplayBackend(),
      onProgress:
          (state) => stdout.writeln(
            jsonEncode({
              'state': state['state'],
              'done': state['done'],
              'error': state['error'],
            }),
          ),
    );
  } finally {
    stdout.writeln(
      jsonEncode({
        'calls': tape.calls,
        'misses': tape.misses,
        'root': root.path,
      }),
    );
  }
}
