import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:thusfar_core/thusfar_core.dart';
import 'package:thusfar_core/storage.dart' as storage;
import 'package:thusfar_core/jobs.dart' show RunLease;

export 'package:thusfar_core/thusfar_core.dart' show Json;

Object? readJson(File f) {
  if (!f.existsSync()) return null;
  try {
    return jsonDecode(f.readAsStringSync());
  } on FormatException {
    return null;
  }
}

/// Atomic JSON write in the Python format, so 1.7.x can still read it.
void writeJson(File f, Object? value) => storage.writeJson(f, value);

/// Reading progress as 1.7.x stored it in `progress.json`.
class Progress {
  const Progress({
    required this.pos,
    required this.cutoff,
    required this.t,
    required this.pct,
  });

  factory Progress.fromJson(Json j) => Progress(
    pos: (j['pos'] as num?)?.toInt() ?? 0,
    cutoff: (j['cutoff'] as num?)?.toInt() ?? 0,
    t: (j['t'] as num?)?.toDouble() ?? 0,
    pct: (j['pct'] as num?)?.toDouble() ?? 0,
  );

  final int pos;
  final int cutoff;
  final double t;
  final double pct;

  Json toJson() => <String, Object?>{
    'pos': pos,
    'cutoff': cutoff,
    't': t,
    'pct': pct,
  };
}

/// The processing state shown on the shelf and in the book drawer.
class ProcessStatus {
  const ProcessStatus(this.raw);

  final Json raw;

  String get state => '${raw['state'] ?? 'idle'}';
  int get done => (raw['done'] as num?)?.toInt() ?? 0;
  int get total => (raw['total'] as num?)?.toInt() ?? 0;
  int get frontier => (raw['frontier'] as num?)?.toInt() ?? 0;
  int get people => (raw['people'] as num?)?.toInt() ?? 0;
  String? get error => raw['error'] as String?;
  String? get notice => raw['notice'] as String?;
  List<Object?> get refused =>
      (raw['refused'] as List<Object?>?) ?? const <Object?>[];
  bool get isDone => state == 'done';
  bool get isRunning =>
      const <String>['queued', 'running', 'finalizing'].contains(state);
  bool get isCancelling => state == 'cancelling';
  bool get isActive => isRunning || isCancelling;
  bool get isPaused => state == 'paused';
  bool get isError => state == 'error';
  bool get isIdle =>
      !isDone && !isActive && !isPaused && !isError && frontier == 0;
}

/// One book on the shelf: cheap metadata only.
class BookEntry {
  BookEntry({
    required this.id,
    required this.dir,
    required this.meta,
    required this.status,
    required this.added,
  });

  final String id;
  final Directory dir;
  final Json meta;
  ProcessStatus status;
  final double added;
  int knowledgeRevision = 0;
  String? _processingStamp;

  String get rawTitle => '${meta['title'] ?? id}';
  String get title => storage
      .displayTitle(meta['title'] as String?, meta['author'] as String?)
      .$1;
  String get author => storage
      .displayTitle(meta['title'] as String?, meta['author'] as String?)
      .$2;
  int get length => (meta['len'] as num?)?.toInt() ?? 0;
  String? get cover => meta['cover'] as String?;
  File? get coverFile => cover == null ? null : File('${dir.path}/img/$cover');
  String get lang => '${meta['lang'] ?? 'zh'}';
}

/// All books under `<data>/books`, laid out exactly as 1.7.x wrote them.
class Library extends ChangeNotifier {
  Library(this.root);

  final Directory root;
  Directory get booksDir => Directory('${root.path}/books');
  List<BookEntry> books = <BookEntry>[];
  Map<String, Progress> progress = <String, Progress>{};
  List<String> readingList = <String>[];
  bool loaded = false;

  File get _progressFile => File('${root.path}/progress.json');
  File get _readingListFile => File('${root.path}/reading-list.json');

