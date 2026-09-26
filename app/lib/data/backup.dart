import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:thusfar_core/thusfar_core.dart';
import 'package:thusfar_core/parse.dart';
import 'package:thusfar_core/storage.dart' as storage;

import 'library.dart';

const String exportFormat = 'yedu-book/2';

Object? _strictRead(File file, {Object? missing}) {
  if (!file.existsSync()) return missing;
  try {
    return jsonDecode(file.readAsStringSync());
  } on FormatException {
    throw ValueError('书籍文件 ${file.uri.pathSegments.last} 已损坏，未生成不完整备份');
  }
}

Json _object(Object? raw, String field) {
  if (raw is! Json) throw ValueError('$field格式无效');
  return raw;
}

bool _same(Object? a, Object? b) {
  if (a is Json && b is Json) {
    return a.length == b.length &&
        a.keys.every(
          (String key) => b.containsKey(key) && _same(a[key], b[key]),
        );
  }
  if (a is List<Object?> && b is List<Object?>) {
    return a.length == b.length &&
        Iterable<int>.generate(a.length).every((int i) => _same(a[i], b[i]));
  }
  return a == b;
}

Map<String, String> _snapshot(Directory root) {
  final List<File> files = <File>[
    for (final String name in <String>[
      'book',
      'kg',
      'meta',
      'status',
      'notebook',
      'manual-entities',
    ])
      File('${root.path}/$name.json'),
  ];
  for (final String name in <String>['mentions', 'img']) {
    final Directory dir = Directory('${root.path}/$name');
    if (dir.existsSync()) {
      files.addAll(dir.listSync(followLinks: false).whereType<File>());
    }
  }
  return <String, String>{
    for (final File file in files)
      if (file.existsSync())
        file.path: crypto.sha256.convert(file.readAsBytesSync()).toString(),
  };
}

Json _mentions(Directory root) {
  final Directory dir = Directory('${root.path}/mentions');
  final Json result = <String, Object?>{};
  if (!dir.existsSync()) return result;
  final List<File> files =
      dir
          .listSync()
          .whereType<File>()
          .where((File file) => file.path.endsWith('.json'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));
  for (final File file in files) {
    final String name = file.uri.pathSegments.last;
    result[name.substring(0, name.length - 5)] = _strictRead(file);
  }
  return result;
}

Json _normalizedMentions(Json value) => <String, Object?>{
  for (final MapEntry<String, Object?> row in value.entries)
    '${int.parse(row.key)}': row.value,
};

bool _matchingSnapshot(
  Directory root,
  Json book,
  Json graph,
  Json mentions,
  Map<String, Uint8List> assets,
  List<Object?> personal,
  List<Object?> manual,
) {
  for (final (String name, Object? expected, Object? missing)
      in <(String, Object?, Object?)>[
        ('book', book, null),
        ('kg', graph, <String, Object?>{'log': <Object?>[]}),
        ('notebook', personal, <Object?>[]),
        ('manual-entities', manual, <Object?>[]),
      ]) {
    if (!_same(
      _strictRead(File('${root.path}/$name.json'), missing: missing),
      expected,
    )) {
      return false;
    }
  }
  if (!_same(
    _normalizedMentions(_mentions(root)),
    _normalizedMentions(mentions),
  )) {
    return false;
  }
  for (final MapEntry<String, Uint8List> entry in assets.entries) {
    final File file = File('${root.path}/img/${entry.key}');
    if (!file.existsSync() ||
        FileSystemEntity.isLinkSync(file.path) ||
        !_same(file.readAsBytesSync(), entry.value)) {
      return false;
    }
  }
  return true;
}

final RegExp _personalId = RegExp(r'^[A-Za-z0-9_-]{8,80}$');

String _sourceQuote(Json book, int start, int end) {
  if (start == end) return '';
  for (final Json block in (book['blocks']! as List<Object?>).cast<Json>()) {
    final int offset = block['o']! as int;
    final String text = block['t']! as String;
    if (offset > start) break;
    if ((block['k'] == 'p' || block['k'] == 'h') &&
        offset <= start &&
        end <= offset + text.length) {
      final String quote = text.substring(start - offset, end - offset);
      // Python's UTF-16 decoder rejects a boundary inside a surrogate pair.
      if (quote.runes.any((int rune) => rune >= 0xd800 && rune <= 0xdfff)) {
        break;
      }
      return quote;
    }
  }
  throw const ValueError('摘录位置已变化，请重新选择原文');
}

