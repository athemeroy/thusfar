import 'package:flutter/material.dart';

import '../ui/theme.dart';
import 'common.dart';
import 'sheet_host.dart';

/// S12 问书. Answers need the ported model client (stage A3/A6); until then
/// the drawer says so plainly instead of pretending.
class AskPage extends StatelessWidget {
  const AskPage({super.key, required this.link, this.prefill, this.quote});

  final ReaderLink link;
  final String? prefill;
  final String? quote;

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final int page = link.pageNo(link.c.cutoff > 0 ? link.c.cutoff - 1 : 0);
    return SheetPage(
      title: '问问这本书',
      tag: '只用前 $page 页回答',
      slivers: <Widget>[
        if (quote != null)
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: t.paper,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                quote!,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: serif,
                  fontSize: 14,
                  color: t.ink2,
                ),
              ),
            ),
          ),
        emptyState(context, '问书正在接入新版的模型引擎，这一版还不能回答。\n整理好的人物、关系和前情已经可以直接看。'),
      ],
    );
  }
}
