import 'package:flutter/material.dart';
import 'package:thusfar_core/thusfar_core.dart';

import '../data/seen.dart';
import '../ui/theme.dart';
import 'common.dart';
import 'graph_view.dart';
import 'manual_entity_editor.dart';
import 'preview_sheet.dart';
import 'sheet_host.dart';

/// S05 人物卡: who this is, as of this page.
class PersonPage extends StatefulWidget {
  const PersonPage({
    super.key,
    required this.link,
    required this.id,
    this.path = const <String>[],
  });

  final ReaderLink link;
  final String id;
  final List<String> path;

  @override
  State<PersonPage> createState() => _PersonPageState();
}

class _PersonPageState extends State<PersonPage> {
  bool newestFirst = true;
  late final int? lastSeen;

  @override
  void initState() {
    super.initState();
    widget.link.c.addListener(_changed);
    final String id = widget.link.c.world?.canon(widget.id) ?? widget.id;
    lastSeen = SeenStore.instance.get(widget.link.c.book.id, id);
    SeenStore.instance.mark(widget.link.c.book.id, id, widget.link.c.cutoff);
  }

  @override
  void dispose() {
    widget.link.c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  int _at(Json r) => ((r['s'] ?? r['p'])! as num).toInt();

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final ReaderLink link = widget.link;
    final World? current = link.c.world;
    final Person? p = current?.person(widget.id);
    final int cutoffPage = link.pageNo(
      link.c.cutoff > 0 ? link.c.cutoff - 1 : 0,
    );
    if (p == null) {
      return SheetPage(
        title: '人物',
        slivers: <Widget>[emptyState(context, '读到这一页，这个人还没有登场。')],
      );
    }
    final World w = current!;
    final List<Json> events = p.events.toList();
    if (newestFirst) {
      events.sort((Json a, Json b) => _at(b).compareTo(_at(a)));
    } else {
      events.sort((Json a, Json b) => _at(a).compareTo(_at(b)));
    }
    final int? seen = lastSeen;
    final Set<Json> fresh = <Json>{
      if (seen != null) ...events.where((Json e) => (e['p']! as num) > seen),
    };
    final List<Json> rels = w.relsOf(p.id);
    final Map<String, List<Json>> attrs = p.attrs;
    final List<Json> trail = p.trail;
    final bool beyond = link.c.beyondFrontier;
    final List<String> path = <String>[...widget.path, p.name];
    return SheetPage(
      title: p.name,
      path: path.length > 1 ? path.join(' › ') : null,
      titleWidget: Row(
        children: <Widget>[
          Avatar(name: p.name, color: p.raw['color']! as String, size: 28),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              p.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: display, fontSize: 22, color: t.ink),
            ),
          ),
        ],
      ),
      tag: '截至第 $cutoffPage 页',
      slivers: <Widget>[
        if (p.manual)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      p.entityKind == 'concept' ? '你手动补充的概念' : '你手动补充的人物',
                      style: TextStyle(color: t.ink2),
                    ),
                  ),
                  TextButton(
                    onPressed: () => SheetScope.of(context).state.push(
                      ManualEntityEditor(link: link, id: p.id.substring(1)),
                    ),
                    child: const Text('编辑或删除'),
                  ),
                ],
              ),
            ),
          ),
        if (beyond)
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.fromLTRB(20, 4, 20, 4),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: t.amber.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '人物资料只整理到第 ${link.pageNo(link.c.book.status.frontier)} 页',
                style: TextStyle(color: t.amber, fontSize: 13),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (p.aliases.isNotEmpty)
                  Text(
                    '又称 ${p.aliases.join('、')}',
                    style: TextStyle(fontSize: 13, color: t.ink2),
                  ),
                if (p.tagline.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      p.tagline,
                      style: TextStyle(fontSize: 15, color: t.ink),
                    ),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: <Widget>[
                    Tag(
                      '第 ${link.pageNo(p.first)} 页登场',
                      onTap: () => _preview(p.first, p.first + p.name.length),
                    ),
                    Tag('出场 ${p.mentions} 次'),
                  ],
                ),
              ],
            ),
          ),
        ),
        if (fresh.isNotEmpty && seen != null)
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: t.zhuSoft,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '你上次在第 ${link.pageNo(seen > 0 ? seen - 1 : 0)} 页看过${p.name}，之后又发生了 ${fresh.length} 件事',
                style: TextStyle(color: t.zhu, fontSize: 14),
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SectionTitle('简介')),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              p.bio.isNotEmpty
                  ? p.bio
                  : p.manual
                  ? '你还没有为这条补充写说明。'
                  : '人物小传还没整理到这里，下面是截至这一页的线索。',
              style: TextStyle(
                fontFamily: p.bio.isNotEmpty ? serif : null,
                fontSize: p.bio.isNotEmpty ? 16 : 14,
                height: 1.75,
                color: p.bio.isNotEmpty ? t.ink : t.ink3,
              ),
            ),
          ),
        ),
        if (attrs.isNotEmpty) ...<Widget>[
          const SliverToBoxAdapter(child: SectionTitle('档案')),
          SliverList.list(
            children: <Widget>[
              for (final MapEntry<String, List<Json>> a in attrs.entries)
                _attrRow(context, a.key, a.value),
            ],
          ),
        ],
        if (rels.isNotEmpty) ...<Widget>[
          SliverToBoxAdapter(
            child: SectionTitle(
              '关系',
              trailing: Text(
                '${rels.length}',
                style: TextStyle(color: t.ink3, fontSize: 13),
              ),
            ),
          ),
          if (rels.length >= 2)
            SliverToBoxAdapter(
              child: SizedBox(
                height: 200,
                child: RelationGraph(
                  world: w,
                  focus: p.id,
                  compact: true,
                  showLabels: false,
                  onTap: (String id) => _push(id),
                ),
              ),
            ),
          SliverList.list(
            children: <Widget>[
              for (final Json r in rels) _relRow(context, w, r),
            ],
          ),
        ],
        if (events.isNotEmpty) ...<Widget>[
          SliverToBoxAdapter(
            child: SectionTitle(
              '经历',
              trailing: GestureDetector(
                onTap: () => setState(() => newestFirst = !newestFirst),
                child: Text(
                  newestFirst ? '最新在上 ⇅' : '最早在上 ⇅',
                  style: TextStyle(color: t.ink3, fontSize: 13),
                ),
              ),
            ),
          ),
          SliverList.list(
            children: <Widget>[
              for (final Json e in events)
                _eventRow(context, e, fresh.contains(e)),
            ],
          ),
        ],
        if (trail.length > 1) ...<Widget>[
          const SliverToBoxAdapter(child: SectionTitle('身份变迁')),
          SliverList.list(
            children: <Widget>[
              for (final Json s in trail)
                ListTile(
                  dense: true,
                  leading: Tag('第 ${link.pageNo((s['p']! as num).toInt())} 页'),
                  title: Text(
                    '${s['t']}',
                    style: TextStyle(fontSize: 14, color: t.ink),
                  ),
                ),
            ],
          ),
        ],
      ],
      bottom: Row(
        children: <Widget>[
          Expanded(
            child: Pill(
              label: '问问这个人',
              icon: Icons.chat_bubble_outline,
              onTap: () => link.openAsk(prefill: '${p.name} '),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Pill(
              label: '在关系图里看',
              icon: Icons.hub_outlined,
              onTap: () => SheetScope.of(
                context,
              ).state.push(GraphPage(link: link, focus: p.id)),
            ),
          ),
        ],
      ),
    );
  }

  void _push(String id) {
    final World w = widget.link.c.world!;
    final String me = w.person(widget.id)?.name ?? '';
    SheetScope.of(context).state.push(
      PersonPage(link: widget.link, id: id, path: <String>[...widget.path, me]),
    );
  }

  void _preview(int start, int end) => SheetScope.of(
    context,
  ).state.push(PreviewPage(link: widget.link, start: start, end: end));

  Widget _attrRow(BuildContext context, String key, List<Json> values) {
    final Tokens t = context.tk;
    final Json last = values.last;
    final bool changed =
        values.length > 1 && values[values.length - 2]['v'] != last['v'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 76,
            child: Text(key, style: TextStyle(fontSize: 14, color: t.ink3)),
          ),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  if (changed)
                    TextSpan(
                      text: '${values[values.length - 2]['v']} → ',
                      style: TextStyle(color: t.ink3),
                    ),
                  TextSpan(text: '${last['v']}'),
                  if (changed)
                    TextSpan(
                      text: '  第 ${widget.link.pageNo(_at(last))} 页',
                      style: TextStyle(color: t.ink3, fontSize: 12),
                    ),
                ],
              ),
              style: TextStyle(fontSize: 14, color: t.ink, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _relRow(BuildContext context, World w, Json r) {
    final Tokens t = context.tk;
    final Person? other = w.person('${r['other']}');
    if (other == null) return const SizedBox.shrink();
    return InkWell(
      onTap: () => _push(other.id),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 20, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Avatar(
              name: other.name,
              color: other.raw['color']! as String,
              size: 34,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          other.name,
                          style: TextStyle(
                            fontSize: 15,
                            color: t.ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      if ((r['role'] ?? '') != '') ...<Widget>[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            '${r['role']}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: t.zhu),
                          ),
                        ),
                      ],
                      if (r['status'] == 'ended') ...<Widget>[
                        const SizedBox(width: 6),
                        Tag('已结束'),
                      ],
                    ],
                  ),
                  if ((r['desc'] ?? '') != '')
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        '${r['desc']}',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: t.ink2,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: t.ink3, size: 18),
          ],
        ),
      ),
    );
  }

  Widget _eventRow(BuildContext context, Json e, bool fresh) {
    final Tokens t = context.tk;
    final int at = _at(e);
    return InkWell(
      onTap: () => _preview(at, (e['p']! as num).toInt()),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 7, right: 12),
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: fresh ? t.zhu : t.rule,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            Expanded(
              child: Text(
                '${e['text']}',
                style: TextStyle(fontSize: 14, height: 1.6, color: t.ink),
              ),
            ),
            const SizedBox(width: 8),
            Tag('第 ${widget.link.pageNo(at)} 页', color: fresh ? t.zhu : null),
          ],
        ),
      ),
    );
  }
}
