import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'auto_page_turner.dart';

Future<void> openAutoPageTurner(
  BuildContext context,
  AutoPageTurner controller, {
  required bool Function() nextPage,
}) {
  controller.pause();
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 600),
    builder: (BuildContext context) => ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, _) {
        final Tokens t = context.tk;
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '自动翻页',
                  style: TextStyle(
                    fontFamily: display,
                    fontSize: 24,
                    color: t.ink,
                  ),
                ),
                const SizedBox(height: 8),
                Text('按阅读节奏逐页前进，轻触屏幕即暂停。', style: TextStyle(color: t.ink2)),
                const SizedBox(height: 20),
                Row(
                  children: <Widget>[
                    const Text('每页停留'),
                    Expanded(
                      child: Slider(
                        min: 10,
                        max: 120,
                        divisions: 22,
                        value: controller.intervalSeconds.toDouble(),
                        label: '${controller.intervalSeconds} 秒',
                        onChanged: (double seconds) =>
                            controller.setIntervalSeconds(seconds.round()),
                      ),
                    ),
                    SizedBox(
                      width: 52,
                      child: Text(
                        '${controller.intervalSeconds} 秒',
                        textAlign: TextAlign.end,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('定时停止'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: <Widget>[
                    for (final int minutes in const <int>[15, 30, 60, 0])
                      ChoiceChip(
                        label: Text(minutes == 0 ? '到书末' : '$minutes 分钟'),
                        selected: controller.stopAfterMinutes == minutes,
                        onSelected: (_) =>
                            controller.setStopAfterMinutes(minutes),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  '打开其他阅读面板或切到后台时停止。',
                  style: TextStyle(fontSize: 12, color: t.ink3),
                ),
                if (controller.message != null) ...<Widget>[
                  const SizedBox(height: 12),
                  Text(controller.message!, style: TextStyle(color: t.ink2)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () {
                    if (controller.paused) {
                      controller.resume();
                    } else {
                      controller.start(nextPage: nextPage);
                    }
                    Navigator.of(context).pop();
                  },
                  child: Text(controller.paused ? '继续翻页' : '开始翻页'),
                ),
                if (controller.running || controller.paused)
                  TextButton(
                    onPressed: controller.stop,
                    child: const Text('停止翻页'),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
