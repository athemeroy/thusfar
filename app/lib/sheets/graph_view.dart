import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    if (ids.length >= limit) ids.removeLast();
    ids.add(focus);
  }
  if (ids.length == 1) {
    return <String, Offset>{ids.single: const Offset(.5, .5)};
  }
  if (ids.length == 2) {
    return <String, Offset>{
      ids[0]: const Offset(.15, .5),
      ids[1]: const Offset(.85, .5),
    };
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

String relationLabel(World world, Json relation, {String? selected}) {
  final String a = world.person('${relation['a']}')?.name ?? '${relation['a']}';
  final String b = world.person('${relation['b']}')?.name ?? '${relation['b']}';
  final String ar = '${relation['a_is'] ?? ''}'.trim();
  final String br = '${relation['b_is'] ?? ''}'.trim();
  final String description = '${relation['desc'] ?? ''}'.trim();
  final List<String> lines = <String>[];
  if (selected == relation['a']) {
    if (br.isNotEmpty) lines.add('$b是$a的$br');
    if (ar.isNotEmpty && ar != br) lines.add('$a是$b的$ar');
  } else if (selected == relation['b']) {
    if (ar.isNotEmpty) lines.add('$a是$b的$ar');
    if (br.isNotEmpty && ar != br) lines.add('$b是$a的$br');
  } else if (ar.isNotEmpty && ar == br) {
    lines.add('$a与$b：$ar');
  } else {
    if (ar.isNotEmpty) lines.add('$a是$b的$ar');
    if (br.isNotEmpty) lines.add('$b是$a的$br');
  }
  if (lines.isEmpty) {
    lines.add('$a与$b：${description.isEmpty ? '已记录关系' : description}');
  }
  if (relation['status'] == 'ended') lines.add('已结束');
  return lines.join('\n');
}

/// Compact roles are separate from names so a long name cannot consume the
/// label's entire line budget before the relationship itself becomes visible.
List<({String id, String name, String role})> _relationRoles(
  World world,
  Json relation, {
  String? selected,
}) {
  final String a = '${relation['a']}', b = '${relation['b']}';
  final String ar = '${relation['a_is'] ?? ''}'.trim();
  final String br = '${relation['b_is'] ?? ''}'.trim();
  final List<({String id, String name, String role})> roles = [
    if (ar.isNotEmpty) (id: a, name: world.person(a)?.name ?? a, role: ar),
    if (br.isNotEmpty) (id: b, name: world.person(b)?.name ?? b, role: br),
  ];
  if (selected == a) {
    roles.sort(
      (left, right) => left.id == b
          ? -1
          : right.id == b
          ? 1
          : 0,
    );
  }
  if (roles.isEmpty) {
    final String description = '${relation['desc'] ?? ''}'.trim();
    roles.add((
      id: 'pair',
      name: '${world.person(a)?.name ?? a} · ${world.person(b)?.name ?? b}',
      role: description.isEmpty ? '已记录关系' : description,
    ));
  }
  return roles;
}

/// The short text on an edge: who the other person is to [selected]
/// ("加害者"), not both roles and both names. Without a selection, both roles.
String edgeRole(World world, Json relation, {String? selected}) {
  final String a = '${relation['a']}', b = '${relation['b']}';
  final String ar = '${relation['a_is'] ?? ''}'.trim();
  final String br = '${relation['b_is'] ?? ''}'.trim();
  String role;
  if (selected == a) {
    role = br;
  } else if (selected == b) {
    role = ar;
  } else {
    role = ar == br || br.isEmpty ? ar : (ar.isEmpty ? br : '$ar · $br');
  }
  if (role.isEmpty) {
    final String description = '${relation['desc'] ?? ''}'.trim();
    role = description.isEmpty
        ? '有关系'
        : description.characters.take(8).toString() +
              (description.characters.length > 8 ? '…' : '');
  }
  return role;
}

class RelationDetailPage extends StatelessWidget {
  const RelationDetailPage({
    super.key,
    required this.world,
    required this.relation,
    this.asOf,
  });
  final World world;
  final Json relation;
  final String? asOf;

  @override
  Widget build(BuildContext context) => SheetPage(
    title: '关系详情',
    tag: asOf,
    slivers: <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 24),
          child: _RelationDetails(world: world, relation: relation),
        ),
      ),
    ],
  );
}

