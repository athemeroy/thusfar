import 'package:flutter/material.dart';

import 'theme.dart';

/// The same three reading destinations on phone, tablet and browser.
class WorkspaceNavigation extends StatelessWidget {
  const WorkspaceNavigation({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    const entries = <(IconData, String, String)>[
      (Icons.auto_stories_outlined, '书架', '你的随身书房'),
      (Icons.edit_note_outlined, '书摘', '留存心动字句'),
      (Icons.tune_outlined, '设置', '偏好与数据管理'),
    ];
    return Material(
      color: t.sheet,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          child: Row(
            children: <Widget>[
              for (int i = 0; i < entries.length; i++) ...<Widget>[
                if (i > 0) const SizedBox(width: 8),
                Expanded(
                  child: Semantics(
                    selected: i == selectedIndex,
                    button: true,
                    hint: entries[i].$3,
                    child: Tooltip(
                      message: entries[i].$3,
                      child: TextButton(
                        onPressed: () => onSelected(i),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(0, 52),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 12,
                          ),
                          foregroundColor: i == selectedIndex ? t.qing : t.ink2,
                          backgroundColor: i == selectedIndex
                              ? t.qingSoft
                              : t.paper,
                          shape: const StadiumBorder(),
                        ),
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 6,
                          children: <Widget>[
                            Icon(entries[i].$1, size: 20),
                            Text(
                              entries[i].$2,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
