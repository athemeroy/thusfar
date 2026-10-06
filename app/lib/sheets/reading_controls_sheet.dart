import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/prefs.dart';
import '../reader/tap_layout.dart';
import '../ui/theme.dart';

String tapPresetLabel(ReaderTapPreset? preset) => switch (preset) {
  ReaderTapPreset.classic => '经典',
  ReaderTapPreset.leftHanded => '左手',
  ReaderTapPreset.rightHanded => '右手',
  null => '自定义',
};

String _actionLabel(ReaderTapAction action) => switch (action) {
  ReaderTapAction.previous => '上一页',
  ReaderTapAction.tools => '工具',
  ReaderTapAction.next => '下一页',
  ReaderTapAction.none => '无动作',
};

IconData _actionIcon(ReaderTapAction action) => switch (action) {
  ReaderTapAction.previous => Icons.arrow_back,
  ReaderTapAction.tools => Icons.menu,
  ReaderTapAction.next => Icons.arrow_forward,
  ReaderTapAction.none => Icons.block,
};

Future<void> openReadingControls(
  BuildContext context,
  Prefs prefs, {
  Offset? anchorPoint,
}) {
  final Widget panel = ListenableBuilder(
    listenable: prefs,
    builder: (BuildContext context, _) => _ReadingControlsPanel(prefs: prefs),
  );
  if (MediaQuery.sizeOf(context).width >= 720) {
    return showDialog<void>(
      context: context,
      anchorPoint: anchorPoint,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(width: 520, child: panel),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    anchorPoint: anchorPoint,
    backgroundColor: Colors.transparent,
    builder: (_) => panel,
  );
}

class _ReadingControlsPanel extends StatefulWidget {
  const _ReadingControlsPanel({required this.prefs});

  final Prefs prefs;

  @override
  State<_ReadingControlsPanel> createState() => _ReadingControlsPanelState();
}

class _ReadingControlsPanelState extends State<_ReadingControlsPanel> {
  int _selected = 6;
  static const List<String> _positions = <String>[
    '左上',
    '上方',
    '右上',
    '左侧',
    '正中',
    '右侧',
    '左下',
    '下方',
    '右下',
  ];

  void _change(ReaderTapLayout layout) {
    HapticFeedback.selectionClick();
    widget.prefs.update((Prefs p) => p.tapLayout = layout);
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final ReaderTapLayout layout = widget.prefs.tapLayout;
    final ReaderTapPreset? preset = layout.matchingPreset;
    final double cellHeight = math.max(
      76,
      MediaQuery.textScalerOf(context).scale(14) * 2 + 36,
    );
    return Material(
      color: t.sheet,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: math.min(680, MediaQuery.sizeOf(context).height * .85),
          child: Column(
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 8, 4),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '点击区域',
                        style: TextStyle(
                          color: t.ink,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '关闭点击区域',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                  children: <Widget>[
                    Text(
                      '选择顺手的布局，或点选下方一格更改动作。设置立即保存。',
                      style: TextStyle(color: t.ink2, fontSize: 14),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: <Widget>[
                        for (final ReaderTapPreset choice
                            in ReaderTapPreset.values)
                          ChoiceChip(
                            key: ValueKey<String>('tap-preset-${choice.name}'),
                            label: Text(tapPresetLabel(choice)),
                            selected: preset == choice,
                            onSelected: (_) =>
                                _change(ReaderTapLayout.preset(choice)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(switch (preset) {
                      ReaderTapPreset.classic => '经典：左侧上一页，中间工具，右侧下一页',
                      ReaderTapPreset.leftHanded => '左手：左侧中部和两个底角翻下一页，顶角翻上一页',
                      ReaderTapPreset.rightHanded => '右手：右侧中部和两个底角翻下一页，顶角翻上一页',
                      null => '自定义：每格对应正文区域的九分之一',
                    }, style: TextStyle(color: t.ink2, fontSize: 13)),
                    const SizedBox(height: 12),
                    for (int row = 0; row < 3; row++)
                      Row(
                        children: <Widget>[
                          for (int col = 0; col < 3; col++)
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.all(3),
                                child: _zone(
                                  context,
                                  row * 3 + col,
                                  layout.actions[row * 3 + col],
                                  cellHeight,
                                ),
                              ),
                            ),
                        ],
                      ),
                    const SizedBox(height: 8),
                    Text(
                      '${_positions[_selected]}区域的动作',
                      style: TextStyle(
                        color: t.ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: <Widget>[
                        for (final ReaderTapAction action
                            in ReaderTapAction.values)
                          ChoiceChip(
                            key: ValueKey<String>('tap-action-${action.name}'),
                            label: Text(_actionLabel(action)),
                            selected: layout.actions[_selected] == action,
                            onSelected: (_) =>
                                _change(layout.withAction(_selected, action)),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '正中固定为工具，避免自定义后找不到设置。示意图按正文区域划分，含页边距；折叠屏按当前阅读分区计算。',
                      style: TextStyle(color: t.ink3, fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '左右滑动和音量键方向不变。长按仍可选字；选字后轻点只取消选择。',
                      style: TextStyle(color: t.ink3, fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => _change(
                          ReaderTapLayout.preset(ReaderTapPreset.classic),
                        ),
                        child: const Text('恢复点击默认值'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _zone(
    BuildContext context,
    int index,
    ReaderTapAction action,
    double height,
  ) {
    final Tokens t = context.tk;
    final bool fixed = index == 4;
    final bool selected = index == _selected;
    return Semantics(
      label:
          '${_positions[index]}：${_actionLabel(action)}${fixed ? '，固定' : ''}',
      button: !fixed,
      selected: selected,
      onTap: fixed ? null : () => setState(() => _selected = index),
      child: ExcludeSemantics(
        child: Material(
          color: selected ? t.ink.withValues(alpha: .08) : t.sheet,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(
              color: selected ? t.ink : t.rule,
              width: selected ? 2 : 1,
            ),
          ),
          child: InkWell(
            key: ValueKey<String>('tap-zone-$index'),
            borderRadius: BorderRadius.circular(8),
            onTap: fixed ? null : () => setState(() => _selected = index),
            child: Container(
              constraints: BoxConstraints(minHeight: height),
              padding: const EdgeInsets.all(6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(
                    fixed ? Icons.lock_outline : _actionIcon(action),
                    size: 18,
                    color: t.ink2,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _actionLabel(action),
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, color: t.ink),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