List<Object?> _validatePersonal(Object? raw, Json book) {
  if (raw is! List<Object?> || raw.length > 5000) {
    throw const ValueError('摘记备份无效');
  }
  final int length = book['len']! as int;
  final Set<String> seen = <String>{};
  final List<Object?> result = <Object?>[];
  for (final Object? value in raw) {
    final Json item = _object(value, '摘记');
    final Object? id = item['id'];
    if (id is! String || !_personalId.hasMatch(id)) {
      throw const ValueError('摘记编号无效');
    }
    if (!seen.add(id)) throw const ValueError('摘记编号重复');
    if (item['kind'] != 'bookmark' && item['kind'] != 'note') {
      throw const ValueError('摘记类型无效');
    }
    final int start = storage.integer(item['start'], '摘记位置', high: length);
    final int end = storage.integer(
      item['end'],
      '摘录终点',
      low: start,
      high: length,
    );
    final Object quote = item['quote'] ?? '';
    final Object text = item['text'] ?? '';
    if (quote is! String ||
        text is! String ||
        quote.runes.length > 4000 ||
        text.runes.length > 10000) {
      throw const ValueError('摘录限 4000 字，想法限 10000 字');
    }
    if (_sourceQuote(book, start, end) != quote) {
      throw const ValueError('摘录与原文不一致，未保存到错误位置');
    }
    if (item['kind'] == 'note' &&
        PyCompat.strip(quote).isEmpty &&
        PyCompat.strip(text).isEmpty) {
      throw const ValueError('请先写下想法或选择原文');
    }
    final Json clean = <String, Object?>{
      ...item,
      'quote': quote,
      'text': text,
      'deleted': item['deleted'] == true,
      'knowledge_cutoff': storage.integer(
        item['knowledge_cutoff'] ?? end,
        '摘记已读范围',
        low: end,
        high: length,
      ),
      'revision': storage.integer(
        item['revision'] ?? 1,
        '摘记版本',
        low: 1,
        high: 1000000000,
      ),
      'operation': PyCompat.slice('${item['operation'] ?? id}', 0, 80),
    };
    for (final String field in <String>['created', 'updated']) {
      final Object time =
          item[field] ?? DateTime.now().millisecondsSinceEpoch / 1000;
      if (time is! num || !time.isFinite || time < 0 || time > 1000000000000) {
        throw const ValueError('摘记时间无效');
      }
      clean[field] = time;
    }
    result.add(clean);
  }
  return result;
}

int _manualAnchor(Json book, String name, int cutoff) {
  for (final Json block in (book['blocks']! as List<Object?>).cast<Json>()) {
    final int offset = block['o']! as int;
    if (offset >= cutoff) break;
    if (block['k'] != 'p' && block['k'] != 'h') continue;
    final String text = block['t']! as String;
    final int at = text.indexOf(name);
    if (at >= 0 && offset + at + name.length <= cutoff) return offset + at;
  }
  throw const ValueError('当前已读原文里没有找到这个完整名称，请检查文字或继续阅读');
}

