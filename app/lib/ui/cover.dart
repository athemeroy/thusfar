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
    final Tokens t = context.tk;
    const BorderRadius r = BorderRadius.only(
      topLeft: Radius.circular(3),
      bottomLeft: Radius.circular(3),
      topRight: Radius.circular(8),
      bottomRight: Radius.circular(8),
    );
    final Color ink =
        _inks[entry.id.codeUnits.fold<int>(0, (int a, int b) => a + b) %
            _inks.length];
    final Widget generated = _buildGeneratedFace(width, h, ink);
    final Widget face = f != null && f.existsSync()
        ? Image.file(
            f,
            fit: BoxFit.cover,
            width: width,
            height: h,
            errorBuilder: (_, _, _) => generated,
          )
        : generated;
    return SizedBox(
      width: width,
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: r,
              border: Border.all(color: t.sheet.withValues(alpha: .72)),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.14),
                  blurRadius: 8,
                  offset: const Offset(1, 3),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.06),
                  blurRadius: 2,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: r,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  face,
                  // Spine curvature gradient
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: (width * 0.07).clamp(4.0, 9.0),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: <Color>[
                            Colors.black.withValues(alpha: 0.22),
                            Colors.black.withValues(alpha: 0.04),
                            Colors.white.withValues(alpha: 0.10),
                            Colors.transparent,
                          ],
                          stops: const <double>[0.0, 0.35, 0.65, 1.0],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
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

  Widget _buildGeneratedFace(double width, double h, Color ink) {
    return Container(
      width: width,
      height: h,
      color: ink,
      padding: EdgeInsets.all(width * 0.1),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (width > 108)
            Align(
              alignment: Alignment.topRight,
              child: Container(
                width: width * .25,
                height: width * .25,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFFF4EBDD).withValues(alpha: .18),
                    width: width > 88 ? 1.2 : .7,
                  ),
                ),
                child: Icon(
                  Icons.auto_stories_outlined,
                  size: width * .13,
                  color: const Color(0xFFF4EBDD).withValues(alpha: .42),
                ),
              ),
            ),
          Align(
            alignment: Alignment.topLeft,
            child: Container(
              width: width > 78 ? 2 : 1,
              height: h,
              color: Colors.black.withValues(alpha: .14),
            ),
          ),
          // With the status dot at its left end, this rule read as a
          // reading-progress bar stuck at 0; keep it only without one.
          if (!statusDot)
            Align(
              alignment: Alignment.bottomLeft,
              child: Container(
                height: width > 78 ? 1 : .6,
                width: width * .62,
                color: const Color(0xFFF4EBDD).withValues(alpha: .52),
              ),
            ),
          Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: EdgeInsets.only(
                top: width > 108 ? width * .28 : 0,
              ),
              child: Text(
                entry.title,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: display,
                  color: const Color(0xFFF4EBDD),
                  fontSize: width * .16,
                  height: 1.25,
                  shadows: const <Shadow>[
                    Shadow(color: Color(0x33000000), blurRadius: 3),
                  ],
                ),
              ),
            ),
          ),
          if (width > 115)
            Positioned(
              left: width * .1,
              bottom: width * .12,
              child: Text(
                '页 读 · ${entry.author.isEmpty ? '藏书' : entry.author}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: const Color(0xFFF4EBDD).withValues(alpha: .7),
                  fontSize: (width * .065).clamp(8, 10),
                  letterSpacing: .6,
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
  late final Animation<double> curved = CurvedAnimation(
    parent: breathe,
    curve: Curves.easeInOut,
  );

  @override
  void initState() {
    super.initState();
    if (widget.status.isRunning) breathe.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.status.isRunning != oldWidget.status.isRunning) {
      if (widget.status.isRunning) {
        breathe.repeat(reverse: true);
      } else {
        breathe.stop();
        breathe.value = 1.0;
      }
    }
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
        border: Border.all(color: t.sheet, width: 1.5),
        boxShadow: s.isRunning
            ? <BoxShadow>[
                BoxShadow(
                  color: t.zhu.withValues(alpha: 0.35),
                  blurRadius: 4,
                  spreadRadius: 0.5,
                ),
              ]
            : null,
      ),
    );
    if (!s.isRunning) return dot;
    return ScaleTransition(
      scale: Tween<double>(begin: 0.88, end: 1.15).animate(curved),
      child: FadeTransition(
        opacity: Tween<double>(begin: 0.45, end: 1.0).animate(curved),
        child: dot,
      ),
    );
  }
}
