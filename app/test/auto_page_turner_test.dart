import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/reading/auto_page_turner.dart';

void main() {
  testWidgets('uses natural next page and stops at the book end', (
    tester,
  ) async {
    final AutoPageTurner controller = AutoPageTurner();
    controller.setIntervalSeconds(10);
    int turns = 0;
    controller.start(nextPage: () => ++turns < 3);
    await tester.pump(const Duration(seconds: 9));
    expect(turns, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(turns, 1);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 10));
    expect(turns, 3);
    expect(controller.running, isFalse);
    expect(controller.message, contains('书末'));
    controller.dispose();
  });

  testWidgets('touch pause and background stop cancel pending turns', (
    tester,
  ) async {
    final AutoPageTurner controller = AutoPageTurner();
    int turns = 0;
    controller.start(
      nextPage: () {
        turns++;
        return true;
      },
    );
    await tester.pump(const Duration(seconds: 5));
    controller.pause();
    await tester.pump(const Duration(seconds: 60));
    expect(turns, 0);
    expect(controller.paused, isTrue);
    controller.resume();
    await tester.pump(const Duration(seconds: 20));
    expect(turns, 1);
    controller.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 60));
    expect(turns, 1);
    expect(controller.running, isFalse);
    expect(controller.paused, isFalse);
    controller.dispose();
  });

  testWidgets('sleep timer stops even while automatic turns are paused', (
    tester,
  ) async {
    final AutoPageTurner controller = AutoPageTurner();
    controller.setStopAfterMinutes(15);
    controller.start(nextPage: () => true);
    controller.pause();
    await tester.pump(const Duration(minutes: 15));
    expect(controller.running, isFalse);
    expect(controller.paused, isFalse);
    expect(controller.message, contains('定时已到'));
    controller.dispose();
  });
}
