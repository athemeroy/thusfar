/// Validated, portable book snapshots and atomic JSON writes.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../errors.dart';
import '../pipeline/lang.dart';
import '../py/py_compat.dart';
import '../py/py_hash.dart';
import '../py/py_json.dart';
import '../py/py_re.dart';

const int assetLimit = 32 * 1024 * 1024;
const int assetsLimit = 96 * 1024 * 1024;
const int maxRecords = 1000000;
final RegExp _assetName = pyRe(r'[A-Za-z0-9_-][A-Za-z0-9_.-]{0,127}\Z');

/// `json.dump(value, ensure_ascii=False, separators=(',', ':'))` written
/// through a temporary file and an atomic rename.
void writeJson(File path, Object? value) {
  path.parent.createSync(recursive: true);
  final File tmp = File(
    '${path.parent.path}/.${path.uri.pathSegments.last}.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
  );
  try {
    final RandomAccessFile out = tmp.openSync(mode: FileMode.write);
    try {
      out.writeFromSync(
        utf8.encode(PyJson.encode(value, ensureAscii: false, compact: true)),
      );
      out.flushSync();
    } finally {
      out.closeSync();
    }
    tmp.renameSync(path.path);
  } finally {
    if (tmp.existsSync()) tmp.deleteSync();
  }
}

final RegExp _byline = pyRe(
  r'^(?P<title>.*?)\s*[-_—\s]*作者\s*[:：]\s*(?P<author>.*?)\s*$',
);
final RegExp _site = pyRe(r'(?i)^[\w.-]+\.(com|net|org|cn|cc)$');

/// TXT file names often carry the byline ("书名 作者：某某"); show it as
/// title + author. Display only: stored book data stays unchanged.
(String, String) displayTitle(String? title, String? author) {
  String t = PyCompat.strip(title ?? '');
  String a = PyCompat.strip(author ?? '');
  final RegExpMatch? m = pyMatch(_byline, t);
  if (m != null && (m.namedGroup('title') ?? '').isNotEmpty) {
    t = m.namedGroup('title')!;
    final String found = PyCompat.strip(m.namedGroup('author') ?? '');
    if (a.isEmpty && found.isNotEmpty && pyMatch(_site, found) == null) {
      a = found;
    }
  }
  return (t, a);
}

bool _truthy(Object? v) =>
    v != null &&
    v != false &&
    v != 0 &&
    v != '' &&
    !(v is List<Object?> && v.isEmpty) &&
    !(v is Map<Object?, Object?> && v.isEmpty);

Map<String, Object?> shelfFields(Map<String, Object?> book) {
  final List<Object?> chapters =
      _truthy(book['chapters']) ? book['chapters']! as List<Object?> : const [];
  final Map<String, Object?> out = <String, Object?>{
    for (final String k in <String>[
      'title',
      'author',
      'len',
      'cover',
      'lang',
      'genre',
    ])
      k: book[k],
  };
  if (!_truthy(out['lang'])) out['lang'] = bookLang(book);
  final Object? len = book['len'];
  out['chapters'] = chapters.length;
  out['thin'] =
      (_truthy(len) ? len! as num : 0) < 30000 ||
      chapters
              .where(
                (Object? c) => (c! as Map<String, Object?>)['kind'] == 'body',
              )
              .length <
          2;
  return out;
}

int integer(Object? value, String label, {int low = 0, int high = 120000000}) {
  if (value is! int || value < low || value > high) {
    throw ValueError('$label无效');
  }
  return value;
}

String assetName(Object? name) {
  if (name is! String || pyFullmatch(_assetName, name) == null) {
    throw const ValueError('图片文件名无效');
  }
  return name;
}

int _utf16Len(String s) => s.length;

Map<String, Object?> validateBook(Object? raw) {
  if (raw is! Map<String, Object?> || raw['title'] is! String) {
    throw const ValueError('书籍信息无效');
  }
  final Map<String, Object?> book = raw;
  final int length = integer(book['len'], '正文长度');
  final Object? blocks = book['blocks'];
  final Object? chapters = book['chapters'];
  if (blocks is! List<Object?> ||
      blocks.isEmpty ||
      blocks.length > maxRecords) {
    throw const ValueError('正文段落无效');
  }
  if (chapters is! List<Object?> ||
      chapters.isEmpty ||
      chapters.length > 100000) {
    throw const ValueError('章节无效');
  }
  int previous = -1;
  for (final Object? block in blocks) {
    if (block is! Map<String, Object?> ||
        !<Object?>['p', 'h', 'img'].contains(block['k']) ||
        block['t'] is! String) {
      throw const ValueError('正文段落格式无效');
    }
    final String text = block['t']! as String;
    final int pos = integer(block['o'], '段落位置', high: length);
    if (pos < previous || pos + _utf16Len(text) > length) {
      throw const ValueError('段落位置超出正文');
    }
    previous = pos;
    if (block['k'] == 'img') assetName(block['src']);
    for (final Object? item in (block['fn'] as List<Object?>?) ?? const []) {
      if (item is! List<Object?> || item.length != 2 || item[1] is! String) {
        throw const ValueError('脚注索引无效');
      }
      integer(item[0], '脚注位置', high: _utf16Len(text));
    }
  }
  previous = -1;
  for (final Object? chapter in chapters) {
    if (chapter is! Map<String, Object?> || chapter['title'] is! String) {
      throw const ValueError('章节格式无效');
    }
    final int a = integer(chapter['b0'], '章节起点', high: blocks.length);
    final int b = integer(chapter['b1'], '章节终点', low: a, high: blocks.length);
    final int p = integer(chapter['o0'], '章节位置', high: length);
    integer(chapter['o1'], '章节终点', low: p, high: length);
    if (a == b || p < previous) throw const ValueError('章节顺序无效');
    previous = p;
  }
  final Object? notes =
      book.containsKey('notes') ? book['notes'] : <String, Object?>{};
  if (notes is! Map<String, Object?>) throw const ValueError('脚注格式无效');
  if (!notes.values.every((Object? v) => v is String)) {
    throw const ValueError('脚注内容无效');
  }
  if (_truthy(book['cover'])) assetName(book['cover']);
  return book;
}

