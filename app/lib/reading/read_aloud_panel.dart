import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'read_aloud.dart';

/// Closing the controls leaves speech running while the reader stays open.
/// The owning reader stops it on page disposal or when the user changes books.
Future<void> openReadAloud(
  BuildContext context,
  ReadAloudController controller, {
  required List<ReadAloudPassage> passages,
  void Function(int heardThrough)? onProgress,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 600),
  builder: (BuildContext context) => ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .85,
    ),
    child: ReadAloudPanel(
      controller: controller,
      passages: passages,
      onProgress: onProgress,
    ),
  ),
);

class ReadAloudPanel extends StatefulWidget {
  const ReadAloudPanel({
    super.key,
    required this.controller,
    required this.passages,
    this.onProgress,
  });

  final ReadAloudController controller;
  final List<ReadAloudPassage> passages;
  final void Function(int heardThrough)? onProgress;

  @override
  State<ReadAloudPanel> createState() => _ReadAloudPanelState();
}

class _ReadAloudPanelState extends State<ReadAloudPanel> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.initialize());
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final ReadAloudController controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (BuildContext context, _) {
        final bool busy = controller.state == ReadAloudState.preparing;
        final String label = controller.playing
            ? '暂停'
            : controller.paused
            ? '继续听'
            : '开始听';
        final Duration? remaining = controller.remaining;
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(Icons.headphones_outlined, color: t.qing),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '听书',
                        style: TextStyle(
                          fontFamily: display,
                          fontSize: 22,
                          color: t.ink,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '收起听书',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                Text(
                  '从当前位置听到本章末尾。',
                  style: TextStyle(color: t.ink2, height: 1.5),
                ),
                const SizedBox(height: 6),
                Text(
                  '切到后台会暂停，回到书架会停止。',
                  style: TextStyle(color: t.ink3, fontSize: 12, height: 1.5),
                ),
                if (controller.message != null) ...<Widget>[
                  const SizedBox(height: 16),
                  Text(
                    controller.message!,
                    key: const ValueKey<String>('read-aloud-message'),
                    style: TextStyle(color: t.ink2, height: 1.5),
                  ),
                ],
                const SizedBox(height: 20),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton.icon(
                        key: const ValueKey<String>('read-aloud-play'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed:
                            busy ||
                                !controller.available ||
                                widget.passages.isEmpty
                            ? null
                            : () async {
                                if (controller.playing) {
                                  await controller.pause();
                                } else if (controller.paused) {
                                  await controller.resume();
                                } else {
                                  await controller.play(
                                    widget.passages,
                                    onProgress: widget.onProgress,
                                  );
                                }
                              },
                        icon: Icon(
                          controller.playing ? Icons.pause : Icons.play_arrow,
                        ),
                        label: Text(busy ? '准备语音' : label),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 48),
                      ),
                      onPressed: controller.playing || controller.paused
                          ? () => unawaited(controller.stop())
                          : null,
                      icon: const Icon(Icons.stop),
                      label: const Text('停止'),
                    ),
                  ],
                ),
                if (!controller.available && !busy)
                  TextButton(
                    onPressed: () => unawaited(controller.initialize()),
                    child: const Text('重新检测'),
                  ),
                if (controller.settingsAvailable && controller.message != null)
                  TextButton(
                    onPressed: () => unawaited(controller.openSettings()),
                    child: const Text('系统语音设置'),
                  ),
                const SizedBox(height: 24),
                Row(
                  children: <Widget>[
                    const Text('朗读语速'),
                    const Spacer(),
                    Text(
                      '${controller.rate.toStringAsFixed(1)} 倍',
                      style: TextStyle(color: t.ink2),
                    ),
                  ],
                ),
                Slider(
                  value: controller.rate,
                  min: .5,
                  max: 2,
                  divisions: 15,
                  label: '${controller.rate.toStringAsFixed(1)} 倍',
                  semanticFormatterCallback: (double value) =>
                      '${value.toStringAsFixed(1)} 倍语速',
                  onChanged: (double value) =>
                      unawaited(controller.setRate(value)),
                ),
                Row(
                  children: <Widget>[
                    const Expanded(child: Text('定时停止')),
                    if (remaining != null)
                      Text(
                        '${(remaining.inSeconds / 60).ceil()} 分钟后',
                        style: TextStyle(color: t.ink3, fontSize: 12),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    for (final int minutes in <int>[0, 15, 30, 60])
                      ChoiceChip(
                        label: Text(minutes == 0 ? '关闭' : '$minutes 分钟'),
                        selected:
                            (controller.sleepDuration?.inMinutes ?? 0) ==
                            minutes,
                        onSelected: (_) => controller.setSleepTimer(
                          minutes == 0 ? null : Duration(minutes: minutes),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  '声音由系统或浏览器提供，部分声音需要联网。',
                  style: TextStyle(color: t.ink3, fontSize: 12, height: 1.5),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