  Future<void> scan() async {
    booksDir.createSync(recursive: true);
    final List<BookEntry> found = <BookEntry>[];
    for (final FileSystemEntity e in booksDir.listSync()) {
      if (e is! Directory) continue;
      final String id = e.uri.pathSegments
          .where((String s) => s.isNotEmpty)
          .last;
      if (id.startsWith('.')) continue;
      final File bookFile = File('${e.path}/book.json');
      if (!bookFile.existsSync()) continue;
      final Json? meta = _shelfMeta(e, bookFile);
      if (meta == null) continue;
      final Json status =
          (readJson(File('${e.path}/status.json')) as Json?) ??
          <String, Object?>{};
      final Json info =
          (readJson(File('${e.path}/meta.json')) as Json?) ??
          <String, Object?>{};
      final BookEntry? existing = byId(id);
      if (existing != null && existing.dir.path == e.path) {
        existing.meta
          ..clear()
          ..addAll(meta);
        existing.status = ProcessStatus(status);
        existing.knowledgeRevision++;
        found.add(existing);
      } else {
        found.add(
          BookEntry(
            id: id,
            dir: e,
            meta: meta,
            status: ProcessStatus(status),
            added:
                (info['added'] as num?)?.toDouble() ??
                bookFile.statSync().modified.millisecondsSinceEpoch / 1000,
          ),
        );
      }
    }
    books = found;
    final Json p = (readJson(_progressFile) as Json?) ?? <String, Object?>{};
    progress = <String, Progress>{
      for (final MapEntry<String, Object?> e in p.entries)
        if (e.value is Json) e.key: Progress.fromJson(e.value! as Json),
    };
    final Json rl =
        (readJson(_readingListFile) as Json?) ?? <String, Object?>{};
    readingList = <String>[
      for (final Object? x
          in (rl['items'] as List<Object?>?) ?? const <Object?>[])
        '$x',
    ];
    loaded = true;
    notifyListeners();
  }

  /// `storage.shelf_metadata`: a small cached copy of the shelf fields.
  Json? _shelfMeta(Directory dir, File bookFile) {
    final FileStat st = bookFile.statSync();
    final List<Object?> stamp = <Object?>[
      st.modified.microsecondsSinceEpoch * 1000,
      st.size,
    ];
    final File shelf = File('${dir.path}/shelf.json');
    final Json? stored = readJson(shelf) as Json?;
    if (stored != null) {
      final List<Object?>? s = stored['source'] as List<Object?>?;
      final Json? b = stored['book'] as Json?;
      if (s != null &&
          s.length >= 2 &&
          s[1] == st.size &&
          b != null &&
          b['lang'] != null) {
        return b;
      }
    }
    final Json? book = readJson(bookFile) as Json?;
    if (book == null) return null;
    final Json fields = storage.shelfFields(book);
    try {
      writeJson(shelf, <String, Object?>{
        'source': <Object?>[stamp[0], stamp[1], 0],
        'book': fields,
      });
    } on FileSystemException {
      // A read-only data directory still shows the shelf.
    }
    return fields;
  }

  final Map<String, (int, List<(int, String)>)> _chapterCache =
      <String, (int, List<(int, String)>)>{};

  /// 「第二章 优胜记略 · 」 for the continue card; reads the book once per change.
  String chapterTitleAt(BookEntry b, int pos) {
    final File f = File('${b.dir.path}/book.json');
    final int stamp = f.statSync().modified.millisecondsSinceEpoch;
    (int, List<(int, String)>)? hit = _chapterCache[b.id];
    if (hit == null || hit.$1 != stamp) {
      final Json? book = readJson(f) as Json?;
      final List<(int, String)> chapters = <(int, String)>[];
      for (final Object? raw
          in (book?['chapters'] as List<Object?>?) ?? const <Object?>[]) {
        final Json c = raw! as Json;
        chapters.add(((c['o0'] as num?)?.toInt() ?? 0, '${c['title']}'));
      }
      hit = _chapterCache[b.id] = (stamp, chapters);
    }
    String title = '';
    for (final (int o0, String t) in hit.$2) {
      if (o0 <= pos) title = t;
    }
    return title.isEmpty ? '' : '$title · ';
  }

  BookEntry? byId(String id) {
    for (final BookEntry b in books) {
      if (b.id == id) return b;
    }
    return null;
  }

  Progress? progressOf(String id) => progress[id];

  void saveProgress(String id, int pos, int cutoff, int length) {
    progress[id] = Progress(
      pos: pos,
      cutoff: cutoff,
      t: DateTime.now().millisecondsSinceEpoch / 1000,
      pct: (cutoff / math.max(1, length) * 100 * 1000).round() / 1000,
    );
    writeJson(_progressFile, <String, Object?>{
      for (final MapEntry<String, Progress> e in progress.entries)
        e.key: e.value.toJson(),
    });
    notifyListeners();
  }

