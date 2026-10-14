import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../reader/source_search.dart';
import '../ui/theme.dart';
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
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final double height = math.min(
      700,
      math.max(
            0,
            MediaQuery.sizeOf(context).height -
                MediaQuery.viewInsetsOf(context).bottom -
                MediaQuery.paddingOf(context).vertical,
          ) *
          .88,
    );
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: height,
          child: Column(
            children: <Widget>[
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: math.max(0, height - 80),
                ),
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                '搜原文',
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
                          key: const ValueKey<String>(
                            'web-reader-search-input',
                          ),
                          controller: _input,
                          autofocus: true,
                          decoration: InputDecoration(
                            labelText: '搜原文',
                            hintText: '寻找书里的一句话',
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
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
                            ChoiceChip(
                              label: const Text('仅看已读'),
                              selected: !_whole,
                              onSelected: (_) {
                                if (_whole) {
                                  _whole = false;
                                  _run();
                                }
                              },
                            ),
                            ChoiceChip(
                              label: const Text('搜索全书'),
                              selected: _whole,
                              onSelected: (_) {
                                if (!_whole) {
                                  _whole = true;
                                  _run();
                                }
                              },
                            ),
                            if (_whole)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 9,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: t.amber.withValues(alpha: .1),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text(
                                  '可能剧透',
                                  style: TextStyle(
                                    color: t.amber,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        if (_whole)
                          Text(
                            '将显示后文内容，请谨慎翻看。',
                            style: TextStyle(color: t.amber, fontSize: 12),
                          ),
                        if (_query.isNotEmpty && !_searching) ...<Widget>[
                          const SizedBox(height: 8),
                          Text(
                            '${_whole ? '全书' : '已读篇幅'}中共找到 ${_hits.length} 处',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: t.ink3, fontSize: 12),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (_searching)
                LinearProgressIndicator(minHeight: 2, color: t.qing),
              Expanded(
                child: _query.isEmpty || (!_searching && _hits.isEmpty)
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            _query.isEmpty
                                ? '输入人物、地点或一句话。'
                                : _whole
                                ? '全书中没有找到，换个词试试。'
                                : '已读内容中没有找到，换个词试试。',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: t.ink2, height: 1.5),
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _hits.length,
                        itemBuilder: (BuildContext context, int index) {
                          final SourceSearchHit hit = _hits[index];
                          return ListTile(
                            key: ValueKey<int>(hit.start),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 6,
                            ),
                            title: Text.rich(
                              TextSpan(
                                children: <InlineSpan>[
                                  TextSpan(text: hit.before),
                                  TextSpan(
                                    text: hit.match,
                                    style: TextStyle(
                                      color: t.qing,
                                      backgroundColor: t.qingSoft,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  TextSpan(text: hit.after),
                                ],
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '${widget.chapterTitle(hit.chapter)} · 第 ${index + 1} 处',
                              style: TextStyle(fontSize: 12, color: t.ink3),
                            ),
                            onTap: () => widget.onHit(hit),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
