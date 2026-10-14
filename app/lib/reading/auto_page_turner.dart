import 'dart:async';

import 'package:flutter/widgets.dart';

export 'auto_page_panel.dart' show openAutoPageTurner;

/// Drives the reader's existing next-page action. It never chooses offsets or
/// changes the knowledge boundary itself. A false return means the book ended.
class AutoPageTurner extends ChangeNotifier with WidgetsBindingObserver {
  AutoPageTurner() {
    WidgetsBinding.instance.addObserver(this);
  }
  int _intervalSeconds = 20;
  int get intervalSeconds => _intervalSeconds;
  int _stopAfterMinutes = 30;
  int get stopAfterMinutes => _stopAfterMinutes;
  bool _running = false;
  bool get running => _running;
  bool _paused = false;
  bool get paused => _paused;
  bool _disposed = false;
  String? message;
  Timer? _pageTimer;
  Timer? _stopTimer;
  DateTime? _stopAt;
  bool Function()? _nextPage;
  Duration? get remaining {
    if (_stopAt == null) return null;
    final Duration value = _stopAt!.difference(DateTime.now());
    return value.isNegative ? Duration.zero : value;
  }

  void setIntervalSeconds(int seconds) {
    _intervalSeconds = seconds.clamp(10, 120);
    if (_running) _schedulePage();
    notifyListeners();
  }

  void setStopAfterMinutes(int minutes) {
    _stopAfterMinutes = const <int>[0, 15, 30, 60].contains(minutes)
        ? minutes
        : 30;
    if (_running || _paused) _scheduleStop();
    notifyListeners();
  }

  void start({required bool Function() nextPage}) {
    if (_disposed) return;
    _nextPage = nextPage;
    _running = true;
    _paused = false;
    message = null;
    _scheduleStop();
    _schedulePage();
    notifyListeners();
  }

  void _scheduleStop() {
    _stopTimer?.cancel();
    _stopAt = _stopAfterMinutes == 0
        ? null
        : DateTime.now().add(Duration(minutes: _stopAfterMinutes));
    if (_stopAt != null) {
      _stopTimer = Timer(
        Duration(minutes: _stopAfterMinutes),
        () => stop(reason: '定时已到，自动翻页已停止。'),
      );
    }
  }

  void _schedulePage() {
    _pageTimer?.cancel();
    _pageTimer = Timer(Duration(seconds: _intervalSeconds), () {
      if (!_running || _disposed) return;
      final bool moved = _nextPage?.call() ?? false;
      if (!_running || _disposed) return;
      if (!moved) {
        stop(reason: '已到书末，自动翻页已停止。');
      } else {
        _schedulePage();
        notifyListeners();
      }
    });
  }

  void pause() {
    if (!_running || _disposed) return;
    _running = false;
    _paused = true;
    _pageTimer?.cancel();
    message = '已暂停，打开自动翻页可继续。';
    notifyListeners();
  }

  void resume() {
    if (!_paused || _disposed || _nextPage == null) return;
    if (_stopAt != null && !DateTime.now().isBefore(_stopAt!)) {
      stop(reason: '定时已到，自动翻页已停止。');
      return;
    }
    _running = true;
    _paused = false;
    message = null;
    _schedulePage();
    notifyListeners();
  }

  void stop({String? reason}) {
    if (_disposed) return;
    final bool wasActive = _running || _paused;
    _pageTimer?.cancel();
    _stopTimer?.cancel();
    _running = false;
    _paused = false;
    _nextPage = null;
    _stopAt = null;
    message = reason;
    if (wasActive || reason != null) notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) stop();
  }

  @override
  void dispose() {
    _disposed = true;
    _pageTimer?.cancel();
    _stopTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
