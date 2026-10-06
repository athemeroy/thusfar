import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/library.dart';
import '../data/reader_directory.dart';
import '../data/seen.dart';
import '../ui/theme.dart';
import 'chapter_title.dart';
import 'common.dart';
import 'sheet_host.dart';
import 'toc_search.dart';

/// A separate drawer page keeps the directory's position and existing page
/// jump intact when readers search, cancel, and search again.
class TocSearchPage extends StatefulWidget {
  const TocSearchPage({super.key, required this.link});

  final ReaderLink link;

  @override
  State<TocSearchPage> createState() => _TocSearchPageState();
}

class _TocSearchPageState extends State<TocSearchPage> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  bool _byOrdinal = false;
  String _query = '';
  int? _confirm;

  @override
  void initState() {
    super.initState();
    _input.addListener(_inputChanged);
  }

  @override
  void dispose() {
    _input.removeListener(_inputChanged);
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _inputChanged() {
    if (_input.value.composing.isValid && !_input.value.composing.isCollapsed) {
      return;
    }
    final String value = _input.text.trim();
    if (value == _query) return;
    setState(() {
      _query = value;
      _confirm = null;
    });
    _resetScroll();
  }

  void _resetScroll() {
    // Each search starts at its first result, including after a long list was
    // scrolled. This does not touch the underlying reader or directory position.
    final ScrollController scroll = SheetScope.of(context).scroll;
    if (scroll.hasClients) scroll.jumpTo(0);
  }

  void _changeMode(int mode) {
    if (_byOrdinal == (mode == 1)) return;
    setState(() {
      _byOrdinal = mode == 1;
      _confirm = null;
    });
    _input.clear();
    _resetScroll();
  }

  void _locateCurrent() {
    setState(() {
      _byOrdinal = true;
      _confirm = null;
    });
    _input.text =
        '${widget.link.c.book.directory.chapterAt(widget.link.c.start) + 1}';
    _focus.unfocus();
    _resetScroll();
  }

  void _select(Chapter chapter) {
    final ReaderLink link = widget.link;
    final int read = SeenStore.instance.maxRead(link.c.book.id, link.c.cutoff);
    HapticFeedback.lightImpact();
    if (chapter.o0 < read) {
      link.jump(chapter.o0);
    } else {
      _focus.unfocus();
      setState(() {
        _confirm = _confirm == chapter.index ? null : chapter.index;
      });
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[
      widget.link.c,
      widget.link.c.book.directory,
    ]),
    builder: (BuildContext context, _) {
      final ReaderLink link = widget.link;
      final BookData book = link.c.book;
      final Tokens t = context.tk;
      final TextScaler scaler = MediaQuery.textScalerOf(context);
      final int read = SeenStore.instance.maxRead(book.id, link.c.cutoff);
      final bool pending = book.status.titleCheckPending;
      final Chapter? numbered = _byOrdinal
          ? tocChapterAtOrdinal(book.directory.chapters, _query)
          : null;
      final List<Chapter> hits = _byOrdinal
          ? <Chapter>[?numbered]
          : findTocChapters(
              book.directory.chapters,
              _query,
              readTo: read,
              checkPending: pending,
            );
      final Segmented modes = Segmented(
        labels: const <String>['标题搜索', '章节序号'],
        index: _byOrdinal ? 1 : 0,
        onChanged: _changeMode,
      );
      final double inputHeight = math.max(48, scaler.scale(16) * 1.6 + 16);
      return SheetPage(
        title: '查找章节',
        headerExtraHeight:
            modes.heightForWidth(context, MediaQuery.sizeOf(context).width) +
            inputHeight +
            12,
        headerExtra: Column(
          children: <Widget>[
            modes,
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: SizedBox(
                height: inputHeight,
                child: TextField(
                  key: const ValueKey<String>('toc-search-input'),
                  controller: _input,
                  focusNode: _focus,
                  keyboardType: _byOrdinal
                      ? TextInputType.number
                      : TextInputType.text,
                  textInputAction: _byOrdinal
                      ? TextInputAction.go
                      : TextInputAction.search,
                  // Keep pasted invalid input intact so validation cannot turn
                  // e.g. "1.5" into an unintended jump to entry 15.
                  autocorrect: !_byOrdinal,
                  enableSuggestions: !_byOrdinal,
                  onSubmitted: (_) {
                    if (!_byOrdinal) return;
                    final Chapter? target = tocChapterAtOrdinal(
                      book.directory.chapters,
                      _input.text,
                    );
                    if (target != null) _select(target);
                  },
                  decoration: InputDecoration(
                    hintText: _byOrdinal
                        ? '输入 1–${book.directory.chapters.length} 的序号'
                        : '输入目录中的标题',
                    filled: true,
                    fillColor: t.paper,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: _input.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清空章节查找',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () {
                              _input.clear();
                              _focus.requestFocus();
                            },
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
        slivers: <Widget>[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
              child: Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                children: <Widget>[
                  Text(
                    _query.isEmpty
                        ? '共 ${book.directory.chapters.length} 项'
                        : '找到 ${hits.length} 项',
                    style: TextStyle(fontSize: 13, color: t.ink3),
                  ),
                  TextButton.icon(
                    onPressed: book.directory.chapters.isEmpty
                        ? null
                        : _locateCurrent,
                    icon: const Icon(Icons.my_location, size: 18),
                    label: const Text('定位当前章节'),
                  ),
                ],
              ),
            ),
          ),
          if (_byOrdinal)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  '序号按目录顺序计数，包含前言、分卷等条目',
                  style: TextStyle(fontSize: 13, height: 1.5, color: t.ink3),
                ),
              ),
            ),
          if (hits.isEmpty)
            emptyState(
              context,
              book.directory.chapters.isEmpty
                  ? '这本书还没有目录'
                  : _query.isEmpty
                  ? (_byOrdinal ? '输入序号定位章节' : '输入标题查找章节；隐藏的标题不会参与搜索')
                  : _byOrdinal
                  ? '请输入 1–${book.directory.chapters.length} 之间的序号'
                  : '没有找到章节，试试标题中的其他字',
            )
          else
            SliverList.builder(
              itemCount: hits.length,
              itemBuilder: (BuildContext context, int index) {
                final Chapter chapter = hits[index];
                final bool current =
                    chapter.index == book.directory.chapterAt(link.c.start);
                return Column(
                  key: ValueKey<String>('toc-search-result-${chapter.index}'),
                  children: <Widget>[
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                      ),
                      selected: current,
                      selectedColor: t.zhu,
                      title: Text(
                        safeTitle(
                          chapter,
                          tocTitleRead(chapter, read),
                          checkPending: pending,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15, height: 1.4),
                      ),
                      subtitle: Text(
                        '目录第 ${chapter.index + 1} 项${current ? ' · 当前章节' : ''}',
                        style: TextStyle(fontSize: 12, color: t.ink3),
                      ),
                      onTap: () => _select(chapter),
                    ),
                    if (_confirm == chapter.index)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                        child: Wrap(
                          alignment: WrapAlignment.end,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 8,
                          children: <Widget>[
                            Text(
                              '会看到后面的内容',
                              style: TextStyle(fontSize: 13, color: t.amber),
                            ),
                            TextButton(
                              onPressed: () => setState(() => _confirm = null),
                              child: const Text('取消'),
                            ),
                            FilledButton(
                              onPressed: () {
                                HapticFeedback.lightImpact();
                                link.jump(chapter.o0);
                              },
                              child: const Text('跳过去'),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      );
    },
  );
}
