import 'package:flutter/material.dart';

import '../data/library.dart';
import '../data/preparation_plan.dart';
import '../ui/theme.dart';

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
      'detect_kind' || 'classify_chapters' || 'check_titles' => '准备和标题检查',
      'extract' || 'model_attempt' || 'waiting_for_model' => '抽取正文中的事实',
      'relation' => '核对人物与关系',
      'recap' => '生成本章前情',
      'finalize' || 'finalizing' || 'bio_generating' => '汇总人物资料',
      'bio_review' => '核对人物小传',
      _ => status.isActive ? '等待下一条阶段记录' : '没有正在运行的请求',
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
          '全书正文覆盖 ${status.done} / ${status.total} 段 · ${chapter == 0 ? '尚无完整章节' : '已覆盖到第 $chapter 章末'}',
          style: TextStyle(color: t.ink2, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 5,
          runSpacing: 5,
          children: <Widget>[
            for (final String stage in const <String>[
              '抽取正文',
              '证据核对',
              '人物关系',
              '按章汇总',
              '可读资料',
            ])
              Chip(
                label: Text(stage, style: const TextStyle(fontSize: 11)),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
              ),
          ],
        ),
        Text(
          '各片段依次经过这些工序，章节资料可并行完成。\n${status.isActive ? '当前：$active' : '最近阶段：$active'}',
          style: TextStyle(color: t.ink2, fontSize: 12, height: 1.4),
        ),
        const SizedBox(height: 6),
        Text(
          '已保存：${status.done} 段正文 · $biographies 篇核对通过的小传。资料只在对应阅读位置解锁。',
          style: TextStyle(color: t.ink2, fontSize: 12, height: 1.4),
        ),
        if (scope?['classification_source'] == 'local')
          Text(
            '本次采用本地章节分类，尚未做全书模型分类。',
            style: TextStyle(color: t.ink3, fontSize: 12),
          ),
        const SizedBox(height: 12),
      ],
    );
  }
}
