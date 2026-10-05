import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:thusfar_core/ask.dart';
import 'package:thusfar_core/llm.dart' as llm;

import '../data/model_settings.dart';
import '../screens/model_settings_screen.dart';
import '../ui/theme.dart';
import 'common.dart';
import 'sheet_host.dart';

final AskService _readerQuestions = AskService(maxConcurrent: 1);
final Expando<_AskSession> _readerSessions = Expando<_AskSession>();

// Tied to the live reader, never persisted or shared with another book.
class _AskSession extends ChangeNotifier {
  _AskSnapshot? snapshot;
  AskCancellation? request;

  void settled(AskCancellation token) {
    if (!identical(request, token)) return;
    request = null;
    notifyListeners();
  }
}

class _AskSnapshot {
  const _AskSnapshot(
    this.cutoff,
    this.history,
    this.draft,
    this.quote,
    this.quoteVisible,
    this.scrollOffset,
  );
  final int cutoff;
  final List<_Exchange> history;
  final String draft;
  final String? quote;
  final bool quoteVisible;
  final double scrollOffset;
}

/// S12: each request and its citations belong to one captured reading prefix.
class AskPage extends StatefulWidget {
  const AskPage({
    super.key,
    required this.link,
    this.prefill,
    this.quote,
    this.selectedStart,
    this.selectedEnd,
    this.restoreDraft = false,
    this.service,
  });

  final ReaderLink link;
  final String? prefill;
  final String? quote;
  final int? selectedStart;
  final int? selectedEnd;

  /// Explicit source-return flow; a newly selected excerpt otherwise wins.
  final bool restoreDraft;
  final AskService? service;

  @override
  State<AskPage> createState() => _AskPageState();
}

class _Exchange {
  _Exchange(this.question, this.position, this.quote);
  final String? quote;
  List<AskTurn> references = const <AskTurn>[];
  final String question;
  final int position;
  String stage = '理解你的问题';
  String? error;
  Json? answer;
}

class _AskPageState extends State<AskPage> {
  late final TextEditingController _input = TextEditingController(
    text: widget.prefill,
  );
  final List<_Exchange> _history = <_Exchange>[];
  AskCancellation? _request;
  late final _AskSession _session;
  double? _restoreOffset;
  double _scrollOffset = 0;

  void _recordScroll() {
    if (_scroll?.hasClients == true) _scrollOffset = _scroll!.offset;
  }

  late int _cutoff = widget.link.c.cutoff;
  bool _busy = false;
  bool _stopping = false;
  bool _newAnswer = false;
  String? _inputError;
  String? _editedQuote;
  ScrollController? _scroll;
  bool _quoteVisible = true;
  int _generation = 0;
  int _scrollRequest = 0;

  @override
  void initState() {
    super.initState();
    widget.link.c.addListener(_positionChanged);
    _session = _readerSessions[widget.link.c] ??= _AskSession();
    _session.addListener(_connectionChanged);
    _request = _session.request;
    _busy = _request != null;
    _stopping = _busy;
    final _AskSnapshot? snapshot = _session.snapshot;
    if (snapshot != null && snapshot.cutoff == _cutoff) {
      _history.addAll(snapshot.history);
      final bool newPrompt =
          !widget.restoreDraft &&
          (widget.prefill != null || widget.quote != null);
      if (!newPrompt) {
        _input.text = snapshot.draft;
        _editedQuote = snapshot.quote;
        _quoteVisible = snapshot.quoteVisible;
        _restoreOffset = snapshot.scrollOffset;
        _scrollOffset = snapshot.scrollOffset;
      }
    }
  }

  void _connectionChanged() {
    if (!mounted || _session.request != null) return;
    setState(() {
      _request = null;
      _busy = false;
      _stopping = false;
    });
  }

