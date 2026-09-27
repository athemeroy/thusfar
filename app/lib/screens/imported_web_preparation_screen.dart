import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../data/library.dart';
import '../ui/theme.dart';

/// Shows browser-produced drafts after a portable backup or WebDAV import.
/// They remain separate from the installed client's verified knowledge graph.
class ImportedWebPreparationScreen extends StatefulWidget {
  const ImportedWebPreparationScreen({
    super.key,
    required this.entry,
    required this.progress,
  });

  final BookEntry entry;
  final Progress? progress;

  @override
  State<ImportedWebPreparationScreen> createState() =>
      _ImportedWebPreparationScreenState();
}

class _ImportedWebPreparationScreenState
    extends State<ImportedWebPreparationScreen> {
  bool _revealCurrent = false;
  late final List<String> _chapters;
  int _currentChapter = 0;
  late final List<(int, int, Json)> _drafts;
  int _invalidDrafts = 0;
  String? _error;

  /// Rebuild the exact browser AI source chunks before showing an imported
  /// citation. A hand-edited backup cannot relabel future evidence as an
  /// earlier chapter and bypass the reading boundary.
  List<String> _chapterChunks(Json chapter, List<Json> blocks) {
    const int maxChars = 5600;
    final int start = ((chapter['b0'] as num?)?.toInt() ?? 0).clamp(
      0,
      blocks.length,
    );
    final int end = ((chapter['b1'] as num?)?.toInt() ?? start).clamp(
      start,
      blocks.length,
    );
    final List<String> chunks = <String>[];
    final StringBuffer buffer = StringBuffer();
    int length = 0;
    void emit() {
      if (length == 0) return;
      chunks.add(buffer.toString());
      buffer.clear();
      length = 0;
    }

    for (int bi = start; bi < end; bi++) {
      final Json block = blocks[bi];
      if (block['k'] != 'p') continue;
      final String paragraph = (block['t'] as String? ?? '').trim();
      if (paragraph.isEmpty) continue;
      int at = 0;
      while (at < paragraph.length) {
        final int separator = length == 0 ? 0 : 1;
        final int space = maxChars - length - separator;
        if (space < 2) {
          emit();
          continue;
        }
        int stop = at + space < paragraph.length
            ? at + space
            : paragraph.length;
        if (stop < paragraph.length &&
            stop > at &&
            paragraph.codeUnitAt(stop - 1) >= 0xd800 &&
            paragraph.codeUnitAt(stop - 1) <= 0xdbff &&
            paragraph.codeUnitAt(stop) >= 0xdc00 &&
            paragraph.codeUnitAt(stop) <= 0xdfff) {
          stop--;
        }
        if (stop == at) {
          emit();
          continue;
        }
        if (separator != 0) {
          buffer.write('\n');
          length++;
        }
        buffer.write(paragraph.substring(at, stop));
        length += stop - at;
        at = stop;
        if (at < paragraph.length || length >= maxChars - 1) emit();
      }
    }
    emit();
    return chunks;
  }

  bool _hasValidEvidence(Json result, String source) {
    final String summary = '${result['summary'] ?? ''}';
    final String summaryEvidence = '${result['summary_evidence'] ?? ''}';
    if (summary.isNotEmpty != summaryEvidence.isNotEmpty ||
        (summaryEvidence.isNotEmpty && !source.contains(summaryEvidence))) {
      return false;
    }
    final Object? facts = result['character_facts'];
    final Object? links = result['relationships'];
    if (facts is! List || links is! List) return false;
    for (final Object? item in facts) {
      if (item is! Json) return false;
      final String name = '${item['name'] ?? ''}';
      final String evidence = '${item['evidence'] ?? ''}';
      if (name.isEmpty ||
          evidence.isEmpty ||
          !evidence.contains(name) ||
          !source.contains(evidence)) {
        return false;
      }
    }
    for (final Object? item in links) {
      if (item is! Json) return false;
      final String from = '${item['from'] ?? ''}';
      final String to = '${item['to'] ?? ''}';
      final String evidence = '${item['evidence'] ?? ''}';
      if (from.isEmpty ||
          to.isEmpty ||
          from == to ||
          evidence.isEmpty ||
          !evidence.contains(from) ||
          !evidence.contains(to) ||
          !source.contains(evidence)) {
        return false;
      }
    }
    return summary.isNotEmpty || facts.isNotEmpty || links.isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    _chapters = <String>[];
    _drafts = <(int, int, Json)>[];
    try {
      final Object? rawBook = jsonDecode(
        File('${widget.entry.dir.path}/book.json').readAsStringSync(),
      );
      final Object? rawTransfer = jsonDecode(
        File('${widget.entry.dir.path}/web-transfer.json').readAsStringSync(),
      );
      if (rawBook is! Json || rawTransfer is! Json) {
        throw const FormatException();
      }
      final Object? rawChapters = rawBook['chapters'];
      final Object? rawPreparation = rawTransfer['preparation'];
      if (rawChapters is! List || rawPreparation is! Json) {
        throw const FormatException();
      }
      final List<Json> chapterRows = <Json>[
        for (final Object? row in rawChapters)
          if (row is Json) row,
      ];
      if (chapterRows.length != rawChapters.length || chapterRows.isEmpty) {
        throw const FormatException();
      }
      final Object? rawBlocks = rawBook['blocks'];
      if (rawBlocks is! List) throw const FormatException();
      final List<Json> blocks = <Json>[
        for (final Object? row in rawBlocks)
          if (row is Json) row,
      ];
      if (blocks.length != rawBlocks.length) throw const FormatException();
      final Map<int, List<String>> sourceCache = <int, List<String>>{};
      _chapters.addAll(<String>[
        for (int i = 0; i < chapterRows.length; i++)
          '${chapterRows[i]['title'] ?? '第 ${i + 1} 章'}',
      ]);
      final int offset = widget.progress?.pos ?? 0;
      int chapter = 0;
      for (int i = 0; i < chapterRows.length; i++) {
        final Object? start = chapterRows[i]['o0'];
        if (start is num && start.toInt() <= offset) chapter = i;
      }
      _currentChapter = chapter;
      final Object? rawResults = rawPreparation['results'];
      if (rawResults is! Json) throw const FormatException();
      for (final MapEntry<String, Object?> entry in rawResults.entries) {
        final Object? row = entry.value;
        if (row is! Json || row['result'] is! Json) {
          _invalidDrafts++;
          continue;
        }
        final Object? chapter = row['chapter_index'];
        final Object? chunk = row['chunk_index'];
        if (chapter is! int ||
            chunk is! int ||
            chapter < 0 ||
            chapter >= _chapters.length ||
            chunk < 0) {
          _invalidDrafts++;
          continue;
        }
        final List<String> sources = sourceCache.putIfAbsent(
          chapter,
          () => _chapterChunks(chapterRows[chapter], blocks),
        );
        final Json result = row['result']! as Json;
        if (entry.key != '$chapter:$chunk' ||
            chunk >= sources.length ||
            !_hasValidEvidence(result, sources[chunk])) {
          _invalidDrafts++;
          continue;
        }
        _drafts.add((chapter, chunk, result));
      }
      _drafts.sort((a, b) {
        final int order = a.$1.compareTo(b.$1);
        return order != 0 ? order : a.$2.compareTo(b.$2);
      });
    } on Object {
      _error = '导入的网页整理草稿无法读取。原始备份仍保留，请重新导入或检查文件。';
    }
  }

  Future<void> _toggleCurrent() async {
    if (_revealCurrent) {
      setState(() => _revealCurrent = false);
      return;
    }
    final bool? answer = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('查看当前章整理？'),
        content: const Text('当前章后半段可能包含尚未读到的情节。仅在这次打开时显示。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('暂不查看'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('仍要查看'),
          ),
        ],
      ),
    );
    if (answer == true && mounted) setState(() => _revealCurrent = true);
  }

  List<(int, Json)> _visible() => <(int, Json)>[
    for (final (int chapter, int _, Json result) in _drafts)
      if (chapter < _currentChapter ||
          (chapter == _currentChapter && _revealCurrent))
        (chapter, result),
  ];

  Widget _quote(Tokens t, Object? raw) {
    final String quote = raw is String ? raw.trim() : '';
    if (quote.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: t.paper,
        border: Border(left: BorderSide(color: t.zhu, width: 2)),
      ),
      child: Text('原文  $quote', style: TextStyle(color: t.ink2, height: 1.45)),
    );
  }

  Widget _item(
    Tokens t,
    int chapter,
    String title,
    String body,
    Object? quote,
  ) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    color: t.sheet,
    child: Padding(
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: TextStyle(
              color: t.ink,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(body, style: TextStyle(color: t.ink, height: 1.5)),
          _quote(t, quote),
          const SizedBox(height: 6),
          Text(
            _chapters[chapter],
            style: TextStyle(color: t.ink3, fontSize: 12),
          ),
        ],
      ),
    ),
  );

  Widget _tab(Tokens t, int kind) {
    final List<Widget> cards = <Widget>[];
    for (final (int chapter, Json result) in _visible()) {
      if (kind == 0) {
        final Object? facts = result['character_facts'];
        if (facts is! List) continue;
        for (final Object? raw in facts) {
          if (raw is! Json) continue;
          final String name = '${raw['name'] ?? ''}'.trim();
          final String fact = '${raw['fact'] ?? ''}'.trim();
          if (name.isNotEmpty && fact.isNotEmpty) {
            cards.add(_item(t, chapter, name, fact, raw['evidence']));
          }
        }
      } else if (kind == 1) {
        final String summary = '${result['summary'] ?? ''}'.trim();
        if (summary.isNotEmpty) {
          cards.add(
            _item(
              t,
              chapter,
              _chapters[chapter],
              summary,
              result['summary_evidence'],
            ),
          );
        }
      } else {
        final Object? links = result['relationships'];
        if (links is! List) continue;
        for (final Object? raw in links) {
          if (raw is! Json) continue;
          final String from = '${raw['from'] ?? ''}'.trim();
          final String to = '${raw['to'] ?? ''}'.trim();
          final String relation = '${raw['relationship'] ?? ''}'.trim();
          if (from.isNotEmpty && to.isNotEmpty && relation.isNotEmpty) {
            cards.add(
              _item(t, chapter, '$from · $to', relation, raw['evidence']),
            );
          }
        }
      }
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: cards.isEmpty
          ? <Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 36),
                child: Text(
                  '还没有已读章节的${const <String>['人物线索', '前情', '人物关系'][kind]}。',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: t.ink2),
                ),
              ),
            ]
          : cards,
    );
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('网页整理草稿')),
        body: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)),
      );
    }
    final int hidden = _drafts
        .where(
          (item) =>
              item.$1 > _currentChapter ||
              (item.$1 == _currentChapter && !_revealCurrent),
        )
        .length;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('网页整理草稿'),
          bottom: const TabBar(
            tabs: <Widget>[
              Tab(text: '人物'),
              Tab(text: '前情'),
              Tab(text: '关系'),
            ],
          ),
        ),
        body: Column(
          children: <Widget>[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              color: t.qingSoft,
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: <Widget>[
                  Text(
                    '已隐藏 $hidden 段未读整理 · 这些是网页草稿，与安装版核对结果分开',
                    style: TextStyle(color: t.qing, fontSize: 12),
                  ),
                  if (_invalidDrafts > 0)
                    Text(
                      '已跳过 $_invalidDrafts 段引文无法核对的草稿',
                      style: TextStyle(color: t.amber, fontSize: 12),
                    ),
                  if (_drafts.any((item) => item.$1 == _currentChapter))
                    TextButton(
                      onPressed: _toggleCurrent,
                      child: Text(_revealCurrent ? '收起当前章' : '查看当前章'),
                    ),
                ],
              ),
            ),
            Expanded(
              child: TabBarView(
                children: <Widget>[_tab(t, 0), _tab(t, 1), _tab(t, 2)],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
