import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../reader/source_search.dart';
import 'web_storage.dart';

/// Search keeps the input and scope fixed while results load or paginate.
class WebReaderSearch extends StatefulWidget {
  const WebReaderSearch({
    super.key,
    required this.book,
    required this.cutoff,
    required this.chapterTitle,
    required this.onHit,
  });
  final WebBook book;
  final int cutoff;
  final String Function(int) chapterTitle;
  final ValueChanged<SourceSearchHit> onHit;
  @override
  State<WebReaderSearch> createState() => _WebReaderSearchState();
}

class _WebReaderSearchState extends State<WebReaderSearch> {
  final TextEditingController _input = TextEditingController();
  late final List<SourceSearchBlock> _blocks;
  Timer? _timer;
  int _epoch = 0;
  bool _whole = false;
  bool _searching = false;
  String _query = '';
  List<SourceSearchHit> _hits = const <SourceSearchHit>[];

  @override
  void initState() {
    super.initState();
    _blocks = <SourceSearchBlock>[
      for (int c = 0; c < widget.book.chapters.length; c++)
        for (
          int b = (widget.book.chapters[c]['b0'] as num).toInt();
          b < (widget.book.chapters[c]['b1'] as num).toInt();
          b++
        )
          if (widget.book.blocks[b]['k'] == 'p' ||
              widget.book.blocks[b]['k'] == 'h')
            SourceSearchBlock(
              chapter: c,
              block: b,
              start: (widget.book.blocks[b]['o'] as num).toInt(),
              text: '${widget.book.blocks[b]['t'] ?? ''}',
            ),
    ];
    _input.addListener(_edited);
  }

  void _edited() {
    if (_input.value.composing.isValid && !_input.value.composing.isCollapsed) {
      return;
    }
    if (_input.text.trim() == _query) return;
    _query = _input.text.trim();
    _run();
  }

  void _run() {
    _timer?.cancel();
    final int epoch = ++_epoch;
    setState(() {
      _hits = const [];
      _searching = _query.isNotEmpty;
    });
    if (_query.isEmpty) return;
    _timer = Timer(const Duration(milliseconds: 160), () async {
      final List<SourceSearchHit> hits = await searchSourceText(
        _blocks,
        _query,
        _whole
            ? (_blocks.isEmpty
                  ? 0
                  : _blocks.last.start + _blocks.last.text.length)
            : widget.cutoff,
        cancelled: () => !mounted || epoch != _epoch,
      );
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _hits = hits;
        _searching = false;
      });
    });
  }

  @override
  void dispose() {
    _epoch++;
    _timer?.cancel();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: math.min(
          700,
          math.max(
                0,
                MediaQuery.sizeOf(context).height -
                    MediaQuery.viewInsetsOf(context).bottom -
                    MediaQuery.paddingOf(context).vertical,
              ) *
              .88,
        ),
        child: CustomScrollView(
          slivers: <Widget>[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Expanded(
                          child: Text(
                            _searching
                                ? '正在搜索…'
                                : _query.isEmpty
                                ? '搜索正文'
                                : '找到 ${_hits.length} 处',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭搜索',
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    TextField(
                      key: const ValueKey<String>('web-reader-search-input'),
                      controller: _input,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: '搜索读到这里的正文',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _input.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清空正文搜索',
                                icon: const Icon(Icons.close),
                                onPressed: _input.clear,
                              ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: <Widget>[
                        ChoiceChip(
                          label: const Text('读到这里'),
                          selected: !_whole,
                          onSelected: (_) {
                            if (_whole) {
                              _whole = false;
                              _run();
                            }
                          },
                        ),
                        ChoiceChip(
                          label: const Text('全书'),
                          selected: _whole,
                          onSelected: (_) {
                            if (!_whole) {
                              _whole = true;
                              _run();
                            }
                          },
                        ),
                      ],
                    ),
                    if (_whole) const Text('会搜到还没读的内容'),
                  ],
                ),
              ),
            ),
            if (_query.isEmpty || (!_searching && _hits.isEmpty))
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _query.isEmpty
                        ? '输入人物、地点或一句话'
                        : _whole
                        ? '全书没有找到'
                        : '读到这里没有找到。可以选择全书搜索。',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            SliverList.builder(
              itemCount: _hits.length,
              itemBuilder: (context, index) {
                final SourceSearchHit hit = _hits[index];
                return ListTile(
                  key: ValueKey<int>(hit.start),
                  title: Text(
                    '${hit.before}${hit.match}${hit.after}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${widget.chapterTitle(hit.chapter)} · 第 ${index + 1} 处',
                  ),
                  onTap: () => widget.onHit(hit),
                );
              },
            ),
          ],
        ),
      ),
    ),
  );
}