  void setReadingList(List<String> items) {
    readingList = List<String>.of(items);
    final Json current =
        (readJson(_readingListFile) as Json?) ??
        <String, Object?>{'revision': 0};
    writeJson(_readingListFile, <String, Object?>{
      'revision': ((current['revision'] as num?)?.toInt() ?? 0) + 1,
      'items': readingList,
      'operation': 'app-${DateTime.now().microsecondsSinceEpoch}',
      'updated': DateTime.now().millisecondsSinceEpoch / 1000,
    });
    notifyListeners();
  }

  /// Moves the book to `<data>/trash` like 1.7.x, keeping a recoverable copy.
  Future<void> remove(BookEntry b) async {
    // The worker has already been asked to stop. Hold its shared lease through
    // the rename so another isolate or Python process cannot resume meanwhile.
    final RunLease lease = await RunLease.acquire(b.dir);
    try {
      final File statusFile = File('${b.dir.path}/status.json');
      final Object? raw = statusFile.existsSync()
          ? jsonDecode(statusFile.readAsStringSync())
          : null;
      if (raw != null && raw is! Json) throw const FormatException('整理状态格式无效');
      final ProcessStatus current = ProcessStatus(
        raw as Json? ?? <String, Object?>{},
      );
      if (current.isActive) throw StateError('这本书还在停止整理，请稍后再移除');
      final Directory trash = Directory('${root.path}/trash')
        ..createSync(recursive: true);
      final String dest =
          '${trash.path}/${b.id}-${DateTime.now().microsecondsSinceEpoch * 1000}';
      b.dir.renameSync(dest);
      final Progress? old = progress.remove(b.id);
      if (old != null) {
        writeJson(File('$dest/reading-progress.json'), old.toJson());
      }
      writeJson(_progressFile, <String, Object?>{
        for (final MapEntry<String, Progress> e in progress.entries)
          e.key: e.value.toJson(),
      });
      if (readingList.contains(b.id)) {
        setReadingList(List<String>.of(readingList)..remove(b.id));
      }
      books.removeWhere((BookEntry entry) => entry.id == b.id);
      notifyListeners();
    } finally {
      lease.release();
    }
  }

  /// Refresh processing state and signal changes to the currently open reader.
  /// Atomic graph/mention replacements count even if progress did not advance.
  bool refreshStatus(BookEntry b) {
    if (!b.dir.existsSync()) return false;
    final File file = File('${b.dir.path}/status.json');
    Json state;
    try {
      final Object? raw = file.existsSync()
          ? jsonDecode(file.readAsStringSync())
          : <String, Object?>{};
      if (raw is! Json) throw const FormatException();
      state = raw;
    } on Object {
      state = <String, Object?>{
        ...b.status.raw,
        'state': 'error',
        'error': '无法读取整理状态，请检查书籍数据后重试',
      };
    }
    String stamp(String path) {
      final FileStat st = FileStat.statSync(path);
      return '${st.type}:${st.size}:${st.modified.microsecondsSinceEpoch}:${st.changed.microsecondsSinceEpoch}';
    }

    final String signature =
        '${jsonEncode(state)}|${stamp('${b.dir.path}/kg.json')}|${stamp('${b.dir.path}/mentions')}';
    if (signature == b._processingStamp) return false;
    b._processingStamp = signature;
    b.status = ProcessStatus(state);
    b.knowledgeRevision++;
    notifyListeners();
    return true;
  }
}

/// A chapter as the reader needs it.
class Chapter {
  Chapter(this.index, this.raw);

  final int index;
  final Json raw;
  String get title => '${raw['title']}';
  int get b0 => (raw['b0']! as num).toInt();
  int get b1 => (raw['b1']! as num).toInt();
  int get o0 => (raw['o0']! as num).toInt();
  int get o1 => (raw['o1']! as num).toInt();
  String get kind => '${raw['kind'] ?? 'body'}';
  int get depth => (raw['depth'] as num?)?.toInt() ?? 0;
}

/// A text block (`p` paragraph, `h` heading, `img` picture).
class Block {
  Block(this.raw);

