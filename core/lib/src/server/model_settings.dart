/// Private native settings shared by Flutter and the Dart HTTP server.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import '../env.dart';
import '../errors.dart';
import '../pipeline/jev.dart' as judge;
import '../pipeline/llm.dart' as llm;
import '../py/py_compat.dart';
import '../py/py_re.dart';

typedef Json = Map<String, Object?>;

class ModelSettings {
  ModelSettings(this.file);
  final File file;

  static const Map<String, String> protocolLabels = <String, String>{
    'openai': 'OpenAI Compatible',
    'gemini': 'Gemini',
    'anthropic': 'Claude Compatible',
  };
  static const Map<String, String> defaultUrls = <String, String>{
    'openai': 'https://api.openai.com/v1',
    'gemini': 'https://generativelanguage.googleapis.com/v1beta',
    'anthropic': 'https://api.anthropic.com/v1',
  };
  static const String defaultUrl = 'https://api.openai.com/v1';
  static const String defaultModel = '';
  static final RegExp _model = pyRe(r'[A-Za-z0-9][A-Za-z0-9._/+:-]{0,99}\Z');

  Json read() {
    final Map<String, String> values = <String, String>{};
    if (file.existsSync()) {
      for (final String line in file.readAsLinesSync()) {
        final int split = line.indexOf('=');
        if (split <= 0) continue;
        final String name = line.substring(0, split);
        if (const <String>{
          'LLM_BASE_URL',
          'LLM_API_KEY',
          'CLASSIFIER_KEY',
          'JEV_API_KEY',
          'EXTRACT_MODEL',
          'JEV_ROUTE',
          'JUDGE_API_URL',
          'JUDGE_API_MODEL',
          'JUDGE_API_KEY',
          'LLM_PROTOCOL',
        }.contains(name))
          values[name] = line.substring(split + 1);
      }
    }
    final String protocol =
        values['LLM_PROTOCOL']?.isNotEmpty == true
            ? values['LLM_PROTOCOL']!
            : 'openai';
    if (!protocolLabels.containsKey(protocol)) {
      throw const ValueError('模型接口协议无效');
    }
    final (String url, String model) = normalize(
      values['LLM_BASE_URL']?.isNotEmpty == true
          ? values['LLM_BASE_URL']!
          : defaultUrls[protocol]!,
      values['EXTRACT_MODEL'] ?? defaultModel,
      protocol: protocol,
    );
    return <String, Object?>{
      'protocol': protocol,
      'base_url': url,
      'model': model,
      'jev_route':
          values['JEV_ROUTE']?.isNotEmpty == true
              ? values['JEV_ROUTE']!
              : 'free-only',
      'api_key': values['LLM_API_KEY'] ?? '',
      'classifier_key': values['CLASSIFIER_KEY'] ?? '',
      'jev_api_key': values['JEV_API_KEY'] ?? '',
      'judge_url': values['JUDGE_API_URL'] ?? '',
      'judge_model': values['JUDGE_API_MODEL'] ?? '',
      'judge_api_key': values['JUDGE_API_KEY'] ?? '',
    };
  }

  Json public() {
    final Json settings = read();
    final String key = settings.remove('api_key')! as String;
    final String classifierKey = settings.remove('classifier_key')! as String;
    final String jevKey = settings.remove('jev_api_key')! as String;
    final String judgeKey = settings.remove('judge_api_key')! as String;
    settings['api_key_set'] = key.isNotEmpty;
    settings['api_key_last4'] = PyCompat.slice(key, -4, null);
    settings['classifier_key_set'] = classifierKey.isNotEmpty;
    settings['classifier_key_last4'] = PyCompat.slice(classifierKey, -4, null);
    settings['judge_api_key_set'] = judgeKey.isNotEmpty;
    settings['judge_api_key_last4'] = PyCompat.slice(judgeKey, -4, null);
    settings['jev_api_key_set'] = jevKey.isNotEmpty;
    settings['jev_api_key_last4'] = PyCompat.slice(jevKey, -4, null);
    return settings;
  }