class _RelationDetails extends StatelessWidget {
  const _RelationDetails({required this.world, required this.relation});
  final World world;
  final Json relation;

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final String a =
        world.person('${relation['a']}')?.name ?? '${relation['a']}';
    final String b =
        world.person('${relation['b']}')?.name ?? '${relation['b']}';
    final String ar = '${relation['a_is'] ?? ''}'.trim();
    final String br = '${relation['b_is'] ?? ''}'.trim();
    final String description = '${relation['desc'] ?? ''}'.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '$a · $b',
          style: TextStyle(fontFamily: display, fontSize: 22, color: t.ink),
        ),
        const SizedBox(height: 16),
        SelectableText(
          ar.isEmpty ? '$a相对于$b的身份：尚未记录' : '$a是$b的$ar',
          style: TextStyle(color: t.ink, fontSize: 16, height: 1.6),
        ),
        const SizedBox(height: 8),
        SelectableText(
          br.isEmpty ? '$b相对于$a的身份：尚未记录' : '$b是$a的$br',
          style: TextStyle(color: t.ink, fontSize: 16, height: 1.6),
        ),
        const SizedBox(height: 16),
        Text(
          relation['status'] == 'ended' ? '这段关系截至此页已结束。' : '以上是截至此页记录的关系。',
          style: TextStyle(
            color: relation['status'] == 'ended' ? t.amber : t.ink2,
            height: 1.5,
          ),
        ),
        if (description.isNotEmpty) ...<Widget>[
          const SizedBox(height: 20),
          Text('关系说明', style: TextStyle(color: t.ink2, fontSize: 13)),
          const SizedBox(height: 8),
          SelectableText(
            description,
            style: TextStyle(color: t.ink, fontSize: 16, height: 1.7),
          ),
        ],
      ],
    );
  }
}

