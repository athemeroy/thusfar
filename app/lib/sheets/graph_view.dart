import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:thusfar_core/thusfar_core.dart';

import '../ui/theme.dart';
import 'common.dart';
import 'person_sheet.dart';
import 'sheet_host.dart';

Color _hex(String c) => Color(int.parse('FF${c.substring(1)}', radix: 16));

/// Deterministic force layout for the people in [w] (at most [limit] of them).
Map<String, Offset> layoutGraph(World w, {int limit = 40, String? focus}) {
  final List<Json> ranked = w.ranked();
  final List<String> ids = <String>[
    for (final Json p in ranked.take(limit)) p['id']! as String,
  ];
  if (focus != null && !ids.contains(focus) && w.people.containsKey(focus)) {
    ids.add(focus);
  }
  final Map<String, Offset> pos = <String, Offset>{};
  final math.Random r = math.Random(7);
  for (int i = 0; i < ids.length; i++) {
    final double a = i * 2.399963;
    final double d = 0.15 + 0.35 * math.sqrt(i / math.max(1, ids.length));
    pos[ids[i]] = Offset(
      0.5 + d * math.cos(a) + r.nextDouble() * 0.01,
      0.5 + d * math.sin(a),
    );
  }
  final List<(String, String)> edges = <(String, String)>[
    for (final Json rel in w.rels)
      if (pos.containsKey(rel['a']) && pos.containsKey(rel['b']))
        (rel['a']! as String, rel['b']! as String),
  ];
  for (int step = 0; step < 220; step++) {
    final Map<String, Offset> force = <String, Offset>{
      for (final String id in ids) id: Offset.zero,
    };
    for (int i = 0; i < ids.length; i++) {
      for (int j = i + 1; j < ids.length; j++) {
        final Offset d = pos[ids[i]]! - pos[ids[j]]!;
        final double dist = math.max(0.02, d.distance);
        final Offset f = d / dist * (0.0016 / (dist * dist));
        force[ids[i]] = force[ids[i]]! + f;
        force[ids[j]] = force[ids[j]]! - f;
      }
    }
    for (final (String a, String b) in edges) {
      final Offset d = pos[b]! - pos[a]!;
      final double dist = math.max(0.01, d.distance);
      final Offset f = d / dist * ((dist - 0.2) * 0.05);
      force[a] = force[a]! + f;
      force[b] = force[b]! - f;
    }
    for (final String id in ids) {
      final Offset toCenter = (const Offset(0.5, 0.5) - pos[id]!) * 0.01;
      final Offset f = force[id]! + toCenter;
      final double cap = 0.03 * (1 - step / 220) + 0.002;
      final Offset step2 = f.distance > cap ? f / f.distance * cap : f;
      pos[id] = pos[id]! + step2;
    }
  }
  double minX = 1, minY = 1, maxX = 0, maxY = 0;
  for (final Offset o in pos.values) {
    minX = math.min(minX, o.dx);
    minY = math.min(minY, o.dy);
    maxX = math.max(maxX, o.dx);
    maxY = math.max(maxY, o.dy);
  }
  final double sx = math.max(0.001, maxX - minX);
  final double sy = math.max(0.001, maxY - minY);
  return <String, Offset>{
    for (final MapEntry<String, Offset> e in pos.entries)
      e.key: Offset(
        0.08 + 0.84 * (e.value.dx - minX) / sx,
        0.1 + 0.8 * (e.value.dy - minY) / sy,
      ),
  };
}

/// Relations as a picture: node size by importance, family ties in 朱.
class RelationGraph extends StatefulWidget {
  const RelationGraph({
    super.key,
    required this.world,
    this.focus,
    this.compact = false,
    required this.onTap,
    this.selected,
  });

  final World world;
  final String? focus;
  final bool compact;
  final ValueChanged<String> onTap;
  final String? selected;

  @override
  State<RelationGraph> createState() => _RelationGraphState();
}

class _RelationGraphState extends State<RelationGraph> {
  late Map<String, Offset> pos;

  @override
  void initState() {
    super.initState();
    pos = _layout();
  }

  @override
  void didUpdateWidget(RelationGraph old) {
    super.didUpdateWidget(old);
    if (old.world != widget.world) pos = _layout();
  }