  static (String, String) normalize(
    String url,
    String model, {
    String protocol = 'openai',
  }) {
    String address = PyCompat.strip(url);
    while (address.endsWith('/')) {
      address = address.substring(0, address.length - 1);
    }
    final Uri? parsed = Uri.tryParse(address);
    if (parsed != null && parsed.path.isEmpty && address.isNotEmpty) {
      address += protocol == 'gemini' ? '/v1beta' : '/v1';
    }
    String name = PyCompat.strip(model);
    // Preserve legacy 1.7.x DeepSeek names on read. Current model names must
    // remain exact; the LLM request layer applies any explicit +variant.
    if (protocol == 'openai' &&
        const <String>{
          'deepseek-chat',
          'deepseek-reasoner',
        }.contains(name.toLowerCase()) &&
        !name.contains('+'))
      name += '+nothink';
    return (address, name);
  }

  /// Apply the saved protocol in this isolate, including custom Gemini/Claude
  /// compatible hosts. Do not let prior per-model route maps override the form.
  void applyEnvironment() {
    final Json settings = read();
    final String protocol = settings['protocol']! as String;
    final String url = settings['base_url']! as String;
    for (final String name in const <String>[
      'EXTRACT_MODEL',
      'LOCAL_MODEL',
      'RECAP_MODEL',
      'JUDGE_MODEL',
      'CLASSIFY_MODEL',
      'QA_MODEL',
      'MARGINALIA_MODEL',
      'MARGINALIA_AUTO_MODEL',
    ]) {
      environ[name] = settings['model']! as String;
    }
    environ['SECRETS_FILE'] = file.path;
    // Empty keys/maps are intentional clears, not permission to inherit ~/.env.
    environ['LLM_SETTINGS_AUTHORITY'] = '1';
    environ['LLM_PROTOCOL'] = protocol;
    environ['LLM_PROTOCOL_MAP'] = '';
    environ['LLM_KEY_MAP'] = '';
    environ['LLM_KEY_NAME'] = '';
    environ['LLM_API_KEY'] = settings['api_key']! as String;
    environ['CLASSIFIER_KEY'] = settings['classifier_key']! as String;
    environ['JEV_API_KEY'] = settings['jev_api_key']! as String;
    environ['LLM_BASE_URL'] = url;
    for (final String route in protocolLabels.keys) {
      environ['LLM_BASE_URL_${route.toUpperCase()}'] =
          route == protocol ? url : defaultUrls[route]!;
    }
    environ['JEV_ROUTE'] = settings['jev_route']! as String;
    environ['JUDGE_API_URL'] = settings['judge_url']! as String;
    environ['JUDGE_API_MODEL'] = settings['judge_model']! as String;
    environ['JUDGE_API_KEY'] = settings['judge_api_key']! as String;
    if (settings['jev_route'] == 'model' &&
        (settings['judge_model']! as String).isNotEmpty) {
      environ['JUDGE_MODEL'] = settings['judge_model']! as String;
    }
    llm.resetEnvCache();
  }

