import 'package:flutter/material.dart';

import '../ui/theme.dart';

/// The preparation route owns work and its lease. This small observable lets a
/// reader explicitly opened above that route show and stop the existing run.
class WebPreparationActivity extends ChangeNotifier {
  bool running = false;
  bool stopping = false;
  int done = 0;
  int total = 0;
  String label = '尚未开始';
  VoidCallback? stop;

  void update({
    required bool running,
    required bool stopping,
    required int done,
    required int total,
    required String label,
    required VoidCallback stop,
  }) {
    this.running = running;
    this.stopping = stopping;
    this.done = done;
    this.total = total;
    this.label = label;
    this.stop = stop;
    notifyListeners();
  }
}

class WebPreparationReader extends StatelessWidget {
  const WebPreparationReader({
    super.key,
    required this.activity,
    required this.child,
  });
  final WebPreparationActivity activity;
  final Widget child;
  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      Expanded(child: child),
      ListenableBuilder(
        listenable: activity,
        builder: (BuildContext context, Widget? _) {
          final Tokens t = context.tk;
          return Material(
            color: t.sheet,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  children: <Widget>[
                    if (activity.running)
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: t.zhu,
                        ),
                      ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Text(
                        '${activity.label} · ${activity.done}/${activity.total} 段',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: t.ink,
                          fontFamily: sans,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    if (activity.running)
                      IconButton(
                        tooltip: '停止整理',
                        onPressed: activity.stopping ? null : activity.stop,
                        icon: const Icon(Icons.stop_circle_outlined),
                      ),
                    TextButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text('查看整理'),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ],
  );
}
