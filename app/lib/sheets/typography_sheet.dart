import 'package:flutter/material.dart';

import '../data/prefs.dart';
import '../ui/theme.dart';

/// S15 排版: the lower ~40% only, so the page above re-flows live.
Future<void> openTypography(BuildContext context, Prefs prefs) {
  return showModalBottomSheet<void>(
    context: context,
    barrierColor: Colors.transparent,
    builder: (BuildContext _) => ListenableBuilder(
      listenable: prefs,
      builder: (BuildContext context, _) => _TypographyPanel(prefs: prefs),
    ),
  );
}

class _TypographyPanel extends StatelessWidget {
  const _TypographyPanel({required this.prefs});

  final Prefs prefs;

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    Widget row(String label, Widget child) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 52,
            child: Text(label, style: TextStyle(fontSize: 13, color: t.ink3)),
          ),
          Expanded(child: child),
        ],
      ),
    );
    Widget choice(List<String> labels, int index, ValueChanged<int> on) => Row(
      children: <Widget>[
        for (int i = 0; i < labels.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(labels[i]),
              selected: i == index,
              onSelected: (_) => on(i),
              selectedColor: t.ink,
              labelStyle: TextStyle(
                color: i == index ? t.sheet : t.ink,
                fontSize: 14,
              ),
              showCheckmark: false,
              side: BorderSide(color: t.rule),
              backgroundColor: t.sheet,
            ),
          ),
      ],
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.only(top: 12, bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            row(
              '字号',
              Row(
                children: <Widget>[
                  Text('A−', style: TextStyle(color: t.ink2)),
                  Expanded(
                    child: Slider(
                      min: 16,
                      max: 26,
                      divisions: 10,
                      value: prefs.fontSize,
                      activeColor: t.ink,
                      inactiveColor: t.rule,
                      onChanged: (double v) =>
                          prefs.update((Prefs p) => p.fontSize = v),
                    ),
                  ),
                  Text('A+', style: TextStyle(color: t.ink2, fontSize: 18)),
                ],
              ),
            ),
            row(
              '行距',
              choice(
                const <String>['紧', '中', '松'],
                prefs.spacing,
                (int i) => prefs.update((Prefs p) => p.spacing = i),
              ),
            ),
            row(
              '字体',
              choice(
                const <String>['宋', '楷', '黑'],
                prefs.font,
                (int i) => prefs.update((Prefs p) => p.font = i),
              ),
            ),
            row(
              '纸色',
              Row(
                children: <Widget>[
                  for (int i = 0; i < Tokens.paperColors.length; i++)
                    Semantics(
                      label: '纸色：${Tokens.paperColors[i].$1}',
                      button: true,
                      selected: i == prefs.paper,
                      onTap: () => prefs.update((Prefs p) => p.paper = i),
                      child: ExcludeSemantics(
                        child: Tooltip(
                          message: '纸色：${Tokens.paperColors[i].$1}',
                          child: GestureDetector(
                            onTap: () => prefs.update((Prefs p) => p.paper = i),
                            child: Container(
                              margin: const EdgeInsets.only(right: 12),
                              width: 34,
                              height: 34,
                              decoration: BoxDecoration(
                                color: Tokens.paperColors[i].$2,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: i == prefs.paper ? t.zhu : t.rule,
                                  width: i == prefs.paper ? 2 : 1,
                                ),
                              ),
                              child: i == 4
                                  ? const Icon(
                                      Icons.dark_mode_outlined,
                                      size: 16,
                                      color: Colors.white70,
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
                (int i) =>
                    prefs.update((Prefs p) => p.anim = PageAnim.values[i]),
              ),
            ),
            SwitchListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              title: Text(
                '音量键翻页',
                style: TextStyle(fontSize: 14, color: t.ink),
              ),
              value: prefs.volumeKeys,
              activeThumbColor: t.ink,
              onChanged: (bool v) =>
                  prefs.update((Prefs p) => p.volumeKeys = v),
            ),
          ],
        ),
      ),
    );
  }
}
