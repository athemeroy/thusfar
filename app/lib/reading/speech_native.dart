import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'speech_backend.dart';

SpeechBackend createSpeechBackend() => _NativeSpeech();

class _NativeSpeech implements SpeechBackend {
  static const MethodChannel _channel = MethodChannel('thusfar/read_aloud');
  static int _nextId = 0;
  static _NativeSpeech? _owner;
  String? _utterance;
  void Function(SpeechEvent)? _listener;
  bool _disposed = false;
  bool _attached = false;

  @override
  Future<SpeechAvailability> initialize() async {
    if (!Platform.isAndroid) {
      return const SpeechAvailability(
        false,
        message: '此设备暂不支持听书，可在安卓版或支持语音的浏览器中使用。',
      );
    }
    if (_disposed) return const SpeechAvailability(false);
    if (!_attached) {
      _channel.setMethodCallHandler(_event);
      _owner = this;
      _attached = true;
    }
    try {
      final Map<Object?, Object?>? result = await _channel
          .invokeMapMethod<Object?, Object?>('initialize')
          .timeout(const Duration(seconds: 12));
      return SpeechAvailability(
        result?['available'] == true,
        message: result?['message'] as String?,
        settings: true,
      );
    } on Object {
      return const SpeechAvailability(
        false,
        message: '未能启动系统语音，请检查系统的文字转语音设置。',
        settings: true,
      );
    }
  }

  Future<void> _event(MethodCall call) async {
    if (_disposed || call.method != 'event') return;
    final Map<Object?, Object?>? data =
        call.arguments as Map<Object?, Object?>?;
    if (data == null || data['id'] != _utterance) return;
    final SpeechEventType? type = switch (data['type']) {
      'start' => SpeechEventType.start,
      'boundary' => SpeechEventType.boundary,
      'done' => SpeechEventType.done,
      'interrupted' => SpeechEventType.interrupted,
      'error' => SpeechEventType.error,
      _ => null,
    };
    if (type != null) {
      _listener?.call(
        SpeechEvent(
          type,
          offset: (data['offset'] as num?)?.toInt() ?? 0,
          message: data['message'] as String?,
        ),
      );
    }
  }

  @override
  Future<void> speak(
    String text, {
    required double rate,
    required String language,
    required void Function(SpeechEvent) onEvent,
  }) async {
    if (_disposed) return;
    final String id = 'reader-${++_nextId}';
    _utterance = id;
    _listener = onEvent;
    try {
      final Map<Object?, Object?>? response = await _channel
          .invokeMapMethod<Object?, Object?>('speak', <String, Object?>{
            'id': id,
            'text': text,
            'rate': rate,
            'language': language,
          });
      if (_utterance == id && response?['accepted'] != true) {
        onEvent(
          SpeechEvent(
            SpeechEventType.error,
            message: response?['message'] as String? ?? '系统语音暂不可用，请稍后重试。',
          ),
        );
      }
    } on Object {
      if (_utterance == id && !_disposed) {
        onEvent(
          const SpeechEvent(SpeechEventType.error, message: '系统语音暂不可用，请稍后重试。'),
        );
      }
    }
  }

  @override
  Future<void> stop() async {
    final String? id = _utterance;
    _utterance = null;
    _listener = null;
    if (id == null) return;
    try {
      await _channel.invokeMethod<void>('stop', <String, Object?>{'id': id});
    } on Object {
      // Page disposal must remain safe when the activity is already gone.
    }
  }

  @override
  Future<void> openSettings() async {
    try {
      await _channel.invokeMethod<void>('settings');
    } on Object {
      // The panel still names the setting if a vendor provides no direct link.
    }
  }

  @override
  void dispose() {
    unawaited(stop());
    _disposed = true;
    if (_attached && identical(_owner, this)) {
      _channel.setMethodCallHandler(null);
      _owner = null;
    }
  }
}
