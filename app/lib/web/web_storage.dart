// JavaScript-only browser storage adapter for lib/main_web.dart.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:convert';
import 'dart:html' as html;
// Flutter's VM analyzer does not register this web-only SDK library, while
// dart2js (the target of this entrypoint) provides it.
// ignore: uri_does_not_exist
import 'dart:indexed_db' as idb;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:thusfar_core/parse.dart' as parser;

typedef Json = Map<String, Object?>;

/// A small shelf record, stored separately so opening the shelf never reads
/// the full text of every book.
class WebBookMeta {
  const WebBookMeta({
    required this.id,
    required this.title,
    required this.author,
    required this.length,
    required this.chapters,
    required this.added,
  });

  final String id;
  final String title;
  final String author;
  final int length;
  final int chapters;
  final int added;

  factory WebBookMeta.fromJson(Json value) => WebBookMeta(
    id: '${value['id']}',
    title: '${value['title']}',
    author: '${value['author'] ?? ''}',
    length: (value['length'] as num?)?.toInt() ?? 0,
    chapters: (value['chapters'] as num?)?.toInt() ?? 0,
    added: (value['added'] as num?)?.toInt() ?? 0,
  );

  Json toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'author': author,
    'length': length,
    'chapters': chapters,
    'added': added,
  };
}

class WebBook {
  WebBook({required this.meta, required this.data, required this.images})
    : blocks = <Json>[
        for (final Object? row in data['blocks'] as List<Object?>? ?? const [])
          if (row is Json) row,
      ],
      chapters = <Json>[
        for (final Object? row
            in data['chapters'] as List<Object?>? ?? const [])
          if (row is Json) row,
      ];

  final WebBookMeta meta;
  final Json data;
  final Map<String, String> images;
  final List<Json> blocks;
  final List<Json> chapters;
}

class WebReadingState {
  WebReadingState({
    this.chapter = 0,
    this.fraction = 0,
    this.lastOpened = 0,
    List<({int chapter, double fraction})>? bookmarks,
    List<({int chapter, double fraction, String text, int created})>? notes,
  }) : bookmarks = bookmarks ?? <({int chapter, double fraction})>[],
       notes =
           notes ??
           <({int chapter, double fraction, String text, int created})>[];

  int chapter;
  double fraction;
  int lastOpened;
  final List<({int chapter, double fraction})> bookmarks;
  final List<({int chapter, double fraction, String text, int created})> notes;

