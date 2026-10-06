// JavaScript-only browser storage adapter for lib/main_web.dart.
// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
// Flutter's VM analyzer does not register this web-only SDK library, while
// dart2js (the target of this entrypoint) provides it.
// ignore: uri_does_not_exist
import 'dart:indexed_db' as idb;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:thusfar_core/chapter_verdicts.dart' as verdicts;
import 'package:thusfar_core/parse.dart' as parser;

import '../data/library_zip.dart';
import '../data/portable_work.dart';
import '../data/restore_report.dart';
import '../data/preparation_scope.dart';
import '../data/reader_customizations.dart';

typedef Json = Map<String, Object?>;

/// Fixed messages from our merge checks. Safe to show without copying input
/// text, URLs, or provider responses into the WebDAV error panel.
class WebBackupConflict implements Exception {
  const WebBackupConflict(this.message);
  final String message;
  @override
  String toString() => message;
}

const int _maxPreparationBytes = 32 * 1024 * 1024;
const int _preparationLeaseMs = 5 * 60 * 1000;
const String _modelProfileStorageKey = 'thusfar-web-model-profile-v1';
const String _librarySettingsStorageKey =
    'thusfar-web-library-settings-transfer-v1';
const String _libraryCustomizationsStorageKey =
    'thusfar-web-reader-customizations-transfer-v1';
const String _readingQueueStorageKey = 'thusfar-web-reading-queue-v1';

class WebLibraryZipRestoreResult {
  const WebLibraryZipRestoreResult({
    required this.total,
    required this.imported,
    required this.existing,
    required this.failures,
    this.settingsError,
    required this.report,
    this.reportError,
  });

  final int total;
  final int imported;
  final int existing;
  final List<String> failures;
  final String? settingsError;
  final RestoreReport report;
  final String? reportError;
  bool get complete => failures.isEmpty && settingsError == null;
}

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
  WebBook({
    required this.meta,
    required this.data,
    required this.images,
    this.nativeBackup,
  }) : blocks = <Json>[
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

  /// Native-only graph and personal fields, excluding duplicated book/assets.
  final Json? nativeBackup;
  final List<Json> blocks;
  final List<Json> chapters;
}

String _legacyPersonalId(String kind, Json row) {
  final int chapter = (row['chapter'] as num).toInt();
  final double fraction = (row['fraction'] as num).toDouble();
  final String text = kind == 'note' ? row['text'] as String : '';
  final int created = kind == 'note'
      ? (row['created'] as num?)?.toInt() ?? 0
      : 0;
  return 'web${sha256.convert(utf8.encode(jsonEncode(<Object?>[kind, chapter, fraction.toString(), text, created]))).toString().substring(0, 24)}';
}

String _newPersonalId() {
  final math.Random random = math.Random.secure();
  return 'web${List<int>.generate(16, (_) => random.nextInt(256)).map((int n) => n.toRadixString(16).padLeft(2, '0')).join()}';
}

/// One personal record keeps its ID and revision even after deletion. Deleted
/// rows stay in the same v1 state arrays so old snapshots cannot revive them.
class WebPersonalItem {
  WebPersonalItem({
    required this.id,
    required this.kind,
    required this.chapter,
    required this.fraction,
    this.text = '',
    this.created = 0,
    this.revision = 1,
    this.updated = 0,
    this.deleted = false,
  });

  final String id;
  final String kind;
  final int chapter;
  final double fraction;
  final String text;
  final int created;
  final int revision;
  final int updated;
  final bool deleted;

  factory WebPersonalItem.fromJson(String kind, Json row) => WebPersonalItem(
    id: row['id'] is String
        ? row['id'] as String
        : _legacyPersonalId(kind, row),
    kind: kind,
    chapter: (row['chapter'] as num).toInt(),
    fraction: (row['fraction'] as num).toDouble(),
    text: kind == 'note' ? row['text'] as String : '',
    created: kind == 'note' ? (row['created'] as num?)?.toInt() ?? 0 : 0,
    revision: (row['revision'] as num?)?.toInt() ?? 1,
    updated:
        (row['updated'] as num?)?.toInt() ??
        ((row['created'] as num?)?.toInt() ?? 0),
    deleted: row['deleted'] == true,
  );

  Json toJson() => <String, Object?>{
    'id': id,
    'chapter': chapter,
    'fraction': fraction,
    if (kind == 'note') 'text': text,
    if (kind == 'note') 'created': created,
    'revision': revision,
    'updated': updated,
    'deleted': deleted,
  };

  WebPersonalItem remove() => WebPersonalItem(
    id: id,
    kind: kind,
    chapter: chapter,
    fraction: fraction,
    text: text,
    created: created,
    revision: revision + 1,
    updated: DateTime.now().millisecondsSinceEpoch,
    deleted: true,
  );
}

class WebReadingState {
  WebReadingState({
    this.chapter = 0,
    this.fraction = 0,
    this.lastOpened = 0,
    this.returnChapter,
    this.returnFraction,
    this.returnOffset,
    List<WebPersonalItem>? items,
  }) : items = items ?? <WebPersonalItem>[];

  int chapter;
  double fraction;
  int lastOpened;
  int? returnChapter;
  double? returnFraction;
  int? returnOffset;
  final List<WebPersonalItem> items;
  List<WebPersonalItem> get bookmarks => items
      .where((WebPersonalItem item) => item.kind == 'bookmark' && !item.deleted)
      .toList();
  List<WebPersonalItem> get notes => items
      .where((WebPersonalItem item) => item.kind == 'note' && !item.deleted)
      .toList();

