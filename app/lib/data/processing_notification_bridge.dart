import 'dart:io';

import 'package:flutter/services.dart';

/// Android's progress notification follows the in-process book worker.
/// It does not restart a task after Android kills the application process.
class ProcessingNotificationBridge {
  ProcessingNotificationBridge._();

  static const MethodChannel _channel = MethodChannel(
    'thusfar/processing_notifications',
  );
  static Future<void> Function(String)? _openBook;
  static Future<void> Function(List<String>)? _backgroundTimeLimit;

  /// Completes only after native foreground startup succeeds.
  /// Returns whether Android currently allows the notification in its drawer.
  /// The service may still run when Android 13+ notification permission is denied.
  static Future<bool> start({
    required String bookId,
    required String title,
    required String phase,
    required int done,
    required int total,
  }) async {
    if (!Platform.isAndroid) return false;
    return await _channel.invokeMethod<bool>('start', <String, Object>{
          'bookId': bookId,
          'title': title,
          'phase': phase,
          'done': done,
          'total': total,
        }) ??
        false;
  }

  /// Returns false if the service is no longer running; the caller can show
  /// task status in the app and decide whether a new user action should start it.
  static Future<bool> update({
    required String bookId,
    required String title,
    required String phase,
    required int done,
    required int total,
  }) async {
    if (!Platform.isAndroid) return true;
    return await _channel.invokeMethod<bool>('update', <String, Object>{
          'bookId': bookId,
          'title': title,
          'phase': phase,
          'done': done,
          'total': total,
        }) ??
        false;
  }

  static Future<void> stop(String bookId) async {
    if (!Platform.isAndroid) return;
    await _channel.invokeMethod<bool>('stop', <String, Object>{
      'bookId': bookId,
    });
  }

  static Future<Map<String, Object?>> diagnostics() async {
    if (!Platform.isAndroid) return const <String, Object?>{};
    try {
      return Map<String, Object?>.from(
        await _channel.invokeMapMethod<String, Object?>('diagnostics') ??
            const {},
      );
    } on Object {
      return const <String, Object?>{'available': false};
    }
  }

  static Future<void> recordLifecycle(String state) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<void>('lifecycle', <String, Object>{
        'state': state,
      });
    } on Object {
      // Diagnostics must never control the worker's lifetime.
    }
  }

  /// Drain the book ID from a notification tap after the library is ready.
  static Future<String?> takeOpenedBookId() async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMethod<String>('takeOpenedBookId');
  }

  /// Read Android's durable signal after an FGS time limit, including on a
  /// cold launch when the live channel event could not reach Flutter.
  static Future<List<String>> takeBackgroundTimeLimitBookIds() async {
    if (!Platform.isAndroid) return const <String>[];
    return await _channel.invokeListMethod<String>(
          'takeBackgroundTimeLimitBookIds',
        ) ??
        const <String>[];
  }

  /// Called for a tap that reaches an already-running activity. Also call
  /// [takeOpenedBookId] on startup because a cold launch can precede this hook.
  static void onOpenBook(Future<void> Function(String)? handler) {
    if (!Platform.isAndroid) return;
    _openBook = handler;
    _installHandler();
  }

  static void onBackgroundTimeLimit(
    Future<void> Function(List<String>)? handler,
  ) {
    if (!Platform.isAndroid) return;
    _backgroundTimeLimit = handler;
    _installHandler();
  }

  static void _installHandler() {
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'openBook' && _openBook != null) {
        final String? bookId = await takeOpenedBookId();
        if (bookId != null) await _openBook!(bookId);
      } else if (call.method == 'backgroundTimeLimit' &&
          _backgroundTimeLimit != null) {
        final List<String> bookIds = await takeBackgroundTimeLimitBookIds();
        if (bookIds.isNotEmpty) await _backgroundTimeLimit!(bookIds);
      }
    });
  }
}