  factory WebReadingState.fromJson(Json value) => WebReadingState(
    chapter: (value['chapter'] as num?)?.toInt() ?? 0,
    fraction: ((value['fraction'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0),
    lastOpened: (value['lastOpened'] as num?)?.toInt() ?? 0,
    bookmarks: <({int chapter, double fraction})>[
      for (final Object? row
          in value['bookmarks'] as List<Object?>? ?? const [])
        if (row is Json)
          (
            chapter: (row['chapter'] as num?)?.toInt() ?? 0,
            fraction: ((row['fraction'] as num?)?.toDouble() ?? 0).clamp(
              0.0,
              1.0,
            ),
          ),
    ],
    notes: <({int chapter, double fraction, String text, int created})>[
      for (final Object? row in value['notes'] as List<Object?>? ?? const [])
        if (row is Json)
          (
            chapter: (row['chapter'] as num?)?.toInt() ?? 0,
            fraction: ((row['fraction'] as num?)?.toDouble() ?? 0).clamp(
              0.0,
              1.0,
            ),
            text: '${row['text'] ?? ''}',
            created: (row['created'] as num?)?.toInt() ?? 0,
          ),
    ],
  );

  Json toJson() => <String, Object?>{
    'chapter': chapter,
    'fraction': fraction,
    'lastOpened': lastOpened,
    'bookmarks': <Json>[
      for (final mark in bookmarks)
        <String, Object?>{'chapter': mark.chapter, 'fraction': mark.fraction},
    ],
    'notes': <Json>[
      for (final note in notes)
        <String, Object?>{
          'chapter': note.chapter,
          'fraction': note.fraction,
          'text': note.text,
          'created': note.created,
        },
    ],
  };
}

/// All book text and images remain in this browser's IndexedDB. No upload or
/// network request is made while importing, reading, or exporting a book.
class WebLibrary {
  WebLibrary._(this._database);

  static const String _databaseName = 'thusfar_web_v1';
  static const String _books = 'books';
  static const String _meta = 'meta';
  static const String _states = 'states';

  final idb.Database _database;

  static Future<WebLibrary> open() async {
    final idb.IdbFactory? factory = html.window.indexedDB;
    if (factory == null) throw StateError('浏览器不支持本地书库（IndexedDB）。');
    final idb.Database database = await factory.open(
      _databaseName,
      version: 1,
      onUpgradeNeeded: (idb.VersionChangeEvent event) {
        final idb.Database db = (event.target as idb.OpenDBRequest).result!;
        db.createObjectStore(_books);
        db.createObjectStore(_meta);
        db.createObjectStore(_states);
      },
    );
    return WebLibrary._(database);
  }

  Future<List<WebBookMeta>> list() async {
    final idb.Transaction transaction = _database.transaction(
      _meta,
      'readonly',
    );
    final List<WebBookMeta> result = <WebBookMeta>[];
    await for (final idb.CursorWithValue row
        in transaction.objectStore(_meta).openCursor(autoAdvance: true)) {
      final Object? value = row.value;
      if (value is String) {
        result.add(WebBookMeta.fromJson(jsonDecode(value) as Json));
      }
    }
    result.sort((WebBookMeta a, WebBookMeta b) => b.added.compareTo(a.added));
    return result;
  }

  Future<WebBook?> load(String id) async {
    final idb.Transaction transaction = _database.transactionList(<String>[
      _books,
      _meta,
    ], 'readonly');
    final Object? rawBook = await transaction.objectStore(_books).getObject(id);
    final Object? rawMeta = await transaction.objectStore(_meta).getObject(id);
    if (rawBook is! String || rawMeta is! String) return null;
    final Json stored = jsonDecode(rawBook) as Json;
    final Json book = stored['book'] as Json;
    final Json images = stored['images'] as Json? ?? <String, Object?>{};
    return WebBook(
      meta: WebBookMeta.fromJson(jsonDecode(rawMeta) as Json),
      data: book,
      images: <String, String>{
        for (final MapEntry<String, Object?> image in images.entries)
          if (image.value is String) image.key: image.value! as String,
      },
    );
  }

  Future<WebReadingState> state(String id) async {
    final idb.Transaction transaction = _database.transaction(
      _states,
      'readonly',
    );
    final Object? value = await transaction.objectStore(_states).getObject(id);
    return value is String
        ? WebReadingState.fromJson(jsonDecode(value) as Json)
        : WebReadingState();
  }

  Future<void> saveState(String id, WebReadingState state) async {
    final idb.Transaction transaction = _database.transaction(
      _states,
      'readwrite',
    );
    final Future<idb.Database> completed = transaction.completed;
    await transaction.objectStore(_states).put(jsonEncode(state.toJson()), id);
    await completed;
  }

  /// Parse the original file with the same pure Dart parser used by the native
  /// client. The digest makes re-importing the same file idempotent.
  Future<WebBookMeta> importFile(String name, Uint8List bytes) async {
    if (bytes.length > 16 * 1024 * 1024) {
      throw const FormatException('网页版单本书最多导入 16 MB；更大的书请使用安装版。');
    }
    final String suffix = name.toLowerCase();
    if (!suffix.endsWith('.txt') && !suffix.endsWith('.epub')) {
      throw const FormatException('请选择 TXT 或 EPUB 文件。');
    }
    final String id = sha256.convert(bytes).toString().substring(0, 24);
    final WebBook? existing = await load(id);
    if (existing != null) return existing.meta;
    final String stem = name.replaceFirst(
      RegExp(r'\.(txt|epub)$', caseSensitive: false),
      '',
    );
    final Map<String, String> images = <String, String>{};
    int imageBytes = 0;
    final Json book = suffix.endsWith('.epub')
        ? parser.parseEpubFile(bytes, stem, (String path, Uint8List data) {
            // Keep the browser record bounded; skipped artwork gets a visible
            // placeholder while the readable text remains intact.
            if (imageBytes + data.length > 48 * 1024 * 1024) return;
            imageBytes += data.length;
            images[path] = base64Encode(data);
          })
        : parser.parseTxt(bytes, stem);
    final List<Object?> chapters =
        book['chapters'] as List<Object?>? ?? const [];
    final WebBookMeta meta = WebBookMeta(
      id: id,
      title: '${book['title'] ?? stem}'.trim().isEmpty
          ? stem
          : '${book['title']}',
      author: '${book['author'] ?? ''}',
      length:
          (book['len'] as num?)?.toInt() ??
          (chapters.isEmpty
              ? 0
              : ((chapters.last as Json)['o1'] as num).toInt()),
      chapters: chapters.length,
      added: DateTime.now().millisecondsSinceEpoch,
    );
    final idb.Transaction transaction = _database.transactionList(<String>[
      _books,
      _meta,
    ], 'readwrite');
    final Future<idb.Database> completed = transaction.completed;
    await transaction
        .objectStore(_books)
        .put(jsonEncode(<String, Object?>{'book': book, 'images': images}), id);
    await transaction.objectStore(_meta).put(jsonEncode(meta.toJson()), id);
    await completed;
    return meta;
  }

  Future<void> importBackup(Uint8List bytes) async {
    if (bytes.length > 80 * 1024 * 1024) {
      throw const FormatException('网页版单个备份最多导入 80 MB。');
    }
    final Json wrapper = jsonDecode(utf8.decode(bytes)) as Json;
    if (wrapper['format'] != 'thusfar-web-backup-v1') {
      throw const FormatException('这不是页读网页版备份文件。');
    }
    final Json rawMeta = wrapper['meta'] as Json;
    final Json book = wrapper['book'] as Json;
    final Json rawImages = wrapper['images'] as Json? ?? <String, Object?>{};
    final Json rawState = wrapper['state'] as Json? ?? <String, Object?>{};
    final String id = '${rawMeta['id']}';
    final List<Object?>? blocks = book['blocks'] as List<Object?>?;
    final List<Object?>? chapters = book['chapters'] as List<Object?>?;
    if (!RegExp(r'^[0-9a-f]{24}$').hasMatch(id) ||
        rawMeta['title'] is! String ||
        (rawMeta['title'] as String).trim().isEmpty ||
        blocks == null ||
        blocks.isEmpty ||
        chapters == null ||
        chapters.isEmpty) {
      throw const FormatException('备份缺少书籍内容。');
    }
    for (final Object? raw in blocks) {
      if (raw is! Json ||
          raw['k'] is! String ||
          raw['t'] is! String ||
          raw['o'] is! num ||
          (raw['o'] as num) < 0) {
        throw const FormatException('备份中的正文段落无效。');
      }
    }
    for (final Object? raw in chapters) {
      if (raw is! Json ||
          raw['title'] is! String ||
          raw['b0'] is! num ||
          raw['b1'] is! num ||
          raw['o0'] is! num ||
          raw['o1'] is! num) {
        throw const FormatException('备份中的章节无效。');
      }
      final int first = (raw['b0'] as num).toInt();
      final int last = (raw['b1'] as num).toInt();
      if (first < 0 ||
          last <= first ||
          last > blocks.length ||
          (raw['o0'] as num) < 0 ||
          (raw['o1'] as num) < (raw['o0'] as num)) {
        throw const FormatException('备份中的章节范围无效。');
      }
    }
    final int chapterCount = chapters.length;
    final Object? current = rawState['chapter'];
    if (current != null &&
        (current is! num || current < 0 || current >= chapterCount)) {
      throw const FormatException('备份中的阅读位置无效。');
    }
    for (final String key in <String>['bookmarks', 'notes']) {
      final Object? entries = rawState[key];
      if (entries != null && entries is! List) {
        throw const FormatException('备份中的书签或摘记无效。');
      }
      for (final Object? raw in entries as List<Object?>? ?? const []) {
        if (raw is! Json ||
            raw['chapter'] is! num ||
            (raw['chapter'] as num) < 0 ||
            (raw['chapter'] as num) >= chapterCount ||
            raw['fraction'] is! num ||
            (raw['fraction'] as num) < 0 ||
            (raw['fraction'] as num) > 1 ||
            (key == 'notes' && raw['text'] is! String)) {
          throw const FormatException('备份中的书签或摘记无效。');
        }
      }
    }
    final Json images = <String, Object?>{};
    int encodedImageBytes = 0;
    for (final MapEntry<String, Object?> image in rawImages.entries) {
      if (image.value is! String) continue;
      final String data = image.value! as String;
      encodedImageBytes += data.length;
      if (encodedImageBytes > 64 * 1024 * 1024) {
        throw const FormatException('备份图片超过浏览器支持的大小。');
      }
      try {
        base64.normalize(data);
        images[image.key] = data;
      } on FormatException {
        throw const FormatException('备份图片数据无效。');
      }
    }
    final WebBookMeta meta = WebBookMeta(
      id: id,
      title: (rawMeta['title'] as String).trim(),
      author: rawMeta['author'] is String ? rawMeta['author'] as String : '',
      length:
          (rawMeta['length'] as num?)?.toInt() ??
          ((chapters.last as Json)['o1'] as num).toInt(),
      chapters: chapterCount,
      added:
          (rawMeta['added'] as num?)?.toInt() ??
          DateTime.now().millisecondsSinceEpoch,
    );
    final Json state = WebReadingState.fromJson(rawState).toJson();
    if (await load(id) != null) {
      throw StateError('这本书已在书架中。为保护当前进度，请先导出当前备份，再手动移除后恢复旧备份。');
    }
    final idb.Transaction transaction = _database.transactionList(<String>[
      _books,
      _meta,
      _states,
    ], 'readwrite');
    final Future<idb.Database> completed = transaction.completed;
    await transaction
        .objectStore(_books)
        .put(jsonEncode(<String, Object?>{'book': book, 'images': images}), id);
    await transaction.objectStore(_meta).put(jsonEncode(meta.toJson()), id);
    await transaction.objectStore(_states).put(jsonEncode(state), id);
    await completed;
  }

  Future<void> exportBackup(String id) async {
    final WebBook? book = await load(id);
    if (book == null) throw StateError('书籍已不存在。');
    final WebReadingState reading = await state(id);
    final String data = jsonEncode(<String, Object?>{
      'format': 'thusfar-web-backup-v1',
      'meta': book.meta.toJson(),
      'book': book.data,
      'images': book.images,
      'state': reading.toJson(),
    });
    final html.Blob blob = html.Blob(<Object>[data], 'application/json');
    final String url = html.Url.createObjectUrlFromBlob(blob);
    final html.AnchorElement anchor = html.AnchorElement(href: url)
      ..download = '${_safeFilename(book.meta.title)}-页读备份.json';
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    Future<void>.delayed(
      const Duration(seconds: 2),
      () => html.Url.revokeObjectUrl(url),
    );
  }

  Future<void> remove(String id) async {
    final idb.Transaction transaction = _database.transactionList(<String>[
      _books,
      _meta,
      _states,
    ], 'readwrite');
    final Future<idb.Database> completed = transaction.completed;
    await transaction.objectStore(_books).delete(id);
    await transaction.objectStore(_meta).delete(id);
    await transaction.objectStore(_states).delete(id);
    await completed;
  }

  void close() => _database.close();
}

String _safeFilename(String title) => title
    .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
    .substring(0, math.min(title.length, 64));
