import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/library.dart';
import '../data/note_drafts.dart';
import '../ui/theme.dart';

/// S17 笔记编辑: quote on top, autofocus, drafts survive closing.
class NoteEditor extends StatefulWidget {
  const NoteEditor({
    super.key,
    required this.book,
    required this.start,
    required this.end,
    required this.cutoff,
    this.existing,
    required this.draftDir,
  });

  final BookData book;
  final int start;
  final int end;
  final int cutoff;
  final Json? existing;
  final Directory draftDir;

  static Future<void> open(
    BuildContext context, {
    required BookData book,
    required int start,
    required int end,
    required int cutoff,
    Json? existing,
  }) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (BuildContext _) => NoteEditor(
        book: book,
        start: start,
        end: end,
        cutoff: cutoff,
        existing: existing,
        draftDir: book.entry.dir,
      ),
    );
    if (NoteDraft.fileFor(
          book.entry.dir,
          start,
          end,
          existing?['id'] as String?,
        ).existsSync() &&
        messenger.mounted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('草稿已保留，可在设置 → 未保存笔记草稿继续编辑')),
      );
    }
  }

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  late final TextEditingController text;
  String? error;

  bool _recovered = false;
  bool _staleDraft = false;
  bool _draftBlocked = false;
  int? _baseRevision;
  String get _original => '${widget.existing?['text'] ?? ''}';
  File get _draft => NoteDraft.fileFor(
    widget.draftDir,
    widget.start,
    widget.end,
    widget.existing?['id'] as String?,
  );

  @override
  void initState() {
    super.initState();
    String initial = _original;
    _baseRevision = widget.existing?['revision'] as int?;
    try {
      if (_draft.existsSync()) {
        final NoteDraft draft = NoteDraft.fromJson(readJson(_draft)! as Json);
        if (draft.start != widget.start ||
            draft.end != widget.end ||
            draft.noteId != widget.existing?['id'] ||
            draft.source !=
                NoteDraft.sourceFor(widget.book, widget.start, widget.end)) {
          _draftBlocked = true;
          error = '这份草稿对应的原文或笔记已变化，未自动载入。原草稿仍保留，本次编辑已锁定以避免覆盖。';
        } else if (draft.end > widget.cutoff || draft.cutoff > widget.cutoff) {
          _draftBlocked = true;
          error = '这份草稿涉及较后的阅读位置。为避免剧透，请回到写下它的位置后再恢复；原草稿仍保留。';
        } else {
          initial = draft.text;
          _recovered = true;
          _staleDraft =
              widget.existing != null && draft.revision != _baseRevision;
          _baseRevision = draft.revision;
        }
      } else if (widget.existing == null) {
        final File legacy = File(
          '${widget.draftDir.path}/.note-draft-${widget.start}-${widget.end}.txt',
        );
        if (legacy.existsSync()) {
          _draftBlocked = true;
          error = '旧版草稿缺少原文与阅读位置记录，未自动显示。原始文件仍保留，本次编辑已锁定以避免剧透或覆盖。';
        }
      }
    } on Object catch (e) {
      _draftBlocked = true;
      error = '草稿读取失败，原始内容仍保留。本次编辑已锁定以避免覆盖：$e';
    }
    if (((widget.existing?['knowledge_cutoff'] as num?)?.toInt() ?? 0) >
            widget.cutoff ||
        widget.end > widget.cutoff) {
      initial = '';
      _draftBlocked = true;
      _recovered = false;
      error = '这条笔记涉及较后的阅读位置，请回到写下它的位置后再编辑。笔记与草稿仍保留。';
    }
    text = TextEditingController(text: initial)..addListener(_keepDraft);
  }

  void _keepDraft() {
    if (_draftBlocked) return;
    try {
      if (text.text == _original && !_staleDraft) {
        if (_draft.existsSync()) _draft.deleteSync();
      } else {
        NoteDraft(
          start: widget.start,
          end: widget.end,
          cutoff: widget.cutoff,
          text: text.text,
          source: NoteDraft.sourceFor(widget.book, widget.start, widget.end),
          noteId: widget.existing?['id'] as String?,
          revision: _baseRevision,
        ).write(widget.draftDir);
      }
    } on Object catch (e) {
      setState(() => error = '草稿保存失败，请保留当前输入：$e');
    }
  }

  Future<void> _discardDraft() async {
    if (_draftBlocked) return;
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('放弃未保存的修改？'),
        content: const Text('只清除此草稿，已保存的笔记不变。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('继续编辑'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('放弃草稿'),
          ),
        ],
      ),
    );
    if (discard != true || !mounted) return;
    try {
      if (_draft.existsSync()) _draft.deleteSync();
      _staleDraft = false;
      _baseRevision = widget.existing?['revision'] as int?;
      text.text = _original;
      setState(() {
        _recovered = false;
        error = null;
      });
    } on Object catch (e) {
      setState(() => error = '草稿未能清除：$e');
    }
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  void _save() {
    if (_draftBlocked) return;
    HapticFeedback.lightImpact();
    try {
      widget.book.notes.save(
        id: _staleDraft ? null : widget.existing?['id'] as String?,
        expectedRevision: _staleDraft ? null : _baseRevision,
        kind: 'note',
        start: widget.start,
        end: widget.end,
        text: text.text.trim(),
        cutoff: widget.cutoff,
      );
    } on Object catch (e) {
      setState(() => error = '$e');
      return;
    }
    // The note is already durable. A draft cleanup failure must not leave a
    // new-note editor open where pressing save again would create a duplicate.
    String? cleanupError;
    {
      try {
        if (_draft.existsSync()) _draft.deleteSync();
        if (widget.existing == null) {
          final File legacy = File(
            '${widget.draftDir.path}/.note-draft-${widget.start}-${widget.end}.txt',
          );
          if (legacy.existsSync()) legacy.deleteSync();
        }
      } on Object catch (e) {
        cleanupError = '笔记已保存，草稿清理失败：$e';
      }
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    if (cleanupError != null) {
      messenger.showSnackBar(SnackBar(content: Text(cleanupError)));
    }
  }

  Future<void> _delete() async {
    if (_draftBlocked) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('删除这条笔记？'),
        content: const Text('摘录和想法都会从摘记列表移除。'),
        actions: <Widget>[
          TextButton(
            onPressed: () {
              HapticFeedback.lightImpact();
              Navigator.pop(context, false);
            },
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              HapticFeedback.mediumImpact();
              Navigator.pop(context, true);
            },
            child: Text(
              '删除',
              style: TextStyle(
                color: Theme.of(context).extension<Tokens>()!.danger,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    HapticFeedback.mediumImpact();
    try {
      widget.book.notes.delete(widget.existing!);
      if (_draft.existsSync()) _draft.deleteSync();
      Navigator.of(context).pop();
    } on Object catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final String quote = widget.end <= widget.cutoff
        ? widget.book.textBetween(widget.start, widget.end)
        : '';
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: t.rule,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            if (quote.isNotEmpty)
              Container(
                margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                decoration: BoxDecoration(
                  color: t.paper,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: t.rule.withValues(alpha: 0.7)),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(9),
                  child: IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Container(width: 4, color: t.qing),
                        Expanded(
                          child: Container(
                            constraints: const BoxConstraints(maxHeight: 120),
                            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                            child: SingleChildScrollView(
                              child: Text(
                                quote,
                                style: TextStyle(
                                  fontFamily: serif,
                                  fontSize: 15,
                                  height: 1.7,
                                  color: t.ink2,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: TextField(
                controller: text,
                enabled: !_draftBlocked,
                autofocus: !_draftBlocked,
                minLines: 4,
                maxLines: 10,
                maxLength: 10000,
                style: TextStyle(fontSize: 16, height: 1.6, color: t.ink),
                decoration: const InputDecoration(
                  hintText: '写下你的想法',
                  border: InputBorder.none,
                  counterText: '',
                ),
              ),
            ),
            if ((_recovered || _staleDraft) && !_draftBlocked)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _staleDraft ? '原笔记已有新版本。已找回草稿，可另存一条笔记。' : '已恢复未保存的草稿',
                        style: TextStyle(color: t.ink2),
                      ),
                    ),
                    TextButton(
                      onPressed: _discardDraft,
                      child: const Text('放弃草稿'),
                    ),
                  ],
                ),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(error!, style: TextStyle(color: t.danger)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 20, 12),
              child: Row(
                children: <Widget>[
                  if (widget.existing != null && !_draftBlocked)
                    TextButton(
                      onPressed: _delete,
                      child: Text('删除', style: TextStyle(color: t.danger)),
                    ),
                  const Spacer(),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: text,
                    builder:
                        (
                          BuildContext context,
                          TextEditingValue val,
                          Widget? _,
                        ) {
                          final int count = val.text.trim().length;
                          if (count == 0) return const SizedBox.shrink();
                          return Padding(
                            padding: const EdgeInsets.only(right: 12),
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
                          );
                        },
                  ),
                  if (_draftBlocked)
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('关闭并保留草稿'),
                    )
                  else
                    Pill(
                      label: _staleDraft ? '另存为新笔记' : '保存',
                      filled: true,
                      color: t.qing,
                      onTap: _save,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
