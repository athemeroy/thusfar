import 'package:flutter/material.dart';
import 'package:thusfar_core/thusfar_core.dart';

import '../ui/theme.dart';
import 'common.dart';
import 'graph_view.dart';
import 'person_sheet.dart';
import 'sheet_host.dart';

/// S09 人物抽屉: this page, this chapter, everyone so far, the graph.
class PeoplePage extends StatefulWidget {
  const PeoplePage({
    super.key,
    required this.link,
    this.tab = 0,
    this.onStartProcessing,
  });

  final ReaderLink link;
  final int tab;
  final VoidCallback? onStartProcessing;

  @override
  State<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<PeoplePage> {
  late int tab = widget.tab;
  String query = '';

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final ReaderLink link = widget.link;
    final World? w = link.c.world;
    final int page = link.pageNo(link.c.cutoff > 0 ? link.c.cutoff - 1 : 0);
    if (w == null || w.people.isEmpty && !link.c.book.hasKnowledge) {
      return SheetPage(
        title: '人物',
        slivers: <Widget>[
          emptyState(
            context,
            '这本书还没整理人物',
            action: widget.onStartProcessing == null
                ? null
                : Pill(
                    label: '开始整理',
                    filled: true,
                    color: t.zhu,
                    onTap: widget.onStartProcessing,
                  ),
          ),
        ],
      );
    }
    List<Json> people;
    switch (tab) {
      case 0:
        people = <Json>[
          for (final String id in link.c.pagePeople()) w.people[id]!,
        ];
      case 1:
        people = <Json>[
          for (final String id in link.c.chapterPeople()) w.people[id]!,
        ];
      default:
        people = w.ranked();
    }
    if (tab == 2 && query.isNotEmpty) {
      final String q = query.toLowerCase();
      people = people.where((Json p) {
        final Person x = Person(p);
        return x.name.toLowerCase().contains(q) ||
            x.aliases.any((String a) => a.toLowerCase().contains(q)) ||
            x.tagline.toLowerCase().contains(q);
      }).toList();
    }
    return SheetPage(
      title: '人物 · 截至第 $page 页',
      headerExtraHeight: tab == 2 ? 100 : 44,
      headerExtra: Column(
        children: <Widget>[
          Segmented(
            labels: const <String>['本页', '本章', '全部', '关系图'],
            index: tab,
            onChanged: (int i) {
              if (i == 3) {
                SheetScope.of(context).state.push(GraphPage(link: link));
              } else {
                setState(() => tab = i);
              }
            },
          ),
          if (tab == 2)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: SizedBox(
                height: 44,
                child: TextField(
                  onChanged: (String v) => setState(() => query = v.trim()),
                  decoration: InputDecoration(
                    hintText: '搜名字、称呼、身份',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    filled: true,
                    fillColor: t.paper,
                    contentPadding: EdgeInsets.zero,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      slivers: <Widget>[
        if (people.isEmpty)
          emptyState(context, tab == 0 ? '这一页没有已整理的人物' : '没有找到')
        else
          SliverList.builder(
            itemCount: people.length,
            itemBuilder: (BuildContext context, int i) {
              final Person p = Person(people[i]);
              final bool isNew = link.c.isNewOnPage(p.id);
              return InkWell(
                onTap: () => SheetScope.of(
                  context,
                ).state.push(PersonPage(link: link, id: p.id)),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 60),
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: Row(
                    children: <Widget>[
                      Avatar(
                        name: p.name,
                        color: p.raw['color']! as String,
                        size: 38,
                        isNew: isNew,
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
                                    p.name,
                                    style: TextStyle(
                                      fontSize: 16,
                                      color: t.ink,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (isNew) ...<Widget>[
                                  const SizedBox(width: 6),
                                  Tag('新', color: t.zhu),
                                ],
                              ],
                            ),
                            if (p.tagline.isNotEmpty)
                              Text(
                                p.tagline,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 13, color: t.ink2),
                              ),
                          ],
                        ),
                      ),
                      Text(
                        '${p.mentions}',
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
              );
            },
          ),
      ],
    );
  }
}