/// The label widgets carry meaning, accessibility, and full-detail interaction.
/// Painted lines only connect the centered person circles.
class RelationGraph extends StatefulWidget {
  const RelationGraph({
    super.key,
    required this.world,
    this.focus,
    this.compact = false,
    required this.onTap,
    this.selected,
    this.onRelationTap,
    this.onLayoutReady,
    this.showLabels = true,
  });
  final World world;
  final String? focus;
  final bool compact;
  final bool showLabels;
  final ValueChanged<String> onTap;
  final String? selected;
  final ValueChanged<Json>? onRelationTap;
  final void Function(Rect label, Rect a, Rect b)? onLayoutReady;

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
    if (old.world != widget.world ||
        old.focus != widget.focus ||
        old.compact != widget.compact) {
      pos = _layout();
    }
  }

  Map<String, Offset> _layout() {
    if (!widget.compact || widget.focus == null) {
      return layoutGraph(widget.world, focus: widget.focus);
    }
    final String focus = widget.focus!;
    final List<String> ids = widget.world
        .relsOf(focus)
        .map((Json relation) => relation['other']! as String)
        .toSet()
        .toList();
    final Map<String, Offset> out = <String, Offset>{
      focus: const Offset(.5, .5),
    };
    for (int i = 0; i < ids.length; i++) {
      final double angle = -math.pi / 2 + i * 2 * math.pi / ids.length;
      out[ids[i]] = Offset(
        .5 + .35 * math.cos(angle),
        .5 + .35 * math.sin(angle),
      );
    }
    return out;
  }

  void _details(BuildContext context, Json relation) {
    if (widget.onRelationTap != null) {
      widget.onRelationTap!(relation);
      return;
    }
    final SheetScope? sheet = context
        .dependOnInheritedWidgetOfExactType<SheetScope>();
    if (sheet != null) {
      sheet.state.push(
        RelationDetailPage(world: widget.world, relation: relation),
      );
    } else {
      showDialog<void>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('关系详情'),
          content: SingleChildScrollView(
            child: _RelationDetails(world: widget.world, relation: relation),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                HapticFeedback.lightImpact();
                Navigator.of(context).pop();
              },
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final Size size = Size(box.maxWidth, box.maxHeight);
        final String? candidate = widget.selected ?? widget.focus;
        final String? selected = widget.world.people.containsKey(candidate)
            ? candidate
            : null;
        final Set<String> near = <String>{
          ?selected,
          if (selected != null)
            for (final Json r in widget.world.relsOf(selected))
              r['other']! as String,
        };
        final double textScale =
            MediaQuery.textScalerOf(context).scale(12) / 12;
        // Large relationship text needs its own vertical band in a sparse
        // graph. Keep the person circles and their two-line names below it.
        final bool sparseLargeText = pos.length <= 2 && textScale > 1.2;
        final double marginX = math.min(64, size.width * .18);
        final double marginY = math.min(62, size.height * .24);
        // The unlabelled card graph is short and wide: spread the ring as an
        // ellipse over the whole box, leaving just room for circles and names.
        final bool card = widget.compact && !widget.showLabels;
        final double rx = math.max(0, size.width / 2 - 56);
        final double ry = math.max(0, size.height / 2 - 34 * textScale);
        final Map<String, Offset> centers = <String, Offset>{
          for (final MapEntry<String, Offset> entry in pos.entries)
            entry.key: card
                ? Offset(
                    size.width / 2 + (entry.value.dx - .5) / .35 * rx,
                    size.height / 2 - 6 + (entry.value.dy - .5) / .35 * ry,
                  )
                : Offset(
                    marginX +
                        entry.value.dx * math.max(0, size.width - marginX * 2),
                    sparseLargeText
                        ? size.height - math.max(72, 60 * textScale)
                        : marginY +
                              entry.value.dy *
                                  math.max(0, size.height - marginY * 2),
                  ),
        };
        final List<Json> relations = <Json>[
          for (final Json relation in widget.world.rels)
            if (centers.containsKey(relation['a']) &&
                centers.containsKey(relation['b']) &&
                (!widget.compact ||
                    widget.focus == null ||
                    relation['a'] == widget.focus ||
                    relation['b'] == widget.focus))
              relation,
        ];
        final double nodeWidth = math.min(
          size.width,
          100 * math.min(textScale, 1.5),
        );
        final Map<String, Rect> nodeBounds = <String, Rect>{
          for (final MapEntry<String, Offset> entry in centers.entries)
            entry.key: Rect.fromLTRB(
              entry.value.dx - nodeWidth / 2,
              entry.value.dy - 27,
              entry.value.dx + nodeWidth / 2,
              entry.value.dy + 58 * textScale,
            ),
        };
        final List<Rect> occupied = nodeBounds.values.toList();
        final List<Widget> labels = <Widget>[];
        final List<(Offset, Offset)> leaders = <(Offset, Offset)>[];
        ({Rect label, Rect a, Rect b})? preferred;
        double preferredPriority = -1;
        final String? font = Theme.of(context).textTheme.bodyMedium?.fontFamily;
        for (int index = 0; index < relations.length; index++) {
          final Json relation = relations[index];
          final Offset a = centers[relation['a']]!, b = centers[relation['b']]!;
          final bool highlighted =
              selected == null ||
              relation['a'] == selected ||
              relation['b'] == selected;
          // Only the selected person's own relations carry a label; the rest
          // are context lines. The small card graph shows no labels at all.
          if (!widget.showLabels || !highlighted) {
            leaders.add((a, a));
            continue;
          }
          final String label = relationLabel(
            widget.world,
            relation,
            selected: selected,
          );
          final bool ended = relation['status'] == 'ended';
          final String role = edgeRole(
            widget.world,
            relation,
            selected: selected,
          );
          final TextStyle roleStyle = TextStyle(
            inherit: false,
            fontFamily: font,
            fontSize: 11.5,
            height: 1.2,
            fontWeight: FontWeight.w600,
            color: ended ? t.amber : t.ink,
          );
          final TextPainter measure = TextPainter(
            text: TextSpan(text: role, style: roleStyle),
            textDirection: TextDirection.ltr,
            textScaler: MediaQuery.textScalerOf(context),
            maxLines: 1,
            ellipsis: '…',
          )..layout(maxWidth: 112 * textScale.clamp(1, 1.8));
          final Size pill = Size(measure.width + 18, measure.height + 8);
          measure.dispose();
          // Sit on the spoke nearer the other person, so labels fan out
          // around the selected node instead of piling up at its centre.
          final String? near = relation['a'] == selected
              ? '${relation['b']}'
              : relation['b'] == selected
              ? '${relation['a']}'
              : null;
          final Rect rect = near == null
              ? _placeLabel(a, b, pill, size, occupied)
              : _placeLabel(
                  centers[selected]!,
                  centers[near]!,
                  pill,
                  size,
                  occupied,
                  fractions: const <double>[.62, .52, .72, .45, .8],
                );
          final double priority =
              ((widget.world.people[relation['a']]?['imp'] as num?) ?? 1)
                  .toDouble() +
              ((widget.world.people[relation['b']]?['imp'] as num?) ?? 1)
                  .toDouble();
          if (priority > preferredPriority) {
            preferredPriority = priority;
            preferred = (
              label: rect,
              a: nodeBounds[relation['a']]!,
              b: nodeBounds[relation['b']]!,
            );
          }
          occupied.add(rect.inflate(3));
          leaders.add((_nearestOnSegment(a, b, rect.center), rect.center));
          labels.add(
            Positioned.fromRect(
              rect: rect,
              child: Semantics(
                button: true,
                label: '$label，查看关系详情',
                child: Material(
                  color: t.sheet,
                  shape: StadiumBorder(
                    side: BorderSide(color: ended ? t.amber : t.ink3),
                  ),
                  child: InkWell(
                    key: ValueKey<String>('relation-label-$index'),
                    customBorder: const StadiumBorder(),
                    onTap: () {
                      HapticFeedback.selectionClick();
                      _details(context, relation);
                    },
                    child: Center(
                      child: ExcludeSemantics(
                        child: Text(
                          role,
                          key: ValueKey<String>('relation-role-$index'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: roleStyle,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        if (preferred != null && widget.onLayoutReady != null) {
          final region = preferred;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              widget.onLayoutReady?.call(region.label, region.a, region.b);
            }
          });
        }
        final List<Widget> nodes = <Widget>[];
        for (final MapEntry<String, Offset> entry in centers.entries) {
          final Json? person = widget.world.people[entry.key];
          if (person == null) continue;
          final double radius = widget.compact
              ? (entry.key == widget.focus ? 16 : 12)
              : 13 +
                    (((person['imp'] as num?) ?? 1).toDouble().clamp(1, 5)) * 2;
          final bool dim = selected != null && !near.contains(entry.key);
          nodes.add(
            Positioned(
              left: entry.value.dx - nodeWidth / 2,
              top: entry.value.dy - radius,
              width: nodeWidth,
              child: Semantics(
                button: true,
                selected: entry.key == selected,
                label: '${person['name']}，选择人物',
                child: Tooltip(
                  message: '${person['name']}',
                  child: GestureDetector(
                    key: ValueKey<String>('graph-person-${entry.key}'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      widget.onTap(entry.key);
                    },
                    child: Opacity(
                      opacity: dim ? .5 : 1,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Container(
                            key: ValueKey<String>('graph-circle-${entry.key}'),
                            width: radius * 2,
                            height: radius * 2,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: _hex(person['color']! as String),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: entry.key == selected ? t.zhu : t.sheet,
                                width: entry.key == selected ? 2.5 : 1.5,
                              ),
                            ),
                            child: ExcludeSemantics(
                              child: Text(
                                initial('${person['name']}'),
                                textScaler: TextScaler.noScaling,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontFamily: display,
                                  fontSize: radius * .9,
                                  height: 1,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 3),
                          ExcludeSemantics(
                            child: Text(
                              '${person['name']}',
                              maxLines: widget.compact ? 1 : 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: widget.compact ? 10 : 12,
                                height: 1.2,
                                color: t.ink,
                                // Lines pass under the name, not through it.
                                background: Paint()..color = t.sheet,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: <Widget>[
            Positioned.fill(
              child: CustomPaint(
                painter: _Edges(relations, centers, leaders, t, selected),
              ),
            ),
            ...nodes,
            ...labels,
          ],
        );
      },
    );
  }
}

Offset _nearestOnSegment(Offset a, Offset b, Offset p) {
  final Offset ab = b - a;
  final double length = ab.distanceSquared;
  if (length == 0) return a;
  final double t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / length).clamp(
    0,
    1,
  );
  return a + ab * t;
}

Rect _placeLabel(
  Offset a,
  Offset b,
  Size label,
  Size bounds,
  List<Rect> occupied, {
  List<double> fractions = const <double>[.5, .35, .65, .2, .8],
}) {
  final Offset direction = b - a;
  final double distance = math.max(1, direction.distance);
  final Offset normal = Offset(-direction.dy, direction.dx) / distance;
  Rect? best;
  double bestScore = double.infinity;
  for (final double fraction in fractions) {
    for (final double shift in <double>[
      0,
      -16,
      16,
      -32,
      32,
      -56,
      56,
      -88,
      88,
    ]) {
      final Offset center = Offset.lerp(a, b, fraction)! + normal * shift;
      final Rect rect = Rect.fromLTWH(
        (center.dx - label.width / 2).clamp(
          4,
          math.max(4, bounds.width - label.width - 4),
        ),
        (center.dy - label.height / 2).clamp(
          4,
          math.max(4, bounds.height - label.height - 4),
        ),
        label.width,
        label.height,
      );
      double score = shift.abs() + (fraction - .5).abs() * 30;
      for (final Rect taken in occupied) {
        if (rect.overlaps(taken)) {
          final Rect overlap = rect.intersect(taken);
          score += overlap.width * overlap.height * 10;
        }
      }
      if (score < bestScore) {
        bestScore = score;
        best = rect;
      }
    }
  }
  // Dense hubs can exhaust the small band around an edge even though the
  // scrollable canvas still has room. Search the full canvas before accepting
  // an overlap; the leader line keeps a displaced label attached to its edge.
  if (best != null && occupied.any(best.overlaps)) {
    final double maxX = math.max(4, bounds.width - label.width - 4);
    final double maxY = math.max(4, bounds.height - label.height - 4);
    final List<double> xs = [for (double x = 4; x < maxX; x += 24) x, maxX];
    final List<double> ys = [for (double y = 4; y < maxY; y += 24) y, maxY];
    final Offset midpoint = Offset.lerp(a, b, .5)!;
    final List<Rect> candidates =
        [
          for (final double y in ys)
            for (final double x in xs)
              Rect.fromLTWH(x, y, label.width, label.height),
        ]..sort(
          (left, right) => (left.center - midpoint).distanceSquared.compareTo(
            (right.center - midpoint).distanceSquared,
          ),
        );
    for (final Rect candidate in candidates) {
      if (!occupied.any(candidate.overlaps)) return candidate;
    }
  }
  return best!;
}

class _Edges extends CustomPainter {
  _Edges(
    this.relations,
    this.centers,
    this.leaders,
    this.tokens,
    this.selected,
  );
  final List<Json> relations;
  final Map<String, Offset> centers;
  final List<(Offset, Offset)> leaders;
  final Tokens tokens;
  final String? selected;

  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < relations.length; i++) {
      final Json relation = relations[i];
      final Offset a = centers[relation['a']]!, b = centers[relation['b']]!;
      final bool lit =
          selected == null ||
          relation['a'] == selected ||
          relation['b'] == selected;
      final bool ended = relation['status'] == 'ended';
      final bool family =
          relation['family'] != null &&
          relation['family'] != '' &&
          relation['family'] != false;
      final Paint paint = Paint()
        ..color =
            (ended
                    ? tokens.amber
                    : family
                    ? tokens.zhu
                    : tokens.ink3)
                .withValues(alpha: lit ? .7 : .22)
        ..strokeWidth = lit ? 1.6 : 1;
      if (ended) {
        final Offset vector = b - a;
        final double distance = vector.distance;
        if (distance > 0) {
          for (double at = 0; at < distance; at += 10) {
            canvas.drawLine(
              a + vector * (at / distance),
              a + vector * (math.min(at + 6, distance) / distance),
              paint,
            );
          }
        }
      } else {
        canvas.drawLine(a, b, paint);
      }
      if ((leaders[i].$2 - leaders[i].$1).distance > 12) {
        canvas.drawLine(leaders[i].$1, leaders[i].$2, paint..strokeWidth = .8);
      }
    }
  }

  @override
  bool shouldRepaint(_Edges old) => true;
}

class GraphPage extends StatefulWidget {
  GraphPage({super.key, required this.link, this.focus});
  final ReaderLink link;
  final String? focus;

  /// The sheet rebuilds only its top page, so this page's State is recreated
  /// after Back from a person card. The widget itself stays in the sheet's
  /// stack; keep the reader's focus and view on it.
  final _GraphMemory _memory = _GraphMemory();
  @override
  State<GraphPage> createState() => _GraphPageState();
}

class _SparseRelationshipCard extends StatelessWidget {
  const _SparseRelationshipCard({
    required this.world,
    required this.relation,
    required this.index,
    required this.selected,
    required this.onTap,
  });

  final World world;
  final Json relation;
  final int index;
  final String? selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final List<({String id, String name, String role})> roles = _relationRoles(
      world,
      relation,
      selected: selected,
    );
    final String label = relationLabel(world, relation, selected: selected);
    final String description = '${relation['desc'] ?? ''}'.trim();
    final bool ended = relation['status'] == 'ended';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Semantics(
        button: true,
        label: '$label，查看关系详情',
        child: Material(
          color: t.paper,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            key: ValueKey<String>('relation-card-$index'),
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              HapticFeedback.lightImpact();
              onTap();
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border.all(color: ended ? t.amber : t.rule),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (int i = 0; i < roles.length; i++) ...<Widget>[
                    if (i > 0) const SizedBox(height: 10),
                    Text(
                      roles[i].name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: t.ink,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      roles[i].role,
                      style: TextStyle(color: t.ink2, height: 1.35),
                    ),
                  ],
                  if (description.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: t.ink2,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                  if (ended) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      '已结束',
                      style: TextStyle(
                        color: t.amber,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      Text('查看关系详情', style: TextStyle(color: t.qing)),
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_right, size: 18, color: t.qing),
                    ],
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

class _GraphMemory {
  bool used = false;
  String? selected;
  Matrix4? view;
}

class _GraphPageState extends State<GraphPage> {
  String? selected;
  double? replay;
  Timer? _playback;
  final TransformationController _view = TransformationController();
  int _lastCutoff = 0;
  Size _viewport = Size.zero;
  Size _canvas = Size.zero;
  Offset? _preferredCenter;
  bool _needsInitialView = true;
  bool _requestedExpansion = false;
  bool _restoredView = false;

  @override
  void initState() {
    super.initState();
    final _GraphMemory memory = widget._memory;
    selected = memory.used ? memory.selected : widget.focus;
    if (memory.view != null) {
      _view.value = memory.view!;
      _restoredView = true;
    }
    memory.used = true;
    _lastCutoff = widget.link.c.cutoff;
    widget.link.c.addListener(_readerChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_requestedExpansion) return;
    _requestedExpansion = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) SheetScope.of(context).state.expand();
    });
  }

  @override
  void dispose() {
    widget.link.c.removeListener(_readerChanged);
    widget._memory
      ..selected = selected
      ..view = _view.value.clone();
    _playback?.cancel();
    _view.dispose();
    super.dispose();
  }

  void _readerChanged() {
    _stop();
    if (!mounted) return;
    setState(() {
      if (_lastCutoff != widget.link.c.cutoff) replay = null;
      _lastCutoff = widget.link.c.cutoff;
    });
  }

  void _stop() {
    _playback?.cancel();
    _playback = null;
  }

  void _play() {
    if (_playback != null) {
      setState(_stop);
      return;
    }
    if (replay == null || replay! >= 1) setState(() => replay = 0);
    _playback = Timer.periodic(const Duration(milliseconds: 90), (_) {
      if (!mounted) {
        _stop();
        return;
      }
      setState(() {
        replay = math.min(1, (replay ?? 0) + .025);
        if (replay! >= 1) _stop();
      });
    });
    setState(() {});
  }

  void _resetView() {
    final Offset center = _preferredCenter ?? _canvas.center(Offset.zero);
    _view.value = Matrix4.identity()
      ..setTranslationRaw(
        _viewport.width / 2 - center.dx,
        _viewport.height / 2 - center.dy,
        0,
      );
  }

  /// The draggable reader sheet and its vertical CustomScrollView both sit
  /// above the graph. Claim a vertical drag that starts on the canvas so it
  /// pans the graph instead of scrolling or collapsing that outer drawer.
  void _panVertically(DragUpdateDetails details) {
    if (_viewport.isEmpty || _canvas.isEmpty) return;
    final Matrix4 next = _view.value.clone();
    final double scale = next.getMaxScaleOnAxis();
    final double minY = math.min(0, _viewport.height - _canvas.height * scale);
    final double currentY = next.storage[13];
    final double nextY = (currentY + details.delta.dy)
        .clamp(minY, 0)
        .toDouble();
    if (nextY == currentY) return;
    next.storage[13] = nextY;
    _view.value = next;
  }

  void _openRelation(
    BuildContext context,
    World world,
    Json relation,
    String asOf,
  ) {
    HapticFeedback.lightImpact();
    setState(_stop);
    SheetScope.of(context).state.push(
      RelationDetailPage(world: world, relation: relation, asOf: asOf),
    );
  }

  /// The focused person sits at the canvas centre, with their relations on a
  /// ring around them; start (and reset) with that person in the middle.
  void _layoutReady(Rect label, Rect a, Rect b) {
    _preferredCenter = null;
    if (_needsInitialView) {
      _needsInitialView = false;
      if (_restoredView) {
        _restoredView = false;
      } else {
        _resetView();
      }
    }
  }

  void _zoom(double factor) {
    final Matrix4 current = _view.value;
    final double oldScale = current.getMaxScaleOnAxis();
    final double scale = (oldScale * factor).clamp(.3, 4);
    final double ratio = scale / oldScale;
    final Offset center = _viewport.center(Offset.zero);
    _view.value = Matrix4.diagonal3Values(scale, scale, scale)
      ..setTranslationRaw(
        center.dx - (center.dx - current.storage[12]) * ratio,
        center.dy - (center.dy - current.storage[13]) * ratio,
        0,
      );
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final ReaderLink link = widget.link;
    final int cutoff = link.c.cutoff;
    final int at = replay == null ? cutoff : (replay! * cutoff).round();
    final World world = link.c.book.world(at);
    final Person? person = selected == null ? null : world.person(selected!);
    final String? graphFocus =
        selected ??
        widget.focus ??
        (world.ranked().isEmpty ? null : world.ranked().first['id'] as String);
    final String asOf = '截至第 ${link.pageNo(at > 0 ? at - 1 : 0)} 页';
    final double height = (MediaQuery.sizeOf(context).height * .5).clamp(
      260,
      540,
    );
    return SheetPage(
      title: '关系图',
      tag: asOf,
      slivers: <Widget>[
        if (world.people.isEmpty)
          emptyState(context, '读到这里还没有人物关系')
        else if (world.people.length <= 2) ...<Widget>[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                world.rels.isEmpty
                    ? '目前只有 ${world.people.length} 位人物，还没有整理出他们之间的关系。'
                    : '人物较少，关系按列表显示。',
                style: TextStyle(color: t.ink3, fontSize: 12, height: 1.4),
              ),
            ),
          ),
          if (world.rels.isEmpty)
            emptyState(context, '截至此页尚未记录人物关系')
          else
            SliverList.builder(
              itemCount: world.rels.length,
              itemBuilder: (BuildContext context, int index) =>
                  _SparseRelationshipCard(
                    world: world,
                    relation: world.rels[index],
                    index: index,
                    selected: selected ?? graphFocus,
                    onTap: () =>
                        _openRelation(context, world, world.rels[index], asOf),
                  ),
            ),
        ] else ...<Widget>[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Tooltip(
                    message: '图中展示重点人物的直接关系；点击其他人物可切换重点。人物卡可查看完整关系列表。',
                    child: Text(
                      graphFocus == null
                          ? '点关系文字看详情'
                          : '人物关系 · ${world.person(graphFocus)?.name ?? '人物'}',
                      style: TextStyle(
                        color: graphFocus == null ? t.ink2 : t.qing,
                        fontSize: 12,
                        fontWeight: graphFocus == null
                            ? FontWeight.normal
                            : FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '缩小关系图',
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      _zoom(1 / 1.3);
                    },
                    icon: const Icon(Icons.remove),
                  ),
                  IconButton(
                    tooltip: '放大关系图',
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      _zoom(1.3);
                    },
                    icon: const Icon(Icons.add),
                  ),
                  IconButton(
                    tooltip: '重置视图',
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      _resetView();
                    },
                    icon: const Icon(Icons.center_focus_strong),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints box) {
                final double panelHeight = height;
                final Size viewport = Size(box.maxWidth, panelHeight);
                final List<Json> focusedRelations = graphFocus == null
                    ? world.rels
                    : world.rels
                          .where(
                            (Json relation) =>
                                relation['a'] == graphFocus ||
                                relation['b'] == graphFocus,
                          )
                          .toList();
                final int visible = graphFocus == null
                    ? math.min(40, world.people.length)
                    : 1 +
                          focusedRelations
                              .map(
                                (Json relation) => relation['a'] == graphFocus
                                    ? relation['b'] as String
                                    : relation['a'] as String,
                              )
                              .toSet()
                              .length;
                final double expansion = visible <= 6
                    ? 0
                    : math.sqrt(math.max(visible, focusedRelations.length)) *
                          190 *
                          (MediaQuery.textScalerOf(context).scale(12) / 12)
                              .clamp(1, 1.8);
                // Keep the relationship labels and nodes inside a pannable
                // canvas even when the focused graph is small. The old
                // viewport-sized child plus a very large boundary margin let
                // one drag move every edge off-screen.
                const double panGutter = 160;
                final Size canvas = Size(
                  math.max(box.maxWidth + panGutter, expansion),
                  math.max(panelHeight + panGutter, expansion),
                );
                if (_canvas != canvas || _viewport != viewport) {
                  _canvas = canvas;
                  _viewport = viewport;
                  _needsInitialView = true;
                  _preferredCenter = null;
                  if (world.rels.isEmpty) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _resetView();
                    });
                  }
                }
                return SizedBox(
                  height: panelHeight,
                  child: InteractiveViewer(
                    key: const ValueKey<String>('graph-viewport'),
                    transformationController: _view,
                    constrained: false,
                    minScale: .3,
                    maxScale: 4,
                    boundaryMargin: EdgeInsets.zero,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: _panVertically,
                      child: SizedBox(
                        width: canvas.width,
                        height: canvas.height,
                        child: RelationGraph(
                          world: world,
                          focus: graphFocus,
                          compact: graphFocus != null,
                          selected: selected,
                          onLayoutReady: _layoutReady,
                          onTap: (String id) {
                            HapticFeedback.selectionClick();
                            setState(() => selected = id);
                          },
                          onRelationTap: (Json relation) {
                            _openRelation(context, world, relation, asOf);
                          },
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text(
                world.rels.isEmpty
                    ? '截至此页尚未记录关系，点人物可看资料。'
                    : '点其他人物切换关系焦点；人物卡中可看完整关系列表。虚线和“已结束”表示关系已经结束。',
                style: TextStyle(color: t.ink3, fontSize: 12, height: 1.5),
              ),
            ),
          ),
        ],
        if (person != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    person.name,
                    style: TextStyle(
                      fontFamily: display,
                      fontSize: 20,
                      color: t.ink,
                    ),
                  ),
                  if (person.tagline.isNotEmpty)
                    Text(person.tagline, style: TextStyle(color: t.ink2)),
                  const SizedBox(height: 8),
                  Pill(
                    label: at < cutoff ? '回到当前页看人物卡' : '打开人物卡',
                    onTap: () {
                      _stop();
                      setState(() => replay = null);
                      SheetScope.of(
                        context,
                      ).state.push(PersonPage(link: link, id: person.id));
                    },
                  ),
                ],
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 12, 16, 0),
            child: Row(
              children: <Widget>[
                IconButton(
                  key: const ValueKey<String>('graph-play'),
                  tooltip: _playback == null ? '播放回放' : '暂停回放',
                  icon: Icon(
                    _playback == null
                        ? Icons.play_arrow_rounded
                        : Icons.pause_rounded,
                  ),
                  onPressed: () {
                    HapticFeedback.lightImpact();
                    _play();
                  },
                ),
                Expanded(
                  child: Slider(
                    key: const ValueKey<String>('graph-replay'),
                    value: replay ?? 1,
                    semanticFormatterCallback: (double value) {
                      final int position = (value * cutoff).round().clamp(
                        0,
                        cutoff,
                      );
                      return '第 ${link.pageNo(position > 0 ? position - 1 : 0)} 页';
                    },
                    onChanged: (double value) {
                      final int prevPage = link.pageNo(at > 0 ? at - 1 : 0);
                      final int newAt = (value * cutoff).round();
                      final int newPage = link.pageNo(newAt > 0 ? newAt - 1 : 0);
                      if (newPage != prevPage) {
                        HapticFeedback.selectionClick();
                      }
                      setState(() {
                        _stop();
                        replay = value;
                      });
                    },
                    activeColor: t.zhu,
                    inactiveColor: t.rule,
                  ),
                ),
                Text(
                  '第 ${link.pageNo(at > 0 ? at - 1 : 0)} 页',
                  style: TextStyle(
                    color: t.ink2,
                    fontSize: 12,
                    fontFeatures: const <FontFeature>[
                      FontFeature.tabularFigures(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (replay != null)
          SliverToBoxAdapter(
            child: TextButton(
              onPressed: () {
                HapticFeedback.lightImpact();
                setState(() {
                  _stop();
                  replay = null;
                });
              },
              child: const Text('回到当前页'),
            ),
          ),
      ],
    );
  }
}