List<Object?> _validateManual(Object? raw, Json book) {
  if (raw is! List<Object?> || raw.length > 1000) {
    throw const ValueError('手动条目备份无效');
  }
  final int length = book['len']! as int;
  final Set<String> seen = <String>{};
  for (final Object? value in raw) {
    final Json item = _object(value, '手动条目');
    final Object? id = item['id'];
    if (id is! String || !_personalId.hasMatch(id)) {
      throw const ValueError('手动条目编号无效');
    }
    if (!seen.add(id)) throw const ValueError('手动条目编号重复');
    if (item['kind'] != 'person' && item['kind'] != 'concept') {
      throw const ValueError('请选择人物或概念');
    }
    final Object? name = item['name'];
    if (name is! String ||
        PyCompat.strip(name).isEmpty ||
        PyCompat.strip(name).runes.length > 80 ||
        name.contains('\n')) {
      throw const ValueError('名称须为 1—80 字');
    }
    final int cutoff = storage.integer(
      item['knowledge_cutoff'],
      '已读范围',
      high: length,
    );
    final Object? versions = item['versions'];
    if (versions is! List<Object?> ||
        versions.isEmpty ||
        versions.length > 1000) {
      throw const ValueError('手动条目版本无效');
    }
    int previous = -1;
    for (final Object? version in versions) {
      final Json row = _object(version, '手动条目版本');
      final int position = storage.integer(row['p'], '补充位置', high: length);
      if (position < previous ||
          row['note'] is! String ||
          (row['note']! as String).runes.length > 3000) {
        throw const ValueError('手动条目版本无效');
      }
      previous = position;
    }
    if (cutoff != previous) throw const ValueError('手动条目已读范围无效');
    if (_manualAnchor(
          book,
          PyCompat.strip(name),
          (versions.first! as Json)['p']! as int,
        ) !=
        item['source_start']) {
      throw const ValueError('手动条目原文位置无效');
    }
    storage.integer(item['revision'], '条目版本', low: 1, high: 1000000000);
    final Object? operation = item['operation'];
    if (operation is! String || !_personalId.hasMatch(operation)) {
      throw const ValueError('手动条目操作编号无效');
    }
    final Object? hash = item['operation_hash'];
    if (hash != null &&
        (hash is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash))) {
      throw const ValueError('手动条目操作摘要无效');
    }
  }
  // Preserve the original version history and optional fields exactly.
  return raw;
}

/// Outcome of importing one file, for the import progress bar (S03.2).
class ImportResult {
  const ImportResult({
    required this.name,
    this.id,
    this.error,
    this.existed = false,
  });

  final String name;
  final String? id;
  final String? error;
  final bool existed;
}

/// `app.py export`: one self-contained `.yedu.json` for a book.
Uint8List exportBookBytes(Library lib, BookEntry b) {
  final Map<String, String> before = _snapshot(b.dir);
  final Json out = <String, Object?>{
    'format': exportFormat,
    'exported': DateTime.now().millisecondsSinceEpoch / 1000,
    'id': b.id,
  };
  for (final String part in const <String>['book', 'kg', 'meta', 'status']) {
    out[part] = _object(
      _strictRead(
        File('${b.dir.path}/$part.json'),
        missing: <String, Object?>{},
      ),
      part,
    );
  }
  final Json book = storage.validateBook(out['book']);
  storage.validateGraph(out['kg'], book['len']! as int);
  out['mentions'] = _mentions(b.dir);
  out['assets'] = storage.encodeAssets(b.dir, out['book']! as Json);
  out['progress'] = lib.progressOf(b.id)?.toJson();
  out['notebook'] = _strictRead(
    File('${b.dir.path}/notebook.json'),
    missing: <Object?>[],
  );
  out['manual_entities'] = _strictRead(
    File('${b.dir.path}/manual-entities.json'),
    missing: <Object?>[],
  );
  _validatePersonal(out['notebook'], book);
  _validateManual(out['manual_entities'], book);
  if (!_same(before, _snapshot(b.dir))) {
    throw const ValueError('这本书正在更新，请稍后重新导出');
  }
  return utf8.encode(PyJson.encode(out, ensureAscii: false));
}

