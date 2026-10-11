import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../data/reading_activity.dart';
import '../ui/theme.dart';

class ReadingActivityScreen extends StatelessWidget {
  const ReadingActivityScreen({super.key, required this.store});
  final ReadingActivityStore store;

  String _duration(int seconds) {
    if (seconds < 60) return '$seconds 秒';
    final int minutes = seconds ~/ 60;
    return minutes < 60
        ? '$minutes 分钟'
        : '${minutes ~/ 60} 小时 ${minutes % 60} 分钟';
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (BuildContext context, _) {
      final Tokens t = context.tk;
      final DateTime today = store.today;
      final List<DateTime> days = <DateTime>[
        for (int ago = 6; ago >= 0; ago--)
          DateTime(today.year, today.month, today.day - ago),
      ];
      final int goalSeconds = store.goalMinutes * 60;
      final int maxSeconds = days
          .map(store.secondsOn)
          .fold<int>(goalSeconds, math.max);
      final List<MapEntry<String, int>> books =
          store.bookSeconds.entries.where((entry) => entry.value > 0).toList()
            ..sort((a, b) => b.value.compareTo(a.value));
      return Scaffold(
        appBar: AppBar(title: const Text('阅读记录')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: <Widget>[
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: t.raised,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: t.rule),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('今日已读', style: TextStyle(color: t.ink2, fontSize: 14)),
                  const SizedBox(height: 8),
                  Text(
                    _duration(store.todaySeconds),
                    style: TextStyle(
                      fontFamily: display,
                      fontSize: 32,
                      color: t.ink,
                    ),
                  ),
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: (store.todaySeconds / goalSeconds).clamp(0.0, 1.0),
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(3),
                    backgroundColor: t.rule,
                    color: t.qing,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    store.todaySeconds >= goalSeconds
                        ? '今日目标已达成。'
                        : '每日目标 ${store.goalMinutes} 分钟，慢慢读就好。',
                    style: TextStyle(fontSize: 13, color: t.ink2),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 20,
              runSpacing: 12,
              children: <Widget>[
                Text(
                  '连续阅读 ${store.streakDays} 天',
                  style: TextStyle(color: t.ink),
                ),
                Text(
                  '累计 ${_duration(store.totalSeconds)}',
                  style: TextStyle(color: t.ink2),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              '每日目标',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: t.ink,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: <Widget>[
                for (final int minutes in <int>{
                  10,
                  20,
                  30,
                  60,
                  store.goalMinutes,
                }.toList()..sort())
                  ChoiceChip(
                    label: Text('$minutes 分钟'),
                    selected: store.goalMinutes == minutes,
                    onSelected: (_) => store.setGoalMinutes(minutes),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              '最近七天',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: t.ink,
              ),
            ),
            const SizedBox(height: 12),
            for (final DateTime day in days)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 54,
                      child: Text(
                        '${day.month}/${day.day}',
                        style: TextStyle(color: t.ink2, fontSize: 13),
                      ),
                    ),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: store.secondsOn(day) / maxSeconds,
                        minHeight: 8,
                        borderRadius: BorderRadius.circular(4),
                        backgroundColor: t.rule.withValues(alpha: .6),
                        color: t.qing,
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 76,
                      child: Text(
                        _duration(store.secondsOn(day)),
                        textAlign: TextAlign.end,
                        style: TextStyle(color: t.ink2, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            if (books.isNotEmpty) ...<Widget>[
              const SizedBox(height: 24),
              Text(
                '读过的书',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: t.ink,
                ),
              ),
              const SizedBox(height: 8),
              for (final entry in books)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(store.titleOf(entry.key)),
                  trailing: Text(
                    _duration(entry.value),
                    style: TextStyle(color: t.ink2),
                  ),
                ),
            ],
            const SizedBox(height: 24),
            Text(
              '仅统计本设备的前台阅读时间。离开阅读页、切到后台或 90 秒无操作时暂停计时。连续阅读按每天至少 1 分钟计算。',
              style: TextStyle(color: t.ink3, fontSize: 12, height: 1.6),
            ),
            if (store.error != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                store.error!,
                style: TextStyle(color: t.danger, fontSize: 13),
              ),
            ],
          ],
        ),
      );
    },
  );
}
