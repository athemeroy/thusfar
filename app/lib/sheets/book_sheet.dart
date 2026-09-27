import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:thusfar_core/models.dart' as models;
import 'package:thusfar_core/llm.dart' as llm;

import '../data/library.dart';
import '../data/model_settings.dart';
import '../data/processing.dart';
import '../data/processing_diagnostics.dart';
import '../ui/cover.dart';
import '../ui/device.dart';
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
    required this.onNotes,
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
  final VoidCallback onNotes;
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
  bool showAllActivity = false;
  String? _biographyGraphStamp;
  String? _biographyGraphRejectedStamp;
  ({int count, int? firstEnd}) _verifiedBios = (count: 0, firstEnd: null);
  String? _biographyBookStamp;
  String? _biographyBookRejectedStamp;
  int? _biographyChapterEnd;
  int? _biographyChapterNumber;

  ({int count, int? firstEnd}) _biographySummary() {
    final File file = File('${widget.entry.dir.path}/kg.json');
    try {
      final FileStat stat = file.statSync();
      if (stat.type != FileSystemEntityType.file) {
        _biographyGraphStamp = null;
        _biographyGraphRejectedStamp = null;
        return _verifiedBios = (count: 0, firstEnd: null);
      }
      final String stamp =
          '${stat.size}:${stat.modified.microsecondsSinceEpoch}:${stat.changed.microsecondsSinceEpoch}';
      if (stamp == _biographyGraphStamp) return _verifiedBios;
      if (stamp == _biographyGraphRejectedStamp) {
        return _verifiedBios = (count: 0, firstEnd: null);
      }
      final Object? graph = readJson(file);
      final Object? log = graph is Json ? graph['log'] : null;
      if (log is! List<Object?>) {
        _biographyGraphRejectedStamp = stamp;
        return _verifiedBios = (count: 0, firstEnd: null);
      }
      _verifiedBios = verifiedChapterBiographies(<Json>[
        for (final Object? row in log)
          if (row is Json) row,
      ]);
      _biographyGraphStamp = stamp;
      _biographyGraphRejectedStamp = null;
    } on FormatException {
      _biographyGraphStamp = null;
      _verifiedBios = (count: 0, firstEnd: null);
    } on FileSystemException {
      _biographyGraphStamp = null;
      _verifiedBios = (count: 0, firstEnd: null);
    }
    return _verifiedBios;
  }

  int? _biographyChapter(int end) {
    final File file = File('${widget.entry.dir.path}/book.json');
    try {
      final FileStat stat = file.statSync();
      if (stat.type != FileSystemEntityType.file) return null;
      final String stamp =
          '${stat.size}:${stat.modified.microsecondsSinceEpoch}:${stat.changed.microsecondsSinceEpoch}';
      if (stamp == _biographyBookStamp && end == _biographyChapterEnd) {
        return _biographyChapterNumber;
      }
      if (stamp == _biographyBookRejectedStamp) return null;
      final Object? book = readJson(file);
      final Object? chapters = book is Json ? book['chapters'] : null;
      if (chapters is! List<Object?>) {
        _biographyBookRejectedStamp = stamp;
        return null;
      }
      _biographyChapterNumber = biographyUnlockChapterNumber(chapters, end);
      _biographyBookStamp = stamp;
      _biographyBookRejectedStamp = null;
      _biographyChapterEnd = end;
      return _biographyChapterNumber;
    } on FormatException {
      _biographyBookStamp = null;
      return null;
    } on FileSystemException {
      _biographyBookStamp = null;
      return null;
    }
  }

  List<Json> _activity() {
    final Object? raw = readJson(
      File('${widget.entry.dir.path}/work/activity.json'),
    );
    if (raw is! List<Object?>) return const <Json>[];
    return <Json>[
      for (final Object? row in raw)
        if (row is Json && row['message'] is String) row,
    ];
  }

  List<Json> _compactActivity(List<Json> activity) {
    final List<Json> result = <Json>[];
    for (final Json row in activity) {
      if (row['phase'] == 'stage_heartbeat' &&
          result.isNotEmpty &&
          result.last['phase'] == 'stage_heartbeat' &&
          result.last['segment'] == row['segment'] &&
          result.last['stage'] == row['stage']) {
        result.last = row;
      } else {
        result.add(row);
      }
    }
    return result;
  }

  String _stageName(Object? value) => switch (value) {
    'extract' => '正文抽取',
    'relation' => '人物关联',
    'recap' => '前情整理',
    'finalize' => '人物资料',
    _ => '当前阶段',
  };

  String _activityDescription(Json row) {
    if (row['phase'] != 'stage_heartbeat') return '${row['message']}';
    final Object? segment = row['segment'];
    final String prefix = segment is num && segment > 0
        ? '第 ${segment.toInt()} 段 · '
        : '';
    final Object? first = row['started_at'];
    final Object? last = row['last_at'] ?? row['at'];
    final int? minutes = first is num && last is num && last >= first
        ? ((last - first) / 60).floor()
        : null;
    return '$prefix${_stageName(row['stage'])}'
        '${minutes == null ? '仍在等待' : '已等待 $minutes 分钟'}';
  }

  String _lastStageSummary(Json row) {
    if (row['phase'] == 'stage_heartbeat') return _activityDescription(row);
    if (row['phase'] == 'model_attempt') {
      final Object? segment = row['segment'];
      final Object? attempt = row['attempt'];
      if (segment is num && attempt is num) {
        return '第 ${segment.toInt()} 段 · 第 ${attempt.toInt()} 次模型请求';
      }
    }
    if (row['phase'] == 'waiting_for_model' || row['phase'] == 'retry') {
      return _activityDescription(row);
    }
    return _activityPhase(row);
  }

  String _activityTime(Object? value) {
    if (value is! num || !value.isFinite || value < 0 || value > 4102444800) {
      return '';
    }
    final DateTime time = DateTime.fromMillisecondsSinceEpoch(
      (value * 1000).round(),
    );
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  String _activityAge(Object? value) {
    if (value is! num) return '';
    final int seconds = (DateTime.now().millisecondsSinceEpoch / 1000 - value)
        .floor();
    if (seconds < 30) return '';
    if (seconds < 60) return '已等待 $seconds 秒';
    return '已等待 ${seconds ~/ 60} 分 ${seconds % 60} 秒';
  }

  String _activityPhase(Json row) {
    final String phase = '${row['phase']}';
    // Older activity files used "running" for both the worker's preflight
    // check and completed body segments. Keep their existing labels accurate.
    if (phase == 'running' && row['message'] == '正在检查书籍和整理缓存') {
      return '准备';
    }
    return switch (phase) {
      'queued' => '排队',
      'running' => '正文',
      'detect_kind' || 'classify_chapters' => '准备',
      'check_titles' || 'check_titles_pending' => '标题',
      'resume_final_jobs' => '资料',
      'waiting_for_model' => '模型',
      'stage_heartbeat' => '模型',
      'model_attempt' => '模型',
      'retry' => '重试',
      'finalizing' => '汇总',
      'bio_generating' ||
      'bio_review' ||
      'bio_complete' ||
      'bio_no_candidates' ||
      'bio_failed' => '人物',
      'done' => '完成',
      'paused' || 'cancelling' => '暂停',
      'error' => '错误',
      _ => '进度',
    };
  }

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

  Future<void> _exportDiagnostics() async {
    if (acting) return;
    setState(() {
      acting = true;
      actionLabel = '正在准备整理诊断…';
    });
    String message;
    try {
      final DateTime now = DateTime.now();
      final String? path = await FilePicker.platform.saveFile(
        dialogTitle: '导出整理诊断',
        fileName: ProcessingDiagnostics.fileName(now),
        bytes: ProcessingDiagnostics.bytes(
          bookDirectory: widget.entry.dir,
          workerHealth: widget.processing.health,
          now: now,
        ),
      );
      message = path == null ? '没有导出整理诊断' : '整理诊断已导出';
    } on Object {
      message = '整理诊断导出没有完成，请检查存储空间后重试。';
    }
    if (!mounted) return;
    setState(() {
      acting = false;
      actionLabel = null;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

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
                    style: TextStyle(
                      fontSize: 13,
                      color: t.ink2,
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
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SizedBox(
              width: double.infinity,
              child: Pill(
                label: p == null ? '开始阅读' : '继续阅读',
                filled: true,
                onTap: acting
                    ? null
                    : () {
                        HapticFeedback.lightImpact();
                        widget.onRead();
                      },
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
                  Text(
                    '${_noteCount()}',
                    style: TextStyle(
                      color: t.ink3,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: t.ink3),
                ],
              ),
              onTap: () {
                HapticFeedback.lightImpact();
                widget.onNotes();
              },
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              title: Text(
                queue >= 0 ? '在书单第 ${queue + 1} 位' : '加入接下来读',
                style: const TextStyle(
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
              trailing: Icon(
                queue >= 0 ? Icons.playlist_remove : Icons.playlist_add,
                color: t.ink3,
              ),
              onTap: () {
                HapticFeedback.lightImpact();
                final List<String> list = List<String>.of(
                  widget.library.readingList,
                );
                final bool wasIn = queue >= 0;
                wasIn ? list.remove(b.id) : list.add(b.id);
                widget.library.setReadingList(list);
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    duration: const Duration(seconds: 2),
                    content: Text(wasIn ? '已从接下来读移除' : '已加入接下来读'),
                  ),
                );
              },
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              title: const Text('导出完整备份'),
              trailing: Icon(Icons.chevron_right, color: t.ink3),
              onTap: () {
                HapticFeedback.lightImpact();
                widget.onExport();
              },
            ),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 20),
              title: const Text('导出整理诊断'),
              subtitle: const Text('仅含进度与阶段记录，不含正文或模型密钥'),
              trailing: Icon(Icons.chevron_right, color: t.ink3),
              onTap: acting
                  ? null
                  : () {
                      HapticFeedback.lightImpact();
                      _exportDiagnostics();
                    },
            ),
            const SizedBox(height: 12),
            if (!confirmRemove)
              TextButton(
                onPressed: acting
                    ? null
                    : () {
                        HapticFeedback.lightImpact();
                        setState(() => confirmRemove = true);
                      },
                child: Text(
                  '从这台$deviceWord移除',
                  style: TextStyle(color: t.danger),
                ),
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
                        Pill(
                          label: '导出备份',
                          onTap: () {
                            HapticFeedback.lightImpact();
                            widget.onExport();
                          },
                        ),
                        const SizedBox(width: 10),
                        Pill(
                          label: acting ? '正在移除…' : '移除',
                          filled: true,
                          color: t.danger,
                          onTap: acting
                              ? null
                              : () {
                                  HapticFeedback.mediumImpact();
                                  _remove();
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
    final ({int count, int? firstEnd}) bios = _biographySummary();
    final List<Json> activity = _compactActivity(_activity());
    final Json? latestActivity = activity.isEmpty ? null : activity.last;
    final num latestAt = latestActivity?['at'] is num
        ? latestActivity!['at']! as num
        : 0;
    final num statusAt = s.raw['updated'] is num ? s.raw['updated']! as num : 0;
    final bool activityAfterNotice =
        latestActivity != null && statusAt > 0 && latestAt > statusAt + 0.5;
    final Map<String, Object?> health = widget.processing.health;
    final bool thisBookIsRunning = health['current'] == b.id;
    final bool workerStopped = health['alive'] == false;
    final List<Object?> queued = health['queued'] is List<Object?>
        ? health['queued']! as List<Object?>
        : const <Object?>[];
    final int queuedAt = queued.indexOf(b.id);
    final List<Widget> body = <Widget>[];
    if (workerStopped && s.isActive) {
      body.add(
        Text(
          '整理任务意外停止，正在核对书籍状态。请重新打开应用后继续。',
          style: TextStyle(fontSize: 14, height: 1.5, color: t.amber),
        ),
      );
    } else if (missingKey) {
      body.addAll(<Widget>[
        Text('还没有填写模型 API 密钥', style: TextStyle(color: t.amber, fontSize: 15)),
        const SizedBox(height: 10),
        Pill(
          label: '去填写',
          onTap: () async {
            HapticFeedback.lightImpact();
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
          s.state == 'queued' && !thisBookIsRunning
              ? queuedAt >= 0
                    ? '等待整理 · 队列第 ${queuedAt + 1} 位'
                    : '已加入整理队列'
              : s.total > 0
              ? '已整理 ${s.done} / ${s.total} 段'
              : '正在准备整理',
          style: TextStyle(
            fontSize: 14,
            color: t.ink,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        if (s.state != 'queued' &&
            !activityAfterNotice &&
            s.notice != null &&
            s.notice!.isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            s.notice!,
            style: TextStyle(fontSize: 13, height: 1.4, color: t.ink2),
          ),
        ] else if (thisBookIsRunning && latestActivity != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            _activityDescription(latestActivity),
            style: TextStyle(fontSize: 13, height: 1.4, color: t.ink2),
          ),
        ],
        if (thisBookIsRunning && s.done == 0) ...<Widget>[
          const SizedBox(height: 5),
          Text(
            '首段结果尚未返回，段数不会增加；模型可能在单次请求内重试。',
            style: TextStyle(fontSize: 12, color: t.ink3),
          ),
        ],
        if (thisBookIsRunning &&
            activity.isNotEmpty &&
            <String>{
              'waiting_for_model',
              'stage_heartbeat',
              'model_attempt',
              'retry',
            }.contains(activity.last['phase']) &&
            _activityAge(
              activity.last['started_at'] ?? activity.last['at'],
            ).isNotEmpty) ...<Widget>[
          const SizedBox(height: 5),
          Text(
            '${_activityAge(activity.last['started_at'] ?? activity.last['at'])}；等待时长不代表已完成新段落。',
            style: TextStyle(fontSize: 12, color: t.ink3),
          ),
        ],
        if (s.done > 0 && bios.count == 0) ...<Widget>[
          const SizedBox(height: 5),
          Text(
            '段数是正文进度；人物小传还需按章汇总和核对。',
            style: TextStyle(fontSize: 12, color: t.ink3),
          ),
        ],
        const SizedBox(height: 5),
        Text(
          '正文最多 $phoneConcurrency 段并行；多本书依次整理。',
          style: TextStyle(fontSize: 12, color: t.ink3),
        ),
        const SizedBox(height: 10),
        Pill(
          label: '暂停整理',
          onTap: acting
              ? null
              : () {
                  HapticFeedback.lightImpact();
                  _pause();
                },
        ),
      ]);
    } else if (s.isDone) {
      body.add(
        Text(
          '整理完成 · 已识别 ${s.people} 位人物',
          style: TextStyle(fontSize: 15, color: t.ink),
        ),
      );
      if (s.people == 0) {
        body.add(
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '这本书尚未识别出人物。',
              style: TextStyle(fontSize: 13, color: t.ink2),
            ),
          ),
        );
      } else {
        body.add(
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '人物数量不等于小传数量；未核对通过的小传不会展示。',
              style: TextStyle(fontSize: 13, color: t.ink2),
            ),
          ),
        );
      }
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
          Pill(
            label: '重试待核对部分',
            onTap: acting
                ? null
                : () {
                    HapticFeedback.lightImpact();
                    _start();
                  },
          ),
        ]);
      }
    } else if (s.isPaused) {
      final Json? lastWork = activity.cast<Json?>().lastWhere(
        (Json? row) =>
            row != null &&
            <String>{
              'stage_heartbeat',
              'model_attempt',
              'waiting_for_model',
              'retry',
              'bio_generating',
              'bio_review',
              'check_titles',
            }.contains(row['phase']),
        orElse: () => null,
      );
      final String pausedAt = _activityTime(s.raw['updated']);
      final String lastWorkAt = lastWork == null
          ? ''
          : _activityTime(lastWork['last_at'] ?? lastWork['at']);
      body.addAll(<Widget>[
        Text(
          '已暂停。已经整理好的部分可以直接看。',
          style: TextStyle(fontSize: 14, color: t.ink),
        ),
        if (s.done > 0 || s.people > 0) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            '已整理 ${s.done}${s.total > 0 ? '/${s.total}' : ''} 段${s.people > 0 ? ' · 已识别 ${s.people} 位人物' : ''}',
            style: TextStyle(fontSize: 13, color: t.ink2),
          ),
        ],
        if (s.total > s.done) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            '下一段：第 ${s.done + 1} / ${s.total} 段，尚未完成。',
            style: TextStyle(fontSize: 13, color: t.ink2),
          ),
        ],
        const SizedBox(height: 6),
        Text(
          '${ProcessingDiagnostics.pauseReasonLabel(b.dir, s.raw)}${pausedAt.isEmpty ? '' : ' · $pausedAt'}',
          style: TextStyle(fontSize: 13, color: t.ink2),
        ),
        if (lastWork != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            '暂停前最后阶段：${_lastStageSummary(lastWork)}${lastWorkAt.isEmpty ? '' : ' · $lastWorkAt'}',
            style: TextStyle(fontSize: 13, color: t.ink2),
          ),
        ],
        const SizedBox(height: 10),
        Pill(
          label: '继续整理',
          filled: true,
          color: t.zhu,
          onTap: acting
              ? null
              : () {
                  HapticFeedback.lightImpact();
                  _start();
                },
        ),
      ]);
    } else if (s.isError) {
      final bool autoRetry =
          s.raw['retryable'] == true &&
          ProcessingDiagnostics.autoEnabled(b.dir) &&
          health['alive'] == true;
      final String retryAt = _activityTime(s.raw['retry_at']);
      final bool retryTimePassed =
          s.raw['retry_at'] is num &&
          (s.raw['retry_at']! as num) <=
              DateTime.now().millisecondsSinceEpoch / 1000;
      body.addAll(<Widget>[
        Text(
          autoRetry ? '模型请求遇到问题，等待自动重试' : '整理遇到问题',
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
        if (autoRetry) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            retryAt.isEmpty
                ? '任务会自动重试，已经整理好的部分会保留。'
                : retryTimePassed
                ? '已到预计重试时间，正在等待整理任务处理。已经整理好的部分会保留。'
                : '预计 $retryAt 自动重试；已经整理好的部分会保留。',
            style: TextStyle(fontSize: 13, height: 1.5, color: t.ink2),
          ),
        ],
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: <Widget>[
            if (!workerStopped)
              Pill(
                label: autoRetry ? '现在重试' : '重试整理',
                filled: true,
                color: t.zhu,
                onTap: acting
                    ? null
                    : () {
                        HapticFeedback.lightImpact();
                        _start();
                      },
              ),
            if (autoRetry)
              Pill(
                label: '停止自动重试',
                onTap: acting
                    ? null
                    : () {
                        HapticFeedback.lightImpact();
                        _pause();
                      },
              ),
            Pill(
              label: '去模型设置',
              onTap: acting
                  ? null
                  : () {
                      HapticFeedback.lightImpact();
                      widget.onModelSettings();
                    },
            ),
          ],
        ),
      ]);
    } else {
      final Map<String, Object?> estimate = models.estimate(
        b.length,
        lang: b.lang,
        model: widget.settings.read().$2,
      );
      final int? minutes = models.deviceMinutes(
        b.length,
        lang: b.lang,
        model: widget.settings.read().$2,
        concurrency: phoneConcurrency,
      );
      final String cost = minutes == null
          ? '费用按你的模型接口计费。'
          : '预计约 $minutes 分钟、约 ¥${estimate['high']}（${estimate['model']}）';
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
                : () {
                    HapticFeedback.lightImpact();
                    setState(() {
                      if (!widget.settings.hasKey) {
                        missingKey = true;
                      } else {
                        confirmStart = true;
                      }
                    });
                  },
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
                    : () {
                        HapticFeedback.lightImpact();
                        setState(() => confirmStart = false);
                      },
              ),
              const SizedBox(width: 10),
              Pill(
                label: '开始',
                filled: true,
                color: t.zhu,
                onTap: acting
                    ? null
                    : () {
                        HapticFeedback.lightImpact();
                        _start();
                      },
              ),
            ],
          ),
        ]);
      }
    }
    if (bios.firstEnd != null) {
      final int? chapter = _biographyChapter(bios.firstEnd!);
      final String unlockAt = chapter == null ? '对应章节末' : '第 $chapter 章末';
      body.add(
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            '已有 ${bios.count} 篇核对通过的人物小传。首批在$unlockAt解锁；阅读页只显示你读到的部分。',
            style: TextStyle(fontSize: 13, height: 1.5, color: t.zhu),
          ),
        ),
      );
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
    if (activity.isNotEmpty) {
      final List<Json> shown = showAllActivity
          ? activity.reversed.take(24).toList()
          : activity.reversed.take(4).toList();
      body.addAll(<Widget>[
        const SizedBox(height: 14),
        Divider(color: t.rule),
        const SizedBox(height: 4),
        Text(
          '整理记录',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: t.ink,
          ),
        ),
        const SizedBox(height: 6),
        for (final Json row in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: 5),
            child: Text(
              '${_activityTime(row['last_at'] ?? row['at'])}  ${_activityPhase(row)} · ${_activityDescription(row)}',
              style: TextStyle(fontSize: 12, height: 1.4, color: t.ink2),
            ),
          ),
        if (activity.length > 4)
          TextButton(
            onPressed: () => setState(() => showAllActivity = !showAllActivity),
            child: Text(
              showAllActivity
                  ? '收起记录'
                  : '查看最近 ${activity.length.clamp(0, 24)} 条记录',
            ),
          ),
      ]);
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
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: t.zhuSoft, width: 0.5),
                  boxShadow: <BoxShadow>[
                    BoxShadow(
                      color: t.zhu.withValues(alpha: 0.25),
                      blurRadius: 3,
                      offset: const Offset(0, 1),
                    ),
                  ],
                ),
                child: const Text(
                  '批',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontFamily: display,
                    fontWeight: FontWeight.w600,
                    height: 1.05,
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
