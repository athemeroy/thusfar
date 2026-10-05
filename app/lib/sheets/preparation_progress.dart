import 'dart:io';

import 'package:flutter/material.dart';

import '../data/library.dart';
import '../data/preparation_plan.dart';
import '../ui/theme.dart';
import '../screens/background_processing_screen.dart';

/// Separate coverage, the selected goal and usable output. Stage labels report
/// observed activity, never a made-up percentage for an opaque model request.
class PreparationProgress extends StatelessWidget {
  const PreparationProgress({
    super.key,
    required this.status,
    required this.plan,
    required this.latest,
    required this.biographies,
  });
  final ProcessStatus status;
  final NativePreparationPlan plan;
  final Json? latest;
  final int biographies;

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final Object? rawPlan = status.raw['plan'];
    final Json? scope = rawPlan is Json ? rawPlan : null;
    final int target = (scope?['target_segments'] as num?)?.toInt() ?? 0;
    final int completed = (scope?['completed_segments'] as num?)?.toInt() ?? 0;
    final int chapter = plan.chapters
        .where((PreparationChapter c) => c.end <= status.frontier)
        .fold<int>(0, (int _, PreparationChapter c) => c.index + 1);
    final String active = switch (latest?['stage'] ?? latest?['phase']) {
      'detect_kind' || 'classify_chapters' || 'check_titles' => '检查章节标题',
      'extract' || 'model_attempt' || 'waiting_for_model' => '整理人物和事件',
      'relation' => '检查人物关系',
      'recap' => '生成本章前情',
      'finalize' || 'finalizing' || 'bio_generating' => '汇总人物资料',
      'bio_review' => '检查人物小传',
      _ => status.isActive ? '准备整理' : '整理已停止',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (scope != null) ...<Widget>[
          Text(
            '本次目标 · ${scope['state'] == 'complete' ? '范围已完成' : '$completed / $target 段'}',
            style: TextStyle(color: t.ink, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          LinearProgressIndicator(
            value: target == 0 ? 0 : (completed / target).clamp(0.0, 1.0),
            color: t.zhu,
            backgroundColor: t.rule,
          ),
          const SizedBox(height: 8),
        ],
        Text(
          '全书已整理 ${status.done} / ${status.total} 段 · ${chapter == 0 ? '尚无完整章节' : '已整理到第 $chapter 章末'}',
          style: TextStyle(color: t.ink2, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Text(
          status.isActive ? '当前：$active' : '上次正在：$active',
          style: TextStyle(color: t.ink2, fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 6),
        Text(
          '已保存：${status.done} 段正文 · $biographies 篇人物小传。读到对应章节后可查看。',
          style: TextStyle(color: t.ink2, fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 12),
        if (Platform.isAndroid)
          TextButton.icon(
            icon: const Icon(Icons.battery_saver_outlined, size: 18),
            label: const Text('切到后台继续整理'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const BackgroundProcessingScreen(),
              ),
            ),
          ),
      ],
    );
  }
}