  /// Validate a form against the saved settings without writing or routing changes.
  Json preview(Json payload) {
    final Json current = read();
    Object? supplied(String key) =>
        payload.containsKey(key) ? payload[key] : current[key];
    final Object? protocol = supplied('protocol');
    if (protocol is! String || !protocolLabels.containsKey(protocol)) {
      throw const ValueError('模型接口协议无效');
    }
    final Object? url = supplied('base_url');
    final Object? model = supplied('model');
    final Object? route = supplied('jev_route');
    final Object? key =
        payload.containsKey('api_key') ? payload['api_key'] : '';
    if (url is! String ||
        url.runes.length > 500 ||
        url.runes.any((int c) => c <= 32 || c == 127)) {
      throw const ValueError('模型接口地址无效');
    }
    final Uri? parsed = Uri.tryParse(url);
    final bool loopbackHttp =
        parsed?.scheme == 'http' &&
        const <String>{
          'localhost',
          '127.0.0.1',
          '::1',
        }.contains(parsed!.host.toLowerCase());
    if (parsed == null ||
        (parsed.scheme != 'https' && !loopbackHttp) ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasQuery ||
        parsed.hasFragment) {
      throw const ValueError(
        '模型接口请填写 HTTPS 地址；本机 localhost 可用 HTTP。不要包含账号、参数或片段',
      );
    }
    if (model is! String || pyFullmatch(_model, model) == null) {
      throw const ValueError('模型名称无效');
    }
    if (route != 'free-only' &&
        route != 'free-then-model' &&
        route != 'systemone' &&
        route != 'model') {
      throw const ValueError('JEV 路线无效');
    }
    final Object? rawJudgeUrl = supplied('judge_url');
    final Object? judgeModel = supplied('judge_model');
    if (rawJudgeUrl is! String ||
        judgeModel is! String ||
        (judgeModel.isNotEmpty && pyFullmatch(_model, judgeModel) == null)) {
      throw const ValueError('核对接口地址或模型名称无效');
    }
    String judgeUrl = rawJudgeUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (route == 'systemone' && judgeUrl.isEmpty) {
      judgeUrl = '${normalize(url, model, protocol: protocol).$1}/systemone';
    }
    if (judgeUrl.isNotEmpty) {
      final Uri? endpoint = Uri.tryParse(judgeUrl);
      final bool localHttp =
          endpoint?.scheme == 'http' &&
          const <String>{
            'localhost',
            '127.0.0.1',
            '::1',
          }.contains(endpoint!.host);
      if (endpoint == null ||
          (endpoint.scheme != 'https' && !localHttp) ||
          endpoint.host.isEmpty ||
          endpoint.userInfo.isNotEmpty ||
          endpoint.hasQuery ||
          endpoint.hasFragment ||
          judgeUrl.length > 500 ||
          judgeUrl.runes.any((c) => c <= 32 || c == 127)) {
        throw const ValueError('核对接口请填写 HTTPS 地址；本机 localhost 可用 HTTP');
      }
    }
    final Object? judgeKey = payload['judge_api_key'] ?? '';
    final Object? clearJudge = payload['clear_judge_api_key'];
    if (judgeKey is! String ||
        judgeKey.runes.length > 1024 ||
        judgeKey.runes.any((int c) => c < 33 || c > 126) ||
        (clearJudge != null && clearJudge is! bool) ||
        (judgeKey.isNotEmpty && clearJudge == true)) {
      throw const ValueError('核对接口密钥格式无效');
    }
    final String effectiveJudgeKey =
        clearJudge == true
            ? ''
            : judgeKey.isNotEmpty
            ? judgeKey
            : current['judge_api_key']! as String;
    if (key is! String ||
        key.runes.length > 1024 ||
        key.runes.any((int c) => c < 33 || c > 126)) {
      throw const ValueError('API 密钥格式无效');
    }
    final Object? clear = payload['clear_key'];
    if (clear != null && clear is! bool) throw const ValueError('清除密钥选项无效');
    if (key.isNotEmpty && clear == true) throw const ValueError('不能同时填写和清除密钥');
    final Object? classifierKey = payload['classifier_key'] ?? '';
    final Object? clearClassifier = payload['clear_classifier_key'];
    if (classifierKey is! String ||
        classifierKey.runes.length > 1024 ||
        classifierKey.runes.any((int c) => c < 33 || c > 126)) {
      throw const ValueError('classifier.dev 工作区密钥格式无效');
    }
    if (clearClassifier != null && clearClassifier is! bool) {
      throw const ValueError('清除 classifier.dev 密钥选项无效');
    }
    if (classifierKey.isNotEmpty && clearClassifier == true) {
      throw const ValueError('不能同时填写和清除 classifier.dev 密钥');
    }
    final Object? jevKey = payload['jev_api_key'] ?? '';
    final Object? clearJev = payload['clear_jev_api_key'];
    if (jevKey is! String ||
        jevKey.runes.length > 1024 ||
        jevKey.runes.any((int c) => c < 33 || c > 126)) {
      throw const ValueError('Jev 网关密钥格式无效');
    }
    if (clearJev != null && clearJev is! bool) {
      throw const ValueError('清除 Jev 网关密钥选项无效');
    }
    if (jevKey.isNotEmpty && clearJev == true) {
      throw const ValueError('不能同时填写和清除 Jev 网关密钥');
    }
    final (String address, String name) = normalize(
      url,
      model,
      protocol: protocol,
    );
    final String effective =
        clear == true
            ? ''
            : key.isNotEmpty
            ? key
            : current['api_key']! as String;
    final String effectiveClassifier =
        clearClassifier == true
            ? ''
            : classifierKey.isNotEmpty
            ? classifierKey
            : current['classifier_key']! as String;
    final String effectiveJev =
        clearJev == true
            ? ''
            : jevKey.isNotEmpty
            ? jevKey
            : current['jev_api_key']! as String;
    if (effective.isNotEmpty &&
        key.isEmpty &&
        (protocol != current['protocol'] || address != current['base_url'])) {
      throw const ValueError('接口地址或协议已变更，请重新填写 API 密钥');
    }
    return <String, Object?>{
      'protocol': protocol,
      'base_url': address,
      'model': name,
      'api_key': effective,
      'classifier_key': effectiveClassifier,
      'jev_api_key': effectiveJev,
      'jev_route': route,
      'judge_url': judgeUrl,
      'judge_model': judgeModel,
      'judge_api_key': effectiveJudgeKey,
    };
  }

