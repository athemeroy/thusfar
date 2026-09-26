import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/library.dart';
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
    if (existing == null &&
        File(
          '${book.entry.dir.path}/.note-draft-$start-$end.txt',
        ).existsSync()) {
      if (messenger.mounted) {
        messenger.showSnackBar(const SnackBar(content: Text('草稿已保留')));
      }
    }
  }

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  late final TextEditingController text;
  String? error;

  File get _draft => File(
    '${widget.draftDir.path}/.note-draft-${widget.start}-${widget.end}.txt',
  );

  @override
  void initState() {
    super.initState();
    String initial = '${widget.existing?['text'] ?? ''}';
    try {
      if (widget.existing == null && _draft.existsSync()) {
        initial = _draft.readAsStringSync();
      }
    } on Object catch (e) {
      error = '草稿读取失败：$e';
    }
    text = TextEditingController(text: initial)..addListener(_keepDraft);
  }

  void _keepDraft() {
    if (widget.existing != null) return;
    try {
      if (text.text.isEmpty) {
        if (_draft.existsSync()) _draft.deleteSync();
      } else {
        _draft.writeAsStringSync(text.text);
      }
    } on Object catch (e) {
      setState(() => error = '草稿保存失败，请保留当前输入：$e');
    }
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  void _save() {
    HapticFeedback.lightImpact();
    try {
      widget.book.notes.save(
        id: widget.existing?['id'] as String?,
        expectedRevision: widget.existing?['revision'] as int?,
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
    if (widget.existing == null) {
      try {
        if (_draft.existsSync()) _draft.deleteSync();
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
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    HapticFeedback.mediumImpact();
    try {
      widget.book.notes.delete(widget.existing!);
      Navigator.of(context).pop();
    } on Object catch (e) {
      setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final String quote = widget.book.textBetween(widget.start, widget.end);
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
                        Container(
                          width: 4,
                          color: t.qing,
                        ),
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
                autofocus: true,
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
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(error!, style: TextStyle(color: t.danger)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 20, 12),
              child: Row(
                children: <Widget>[
                  if (widget.existing != null)
                    TextButton(
                      onPressed: _delete,
                      child: Text('删除', style: TextStyle(color: t.danger)),
                    ),
                  const Spacer(),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: text,
                    builder: (BuildContext context, TextEditingValue val, Widget? _) {
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
                  Pill(label: '保存', filled: true, color: t.qing, onTap: _save),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