  final Json raw;
  String get kind => '${raw['k']}';
  String get text => '${raw['t']}';
  int get o => (raw['o']! as num).toInt();
  int get end => o + text.length;
  String? get src => raw['src'] as String?;
  List<(int, String)> get footnotes {
    final List<(int, String)> out = <(int, String)>[];
    for (final Object? item
        in (raw['fn'] as List<Object?>?) ?? const <Object?>[]) {
      final List<Object?> f = item! as List<Object?>;
      out.add((f[0]! as int, '${f[1]}'));
    }
    return out;
  }
}

/// A name in the text: `[start, end, personId, generic]`, absolute UTF-16.
class Mention {
  const Mention(this.start, this.end, this.id, this.generic);

  final int start;
  final int end;
  final String id;
  final bool generic;
}

/// One opened book: text, chapters, the knowledge log and personal notes.
class BookData extends ChangeNotifier {
  BookData._(this.entry, this.book, this.blocks, this.chapters, this.records);

  static BookData open(BookEntry entry) {
    final Json book = readJson(File('${entry.dir.path}/book.json'))! as Json;
    final List<Block> blocks = <Block>[
      for (final Object? b in book['blocks']! as List<Object?>)
        Block(b! as Json),
    ];
    final List<Object?> rawChapters = book['chapters']! as List<Object?>;
    final List<Chapter> chapters = <Chapter>[
      for (int i = 0; i < rawChapters.length; i++)
        Chapter(i, rawChapters[i]! as Json),
    ];
    final Json kg =
        (readJson(File('${entry.dir.path}/kg.json')) as Json?) ??
        <String, Object?>{'log': <Object?>[]};
    final List<Json> records = <Json>[
      for (final Object? r
          in (kg['log'] as List<Object?>?) ?? const <Object?>[])
        r! as Json,
    ];
    final BookData data = BookData._(entry, book, blocks, chapters, records);
    data._loadedRevision = entry.knowledgeRevision;
    data.notes = NoteStore(File('${entry.dir.path}/notebook.json'), data);
    return data;
  }

  final BookEntry entry;
  final Json book;
  final List<Block> blocks;
  final List<Chapter> chapters;
  final List<Json> records;
  late final NoteStore notes;
  final Map<int, List<Mention>> _mentions = <int, List<Mention>>{};
  final Map<int, World> _worlds = <int, World>{};
  int _loadedRevision = -1;
  String? knowledgeError;

  /// Re-read durable knowledge after processing writes while retaining the
  /// reader's text, position and personal notes. Corruption keeps the last valid
  /// graph visible and reports a separate error instead of becoming empty data.
  bool refreshKnowledge() {
    if (_loadedRevision == entry.knowledgeRevision) return false;
    _loadedRevision = entry.knowledgeRevision;
    try {
      final File file = File('${entry.dir.path}/kg.json');
      final Object? raw = file.existsSync()
          ? jsonDecode(file.readAsStringSync())
          : <String, Object?>{'log': <Object?>[]};
      final Json graph = storage.validateGraph(raw, length);
      final List<Json> next = ((graph['log'] as List<Object?>?) ?? <Object?>[])
          .cast<Json>();
      records
        ..clear()
        ..addAll(next);
      knowledgeError = null;
    } on Object {
      knowledgeError = '人物资料暂时无法更新，仍显示上次整理好的内容。';
    }
    _mentions.clear();
    _worlds.clear();
    notifyListeners();
    return true;
  }

  String get id => entry.id;
  int get length => (book['len']! as num).toInt();
  Map<String, String> get footnoteText => <String, String>{
    for (final MapEntry<String, Object?> e
        in ((book['notes'] as Json?) ?? <String, Object?>{}).entries)
      e.key: '${e.value}',
  };
  ProcessStatus get status => entry.status;

  /// Mentions of chapter [n] that the processing has confirmed (end <= frontier).
  List<Mention> mentions(int n) => _mentions[n] ??= _loadMentions(n);

  List<Mention> _loadMentions(int n) {
    final String name = n.toString().padLeft(4, '0');
    final List<Object?> raw =
        (readJson(File('${entry.dir.path}/mentions/$name.json'))
            as List<Object?>?) ??
        const <Object?>[];
    final int frontier = status.frontier;
    final List<Mention> out = <Mention>[];
    for (final Object? item in raw) {
      final List<Object?> m = item! as List<Object?>;
      if ((m[1]! as num) > frontier) continue;
      out.add(
        Mention(
          (m[0]! as num).toInt(),
          (m[1]! as num).toInt(),
          '${m[2]}',
          m.length > 3 && m[3] != 0 && m[3] != false,
        ),
      );
    }
    return out;
  }