const Map<String, List<String>> _graphFields = <String, List<String>>{
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

Map<String, Object?> validateGraph(Object? raw, int length) {
  if (raw is! Map<String, Object?> ||
      (raw.containsKey('log') && raw['log'] is! List<Object?>)) {
    throw const ValueError('人物图谱格式无效');
  }
  final List<Object?> log = (raw['log'] as List<Object?>?) ?? const [];
  if (log.length > maxRecords) throw const ValueError('人物图谱太大');
  int previous = -1;
  for (final Object? item in log) {
    if (item is! Map<String, Object?> || !_graphFields.containsKey(item['t'])) {
      throw const ValueError('人物记录类型无效');
    }
    final Map<String, Object?> row = item;
    final int pos = integer(row['p'], '人物记录位置', high: length);
    if (pos < previous) throw const ValueError('人物记录没有按位置排序');
    previous = pos;
    for (final String key in _graphFields[row['t']]!) {
      if (row[key] is! String) throw const ValueError('人物记录字段无效');
    }
    for (final String key in const <String>[
      'intro',
      'tagline',
      'bio',
      'family',
      'a_is',
      'b_is',
      'desc',
      'status',
      'reason',
    ]) {
      if (row.containsKey(key) && row[key] != null && row[key] is! String) {
        throw const ValueError('人物记录文本无效');
      }
    }
    if (row.containsKey('s')) integer(row['s'], '原文位置', high: length);
    if (row.containsKey('imp')) integer(row['imp'], '人物重要度', high: 100);
    if (row.containsKey('chapter')) {
      integer(row['chapter'], '章节编号', high: 100000);
    }
    if (row['t'] == 'event') {
      final Object? who = row['who'];
      if (who is! List<Object?> || !who.every((Object? x) => x is String)) {
        throw const ValueError('事件人物无效');
      }
    }
    if (row['t'] == 'cnt') {
      final Object? c = row['c'];
      if (c is! Map<String, Object?> ||
          !c.values.every((Object? v) => v is int && v >= 0)) {
        throw const ValueError('人物计数无效');
      }
    }
  }
  return raw;
}

Set<String> referencedAssets(Map<String, Object?> book) {
  final Set<String> names = <String>{};
  for (final Object? raw in book['blocks']! as List<Object?>) {
    final Map<String, Object?> b = raw! as Map<String, Object?>;
    if (b['k'] == 'img') names.add(b['src']! as String);
  }
  if (_truthy(book['cover'])) names.add(book['cover']! as String);
  return names;
}

/// Base64 image payloads for a portable export, in sorted name order.
Map<String, Object?> encodeAssets(Directory root, Map<String, Object?> book) {
  final Map<String, Object?> assets = <String, Object?>{};
  int total = 0;
  final List<String> names = referencedAssets(book).toList()..sort();
  for (final String name in names) {
    assetName(name);
    final File path = File('${root.path}/img/$name');
    if (FileSystemEntity.isLinkSync(path.path) || !path.existsSync()) {
      throw const ValueError('这本书缺少图片，请先修复后再导出');
    }
    final int size = path.lengthSync();
    total += size;
    if (size > assetLimit || total > assetsLimit) {
      throw const ValueError('图片超过导出限制');
    }
    final Uint8List bytes = path.readAsBytesSync();
    assets[name] = <String, Object?>{
      'size': bytes.length,
      'sha256': sha256Hex(bytes),
      'base64': base64.encode(bytes),
    };
  }
  return assets;
}

final RegExp _base64 = RegExp(r'^[A-Za-z0-9+/]*={0,2}$');

Map<String, Uint8List> decodeAssets(Object? assets, Map<String, Object?> book) {
  if (assets is! Map<String, Object?> ||
      !_sameSet(assets.keys.toSet(), referencedAssets(book))) {
    throw const ValueError('图片清单与正文不一致');
  }
  final Map<String, Uint8List> out = <String, Uint8List>{};
  int total = 0;
  for (final MapEntry<String, Object?> e in assets.entries) {
    assetName(e.key);
    final Object? item = e.value;
    if (item is! Map<String, Object?>) throw const ValueError('图片格式无效');
    final int size = integer(item['size'], '图片长度', high: assetLimit);
    total += size;
    if (total > assetsLimit) throw const ValueError('图片总量太大');
    final Object? encoded = item['base64'];
    if (encoded is! String || encoded.length > ((size + 2) ~/ 3) * 4) {
      throw const ValueError('图片编码长度无效');
    }
    final Uint8List raw;
    try {
      if (encoded.length % 4 != 0 || !_base64.hasMatch(encoded)) {
        throw const FormatException();
      }
      raw = base64.decode(encoded);
    } on FormatException {
      throw const ValueError('图片编码无效');
    }
    if (raw.length != size || sha256Hex(raw) != item['sha256']) {
      throw const ValueError('图片校验失败');
    }
    out[e.key] = raw;
  }
  return out;
}

bool _sameSet(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);
