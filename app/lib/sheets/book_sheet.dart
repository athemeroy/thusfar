import 'dart:io';

import 'package:flutter/material.dart';
import 'package:thusfar_core/models.dart' as models;
import 'package:thusfar_core/llm.dart' as llm;

import '../data/library.dart';
import '../data/model_settings.dart';
import '../data/processing.dart';
import '../ui/cover.dart';
import '../ui/theme.dart';
import 'sheet_host.dart';

/// S02 书籍抽屉: everything about one book, above all its processing.
class BookSheet extends StatefulWidget {
  const BookSheet({
    super.key,
    required this.library,
    required this.entry,
    required this.settings,
    required this.processing,
    this.onRemoved,
    required this.onRead,
    required this.onModelSettings,
    required this.onExport,
    this.focusProcessing = false,
  });

  final Library library;
  final BookEntry entry;
  final ModelSettings settings;
  final BookProcessing processing;
  final VoidCallback? onRemoved;
  final VoidCallback onRead;
  final Future<void> Function() onModelSettings;
  final Future<void> Function() onExport;
  final bool focusProcessing;

  static Future<void> open(BuildContext context, BookSheet sheet) =>
      openSheet<void>(
        context,
        sheet,
        initial: sheet.focusProcessing ? 0.92 : 0.6,
      );

  @override
  State<BookSheet> createState() => _BookSheetState();
}

class _BookSheetState extends State<BookSheet> {
  bool confirmStart = false;
  bool confirmRemove = false;
  bool missingKey = false;
  String? engineNote;
  bool acting = false;
  String? actionLabel;

  @override
  void initState() {
    super.initState();
    widget.library.addListener(_changed);
    widget.processing.addListener(_changed);
  }