  /// What the reader knows at [cutoff] (memoised like `KG.world`).
  World world(int cutoff) {
    final World? hit = _worlds[cutoff];
    if (hit != null) return hit;
    if (_worlds.length > 40) _worlds.clear();
    final World w = fold(records, cutoff)
      ..frontier = status.frontier
      ..state = status.state;
    return _worlds[cutoff] = w;
  }

  bool get hasKnowledge => records.isNotEmpty;

  int chapterAt(int offset) {
    for (int i = chapters.length - 1; i >= 0; i--) {
      if (chapters[i].o0 <= offset) return i;
    }
    return 0;
  }

  /// Block index containing [offset].
  int blockAt(int offset) {
    int lo = 0;
    int hi = blocks.length - 1;
    while (lo < hi) {
      final int mid = (lo + hi + 1) ~/ 2;
      if (blocks[mid].o <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  /// Source text between absolute offsets, across blocks.
  String textBetween(int start, int end) {
    final StringBuffer out = StringBuffer();
    for (int i = blockAt(start); i < blocks.length; i++) {
      final Block b = blocks[i];
      if (b.o >= end) break;
      final int a = math.max(0, start - b.o);
      final int z = math.min(b.text.length, end - b.o);
      if (z > a) {
        if (out.isNotEmpty) out.write('\n');
        out.write(b.text.substring(a, z));
      }
    }
    return out.toString();
  }
}

/// `notebook.json`: excerpts, notes and bookmarks in UTF-16 source offsets.
class NoteStore extends ChangeNotifier {
  NoteStore(this.file, this.book) {
    final List<Object?> raw =
        (readJson(file) as List<Object?>?) ?? const <Object?>[];
    items = <Json>[for (final Object? x in raw) x! as Json];
  }

  final File file;
  final BookData book;
  late List<Json> items;

  List<Json> get live => items.where((Json x) => x['deleted'] != true).toList()
    ..sort(
      (Json a, Json b) => (a['start']! as num).compareTo(b['start']! as num),
    );
  List<Json> get bookmarks =>
      live.where((Json x) => x['kind'] == 'bookmark').toList();
  List<Json> get notes => live.where((Json x) => x['kind'] == 'note').toList();

  Json? bookmarkIn(int start, int end) {
    for (final Json b in bookmarks) {
      final int s = (b['start']! as num).toInt();
      if (s >= start && s < math.max(end, start + 1)) return b;
    }
    return null;
  }

  static String _id() {
    final math.Random r = math.Random.secure();
    return List<String>.generate(
      20,
      (_) => r.nextInt(36).toRadixString(36),
    ).join();
  }

  /// Creates or updates an item with the same validation as `notebook.apply`.
  Json save({
    String? id,
    required String kind,
    required int start,
    required int end,
    String text = '',
    required int cutoff,
  }) {
    final Json? old = id == null
        ? null
        : items.where((Json x) => x['id'] == id).firstOrNull;
    final double now = DateTime.now().millisecondsSinceEpoch / 1000;
    final Json item = <String, Object?>{
      'id': id ?? _id(),
      'kind': kind,
      'start': start,
      'end': end,
      'quote': start == end ? '' : book.textBetween(start, end),
      'text': text,
      'deleted': false,
      'knowledge_cutoff': math.max(end, cutoff),
      'revision': ((old?['revision'] as num?)?.toInt() ?? 0) + 1,
      'operation': _id(),
      'created': old?['created'] ?? now,
      'updated': now,
    };
    items = <Json>[...items.where((Json x) => x['id'] != item['id']), item];
    _write();
    return item;
  }

  void delete(Json item) {
    final Json gone = <String, Object?>{
      ...item,
      'deleted': true,
      'revision': ((item['revision'] as num?)?.toInt() ?? 0) + 1,
      'operation': _id(),
      'updated': DateTime.now().millisecondsSinceEpoch / 1000,
    };
    items = <Json>[...items.where((Json x) => x['id'] != item['id']), gone];
    _write();
  }

  void restore(Json item) {
    items = <Json>[...items.where((Json x) => x['id'] != item['id']), item];
    _write();
  }

  void _write() {
    writeJson(file, items);
    notifyListeners();
  }
}
