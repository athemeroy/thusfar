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
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('注 ${i + 1}', style: TextStyle(color: context.tk.ink3)),
                  const SizedBox(height: 8),
                  SelectableText(
                    book.footnoteText[notes[i].$2] ?? '这条注释的内容缺失',
                    style: TextStyle(
                      fontFamily: serif,
                      fontSize: 16,
                      height: 1.7,
                      color: context.tk.ink,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ],
  );
}
