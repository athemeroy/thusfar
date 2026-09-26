import 'package:flutter/material.dart';

import '../data/library.dart';
import '../ui/theme.dart';
import 'sheet_host.dart';

/// Footnote anchors are offsets between source characters. An anchor exactly
/// at the page end belongs to the text just read, not to the next page.
List<(int, String)> pageFootnotes(BookData book, int start, int end) {
  final List<(int, String)> result = <(int, String)>[];
  for (final Block block in book.blocks) {
    if (block.o >= end) break;
    for (final (int offset, String id) in block.footnotes) {
      final int at = block.o + offset;
      if ((at > start || (block.o == start && offset == 0)) && at <= end) {
        result.add((at, id));
      }
    }
  }
  return result;
}

class FootnotesPage extends StatelessWidget {
  const FootnotesPage({super.key, required this.book, required this.notes});
  final BookData book;
  final List<(int, String)> notes;

  @override
  Widget build(BuildContext context) => SheetPage(
    title: '本页注释',
    slivers: <Widget>[
      SliverList.list(
        children: <Widget>[
          for (int i = 0; i < notes.length; i++)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 14),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: context.tk.paper,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: context.tk.ink.withValues(alpha: 0.06),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1.5,
                          ),
                          decoration: BoxDecoration(
                            color: context.tk.zhu.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '注 ${i + 1}',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: context.tk.zhu,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SelectableText(
                      book.footnoteText[notes[i].$2] ?? '这条注释的内容缺失',
                      style: TextStyle(
                        fontFamily: serif,
                        fontSize: 15,
                        height: 1.7,
                        color: context.tk.ink,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ],
  );
}
