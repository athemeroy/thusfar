// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ui/theme.dart';
import 'web_storage.dart';

class WebNotesCenter extends StatefulWidget {
  const WebNotesCenter({
    super.key,
    required this.books,
    required this.states,
    required this.onOpen,
  });
  final List<WebBookMeta> books;
  final Map<String, WebReadingState> states;
  final Future<void> Function(WebBookMeta, WebPersonalItem) onOpen;

  @override
  State<WebNotesCenter> createState() => _WebNotesCenterState();
}

class _WebNotesCenterState extends State<WebNotesCenter> {
  String _filter = 'all';
  final TextEditingController _search = TextEditingController();

  String _kind(WebPersonalItem item) => item.kind == 'bookmark'
      ? '书签'
      : item.style == 'highlight'
      ? '划线'
      : '想法';

  List<(WebBookMeta, WebPersonalItem)> get _rows {
    final String query = _search.text.trim().toLowerCase();
    return <(WebBookMeta, WebPersonalItem)>[
      for (final book in widget.books)
        for (final item in widget.states[book.id]?.items ?? <WebPersonalItem>[])
          if (!item.deleted &&
              (_filter == 'all' || _kind(item) == _filter) &&
              (query.isEmpty ||
                  '${book.title} ${book.author} ${item.text}'
                      .toLowerCase()
                      .contains(query)))
            (book, item),
    ]..sort((a, b) => b.$2.updated.compareTo(a.$2.updated));
  }

  String _markdown(List<(WebBookMeta, WebPersonalItem)> rows) {
    final List<String> lines = <String>['# 我的书摘', ''];
    for (final (WebBookMeta book, WebPersonalItem item) in rows) {
      lines.addAll(<String>[
        '## ${book.title}',
        if (book.author.isNotEmpty) book.author,
        '',
        '### ${_kind(item)}',
        '',
      ]);
      if (item.style == 'highlight') {
        lines.addAll(item.text.split('\n').map((String line) => '> $line'));
      } else if (item.text.isNotEmpty) {
        lines.add(item.text);
      }
      lines.addAll(<String>[
        '',
        '第 ${item.chapter + 1} 章 · 本章 ${(item.fraction * 100).round()}%',
        '',
      ]);
    }
    return lines.join('\n');
  }

  Future<void> _copy() async {
    try {
      await Clipboard.setData(ClipboardData(text: _markdown(_rows)));
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已复制')));
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未能复制，请使用导出书摘。')));
      }
    }
  }

  void _export() {
    final html.Blob file = html.Blob(<Object>[
      utf8.encode(_markdown(_rows)),
    ], 'text/markdown;charset=utf-8');
    final String url = html.Url.createObjectUrlFromBlob(file);
    final html.AnchorElement anchor = html.AnchorElement(href: url)
      ..download = '页读书摘.md';
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    Future<void>.delayed(
      const Duration(seconds: 1),
      () => html.Url.revokeObjectUrl(url),
    );
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final rows = _rows;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            Text(
              '书摘',
              style: TextStyle(fontFamily: display, fontSize: 32, color: t.ink),
            ),
            const SizedBox(height: 6),
            Text('留存心动字句。', style: TextStyle(color: t.ink2)),
            const SizedBox(height: 20),
            TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: '搜索书摘或书名',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空搜索',
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          _search.clear();
                          setState(() {});
                        },
                      ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final (value, label) in const [
                  ('all', '全部'),
                  ('划线', '划线'),
                  ('想法', '想法'),
                  ('书签', '书签'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    selected: _filter == value,
                    onSelected: (_) => setState(() => _filter = value),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: <Widget>[
                TextButton.icon(
                  onPressed: rows.isEmpty ? null : _copy,
                  icon: const Icon(Icons.copy_outlined),
                  label: const Text('复制当前结果'),
                ),
                TextButton.icon(
                  onPressed: rows.isEmpty ? null : _export,
                  icon: const Icon(Icons.download_outlined),
                  label: const Text('导出当前结果'),
                ),
              ],
            ),
            if (rows.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 56),
                child: Column(
                  children: <Widget>[
                    Icon(Icons.edit_note_outlined, color: t.qing, size: 40),
                    const SizedBox(height: 16),
                    Text(
                      _search.text.isEmpty && _filter == 'all'
                          ? '笔墨未动'
                          : '没有找到',
                      style: TextStyle(
                        fontFamily: serif,
                        fontSize: 22,
                        color: t.ink,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _search.text.isEmpty && _filter == 'all'
                          ? '读书时长按句子，留存心中感动。'
                          : '换个词，或看看其他分类。',
                      style: TextStyle(color: t.ink2),
                    ),
                  ],
                ),
              ),
            for (final (book, item) in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Material(
                  color: t.sheet,
                  borderRadius: BorderRadius.circular(18),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => widget.onOpen(book, item),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            _kind(item),
                            style: TextStyle(color: t.qing, fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            item.text.isEmpty ? '记住这一页。' : item.text,
                            style: TextStyle(
                              fontFamily: serif,
                              color: t.ink,
                              height: 1.7,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '${book.title} · 第 ${item.chapter + 1} 章',
                            style: TextStyle(color: t.ink2, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