/// `app.py restore`: validates everything before a single atomic publish.
ImportResult restoreBackup(Library lib, String name, Uint8List raw) {
  final Object? data;
  try {
    data = jsonDecode(utf8.decode(raw));
  } on FormatException catch (e) {
    return ImportResult(name: name, error: '这个文件不是导出的书：${e.message}');
  }
  if (data is! Json) return ImportResult(name: name, error: '导出文件必须是书籍对象');
  if (data['format'] != 'yedu-book/1' && data['format'] != exportFormat) {
    return ImportResult(name: name, error: '认不出的格式：${data['format']}');
  }
  try {
    final Json book = storage.validateBook(data['book']);
    final Json graph = storage.validateGraph(
      data['kg'] ?? <String, Object?>{'log': <Object?>[]},
      book['len']! as int,
    );
    final List<Object?> personal = _validatePersonal(
      data['notebook'] ?? <Object?>[],
      book,
    );
    final List<Object?> manual = _validateManual(
      data['manual_entities'] ?? <Object?>[],
      book,
    );
    final Json sourceMeta = _object(
      data['meta'] ?? <String, Object?>{},
      '书籍元数据',
    );
    final Json sourceStatus = _object(
      data['status'] ?? <String, Object?>{},
      '整理状态',
    );
    storage.integer(
      sourceStatus['frontier'] ?? 0,
      '整理进度',
      high: book['len']! as int,
    );
    final Object? progress = data['progress'];
    int? pos;
    int? cutoff;
    if (progress != null) {
      final Json value = _object(progress, '阅读进度');
      pos = storage.integer(value['pos'], '阅读进度', high: book['len']! as int);
      cutoff = storage.integer(
        value['cutoff'] ?? pos,
        '已读范围',
        low: pos,
        high: book['len']! as int,
      );
    }
    if (data['format'] == 'yedu-book/1' &&
        storage.referencedAssets(book).isNotEmpty) {
      throw const ValueError('旧版导出没有包含图片，请从原设备重新导出完整书籍');
    }
    final Map<String, Uint8List> assets = storage.decodeAssets(
      data['assets'] ?? <String, Object?>{},
      book,
    );
    final Object mentions = data['mentions'] ?? <String, Object?>{};
    final int chapters = (book['chapters']! as List<Object?>).length;
    if (mentions is! Json || mentions.length > chapters) {
      throw const ValueError('人名索引无效');
    }
    final Set<Object?> known = <Object?>{};
    for (final Object? raw
        in (graph['log'] as List<Object?>?) ?? const <Object?>[]) {
      final Json r = raw! as Json;
      if (r['t'] == 'person') known.add(r['id']);
    }
    final Set<int> chapterIds = <int>{};
    for (final MapEntry<String, Object?> e in mentions.entries) {
      if (!RegExp(r'^[0-9]{1,6}$').hasMatch(e.key) ||
          int.parse(e.key) >= chapters ||
          e.value is! List<Object?> ||
          !chapterIds.add(int.parse(e.key))) {
        throw const ValueError('人名章节索引无效');
      }
      for (final Object? row in e.value! as List<Object?>) {
        if (row is! List<Object?> ||
            row.length < 3 ||
            row[2] is! String ||
            !known.contains(row[2])) {
          throw const ValueError('人名索引字段无效');
        }
        final int start = storage.integer(
          row[0],
          '人名起点',
          high: book['len']! as int,
        );
        storage.integer(row[1], '人名终点', low: start, high: book['len']! as int);
      }
    }
    final String id = crypto.sha1
        .convert(
          utf8.encode(PyJson.encode(book, ensureAscii: false, sortKeys: true)),
        )
        .toString()
        .substring(0, 16);
    final Directory dest = Directory('${lib.booksDir.path}/$id');
    if (File('${dest.path}/book.json').existsSync()) {
      if (!_matchingSnapshot(
        dest,
        book,
        graph,
        mentions,
        assets,
        personal,
        manual,
      )) {
        return ImportResult(name: name, error: '已有这本书的不同资料，未覆盖；请先保存现有版本后再处理');
      }
      return ImportResult(name: name, id: id, existed: true);
    }
    if (dest.existsSync()) {
      return ImportResult(name: name, error: '书籍目录不完整，请先检查已有文件');
    }
    final Directory tmp = Directory(
      '${lib.booksDir.path}/.$id.${DateTime.now().microsecondsSinceEpoch}.tmp',
    )..createSync(recursive: true);
    try {
      final double now = DateTime.now().millisecondsSinceEpoch / 1000;
      final Json meta = <String, Object?>{
        ...sourceMeta,
        'added': now,
        'auto': false,
        'imported': true,
        'hidden': false,
      };
      final Json state = <String, Object?>{...sourceStatus};
      if (state['state'] != 'done') {
        state
          ..['state'] = 'paused'
          ..['error'] = null
          ..['updated'] = now;
      }
      final Map<String, Object?> parts = <String, Object?>{
        'book': book,
        'kg': graph,
        'meta': meta,
        'status': state,
        'notebook': personal,
        'manual-entities': manual,
      };
      for (final MapEntry<String, Object?> p in parts.entries) {
        writeJson(File('${tmp.path}/${p.key}.json'), p.value);
      }
      for (final MapEntry<String, Object?> e in mentions.entries) {
        writeJson(
          File(
            '${tmp.path}/mentions/${int.parse(e.key).toString().padLeft(4, '0')}.json',
          ),
          e.value,
        );
      }
      if (assets.isNotEmpty) {
        Directory('${tmp.path}/img').createSync();
        for (final MapEntry<String, Uint8List> a in assets.entries) {
          File('${tmp.path}/img/${a.key}').writeAsBytesSync(a.value);
        }
      }
      tmp.renameSync(dest.path);
    } finally {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    }
    if (pos != null && cutoff != null) {
      lib.saveProgress(id, pos, cutoff, book['len']! as int);
    }
    return ImportResult(name: name, id: id);
  } on PyException catch (e) {
    return ImportResult(name: name, error: e.message);
  } on FileSystemException {
    return ImportResult(name: name, error: '无法读写书籍文件，请检查存储空间和文件权限后重试');
  } on FormatException {
    return ImportResult(name: name, error: '书籍数据格式无效，未覆盖现有资料');
  }
}