  void _remember() {
    if (_history.isEmpty && _input.text.isEmpty) return;
    for (final _Exchange entry in _history) {
      if (entry.answer == null && entry.error == null) {
        entry.error = '回答已停止；可重试原题。已发生的费用可能无法取消。';
      }
    }
    _session.snapshot = _AskSnapshot(
      _cutoff,
      _history.skip(math.max(0, _history.length - 24)).toList(),
      _input.text,
      _editedQuote,
      _quoteVisible,
      _scroll?.hasClients == true ? _scroll!.offset : _scrollOffset,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scroll?.removeListener(_recordScroll);
    _scroll = SheetScope.of(context).scroll;
    _scroll!.addListener(_recordScroll);
    final double? offset = _restoreOffset;
    if (offset != null) {
      _restoreOffset = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _scroll?.hasClients != true) return;
        _scroll!.jumpTo(offset.clamp(0, _scroll!.position.maxScrollExtent));
      });
    }
  }

  bool get _atBottom =>
      _scroll?.hasClients != true || _scroll!.position.extentAfter < 120;

  void _showLatest({bool force = false}) {
    if (!force && !_atBottom) {
      setState(() => _newAnswer = true);
      return;
    }
    final int request = ++_scrollRequest;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_newAnswer && mounted) setState(() => _newAnswer = false);
      while (mounted &&
          request == _scrollRequest &&
          _scroll?.hasClients == true) {
        final ScrollController scroll = _scroll!;
        final double target = scroll.position.maxScrollExtent;
        await scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
        if (!mounted || request != _scrollRequest || !scroll.hasClients) return;
        // Lazy slivers can discover the appended row during the animation.
        // Correct only if the reader has not interrupted the requested scroll.
        if ((scroll.offset - target).abs() > 1 ||
            scroll.position.maxScrollExtent - target < 1) {
          return;
        }
      }
    });
  }

  void _stop() {
    if (_request == null || _stopping) return;
    _request!.cancel();
    _generation++;
    setState(() {
      _stopping = true;
      if (_history.isNotEmpty && _history.last.answer == null) {
        _history.last.error = '已停止显示回答。等待当前连接结束后可发送下一问；已发生的费用可能无法取消。';
      }
    });
  }

  @override
  void dispose() {
    _remember();
    _scroll?.removeListener(_recordScroll);
    _generation++;
    widget.link.c.removeListener(_positionChanged);
    _session.removeListener(_connectionChanged);
    _request?.cancel();
    _input.dispose();
    super.dispose();
  }

  void _positionChanged() {
    final int next = widget.link.c.cutoff;
    if (next == _cutoff) return;
    _remember();
    _request?.cancel();
    _generation++;
    setState(() {
      _cutoff = next;
      _stopping = _request != null;
      _history.clear();
      _editedQuote = null;
      _input.clear();
      _quoteVisible = false;
    });
  }

  Future<void> _submit({_Exchange? retry}) async {
    if (_busy) return;
    HapticFeedback.lightImpact();
    final String q = retry?.question ?? _input.text.trim();
    final String? quote =
        retry?.quote ?? _editedQuote ?? (_quoteVisible ? widget.quote : null);
    final String? invalid = validateAskInput(q, selection: quote);
    if (invalid != null) {
      setState(() => _inputError = invalid);
      return;
    }
    final _Exchange entry = retry ?? _Exchange(q, _cutoff, quote);
    if (entry.position != widget.link.c.cutoff) return;
    final List<AskTurn> references =
        retry?.references ??
        <AskTurn>[
          for (final _Exchange previous in _history)
            if (previous != retry &&
                previous.answer != null &&
                (previous.answer!['guard'] as Json?)?['verdict'] != 'withheld')
              AskTurn(
                bookId: widget.link.c.book.entry.dir.absolute.path,
                cutoff: previous.position,
                question: previous.question,
                answer: previous.answer!['text']! as String,
              ),
        ];
    entry.references = references;
    final AskCancellation token = AskCancellation();
    final int generation = ++_generation;
    _request = token;
    _session.request = token;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _stopping = false;
      _inputError = null;
      entry.error = null;
      entry.answer = null;
      entry.stage = '理解你的问题';
      if (retry == null) _history.add(entry);
      if (retry == null) {
        _input.clear();
        _editedQuote = null;
      }
      _quoteVisible = false;
    });
    _showLatest(force: true);
    try {
      final Json answer = await (widget.service ?? _readerQuestions).answer(
        widget.link.c.book.entry.dir,
        q,
        entry.position,
        cancellation: token,
        history: references,
        selectedText: entry.quote,
        onSettled: () {
          _session.settled(token);
          if (!mounted || !identical(_request, token)) return;
          setState(() {
            _busy = false;
            _stopping = false;
            _request = null;
          });
        },
        onEvent: (String kind, Json value) {
          if (!mounted ||
              generation != _generation ||
              entry.position != widget.link.c.cutoff) {
            return;
          }
          if (kind == 'stage') {
            setState(() => entry.stage = value['text']! as String);
          }
        },
      );
      if (!mounted ||
          generation != _generation ||
          entry.position != widget.link.c.cutoff) {
        return;
      }
      setState(() => entry.answer = answer);
      _showLatest();
    } on Object catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() => entry.error = llm.explain(e) ?? '这次没能完成回答，请稍后重试。');
      _showLatest();
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          // onSettled owns release: timeout/cancel can precede transport end.
          _stopping = _request != null;
        });
      }
    }
  }

  Future<void> _settings() async {
    final ModelSettings settings = ModelSettings(
      File('${widget.link.c.library.root.path}/.model.env'),
    );
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ModelSettingsScreen(settings: settings),
      ),
    );
    applyModelEnvironment(settings);
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final int page = widget.link.pageNo(_cutoff > 0 ? _cutoff - 1 : 0);
    return SheetPage(
      title: '问问这本书',
      tag: '只用前 $page 页 · 最近3轮追问',
      slivers: <Widget>[
        if (_quoteVisible && widget.quote != null)
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: t.paper,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '所选原文（最多 $askSelectionLimit 字）\n${widget.quote!}',
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
        if (_history.isEmpty) ...<Widget>[
          emptyState(context, '想问人物、关系，或刚读到的情节？\n回答只参考你读过的原文，出处可以点开。'),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final String q in <String>[
                    '刚才发生了什么？',
                    '这里有哪些人物？',
                    '他们之间是什么关系？',
                    '这段话是什么意思？',
                  ])
                    ActionChip(
                      label: Text(q),
                      onPressed: () {
                        HapticFeedback.selectionClick();
                        setState(() => _input.text = q);
                      },
                    ),
                ],
              ),
            ),
          ),
        ],
        if (_inputError != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_inputError!, style: TextStyle(color: t.danger)),
            ),
          ),
        if (_quoteVisible && widget.quote != null)
          SliverToBoxAdapter(
            child: TextButton(
              onPressed: () => setState(() {
                _quoteVisible = false;
                _inputError = null;
              }),
              child: const Text('移除所选原文'),
            ),
          ),
        if (_editedQuote != null)
          SliverToBoxAdapter(
            child: TextButton(
              onPressed: () => setState(() => _editedQuote = null),
              child: const Text('已恢复原选文 · 点击移除'),
            ),
          ),
        for (final _Exchange entry in _history)
          SliverToBoxAdapter(child: _exchange(context, entry)),
      ],
      bottom: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (_newAnswer)
              TextButton(
                onPressed: () => _showLatest(force: true),
                child: const Text('查看新回答'),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: TextField(
                    key: const ValueKey<String>('ask-input'),
                    controller: _input,
                    enabled: true,
                    minLines: 1,
                    maxLines: 3,
                    maxLength: askQuestionLimit,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _submit(),
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: _busy ? '可以先写下一问，连接结束后发送…' : '问问已经读过的内容…',
                      filled: true,
                      fillColor: t.paper,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                      suffixIcon: _input.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              tooltip: '清空',
                              onPressed: () {
                                HapticFeedback.selectionClick();
                                _input.clear();
                                setState(() {});
                              },
                            )
                          : null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  key: const ValueKey<String>('ask-send'),
                  tooltip: _busy
                      ? (_stopping ? '正在结束连接' : '停止当前回答')
                      : '发送问题（可能收费）',
                  onPressed: _busy
                      ? (_stopping ? null : _stop)
                      : _input.text.trim().isEmpty
                      ? null
                      : () => _submit(),
                  icon: Icon(_busy ? Icons.stop : Icons.arrow_upward),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _previewCitation(_Exchange entry, Json cite) async {
    final int start = cite['o']! as int;
    final int end = math.min(entry.position, start + 1200);
    if (entry.position != widget.link.c.cutoff || start >= end) return;
    final String source = widget.link.c.book.textBetween(start, end);
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialog) => AnimatedBuilder(
        animation: widget.link.c,
        builder: (BuildContext context, Widget? child) {
          final bool safe = entry.position == widget.link.c.cutoff;
          return AlertDialog(
            title: Text(
              safe ? '原文出处 · 第 ${widget.link.pageNo(start)} 页' : '阅读位置已改变',
            ),
            content: SingleChildScrollView(
              child: safe
                  ? SelectableText(source)
                  : const Text('已隐藏之前位置的原文和回答。'),
            ),
            actions: <Widget>[
              if (safe)
                TextButton(
                  onPressed: () {
                    if (entry.position != widget.link.c.cutoff) return;
                    _remember();
                    widget.link.c.returnToAsk = true;
                    Navigator.pop(dialog);
                    widget.link.jump(
                      start,
                      highlight: (
                        start,
                        math.min(
                          entry.position,
                          start + (cite['text']! as String).length,
                        ),
                      ),
                    );
                  },
                  child: const Text('定位原文（可返回回答）'),
                ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog),
                child: Text(safe ? '返回这条回答' : '返回问书'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _exchange(BuildContext context, _Exchange entry) {
    final Tokens t = context.tk;
    final Json? answer = entry.answer;
    final List<Json> cites =
        ((answer?['cites'] as List<Object?>?) ?? <Object?>[]).cast<Json>();
    final bool withheld = (answer?['guard'] as Json?)?['verdict'] == 'withheld';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: t.paper,
                borderRadius: BorderRadius.circular(14),
              ),
              child: SelectableText(
                entry.quote == null
                    ? entry.question
                    : '所选原文：${entry.quote}\n\n${entry.question}',
                style: TextStyle(color: t.ink, height: 1.5),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (answer != null) ...<Widget>[
            SelectableText(
              answer['text']! as String,
              style: TextStyle(
                fontFamily: serif,
                fontSize: 16,
                height: 1.7,
                color: t.ink,
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: '复制回答',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy_outlined, size: 16),
                onPressed: () {
                  HapticFeedback.lightImpact();
                  Clipboard.setData(
                    ClipboardData(text: answer['text']! as String),
                  );
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('已复制回答')));
                },
              ),
            ),
            if (cites.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '原文出处',
                  style: TextStyle(fontSize: 12, color: t.ink3),
                ),
              ),
            for (final Json cite in cites)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: InkWell(
                  key: ValueKey<String>('ask-cite-${cite['n']}'),
                  onTap: () => _previewCitation(entry, cite),
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      color: t.paper,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: t.ink.withValues(alpha: 0.08)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Container(
                          margin: const EdgeInsets.only(top: 2),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: t.zhu.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${cite['n']}',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: t.zhu,
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '第 ${widget.link.pageNo(cite['o']! as int)} 页 · ${cite['text']}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: t.ink2,
                              height: 1.5,
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (answer['cached'] == true)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '已保存的回答 · 同一阅读位置',
                  style: TextStyle(fontSize: 12, color: t.ink3),
                ),
              ),
          ] else if (entry.error != null)
            Text(entry.error!, style: TextStyle(color: t.danger, height: 1.6))
          else
            Row(
              children: <Widget>[
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: t.ink3,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    entry.stage,
                    style: TextStyle(color: t.ink3, fontSize: 14),
                  ),
                ),
              ],
            ),
          if (entry.error != null || withheld)
            Wrap(
              spacing: 8,
              children: <Widget>[
                TextButton(
                  onPressed: _busy
                      ? null
                      : () {
                          HapticFeedback.lightImpact();
                          _submit(retry: entry);
                        },
                  child: const Text('重试原题（可能再次收费）'),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _input.text = entry.question;
                    _editedQuote = entry.quote;
                    _inputError = null;
                  }),
                  child: const Text('编辑问题'),
                ),
                if (entry.error != null)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () {
                            HapticFeedback.lightImpact();
                            _settings();
                          },
                    child: const Text('模型设置'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
