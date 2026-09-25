import 'dart:io';

import 'package:flutter/material.dart';

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
      messenger.showSnackBar(const SnackBar(content: Text('草稿已保留')));
    }
  }

  @override
  State<NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<NoteEditor> {
  late final TextEditingController text;

  File get _draft => File(
    '${widget.draftDir.path}/.note-draft-${widget.start}-${widget.end}.txt',
  );

  @override
  void initState() {
    super.initState();
    final String initial = widget.existing != null
        ? '${widget.existing!['text']}'
        : (_draft.existsSync() ? _draft.readAsStringSync() : '');
    text = TextEditingController(text: initial)..addListener(_keepDraft);
  }

  void _keepDraft() {
    if (widget.existing != null) return;
    if (text.text.isEmpty) {
      if (_draft.existsSync()) _draft.deleteSync();
    } else {
      _draft.writeAsStringSync(text.text);
    }
  }

  @override
  void dispose() {
    text.dispose();
    super.dispose();
  }

  void _save() {
    widget.book.notes.save(
      id: widget.existing?['id'] as String?,
      kind: 'note',
      start: widget.start,
      end: widget.end,
      text: text.text.trim(),
      cutoff: widget.cutoff,
    );
    if (_draft.existsSync()) _draft.deleteSync();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final Tokens t = context.tk;
    final String quote = widget.book.textBetween(widget.start, widget.end);
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
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
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: t.qing, width: 3)),
              ),
              constraints: const BoxConstraints(maxHeight: 120),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 20, 12),
            child: Row(
              children: <Widget>[
                if (widget.existing != null)
                  TextButton(
                    onPressed: () {
                      widget.book.notes.delete(widget.existing!);
                      Navigator.of(context).pop();
                    },
                    child: Text('删除', style: TextStyle(color: t.danger)),
                  ),
                const Spacer(),
                Pill(label: '保存', filled: true, color: t.qing, onTap: _save),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
