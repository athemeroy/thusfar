import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'library.dart';

/// A draft belongs to one book, one excerpt, and optionally one note revision.
/// It never writes the notebook until the reader explicitly saves it.
class NoteDraft {
  const NoteDraft({
    required this.start,
    required this.end,
    required this.cutoff,
    required this.text,
    required this.source,
    this.noteId,
    this.revision,
  });
  final int start;
  final int end;
  final int cutoff;
  final String text;
  final String source;
  final String? noteId;
  final int? revision;

  static String sourceFor(BookData book, int start, int end) => sha256
      .convert(
        utf8.encode(
          '${book.entry.id}:${book.book['len']}:$start:$end:${book.textBetween(start, end)}',
        ),
      )
      .toString();
  static File fileFor(Directory dir, int start, int end, String? noteId) {
    final String key = sha256
        .convert(utf8.encode('$start:$end:${noteId ?? 'new'}'))
        .toString()
        .substring(0, 24);
    return File('${dir.path}/.note-draft-v2-$key.json');
  }

  Map<String, Object?> toJson() => {
    'start': start,
    'end': end,
    'cutoff': cutoff,
    'text': text,
    'source': source,
    'noteId': noteId,
    'revision': revision,
  };
  factory NoteDraft.fromJson(Json raw) => NoteDraft(
    start: raw['start'] as int,
    end: raw['end'] as int,
    cutoff: raw['cutoff'] as int,
    text: raw['text'] as String,
    source: raw['source'] as String,
    noteId: raw['noteId'] as String?,
    revision: raw['revision'] as int?,
  );
  void write(Directory dir) =>
      writeJson(fileFor(dir, start, end, noteId), toJson());
  static List<NoteDraft> list(Directory dir) {
    final List<NoteDraft> result = <NoteDraft>[];
    for (final FileSystemEntity f in dir.listSync(followLinks: false)) {
      if (f is! File ||
          !RegExp(r'/\.note-draft-v2-[0-9a-f]{24}\.json$').hasMatch(f.path)) {
        continue;
      }
      try {
        final Object? raw = readJson(f);
        if (raw is Json) result.add(NoteDraft.fromJson(raw));
      } on Object {
        /* Keep unreadable drafts untouched for manual recovery. */
      }
    }
    return result;
  }
}
