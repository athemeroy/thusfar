import 'dart:io';

import 'package:flutter/material.dart';

import '../data/library.dart';
import 'theme.dart';

/// A cover with the spine-side 3 dp and open-side 8 dp radius; generated
/// covers show the title in ZCOOL on the book's own ink.
class BookCover extends StatelessWidget {
  const BookCover({
    super.key,
    required this.entry,
    required this.width,
    this.statusDot = false,
    this.onDot,
  });

  final BookEntry entry;
  final double width;
  final bool statusDot;
  final VoidCallback? onDot;

  static const List<Color> _inks = <Color>[
    Color(0xFF6D4A3A),
    Color(0xFF35507A),
    Color(0xFF4F7A5A),
    Color(0xFF8A5A2B),
    Color(0xFF3D5D6B),
    Color(0xFF6A4A7A),
    Color(0xFF2F6F63),
  ];

  @override
  Widget build(BuildContext context) {
    final File? f = entry.coverFile;
    final double h = width * 4 / 3;
    const BorderRadius r = BorderRadius.only(
      topLeft: Radius.circular(3),
      bottomLeft: Radius.circular(3),
      topRight: Radius.circular(8),
      bottomRight: Radius.circular(8),
    );
    final Color ink =
        _inks[entry.id.codeUnits.fold<int>(0, (int a, int b) => a + b) %
            _inks.length];
    final Widget face = f != null && f.existsSync()
        ? Image.file(f, fit: BoxFit.cover, width: width, height: h)
        : Container(
            width: width,
            height: h,
            color: ink,
            padding: EdgeInsets.all(width * 0.1),
            alignment: Alignment.topLeft,
            child: Text(
              entry.title,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: display,
                color: const Color(0xFFF4EBDD),
                fontSize: width * 0.16,
                height: 1.25,
              ),
            ),
          );
    return SizedBox(
      width: width,
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: r,
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 6,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(borderRadius: r, child: face),
          ),
          if (statusDot)
            Positioned(
              left: 6,
              bottom: 6,
              child: GestureDetector(
                onTap: onDot,
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: StatusDot(status: entry.status),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 灰 = 未整理，朱红呼吸 = 整理中，朱红实心 = 已完成，琥珀 = 需要处理.
class StatusDot extends StatefulWidget {
  const StatusDot({super.key, required this.status, this.size = 9});

  final ProcessStatus status;
  final double size;

  @override
  State<StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController breathe = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.status.isRunning) breathe.repeat(reverse: true);
  }

  @override
  void dispose() {
    breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final ProcessStatus s = widget.status;
    final Color c = s.isError || s.isPaused
        ? t.amber
        : (s.isDone || s.isRunning ? t.zhu : t.ink3);
    final Widget dot = Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 1.5),
      ),
    );
    if (!s.isRunning) return dot;
    return FadeTransition(
      opacity: Tween<double>(begin: 0.35, end: 1).animate(breathe),
      child: dot,
    );
  }
}