  Map<String, Offset> _layout() {
    if (!widget.compact) return layoutGraph(widget.world, focus: widget.focus);
    // Compact: the focus person and their direct relations only.
    final String f = widget.focus!;
    final List<Json> rels = widget.world.relsOf(f);
    final List<String> ids = <String>[
      for (final Json r in rels.take(8)) r['other']! as String,
    ];
    final Map<String, Offset> out = <String, Offset>{f: const Offset(0.5, 0.5)};
    for (int i = 0; i < ids.length; i++) {
      final double a = -math.pi / 2 + i * 2 * math.pi / ids.length;
      out[ids[i]] = Offset(0.5 + 0.36 * math.cos(a), 0.5 + 0.36 * math.sin(a));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final Size size = Size(box.maxWidth, box.maxHeight);
        final String? sel = widget.selected ?? widget.focus;
        final Set<String> near = <String>{
          ?sel,
          if (sel != null)
            for (final Json r in widget.world.relsOf(sel))
              r['other']! as String,
        };
        final List<Widget> nodes = <Widget>[];
        for (final MapEntry<String, Offset> e in pos.entries) {
          final Json? p = widget.world.people[e.key];
          if (p == null) continue;
          final int imp = ((p['imp'] as num?) ?? 1).toInt();
          final double r = widget.compact
              ? (e.key == widget.focus ? 16 : 12)
              : 10 + imp * 3.0;
          final bool dim = sel != null && !near.contains(e.key);
          nodes.add(
            Positioned(
              left: e.value.dx * size.width - r,
              top: e.value.dy * size.height - r,
              child: GestureDetector(
                onTap: () => widget.onTap(e.key),
                child: Opacity(
                  opacity: dim ? 0.35 : 1,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Container(
                        width: r * 2,
                        height: r * 2,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: _hex(p['color']! as String),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: e.key == sel ? t.zhu : t.sheet,
                            width: e.key == sel ? 2.5 : 1.5,
                          ),
                        ),
                        child: Text(
                          initial('${p['name']}'),
                          style: TextStyle(
                            color: Colors.white,
                            fontFamily: display,
                            fontSize: r * 0.9,
                            height: 1,
                          ),
                        ),
                      ),
                      Text(
                        '${p['name']}',
                        style: TextStyle(
                          fontSize: widget.compact ? 10 : 11,
                          color: t.ink2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        return Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Positioned.fill(
              child: CustomPaint(
                painter: _Edges(
                  widget.world,
                  pos,
                  t,
                  sel,
                  widget.compact ? widget.focus : null,
                ),
              ),
            ),
            ...nodes,
          ],
        );
      },
    );
  }
}

class _Edges extends CustomPainter {
  _Edges(this.w, this.pos, this.t, this.sel, this.onlyFrom);

  final World w;
  final Map<String, Offset> pos;
  final Tokens t;
  final String? sel;
  final String? onlyFrom;

  @override
  void paint(Canvas canvas, Size size) {
    for (final Json r in w.rels) {
      final String a = r['a']! as String;
      final String b = r['b']! as String;
      if (onlyFrom != null && a != onlyFrom && b != onlyFrom) continue;
      final Offset? pa = pos[a];
      final Offset? pb = pos[b];
      if (pa == null || pb == null) continue;
      final bool family = (r['family'] ?? '') != '' && r['family'] != false;
      final bool lit = sel == null || a == sel || b == sel;
      final Paint paint = Paint()
        ..color = (family ? t.zhu : t.ink3).withValues(alpha: lit ? 0.8 : 0.15)
        ..strokeWidth = family ? 1.6 : 1
        ..style = PaintingStyle.stroke;
      canvas.drawLine(
        Offset(pa.dx * size.width, pa.dy * size.height),
        Offset(pb.dx * size.width, pb.dy * size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_Edges old) => true;
}

/// S10 关系图 inside the drawer, with the replay slider.
class GraphPage extends StatefulWidget {
  const GraphPage({super.key, required this.link, this.focus});

  final ReaderLink link;
  final String? focus;

  @override
  State<GraphPage> createState() => _GraphPageState();
}

class _GraphPageState extends State<GraphPage> {
  String? selected;
  double? replay;

  @override
  void initState() {
    super.initState();
    selected = widget.focus;
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final ReaderLink link = widget.link;
    final int cutoff = link.c.cutoff;
    final int at = replay == null ? cutoff : (replay! * cutoff).round();
    final World w = link.c.book.world(at);
    final Person? sel = selected == null ? null : w.person(selected!);
    final double height = MediaQuery.of(context).size.height * 0.56;
    return SheetPage(
      title: '关系图',
      tag: '截至第 ${link.pageNo(cutoff > 0 ? cutoff - 1 : 0)} 页',
      slivers: <Widget>[
        if (w.people.length <= 2)
          emptyState(context, w.people.isEmpty ? '读到这里还没有人物关系' : '人物还很少，先看列表吧')
        else
          SliverToBoxAdapter(
            child: SizedBox(
              height: height,
              child: InteractiveViewer(
                minScale: 0.6,
                maxScale: 4,
                boundaryMargin: const EdgeInsets.all(120),
                child: RelationGraph(
                  world: w,
                  selected: selected,
                  onTap: (String id) {
                    if (selected == id) {
                      SheetScope.of(
                        context,
                      ).state.push(PersonPage(link: link, id: id));
                    } else {
                      setState(() => selected = id);
                    }
                  },
                ),
              ),
            ),
          ),
        if (sel != null)
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: t.raised,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: t.rule),
              ),
              child: Row(
                children: <Widget>[
                  Avatar(
                    name: sel.name,
                    color: sel.raw['color']! as String,
                    size: 36,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          sel.name,
                          style: TextStyle(
                            fontFamily: display,
                            fontSize: 18,
                            color: t.ink,
                          ),
                        ),
                        if (sel.tagline.isNotEmpty)
                          Text(
                            sel.tagline,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: t.ink2),
                          ),
                      ],
                    ),
                  ),
                  Pill(
                    label: '打开人物卡',
                    dense: true,
                    onTap: () => SheetScope.of(
                      context,
                    ).state.push(PersonPage(link: link, id: sel.id)),
                  ),
                ],
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 20, 0),
            child: Row(
              children: <Widget>[
                IconButton(
                  icon: Icon(Icons.play_arrow_rounded, color: t.ink),
                  tooltip: '回放',
                  onPressed: _play,
                ),
                Expanded(
                  child: Slider(
                    value: replay ?? 1,
                    onChanged: (double v) => setState(() => replay = v),
                    activeColor: t.zhu,
                    inactiveColor: t.rule,
                  ),
                ),
                Text(
                  '第 ${link.pageNo(at > 0 ? at - 1 : 0)} 页',
                  style: TextStyle(
                    fontSize: 12,
                    color: t.ink3,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _play() async {
    for (int i = 0; i <= 40; i++) {
      if (!mounted) return;
      setState(() => replay = i / 40);
      await Future<void>.delayed(const Duration(milliseconds: 90));
    }
  }
}