  @override
  void dispose() {
    widget.library.removeListener(_changed);
    widget.processing.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _action(String label, Future<void> Function() run) async {
    if (acting) return;
    setState(() {
      acting = true;
      actionLabel = label;
      engineNote = null;
      confirmStart = false;
    });
    try {
      await run();
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => engineNote =
              llm.explain(error) ??
              (error is StateError ? error.message : '整理操作没有完成，请稍后重试。'),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          acting = false;
          actionLabel = null;
        });
      }
    }
  }

  Future<void> _start() async {
    if (!widget.settings.hasKey) {
      setState(() => missingKey = true);
      return;
    }
    await _action('正在开始整理…', () => widget.processing.startBook(widget.entry));
  }

  Future<void> _pause() => _action(
    '正在暂停，等待当前步骤结束…',
    () => widget.processing.pauseBook(widget.entry),
  );

  Future<void> _remove() => _action('正在停止整理，完成后移除…', () async {
    await widget.processing.prepareRemoval(widget.entry);
    widget.library.refreshStatus(widget.entry);
    if (widget.entry.status.isActive) throw StateError('这本书仍在停止整理，完成后才能移除。');
    await widget.library.remove(widget.entry);
    if (mounted) Navigator.of(context).pop();
    // The user can dismiss this drawer while cancellation settles. Its reader
    // must still close after removal, even when the drawer is already gone.
    widget.onRemoved?.call();
  });

  int _noteCount() {
    final List<Object?> raw =
        (readJson(File('${widget.entry.dir.path}/notebook.json'))
            as List<Object?>?) ??
        const <Object?>[];
    return raw.where((Object? x) => x is Json && x['deleted'] != true).length;
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final BookEntry b = widget.entry;
    final Progress? p = widget.library.progressOf(b.id);
    final int pct = (p?.pct ?? 0).round();
    final int queue = widget.library.readingList.indexOf(b.id);
    final String chars = b.length >= 10000
        ? '${(b.length / 10000).toStringAsFixed(1)} 万字'
        : '${b.length} 字';
    return SheetPage(
      title: b.title,
      titleWidget: Text(
        b.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontFamily: display, fontSize: 20, color: t.ink),
      ),
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Row(
              children: <Widget>[
                BookCover(entry: b, width: 56),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    '${b.author.isEmpty ? '佚名' : b.author} · $chars · 读到 $pct%',
                    style: TextStyle(fontSize: 13, color: t.ink2),
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SizedBox(
              width: double.infinity,
              child: Pill(
                label: p == null ? '开始阅读' : '继续阅读',
                filled: true,
                onTap: acting ? null : widget.onRead,
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(child: _processingCard(context)),
        SliverList.list(
          children: <Widget>[
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              title: const Text('我的摘记'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text('${_noteCount()}', style: TextStyle(color: t.ink3)),
                  Icon(Icons.chevron_right, color: t.ink3),
                ],
              ),
              onTap: widget.onRead,
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              title: Text(queue >= 0 ? '在书单第 ${queue + 1} 位' : '加入接下来读'),
              trailing: Icon(
                queue >= 0 ? Icons.playlist_remove : Icons.playlist_add,
                color: t.ink3,
              ),
              onTap: () {
                final List<String> list = List<String>.of(
                  widget.library.readingList,
                );
                queue >= 0 ? list.remove(b.id) : list.add(b.id);
                widget.library.setReadingList(list);
                setState(() {});
              },
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              title: const Text('导出完整备份'),
              trailing: Icon(Icons.chevron_right, color: t.ink3),
              onTap: widget.onExport,
            ),
            const SizedBox(height: 12),
            if (!confirmRemove)
              TextButton(
                onPressed: acting
                    ? null
                    : () => setState(() => confirmRemove = true),
                child: Text('从这台手机移除', style: TextStyle(color: t.danger)),
              )
            else
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: t.danger.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '会删除正文、人物资料和你的摘记。建议先导出备份。',
                      style: TextStyle(
                        color: t.danger,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: <Widget>[
                        Pill(label: '导出备份', onTap: widget.onExport),
                        const SizedBox(width: 10),
                        Pill(
                          label: acting ? '正在移除…' : '移除',
                          filled: true,
                          color: t.danger,
                          onTap: acting ? null : _remove,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _processingCard(BuildContext context) {
    final Tokens t = context.tk;
    final BookEntry b = widget.entry;
    final ProcessStatus s = b.status;
    final List<Widget> body = <Widget>[];
    if (missingKey) {
      body.addAll(<Widget>[
        Text('还没有填写模型 API 密钥', style: TextStyle(color: t.amber, fontSize: 15)),
        const SizedBox(height: 10),
        Pill(
          label: '去填写',
          onTap: () async {
            await widget.onModelSettings();
            if (mounted) setState(() => missingKey = !widget.settings.hasKey);
          },
        ),
      ]);
    } else if (s.isCancelling) {
      body.addAll(<Widget>[
        Text(
          '正在暂停，等待当前步骤结束。已经整理好的内容会保留。',
          style: TextStyle(fontSize: 14, height: 1.6, color: t.ink),
        ),
        const SizedBox(height: 10),
        LinearProgressIndicator(color: t.zhu, backgroundColor: t.zhuSoft),
      ]);
    } else if (s.isRunning) {
      body.addAll(<Widget>[
        LinearProgressIndicator(
          value: s.total == 0 ? null : (s.done / s.total).clamp(0.0, 1.0),
          color: t.zhu,
          backgroundColor: t.zhuSoft,
        ),
        const SizedBox(height: 8),
        Text(
          s.state == 'queued' ? '已加入整理队列' : '已整理 ${s.done} / ${s.total} 段',
          style: TextStyle(fontSize: 14, color: t.ink),
        ),
        const SizedBox(height: 10),
        Pill(label: '暂停整理', onTap: acting ? null : _pause),
      ]);
    } else if (s.isDone) {
      body.add(
        Text(
          '已读完 · ${s.people} 位人物',
          style: TextStyle(fontSize: 15, color: t.ink),
        ),
      );
      if (s.refused.isNotEmpty) {
        body.add(
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '有 ${s.refused.length} 段被模型拒绝（通常是内容审核），已跳过',
              style: TextStyle(fontSize: 13, color: t.ink2),
            ),
          ),
        );
      }
      final Json? quality = s.raw['quality'] as Json?;
      if (quality != null &&
          (quality['state'] == 'pending' || quality['pending'] == true)) {
        body.addAll(<Widget>[
          const SizedBox(height: 8),
          Text('部分资料待核对', style: TextStyle(fontSize: 13, color: t.ink2)),
          const SizedBox(height: 8),
          Pill(label: '重试待核对部分', onTap: acting ? null : _start),
        ]);
      }
    } else if (s.isPaused) {
      body.addAll(<Widget>[
        Text(
          '已暂停。已经整理好的部分可以直接看。',
          style: TextStyle(fontSize: 14, color: t.ink),
        ),
        const SizedBox(height: 10),
        Pill(
          label: '继续整理',
          filled: true,
          color: t.zhu,
          onTap: acting ? null : _start,
        ),
      ]);
    } else if (s.isError) {
      body.addAll(<Widget>[
        Text(
          '整理停下了',
          style: TextStyle(
            fontSize: 15,
            color: t.amber,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          s.error ?? '请稍后重试。',
          style: TextStyle(fontSize: 14, height: 1.5, color: t.ink),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: <Widget>[
            Pill(
              label: '重试整理',
              filled: true,
              color: t.zhu,
              onTap: acting ? null : _start,
            ),
            Pill(label: '去模型设置', onTap: acting ? null : widget.onModelSettings),
          ],
        ),
      ]);
    } else {
      final Map<String, Object?> estimate = models.estimate(
        b.length,
        lang: b.lang,
        model: widget.settings.read().$2,
      );
      final String cost = estimate['minutes'] == null
          ? '费用按你的模型接口计费。'
          : '预计约 ${estimate['minutes']} 分钟、约 ¥${estimate['high']}（${estimate['model']}）';
      body.add(
        Text(
          '让 AI 读完这本书，整理人物、关系和前情。只显示到你读到的那一页。',
          style: TextStyle(fontSize: 14, height: 1.6, color: t.ink),
        ),
      );
      body.add(const SizedBox(height: 10));
      if (!confirmStart) {
        body.add(
          Pill(
            label: '开始整理',
            filled: true,
            color: t.zhu,
            onTap: acting
                ? null
                : () => setState(() {
                    if (!widget.settings.hasKey) {
                      missingKey = true;
                    } else {
                      confirmStart = true;
                    }
                  }),
          ),
        );
      } else {
        body.addAll(<Widget>[
          Text(
            '会调用你的模型接口，$cost',
            style: TextStyle(fontSize: 13, color: t.ink2),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Pill(
                label: '取消',
                onTap: acting
                    ? null
                    : () => setState(() => confirmStart = false),
              ),
              const SizedBox(width: 10),
              Pill(
                label: '开始',
                filled: true,
                color: t.zhu,
                onTap: acting ? null : _start,
              ),
            ],
          ),
        ]);
      }
    }
    if (actionLabel != null) {
      body.add(
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            actionLabel!,
            style: TextStyle(fontSize: 13, color: t.ink3),
          ),
        ),
      );
    }
    if (engineNote != null) {
      body.add(
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            engineNote!,
            style: TextStyle(fontSize: 13, height: 1.5, color: t.amber),
          ),
        ),
      );
    }
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: t.raised,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: t.rule),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 22,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: t.zhu,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: const Text(
                  '批',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontFamily: display,
                    height: 1,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '人物与关系',
                style: TextStyle(
                  fontSize: 15,
                  color: t.ink,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...body,
        ],
      ),
    );
  }
}
