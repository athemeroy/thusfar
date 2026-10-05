import 'package:flutter/material.dart';
import '../data/library.dart';
import '../data/note_drafts.dart';
export '../ui/restore_report_view.dart';
import '../sheets/note_editor.dart';

class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key, required this.library});
  final Library library;
  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  bool _busy = false;
  String? _error;
  List<TrashedBook> _books = [];
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    try {
      _books = widget.library.listTrash();
    } on Object catch (e) {
      _error = '无法读取回收站：$e';
    }
  }

  Future<void> _act(TrashedBook book, {bool permanent = false}) async {
    if (_busy) return;
    if (permanent) {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('永久删除这本书？'),
          content: Text(
            '《${book.title}》的正文、笔记、草稿和阅读进度将从这台设备永久删除，无法撤销。其他备份不受影响。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('永久删除'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (permanent) {
        await widget.library.permanentlyDelete(book);
      } else {
        await widget.library.restoreFromTrash(book);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(permanent ? '已永久删除' : '已恢复到书架，阅读进度和摘记已保留')),
        );
      }
    } on Object catch (e) {
      _error = '$e';
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _refresh();
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('回收站')),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text('移除的书籍仍占用设备空间。恢复会找回正文、摘记和阅读进度；永久删除前会再次确认。'),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: SelectableText(_error!),
          ),
        if (_books.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('回收站是空的')),
          ),
        for (final TrashedBook book in _books)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    '${book.removed.toLocal().toString().split('.').first} · ${(book.bytes / 1024 / 1024).toStringAsFixed(1)} MB',
                  ),
                  if (book.issue != null) Text(book.issue!),
                  Wrap(
                    spacing: 12,
                    children: [
                      FilledButton.tonal(
                        onPressed: _busy || !book.canRestore
                            ? null
                            : () => _act(book),
                        child: const Text('恢复到书架'),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _act(book, permanent: true),
                        child: const Text('永久删除'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

class NoteDraftsScreen extends StatefulWidget {
  const NoteDraftsScreen({super.key, required this.library});
  final Library library;
  @override
  State<NoteDraftsScreen> createState() => _NoteDraftsScreenState();
}

class _NoteDraftsScreenState extends State<NoteDraftsScreen> {
  List<(BookEntry, NoteDraft)> _drafts = [];
  String? _error;
  @override
  void initState() {
    super.initState();
    _read();
  }

  void _read() {
    try {
      _drafts = [
        for (final book in widget.library.books)
          for (final draft in NoteDraft.list(book.dir)) (book, draft),
      ];
    } on Object catch (e) {
      _error = '$e';
    }
  }

  Future<void> _open(BookEntry entry, NoteDraft draft) async {
    final BookData book = BookData.open(entry);
    try {
      final int cutoff = widget.library.progressOf(entry.id)?.cutoff ?? 0;
      if (draft.end > cutoff || draft.cutoff > cutoff) {
        setState(() => _error = '这份草稿涉及较后的阅读位置。为避免剧透，请回到写下它的位置后再恢复。');
        return;
      }
      if (draft.source != NoteDraft.sourceFor(book, draft.start, draft.end)) {
        setState(() => _error = '草稿对应的原文已变化，未打开。草稿仍保留在这台设备。');
        return;
      }
      Json? existing;
      if (draft.noteId != null) {
        existing = book.notes.live
            .where((row) => row['id'] == draft.noteId)
            .firstOrNull;
        if (existing == null) {
          setState(() => _error = '原笔记已删除。草稿仍保留，未自动新建或覆盖其他笔记。');
          return;
        }
      }
      if (!mounted) return;
      await NoteEditor.open(
        context,
        book: book,
        start: draft.start,
        end: draft.end,
        cutoff: cutoff,
        existing: existing,
      );
      if (mounted) setState(_read);
    } on Object catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      book.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('未保存笔记草稿')),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const Text('草稿仅保存在这台设备，尚未写入正式笔记或书籍备份。关闭编辑器后，可在这里继续。'),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_error!),
          ),
        if (_drafts.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Center(child: Text('没有未保存的草稿')),
          ),
        for (final (BookEntry book, NoteDraft draft) in _drafts)
          Card(
            child: ListTile(
              title: Text(book.title),
              subtitle: Text(
                '${draft.noteId == null ? '新笔记草稿' : '现有笔记的未保存修改'} · 原文位置 ${draft.start}–${draft.end}',
              ),
              trailing: const Icon(Icons.edit_note),
              onTap: () => _open(book, draft),
            ),
          ),
      ],
    ),
  );
}
