import 'dart:async';
import 'dart:io';

import 'package:thusfar_core/http_server.dart';

Future<void> main(List<String> args) async {
  String host = '127.0.0.1';
  int port = 18770;
  String? data, web;
  for (int i = 0; i < args.length; i++) {
    if (args[i] == '--help' || args[i] == '-h') {
      stdout.writeln(
        '用法：dart run bin/server.dart [--host 127.0.0.1] [--port 18770] [--data 数据目录] [--web 网页目录]',
      );
      return;
    }
    if (!<String>['--host', '--port', '--data', '--web'].contains(args[i]) ||
        i + 1 >= args.length) {
      stderr.writeln('参数无效，请使用 --help 查看用法');
      exitCode = 64;
      return;
    }
    final String flag = args[i], value = args[++i];
    switch (flag) {
      case '--host':
        host = value;
      case '--port':
        final int? parsed = int.tryParse(value);
        if (parsed == null || parsed < 0 || parsed > 65535) {
          stderr.writeln('端口必须是 0 到 65535 之间的整数');
          exitCode = 64;
          return;
        }
        port = parsed;
      case '--data':
        data = value;
      case '--web':
        web = value;
    }
  }
  final Directory scriptFolder = File.fromUri(Platform.script).parent;
  final Directory repository =
      Platform.script.path.endsWith('.dart')
          ? scriptFolder.parent.parent
          : Directory(scriptFolder.path + '/web').existsSync()
          ? scriptFolder
          : Directory.current;
  final Map<String, String> env = Platform.environment;
  final YeduHttpServer server = YeduHttpServer(
    data: Directory(data ?? env['DATA_DIR'] ?? repository.path + '/data'),
    web: Directory(web ?? env['WEB_DIR'] ?? repository.path + '/web'),
    passcode: env['PASSCODE'] ?? '',
    localMode: env['YEDU_LOCAL_MODE'] == '1',
    autoProcess: (env['AUTO_PROCESS'] ?? '0') == '1',
    cookieSecure: (env['COOKIE_SECURE'] ?? '1') == '1',
    release: env['YEDU_RELEASE_ID'] ?? env['RELEASE_ID'] ?? '2.0.0-dev.3',
    readTimeout: Duration(
      milliseconds:
          ((double.tryParse(env['HTTP_READ_TIMEOUT'] ?? '30') ?? 30) * 1000)
              .round(),
    ),
    answerTimeout: Duration(
      milliseconds:
          ((double.tryParse(env['ANSWER_TIMEOUT'] ?? '180') ?? 180) * 1000)
              .round(),
    ),
    httpConcurrency: int.parse(env['HTTP_CONCURRENCY'] ?? '32'),
    askConcurrency: int.parse(env['ASK_CONCURRENCY'] ?? '2'),
    onError: (Object error, StackTrace trace) {
      stderr.writeln('请求处理失败：$error');
    },
  );
  await server.start(host: host, port: port);
  stdout.writeln(
    '页读服务已启动：http://$host:' +
        server.port.toString() +
        '，数据目录：' +
        server.data.path,
  );
  final Completer<void> stopping = Completer<void>();
  final List<StreamSubscription<ProcessSignal>> signals =
      <StreamSubscription<ProcessSignal>>[
        ProcessSignal.sigint.watch().listen((_) {
          if (!stopping.isCompleted) stopping.complete();
        }),
        if (!Platform.isWindows)
          ProcessSignal.sigterm.watch().listen((_) {
            if (!stopping.isCompleted) stopping.complete();
          }),
      ];
  await stopping.future;
  for (final StreamSubscription<ProcessSignal> signal in signals) {
    await signal.cancel();
  }
  await server.close();
  stdout.writeln('服务已停止，整理任务和缓存已保留');
}
