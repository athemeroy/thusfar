import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/prefs.dart';
import '../ui/theme.dart';
import 'reading_controls_sheet.dart';

/// Keep part of the book visible while changing reading layout.
Future<void> openTypography(
  BuildContext context,
  Prefs prefs, {
  Offset? anchorPoint,
}) {
  final Widget panel = ListenableBuilder(
    listenable: prefs,
    builder: (BuildContext context, _) =>
        _TypographyPanel(prefs: prefs, anchorPoint: anchorPoint),
  );
  if (MediaQuery.sizeOf(context).width >= 720) {
    return showDialog<void>(
      context: context,
      anchorPoint: anchorPoint,
      barrierColor: Colors.black.withValues(alpha: .18),
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(width: 560, child: panel),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    anchorPoint: anchorPoint,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.transparent,
    builder: (BuildContext _) => panel,
  );
}

/// Drags stay local; a long chapter is repaginated only when the finger lifts.
class _MetricControl extends StatefulWidget {
  const _MetricControl({
    required this.label,
    required this.value,
    required this.minimum,
    required this.maximum,
    required this.step,
    required this.format,
    required this.onCommit,
  });

  final String label;
  final double value;
  final double minimum;
  final double maximum;
  final double step;
  final String Function(double) format;
  final ValueChanged<double> onCommit;

  @override
  State<_MetricControl> createState() => _MetricControlState();
}

class _MetricControlState extends State<_MetricControl> {
  late double _draft = widget.value;
  bool _dragging = false;

  @override
  void didUpdateWidget(covariant _MetricControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_dragging && widget.value != oldWidget.value) {
      _draft = widget.value;
    }
  }

  void _commit(double value) {
    final double snapped = double.parse(
      ((((value - widget.minimum) / widget.step).round() * widget.step) +
              widget.minimum)
          .toStringAsFixed(2),
    );
    setState(() {
      _dragging = false;
      _draft = snapped;
    });
    if (snapped != widget.value) {
      HapticFeedback.selectionClick();
      widget.onCommit(snapped);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final double value = _draft.clamp(widget.minimum, widget.maximum);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 60,
            child: Text(
              widget.label,
              style: TextStyle(fontSize: 13, color: t.ink3),
            ),
          ),
          IconButton(
            tooltip: '${widget.label}减少',
            visualDensity: VisualDensity.standard,
            constraints: const BoxConstraints.tightFor(width: 44, height: 44),
            padding: EdgeInsets.zero,
            onPressed: value <= widget.minimum
                ? null
                : () => _commit(
                    (value - widget.step).clamp(widget.minimum, widget.maximum),
                  ),
            icon: const Icon(Icons.remove, size: 18),
          ),
          Expanded(
            child: Slider(
              min: widget.minimum,
              max: widget.maximum,
              divisions: ((widget.maximum - widget.minimum) / widget.step)
                  .round(),
              value: value,
              label: widget.format(value),
              activeColor: t.ink,
              inactiveColor: t.rule,
              semanticFormatterCallback: widget.format,
              onChangeStart: (_) => setState(() => _dragging = true),
              onChanged: (double next) => setState(() => _draft = next),
              onChangeEnd: _commit,
            ),
          ),
          IconButton(
            tooltip: '${widget.label}增加',
            visualDensity: VisualDensity.standard,
            constraints: const BoxConstraints.tightFor(width: 44, height: 44),
            padding: EdgeInsets.zero,
            onPressed: value >= widget.maximum
                ? null
                : () => _commit(
                    (value + widget.step).clamp(widget.minimum, widget.maximum),
                  ),
            icon: const Icon(Icons.add, size: 18),
          ),
          SizedBox(
            width: 46,
            child: Text(
              widget.format(value),
              textAlign: TextAlign.end,
              style: TextStyle(fontSize: 11, color: t.ink2),
            ),
          ),
        ],
      ),
    );
  }
}

