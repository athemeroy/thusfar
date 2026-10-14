import 'package:flutter_test/flutter_test.dart';
import 'package:thusfar_app/data/reading_activity.dart';

void main() {
  test('only active reading counts and idle time stops at 90 seconds', () {
    DateTime now = DateTime(2026, 10, 11, 12);
    final ReadingActivityStore store = ReadingActivityStore.memory(
      clock: () => now,
    );
    final ReadingActivitySession session = store.startSession(
      bookId: 'book',
      title: '书',
    );
    now = now.add(const Duration(seconds: 40));
    session.setActive(false);
    expect(store.todaySeconds, 40);
    now = now.add(const Duration(minutes: 5));
    session.setActive(true);
    now = now.add(const Duration(minutes: 3));
    store.flush();
    expect(store.todaySeconds, 130);
    session.touch();
    now = now.add(const Duration(seconds: 20));
    session.dispose();
    expect(store.todaySeconds, 150);
    store.dispose();
  });

  test('midnight splits days and two readers never double count', () {
    DateTime now = DateTime(2026, 10, 11, 23, 59, 30);
    final ReadingActivityStore store = ReadingActivityStore.memory(
      clock: () => now,
    );
    final ReadingActivitySession first = store.startSession(
      bookId: 'a',
      title: '甲',
    );
    now = now.add(const Duration(seconds: 20));
    final ReadingActivitySession second = store.startSession(
      bookId: 'b',
      title: '乙',
    );
    now = now.add(const Duration(seconds: 40));
    store.flush();
    expect(store.totalSeconds, 60);
    expect(store.secondsOn(DateTime(2026, 10, 11)), 30);
    expect(store.secondsOn(DateTime(2026, 10, 12)), 30);
    expect(store.bookSeconds, <String, int>{'a': 20, 'b': 40});
    first.dispose();
    second.dispose();
    store.dispose();
  });

  test('daily goal and streak use actual minutes without fabricated days', () {
    DateTime now = DateTime(2026, 10, 10, 12);
    final ReadingActivityStore store = ReadingActivityStore.memory(
      clock: () => now,
    );
    expect(store.goalMinutes, 20);
    expect(store.streakDays, 0);
    final ReadingActivitySession session = store.startSession(
      bookId: 'a',
      title: '甲',
    );
    now = now.add(const Duration(minutes: 1));
    session.setActive(false);
    expect(store.streakDays, 1);
    now = DateTime(2026, 10, 11, 12);
    session.setActive(true);
    now = now.add(const Duration(minutes: 1));
    session.setActive(false);
    expect(store.streakDays, 2);
    store.setGoalMinutes(30);
    expect(store.goalMinutes, 30);
    now = DateTime(2026, 10, 13, 12);
    expect(store.streakDays, 0);
    session.dispose();
    store.dispose();
  });
}