  Json save(Json payload) {
    final Json settings = preview(payload);
    writePrivateFile(
      file,
      <String, String>{
            'LLM_BASE_URL': settings['base_url']! as String,
            'LLM_API_KEY': settings['api_key']! as String,
            'CLASSIFIER_KEY': settings['classifier_key']! as String,
            'JEV_API_KEY': settings['jev_api_key']! as String,
            'EXTRACT_MODEL': settings['model']! as String,
            'JEV_ROUTE': settings['jev_route']! as String,
            'JUDGE_API_URL': settings['judge_url']! as String,
            'JUDGE_API_MODEL': settings['judge_model']! as String,
            'JUDGE_API_KEY': settings['judge_api_key']! as String,
            'LLM_PROTOCOL': settings['protocol']! as String,
          }.entries
          .map((MapEntry<String, String> e) => '${e.key}=${e.value}\n')
          .join(),
    );
    applyEnvironment();
    return public();
  }

  Future<Json> test({Json? payload}) async {
    final Json settings = payload == null ? read() : preview(payload);
    if ((settings['api_key']! as String).isEmpty) {
      return <String, Object?>{
        'ok': false,
        'message': llm.explain(const llm.LLMError('缺少模型访问密钥')),
      };
    }
    if ((settings['model']! as String).isEmpty) {
      return <String, Object?>{'ok': false, 'message': '请先填写模型名称'};
    }
    final Stopwatch watch = Stopwatch()..start();
    try {
      final llm.ChatResult result = await llm.chat(
        settings['model']! as String,
        <Map<String, String>>[
          <String, String>{'role': 'user', 'content': '只回答两个字：可以'},
        ],
        maxTokens: 16,
        temperature: 0,
        timeout: 30,
        retries: 0,
        endpoint: llm.ChatEndpoint(
          protocol: settings['protocol']! as String,
          baseUrl: settings['base_url']! as String,
          apiKey: settings['api_key']! as String,
        ),
      );
      final double seconds = watch.elapsedMicroseconds / 1000000;
      final String reply = llm.redactSecrets(
        PyCompat.strip(result.text),
        <String>[
          settings['api_key']! as String,
          settings['judge_api_key']! as String,
        ],
      );
      String message =
          '连接成功：${settings['model']} 用 ${seconds.toStringAsFixed(1)} 秒回复了「${PyCompat.slice(reply, 0, 20)}」';
      final String judgeKey =
          (settings['judge_api_key']! as String).isNotEmpty
              ? settings['judge_api_key']! as String
              : settings['api_key']! as String;
      final String judgeModel = settings['judge_model']! as String;
      final String judgeUrl = settings['judge_url']! as String;
      if (settings['jev_route'] == 'systemone' ||
          settings['jev_route'] == 'model') {
        final Json questions = <String, Object?>{
          'check': <String, Object?>{
            'type': 'choice',
            'instructions':
                'Does the passage support the claim that 林舟 is the lighthouse keeper?',
            'criteria': <String, Object?>{
              'yes': 'Supported',
              'no': 'Not supported',
            },
          },
        };
        if (settings['jev_route'] == 'systemone') {
          await judge.systemOneJudge(
            '林舟是灯塔管理员。',
            questions,
            endpoint: judgeUrl,
            apiKey: judgeKey,
            model: judgeModel,
          );
        } else {
          await judge.llmJudge(
            '林舟是灯塔管理员。',
            questions,
            model:
                judgeModel.isEmpty ? settings['model']! as String : judgeModel,
            endpoint: llm.ChatEndpoint(
              protocol: settings['protocol']! as String,
              baseUrl:
                  judgeUrl.isEmpty ? settings['base_url']! as String : judgeUrl,
              apiKey: judgeKey,
            ),
          );
        }
        message += '；核对接口测试通过';
      }
      if (seconds > 8) message += '。这个模型回复较慢，整理一本书可能需要较长时间';
      return <String, Object?>{
        'ok': true,
        'message': llm.redactSecrets(message, <String>[
          settings['api_key']! as String,
          settings['judge_api_key']! as String,
        ]),
        'seconds': seconds,
      };
    } on Object catch (error) {
      final String detail = llm.redactSecrets(
        error is PyException ? error.message : '$error',
        <String>[
          settings['api_key']! as String,
          settings['judge_api_key']! as String,
        ],
      );
      return <String, Object?>{
        'ok': false,
        'message': PyCompat.slice(
          llm.explain(llm.LLMError(detail)) ?? '连接失败：$detail',
          0,
          240,
        ),
      };
    }
  }
}

typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _FreeNative = Void Function(Pointer<Void>);
typedef _ChmodNative = Int32 Function(Pointer<Uint8>, Uint32);

void _privateMode(File file) {
  if (Platform.isWindows) return; // Windows uses inherited directory ACLs.
  final DynamicLibrary libc = DynamicLibrary.open(
    Platform.isAndroid
        ? 'libc.so'
        : Platform.isMacOS || Platform.isIOS
        ? '/usr/lib/libSystem.B.dylib'
        : 'libc.so.6',
  );
  final Pointer<Void> Function(int) malloc = libc
      .lookupFunction<_MallocNative, Pointer<Void> Function(int)>('malloc');
  final void Function(Pointer<Void>) free = libc
      .lookupFunction<_FreeNative, void Function(Pointer<Void>)>('free');
  final int Function(Pointer<Uint8>, int) chmod = libc
      .lookupFunction<_ChmodNative, int Function(Pointer<Uint8>, int)>('chmod');
  final List<int> bytes = utf8.encode(file.path);
  final Pointer<Uint8> path = malloc(bytes.length + 1).cast<Uint8>();
  if (path == nullptr) throw StateError('Unable to allocate settings path');
  try {
    path.asTypedList(bytes.length + 1).setAll(0, <int>[...bytes, 0]);
    if (chmod(path, 384) != 0)
      throw FileSystemException('无法设置密钥文件权限', file.path);
  } finally {
    free(path.cast<Void>());
  }
}

/// Atomically replace a private text file, setting mode 0600 before writing on
/// POSIX. Callers creating shared identity files must serialize first creation.
void writePrivateFile(File file, String value) {
  file.parent.createSync(recursive: true);
  final File temporary = File(
    '${file.parent.path}/.model-$pid-${Random.secure().nextInt(1 << 32)}',
  );
  try {
    temporary.createSync(exclusive: true);
    _privateMode(temporary);
    temporary.writeAsStringSync(value, flush: true);
    temporary.renameSync(file.path);
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
}
