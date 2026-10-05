import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:thusfar_core/models.dart' as models;
import 'package:thusfar_core/judge_budget.dart' as judge_budget;
import 'package:thusfar_core/llm.dart' as llm;
import 'package:thusfar_core/jobs.dart' show hasUnsettledModelRequests;

import '../data/library.dart';
import '../data/model_settings.dart';
import '../data/processing.dart';
import '../data/processing_copy.dart';
import '../data/preparation_plan.dart';
import '../data/processing_diagnostics.dart';
import '../data/processing_notification_bridge.dart';
import '../screens/imported_web_preparation_screen.dart';
import '../ui/cover.dart';
import '../ui/theme.dart';
import 'sheet_host.dart';
import 'preparation_plan_editor.dart';
import 'preparation_progress.dart';

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
  NativePreparationPlan? _selectedPlan;

  NativePreparationPlan _plan() {
    if (_selectedPlan != null) return _selectedPlan!;
    final Object? book = readJson(File('${widget.entry.dir.path}/book.json'));
    final Object? meta = readJson(File('${widget.entry.dir.path}/meta.json'));
    final Object? saved = meta is Json ? meta['preparation_plan'] : null;
    return _selectedPlan = NativePreparationPlan.fromBook(
      book is Json ? book : <String, Object?>{},
      readingCutoff: widget.library.progressOf(widget.entry.id)?.cutoff ?? 0,
      saved: saved is Json ? saved : null,
    );
  }

  Future<void> _adjustPlan() async {
    if (!widget.settings.hasKey) {
      setState(() => missingKey = true);
      return;
    }
    NativePreparationPlan selected = _plan();
    final NativePreparationPlan? choice =
        await showDialog<NativePreparationPlan>(
          context: context,
          builder: (BuildContext context) => StatefulBuilder(
            builder: (BuildContext context, StateSetter redraw) => AlertDialog(
              title: const Text('调整这次整理范围'),
              content: SizedBox(
                width: 520,
                child: SingleChildScrollView(
                  child: PreparationPlanEditor(
                    plan: selected,
                    frontier: widget.entry.status.frontier,
                    onChanged: (NativePreparationPlan plan) =>
                        redraw(() => selected = plan),
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: !selected.valid
                      ? null
                      : () => Navigator.pop(context, selected),
                  child: const Text('按此范围开始（可能收费）'),
                ),
              ],
            ),
          ),
        );
    if (choice == null || !mounted) return;
    setState(() => _selectedPlan = choice);
    await _action('正在开始本次范围…', () => _startWorker(plan: choice.toJson()));
  }

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

  bool _hasReviewablePendingBiography(Object? pending) {
    if (pending is! List<Object?>) return false;
    for (final Object? item in pending) {
      if (item is! String || !RegExp(r'^bio-\d+$').hasMatch(item)) continue;
      try {
        final Object? job = readJson(
          File('${widget.entry.dir.path}/work/jobs/$item.json'),
        );
        if (job is! Json || job['state'] != 'deferred') continue;
        final Object? review = job['bio_review'];
        if (review is Json &&
            (review['verification_pending'] == true ||
                (review['blocked'] is num &&
                    (review['blocked']! as num) > 0))) {
          return true;
        }
      } on Object {
        // A missing or damaged optional job cannot justify a paid recheck.
      }
    }
    return false;
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
    'extract' => '整理人物和事件',
    'relation' => '整理人物关系',
    'recap' => '前情整理',
    'finalize' => '人物资料',
    _ => '当前阶段',
  };

  String _activityDescription(Json row) {
    if (row['phase'] != 'stage_heartbeat') {
      return switch (row['phase']) {
        'queued' => '等待开始整理',
        'running' => row['done'] is num ? '已整理 ${row['done']} 段' : '准备整理',
        'detect_kind' || 'classify_chapters' => '整理章节目录',
        'check_titles' => '检查章节标题',
        'check_titles_pending' => '部分章节标题还需要检查',
        'resume_final_jobs' || 'finalizing' => '汇总人物资料',
        'waiting_for_model' => '等待 AI 的整理结果',
        'model_attempt' => _lastStageSummary(row),
        'retry' => '暂时没有完成，稍后自动再试',
        'bio_generating' => '正在写人物小传',
        'bio_review' => '检查人物小传是否符合原文',
        'bio_complete' => '人物小传已保存',
        'bio_no_candidates' => '这一部分没有需要新增的小传',
        'bio_failed' => '人物小传暂未完成，已完成的内容已保留',
        'done' => '整理完成',
        'paused' => '整理已暂停',
        'cancelling' => '正在暂停',
        'error' => processingErrorMessage(row['message'] as String?),
        _ => '整理进度已更新',
      };
    }
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
        return '第 ${segment.toInt()} 段 · 第 ${attempt.toInt()} 次尝试';
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
    final bool bounded = confirmStart || widget.entry.status.isIdle;
    final NativePreparationPlan plan = _plan();
    if (bounded && !plan.valid) {
      setState(() => engineNote = '这个范围没有可处理的正文，请调整范围。');
      return;
    }
    await _action(
      '正在开始整理…',
      () => _startWorker(plan: bounded ? plan.toJson() : null),
    );
  }

  Future<void> _startWorker({Json? plan}) async {
    if (widget.entry.status.raw['pause_reason'] == 'request_outcome_unknown' ||
        hasUnsettledModelRequests(widget.entry.dir)) {
      final bool? approved = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('继续未完成的整理？'),
          content: const Text(
            '已完成的内容会保留。上次未收到结果的部分可能需要重新处理；如果你使用付费服务，这部分可能再次收费。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('暂不继续'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('继续整理'),
            ),
          ],
        ),
      );
      if (approved != true || !mounted) return;
    }
    if (plan != null) {
      await widget.processing.startBookWithPlan(widget.entry, plan);
    } else {
      await widget.processing.startBook(widget.entry);
    }
  }

  Future<void> _continueWithModel() =>
      _setBookJudgeFallback('model', '正在用当前模型检查内容并继续整理…');

  Future<void> _continueWithJev() =>
      _setBookJudgeFallback('jev', '正在改用 Jev 检查内容并继续整理…');

  Future<void> _retryWithDirectModel() =>
      _setBookJudgeFallback('model-direct', '正在用当前模型重新检查内容…');

  Future<void> _retryWithDirectJev() =>
      _setBookJudgeFallback('jev-direct', '正在用 Jev 重新检查内容…');

  Future<void> _setBookJudgeFallback(String route, String label) =>
      _action(label, () async {
        if (!widget.settings.hasKey || widget.settings.read().$2.isEmpty) {
          throw StateError('请先保存可用的模型和 API 密钥');
        }
        if (route.startsWith('jev') && !widget.settings.hasJevApiKey) {
          throw StateError('请先在模型设置中填写 Jev 密钥');
        }
        final File metaFile = File('${widget.entry.dir.path}/meta.json');
        final Json meta = (readJson(metaFile) as Json?) ?? <String, Object?>{};
        meta['judge_fallback_route'] = route;
        meta.remove('judge_model_fallback');
        writeJson(metaFile, meta);
        await _startWorker();
      });

  String? _bookJudgeFallback(Directory book) {
    try {
      final Object? meta = readJson(File('${book.path}/meta.json'));
      if (meta is! Json) return null;
      if (meta.containsKey('judge_fallback_route')) {
        final Object? route = meta['judge_fallback_route'];
        return const <String>{
              'model',
              'jev',
              'model-direct',
              'jev-direct',
            }.contains(route)
            ? route as String
            : null;
      }
      return meta['judge_model_fallback'] == true ? 'model' : null;
    } on Object {
      return null;
    }
  }

  Future<void> _disableBookJudgeFallback() =>
      _action('正在恢复使用设置中的检查方式…', () async {
        await widget.processing.pauseBookUntilIdle(widget.entry);
        final File metaFile = File('${widget.entry.dir.path}/meta.json');
        final Json meta = (readJson(metaFile) as Json?) ?? <String, Object?>{};
        meta.remove('judge_fallback_route');
        meta.remove('judge_model_fallback');
        writeJson(metaFile, meta);
      });

  Future<void> _extendJudgeBudget() => _action('正在增加本书允许检查的次数…', () async {
    judge_budget.extendModelJudgeBudget(
      File('${widget.entry.dir.path}/work/judge/model-budget.json'),
    );
    await _startWorker();
  });

  Future<void> _extendPaidJudgeBudget() =>
      _action('正在增加本书允许使用 Jev 的次数…', () async {
        judge_budget.extendPaidJudgeBudget(
          File('${widget.entry.dir.path}/work/judge/paid-budget.json'),
        );
        await _startWorker();
      });

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
      final Map<String, Object?> runtime =
          await ProcessingNotificationBridge.diagnostics();
      final String? path = await FilePicker.platform.saveFile(
        dialogTitle: '导出问题记录',
        fileName: ProcessingDiagnostics.fileName(now),
        bytes: ProcessingDiagnostics.bytes(
          bookDirectory: widget.entry.dir,
          workerHealth: widget.processing.health,
          backgroundRuntime: runtime,
          now: now,
        ),
      );
      message = path == null ? '没有导出问题记录' : '问题记录已导出';
    } on Object {
      message = '问题记录导出没有完成，请检查存储空间后重试。';
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

  bool _hasImportedWebDraft() {
    final Object? transfer = readJson(
      File('${widget.entry.dir.path}/web-transfer.json'),
    );
    if (transfer is! Json || transfer['preparation'] is! Json) return false;
    final Object? results = (transfer['preparation']! as Json)['results'];
    return results is Json && results.isNotEmpty;
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
            if (_hasImportedWebDraft())
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                title: const Text('网页整理草稿'),
                subtitle: const Text('查看跨端带来的已读人物、前情和关系'),
                trailing: Icon(Icons.chevron_right, color: t.ink3),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ImportedWebPreparationScreen(
                      entry: b,
                      progress: widget.library.progressOf(b.id),
                    ),
                  ),
                ),
              ),
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
              title: const Text('导出问题记录'),
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
                child: Text('移到回收站', style: TextStyle(color: t.danger)),
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
                      '书籍、人物资料、摘记和阅读进度会保留，可在设置 → 回收站恢复；仍占用存储空间。',
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
                          label: acting ? '正在移动…' : '移到回收站',
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
    final File modelBudgetFile = File(
      '${b.dir.path}/work/judge/model-budget.json',
    );
    late final Map<String, Object?> modelBudget;
    try {
      modelBudget = judge_budget.readModelJudgeBudget(modelBudgetFile);
    } on Object {
      modelBudget = const <String, Object?>{};
    }
    final File paidBudgetFile = File(
      '${b.dir.path}/work/judge/paid-budget.json',
    );
    late final Map<String, Object?> paidBudget;
    try {
      paidBudget = judge_budget.readPaidJudgeBudget(paidBudgetFile);
    } on Object {
      paidBudget = <String, Object?>{};
    }
    final String? statusError = s.error;
    final bool freeAccessBlocked =
        statusError != null &&
        (statusError.contains('proxy_requires_payment') ||
            statusError.contains('classifier.dev HTTP 401') ||
            statusError.contains('classifier.dev HTTP 403') ||
            statusError.contains('匿名免费额度不可用'));
    final bool deniedWorkspaceKey = statusError?.contains('工作区密钥访问被拒绝') == true;
    final bool deniedAnonymous =
        statusError != null &&
        (statusError.contains('proxy_requires_payment') ||
            statusError.contains('匿名免费额度不可用') ||
            statusError.contains('匿名访问被拒绝'));
    final bool jevAuthFailed = statusError?.contains('Jev HTTP 401') == true;
    final bool modelBudgetExceeded =
        statusError?.contains('模型判断额度已达上限') == true;
    final bool paidBudgetExceeded = statusError?.contains('付费裁判预算已达上限') == true;
    final String? bookJudgeRoute = _bookJudgeFallback(b.dir);
    final String effectiveJudgeRoute =
        bookJudgeRoute ??
        (widget.settings.systemOneEnabled
            ? 'systemone'
            : widget.settings.judgeRoute == 'model'
            ? 'model-direct'
            : widget.settings.judgeFallbackEnabled
            ? 'model'
            : 'free');
    final bool modelFallback = effectiveJudgeRoute == 'model';
    final bool paidFallback = effectiveJudgeRoute == 'jev';
    final bool directModel = effectiveJudgeRoute == 'model-direct';
    final bool directPaid = effectiveJudgeRoute == 'jev-direct';
    final bool modelUsesBudget = modelFallback || directModel;
    final bool paidUsesBudget = paidFallback || directPaid;
    final Json? quality = s.raw['quality'] as Json?;
    final int pendingBiographyCount = quality?['pending'] is List<Object?>
        ? (quality!['pending']! as List<Object?>)
              .where(
                (Object? item) =>
                    item is String && RegExp(r'^bio-\d+$').hasMatch(item),
              )
              .length
        : 0;
    final bool pendingBiographyNeedsReview = _hasReviewablePendingBiography(
      quality?['pending'],
    );
    final bool biographyNeedsReview =
        pendingBiographyNeedsReview ||
        (statusError != null &&
            RegExp(r'人物小传通过\s*0/\d+.*拦截\s*[1-9]\d*').hasMatch(statusError));
    List<Widget> directReviewActions() {
      final bool canChooseModel =
          widget.settings.hasKey && !directModel && !modelBudgetExceeded;
      final bool canChooseJev =
          widget.settings.hasKey &&
          widget.settings.hasJevApiKey &&
          !directPaid &&
          !paidBudgetExceeded;
      if (!(biographyNeedsReview ||
              statusError?.contains('判断回答不完整') == true ||
              statusError?.contains('核对失败') == true) ||
          (!canChooseModel && !canChooseJev)) {
        return const <Widget>[];
      }
      return <Widget>[
        const SizedBox(height: 10),
        Text(
          biographyNeedsReview
              ? '这些小传暂时无法确认是否符合原文，因此还没有显示。你可以换一个模型重新检查；只影响这本书，可能产生模型费用。'
              : '可以换一个模型检查这本书的整理结果。只影响这本书，可能产生模型费用。',
          style: TextStyle(fontSize: 13, height: 1.5, color: t.ink2),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: <Widget>[
            if (canChooseModel)
              Pill(
                label: '用当前模型重新检查',
                onTap: acting ? null : _retryWithDirectModel,
              ),
            if (canChooseJev)
              Pill(
                label: '用 Jev 重新检查',
                onTap: acting ? null : _retryWithDirectJev,
              ),
          ],
        ),
      ];
    }

    if (workerStopped && s.isActive) {
      body.add(
        Text(
          '整理意外停止。请重新打开页读，再点“继续整理”。',
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
          '正在暂停，已完成的内容会保留。如果使用付费服务，已经开始的处理仍可能收费。',
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
            '正在等待第一段的整理结果，完成后会更新进度。',
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
            '正文按段整理，人物小传在章节整理后生成。',
            style: TextStyle(fontSize: 12, color: t.ink3),
          ),
        ],
        if (pendingBiographyCount > 0) ...<Widget>[
          const SizedBox(height: 5),
          Text(
            '$pendingBiographyCount 章的人物小传还需要检查，正文会继续整理。',
            style: TextStyle(fontSize: 12, color: t.amber),
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
              '发现人物后，还需要整理资料才能生成人物小传。',
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
      if (quality != null &&
          (quality['state'] == 'pending' || quality['pending'] == true)) {
        body.addAll(<Widget>[
          const SizedBox(height: 8),
          Text(
            pendingBiographyCount > 0
                ? '正文已整理完，$pendingBiographyCount 章人物小传待检查'
                : '部分资料还需要检查',
            style: TextStyle(fontSize: 13, color: t.ink2),
          ),
          const SizedBox(height: 8),
          Pill(
            label: '重新检查未完成的资料',
            onTap: acting
                ? null
                : () {
                    HapticFeedback.lightImpact();
                    _start();
                  },
          ),
        ]);
        body.addAll(directReviewActions());
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
          s.raw['pause_reason'] == 'scope_complete'
              ? '本次范围已完成，已停止。选择新的范围后才会继续调用模型。'
              : '已暂停。已经整理好的部分可以直接看。',
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
        if (s.error != null && s.error!.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            processingErrorMessage(s.error),
            style: TextStyle(fontSize: 13, height: 1.5, color: t.amber),
          ),
        ],
        if (lastWork != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            '暂停前最后阶段：${_lastStageSummary(lastWork)}${lastWorkAt.isEmpty ? '' : ' · $lastWorkAt'}',
            style: TextStyle(fontSize: 13, color: t.ink2),
          ),
        ],
        const SizedBox(height: 10),
        Pill(
          label: s.raw['pause_reason'] == 'scope_complete' ? '选择下一次范围' : '继续整理',
          filled: true,
          color: t.zhu,
          onTap: acting
              ? null
              : () {
                  HapticFeedback.lightImpact();
                  if (s.raw['pause_reason'] == 'scope_complete') {
                    _adjustPlan();
                  } else {
                    _start();
                  }
                },
        ),
      ]);
      body.addAll(directReviewActions());
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
          autoRetry ? '暂时连不上 AI 服务，稍后会自动再试' : '整理遇到问题',
          style: TextStyle(
            fontSize: 15,
            color: t.amber,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          freeAccessBlocked
              ? deniedWorkspaceKey
                    ? 'classifier.dev 暂时无法使用。请在模型设置中检查该服务的密钥和余额，或换一个检查服务。进度已保留。'
                    : deniedAnonymous
                    ? '免费检查服务暂时无法使用。进度已保留，可以换一个检查服务继续。'
                    : 'classifier.dev 暂时无法使用。请检查该服务的设置，或换一个检查服务。进度已保留。'
              : jevAuthFailed
              ? 'Jev 密钥无效，请在模型设置中重新填写，或改用当前模型检查。进度已保留。'
              : modelBudgetExceeded
              ? '本书已达到你允许检查的次数。进度已保留，增加次数后可以继续。'
              : paidBudgetExceeded
              ? '本书已达到你允许使用 Jev 的次数。进度已保留，增加次数后可以继续。'
              : processingErrorMessage(s.error),
          style: TextStyle(fontSize: 14, height: 1.5, color: t.ink),
        ),
        if (freeAccessBlocked &&
            !modelFallback &&
            widget.settings.hasKey) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            '用 ${widget.settings.read().$2} 检查这本书的内容，可能产生模型费用。先允许检查 ${judge_budget.modelJudgeInitialCalls} 次，之后可以增加。',
            style: TextStyle(fontSize: 13, height: 1.5, color: t.ink2),
          ),
          const SizedBox(height: 8),
          Pill(
            label: '用已配置模型继续整理',
            filled: true,
            color: t.zhu,
            onTap: acting ? null : _continueWithModel,
          ),
        ],
        if (freeAccessBlocked &&
            !paidFallback &&
            widget.settings.hasJevApiKey) ...<Widget>[
          const SizedBox(height: 10),
          Text(
            '用 Jev 检查这本书的内容，会使用你在 TypeSafe AI 的账户余额。',
            style: TextStyle(fontSize: 13, height: 1.5, color: t.ink2),
          ),
          const SizedBox(height: 8),
          Pill(
            label: '用 Jev 继续整理',
            filled: true,
            color: t.zhu,
            onTap: acting ? null : _continueWithJev,
          ),
        ],
        if (!freeAccessBlocked) ...directReviewActions(),
        if (jevAuthFailed &&
            widget.settings.hasKey &&
            !directModel &&
            !modelBudgetExceeded) ...<Widget>[
          const SizedBox(height: 10),
          Pill(label: '改用当前模型检查', onTap: acting ? null : _retryWithDirectModel),
        ],
        if (modelBudgetExceeded) ...<Widget>[
          const SizedBox(height: 8),
          Pill(
            label: '再允许检查 ${judge_budget.modelJudgeTopUpCalls} 次',
            filled: true,
            color: t.zhu,
            onTap: acting ? null : _extendJudgeBudget,
          ),
        ],
        if (paidBudgetExceeded) ...<Widget>[
          const SizedBox(height: 8),
          Pill(
            label: '再允许使用 Jev ${judge_budget.paidJudgeTopUpCalls} 次',
            filled: true,
            color: t.zhu,
            onTap: acting ? null : _extendPaidJudgeBudget,
          ),
        ],
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
            if (!workerStopped &&
                !modelBudgetExceeded &&
                !paidBudgetExceeded &&
                !(freeAccessBlocked &&
                    !modelUsesBudget &&
                    !paidUsesBudget &&
                    !widget.settings.hasClassifierKey))
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
        _plan().pendingCharacters(s.frontier),
        lang: b.lang,
        model: widget.settings.read().$2,
      );
      final int? minutes = models.deviceMinutes(
        _plan().pendingCharacters(s.frontier),
        lang: b.lang,
        model: widget.settings.read().$2,
        concurrency: phoneConcurrency,
      );
      final String cost = minutes == null || estimate['high'] == null
          ? '费用按你的模型接口计费。'
          : '正文整理预计约 $minutes 分钟、约 ¥${estimate['high']}（${estimate['model']}）';
      body.add(
        Text(
          '按你选择的范围整理人物、关系和前情。先试首章，再按需要继续；资料只显示到当前阅读位置。',
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
          PreparationPlanEditor(
            plan: _plan(),
            frontier: s.frontier,
            onChanged: (NativePreparationPlan plan) =>
                setState(() => _selectedPlan = plan),
          ),
          const SizedBox(height: 10),
          Text(
            '$cost${modelFallback || directModel ? ' 用当前模型检查内容也可能产生费用。' : ''}${paidFallback || directPaid ? ' 使用 Jev 检查内容会按该服务的价格收费。' : ''}',
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
    if ((s.isPaused || s.isError || s.isDone) && !acting) {
      body.add(
        TextButton.icon(
          onPressed: _adjustPlan,
          icon: const Icon(Icons.tune),
          label: const Text('调整整理范围'),
        ),
      );
    }
    if (s.isActive || s.isPaused || s.isError || s.isDone) {
      body.insert(
        0,
        PreparationProgress(
          status: s,
          plan: _plan(),
          latest:
              activity.reversed
                  .where((Json row) => row['stage'] != null)
                  .firstOrNull ??
              latestActivity,
          biographies: bios.count,
        ),
      );
      final String modelName = widget.settings.read().$2;
      body.insertAll(0, <Widget>[
        Text(
          effectiveJudgeRoute == 'systemone'
              ? '内容检查： ${widget.settings.judgeModel.isEmpty ? '服务默认模型' : widget.settings.judgeModel}'
              : directPaid
              ? '内容检查：Jev（仅本书）'
              : directModel
              ? '内容检查：$modelName（仅本书）'
              : paidFallback
              ? '内容检查：免费服务不可用时，改用 Jev（仅本书）'
              : modelFallback
              ? '内容检查：免费服务不可用时，改用 $modelName'
              : widget.settings.hasClassifierKey
              ? '内容检查：classifier.dev'
              : '内容检查：免费服务',
          style: TextStyle(fontSize: 12, color: t.ink2),
        ),
        if (modelUsesBudget && modelBudget.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text(
              '本书已检查 ${modelBudget['calls']} 次，最多允许 ${modelBudget['max_calls']} 次（不是账户余额）',
              style: TextStyle(fontSize: 12, color: t.ink3),
            ),
          )
        else if (paidUsesBudget)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text(
              '本书已使用 Jev ${paidBudget['calls'] ?? 0} 次，最多允许 ${paidBudget['max_calls'] ?? judge_budget.paidJudgeDefaultCalls} 次（不是账户余额）',
              style: TextStyle(fontSize: 12, color: t.ink3),
            ),
          )
        else
          const SizedBox(height: 8),
      ]);
      if (bookJudgeRoute == 'jev' ||
          bookJudgeRoute == 'jev-direct' ||
          bookJudgeRoute == 'model-direct' ||
          (bookJudgeRoute == 'model' &&
              !widget.settings.judgeFallbackEnabled)) {
        body.add(
          Pill(
            label: s.isActive ? '暂停并使用设置中的检查方式' : '使用设置中的检查方式',
            onTap: acting ? null : _disableBookJudgeFallback,
          ),
        );
      }
    }
    if (bios.firstEnd != null) {
      final int? chapter = _biographyChapter(bios.firstEnd!);
      final String unlockAt = chapter == null ? '对应章节末' : '第 $chapter 章末';
      body.add(
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            '已生成 ${bios.count} 篇人物小传。读到$unlockAt可查看首批内容，不会提前透露后面的情节。',
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