class _TypographyPanel extends StatelessWidget {
  const _TypographyPanel({required this.prefs, this.anchorPoint});

  final Prefs prefs;
  final Offset? anchorPoint;

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    Widget row(String label, Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 60,
            child: Text(label, style: TextStyle(fontSize: 13, color: t.ink3)),
          ),
          Expanded(child: child),
        ],
      ),
    );
    Widget metric(
      String label,
      double value,
      double minimum,
      double maximum,
      double step,
      String Function(double) format,
      ValueChanged<double> onChanged,
    ) => _MetricControl(
      label: label,
      value: value,
      minimum: minimum,
      maximum: maximum,
      step: step,
      format: format,
      onCommit: onChanged,
    );
    Widget choice(
      List<String> labels,
      int index,
      ValueChanged<int> on, {
      List<String?>? fontFamilies,
      List<List<String>?>? fontFallbacks,
    }) => Wrap(
      spacing: 8,
      runSpacing: 4,
      children: <Widget>[
        for (int i = 0; i < labels.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(
                labels[i],
                style:
                    fontFamilies != null &&
                        i < fontFamilies.length &&
                        fontFamilies[i] != null
                    ? TextStyle(
                        fontFamily: fontFamilies[i],
                        fontFamilyFallback:
                            fontFallbacks != null && i < fontFallbacks.length
                            ? fontFallbacks[i]
                            : null,
                      )
                    : null,
              ),
              selected: i == index,
              onSelected: (_) {
                HapticFeedback.selectionClick();
                on(i);
              },
              selectedColor: t.ink,
              labelStyle: TextStyle(
                color: i == index ? t.sheet : t.ink,
                fontSize: 14,
                fontFamily: fontFamilies != null && i < fontFamilies.length
                    ? fontFamilies[i]
                    : null,
                fontFamilyFallback:
                    fontFallbacks != null && i < fontFallbacks.length
                    ? fontFallbacks[i]
                    : null,
              ),
              showCheckmark: false,
              side: BorderSide(color: i == index ? t.ink : t.rule),
              backgroundColor: t.sheet,
            ),
          ),
      ],
    );
    return Container(
      decoration: BoxDecoration(
        color: t.sheet,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: math.min(620, MediaQuery.sizeOf(context).height * 0.72),
            child: Column(
              children: <Widget>[
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: t.rule,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '阅读排版',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: t.ink,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭排版',
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ],
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => prefs.update((Prefs p) {
                      p.fontSize = 19;
                      p.spacing = 1;
                      p.lineHeightOverride = null;
                      p.letterSpacing = 0;
                      p.pageHorizontalMargin = 20;
                      p.pageVerticalMargin = 16;
                      p.font = 0;
                    }),
                    child: const Text('恢复文字默认值'),
                  ),
                ),
                Expanded(
                  child: ListView(
                    children: <Widget>[
                      metric(
                        '字号',
                        prefs.fontSize,
                        14,
                        32,
                        0.5,
                        (double v) => '${v.toStringAsFixed(1)} pt',
                        (double v) => prefs.update((Prefs p) => p.fontSize = v),
                      ),
                      metric(
                        '行距',
                        prefs.lineHeight,
                        1.2,
                        2.4,
                        0.05,
                        (double v) => '${v.toStringAsFixed(2)}×',
                        (double v) =>
                            prefs.update((Prefs p) => p.lineHeightOverride = v),
                      ),
                      metric(
                        '字距',
                        prefs.letterSpacing,
                        -0.5,
                        2.5,
                        0.1,
                        (double v) => '${v.toStringAsFixed(1)} pt',
                        (double v) =>
                            prefs.update((Prefs p) => p.letterSpacing = v),
                      ),
                      metric(
                        '左右边距',
                        prefs.pageHorizontalMargin,
                        8,
                        96,
                        2,
                        (double v) => '${v.round()} dp',
                        (double v) => prefs.update(
                          (Prefs p) => p.pageHorizontalMargin = v,
                        ),
                      ),
                      metric(
                        '上下边距',
                        prefs.pageVerticalMargin,
                        4,
                        48,
                        2,
                        (double v) => '${v.round()} dp',
                        (double v) =>
                            prefs.update((Prefs p) => p.pageVerticalMargin = v),
                      ),
                      row(
                        '字体',
                        choice(
                          const <String>['宋', '楷', '黑'],
                          prefs.font,
                          (int i) => prefs.update((Prefs p) => p.font = i),
                          fontFamilies: const <String?>[
                            'NotoSerifSC',
                            'LXGWWenKaiScreen',
                            'NotoSansSC',
                          ],
                          fontFallbacks: const <List<String>?>[
                            <String>[
                              'NotoSerifSC',
                              'Songti SC',
                              'STSong',
                              'SimSun',
                              'serif',
                            ],
                            <String>['NotoSerifSC', 'serif'],
                            <String>[
                              'MiSans',
                              'MiSans Normal',
                              'Noto Sans CJK SC',
                              'Source Han Sans SC',
                              'PingFang SC',
                              'Heiti SC',
                              'sans-serif',
                              'NotoSerifSC',
                            ],
                          ],
                        ),
                      ),
                      row(
                        '纸色',
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: <Widget>[
                            for (int i = 0; i < Tokens.paperColors.length; i++)
                              Semantics(
                                label: '纸色：${Tokens.paperColors[i].$1}',
                                button: true,
                                selected: i == prefs.paper,
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  prefs.update((Prefs p) => p.paper = i);
                                },
                                child: ExcludeSemantics(
                                  child: Tooltip(
                                    message: '纸色：${Tokens.paperColors[i].$1}',
                                    child: InkWell(
                                      customBorder: const CircleBorder(),
                                      onTap: () {
                                        HapticFeedback.selectionClick();
                                        prefs.update((Prefs p) => p.paper = i);
                                      },
                                      child: Container(
                                        width: 44,
                                        height: 44,
                                        decoration: BoxDecoration(
                                          color: Tokens.paperColors[i].$2,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: i == prefs.paper
                                                ? t.zhu
                                                : t.rule,
                                            width: i == prefs.paper ? 2.2 : 1,
                                          ),
                                          boxShadow: i == prefs.paper
                                              ? <BoxShadow>[
                                                  BoxShadow(
                                                    color: t.zhu.withValues(
                                                      alpha: 0.25,
                                                    ),
                                                    blurRadius: 6,
                                                  ),
                                                ]
                                              : null,
                                        ),
                                        child: i == 4
                                            ? const Icon(
                                                Icons.dark_mode_outlined,
                                                size: 16,
                                                color: Colors.white70,
                                              )
                                            : i == prefs.paper
                                            ? Center(
                                                child: Container(
                                                  width: 6,
                                                  height: 6,
                                                  decoration: BoxDecoration(
                                                    color: t.zhu,
                                                    shape: BoxShape.circle,
                                                  ),
                                                ),
                                              )
                                            : null,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      row(
                        '翻页',
                        choice(
                          const <String>['平移', '覆盖', '无'],
                          prefs.anim.index,
                          (int i) => prefs.update(
                            (Prefs p) => p.anim = PageAnim.values[i],
                          ),
                        ),
                      ),
                      ListTile(
                        title: const Text('点击区域'),
                        subtitle: Text(
                          tapPresetLabel(prefs.tapLayout.matchingPreset),
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => openReadingControls(
                          context,
                          prefs,
                          anchorPoint: anchorPoint,
                        ),
                      ),
                      SwitchListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                        ),
                        title: Text(
                          '音量键翻页',
                          style: TextStyle(fontSize: 14, color: t.ink),
                        ),
                        value: prefs.volumeKeys,
                        activeThumbColor: t.ink,
                        onChanged: (bool v) {
                          HapticFeedback.selectionClick();
                          prefs.update((Prefs p) => p.volumeKeys = v);
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
