import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/library.dart';
import '../data/seen.dart';
import '../ui/theme.dart';
import 'chapter_title.dart';
import 'common.dart';
import 'preview_sheet.dart';
import 'sheet_host.dart';

class _Hit {
  const _Hit(this.chapter, this.at, this.before, this.match, this.after);

  final int chapter;
  final int at;
  final String before;
  final String match;
  final String after;
}

/// S13 搜索原文: defaults to what has been read.
class SearchPage extends StatefulWidget {
  const SearchPage({super.key, required this.link});

  final ReaderLink link;

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  String query = '';
  bool whole = false;
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;
  int _epoch = 0;
  int _lastLimit = 0;
  bool _searching = false;
  List<_Hit> _hits = const <_Hit>[];

  @override
  void initState() {
    super.initState();
    _lastLimit = widget.link.c.cutoff;
    widget.link.c.addListener(_positionChanged);
  }

  void _positionChanged() {
    final int limit = whole ? widget.link.c.book.length : widget.link.c.cutoff;
    if (limit != _lastLimit) _scheduleSearch();
  }

  @override
  void dispose() {
    _epoch++;
    _debounce?.cancel();
    widget.link.c.removeListener(_positionChanged);
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _clear() {
    _input.clear();
    query = '';
    _scheduleSearch();
    _focus.requestFocus();
  }

  void _scheduleSearch() {
    final int epoch = ++_epoch;
    _debounce?.cancel();
    final String q = query.toLowerCase();
    final int limit = whole ? widget.link.c.book.length : widget.link.c.cutoff;
    _lastLimit = limit;
    setState(() {
      _hits = const <_Hit>[];
      _searching = q.isNotEmpty;
    });
    if (q.isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 160), () async {
      final List<_Hit> hits = await _search(epoch, q, limit);
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _hits = hits;
        _searching = false;
      });
    });
  }

  Future<List<_Hit>> _search(int epoch, String q, int limit) async {
    final BookData book = widget.link.c.book;
    final List<_Hit> out = <_Hit>[];
    int scanned = 0;
    for (final Block b in book.blocks) {
      if (++scanned % 64 == 0) {
        await Future<void>.delayed(Duration.zero);
        if (!mounted || epoch != _epoch) return const <_Hit>[];
      }
      if (b.o >= limit) break;
      if (b.kind == 'img') continue;
      final String lower = b.text.toLowerCase();
      int from = 0;
      while (true) {
        final int i = lower.indexOf(q, from);
        if (i < 0 || b.o + i + q.length > limit) break;
        final int s = (i - 24).clamp(0, b.text.length);
        final int e = (i + q.length + 36).clamp(
          0,
          (limit - b.o).clamp(0, b.text.length),
        );
        out.add(
          _Hit(
            book.chapterAt(b.o + i),
            b.o + i,
            book.textBetween(b.o + s, b.o + i),
            b.text.substring(i, i + q.length),
            book.textBetween(b.o + i + q.length, b.o + e),
          ),
        );
        if (out.length >= 500) return out;
        from = i + q.length;
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final List<_Hit> hits = _hits;
    final BookData book = widget.link.c.book;
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    final double inputHeight = math.max(44, scaler.scale(16) * 1.6 + 10);
    final Segmented tabs = Segmented(
      labels: const <String>['读到这里', '全书'],
      index: whole ? 1 : 0,
      onChanged: (int i) {
        whole = i == 1;
        _scheduleSearch();
      },
    );
    final int read = SeenStore.instance.maxRead(book.id, widget.link.c.cutoff);
    final List<Widget> rows = <Widget>[];
    int? lastChapter;
    for (final _Hit h in hits) {
      if (h.chapter != lastChapter) {
        lastChapter = h.chapter;
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
            child: Text(
              safeTitle(
                book.chapters[h.chapter],
                book.chapters[h.chapter].o0 < read,
                checkPending: book.status.titleCheckPending,
              ),
              style: TextStyle(fontSize: 12, color: t.ink3, letterSpacing: 0.6),
            ),
          ),
        );
      }
      rows.add(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
          child: Material(
            color: t.paper,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () {
                HapticFeedback.lightImpact();
                SheetScope.of(context).state.push(
                  PreviewPage(
                    link: widget.link,
                    start: h.at,
                    end: h.at + h.match.length,
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: <InlineSpan>[
                            TextSpan(
                              text: h.before.isEmpty ? '' : '…${h.before}',
                            ),
                            TextSpan(
                              text: h.match,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: t.zhu,
                                backgroundColor: t.zhu.withValues(alpha: 0.12),
                              ),
                            ),
                            TextSpan(text: '${h.after}…'),
                          ],
                        ),
                        style: TextStyle(
                          fontFamily: serif,
                          fontSize: 14.5,
                          height: 1.6,
                          color: t.ink2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Tag('第 ${widget.link.pageNo(h.at)} 页'),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    return SheetPage(
      title: _searching
          ? '正在搜索…'
          : query.isEmpty
          ? '搜索原文'
          : '找到 ${hits.length}${hits.length >= 500 ? '+' : ''} 处',
      titleWidget: query.isEmpty || _searching
          ? null
          : Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  const TextSpan(text: '找到 '),
                  TextSpan(
                    text: '${hits.length}${hits.length >= 500 ? '+' : ''}',
                    style: TextStyle(
                      color: t.zhu,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                  const TextSpan(text: ' 处'),
                ],
              ),
              style: TextStyle(
                fontSize: 17,
                color: t.ink,
                fontWeight: FontWeight.w600,
              ),
            ),
      headerExtraHeight:
          inputHeight +
          8 +
          tabs.heightForWidth(context, MediaQuery.sizeOf(context).width) +
          (whole ? (scaler.scale(12) * 1.5 + 8).ceilToDouble() : 0),
      headerExtra: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: SizedBox(
              height: inputHeight,
              child: Focus(
                onKeyEvent: (_, KeyEvent event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.escape &&
                      query.isNotEmpty) {
                    _clear();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  key: const ValueKey<String>('reader-search-input'),
                  controller: _input,
                  focusNode: _focus,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onChanged: (String v) {
                    query = v.trim();
                    _scheduleSearch();
                  },
                  decoration: InputDecoration(
                    hintText: '搜索书里的一句话',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清空搜索',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              HapticFeedback.selectionClick();
                              _clear();
                            },
                          ),
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
          ),
          tabs,
          if (whole)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(Icons.warning_amber_rounded, size: 14, color: t.amber),
                  const SizedBox(width: 4),
                  Text(
                    '会搜到还没读的内容',
                    style: TextStyle(color: t.amber, fontSize: 12, height: 1.4),
                  ),
                ],
              ),
            ),
        ],
      ),
      slivers: <Widget>[
        if (query.isEmpty)
          emptyState(context, '输入关键词搜索正文内容')
        else if (_searching)
          emptyState(context, '正在搜索…')
        else if (hits.isEmpty)
          emptyState(
            context,
            whole ? '全书没有找到' : '读到这里的部分没有找到。要搜全书吗？',
            action: whole
                ? null
                : Pill(
                    label: '搜全书',
                    onTap: () {
                      HapticFeedback.lightImpact();
                      whole = true;
                      _scheduleSearch();
                    },
                  ),
          )
        else
          SliverList.list(children: rows),
      ],
    );
  }
}
