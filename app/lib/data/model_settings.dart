import 'dart:io';

import 'package:thusfar_core/model_settings.dart' as core;
import 'package:thusfar_core/thusfar_core.dart' show PyException;

/// Flutter adapter for the same private settings used by the native server.
class ModelSettings {
  ModelSettings(this.file) : _settings = core.ModelSettings(file);

  final File file;
  final core.ModelSettings _settings;

  static const String defaultUrl = core.ModelSettings.defaultUrl;
  static const String defaultModel = core.ModelSettings.defaultModel;
  static const Map<String, String> protocolLabels =
      core.ModelSettings.protocolLabels;
  static const Map<String, String> defaultUrls = core.ModelSettings.defaultUrls;

  (String, String, String) read() {
    final Map<String, Object?> settings = _settings.read();
    return (
      settings['base_url']! as String,
      settings['model']! as String,
      settings['api_key']! as String,
    );
  }

  String get protocol => _settings.read()['protocol']! as String;
  String get protocolLabel => protocolLabels[protocol]!;
  bool get hasKey => read().$3.isNotEmpty;
  void applyEnvironment() => _settings.applyEnvironment();

  static (String, String) normalize(
    String url,
    String model, {
    String protocol = 'openai',
  }) => core.ModelSettings.normalize(url, model, protocol: protocol);

  Future<Map<String, Object?>> test({
    required String url,
    required String model,
    required String key,
    required bool clearKey,
    required String protocol,
  }) => _settings.test(
    payload: <String, Object?>{
      'base_url': url.trim(),
      'model': model.trim(),
      'api_key': key.trim(),
      'clear_key': clearKey,
      'protocol': protocol,
    },
  );

  String? save({
    required String url,
    required String model,
    String? key,
    bool clearKey = false,
    String? protocol,
  }) {
    try {
      _settings.save(<String, Object?>{
        'base_url': url.trim(),
        'model': model.trim(),
        'api_key': key ?? '',
        'clear_key': clearKey,
        'protocol': protocol ?? this.protocol,
      });
      return null;
    } on PyException catch (error) {
      return error.message;
    } on FileSystemException {
      return '模型设置未能保存，请检查存储空间后重试';
    }
  }
}
