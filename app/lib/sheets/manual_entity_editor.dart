import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:thusfar_core/thusfar_core.dart';

import '../ui/theme.dart';
import 'common.dart';
import 'people_sheet.dart';
import 'person_sheet.dart';
import 'sheet_host.dart';

/// Personal people/concepts are saved locally and become visible at this page.
class ManualEntityEditor extends StatefulWidget {
  const ManualEntityEditor({
    super.key,
    required this.link,
    this.id,
    this.prefill = '',
  });
  final ReaderLink link;
  final String? id;
  final String prefill;

  @override
  State<ManualEntityEditor> createState() => _ManualEntityEditorState();
}

class _ManualEntityEditorState extends State<ManualEntityEditor> {
  static String _identifier() {
    final math.Random random = math.Random.secure();
    return List<String>.generate(
      24,
      (_) => random.nextInt(36).toRadixString(36),
    ).join();
  }

  late final String id = widget.id ?? _identifier();
  late final String operation = _identifier();
  late final String deleteOperation = _identifier();
  late final int openedCutoff = widget.link.c.cutoff;
  late final Json? original = widget.id == null
      ? null
      : widget.link.c.book.manualEntry(id, openedCutoff);
  late final TextEditingController name = TextEditingController(
    text: original?['name'] as String? ?? widget.prefill,
  );
  late final TextEditingController note = TextEditingController(
    text: original == null
        ? ''
        : '${((original!['versions']! as List<Object?>).last! as Json)['note']}',
  );
  late String kind = original?['kind'] as String? ?? 'person';
  String? error;
  bool confirmDelete = false;

  @override
  void initState() {
    super.initState();
    // Capture a visible revision once. Later updates must trigger a conflict,
    // not silently overwrite the other writer's changes.
    original;
    name;
    note;
    widget.link.c.addListener(_changed);
  }

  @override
  void dispose() {
    widget.link.c.removeListener(_changed);
    name.dispose();
    note.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool get _unavailable =>
      widget.id != null &&
      (original == null ||
          widget.link.c.book.manualEntry(id, widget.link.c.cutoff) == null);
  bool get _locked =>
      widget.id != null &&
      widget.link.c.book.manualEntry(id, widget.link.c.cutoff)?['locked'] ==
          true;
  bool get _rewound => widget.link.c.cutoff < openedCutoff;

  void _save({bool deleted = false}) {
    if (_unavailable || _locked || _rewound) return;
    if (deleted) {
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.lightImpact();
    }
    try {
      final Json saved = widget.link.c.book.saveManual(<String, Object?>{
        'id': id,
        'kind': kind,
        'name': name.text,
        'note': note.text,
        'knowledge_cutoff': widget.link.c.cutoff,
        'expected_revision': original?['revision'] ?? 0,
        'operation': deleted ? deleteOperation : operation,
        'deleted': deleted,
      });
      if (!mounted) return;
      if (deleted) {
        if (saved['deleted'] != true) throw const ValueError('删除尚未确认，请重新打开后检查');
        SheetScope.of(
          context,
        ).state.reset(PeoplePage(link: widget.link, tab: 2));
      } else {
        SheetScope.of(
          context,
        ).state.reset(PersonPage(link: widget.link, id: 'U${saved['id']}'));
      }
    } on PyException catch (failure) {
      setState(() => error = failure.message);
    } on Object {
      setState(() => error = '保存没有完成，已保留你的文字，请检查书籍文件后重试。');
    }
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final String? problem = _unavailable
        ? '这一页还看不到该条目，或它已被删除。'
        : _rewound
        ? '阅读位置已回到之前，请关闭后重新打开补充。'
        : widget.link.c.book.manualError;
    return SheetPage(
      title: widget.id == null ? '补充人物或概念' : '编辑手动补充',
      slivers: <Widget>[
        if (problem != null)
          emptyState(context, problem)
        else
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    '只补充已读原文里出现过的名称。说明从当前这一页起可见，并随本书备份保存。',
                    style: TextStyle(color: t.ink2, fontSize: 14, height: 1.6),
                  ),
                  const SizedBox(height: 16),
                  if (widget.id == null)
                    Segmented(
                      labels: const <String>['人物', '概念'],
                      index: kind == 'person' ? 0 : 1,
                      onChanged: (int index) => setState(
                        () => kind = index == 0 ? 'person' : 'concept',
                      ),
                    )
                  else
                    Text(
                      kind == 'person' ? '人物' : '概念',
                      style: TextStyle(color: t.ink2),
                    ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const ValueKey<String>('manual-name'),
                    controller: name,
                    readOnly: widget.id != null,
                    decoration: const InputDecoration(labelText: '原文中的完整名称'),
                    maxLength: 80,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey<String>('manual-note'),
                    controller: note,
                    readOnly: _locked,
                    decoration: const InputDecoration(
                      labelText: '你知道的内容',
                      hintText: '身份、含义或线索，可留空',
                    ),
                    minLines: 4,
                    maxLines: 8,
                    maxLength: 3000,
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: note,
                    builder: (BuildContext context, TextEditingValue val, Widget? _) {
                      final int count = val.text.trim().length;
                      if (count == 0) return const SizedBox.shrink();
                      return Align(
                        alignment: Alignment.centerRight,
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4, right: 4),
                          child: Text(
                            '$count 字',
                            style: TextStyle(
                              fontSize: 12,
                              color: t.ink3,
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  if (_locked)
                    Text(
                      '这条资料在更后面的阅读位置修改过；回到那里才能继续编辑。',
                      style: TextStyle(color: t.amber, height: 1.6),
                    ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        error!,
                        style: TextStyle(color: t.danger, height: 1.5),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Pill(
                    label: widget.id == null ? '保存补充' : '保存修改',
                    filled: true,
                    onTap: _locked ? null : _save,
                  ),
                  if (widget.id != null && !_locked) ...<Widget>[
                    const SizedBox(height: 12),
                    if (!confirmDelete)
                      TextButton(
                        onPressed: () {
                          HapticFeedback.lightImpact();
                          setState(() => confirmDelete = true);
                        },
                        child: Text(
                          '删除这条补充',
                          style: TextStyle(color: t.danger),
                        ),
                      )
                    else
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: t.danger.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Column(
                          children: <Widget>[
                            Text(
                              '删除「${name.text}」的手动补充？',
                              style: TextStyle(
                                color: t.danger,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Pill(
                                    label: '取消',
                                    onTap: () {
                                      HapticFeedback.lightImpact();
                                      setState(() => confirmDelete = false);
                                    },
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Pill(
                                    label: '确认删除',
                                    filled: true,
                                    color: t.danger,
                                    onTap: () => _save(deleted: true),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}
