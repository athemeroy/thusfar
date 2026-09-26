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

final AskService _readerQuestions = AskService();

/// S12: each request and its citations belong to one captured reading prefix.
class AskPage extends StatefulWidget {
  const AskPage({
    super.key,
    required this.link,
    this.prefill,
    this.quote,
    this.service,
  });

  final ReaderLink link;
  final String? prefill;
  final String? quote;
  final AskService? service;

  @override
  State<AskPage> createState() => _AskPageState();
}

class _Exchange {
  _Exchange(this.question, this.position);
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
  late int _cutoff = widget.link.c.cutoff;
  bool _busy = false;
  bool _quoteVisible = true;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget.link.c.addListener(_positionChanged);
  }

  @override
  void dispose() {
    widget.link.c.removeListener(_positionChanged);
    _request?.cancel();
    _input.dispose();
    super.dispose();
  }

  void _positionChanged() {
    final int next = widget.link.c.cutoff;
    if (next == _cutoff) return;
    _request?.cancel();
    _generation++;
    setState(() {
      _cutoff = next;
      _busy = false;
      _history.clear();
      _quoteVisible = false;
    });
  }

  Future<void> _submit({_Exchange? retry}) async {
    if (_busy) return;
    HapticFeedback.lightImpact();
    final String input = _input.text.trim();
    final String draft =
        retry?.question ??
        (_quoteVisible && widget.quote != null && input.isNotEmpty
            ? '关于「${String.fromCharCodes(widget.quote!.runes.take(180))}」：$input'
            : input);
    if (draft.isEmpty) return;
    final String q = String.fromCharCodes(draft.runes.take(500));
    final _Exchange entry = retry ?? _Exchange(q, _cutoff);
    if (entry.position != widget.link.c.cutoff) return;
    final AskCancellation token = AskCancellation();
    final int generation = ++_generation;
    _request = token;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      entry.error = null;
      entry.answer = null;
      entry.stage = '理解你的问题';
      if (retry == null) _history.add(entry);
      _input.clear();
    });
    try {
      final Json answer = await (widget.service ?? _readerQuestions).answer(
        widget.link.c.book.entry.dir,
        q,
        entry.position,
        cancellation: token,
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
    } on Object catch (e) {
      if (!mounted || generation != _generation) return;
      setState(() => entry.error = llm.explain(e) ?? '这次没能完成回答，请稍后重试。');
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _busy = false;
          _request = null;
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
      tag: '只用前 $page 页回答',
      slivers: <Widget>[
        if (_quoteVisible && widget.quote != null && _history.isEmpty)
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: t.paper,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                widget.quote!,
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
        for (final _Exchange entry in _history)
          SliverToBoxAdapter(child: _exchange(context, entry)),
      ],
      bottom: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const ValueKey<String>('ask-input'),
                controller: _input,
                enabled: !_busy,
                minLines: 1,
                maxLines: 3,
                maxLength: 500,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _submit(),
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: '问问已经读过的内容…',
                  counterText: '',
                  filled: true,
                  fillColor: t.paper,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              key: const ValueKey<String>('ask-send'),
              tooltip: '发送问题',
              onPressed: _busy || _input.text.trim().isEmpty
                  ? null
                  : () => _submit(),
              icon: const Icon(Icons.arrow_upward),
            ),
          ],
        ),
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
              child: Text(
                entry.question,
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
            if (cites.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
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
                  onTap: () {
                    final int start = cite['o']! as int;
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
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: t.paper,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '[${cite['n']}] 第 ${widget.link.pageNo(cite['o']! as int)} 页 · ${cite['text']}',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: t.ink2,
                        height: 1.5,
                      ),
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
                  onPressed: _busy ? null : () => _submit(retry: entry),
                  child: const Text('重试'),
                ),
                if (entry.error != null)
                  TextButton(
                    onPressed: _busy ? null : _settings,
                    child: const Text('模型设置'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
