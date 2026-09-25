import 'dart:io';

import 'package:flutter/material.dart';
import 'package:thusfar_core/models.dart' as models;

import '../data/library.dart';
import '../data/model_settings.dart';
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
    required this.onRead,
    required this.onModelSettings,
    required this.onExport,
    this.focusProcessing = false,
  });

  final Library library;
  final BookEntry entry;
  final ModelSettings settings;
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
                onTap: widget.onRead,
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
                onPressed: () => setState(() => confirmRemove = true),
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
                          label: '移除',
                          filled: true,
                          color: t.danger,
                          onTap: () {
                            widget.library.remove(b);
                            Navigator.of(context).pop();
                          },
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
      if (quality != null && quality['state'] == 'pending') {
        body.add(
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '部分资料待核对',
              style: TextStyle(fontSize: 13, color: t.ink2),
            ),
          ),
        );
      }
    } else if (s.isRunning) {
      body.addAll(<Widget>[
        LinearProgressIndicator(
          value: s.total == 0 ? null : s.done / s.total,
          color: t.zhu,
          backgroundColor: t.zhuSoft,
        ),
        const SizedBox(height: 8),
        Text(
          '已整理 ${s.done} / ${s.total} 段',
          style: TextStyle(fontSize: 14, color: t.ink),
        ),
      ]);
    } else if (s.isPaused) {
      body.add(
        Text(
          '已暂停。已经整理好的部分可以直接看。',
          style: TextStyle(fontSize: 14, color: t.ink),
        ),
      );
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
          s.error ?? '',
          style: TextStyle(fontSize: 14, height: 1.5, color: t.ink),
        ),
        const SizedBox(height: 10),
        Pill(label: '去模型设置', onTap: widget.onModelSettings),
      ]);
    } else {
      final Map<String, Object?> est = models.estimate(
        b.length,
        lang: b.lang,
        model: widget.settings.read().$2,
      );
      final String cost = est['minutes'] == null
          ? ''
          : '预计约 ${est['minutes']} 分钟、约 ¥${est['high']}（${est['model']}）';
      body.add(
        Text(
          '让 AI 读完这本书，整理人物、关系和前情。只显示到你读到的那一页。',
          style: TextStyle(fontSize: 14, height: 1.6, color: t.ink),
        ),
      );
      if (!confirmStart) {
        body.addAll(<Widget>[
          const SizedBox(height: 10),
          Pill(
            label: '开始整理',
            filled: true,
            color: t.zhu,
            onTap: () => setState(() {
              if (!widget.settings.hasKey) {
                missingKey = true;
              } else {
                confirmStart = true;
              }
            }),
          ),
        ]);
      } else {
        body.addAll(<Widget>[
          const SizedBox(height: 10),
          Text(
            '会调用你的模型接口，$cost',
            style: TextStyle(fontSize: 13, color: t.ink2),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Pill(
                label: '取消',
                onTap: () => setState(() => confirmStart = false),
              ),
              const SizedBox(width: 10),
              Pill(
                label: '开始',
                filled: true,
                color: t.zhu,
                onTap: () => setState(() {
                  confirmStart = false;
                  engineNote =
                      '整理引擎正在移植到新版，这一版还不能开始整理。已经整理好的书（包括从 1.7 升级来的）可以直接读。';
                }),
              ),
            ],
          ),
        ]);
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
