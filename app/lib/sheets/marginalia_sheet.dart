import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:thusfar_core/llm.dart' as llm;
import 'package:thusfar_core/marginalia.dart';
import 'package:thusfar_core/thusfar_core.dart' show PyException;

import '../data/model_settings.dart';
import '../screens/model_settings_screen.dart';
import '../ui/theme.dart';
import 'common.dart';
import 'sheet_host.dart';

final MarginaliaService _readerComments = MarginaliaService();

/// Comments are verified before display and stored independently of notes.
class MarginaliaPage extends StatefulWidget {
  const MarginaliaPage({
    super.key,
    required this.link,
    required this.start,
    required this.end,
    this.pageMode = false,
    this.service,
  });
  final ReaderLink link;
  final int start, end;
  final bool pageMode;
  final MarginaliaService? service;
  @override
  State<MarginaliaPage> createState() => _MarginaliaPageState();
}

class _MarginaliaPageState extends State<MarginaliaPage> {
  late int _cutoff = widget.link.c.cutoff;
  late int _start = widget.start, _end = widget.end;
  String _persona = 'empathy', _stage = '';
  String _lastMode = 'manual';
  Json? _lastSelection;
  String? _error;
  bool _busy = false, _stale = false, _showCues = false;
  Json? _result;
  MarginaliaCancellation? _token;
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    widget.link.c.addListener(_positionChanged);
  }

  @override
  void dispose() {
    widget.link.c.removeListener(_positionChanged);
    _token?.cancel();
    super.dispose();
  }

  void _positionChanged() {
    if (widget.link.c.cutoff == _cutoff) return;
    _token?.cancel();
    _generation++;
    setState(() {
      _cutoff = widget.link.c.cutoff;
      _stale = true;
      _busy = false;
      _result = null;
      _error = null;
    });
  }

  Future<void> _request(String mode, {Json? selection}) async {
    if (_busy || _stale) return;
    final int start =
            selection?['start'] as int? ??
            (mode == 'cues' ? widget.start : _start),
        end = selection?['end'] as int? ?? (mode == 'cues' ? widget.end : _end);
    final String persona = selection?['persona'] as String? ?? _persona;
    final Json payload = {
      'mode': mode,
      'pos': _cutoff,
      'persona': persona,
      if (mode == 'manual') ...{
        'start': start,
        'end': end,
      } else ...{
        'page_start': start,
        'page_end': end,
      },
    };
    _lastMode = mode;
    _lastSelection = selection;
    final int generation = ++_generation;
    final MarginaliaCancellation token = MarginaliaCancellation();
    _token = token;
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _stage = mode == 'cues' ? '正在挑选本页的句子' : '正在写一句读者评论';
    });
    try {
      final Json result = await (widget.service ?? _readerComments).respond(
        widget.link.c.book.entry.dir,
        payload,
        cancellation: token,
        onEvent: (stage) {
          if (mounted && generation == _generation && !token.isCancelled) {
            setState(() => _stage = stage);
          }
        },
      );
      if (!mounted ||
          generation != _generation ||
          token.isCancelled ||
          _cutoff != widget.link.c.cutoff) {
        return;
      }
      setState(() {
        _result = result;
        _showCues = mode == 'cues';
        if (mode != 'cues') {
          _start = start;
          _end = end;
        }
      });
    } on Object catch (e) {
      if (mounted && generation == _generation && !token.isCancelled) {
        setState(
          () => _error = e is PyException
              ? e.message
              : llm.explain(e) ?? '这次没有完成批注，请稍后重试。',
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() {
          _busy = false;
          _token = null;
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

  void _cancel() {
    _token?.cancel();
    _generation++;
    setState(() {
      _busy = false;
      _token = null;
      _stage = '';
    });
  }

  Widget _button(String text, VoidCallback on, {String? key}) => FilledButton(
    onPressed: _busy || _stale
        ? null
        : () {
            HapticFeedback.lightImpact();
            on();
          },
    key: key == null ? null : ValueKey<String>(key),
    child: Text(text),
  );
  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final int page = widget.link.pageNo(_cutoff > 0 ? _cutoff - 1 : 0);
    final String quote = widget.link.c.book.textBetween(_start, _end);
    final List<Json> items = _result?['items'] is List
        ? (_result!['items']! as List<Object?>).cast<Json>()
        : _result == null
        ? []
        : [_result!];
    return SheetPage(
      title: '页边批注',
      tag: '只读到第 $page 页',
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Text(
              widget.pageMode ? '从眼前的句子出发，听听几种读者视角。' : '选一个角度，给这句话留一句读者评论。',
              style: TextStyle(color: t.ink2, fontSize: 14, height: 1.6),
            ),
          ),
        ),
        if (_stale)
          emptyState(context, '阅读位置已改变，请回到原文重新选择。')
        else ...[
          SliverToBoxAdapter(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: t.paper,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                quote,
                key: const ValueKey<String>('marginalia-quote'),
                maxLines: widget.pageMode ? 5 : 8,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: serif,
                  color: t.ink2,
                  fontSize: 15,
                  height: 1.65,
                ),
              ),
            ),
          ),
          if (!widget.pageMode)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final entry in personas.entries)
                      ChoiceChip(
                        label: Text(entry.value[0]),
                        selected: _persona == entry.key,
                        onSelected: _busy
                            ? null
                            : (_) {
                                HapticFeedback.selectionClick();
                                setState(() {
                                  _persona = entry.key;
                                  _result = null;
                                  _error = null;
                                });
                              },
                      ),
                  ],
                ),
              ),
            ),
          if (_busy)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _stage,
                        key: const ValueKey<String>('marginalia-stage'),
                      ),
                    ),
                    TextButton(onPressed: _cancel, child: const Text('停止')),
                  ],
                ),
              ),
            ),
          if (_error != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _error!,
                      key: const ValueKey<String>('marginalia-error'),
                      style: TextStyle(color: t.danger, height: 1.6),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      children: [
                        TextButton(
                          onPressed: () =>
                              _request(_lastMode, selection: _lastSelection),
                          child: const Text('重试'),
                        ),
                        TextButton(
                          onPressed: _settings,
                          child: const Text('模型设置'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (_result != null && _showCues && items.isEmpty)
            emptyState(context, '这一页暂时没有特别适合评论的句子，继续读也很好。'),
          for (final Json item in items)
            SliverToBoxAdapter(
              child: _showCues
                  ? ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 8,
                      ),
                      title: Text(
                        '${item['quote']}',
                        style: TextStyle(
                          fontFamily: serif,
                          fontSize: 15,
                          height: 1.6,
                        ),
                      ),
                      subtitle: Text(
                        '${personas[item['persona']]?.first ?? '读者'}视角',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy
                          ? null
                          : () => _request('auto', selection: item),
                    )
                  : _comment(context, item),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (widget.pageMode)
                    _button(
                      _result != null ? '重新查看本页句子' : '找出可讨论的句子',
                      () => _request('cues'),
                      key: 'marginalia-generate',
                    )
                  else ...[
                    _button(
                      _result == null ? '生成批注' : '查看这个角度',
                      () => _request('manual'),
                      key: 'marginalia-generate',
                    ),
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () {
                              HapticFeedback.lightImpact();
                              _request('auto');
                            },
                      child: const Text('看看不同角度'),
                    ),
                  ],
                  TextButton(
                    onPressed: _busy ? null : _settings,
                    child: const Text('模型设置'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _comment(BuildContext context, Json item) {
    final Tokens t = context.tk;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.paper,
        border: Border.all(color: t.rule.withValues(alpha: 0.8)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: t.zhu,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${personas[item['persona']]?.first ?? '读者'} · 已核对原文',
                style: TextStyle(color: t.ink3, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SelectableText(
            '${item['comment']}',
            style: TextStyle(color: t.ink, fontSize: 16, height: 1.65),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () {
                  HapticFeedback.lightImpact();
                  widget.link.jump(
                    item['start']! as int,
                    highlight: (item['start']! as int, item['end']! as int),
                  );
                },
                child: const Text('回到原句'),
              ),
              IconButton(
                tooltip: '复制批注',
                onPressed: () {
                  HapticFeedback.lightImpact();
                  Clipboard.setData(ClipboardData(text: '${item['comment']}'));
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('已复制批注')));
                },
                icon: const Icon(Icons.copy_outlined, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
