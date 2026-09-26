import 'dart:async';
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

({
  double width,
  double height,
  TextStyle roleStyle,
  TextStyle nameStyle,
  TextStyle endedStyle,
})
_measureRelationLabel(
  BuildContext context, {
  required double availableWidth,
  required List<({String id, String name, String role})> roles,
  required bool ended,
  bool compact = false,
  bool highlighted = true,
}) {
  final Tokens t = context.tk;
  final double textScale = MediaQuery.textScalerOf(context).scale(12) / 12;
  final double width = math.min(
    availableWidth - 8,
    (compact ? 148 : 170) * textScale.clamp(1, 1.8),
  );
  final String? font = Theme.of(context).textTheme.bodyMedium?.fontFamily;
  final TextStyle roleStyle = TextStyle(
    inherit: false,
    fontFamily: font,
    fontSize: compact ? 11 : 12.5,
    fontWeight: FontWeight.w600,
    height: 1.25,
    color: highlighted ? t.ink : t.ink2,
  );
  final TextStyle nameStyle = TextStyle(
    inherit: false,
    fontFamily: font,
    fontSize: compact ? 10 : 10.5,
    height: 1.2,
    color: t.ink2,
  );
  final TextStyle endedStyle = TextStyle(
    inherit: false,
    fontFamily: font,
    fontSize: compact ? 10 : 11,
    height: 1.2,
    color: t.amber,
  );
  double textHeight(String text, TextStyle style, {bool name = false}) {
    final TextPainter measure = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: name ? 1 : null,
      ellipsis: name ? '…' : null,
    )..layout(maxWidth: math.max(1, width - 18));
    final double height = measure.height;
    measure.dispose();
    return height;
  }

  // Decoration adds a one-pixel border on top of the content padding.
  // Measure every role independently; only the smaller name may ellipsize.
  final double height =
      14 +
      roles.fold<double>(
        0,
        (sum, role) =>
            sum +
            textHeight(role.role, roleStyle) +
            1 +
            textHeight(role.name, nameStyle, name: true),
      ) +
      math.max(0, roles.length - 1) * 5 +
      (ended ? 5 + textHeight('已结束', endedStyle) : 0);
  return (
    width: width,
    height: height,
    roleStyle: roleStyle,
    nameStyle: nameStyle,
    endedStyle: endedStyle,
  );
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
  });
  final World world;
  final String? focus;
  final bool compact;
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
        .take(4)
        .toList();
    final Map<String, Offset> out = <String, Offset>{
      focus: const Offset(.5, .5),
    };
    for (int i = 0; i < ids.length; i++) {
      final double angle = -math.pi / 2 + i * 2 * math.pi / ids.length;
      out[ids[i]] = Offset(
        .5 + .42 * math.cos(angle),
        .5 + .42 * math.sin(angle),
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
              onPressed: () => Navigator.of(context).pop(),
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
        final Map<String, Offset> centers = <String, Offset>{
          for (final MapEntry<String, Offset> entry in pos.entries)
            entry.key: Offset(
              marginX + entry.value.dx * math.max(0, size.width - marginX * 2),
              sparseLargeText
                  ? size.height - math.max(72, 60 * textScale)
                  : marginY +
                        entry.value.dy * math.max(0, size.height - marginY * 2),
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
        for (int index = 0; index < relations.length; index++) {
          final Json relation = relations[index];
          final String label = relationLabel(
            widget.world,
            relation,
            selected: selected,
          );
          final Offset a = centers[relation['a']]!, b = centers[relation['b']]!;
          final bool highlighted =
              selected == null ||
              relation['a'] == selected ||
              relation['b'] == selected;
          final roles = _relationRoles(
            widget.world,
            relation,
            selected: selected,
          );
          final bool ended = relation['status'] == 'ended';
          final metrics = _measureRelationLabel(
            context,
            availableWidth: size.width,
            roles: roles,
            ended: ended,
            compact: widget.compact,
            highlighted: highlighted,
          );
          final double width = metrics.width, height = metrics.height;
          final TextStyle roleStyle = metrics.roleStyle,
              nameStyle = metrics.nameStyle,
              endedStyle = metrics.endedStyle;
          final Rect rect = _placeLabel(
            a,
            b,
            Size(width, height),
            size,
            occupied,
          );
          // Start on a meaningful relationship, even when collision-free
          // labels have been placed away from a dense cluster of circles.
          final double priority =
              (selected != null && highlighted ? 100 : 0) +
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
          occupied.add(rect.inflate(5));
          leaders.add((Offset.lerp(a, b, .5)!, rect.center));
          labels.add(
            Positioned.fromRect(
              rect: rect,
              child: Semantics(
                button: true,
                label: '$label，查看关系详情',
                child: Tooltip(
                  message: label,
                  child: Material(
                    color: t.sheet,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      key: ValueKey<String>('relation-label-$index'),
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => _details(context, relation),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: relation['status'] == 'ended'
                                ? t.amber
                                : highlighted
                                ? t.ink3
                                : t.rule,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ExcludeSemantics(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (int i = 0; i < roles.length; i++) ...[
                                if (i > 0) const SizedBox(height: 5),
                                Text(
                                  roles[i].role,
                                  key: ValueKey<String>(
                                    'relation-role-$index-${roles[i].id}',
                                  ),
                                  textAlign: TextAlign.center,
                                  style: roleStyle,
                                ),
                                const SizedBox(height: 1),
                                Text(
                                  roles[i].name,
                                  key: ValueKey<String>(
                                    'relation-name-$index-${roles[i].id}',
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: nameStyle,
                                ),
                              ],
                              if (ended) ...[
                                const SizedBox(height: 5),
                                Text(
                                  '已结束',
                                  key: ValueKey<String>(
                                    'relation-ended-$index',
                                  ),
                                  textAlign: TextAlign.center,
                                  style: endedStyle,
                                ),
                              ],
                            ],
                          ),
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
                    onTap: () => widget.onTap(entry.key),
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
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: widget.compact ? 10 : 12,
                                height: 1.2,
                                color: t.ink,
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

Rect _placeLabel(
  Offset a,
  Offset b,
  Size label,
  Size bounds,
  List<Rect> occupied,
) {
  final Offset direction = b - a;
  final double distance = math.max(1, direction.distance);
  final Offset normal = Offset(-direction.dy, direction.dx) / distance;
  Rect? best;
  double bestScore = double.infinity;
  for (final double fraction in <double>[.5, .35, .65, .2, .8]) {
    for (final double shift in <double>[
      0,
      -36,
      36,
      -72,
      72,
      -108,
      108,
      -144,
      144,
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
  const GraphPage({super.key, required this.link, this.focus});
  final ReaderLink link;
  final String? focus;
  @override
  State<GraphPage> createState() => _GraphPageState();
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

  @override
  void initState() {
    super.initState();
    selected = widget.focus;
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

  void _layoutReady(Rect label, Rect a, Rect b) {
    bool fits(Rect region) =>
        region.width <= _viewport.width - 8 &&
        region.height <= _viewport.height - 8;
    final Rect both = label.expandToInclude(a).expandToInclude(b);
    final List<Rect> single =
        <Rect>[label.expandToInclude(a), label.expandToInclude(b)]..sort(
          (left, right) =>
              (left.width * left.height).compareTo(right.width * right.height),
        );
    final Rect region = fits(both)
        ? both
        : single.firstWhere(fits, orElse: () => label);
    _preferredCenter = region.center;
    if (_needsInitialView) {
      _needsInitialView = false;
      _resetView();
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
        else ...<Widget>[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Text(
                    '点关系文字看详情',
                    style: TextStyle(color: t.ink2, fontSize: 12),
                  ),
                  IconButton(
                    tooltip: '缩小关系图',
                    onPressed: () => _zoom(1 / 1.3),
                    icon: const Icon(Icons.remove),
                  ),
                  IconButton(
                    tooltip: '放大关系图',
                    onPressed: () => _zoom(1.3),
                    icon: const Icon(Icons.add),
                  ),
                  IconButton(
                    tooltip: '重置视图',
                    onPressed: _resetView,
                    icon: const Icon(Icons.center_focus_strong),
                  ),
                ],
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints box) {
                double panelHeight = height;
                final double scale =
                    MediaQuery.textScalerOf(context).scale(12) / 12;
                if (world.people.length <= 2 && scale > 1.2) {
                  for (final Json relation in world.rels) {
                    final metrics = _measureRelationLabel(
                      context,
                      availableWidth: box.maxWidth,
                      roles: _relationRoles(
                        world,
                        relation,
                        selected: selected,
                      ),
                      ended: relation['status'] == 'ended',
                    );
                    // Label top inset + measured card + the node's occupied
                    // upper bound + lower name band; all are in logical pixels.
                    panelHeight = math.max(
                      panelHeight,
                      4 + metrics.height + 4 + 27 + math.max(72, 60 * scale),
                    );
                  }
                }
                final Size viewport = Size(box.maxWidth, panelHeight);
                final int visible = math.min(40, world.people.length);
                final double expansion = visible <= 6
                    ? 0
                    : math.sqrt(math.max(visible, world.rels.length)) *
                          190 *
                          (MediaQuery.textScalerOf(context).scale(12) / 12)
                              .clamp(1, 1.8);
                final Size canvas = Size(
                  math.max(box.maxWidth, expansion),
                  math.max(panelHeight, expansion),
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
                    boundaryMargin: EdgeInsets.all(
                      math.max(_viewport.width, _viewport.height) *
                          (1 / .3 - 1) /
                          2,
                    ),
                    child: SizedBox(
                      width: canvas.width,
                      height: canvas.height,
                      child: RelationGraph(
                        world: world,
                        focus: widget.focus,
                        selected: selected,
                        onLayoutReady: _layoutReady,
                        onTap: (String id) => setState(() => selected = id),
                        onRelationTap: (Json relation) {
                          setState(_stop);
                          SheetScope.of(context).state.push(
                            RelationDetailPage(
                              world: world,
                              relation: relation,
                              asOf: asOf,
                            ),
                          );
                        },
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
                world.people.length > 40
                    ? '显示其中 40 位人物。拖动或放大查看，人物卡中可看各自的直接关系。'
                    : world.rels.isEmpty
                    ? '截至此页尚未记录关系，点人物可看资料。'
                    : '拖动或放大查看；虚线和“已结束”表示关系已经结束。',
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
                  onPressed: _play,
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
                    onChanged: (double value) => setState(() {
                      _stop();
                      replay = value;
                    }),
                    activeColor: t.zhu,
                    inactiveColor: t.rule,
                  ),
                ),
                Text(
                  '第 ${link.pageNo(at > 0 ? at - 1 : 0)} 页',
                  style: TextStyle(color: t.ink2, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        if (replay != null)
          SliverToBoxAdapter(
            child: TextButton(
              onPressed: () => setState(() {
                _stop();
                replay = null;
              }),
              child: const Text('回到当前页'),
            ),
          ),
      ],
    );
  }
}
