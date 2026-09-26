import 'dart:io';

/// `.model.env` in the data directory, the same file 1.7.x wrote.
class ModelSettings {
  ModelSettings(this.file);

  final File file;

  static const String defaultUrl = 'https://api.deepseek.com/v1';
  static const String defaultModel = 'deepseek-flash+nothink';

  Map<String, String> _values() {
    final Map<String, String> out = <String, String>{};
    if (!file.existsSync()) return out;
    for (final String line in file.readAsLinesSync()) {
      final int i = line.indexOf('=');
      if (i <= 0) continue;
      final String name = line.substring(0, i);
      if (const <String>[
        'LLM_BASE_URL',
        'LLM_API_KEY',
        'EXTRACT_MODEL',
        'JEV_ROUTE',
      ].contains(name)) {
        out[name] = line.substring(i + 1);
      }
    }
    return out;
  }

  /// (url, model, key), corrected like `model_settings.read`.
  (String, String, String) read() {
    final Map<String, String> v = _values();
    final (String url, String model) = normalize(
      (v['LLM_BASE_URL'] ?? '').isEmpty ? defaultUrl : v['LLM_BASE_URL']!,
      (v['EXTRACT_MODEL'] ?? '').isEmpty ? defaultModel : v['EXTRACT_MODEL']!,
    );
    return (url, model, v['LLM_API_KEY'] ?? '');
  }

  bool get hasKey => read().$3.isNotEmpty;

  /// Adds `/v1` to a bare host and `+nothink` to plain deepseek-* names.
  static (String, String) normalize(String url, String model) {
    String u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    final Uri? parsed = Uri.tryParse(u);
    if (parsed != null && (parsed.path.isEmpty || parsed.path == '/')) {
      u = '$u/v1';
    }
    String m = model.trim();
    if (m.toLowerCase().startsWith('deepseek-') && !m.contains('+')) {
      m = '$m+nothink';
    }
    return (u, m);
  }

  /// Validates and writes like `model_settings.save`; returns an error or null.
  String? save({
    required String url,
    required String model,
    String? key,
    bool clearKey = false,
  }) {
    final Uri? parsed = Uri.tryParse(url.trim());
    if (url.length > 500 || url.runes.any((int c) => c <= 32 || c == 127)) {
      return '模型接口地址无效';
    }
    if (parsed == null ||
        parsed.scheme != 'https' ||
        parsed.host.isEmpty ||
        parsed.userInfo.isNotEmpty ||
        parsed.hasQuery ||
        parsed.hasFragment) {
      return '模型接口请填写 HTTPS 地址，不要包含账号、参数或片段';
    }
    if (!RegExp(
      r'^[A-Za-z0-9][A-Za-z0-9._/+:-]{0,99}$',
    ).hasMatch(model.trim())) {
      return '模型名称无效';
    }
    final String k = key ?? '';
    if (k.length > 1024 || k.runes.any((int c) => c < 33 || c > 126)) {
      return 'API 密钥格式无效';
    }
    if (k.isNotEmpty && clearKey) return '不能同时填写和清除密钥';
    final String effective = clearKey ? '' : (k.isNotEmpty ? k : read().$3);
    final (String u, String m) = normalize(url, model);
    file.parent.createSync(recursive: true);
    final File tmp = File(
      '${file.parent.path}/.model-${DateTime.now().microsecondsSinceEpoch}',
    );
    tmp.writeAsStringSync(
      'LLM_BASE_URL=$u\nLLM_API_KEY=$effective\nEXTRACT_MODEL=$m\nJEV_ROUTE=free-only\n',
      flush: true,
    );
    tmp.renameSync(file.path);
    return null;
  }
}