/// `app.py upload`: parse a TXT/EPUB off the UI thread and publish it as
/// `books/<sha1(file)[:16]>` exactly like 1.7.x.
Future<ImportResult> importBookFile(
  Library lib,
  String name,
  Uint8List raw,
) async {
  final String lower = name.toLowerCase();
  final String ext = lower.endsWith('.epub') ? '.epub' : '.txt';
  final String id = crypto.sha1.convert(raw).toString().substring(0, 16);
  final Directory dest = Directory('${lib.booksDir.path}/$id');
  if (File('${dest.path}/book.json').existsSync()) {
    return ImportResult(name: name, id: id, existed: true);
  }
  final Directory tmp = Directory(
    '${lib.booksDir.path}/.$id.${DateTime.now().microsecondsSinceEpoch}.tmp',
  )..createSync(recursive: true);
  try {
    final String tmpPath = tmp.path;
    final String? error = await Isolate.run(() {
      try {
        File('$tmpPath/source$ext').writeAsBytesSync(raw);
        final Json book = ext == '.epub'
            ? parseEpubFile(raw, 'source', (String n, List<int> data) {
                Directory('$tmpPath/img').createSync(recursive: true);
                File('$tmpPath/img/$n').writeAsBytesSync(data);
              })
            : parseTxt(raw, 'source');
        final Object? title = book['title'];
        if (title == null || title == '' || title == 'source') {
          book['title'] = name.contains('.')
              ? name.substring(0, name.lastIndexOf('.'))
              : name;
        }
        book
          ..['genre'] = 'novel'
          ..['genre_p'] = 0.0
          ..['genre_provisional'] = true;
        storage.validateBook(book);
        final double now = DateTime.now().millisecondsSinceEpoch / 1000;
        writeJson(File('$tmpPath/book.json'), book);
        writeJson(File('$tmpPath/meta.json'), <String, Object?>{
          'added': now,
          'filename': name,
          'auto': false,
        });
        writeJson(File('$tmpPath/status.json'), <String, Object?>{
          'state': 'idle',
          'done': 0,
          'total': 0,
          'frontier': 0,
        });
        return null;
      } on PyException catch (e) {
        return e.message;
      }
    });
    if (error != null) return ImportResult(name: name, error: error);
    if (File('${dest.path}/book.json').existsSync()) {
      return ImportResult(name: name, id: id, existed: true);
    }
    if (dest.existsSync()) {
      return ImportResult(name: name, error: '书籍目录不完整，请先检查已有文件');
    }
    tmp.renameSync(dest.path);
    return ImportResult(name: name, id: id);
  } finally {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }
}