  void addBookmark(int chapter, double fraction) {
    items.add(
      WebPersonalItem(
        id: _newPersonalId(),
        kind: 'bookmark',
        chapter: chapter,
        fraction: fraction,
        updated: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  void addNote(int chapter, double fraction, String text) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    items.add(
      WebPersonalItem(
        id: _newPersonalId(),
        kind: 'note',
        chapter: chapter,
        fraction: fraction,
        text: text,
        created: now,
        updated: now,
      ),
    );
  }

  void remove(WebPersonalItem item) {
    final int index = items.indexWhere(
      (WebPersonalItem row) => row.id == item.id,
    );
    if (index >= 0 && !items[index].deleted) {
      items[index] = items[index].remove();
    }
  }

  factory WebReadingState.fromJson(Json value) => WebReadingState(
    chapter: (value['chapter'] as num?)?.toInt() ?? 0,
    fraction: ((value['fraction'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0),
    lastOpened: (value['lastOpened'] as num?)?.toInt() ?? 0,
    returnChapter: (value['returnChapter'] as num?)?.toInt(),
    returnOffset: (value['returnOffset'] as num?)?.toInt(),
    returnFraction: (value['returnFraction'] as num?)?.toDouble().clamp(
      0.0,
      1.0,
    ),
    items: <WebPersonalItem>[
      for (final String key in <String>['bookmarks', 'notes'])
        for (final Object? row in value[key] as List<Object?>? ?? const [])
          if (row is Json)
            WebPersonalItem.fromJson(key == 'notes' ? 'note' : 'bookmark', row),
    ],
  );

  Json toJson() => <String, Object?>{
    'chapter': chapter,
    'fraction': fraction,
    'lastOpened': lastOpened,
    if (returnChapter != null) 'returnChapter': returnChapter,
    if (returnFraction != null) 'returnFraction': returnFraction,
    if (returnOffset != null) 'returnOffset': returnOffset,
    'bookmarks': <Json>[
      for (final WebPersonalItem item in items)
        if (item.kind == 'bookmark') item.toJson(),
    ],
    'notes': <Json>[
      for (final WebPersonalItem item in items)
        if (item.kind == 'note') item.toJson(),
    ],
  };
}

bool _sameJson(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every(
          (Object? key) => b.containsKey(key) && _sameJson(a[key], b[key]),
        );
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        Iterable<int>.generate(
          a.length,
        ).every((int i) => _sameJson(a[i], b[i]));
  }
  return a == b;
}

bool _sameBookData(Json a, Json b) {
  final Json left = <String, Object?>{...a}..remove('chapters');
  final Json right = <String, Object?>{...b}..remove('chapters');
  return _sameJson(left, right) &&
      verdicts.sameChapterContent(a['chapters'], b['chapters']);
}

final RegExp _webAssetName = RegExp(r'^[A-Za-z0-9_-][A-Za-z0-9_.-]{0,127}$');

void _validateImportedBook(Json book) {
  final Object? title = book['title'];
  final Object? lengthRaw = book['len'];
  final Object? blocksRaw = book['blocks'];
  final Object? chaptersRaw = book['chapters'];
  if (title is! String ||
      title.trim().isEmpty ||
      lengthRaw is! int ||
      lengthRaw < 0 ||
      blocksRaw is! List<Object?> ||
      blocksRaw.isEmpty ||
      blocksRaw.length > 1000000 ||
      chaptersRaw is! List<Object?> ||
      chaptersRaw.isEmpty ||
      chaptersRaw.length > 100000) {
    throw const FormatException('备份中的书籍结构无效。');
  }
  final int length = lengthRaw;
  int previousBlockOffset = -1;
  for (final Object? raw in blocksRaw) {
    if (raw is! Json ||
        !const <String>{'p', 'h', 'img'}.contains(raw['k']) ||
        raw['t'] is! String ||
        raw['o'] is! int) {
      throw const FormatException('备份中的正文段落无效。');
    }
    final int offset = raw['o'] as int;
    if (offset < previousBlockOffset ||
        offset < 0 ||
        offset + (raw['t'] as String).length > length) {
      throw const FormatException('备份中的正文位置无效。');
    }
    previousBlockOffset = offset;
    if (raw['k'] == 'img' &&
        (raw['src'] is! String ||
            !_webAssetName.hasMatch(raw['src'] as String))) {
      throw const FormatException('备份中的图片名称无效。');
    }
    final Object? footnotes = raw['fn'];
    if (footnotes != null && footnotes is! List<Object?>) {
      throw const FormatException('备份中的脚注索引无效。');
    }
    for (final Object? footnote in footnotes as List<Object?>? ?? const []) {
      if (footnote is! List<Object?> ||
          footnote.length != 2 ||
          footnote[0] is! int ||
          (footnote[0] as int) < 0 ||
          (footnote[0] as int) > (raw['t'] as String).length ||
          footnote[1] is! String) {
        throw const FormatException('备份中的脚注索引无效。');
      }
    }
  }
  int previousChapterOffset = -1;
  for (final Object? raw in chaptersRaw) {
    if (raw is! Json ||
        raw['title'] is! String ||
        raw['b0'] is! int ||
        raw['b1'] is! int ||
        raw['o0'] is! int ||
        raw['o1'] is! int) {
      throw const FormatException('备份中的章节无效。');
    }
    final int first = raw['b0'] as int;
    final int last = raw['b1'] as int;
    final int start = raw['o0'] as int;
    final int end = raw['o1'] as int;
    if (first < 0 ||
        last <= first ||
        last > blocksRaw.length ||
        start < previousChapterOffset ||
        start < 0 ||
        end < start ||
        end > length) {
      throw const FormatException('备份中的章节范围无效。');
    }
    previousChapterOffset = start;
  }
  final Object? notes = book['notes'];
  if (notes != null &&
      (notes is! Json ||
          !notes.values.every((Object? value) => value is String))) {
    throw const FormatException('备份中的脚注内容无效。');
  }
  final Object? cover = book['cover'];
  if (cover != null &&
      cover != '' &&
      (cover is! String || !_webAssetName.hasMatch(cover))) {
    throw const FormatException('备份中的封面名称无效。');
  }
}

void _validateNativeExtras(Json value, Json book) {
  final int bookLength = book['len'] as int;
  const Set<String> allowed = <String>{
    'format',
    'exported',
    'id',
    'kg',
    'meta',
    'status',
    'mentions',
    'progress',
    'notebook',
    'manual_entities',
    'work_files',
    'reader_customizations',
  };
  if (value.keys.any((String key) => !allowed.contains(key))) {
    throw const FormatException('安装版备份含未知附加字段，未导入。');
  }
  // Work checkpoints have their own path and schema validator. Keep its
  // normalized copy (for example a paused worker receipt) in the transferable
  // backup; scanning the raw work a second time would reject valid narrative
  // fields even after they passed the work-specific rules.
  if (value.containsKey('work_files')) {
    value['work_files'] = validatedPortableWork(value['work_files']);
  }
  rejectPortableCredentials(<String, Object?>{
    for (final MapEntry<String, Object?> entry in value.entries)
      if (entry.key != 'work_files') entry.key: entry.value,
  });
  if (value['format'] != 'yedu-book/2' ||
      value['id'] is! String ||
      value['kg'] is! Json) {
    throw const FormatException('备份中的安装版附加资料无效。');
  }
  if (value.containsKey('reader_customizations')) {
    final Json? customizations = validatedReaderCustomizations(
      value['reader_customizations'],
      book: book,
      bookId: value['id'] as String,
      meta: value['meta'] is Json ? value['meta'] as Json : <String, Object?>{},
    );
    if (customizations == null) {
      value.remove('reader_customizations');
    } else {
      value['reader_customizations'] = customizations;
    }
  }
  final Json graph = value['kg'] as Json;
  final Object? rawLog = graph['log'];
  if (rawLog is! List<Object?> || rawLog.length > 1000000) {
    throw const FormatException('备份中的人物图谱无效。');
  }
  const Map<String, List<String>> required = <String, List<String>>{
    'person': <String>['id', 'name'],
    'name': <String>['id', 'name'],
    'alias': <String>['id', 'alias'],
    'merge': <String>['from', 'into'],
    'profile': <String>['id'],
    'attr': <String>['id', 'key', 'value'],
    'rel': <String>['a', 'b'],
    'event': <String>['text'],
    'imp': <String>['id'],
    'cnt': <String>[],
    'recap': <String>['text'],
    'saga': <String>['text'],
  };
  int previous = -1;
  for (final Object? raw in rawLog) {
    if (raw is! Json || raw['t'] is! String || raw['p'] is! int) {
      throw const FormatException('备份中的人物记录无效。');
    }
    final int position = raw['p'] as int;
    final List<String>? fields = required[raw['t'] as String];
    if (fields == null ||
        position < previous ||
        position < 0 ||
        position > bookLength ||
        fields.any((String key) => raw[key] is! String)) {
      throw const FormatException('备份中的人物记录无效。');
    }
    previous = position;
  }
  final Object? mentions = value['mentions'];
  if (mentions != null &&
      (mentions is! Json ||
          !mentions.values.every((Object? item) => item is List<Object?>))) {
    throw const FormatException('备份中的人物索引无效。');
  }
  for (final String key in <String>['notebook', 'manual_entities']) {
    final Object? rows = value[key];
    if (rows != null &&
        (rows is! List<Object?> ||
            !rows.every((Object? row) => row is Json && row['id'] is String))) {
      throw const FormatException('备份中的安装版个人资料无效。');
    }
  }
}

({int chapter, double fraction}) _positionForOffset(Json book, int offset) {
  final List<Object?> chapters = book['chapters'] as List<Object?>? ?? const [];
  if (chapters.isEmpty) return (chapter: 0, fraction: 0);
  final int length = (book['len'] as num?)?.toInt() ?? 0;
  final int safe = offset.clamp(0, length);
  int chapter = 0;
  for (int i = 0; i < chapters.length; i++) {
    final Json row = chapters[i] as Json;
    if ((row['o0'] as num).toInt() <= safe) chapter = i;
  }
  final Json selected = chapters[chapter] as Json;
  final int start = (selected['o0'] as num).toInt();
  final int end = (selected['o1'] as num).toInt();
  return (
    chapter: chapter,
    fraction: end <= start
        ? 0
        : ((safe - start) / (end - start)).clamp(0.0, 1.0),
  );
}

Json _webWrapperFromNative(Json native) {
  if (native['format'] != 'yedu-book/2' || native['book'] is! Json) {
    throw const FormatException('这不是可导入的页读安装版备份。');
  }
  final Json book = native['book'] as Json;
  final Json rawAssets = native['assets'] is Json
      ? native['assets'] as Json
      : <String, Object?>{};
  final Set<String> requiredAssets = <String>{
    if (book['cover'] is String && (book['cover'] as String).isNotEmpty)
      book['cover'] as String,
    for (final Object? raw in book['blocks'] as List<Object?>? ?? const [])
      if (raw is Json && raw['k'] == 'img' && raw['src'] is String)
        raw['src'] as String,
  };
  if (rawAssets.keys.toSet().length != requiredAssets.length ||
      !rawAssets.keys.toSet().containsAll(requiredAssets)) {
    throw const FormatException('安装版备份图片不完整，未导入。');
  }
  final Json images = <String, Object?>{};
  int totalImageBytes = 0;
  for (final MapEntry<String, Object?> entry in rawAssets.entries) {
    final Object? value = entry.value;
    if (value is! Json ||
        value['base64'] is! String ||
        value['size'] is! num ||
        value['sha256'] is! String) {
      throw const FormatException('安装版备份图片格式无效。');
    }
    final String encoded = value['base64'] as String;
    final Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      throw const FormatException('安装版备份图片编码无效。');
    }
    totalImageBytes += encoded.length;
    if (totalImageBytes > 64 * 1024 * 1024 ||
        bytes.length != (value['size'] as num).toInt() ||
        sha256.convert(bytes).toString() != value['sha256']) {
      throw const FormatException('安装版备份图片超限或校验失败。');
    }
    images[entry.key] = encoded;
  }
  final Json nativeExtras = <String, Object?>{
    for (final MapEntry<String, Object?> entry in native.entries)
      if (const <String>{
        'format',
        'exported',
        'id',
        'kg',
        'meta',
        'status',
        'mentions',
        'progress',
        'notebook',
        'manual_entities',
        'work_files',
        'reader_customizations',
      }.contains(entry.key))
        entry.key: entry.value,
  };
  if (native.keys.any(
    (String key) => !const <String>{
      'book',
      'assets',
      'web_state',
      'web_preparation',
      'format',
      'exported',
      'id',
      'kg',
      'meta',
      'status',
      'mentions',
      'progress',
      'notebook',
      'manual_entities',
      'work_files',
      'reader_customizations',
    }.contains(key),
  )) {
    throw const FormatException('安装版备份含未知附加字段，未导入。');
  }
  _validateNativeExtras(nativeExtras, book);
  final Json state;
  if (native['web_state'] is Json) {
    state = native['web_state'] as Json;
  } else {
    final Json? progress = native['progress'] is Json
        ? native['progress'] as Json
        : null;
    final int offset = (progress?['pos'] as num?)?.toInt() ?? 0;
    final position = _positionForOffset(book, offset);
    final List<Json> bookmarks = <Json>[];
    final List<Json> notes = <Json>[];
    final Object? personal = native['notebook'];
    if (personal is List) {
      for (final Object? raw in personal) {
        if (raw is! Json || raw['start'] is! num) {
          continue;
        }
        final place = _positionForOffset(book, (raw['start'] as num).toInt());
        if (raw['kind'] == 'bookmark') {
          bookmarks.add(<String, Object?>{
            'chapter': place.chapter,
            'fraction': place.fraction,
            'id': raw['id'],
            'revision': raw['revision'] ?? 1,
            'updated': (((raw['updated'] as num?)?.toDouble() ?? 0) * 1000)
                .round(),
            'deleted': raw['deleted'] == true,
          });
        } else if (raw['kind'] == 'note') {
          final String text = '${raw['text'] ?? ''}';
          final String quote = '${raw['quote'] ?? ''}';
          notes.add(<String, Object?>{
            'chapter': place.chapter,
            'fraction': place.fraction,
            'text': text.isNotEmpty ? text : quote,
            'created': (((raw['created'] as num?)?.toDouble() ?? 0) * 1000)
                .round(),
            'id': raw['id'],
            'revision': raw['revision'] ?? 1,
            'updated': (((raw['updated'] as num?)?.toDouble() ?? 0) * 1000)
                .round(),
            'deleted': raw['deleted'] == true,
          });
        }
      }
    }
    state = <String, Object?>{
      'chapter': position.chapter,
      'fraction': position.fraction,
      'lastOpened': (((progress?['t'] as num?)?.toDouble() ?? 0) * 1000)
          .round(),
      'bookmarks': bookmarks,
      'notes': notes,
    };
  }
  final Json meta = <String, Object?>{
    'id': sha256
        .convert(utf8.encode(jsonEncode(book)))
        .toString()
        .substring(0, 24),
    'title': '${book['title'] ?? ''}',
    'author': '${book['author'] ?? ''}',
    'length': (book['len'] as num?)?.toInt() ?? 0,
    'chapters': (book['chapters'] as List?)?.length ?? 0,
    'added': DateTime.now().millisecondsSinceEpoch,
  };
  return <String, Object?>{
    'format': 'thusfar-web-backup-v1',
    'meta': meta,
    'book': book,
    'images': images,
    'state': state,
    if (native['web_preparation'] is Json)
      'preparation': native['web_preparation'],
    'native_backup': nativeExtras,
  };
}

WebReadingState _mergeReadingStates(
  WebReadingState local,
  WebReadingState incoming,
) {
  final bool incomingLater =
      incoming.lastOpened > local.lastOpened ||
      (incoming.lastOpened == local.lastOpened &&
          (incoming.chapter > local.chapter ||
              (incoming.chapter == local.chapter &&
                  incoming.fraction > local.fraction)));
  final WebReadingState latest = incomingLater ? incoming : local;
  final Map<String, WebPersonalItem> byId = <String, WebPersonalItem>{};
  for (final WebPersonalItem item in <WebPersonalItem>[
    ...local.items,
    ...incoming.items,
  ]) {
    final WebPersonalItem? old = byId[item.id];
    if (old == null || item.revision > old.revision) {
      byId[item.id] = item;
    } else if (item.revision == old.revision &&
        !_sameJson(item.toJson(), old.toJson())) {
      throw const WebBackupConflict('同一条书签或摘记在两端有不同修改，未覆盖；请分别导出备份。');
    }
  }
  return WebReadingState(
    chapter: latest.chapter,
    fraction: latest.fraction,
    lastOpened: latest.lastOpened,
    items: byId.values.toList(),
  );
}

Json? _mergePreparations(Json? local, Json? incoming) {
  if (local == null) return incoming;
  if (incoming == null) return local;
  final Json localResults = local['results'] as Json;
  final Json incomingResults = incoming['results'] as Json;
  for (final String key in localResults.keys) {
    if (!incomingResults.containsKey(key)) continue;
    final Json localRow = localResults[key] as Json;
    final Json incomingRow = incomingResults[key] as Json;
    if (!_sameJson(localRow['result'], incomingRow['result'])) {
      throw const WebBackupConflict('同一段书籍有不同的整理结果，未覆盖；请分别保留两个快照后处理。');
    }
  }
  final List<Object?> localEvents = local['events'] as List<Object?>;
  final List<Object?> incomingEvents = incoming['events'] as List<Object?>;
  final List<Object?> combinedEvents = <Object?>[
    ...incomingEvents,
    ...localEvents,
  ];
  final Json merged = <String, Object?>{
    ...local,
    'results': <String, Object?>{...incomingResults, ...localResults},
    'events': combinedEvents.length > 120
        ? combinedEvents.sublist(combinedEvents.length - 120)
        : combinedEvents,
    'updated_at': DateTime.now().millisecondsSinceEpoch,
  };
  return _validatedPreparation(merged);
}

bool _orderedJsonSubset(List<Object?> older, List<Object?> newer) {
  if (older.length > newer.length) return false;
  int seen = 0;
  for (final Object? row in newer) {
    if (seen < older.length && _sameJson(older[seen], row)) seen++;
  }
  return seen == older.length;
}

bool _nativeGraphExtends(Json older, Json newer) {
  if (older.keys.length != newer.keys.length ||
      !older.keys.every(newer.containsKey)) {
    return false;
  }
  for (final String key in older.keys) {
    if (key == 'log' || key == 'segments') continue;
    if (!_sameJson(older[key], newer[key])) return false;
  }
  final Object? oldSegments = older['segments'];
  final Object? newSegments = newer['segments'];
  if ((oldSegments != null && oldSegments is! List<Object?>) ||
      (newSegments != null && newSegments is! List<Object?>)) {
    return false;
  }
  return _orderedJsonSubset(
        older['log'] as List<Object?>? ?? const <Object?>[],
        newer['log'] as List<Object?>? ?? const <Object?>[],
      ) &&
      _orderedJsonSubset(
        oldSegments as List<Object?>? ?? const <Object?>[],
        newSegments as List<Object?>? ?? const <Object?>[],
      );
}

Json? _normalizedNativeMentions(Json source) {
  final Json result = <String, Object?>{};
  for (final MapEntry<String, Object?> entry in source.entries) {
    if (!RegExp(r'^\d{1,6}$').hasMatch(entry.key) ||
        entry.value is! List<Object?>) {
      return null;
    }
    final String key = int.parse(entry.key).toString();
    if (result.containsKey(key)) return null;
    result[key] = entry.value;
  }
  return result;
}

bool _nativeMentionsExtend(Json older, Json newer) {
  final Json? oldRows = _normalizedNativeMentions(older);
  final Json? newRows = _normalizedNativeMentions(newer);
  if (oldRows == null || newRows == null) return false;
  for (final MapEntry<String, Object?> entry in oldRows.entries) {
    final Object? target = newRows[entry.key];
    if (target is! List<Object?> ||
        !_orderedJsonSubset(entry.value! as List<Object?>, target)) {
      return false;
    }
  }
  return true;
}

List<Object?> _mergeNativeManual(Object? local, Object? incoming) {
  if (local is! List<Object?> || incoming is! List<Object?>) {
    throw const WebBackupConflict('安装版手动人物资料格式不同，未覆盖；请另存快照。');
  }
  final List<Object?> merged = <Object?>[...local];
  final Map<String, Json> byId = <String, Json>{};
  for (final Object? row in local) {
    if (row is! Json || row['id'] is! String) {
      throw const WebBackupConflict('安装版手动人物资料无效，未覆盖；请另存快照。');
    }
    byId[row['id'] as String] = row;
  }
  for (final Object? row in incoming) {
    if (row is! Json || row['id'] is! String) {
      throw const WebBackupConflict('安装版手动人物资料无效，未覆盖；请另存快照。');
    }
    final String id = row['id'] as String;
    final Json? old = byId[id];
    if (old != null) {
      if (!_sameJson(old, row)) {
        throw const WebBackupConflict('同一条手动人物资料在两端不同，未覆盖；请另存快照。');
      }
      continue;
    }
    merged.add(row);
    byId[id] = row;
  }
  return merged;
}

Json? _mergeNativeBackups(Json? local, Json? incoming) {
  if (local == null) return incoming;
  if (incoming == null) return local;
  if (local['reader_customizations'] != null &&
      incoming['reader_customizations'] != null &&
      !_sameJson(
        local['reader_customizations'],
        incoming['reader_customizations'],
      )) {
    throw const WebBackupConflict('这本书的阅读自定义在两端不同，未覆盖；请分别导出备份后在安装版处理。');
  }
  final Json? localMeta = local['meta'] is Json ? local['meta'] as Json : null;
  final Json? incomingMeta = incoming['meta'] is Json
      ? incoming['meta'] as Json
      : null;
  final Json? incomingStatusForIntent = incoming['status'] is Json
      ? incoming['status'] as Json
      : null;
  if (localMeta?['retry_quality'] == true &&
      incomingMeta?['retry_quality'] != true &&
      incomingStatusForIntent?['state'] == 'done') {
    throw const WebBackupConflict('本地仍有待执行的质量重试请求，来源已完成整理；请先处理本地重试意图。');
  }
  final Json localWork = validatedPortableWork(local['work_files']);
  final Json incomingWork = validatedPortableWork(incoming['work_files']);
  for (final String field in <String>['id']) {
    if (!_sameJson(local[field], incoming[field])) {
      throw const WebBackupConflict('本地与远端安装版人物资料不同，未覆盖；请另存快照并手动处理。');
    }
  }
  final Json localGraph = local['kg'] as Json;
  final Json incomingGraph = incoming['kg'] as Json;
  final Json localMentions = local['mentions'] as Json? ?? <String, Object?>{};
  final Json incomingMentions =
      incoming['mentions'] as Json? ?? <String, Object?>{};
  final int localFrontier =
      ((local['status'] as Json?)?['frontier'] as num?)?.toInt() ?? 0;
  final int incomingFrontier =
      ((incoming['status'] as Json?)?['frontier'] as num?)?.toInt() ?? 0;
  final bool incomingExtends =
      _nativeGraphExtends(localGraph, incomingGraph) &&
      _nativeMentionsExtend(localMentions, incomingMentions) &&
      incomingFrontier >= localFrontier;
  final bool localExtends =
      _nativeGraphExtends(incomingGraph, localGraph) &&
      _nativeMentionsExtend(incomingMentions, localMentions) &&
      localFrontier >= incomingFrontier;
  if (!incomingExtends && !localExtends) {
    throw const WebBackupConflict('本地与远端安装版人物资料分叉，未覆盖；请另存快照。');
  }
  final Json mergedWork;
  try {
    mergedWork = mergePortableWork(
      localWork,
      incomingWork,
      incomingWins:
          incoming.containsKey('work_files') &&
          incomingExtends &&
          !localExtends,
      localWins:
          local.containsKey('work_files') && localExtends && !incomingExtends,
    );
  } on FormatException catch (error) {
    throw WebBackupConflict('${error.message} 请分别导出备份。');
  }
  final Json mergedGraph = incomingExtends ? incomingGraph : localGraph;
  final Json mergedMentions = incomingExtends
      ? incomingMentions
      : localMentions;
  final List<Object?> mergedManual = _mergeNativeManual(
    local['manual_entities'] ?? const <Object?>[],
    incoming['manual_entities'] ?? const <Object?>[],
  );
  final Map<String, Json> byId = <String, Json>{};
  for (final Object? raw in local['notebook'] as List<Object?>? ?? const []) {
    if (raw is Json && raw['id'] is String) {
      byId[raw['id'] as String] = raw;
    }
  }
  for (final Object? raw
      in incoming['notebook'] as List<Object?>? ?? const []) {
    if (raw is! Json || raw['id'] is! String) continue;
    final String id = raw['id'] as String;
    final Json? old = byId[id];
    if (old != null) {
      final int oldRevision = (old['revision'] as num?)?.toInt() ?? 1;
      final int revision = (raw['revision'] as num?)?.toInt() ?? 1;
      if (revision < oldRevision) continue;
      if (revision == oldRevision && !_sameJson(old, raw)) {
        throw const WebBackupConflict('同一条安装版摘记在本地与远端不同，未覆盖；请另存快照。');
      }
    }
    byId[id] = raw;
  }
  final Json merged = <String, Object?>{...local};
  for (final MapEntry<String, Object?> entry in incoming.entries) {
    if (!merged.containsKey(entry.key)) {
      merged[entry.key] = entry.value;
    } else if (!const <String>{
          'format',
          'id',
          'kg',
          'mentions',
          'manual_entities',
          'notebook',
          'meta',
          'status',
          'progress',
          'exported',
          'work_files',
        }.contains(entry.key) &&
        !_sameJson(merged[entry.key], entry.value)) {
      throw const WebBackupConflict('安装版扩展资料在本地与远端不同，未覆盖；请另存快照。');
    }
  }
  merged['notebook'] = byId.values.toList();
  merged['kg'] = mergedGraph;
  merged['mentions'] = mergedMentions;
  merged['manual_entities'] = mergedManual;
  if (local.containsKey('work_files') || incoming.containsKey('work_files')) {
    merged['work_files'] = mergedWork;
  }
  final Json? localProgress = local['progress'] is Json
      ? local['progress'] as Json
      : null;
  final Json? incomingProgress = incoming['progress'] is Json
      ? incoming['progress'] as Json
      : null;
  if (incomingProgress != null &&
      ((incomingProgress['t'] as num?)?.toDouble() ?? 0) >
          ((localProgress?['t'] as num?)?.toDouble() ?? 0)) {
    merged['progress'] = incomingProgress;
  }
  final Json? incomingStatus = incoming['status'] is Json
      ? incoming['status'] as Json
      : null;
  final Json? localStatus = local['status'] is Json
      ? local['status'] as Json
      : null;
  Set<Object?> pending(Json? status) {
    final Object? quality = status?['quality'];
    final Object? rows = quality is Json ? quality['pending'] : null;
    return rows is List<Object?> ? rows.toSet() : <Object?>{};
  }

  final Set<Object?> localPending = pending(localStatus);
  final Set<Object?> incomingPending = pending(incomingStatus);
  final bool qualityAdvanced =
      localPending.length > incomingPending.length &&
      localPending.containsAll(incomingPending);
  final bool doneAdvanced =
      incomingStatus?['state'] == 'done' && localStatus?['state'] != 'done';
  if (incomingStatus != null &&
      incomingExtends &&
      (!localExtends ||
          incomingFrontier > localFrontier ||
          qualityAdvanced ||
          doneAdvanced)) {
    merged['status'] = incomingStatus;
  }
  return merged;
}

/// All book text and images remain in this browser's IndexedDB. No upload or
/// network request is made while importing, reading, or exporting a book.
class WebLibrary {
  WebLibrary._(this._database);

  /// Non-sensitive default model profile shared by preparation and Ask.
  /// API keys remain in WebModelSession's current-tab memory only.
  static Json? savedModelProfile() {
    try {
      final String? raw = html.window.localStorage[_modelProfileStorageKey];
      if (raw == null) return null;
      return LibraryZipCodec.validatedModelProfile(jsonDecode(raw));
    } on Object {
      return null;
    }
  }

  static void saveModelProfile(Json profile) {
    final Json merged = <String, Object?>{
      ...profile,
      if (!profile.containsKey('jev_route') &&
          savedModelProfile()?['jev_route'] is String)
        'jev_route': savedModelProfile()!['jev_route'],
    };
    html.window.localStorage[_modelProfileStorageKey] = jsonEncode(
      LibraryZipCodec.validatedModelProfile(merged),
    );
  }

  static List<String> _readingQueueIds() {
    try {
      final String? raw = html.window.localStorage[_readingQueueStorageKey];
      final Object? decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is List<Object?> && decoded.length <= 2000) {
        return <String>[
          for (final Object? id in decoded)
            if (id is String && RegExp(r'^[0-9a-f]{24}$').hasMatch(id)) id,
        ];
      }
    } on Object {
      // Optional order metadata cannot hide books.
    }
    return <String>[];
  }

  /// Ask the browser to reduce automatic storage eviction. Browsers may
  /// decline; a portable backup remains necessary even when this succeeds.
  static Future<void> requestPersistence() async {
    try {
      await html.window.navigator.storage?.persist();
    } on Object {
      // Storage persistence is optional and must never block book access.
    }
  }

  static const String _databaseName = 'thusfar_web_v1';
  static const String _books = 'books';
  static const String _meta = 'meta';
  static const String _states = 'states';
  static const String _preparations = 'preparations';
  static const String _trash = 'trash';
  static const String _reportKey = 'thusfar-web-restore-report-v1';
  static String _preparationLeaseKey(String bookId) => 'lease:$bookId';

  final idb.Database _database;

  static Future<WebLibrary> open({String databaseName = _databaseName}) async {
    final idb.IdbFactory? factory = html.window.indexedDB;
    if (factory == null) throw StateError('浏览器不支持本地书库（IndexedDB）。');
    final Completer<idb.Database> ready = Completer<idb.Database>();
    factory
        .open(
          databaseName,
          version: 3,
          onBlocked: (_) {
            if (!ready.isCompleted) {
              ready.completeError(
                StateError('另一页读标签页仍打开，阻止书库升级。请关闭其他页读标签页后刷新。'),
              );
            }
          },
          onUpgradeNeeded: (idb.VersionChangeEvent event) {
            final idb.Database db = (event.target as idb.OpenDBRequest).result!;
            final List<String> stores = db.objectStoreNames ?? <String>[];
            if (!stores.contains(_trash)) db.createObjectStore(_trash);
            if (!stores.contains(_books)) {
              db.createObjectStore(_books);
            }
            if (!stores.contains(_meta)) {
              db.createObjectStore(_meta);
            }
            if (!stores.contains(_states)) {
              db.createObjectStore(_states);
            }
            if (!stores.contains(_preparations)) {
              db.createObjectStore(_preparations);
            }
          },
        )
        .then(
          (idb.Database database) {
            if (ready.isCompleted) {
              database.close();
            } else {
              ready.complete(database);
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!ready.isCompleted) ready.completeError(error, stack);
          },
        );
    final idb.Database database = await ready.future;
    database.onVersionChange.listen((_) => database.close());
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
      nativeBackup: stored['native_backup'] is Json
          ? stored['native_backup'] as Json
          : null,
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

  /// Returns the bounded, credential-free preparation checkpoint for a book.
  Future<Json?> loadPreparation(String bookId) async {
    final idb.Transaction transaction = _database.transactionList(<String>[
      _books,
      _preparations,
    ], 'readonly');
    if (await transaction.objectStore(_books).getKey(bookId) == null) {
      return null;
    }
    final Object? raw = await transaction
        .objectStore(_preparations)
        .getObject(bookId);
    if (raw == null) return null;
    if (raw is! String) {
      throw const FormatException('书籍准备记录无效。');
    }
    return _decodePreparation(raw);
  }

  Future<void> savePreparation(String bookId, Json state) async {
    final String encoded = _encodePreparation(state);
    final idb.Transaction transaction = _database.transactionList(<String>[
      _books,
      _preparations,
    ], 'readwrite');
    final Future<idb.Database> completed = transaction.completed;
    if (await transaction.objectStore(_books).getKey(bookId) == null) {
      await completed;
      throw StateError('书籍已不存在，无法保存准备进度。');
    }
    await transaction.objectStore(_preparations).put(encoded, bookId);
    await completed;
  }

  Future<void> clearPreparation(String bookId) async {
    final idb.Transaction transaction = _database.transaction(
      _preparations,
      'readwrite',
    );
    final Future<idb.Database> completed = transaction.completed;
    await transaction.objectStore(_preparations).delete(bookId);
    await completed;
  }

  /// IndexedDB readwrite transactions on one store serialize across tabs.
  /// This is the authoritative gate for billable model requests; a
  /// localStorage read/write pair alone cannot provide that guarantee.
  Future<bool> acquirePreparationLease(String bookId, String owner) async {
    final idb.Transaction transaction = _database.transaction(
      _preparations,
      'readwrite',
    );
    final Future<idb.Database> completed = transaction.completed;
    final idb.ObjectStore store = transaction.objectStore(_preparations);
    final String key = _preparationLeaseKey(bookId);
    final Object? raw = await store.getObject(key);
    final Json? lease = _decodeLease(raw);
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (lease != null &&
        lease['owner'] != owner &&
        (lease['expires'] as int) > now) {
      await completed;
      return false;
    }
    await store.put(
      jsonEncode(<String, Object?>{
        'owner': owner,
        'expires': now + _preparationLeaseMs,
      }),
      key,
    );
    await completed;
    return true;
  }

  /// The owner must renew before each paid call and after receiving its reply.
  Future<bool> renewPreparationLease(String bookId, String owner) async {
    final idb.Transaction transaction = _database.transaction(
      _preparations,
      'readwrite',
    );
    final Future<idb.Database> completed = transaction.completed;
    final idb.ObjectStore store = transaction.objectStore(_preparations);
    final String key = _preparationLeaseKey(bookId);
    final Json? lease = _decodeLease(await store.getObject(key));
    if (lease == null || lease['owner'] != owner) {
      await completed;
      return false;
    }
    await store.put(
      jsonEncode(<String, Object?>{
        'owner': owner,
        'expires': DateTime.now().millisecondsSinceEpoch + _preparationLeaseMs,
      }),
      key,
    );
    await completed;
    return true;
  }

  Future<bool> otherPreparationLeaseActive(String bookId, String owner) async {
    final idb.Transaction transaction = _database.transaction(
      _preparations,
      'readonly',
    );
    final Json? lease = _decodeLease(
      await transaction
          .objectStore(_preparations)
          .getObject(_preparationLeaseKey(bookId)),
    );
    return lease != null &&
        lease['owner'] != owner &&
        (lease['expires'] as int) > DateTime.now().millisecondsSinceEpoch;
  }

  Future<void> releasePreparationLease(String bookId, String owner) async {
    final idb.Transaction transaction = _database.transaction(
      _preparations,
      'readwrite',
    );
    final Future<idb.Database> completed = transaction.completed;
    final idb.ObjectStore store = transaction.objectStore(_preparations);
    final String key = _preparationLeaseKey(bookId);
    final Json? lease = _decodeLease(await store.getObject(key));
    if (lease != null && lease['owner'] == owner) {
      await store.delete(key);
    }
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

  Future<String> importBackup(
    Uint8List bytes, {
    bool previewOnly = false,
  }) async {
    if (bytes.length > 144 * 1024 * 1024) {
      throw const FormatException('网页版单个备份最多导入 144 MB。');
    }
    final Object? decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Json) {
      throw const FormatException('备份必须是 JSON 对象。');
    }
    final Json wrapper = decoded['format'] == 'yedu-book/2'
        ? _webWrapperFromNative(decoded)
        : decoded;
    if (wrapper['format'] != 'thusfar-web-backup-v1') {
      throw const FormatException('这不是可导入的页读单书备份文件。');
    }
    if (wrapper['meta'] is! Json || wrapper['book'] is! Json) {
      throw const FormatException('备份缺少书籍信息或正文。');
    }
    final Json rawMeta = wrapper['meta'] as Json;
    final Json book = wrapper['book'] as Json;
    final Json rawImages = wrapper['images'] as Json? ?? <String, Object?>{};
    final Json rawState = wrapper['state'] as Json? ?? <String, Object?>{};
    if (wrapper['native_backup'] != null && wrapper['native_backup'] is! Json) {
      throw const FormatException('备份中的安装版附加资料无效，未导入。');
    }
    final Json? nativeBackup = wrapper['native_backup'] is Json
        ? wrapper['native_backup'] as Json
        : null;
    _validateImportedBook(book);
    final Set<String> requiredImages = <String>{
      if (book['cover'] is String && (book['cover'] as String).isNotEmpty)
        book['cover'] as String,
      for (final Object? block in book['blocks'] as List<Object?>)
        if (block is Json && block['k'] == 'img') block['src'] as String,
    };
    if (!rawImages.keys.toSet().containsAll(requiredImages) ||
        requiredImages.any((String name) => rawImages[name] is! String)) {
      throw const FormatException('备份缺少正文引用的图片或封面，未导入。');
    }
    if (nativeBackup != null) {
      _validateNativeExtras(nativeBackup, book);
    }
    final Object? rawPreparation = wrapper['preparation'];
    final String? preparation;
    if (rawPreparation == null) {
      preparation = null;
    } else if (rawPreparation is Json) {
      preparation = _encodePreparation(rawPreparation);
    } else {
      throw const FormatException('备份中的书籍准备记录无效。');
    }
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
    final int chapterCount = chapters.length;
    final Object? current = rawState['chapter'];
    if (current != null &&
        (current is! num || current < 0 || current >= chapterCount)) {
      throw const FormatException('备份中的阅读位置无效。');
    }
    final Set<String> personalIds = <String>{};
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
            !(raw['fraction'] as num).toDouble().isFinite ||
            (raw['fraction'] as num) < 0 ||
            (raw['fraction'] as num) > 1 ||
            (key == 'notes' && raw['text'] is! String) ||
            (raw['id'] != null &&
                (raw['id'] is! String ||
                    !RegExp(
                      r'^[A-Za-z0-9_-]{8,80}$',
                    ).hasMatch(raw['id'] as String))) ||
            (raw['revision'] != null &&
                (raw['revision'] is! int ||
                    (raw['revision'] as int) < 1 ||
                    (raw['revision'] as int) > 1000000000)) ||
            (raw['updated'] != null &&
                (raw['updated'] is! int ||
                    (raw['updated'] as int) < 0 ||
                    (raw['updated'] as int) > 1000000000000000)) ||
            (raw['deleted'] != null && raw['deleted'] is! bool)) {
          throw const FormatException('备份中的书签或摘记无效。');
        }
        final String id = raw['id'] is String
            ? raw['id'] as String
            : _legacyPersonalId(key == 'notes' ? 'note' : 'bookmark', raw);
        if (!personalIds.add(id)) {
          throw const FormatException('备份中的书签或摘记编号重复。');
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
    final WebReadingState incomingState = WebReadingState.fromJson(rawState);
    String targetId = id;
    for (final WebBookMeta candidate in await list()) {
      final WebBook? existing = await load(candidate.id);
      if (existing == null) continue;
      if (candidate.id == id &&
          (!_sameBookData(existing.data, book) ||
              !_sameJson(existing.images, images))) {
        throw const WebBackupConflict('本地已有同编号但正文或图片不同的书，未覆盖；请先导出两个版本再处理。');
      }
      if (_sameBookData(existing.data, book) &&
          _sameJson(existing.images, images)) {
        targetId = candidate.id;
        if (candidate.id == id) break;
      }
    }
    final idb.Transaction transaction = _database.transactionList(<String>[
      _books,
      _meta,
      _states,
      _preparations,
    ], previewOnly ? 'readonly' : 'readwrite');
    final Future<idb.Database> completed = transaction.completed;
    final idb.ObjectStore booksStore = transaction.objectStore(_books);
    final idb.ObjectStore statesStore = transaction.objectStore(_states);
    final idb.ObjectStore preparationStore = transaction.objectStore(
      _preparations,
    );
    final Object? currentBookRaw = await booksStore.getObject(targetId);
    if (currentBookRaw is String) {
      final Json currentBook = jsonDecode(currentBookRaw) as Json;
      if (currentBook['book'] is! Json ||
          !_sameBookData(currentBook['book'] as Json, book) ||
          !_sameJson(currentBook['images'], images)) {
        throw const WebBackupConflict('本地同书资料已变化，未覆盖；请刷新后检查冲突。');
      }
      final Json? localNative = currentBook['native_backup'] is Json
          ? currentBook['native_backup'] as Json
          : null;
      final Json mergedBook;
      try {
        mergedBook = verdicts.mergeChapterVerdicts(
          currentBook['book'] as Json,
          book,
          localCheckPending: verdicts.titleCheckPending(localNative?['status']),
          incomingCheckPending: verdicts.titleCheckPending(
            nativeBackup?['status'],
          ),
        );
      } on verdicts.ChapterVerdictConflict {
        throw const WebBackupConflict('两端对章节标题的剧透判断不同，未覆盖；请分别导出备份后处理。');
      }
      final Json? mergedNative = _mergeNativeBackups(localNative, nativeBackup);
      final Json? lease = _decodeLease(
        await preparationStore.getObject(_preparationLeaseKey(targetId)),
      );
      if (lease != null &&
          (lease['expires'] as int) > DateTime.now().millisecondsSinceEpoch) {
        throw const WebBackupConflict('这本书正在整理，请先暂停后再导入快照。');
      }
      final Object? currentStateRaw = await statesStore.getObject(targetId);
      final WebReadingState currentState = currentStateRaw is String
          ? WebReadingState.fromJson(jsonDecode(currentStateRaw) as Json)
          : WebReadingState();
      final WebReadingState mergedState = _mergeReadingStates(
        currentState,
        incomingState,
      );
      final Object? currentPrepRaw = await preparationStore.getObject(targetId);
      final Json? currentPrep = currentPrepRaw is String
          ? _decodePreparation(currentPrepRaw)
          : null;
      final Json? mergedPrep = _mergePreparations(
        currentPrep,
        preparation == null ? null : _decodePreparation(preparation),
      );
      if (previewOnly) {
        await completed;
        return targetId;
      }
      if (!_sameJson(currentBook['book'], mergedBook) ||
          (mergedNative != null && !_sameJson(localNative, mergedNative))) {
        await booksStore.put(
          jsonEncode(<String, Object?>{
            ...currentBook,
            'book': mergedBook,
            'native_backup': ?mergedNative,
          }),
          targetId,
        );
      }
      await statesStore.put(jsonEncode(mergedState.toJson()), targetId);
      if (mergedPrep != null) {
        await preparationStore.put(_encodePreparation(mergedPrep), targetId);
      }
    } else {
      if (previewOnly) {
        await completed;
        return targetId;
      }
      await booksStore.put(
        jsonEncode(<String, Object?>{
          'book': book,
          'images': images,
          'native_backup': ?nativeBackup,
        }),
        targetId,
      );
      await transaction
          .objectStore(_meta)
          .put(
            jsonEncode(<String, Object?>{...meta.toJson(), 'id': targetId}),
            targetId,
          );
      await statesStore.put(jsonEncode(incomingState.toJson()), targetId);
      if (preparation != null) {
        await preparationStore.put(preparation, targetId);
      }
    }
    await completed;
    return targetId;
  }

  Future<Uint8List> exportBackupBytes(String id) async {
    final String owner = 'backup:$id:${DateTime.now().microsecondsSinceEpoch}';
    if (!await acquirePreparationLease(id, owner)) {
      throw StateError('这本书正在整理；请先暂停并等待当前模型请求结束，再导出完整备份。');
    }
    try {
      final WebBook? book = await load(id);
      if (book == null) throw StateError('书籍已不存在。');
      final WebReadingState reading = await state(id);
      final Json? savedPreparation = await loadPreparation(id);
      // An active worker owns the lease and was rejected above. An expired
      // lease may leave a running checkpoint after a browser crash. Export a
      // paused copy without changing the source or erasing its in-flight ID.
      final Json? preparation;
      if (savedPreparation != null &&
          (savedPreparation['phase'] == 'running' ||
              savedPreparation['in_flight'] != null)) {
        final String prior = savedPreparation['last_error'] is String
            ? savedPreparation['last_error'] as String
            : '';
        const String notice = '备份时上一轮模型请求尚未确认；继续可能重复计费。';
        final String detail = prior.isEmpty ? notice : '$prior\n$notice';
        preparation = <String, Object?>{
          ...savedPreparation,
          'phase': 'paused',
          'last_error': detail.length > 4096
              ? detail.substring(0, 4096)
              : detail,
        };
      } else {
        preparation = savedPreparation;
      }
      final Json backup = <String, Object?>{
        'format': 'thusfar-web-backup-v1',
        'exported': DateTime.now().millisecondsSinceEpoch / 1000,
        'meta': book.meta.toJson(),
        'book': book.data,
        'images': book.images,
        'state': reading.toJson(),
      };
      if (preparation != null) backup['preparation'] = preparation;
      if (book.nativeBackup != null) {
        final Json native = <String, Object?>{...book.nativeBackup!};
        // Native-only customization metadata is transferable, never rendered.
        // Refuse damaged or stale source bindings rather than losing them.
        _validateNativeExtras(native, book.data);
        backup['native_backup'] = native;
      }
      return Uint8List.fromList(utf8.encode(jsonEncode(backup)));
    } finally {
      await releasePreparationLease(id, owner);
    }
  }

  Future<void> exportBackup(String id) async {
    final WebBook? book = await load(id);
    if (book == null) throw StateError('书籍已不存在。');
    final Uint8List bytes = await exportBackupBytes(id);
    final html.Blob blob = html.Blob(<Object>[bytes], 'application/json');
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

  Future<Uint8List> exportLibraryZipBytes() async {
    final List<WebBookMeta> books = await list();
    final List<Uint8List> backups = <Uint8List>[];
    Json? newestModel = savedModelProfile();
    final bool hasSavedModel = newestModel != null;
    int newestAt = -1;
    for (final WebBookMeta book in books) {
      backups.add(await exportBackupBytes(book.id));
      final Json? preparation = await loadPreparation(book.id);
      final int updated = (preparation?['updated_at'] as num?)?.toInt() ?? -1;
      if (!hasSavedModel && preparation != null && updated > newestAt) {
        final Json candidate = <String, Object?>{
          'protocol':
              preparation['protocol'] ??
              _preparationProtocol('${preparation['endpoint'] ?? ''}'),
          'base_url': preparation['endpoint'],
          'model': preparation['model'],
        };
        try {
          newestModel = LibraryZipCodec.validatedModelProfile(candidate);
          newestAt = updated;
        } on FormatException {
          // An unusable old model profile does not block book export.
        }
      }
    }
    Json source = <String, Object?>{};
    try {
      final String? raw = html.window.localStorage[_librarySettingsStorageKey];
      if (raw != null) {
        source = LibraryZipCodec.validatedSettings(jsonDecode(raw));
      }
    } on Object {
      // Corrupt optional transfer metadata cannot block exporting books.
    }
    final Json prefs = _webReaderSettings();
    final Map<String, int> bookIndexes = <String, int>{
      for (int i = 0; i < books.length; i++) books[i].id: i,
    };
    final Json settings = <String, Object?>{
      if (source['native'] is Json) 'native': source['native'],
      'reader': prefs,
      'web': <String, Object?>{
        'pageMode': prefs['pageMode'],
        'columnWidth': prefs['columnWidth'],
        'fontSize': prefs['fontSize'],
      },
      'model': ?newestModel,
      'shelf': <String, Object?>{
        'readingQueue': <int>[
          ...<int>{
            for (final String id in _readingQueueIds())
              if (bookIndexes.containsKey(id)) bookIndexes[id]!,
          },
        ],
      },
    };
    return LibraryZipCodec.encode(
      books: backups,
      settings: settings,
      customizations: _exportReaderCustomizations(backups),
    );
  }

  /// Keep native identities intact, even when same-book import chose an
  /// existing browser shelf ID. A removed book must not donate its scoped
  /// rules to a different book that later occupies its archive position.
  static Map<String, String> _readerSources(List<Uint8List> backups) {
    final Map<String, String> sources = <String, String>{};
    for (final Uint8List bytes in backups) {
      final Json wrapper = jsonDecode(utf8.decode(bytes)) as Json;
      final Json? native = wrapper['format'] == 'yedu-book/2'
          ? wrapper
          : wrapper['native_backup'] as Json?;
      final String? id = native?['id'] as String?;
      if (id == null || id.isEmpty) continue;
      final String source = readerCustomizationSource(wrapper['book'] as Json);
      if (sources.containsKey(id) && sources[id] != source) {
        throw const FormatException('书库中的安装版书籍编号对应不同正文，未导出阅读自定义。');
      }
      sources[id] = source;
    }
    return sources;
  }

  static Json _savedReaderCustomizations(String raw) {
    final Object? value = jsonDecode(raw);
    if (value is! Json || value['books'] is! List<Object?>) {
      throw const FormatException('保留的阅读自定义已损坏，未生成不完整备份。');
    }
    final Map<String, String> sources = <String, String>{};
    for (final Object? row in value['books'] as List<Object?>) {
      if (row is! Json ||
          row['bookId'] is! String ||
          row['source'] is! String) {
        throw const FormatException('保留的阅读自定义书籍信息已损坏。');
      }
      sources[row['bookId'] as String] = row['source'] as String;
    }
    return validatedReaderLibrary(value, sources: sources);
  }

  static Json? _exportReaderCustomizations(List<Uint8List> backups) {
    final String? raw =
        html.window.localStorage[_libraryCustomizationsStorageKey];
    if (raw == null) return null;
    // Unlike optional cosmetic settings, dropping damaged customization data
    // would produce a deceptively successful, incomplete portable backup.
    return _survivingReaderCustomizations(
      _savedReaderCustomizations(raw),
      _readerSources(backups),
    );
  }

  static Json _survivingReaderCustomizations(
    Json saved,
    Map<String, String> sources,
  ) {
    for (final Object? value in saved['books'] as List<Object?>) {
      final Json row = value! as Json;
      final String id = row['bookId']! as String;
      if (sources.containsKey(id) && sources[id] != row['source']) {
        throw const FormatException('保留的阅读自定义与当前同编号书籍原文不同，未生成不完整备份。');
      }
    }
    final List<Json> retained = <Json>[
      for (final Object? row in saved['books'] as List<Object?>)
        if (row is Json && sources[row['bookId']] == row['source']) row,
    ];
    final Set<String> ids = retained
        .map((Json row) => row['bookId'] as String)
        .toSet();
    return validatedReaderLibrary(<String, Object?>{
      ...saved,
      'books': retained,
      'purification': <Object?>[
        for (final Object? row in saved['purification'] as List<Object?>)
          if (row is Json &&
              (row['bookId'] == null || ids.contains(row['bookId'])))
            row,
      ],
    }, sources: sources);
  }

  Future<Json?> _readerCustomizationsToRestore(LibraryZipData archive) async {
    final Json? incoming = archive.customizations;
    if (incoming == null) return null;
    final Json validated = LibraryZipCodec.validatedCustomizations(
      archive.books,
      incoming,
    );
    final Map<String, String> currentSources = <String, String>{};
    for (final WebBookMeta meta in await list()) {
      final WebBook? book = await load(meta.id);
      final String? id = book?.nativeBackup?['id'] as String?;
      if (book == null || id == null) continue;
      final String source = readerCustomizationSource(book.data);
      if (currentSources.containsKey(id) && currentSources[id] != source) {
        throw const FormatException('本地安装版书籍编号对应不同正文。');
      }
      currentSources[id] = source;
    }
    validatedReaderLibrary(validated, sources: currentSources);
    final String? raw =
        html.window.localStorage[_libraryCustomizationsStorageKey];
    if (raw != null) {
      final Json saved = _savedReaderCustomizations(raw);
      if (!_sameJson(
        _survivingReaderCustomizations(saved, currentSources),
        validated,
      )) {
        throw const WebBackupConflict(
          '书籍已恢复，但两份书库的阅读自定义不同，未覆盖；当前设置保留，请分别导出后处理。',
        );
      }
      // Preserve absent/recycled identities in local transfer storage. Export
      // filters them, and restoring that same source can recover original order.
      return saved;
    }
    return validated;
  }

  Future<void> exportLibraryZip() async {
    final Uint8List bytes = await exportLibraryZipBytes();
    final html.Blob blob = html.Blob(<Object>[bytes], 'application/zip');
    final String url = html.Url.createObjectUrlFromBlob(blob);
    final String date = DateTime.now().toIso8601String().substring(0, 10);
    final html.AnchorElement anchor = html.AnchorElement(href: url)
      ..download = '页读书库-$date.zip';
    html.document.body?.append(anchor);
    anchor.click();
    anchor.remove();
    Future<void>.delayed(
      const Duration(seconds: 2),
      () => html.Url.revokeObjectUrl(url),
    );
  }

  Future<WebLibraryZipRestoreResult> importLibraryZipData(
    LibraryZipData archive, {
    required bool applySettings,
  }) async {
    final Set<String> beforeIds = (await list()).map((b) => b.id).toSet();
    final int before = beforeIds.length;
    final List<RestoreReportEntry> entries = <RestoreReportEntry>[];
    final List<String> failures = <String>[];
    final List<String?> ids = <String?>[];
    for (int i = 0; i < archive.books.length; i++) {
      final String title = BackupSummary.read(
        archive.books[i],
        fallback: '第 ${i + 1} 本书',
      ).title;
      try {
        final String id = await importBackup(archive.books[i]);
        ids.add(id);
        entries.add(
          RestoreReportEntry(
            title: title,
            status: beforeIds.contains(id) ? 'merged' : 'imported',
          ),
        );
        beforeIds.add(id);
      } on WebBackupConflict catch (error) {
        ids.add(null);
        failures.add('《$title》：${error.message}');
        entries.add(
          RestoreReportEntry(
            title: title,
            status: 'conflict',
            detail: error.message,
          ),
        );
      } on FormatException catch (error) {
        ids.add(null);
        failures.add('《$title》：${error.message}');
        entries.add(
          RestoreReportEntry(
            title: title,
            status: 'conflict',
            detail: error.message,
          ),
        );
      } on Object {
        ids.add(null);
        failures.add('《$title》无法导入，请检查浏览器存储空间。');
        entries.add(
          RestoreReportEntry(
            title: title,
            status: 'conflict',
            detail: '无法导入，请检查浏览器存储空间。',
          ),
        );
      }
    }
    final int imported = ((await list()).length - before).clamp(
      0,
      archive.books.length,
    );
    String? settingsError;
    if (failures.isEmpty && applySettings) {
      Json? customizations;
      try {
        // Check before changing settings. Global rule order is meaningful and
        // two different archived sets cannot be silently chosen or combined.
        customizations = await _readerCustomizationsToRestore(archive);
      } on WebBackupConflict catch (error) {
        settingsError = error.message;
      } on FormatException {
        settingsError = '书籍已恢复，但阅读自定义损坏或来源不符，未覆盖当前设置。';
      } on Object {
        settingsError = '书籍已恢复，但无法校验阅读自定义；当前设置保留，请检查浏览器可用空间。';
      }
      if (settingsError == null) {
        try {
          final Json shelf =
              archive.settings['shelf'] as Json? ?? <String, Object?>{};
          final List<int> queue =
              shelf['readingQueue'] as List<int>? ?? <int>[];
          if (queue.isNotEmpty) {
            html.window.localStorage[_readingQueueStorageKey] = jsonEncode(
              <String>[
                ...<String>{
                  for (final int index in queue)
                    if (ids[index] != null) ids[index]!,
                  ..._readingQueueIds(),
                },
              ],
            );
          }
          _applyWebReaderSettings(archive.settings);
          if (customizations != null) {
            html.window.localStorage[_libraryCustomizationsStorageKey] =
                jsonEncode(customizations);
          }
        } on Object {
          settingsError = '书籍已恢复，设置未完全保存；请检查浏览器可用空间。';
        }
      }
    }
    final RestoreReport report = RestoreReport(
      created: DateTime.now(),
      entries: entries,
      settingsStatus: !applySettings
          ? '按你的选择保留当前设置'
          : failures.isNotEmpty
          ? '因书籍冲突而跳过，当前设置保留；可处理冲突后重试'
          : settingsError ??
                (archive.customizations == null
                    ? '已导入阅读清单、排版和模型设置；模型密钥需重填'
                    : '已导入阅读清单、排版和模型设置，并保留阅读自定义供安装版使用；网页版不应用净化或修正目录，模型密钥需重填'),
    );
    String? reportError;
    try {
      html.window.localStorage[_reportKey] = jsonEncode(report.toJson());
    } on Object {
      reportError = '恢复报告未能保存，请保留本次结果并检查存储空间。';
    }
    return WebLibraryZipRestoreResult(
      total: archive.books.length,
      imported: imported,
      existing: archive.books.length - imported - failures.length,
      failures: failures,
      settingsError: settingsError,
      report: report,
      reportError: reportError,
    );
  }

  static Json _webReaderSettings() {
    Json stored = <String, Object?>{};
    try {
      final String? raw = html.window.localStorage['thusfar-web-prefs'];
      final Object? decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Json) stored = decoded;
    } on Object {
      // A malformed reading preference falls back to the app defaults.
    }
    double metric(String key, double fallback, double min, double max) {
      final Object? value = stored[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(min, max)
          : fallback;
    }

    int choice(String key, int fallback, int max) {
      final Object? value = stored[key];
      return value is num && value.isFinite
          ? value.toInt().clamp(0, max)
          : fallback;
    }

    return <String, Object?>{
      'fontSize': metric('fontSize', 21, 14, 34),
      'lineHeight': metric('lineHeight', 1.75, 1.2, 2.4),
      'letterSpacing': metric('letterSpacing', 0, -0.5, 2.5),
      'margin': metric('margin', 24, 8, 90),
      'columnWidth': metric('columnWidth', 960, 520, 1400),
      'paper': choice('paper', 0, 4),
      'font': choice('font', 0, 2),
      'pageMode': stored['pageMode'] is bool ? stored['pageMode'] : true,
    };
  }

  static void _applyWebReaderSettings(Json settings) {
    final Json reader = settings['reader'] as Json? ?? <String, Object?>{};
    final Json web = settings['web'] as Json? ?? <String, Object?>{};
    final Json current = _webReaderSettings();
    final Json applied = <String, Object?>{
      ...current,
      for (final String key in const <String>[
        'fontSize',
        'lineHeight',
        'letterSpacing',
        'margin',
        'paper',
        'font',
        'pageMode',
        'columnWidth',
      ])
        if (reader.containsKey(key)) key: reader[key],
      if (web['fontSize'] is num) 'fontSize': web['fontSize'],
      if (web['pageMode'] is bool) 'pageMode': web['pageMode'],
      if (web['columnWidth'] is num) 'columnWidth': web['columnWidth'],
    };
    html.window.localStorage['thusfar-web-prefs'] = jsonEncode(applied);
    html.window.localStorage[_librarySettingsStorageKey] = jsonEncode(settings);
    final Object? model = settings['model'];
    if (model is Json) saveModelProfile(model);
  }

  RestoreReport? get lastRestoreReport {
    try {
      final String? raw = html.window.localStorage[_reportKey];
      return raw == null
          ? null
          : RestoreReport.fromJson(jsonDecode(raw) as Json);
    } on Object {
      return null;
    }
  }

  Future<List<WebTrashEntry>> listTrash() async {
    final idb.Transaction transaction = _database.transaction(
      _trash,
      'readonly',
    );
    final List<WebTrashEntry> result = [];
    await for (final idb.CursorWithValue row
        in transaction.objectStore(_trash).openCursor(autoAdvance: true)) {
      if (row.key is! String) continue;
      try {
        final Json value = jsonDecode(row.value as String) as Json;
        final Json meta = jsonDecode(value['meta'] as String) as Json;
        final Json book = jsonDecode(value['book'] as String) as Json;
        if (book['book'] is! Json || meta['id'] != value['id']) {
          throw const FormatException('invalid trash book');
        }
        result.add(
          WebTrashEntry(
            key: row.key as String,
            id: value['id'] as String,
            title: '${meta['title']}',
            removed: DateTime.parse(value['removed'] as String),
            bytes: utf8.encode(row.value as String).length,
          ),
        );
      } on Object {
        result.add(
          WebTrashEntry(
            key: row.key as String,
            id: '',
            title: '无法读取书名的回收记录',
            removed: DateTime.fromMillisecondsSinceEpoch(0),
            bytes: row.value is String
                ? utf8.encode(row.value as String).length
                : 0,
            issue: '这条回收记录损坏，暂不能自动恢复。原始数据仍保留，其他书籍可正常恢复。',
          ),
        );
      }
    }
    return result..sort((a, b) => b.removed.compareTo(a.removed));
  }

  Future<void> remove(String id) async {
    final idb.Transaction transaction = _database.transactionList(<String>[
      _books,
      _meta,
      _states,
      _preparations,
      _trash,
    ], 'readwrite');
    final Future<idb.Database> completed = transaction.completed;
    final Object? book = await transaction.objectStore(_books).getObject(id);
    final Object? meta = await transaction.objectStore(_meta).getObject(id);
    final Object? state = await transaction.objectStore(_states).getObject(id);
    final Object? preparation = await transaction
        .objectStore(_preparations)
        .getObject(id);
    final Json? lease = _decodeLease(
      await transaction
          .objectStore(_preparations)
          .getObject(_preparationLeaseKey(id)),
    );
    if (lease != null &&
        (lease['expires'] as int) > DateTime.now().millisecondsSinceEpoch) {
      throw StateError('这本书正在整理，请先暂停并等待当前请求结束再移除。');
    }
    if (book == null || meta == null) throw StateError('书籍已变化，请刷新书架。');
    final String key = '$id-${DateTime.now().microsecondsSinceEpoch}';
    await transaction
        .objectStore(_trash)
        .put(
          jsonEncode({
            'id': id,
            'book': book,
            'meta': meta,
            'state': state,
            'preparation': preparation,
            'removed': DateTime.now().toIso8601String(),
          }),
          key,
        );
    for (final String store in [_books, _meta, _states, _preparations]) {
      await transaction.objectStore(store).delete(id);
    }
    await transaction
        .objectStore(_preparations)
        .delete(_preparationLeaseKey(id));
    await completed;
  }

  Future<void> restoreFromTrash(String key) async {
    final idb.Transaction transaction = _database.transactionList(<String>[
      _books,
      _meta,
      _states,
      _preparations,
      _trash,
    ], 'readwrite');
    final Future<idb.Database> completed = transaction.completed;
    final Object? raw = await transaction.objectStore(_trash).getObject(key);
    if (raw is! String) throw StateError('回收站记录已变化，请刷新。');
    final Json value = jsonDecode(raw) as Json;
    final String id = value['id'] as String;
    final Json stored = jsonDecode(value['book'] as String) as Json;
    final Json meta = jsonDecode(value['meta'] as String) as Json;
    if (stored['book'] is! Json || meta['id'] != id || id.isEmpty) {
      throw StateError('回收记录损坏，未恢复；原始数据仍保留。');
    }
    if (await transaction.objectStore(_books).getObject(id) != null) {
      throw StateError('书架已有同一本书，未覆盖；回收站版本仍保留。请先导出两个版本。');
    }
    for (final (String store, String field) in [
      (_books, 'book'),
      (_meta, 'meta'),
      (_states, 'state'),
      (_preparations, 'preparation'),
    ]) {
      if (value[field] != null) {
        await transaction.objectStore(store).put(value[field], id);
      }
    }
    await transaction.objectStore(_trash).delete(key);
    await completed;
  }

  /// The caller must show an explicit irreversible-deletion confirmation.
  Future<void> permanentlyDeleteFromTrash(String key) async {
    final idb.Transaction transaction = _database.transaction(
      _trash,
      'readwrite',
    );
    final Future<idb.Database> completed = transaction.completed;
    await transaction.objectStore(_trash).delete(key);
    await completed;
  }

  void close() => _database.close();
}

Json? _decodeLease(Object? raw) {
  if (raw == null) return null;
  if (raw is! String || raw.length > 512) {
    throw const FormatException('浏览器整理锁无效，已停止请求。');
  }
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is Json &&
        decoded['owner'] is String &&
        (decoded['owner'] as String).isNotEmpty &&
        (decoded['owner'] as String).length <= 128 &&
        decoded['expires'] is int &&
        (decoded['expires'] as int) >= 0) {
      return decoded;
    }
  } on FormatException {
    // A malformed lock must fail closed, never authorize a paid request.
  }
  throw const FormatException('浏览器整理锁无效，已停止请求。');
}

const Set<String> _preparationFields = <String>{
  'schema',
  'scope',
  'phase',
  'endpoint',
  'protocol',
  'model',
  'in_flight',
  'last_error',
  'updated_at',
  'results',
  'events',
  'target_count',
  'completed_count',
};

final RegExp _credentialText = RegExp(
  r'\b(?:Bearer\s+\S{12,}|sk-[A-Za-z0-9_-]{12,}|gsk_[A-Za-z0-9_-]{12,}|AIza[A-Za-z0-9_-]{20,}|(?:api[_-]?key|access[_-]?token|refresh[_-]?token|authorization|client[_-]?secret|password)\s*[:=]\s*\S{8,})',
  caseSensitive: false,
);

/// Reject source passages that cannot be safely checkpointed if quoted.
bool webPreparationPassageContainsCredential(String text) =>
    _credentialText.hasMatch(text);

bool _credentialField(String field) {
  final String key = field.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return key == 'key' ||
      key == 'auth' ||
      key == 'authorization' ||
      key == 'headers' ||
      key == 'bearer' ||
      key.endsWith('apikey') ||
      key.endsWith('secret') ||
      key.endsWith('password') ||
      key.endsWith('credential') ||
      key.endsWith('token') ||
      key.endsWith('privatekey');
}

Object? _safePreparationValue(Object? value, int depth) {
  if (depth > 20) {
    throw const FormatException('书籍准备记录嵌套过深。');
  }
  if (value == null || value is bool) return value;
  if (value is String) {
    if (_credentialText.hasMatch(value)) {
      throw const FormatException('书籍准备记录含有凭据，未保存。');
    }
    return value;
  }
  if (value is num) {
    if (!value.isFinite) {
      throw const FormatException('书籍准备记录含有无效数字。');
    }
    return value;
  }
  if (value is List) {
    return <Object?>[
      for (final Object? row in value) _safePreparationValue(row, depth + 1),
    ];
  }
  if (value is Map) {
    final Json result = <String, Object?>{};
    for (final Object? key in value.keys) {
      if (key is! String) {
        throw const FormatException('书籍准备记录字段无效。');
      }
      if (_credentialField(key)) {
        throw const FormatException('书籍准备记录含有凭据字段，未保存。');
      }
      result[key] = _safePreparationValue(value[key], depth + 1);
    }
    return result;
  }
  throw const FormatException('书籍准备记录包含不支持的数据。');
}

Json _validatedPreparation(Json state) {
  if (state.isEmpty ||
      state.keys.any((String key) => !_preparationFields.contains(key))) {
    throw const FormatException('书籍准备记录包含不支持的字段。');
  }
  final Json result = <String, Object?>{
    for (final MapEntry<String, Object?> field in state.entries)
      field.key: _safePreparationValue(field.value, 0),
  };
  if (result['schema'] != 'thusfar-web-ai-v1' ||
      !validPreparationScope(result['scope']) ||
      !const <String>{
        'idle',
        'running',
        'paused',
        'complete',
        'error',
      }.contains(result['phase'])) {
    throw const FormatException('书籍准备状态无效。');
  }
  final Object? endpoint = result['endpoint'];
  if (endpoint is! String || endpoint.length > 2048) {
    throw const FormatException('书籍准备端点无效。');
  }
  final Uri? uri = Uri.tryParse(endpoint);
  final bool loopback =
      uri != null &&
      const <String>{
        'localhost',
        '127.0.0.1',
        '::1',
      }.contains(uri.host.toLowerCase());
  if (uri == null ||
      (uri.scheme != 'https' && !(loopback && uri.scheme == 'http')) ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const FormatException('书籍准备端点含有无效或敏感信息。');
  }
  final Object? protocol = result['protocol'];
  if (protocol == null) {
    result['protocol'] = _preparationProtocol(endpoint);
  } else if (!const <String>{
    'openai',
    'gemini',
    'anthropic',
  }.contains(protocol)) {
    throw const FormatException('书籍准备模型协议无效。');
  }
  final Object? model = result['model'];
  if (model is! String || model.isEmpty || model.length > 200) {
    throw const FormatException('书籍准备模型名称无效。');
  }
  final Object? updatedAt = result['updated_at'];
  if (updatedAt is! int || updatedAt < 0) {
    throw const FormatException('书籍准备更新时间无效。');
  }
  final Object? inFlight = result['in_flight'];
  if (inFlight != null &&
      (inFlight is! String ||
          !RegExp(r'^\d+:\d+$').hasMatch(inFlight) ||
          inFlight.length > 32)) {
    throw const FormatException('书籍准备进行中的分段无效。');
  }
  final Object? lastError = result['last_error'];
  if (lastError != null && (lastError is! String || lastError.length > 4096)) {
    throw const FormatException('书籍准备错误信息无效。');
  }
  final Object? results = result['results'];
  if (results is! Json || results.length > 50000) {
    throw const FormatException('书籍准备结果无效。');
  }
  for (final MapEntry<String, Object?> entry in results.entries) {
    final Object? row = entry.value;
    if (!RegExp(r'^\d+:\d+$').hasMatch(entry.key) ||
        entry.key.length > 32 ||
        row is! Json ||
        row['chapter_index'] is! int ||
        (row['chapter_index'] as int) < 0 ||
        row['chunk_index'] is! int ||
        (row['chunk_index'] as int) < 0 ||
        entry.key != '${row['chapter_index']}:${row['chunk_index']}' ||
        row['result'] is! Json ||
        row['completed_at'] is! int ||
        (row['completed_at'] as int) < 0) {
      throw const FormatException('书籍准备结果无效。');
    }
  }
  final Object? events = result['events'];
  if (events is! List ||
      events.length > 1000 ||
      events.any((Object? row) => row is! Json)) {
    throw const FormatException('书籍准备日志无效。');
  }
  for (final Object? row in events) {
    final Json event = row! as Json;
    if (event['at'] is! int ||
        (event['at'] as int) < 0 ||
        event['kind'] is! String ||
        (event['kind'] as String).length > 64 ||
        event['message'] is! String ||
        (event['message'] as String).length > 4096) {
      throw const FormatException('书籍准备日志无效。');
    }
  }
  for (final String field in <String>['target_count', 'completed_count']) {
    final Object? value = result[field];
    if (result.containsKey(field) &&
        (value is! int || value < 0 || value > 100000)) {
      throw const FormatException('书籍准备分段进度无效。');
    }
  }
  final Object? targetCount = result['target_count'];
  final Object? completedCount = result['completed_count'];
  if (targetCount is int &&
      completedCount is int &&
      completedCount > targetCount) {
    throw const FormatException('书籍准备分段进度无效。');
  }
  return result;
}

String _preparationProtocol(String endpoint) {
  final Uri? uri = Uri.tryParse(endpoint);
  if (uri == null) return 'openai';
  final String host = uri.host.toLowerCase();
  final String path = uri.path.toLowerCase();
  // Old Gemini checkpoints used its OpenAI-compatible /openai/ endpoint.
  if (host == 'generativelanguage.googleapis.com' &&
      !path.contains('/openai')) {
    return 'gemini';
  }
  if (host == 'api.anthropic.com') return 'anthropic';
  return 'openai';
}

String _encodePreparation(Json state) {
  final String encoded = jsonEncode(_validatedPreparation(state));
  if (utf8.encode(encoded).length > _maxPreparationBytes) {
    throw const FormatException('书籍准备记录超过 32 MB。');
  }
  return encoded;
}

Json _decodePreparation(String raw) {
  if (utf8.encode(raw).length > _maxPreparationBytes) {
    throw const FormatException('书籍准备记录超过 32 MB。');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    throw const FormatException('书籍准备记录无效。');
  }
  if (decoded is! Json) {
    throw const FormatException('书籍准备记录无效。');
  }
  return _validatedPreparation(decoded);
}

String _safeFilename(String title) => title
    .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
    .substring(0, math.min(title.length, 64));

class WebTrashEntry {
  const WebTrashEntry({
    required this.key,
    required this.id,
    required this.title,
    required this.removed,
    required this.bytes,
    this.issue,
  });
  final String? issue;
  final String key;
  final String id;
  final String title;
  final DateTime removed;
  final int bytes;
}
