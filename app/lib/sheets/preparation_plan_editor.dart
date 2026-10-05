import 'package:flutter/material.dart';

import '../data/preparation_plan.dart';
import '../ui/theme.dart';

class PreparationPlanEditor extends StatelessWidget {
  const PreparationPlanEditor({
    super.key,
    required this.plan,
    required this.frontier,
    required this.onChanged,
  });
  final NativePreparationPlan plan;
  final int frontier;
  final ValueChanged<NativePreparationPlan> onChanged;

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final int prerequisites = plan.prerequisiteCharacters(frontier);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '这次整理到哪里',
          style: TextStyle(color: t.ink, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: <Widget>[
            for (final (String, String) option in const <(String, String)>[
              ('first', '首章试整理'),
              ('read', '读到这里'),
              ('range', '选择章节'),
              ('all', '整本书'),
            ])
              ChoiceChip(
                label: Text(option.$2),
                selected: plan.scope == option.$1,
                onSelected: (_) => onChanged(plan.copyWith(scope: option.$1)),
              ),
          ],
        ),
        if (plan.scope == 'range') ...<Widget>[
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: DropdownButtonFormField<int>(
                  key: ValueKey<String>('plan-from-${plan.startChapter}'),
                  initialValue: plan.chapter(plan.startChapter) == null
                      ? null
                      : plan.startChapter,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '目标从'),
                  items: <DropdownMenuItem<int>>[
                    for (final PreparationChapter chapter in plan.chapters)
                      DropdownMenuItem(
                        value: chapter.index,
                        child: Text('第 ${chapter.index + 1} 章'),
                      ),
                  ],
                  onChanged: (int? v) {
                    if (v != null) {
                      onChanged(
                        plan.copyWith(
                          startChapter: v,
                          endChapter: plan.endChapter < v ? v : plan.endChapter,
                        ),
                      );
                    }
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<int>(
                  key: ValueKey<String>(
                    'plan-to-${plan.startChapter}-${plan.endChapter}',
                  ),
                  initialValue: plan.chapter(plan.endChapter) == null
                      ? null
                      : plan.endChapter,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '整理到'),
                  items: <DropdownMenuItem<int>>[
                    for (final PreparationChapter chapter in plan.chapters)
                      if (chapter.index >= plan.startChapter)
                        DropdownMenuItem(
                          value: chapter.index,
                          child: Text('第 ${chapter.index + 1} 章'),
                        ),
                  ],
                  onChanged: (int? v) {
                    if (v != null) onChanged(plan.copyWith(endChapter: v));
                  },
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Text(
          '目标：${plan.label} · 还有约 ${plan.pendingCharacters(frontier)} 字',
          style: TextStyle(color: t.ink, fontSize: 13),
        ),
        const SizedBox(height: 5),
        Text(
          prerequisites > 0
              ? '前面约 $prerequisites 字还未整理，人物身份和关系依赖它们。本次会先从已保存进度补齐，再处理目标章节；这部分也会发送并计费。'
              : '从已保存进度继续，已完成的片段不会重复发送。达到本次范围后停止，扩大范围需要你再次开始。',
          style: TextStyle(
            color: prerequisites > 0 ? t.amber : t.ink2,
            fontSize: 12,
            height: 1.45,
          ),
        ),
        if (plan.scope == 'read') ...<Widget>[
          const SizedBox(height: 5),
          Text(
            '以当前显示位置为上限，只发送完整片段；跨过这一页的片段留到以后。不会为了凑整章发送未读正文。',
            style: TextStyle(color: t.ink2, fontSize: 12, height: 1.45),
          ),
        ],
        if (!plan.valid)
          Padding(
            padding: const EdgeInsets.only(top: 5),
            child: Text(
              '这个范围还没有可处理的正文，请先阅读或选择其他范围。',
              style: TextStyle(color: t.amber, fontSize: 12),
            ),
          ),
        Material(
          type: MaterialType.transparency,
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('片段大小与缓存复用'),
            children: <Widget>[
              Text(
                '目前保留已验证的片段大小。扩大早期窗口会改变缓存边界，也可能把后文身份带进前文资料；没有跨窗口质量和费用证据前不自动扩大。已完成的片段可复用，无需重新花费。',
                style: TextStyle(color: t.ink2, fontSize: 12, height: 1.45),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
