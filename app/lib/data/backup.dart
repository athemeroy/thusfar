import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:thusfar_core/chapter_verdicts.dart' as verdicts;
import 'package:thusfar_core/thusfar_core.dart';
import 'package:thusfar_core/parse.dart';
import 'package:thusfar_core/storage.dart' as storage;
import 'package:thusfar_core/notebook.dart' as notebook;
import 'package:thusfar_core/manual_entities.dart' as manual_entities;

import 'library.dart';

const String exportFormat = 'yedu-book/2';
const String webExportFormat = 'thusfar-web-backup-v1';
const String _webTransferName = 'web-transfer.json';
const String _mergeMarkerName = '.sync-merge-pending.json';

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
      'web-transfer',
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

bool _sameText(Json a, Json b) {
  // Chapter verdicts can change without changing a book's identity. Every
  // other book field, including its title, must still match exactly.
  final Json left = <String, Object?>{...a}..remove('chapters');
  final Json right = <String, Object?>{...b}..remove('chapters');
  return _same(left, right) &&
      verdicts.sameChapterContent(a['chapters'], b['chapters']);
}

bool _orderedSubset(List<Object?> older, List<Object?> newer) {
  if (older.length > newer.length) return false;
  int seen = 0;
  for (final Object? row in newer) {
    if (seen < older.length && _same(older[seen], row)) seen++;
  }
  return seen == older.length;
}

/// Graph records are sorted by source position, so a newly verified biography
/// can be inserted among older records. Every old record must still occur in
/// the same order; changed or removed evidence is a real conflict.
bool _graphExtends(Json older, Json newer) {
  for (final String key in <String>{...older.keys, ...newer.keys}) {
    if (key == 'log' || key == 'segments') continue;
    if (!older.containsKey(key) ||
        !newer.containsKey(key) ||
        !_same(older[key], newer[key])) {
      return false;
    }
  }
  final Object? oldSegments = older['segments'];
  final Object? newSegments = newer['segments'];
  if ((oldSegments != null && oldSegments is! List<Object?>) ||
      (newSegments != null && newSegments is! List<Object?>)) {
    return false;
  }
  return _orderedSubset(
        older['log'] as List<Object?>? ?? const <Object?>[],
        newer['log'] as List<Object?>? ?? const <Object?>[],
      ) &&
      _orderedSubset(
        oldSegments as List<Object?>? ?? const <Object?>[],
        newSegments as List<Object?>? ?? const <Object?>[],
      );
}

bool _mentionsExtend(Json older, Json newer) {
  final Json oldRows = _normalizedMentions(older);
  final Json newRows = _normalizedMentions(newer);
  for (final MapEntry<String, Object?> entry in oldRows.entries) {
    final Object? target = newRows[entry.key];
    if (entry.value is! List<Object?> ||
        target is! List<Object?> ||
        !_orderedSubset(entry.value! as List<Object?>, target)) {
      return false;
    }
  }
  return true;
}

void _writeMentions(Directory root, Json mentions) {
  final Directory dir = Directory('${root.path}/mentions')
    ..createSync(recursive: true);
  final Json normalized = _normalizedMentions(mentions);
  for (final File file in dir.listSync(followLinks: false).whereType<File>()) {
    if (file.path.endsWith('.json')) file.deleteSync();
  }
  for (final MapEntry<String, Object?> entry in normalized.entries) {
    writeJson(
      File(
        '${dir.path}/${int.parse(entry.key).toString().padLeft(4, '0')}.json',
      ),
      entry.value,
    );
  }
}

String _digest(Object? value) => crypto.sha256
    .convert(
      utf8.encode(PyJson.encode(value, ensureAscii: false, sortKeys: true)),
    )
    .toString();

int _chapterOffset(Json book, int chapter, double fraction) {
  final List<Object?> chapters = book['chapters']! as List<Object?>;
  if (chapter < 0 ||
      chapter >= chapters.length ||
      !fraction.isFinite ||
      fraction < 0 ||
      fraction > 1) {
    throw const ValueError('网页版阅读位置无效');
  }
  final Json row = chapters[chapter]! as Json;
  final int start = row['o0']! as int;
  final int end = row['o1']! as int;
  return (start + ((end - start) * fraction).round()).clamp(start, end);
}

String _legacyWebPersonalId(String kind, Json row) {
  final int chapter = row['chapter']! as int;
  final double fraction = (row['fraction']! as num).toDouble();
  final String text = kind == 'notes' ? row['text']! as String : '';
  final int created = kind == 'notes'
      ? (row['created'] as num?)?.toInt() ?? 0
      : 0;
  return 'web${crypto.sha256.convert(utf8.encode(jsonEncode(<Object?>[kind == 'notes' ? 'note' : 'bookmark', chapter, fraction.toString(), text, created]))).toString().substring(0, 24)}';
}

(int, double) _webPosition(Json book, int offset) {
  final List<Object?> chapters = book['chapters']! as List<Object?>;
  int index = 0;
  for (int i = 0; i < chapters.length; i++) {
    if ((chapters[i]! as Json)['o0']! as int <= offset) index = i;
  }
  final Json row = chapters[index]! as Json;
  final int start = row['o0']! as int;
  final int end = row['o1']! as int;
  final double fraction = end <= start
      ? 0
      : ((offset - start) / (end - start)).clamp(0.0, 1.0);
  return (index, fraction);
}

Json _validatedWebState(Object? raw, Json book) {
  if (raw is! Json) throw const ValueError('网页版阅读记录无效');
  final Object chapter = raw['chapter'] ?? 0;
  final Object fraction = raw['fraction'] ?? 0;
  final Object opened = raw['lastOpened'] ?? 0;
  if (chapter is! int ||
      fraction is! num ||
      opened is! num ||
      !fraction.toDouble().isFinite ||
      !opened.toDouble().isFinite ||
      opened < 0 ||
      opened > 1000000000000000) {
    throw const ValueError('网页版阅读记录无效');
  }
  _chapterOffset(book, chapter, fraction.toDouble());
  final Json state = <String, Object?>{
    'chapter': chapter,
    'fraction': fraction.toDouble(),
    'lastOpened': opened.toInt(),
  };
  final Set<String> ids = <String>{};
  for (final String kind in const <String>['bookmarks', 'notes']) {
    final Object entries = raw[kind] ?? <Object?>[];
    if (entries is! List<Object?> || entries.length > notebook.maxItems) {
      throw const ValueError('网页版书签或摘记无效');
    }
    final List<Json> clean = <Json>[];
    for (final Object? value in entries) {
      if (value is! Json ||
          value['chapter'] is! int ||
          value['fraction'] is! num) {
        throw const ValueError('网页版书签或摘记无效');
      }
      final int at = value['chapter']! as int;
      final double ratio = (value['fraction']! as num).toDouble();
      _chapterOffset(book, at, ratio);
      final Object? rawId = value['id'];
      if (rawId != null &&
          (rawId is! String ||
              !RegExp(r'^[A-Za-z0-9_-]{8,80}$').hasMatch(rawId))) {
        throw const ValueError('网页版书签或摘记编号无效');
      }
      final String id = rawId is String
          ? rawId
          : _legacyWebPersonalId(kind, value);
      if (!ids.add(id)) throw const ValueError('网页版书签或摘记编号重复');
      final Object revision = value['revision'] ?? 1;
      final Object updated = value['updated'] ?? value['created'] ?? 0;
      final Object deleted = value['deleted'] ?? false;
      if (revision is! int ||
          revision < 1 ||
          revision > 1000000000 ||
          updated is! num ||
          !updated.toDouble().isFinite ||
          updated < 0 ||
          updated > 1000000000000000 ||
          deleted is! bool) {
        throw const ValueError('网页版书签或摘记版本无效');
      }
      if (kind == 'notes') {
        final Object? text = value['text'];
        final Object created = value['created'] ?? 0;
        if (text is! String ||
            text.runes.length > 10000 ||
            created is! num ||
            !created.toDouble().isFinite ||
            created < 0 ||
            created > 1000000000000000) {
          throw const ValueError('网页版摘记无效');
        }
        clean.add(<String, Object?>{
          'chapter': at,
          'fraction': ratio,
          'text': text,
          'created': created.toInt(),
          'id': id,
          'revision': revision,
          'updated': updated.toInt(),
          'deleted': deleted,
        });
      } else {
        clean.add(<String, Object?>{
          'chapter': at,
          'fraction': ratio,
          'id': id,
          'revision': revision,
          'updated': updated.toInt(),
          'deleted': deleted,
        });
      }
    }
    state[kind] = clean;
  }
  return state;
}

Json? _validatedWebPreparation(Object? raw) {
  if (raw == null) return null;
  if (raw is! Json) throw const ValueError('网页版整理草稿无效');
  final String encoded = jsonEncode(raw);
  if (utf8.encode(encoded).length > 32 * 1024 * 1024) {
    throw const ValueError('网页版整理草稿超过 32 MB');
  }
  const Set<String> allowed = <String>{
    'schema',
    'scope',
    'phase',
    'endpoint',
    'model',
    'in_flight',
    'last_error',
    'updated_at',
    'results',
    'events',
    'target_count',
    'completed_count',
  };
  if (raw.isEmpty || raw.keys.any((String key) => !allowed.contains(key))) {
    throw const ValueError('网页版整理草稿包含不支持的字段');
  }
  final RegExp credentialText = RegExp(
    r'\b(?:Bearer\s+\S{12,}|sk-[A-Za-z0-9_-]{12,}|gsk_[A-Za-z0-9_-]{12,}|AIza[A-Za-z0-9_-]{20,}|(?:api[_-]?key|access[_-]?token|refresh[_-]?token|authorization|client[_-]?secret|password)\s*[:=]\s*\S{8,})',
    caseSensitive: false,
  );
  bool containsCredential(Object? value, int depth) {
    if (depth > 20) throw const ValueError('网页版整理草稿嵌套过深');
    if (value is Map) {
      for (final MapEntry<Object?, Object?> entry in value.entries) {
        final String key = '${entry.key}'.toLowerCase().replaceAll(
          RegExp(r'[^a-z0-9]'),
          '',
        );
        if (key == 'key' ||
            key == 'auth' ||
            key == 'authorization' ||
            key == 'headers' ||
            key == 'bearer' ||
            key.endsWith('apikey') ||
            key.endsWith('secret') ||
            key.endsWith('password') ||
            key.endsWith('credential') ||
            key.endsWith('token') ||
            key.endsWith('privatekey')) {
          return true;
        }
        if (containsCredential(entry.value, depth + 1)) return true;
      }
    } else if (value is List) {
      for (final Object? item in value) {
        if (containsCredential(item, depth + 1)) return true;
      }
    } else if (value is String && credentialText.hasMatch(value)) {
      return true;
    }
    return false;
  }

  if (containsCredential(raw, 0)) {
    throw const ValueError('网页版整理草稿包含疑似密钥，未导入');
  }
  if (raw['schema'] != 'thusfar-web-ai-v1' ||
      !const <String>{'first', 'read', 'all'}.contains(raw['scope']) ||
      !const <String>{
        'idle',
        'running',
        'paused',
        'complete',
        'error',
      }.contains(raw['phase'])) {
    throw const ValueError('网页版整理草稿状态无效');
  }
  final Object? endpoint = raw['endpoint'];
  if (endpoint is! String || endpoint.length > 2048) {
    throw const ValueError('网页版模型地址无效');
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
    throw const ValueError('网页版模型地址含有无效或敏感信息');
  }
  final Object? model = raw['model'];
  final Object? updatedAt = raw['updated_at'];
  final Object? inFlight = raw['in_flight'];
  final Object? lastError = raw['last_error'];
  final Object? results = raw['results'];
  final Object? events = raw['events'];
  if (model is! String ||
      model.isEmpty ||
      model.length > 200 ||
      updatedAt is! int ||
      updatedAt < 0 ||
      (inFlight != null &&
          (inFlight is! String ||
              !RegExp(r'^\d+:\d+$').hasMatch(inFlight) ||
              inFlight.length > 32)) ||
      (lastError != null &&
          (lastError is! String || lastError.length > 4096)) ||
      results is! Json ||
      results.length > 50000 ||
      events is! List ||
      events.length > 1000) {
    throw const ValueError('网页版整理草稿内容无效');
  }
  for (final MapEntry<String, Object?> entry in results.entries) {
    final Object? row = entry.value;
    if (!RegExp(r'^\d+:\d+$').hasMatch(entry.key) ||
        entry.key.length > 32 ||
        row is! Json ||
        row['chapter_index'] is! int ||
        row['chunk_index'] is! int ||
        (row['chapter_index'] as int) < 0 ||
        (row['chunk_index'] as int) < 0 ||
        entry.key != '${row['chapter_index']}:${row['chunk_index']}' ||
        row['result'] is! Json ||
        row['completed_at'] is! int ||
        (row['completed_at'] as int) < 0) {
      throw const ValueError('网页版整理草稿结果无效');
    }
  }
  for (final Object? value in events) {
    if (value is! Json ||
        value['at'] is! int ||
        (value['at'] as int) < 0 ||
        value['kind'] is! String ||
        (value['kind'] as String).length > 64 ||
        value['message'] is! String ||
        (value['message'] as String).length > 4096) {
      throw const ValueError('网页版整理日志无效');
    }
  }
  for (final String field in const <String>[
    'target_count',
    'completed_count',
  ]) {
    final Object? count = raw[field];
    if (count != null && (count is! int || count < 0 || count > 100000)) {
      throw const ValueError('网页版整理分段进度无效');
    }
  }
  if (raw['target_count'] is int &&
      raw['completed_count'] is int &&
      (raw['completed_count'] as int) > (raw['target_count'] as int)) {
    throw const ValueError('网页版整理分段进度无效');
  }
  return raw;
}

List<Json> _webNotebook(Json state, Json book) {
  final List<Json> rows = <Json>[];
  for (final String kind in const <String>['bookmarks', 'notes']) {
    final List<Object?> entries = state[kind]! as List<Object?>;
    for (final Object? entry in entries) {
      final Json row = entry! as Json;
      final int offset = _chapterOffset(
        book,
        row['chapter']! as int,
        row['fraction']! as double,
      );
      final String text = kind == 'notes' ? row['text']! as String : '';
      final String id = row['id']! as String;
      final double created = kind == 'notes'
          ? (row['created']! as int) / 1000
          : 0;
      rows.add(<String, Object?>{
        'id': id,
        'kind': kind == 'notes' ? 'note' : 'bookmark',
        'start': offset,
        'end': offset,
        'quote': '',
        'text': text,
        'knowledge_cutoff': offset,
        'deleted': row['deleted'],
        'revision': row['revision'],
        'operation': id,
        'created': created,
        'updated': (row['updated']! as int) / 1000,
      });
    }
  }
  return notebook.restore(rows, book);
}

List<Json> _newWebNotebook(Json state, Json book, List<Json> embeddedNative) {
  final List<Json> projected = _webNotebook(state, book);
  if (embeddedNative.isEmpty) return projected;
  return <Json>[
    for (final Json row in projected)
      if (!embeddedNative.any((Json native) {
        if (native['kind'] != row['kind'] ||
            native['start'] is! int ||
            row['start'] is! int ||
            ((native['start'] as int) - (row['start'] as int)).abs() > 1) {
          return false;
        }
        if (native['deleted'] != row['deleted'] ||
            (native['id'] == row['id'] &&
                native['revision'] != row['revision']) ||
            (row['deleted'] == true && native['id'] != row['id'])) {
          return false;
        }
        if (row['kind'] == 'bookmark') return true;
        final String note = '${native['text'] ?? ''}';
        final String visible = note.isEmpty ? '${native['quote'] ?? ''}' : note;
        return visible == row['text'];
      }))
        row,
  ];
}

Json _nativeWebState(Json book, Progress? progress, List<Json> personal) {
  final int pos = progress?.pos ?? 0;
  final (int chapter, double fraction) = _webPosition(book, pos);
  final Json state = <String, Object?>{
    'chapter': chapter,
    'fraction': fraction,
    'lastOpened': ((progress?.t ?? 0) * 1000).round(),
    'bookmarks': <Json>[],
    'notes': <Json>[],
  };
  for (final Json row in personal) {
    final (int at, double ratio) = _webPosition(book, row['start']! as int);
    final Json anchor = <String, Object?>{
      'chapter': at,
      'fraction': ratio,
      'id': row['id'],
      'revision': row['revision'],
      'updated': ((row['updated']! as num) * 1000).round(),
      'deleted': row['deleted'],
    };
    if (row['kind'] == 'bookmark') {
      (state['bookmarks']! as List<Json>).add(anchor);
    } else if (row['kind'] == 'note') {
      final String note = row['text']! as String;
      (state['notes']! as List<Json>).add(<String, Object?>{
        ...anchor,
        'text': note.isEmpty ? row['quote'] : note,
        'created': ((row['created']! as num) * 1000).round(),
      });
    }
  }
  return state;
}

Json? _webTransfer(Directory root) {
  final Object? raw = _strictRead(File('${root.path}/$_webTransferName'));
  if (raw == null) return null;
  if (raw is! Json) throw const ValueError('网页版同步记录已损坏，未导出不完整备份');
  return raw;
}

/// Keep an unchanged browser anchor exactly as it was saved. Mapping a
/// fractional chapter position through an integer Native offset is lossy, so
/// regenerating that anchor can make an unchanged item look like a conflicting
/// edit to the browser (the ID and revision would still be the same).
List<Json> _preserveWebAnchors(
  Json book,
  List<Json> generated,
  List<Json> original, {
  required bool notes,
}) {
  final Map<String, Json> oldById = <String, Json>{
    for (final Json row in original) row['id']! as String: row,
  };
  return <Json>[
    for (final Json row in generated)
      () {
        final Json? old = oldById[row['id']];
        if (old == null ||
            old['revision'] != row['revision'] ||
            old['updated'] != row['updated'] ||
            old['deleted'] != row['deleted'] ||
            (notes &&
                (old['text'] != row['text'] ||
                    old['created'] != row['created'])) ||
            _chapterOffset(
                  book,
                  old['chapter']! as int,
                  old['fraction']! as double,
                ) !=
                _chapterOffset(
                  book,
                  row['chapter']! as int,
                  row['fraction']! as double,
                )) {
          return row;
        }
        return old;
      }(),
  ];
}

Json _webStateForExport(
  Directory root,
  Json book,
  Progress? progress,
  List<Json> personal,
) {
  final Json generated = _nativeWebState(book, progress, personal);
  final Json? transfer = _webTransfer(root);
  final Object? old = transfer?['state'];
  if (old is! Json) return generated;
  final Json original = _validatedWebState(old, book);
  if (transfer?['mapped_pos'] == progress?.pos) {
    generated['chapter'] = original['chapter'];
    generated['fraction'] = original['fraction'];
  }
  generated['bookmarks'] = _preserveWebAnchors(
    book,
    (generated['bookmarks']! as List<Object?>).cast<Json>(),
    (original['bookmarks']! as List<Object?>).cast<Json>(),
    notes: false,
  );
  generated['notes'] = _preserveWebAnchors(
    book,
    (generated['notes']! as List<Object?>).cast<Json>(),
    (original['notes']! as List<Object?>).cast<Json>(),
    notes: true,
  );
  return generated;
}

Json _webAsNative(Json wrapper) {
  final Json book = storage.validateBook(wrapper['book']);
  final Json images = _object(
    wrapper['images'] ?? <String, Object?>{},
    '网页版图片',
  );
  final Set<String> requiredImages = storage.referencedAssets(book);
  if (!images.keys.toSet().containsAll(requiredImages)) {
    throw const ValueError('网页版备份缺少原图，请从原设备重新导出完整书籍');
  }
  final Json assets = <String, Object?>{};
  int total = 0;
  for (final String name in requiredImages) {
    storage.assetName(name);
    final Object? value = images[name];
    if (value is! String) throw const ValueError('网页版图片数据无效');
    final Uint8List bytes;
    try {
      bytes = base64.decode(value);
    } on FormatException {
      throw const ValueError('网页版图片编码无效');
    }
    total += bytes.length;
    if (bytes.length > storage.assetLimit || total > storage.assetsLimit) {
      throw const ValueError('网页版图片超过安装版备份上限');
    }
    assets[name] = <String, Object?>{
      'size': bytes.length,
      'sha256': crypto.sha256.convert(bytes).toString(),
      'base64': value,
    };
  }
  if (wrapper['state'] is! Json) throw const ValueError('网页版备份缺少阅读记录');
  final Json state = _validatedWebState(wrapper['state'], book);
  final Json? preparation = _validatedWebPreparation(wrapper['preparation']);
  final Object? rawNative = wrapper['native_backup'];
  final Json native;
  if (rawNative == null) {
    native = <String, Object?>{};
  } else if (rawNative is Json &&
      (rawNative['format'] == exportFormat ||
          rawNative['format'] == 'yedu-book/1')) {
    native = rawNative;
    if (native['book'] != null &&
        !_sameText(_object(native['book'], '安装版书籍'), book)) {
      throw const ValueError('网页版与安装版正文不一致，未合并');
    }
    if (native['assets'] != null && !_same(native['assets'], assets)) {
      throw const ValueError('网页版与安装版图片不一致，未合并');
    }
  } else {
    throw const ValueError('网页版内嵌安装版资料无效');
  }
  final int pos = _chapterOffset(
    book,
    state['chapter']! as int,
    state['fraction']! as double,
  );
  final Json previousProgress = native['progress'] is Json
      ? native['progress']! as Json
      : <String, Object?>{};
  final int previousCutoff = previousProgress['cutoff'] is int
      ? previousProgress['cutoff']! as int
      : 0;
  final Json out = <String, Object?>{
    ...native,
    'format': exportFormat,
    'book': book,
    'assets': assets,
    'kg': native['kg'] ?? <String, Object?>{'log': <Object?>[]},
    'meta': native['meta'] ?? <String, Object?>{},
    'status':
        native['status'] ?? <String, Object?>{'state': 'paused', 'frontier': 0},
    'mentions': native['mentions'] ?? <String, Object?>{},
    'progress': <String, Object?>{
      'pos': pos,
      'cutoff': math.max(pos, previousCutoff),
      't': (state['lastOpened']! as int) / 1000,
    },
    'notebook': native['notebook'] ?? <Object?>[],
    'manual_entities': native['manual_entities'] ?? <Object?>[],
    'web_state': state,
    'web_preparation': ?preparation,
  };
  return out;
}

Json? _mergePreparation(Json? local, Json? incoming) {
  if (incoming == null) return local;
  if (local == null || _same(local, incoming)) return incoming;
  final Object? localResults = local['results'];
  final Object? incomingResults = incoming['results'];
  if (localResults is! Json || incomingResults is! Json) {
    throw const ValueError('两端整理草稿不同，请先分别导出备份后手动选择');
  }
  final Json results = <String, Object?>{...localResults};
  for (final MapEntry<String, Object?> entry in incomingResults.entries) {
    if (results.containsKey(entry.key) &&
        !_same(results[entry.key], entry.value)) {
      throw const ValueError('同一段有不同整理草稿，请先分别导出备份后手动选择');
    }
    results[entry.key] = entry.value;
  }
  final int localUpdated = (local['updated_at'] as num?)?.toInt() ?? 0;
  final int incomingUpdated = (incoming['updated_at'] as num?)?.toInt() ?? 0;
  final Json latest = localUpdated > incomingUpdated ? local : incoming;
  final List<Object?> events = <Object?>[];
  final Set<String> seen = <String>{};
  for (final Object? event in <Object?>[
    ...((local['events'] as List<Object?>?) ?? const <Object?>[]),
    ...((incoming['events'] as List<Object?>?) ?? const <Object?>[]),
  ]) {
    final String marker = _digest(event);
    if (seen.add(marker)) events.add(event);
  }
  final Json merged = <String, Object?>{
    ...latest,
    'phase': 'paused',
    'in_flight': null,
    'target_count': math.max(
      results.length,
      math.max(
        (local['target_count'] as num?)?.toInt() ?? 0,
        (incoming['target_count'] as num?)?.toInt() ?? 0,
      ),
    ),
    'completed_count': results.length,
    'results': results,
    'events': events.length <= 120
        ? events
        : events.sublist(events.length - 120),
  };
  return _validatedWebPreparation(merged);
}

List<Json> _mergePersonal(List<Json> local, List<Json> incoming, Json book) {
  final List<Json> result = <Json>[...local];
  final Map<String, Json> byId = <String, Json>{
    for (final Json row in local) row['id']! as String: row,
  };
  bool sameContent(Json a, Json b) =>
      a['kind'] == b['kind'] &&
      a['start'] == b['start'] &&
      a['end'] == b['end'] &&
      a['text'] == b['text'] &&
      a['deleted'] == b['deleted'];
  for (final Json row in incoming) {
    final String id = row['id']! as String;
    final Json? old = byId[id];
    if (old != null) {
      final int oldRevision = old['revision']! as int;
      final int revision = row['revision']! as int;
      if (revision < oldRevision) continue;
      if (revision == oldRevision && !_same(old, row)) {
        throw const ValueError('已有这本书的不同资料：同一摘记在两端有不同修改，未覆盖；请先分别导出备份');
      }
      if (revision > oldRevision) {
        final bool projectedDeletion =
            row['deleted'] == true &&
            row['operation'] == id &&
            (old['end'] != row['end'] ||
                old['quote'] != row['quote'] ||
                old['text'] != row['text']);
        final Json next = projectedDeletion
            ? <String, Object?>{
                ...old,
                'deleted': true,
                'revision': revision,
                'operation': row['operation'],
                'updated': row['updated'],
              }
            : row;
        result[result.indexOf(old)] = next;
        byId[id] = next;
      }
      continue;
    }
    if (row['deleted'] == true && id.startsWith('web')) {
      // Older Web imports projected the same row under an index-based ID.
      // Tombstone that historical projection as well as retaining the new ID.
      for (int i = 0; i < result.length; i++) {
        final Json prior = result[i];
        if (prior['deleted'] == true ||
            prior['id'] == id ||
            prior['id'] is! String ||
            !(prior['id'] as String).startsWith('web') ||
            prior['kind'] != row['kind'] ||
            prior['start'] != row['start'] ||
            prior['text'] != row['text'] ||
            prior['created'] != row['created']) {
          continue;
        }
        final Json removed = <String, Object?>{
          ...prior,
          'deleted': true,
          'revision': math.max(
            (prior['revision']! as int) + 1,
            row['revision']! as int,
          ),
          'updated': row['updated'],
          'operation': row['operation'],
        };
        result[i] = removed;
        byId[prior['id']! as String] = removed;
      }
    }
    if (row['deleted'] != true &&
        result.any((Json item) => sameContent(item, row))) {
      continue;
    }
    result.add(row);
    byId[id] = row;
  }
  return notebook.restore(result, book);
}

List<Json> _mergeManual(List<Json> local, List<Json> incoming, Json book) {
  final List<Json> result = <Json>[...local];
  final Map<String, Json> byId = <String, Json>{
    for (final Json row in local) row['id']! as String: row,
  };
  for (final Json row in incoming) {
    final String id = row['id']! as String;
    final Json? old = byId[id];
    if (old != null) {
      if (!_same(old, row)) {
        throw const ValueError('已有这本书的不同资料：同一手动人物资料在两端有不同修改，未覆盖；请先分别导出备份');
      }
      continue;
    }
    result.add(row);
    byId[id] = row;
  }
  return manual_entities.manualRestore(result, book);
}

Directory? _sameBookOnDisk(
  Library lib,
  Json book, {
  required String preferredId,
  required String canonicalId,
}) {
  if (!lib.booksDir.existsSync()) return null;
  final Set<String> checked = <String>{};
  for (final String id in <String>[preferredId, canonicalId]) {
    if (!checked.add(id)) continue;
    final Directory direct = Directory('${lib.booksDir.path}/$id');
    if (FileSystemEntity.isLinkSync(direct.path)) {
      throw const ValueError('书籍目录是链接，未执行跨端合并');
    }
    final File directBook = File('${direct.path}/book.json');
    if (FileSystemEntity.isLinkSync(directBook.path)) {
      throw const ValueError('书籍正文是链接，未执行跨端合并');
    }
    final Object? existing = _strictRead(directBook);
    if (existing is Json && _sameText(existing, book)) return direct;
  }
  Directory? found;
  for (final FileSystemEntity entity in lib.booksDir.listSync(
    followLinks: false,
  )) {
    if (entity is! Directory || entity.uri.pathSegments.last.startsWith('.')) {
      continue;
    }
    final String id = entity.uri.pathSegments
        .where((String p) => p.isNotEmpty)
        .last;
    if (checked.contains(id)) continue;
    final BookEntry? shelf = lib.byId(id);
    if (shelf != null && shelf.length != book['len']) continue;
    final File source = File('${entity.path}/book.json');
    if (FileSystemEntity.isLinkSync(source.path)) continue;
    final Object? existing = _strictRead(source);
    if (existing is Json && _sameText(existing, book)) {
      if (found != null) throw const ValueError('本地有多份相同正文，请先整理重复书籍再同步');
      found = entity;
    }
  }
  return found;
}

void _backupBeforeMerge(Library lib, Directory dest, String id) {
  final BookEntry entry =
      lib.byId(id) ??
      BookEntry(
        id: id,
        dir: dest,
        meta: <String, Object?>{},
        status: ProcessStatus(<String, Object?>{}),
        added: 0,
      );
  final Uint8List backup = exportBookBytes(lib, entry);
  final Directory folder = Directory('${lib.root.path}/sync-backups')
    ..createSync(recursive: true);
  final File file = File(
    '${folder.path}/$id-${DateTime.now().toUtc().microsecondsSinceEpoch}.yedu.json',
  );
  file.writeAsBytesSync(backup, flush: true);
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
  if (File('${b.dir.path}/$_mergeMarkerName').existsSync()) {
    throw const ValueError('上次跨端合并未完成，请先恢复书库再导出');
  }
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
  notebook.restore(out['notebook'], book);
  manual_entities.manualRestore(out['manual_entities'], book);
  final Json? transfer = _webTransfer(b.dir);
  out['web_state'] = _webStateForExport(
    b.dir,
    book,
    lib.progressOf(b.id),
    (out['notebook']! as List<Object?>).cast<Json>(),
  );
  if (transfer?['preparation'] != null) {
    out['web_preparation'] = _validatedWebPreparation(transfer!['preparation']);
  }
  if (!_same(before, _snapshot(b.dir))) {
    throw const ValueError('这本书正在更新，请稍后重新导出');
  }
  return utf8.encode(PyJson.encode(out, ensureAscii: false));
}

/// Restore the files from an interrupted same-book merge before the shelf scan.
/// The marker remains until every rollback write succeeds, so another crash is
/// recoverable on the next launch. Local snapshots in sync-backups are retained.
int recoverPendingBackupMerges(Directory root) {
  final Directory books = Directory('${root.path}/books');
  if (!books.existsSync()) return 0;
  int recovered = 0;
  for (final FileSystemEntity entity in books.listSync(followLinks: false)) {
    if (entity is! Directory) continue;
    final File marker = File('${entity.path}/$_mergeMarkerName');
    if (!marker.existsSync()) continue;
    final Object? raw = _strictRead(marker);
    if (raw is! Json) throw const ValueError('跨端合并恢复记录损坏，请先保留书库并手动恢复');
    final String id = entity.uri.pathSegments
        .where((String p) => p.isNotEmpty)
        .last;
    if (raw['id'] != id) throw const ValueError('跨端合并恢复记录编号不符，请手动恢复');
    final Json book = storage.validateBook(
      raw['book'] ?? _strictRead(File('${entity.path}/book.json')),
    );
    final List<Json> personal = notebook.restore(raw['notebook'], book);
    final List<Json> manual = manual_entities.manualRestore(
      raw['manual_entities'],
      book,
    );
    final Object? transfer = raw['web_transfer'];
    if (transfer != null && transfer is! Json) {
      throw const ValueError('跨端合并恢复记录内容无效，请手动恢复');
    }
    final bool hasKnowledge =
        raw.containsKey('kg') ||
        raw.containsKey('status') ||
        raw.containsKey('mentions');
    Json? graph;
    Json? status;
    Json? mentions;
    if (hasKnowledge) {
      if (raw['kg'] is! Json ||
          raw['status'] is! Json ||
          raw['mentions'] is! Json) {
        throw const ValueError('跨端合并恢复记录缺少人物资料，请手动恢复');
      }
      graph = storage.validateGraph(raw['kg'], book['len']! as int);
      status = raw['status']! as Json;
      storage.integer(
        status['frontier'] ?? 0,
        '原整理进度',
        high: book['len']! as int,
      );
      mentions = raw['mentions']! as Json;
    }
    final Object? progress = raw['progress'];
    if (progress != null) {
      final Json record = _object(progress, '原阅读进度');
      final int position = storage.integer(
        record['pos'],
        '原阅读进度',
        high: book['len']! as int,
      );
      storage.integer(
        record['cutoff'],
        '原已读范围',
        low: position,
        high: book['len']! as int,
      );
    }
    if (raw['book'] != null) {
      writeJson(File('${entity.path}/book.json'), book);
    }
    writeJson(File('${entity.path}/notebook.json'), personal);
    writeJson(File('${entity.path}/manual-entities.json'), manual);
    final File transferFile = File('${entity.path}/$_webTransferName');
    if (transfer == null) {
      if (transferFile.existsSync()) transferFile.deleteSync();
    } else {
      writeJson(transferFile, transfer);
    }
    if (hasKnowledge) {
      writeJson(File('${entity.path}/kg.json'), graph);
      writeJson(File('${entity.path}/status.json'), status);
      _writeMentions(entity, mentions!);
    }
    final File progressFile = File('${root.path}/progress.json');
    final Object? current = _strictRead(
      progressFile,
      missing: <String, Object?>{},
    );
    final Json all = _object(current, '阅读进度表');
    if (progress == null) {
      all.remove(id);
    } else {
      all[id] = progress;
    }
    writeJson(progressFile, all);
    marker.deleteSync();
    recovered++;
  }
  return recovered;
}

/// Import validates before publication. New books use an atomic directory
/// rename; same-book merges retain a rollback marker until all writes finish.
ImportResult restoreBackup(Library lib, String name, Uint8List raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(raw));
  } on FormatException catch (e) {
    return ImportResult(name: name, error: '这个文件不是导出的书：${e.message}');
  }
  if (decoded is! Json) return ImportResult(name: name, error: '导出文件必须是书籍对象');
  if (decoded['format'] != 'yedu-book/1' &&
      decoded['format'] != exportFormat &&
      decoded['format'] != webExportFormat) {
    return ImportResult(name: name, error: '认不出的格式：${decoded['format']}');
  }
  try {
    final bool fromWeb = decoded['format'] == webExportFormat;
    if (fromWeb && raw.length > 144 * 1024 * 1024) {
      throw const ValueError('网页版备份超过 144 MB，未导入');
    }
    final Json data = fromWeb ? _webAsNative(decoded) : decoded;
    final Json book = storage.validateBook(data['book']);
    final Json graph = storage.validateGraph(
      data['kg'] ?? <String, Object?>{'log': <Object?>[]},
      book['len']! as int,
    );
    List<Json> personal = notebook.restore(
      data['notebook'] ?? <Object?>[],
      book,
    );
    final List<Json> manual = manual_entities.manualRestore(
      data['manual_entities'] ?? <Object?>[],
      book,
    );
    final Json? webState = data['web_state'] == null
        ? null
        : _validatedWebState(data['web_state'], book);
    final Json? webPreparation = _validatedWebPreparation(
      data['web_preparation'],
    );
    if (fromWeb && webState != null) {
      final List<Json> additions = decoded['native_backup'] is Json
          ? _newWebNotebook(webState, book, personal)
          : _webNotebook(webState, book);
      personal = _mergePersonal(personal, additions, book);
    }
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
    double sourceTime = 0;
    if (progress != null) {
      final Json value = _object(progress, '阅读进度');
      pos = storage.integer(value['pos'], '阅读进度', high: book['len']! as int);
      cutoff = storage.integer(
        value['cutoff'] ?? pos,
        '已读范围',
        low: pos,
        high: book['len']! as int,
      );
      if (value['t'] is num) {
        sourceTime = (value['t']! as num).toDouble();
        if (!sourceTime.isFinite ||
            sourceTime < 0 ||
            sourceTime > 1000000000000) {
          throw const ValueError('阅读时间无效');
        }
      }
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
    final String canonicalId = crypto.sha1
        .convert(
          utf8.encode(PyJson.encode(book, ensureAscii: false, sortKeys: true)),
        )
        .toString()
        .substring(0, 16);
    final String offeredId = '${data['id'] ?? ''}';
    final String freshId = RegExp(r'^[0-9a-f]{16}$').hasMatch(offeredId)
        ? offeredId
        : canonicalId;
    final Directory? matching = _sameBookOnDisk(
      lib,
      book,
      preferredId: freshId,
      canonicalId: canonicalId,
    );
    final String id = matching == null
        ? freshId
        : matching.uri.pathSegments
              .where((String part) => part.isNotEmpty)
              .last;
    final Directory dest = Directory('${lib.booksDir.path}/$id');
    if (File('${dest.path}/book.json').existsSync()) {
      final Object? rawStatus = _strictRead(
        File('${dest.path}/status.json'),
        missing: <String, Object?>{},
      );
      final Json liveStatus = _object(rawStatus, '本地整理状态');
      if (const <String>{
        'queued',
        'running',
        'finalizing',
        'cancelling',
      }.contains(liveStatus['state'])) {
        return ImportResult(name: name, error: '这本书正在整理。请先暂停整理，再导入另一台设备的备份。');
      }
      final Json currentBook = storage.validateBook(
        _strictRead(File('${dest.path}/book.json')),
      );
      if (!_sameText(currentBook, book)) {
        return ImportResult(name: name, error: '同一书籍编号对应不同正文，未覆盖');
      }
      final Json mergedBook;
      try {
        mergedBook = verdicts.mergeChapterVerdicts(
          currentBook,
          book,
          localCheckPending: verdicts.titleCheckPending(liveStatus),
          incomingCheckPending: verdicts.titleCheckPending(sourceStatus),
        );
      } on verdicts.ChapterVerdictConflict {
        return ImportResult(name: name, error: '两端对章节标题的剧透判断不同，未覆盖；请分别导出备份后处理');
      }
      final Json currentGraph = storage.validateGraph(
        _strictRead(
          File('${dest.path}/kg.json'),
          missing: <String, Object?>{'log': <Object?>[]},
        ),
        book['len']! as int,
      );
      final bool webWithoutNative = fromWeb && decoded['native_backup'] == null;
      final bool graphSame = _same(currentGraph, graph);
      final bool graphForward =
          !webWithoutNative && !graphSame && _graphExtends(currentGraph, graph);
      final bool graphStale =
          !webWithoutNative && !graphSame && _graphExtends(graph, currentGraph);
      if (!webWithoutNative && !graphSame && !graphForward && !graphStale) {
        return ImportResult(
          name: name,
          error: '已有这本书的不同资料：两端人物图谱分叉，未覆盖本地图谱；请分别导出备份后处理冲突',
        );
      }
      final Json currentMentions = _mentions(dest);
      final bool mentionsSame = _same(
        _normalizedMentions(currentMentions),
        _normalizedMentions(mentions),
      );
      final bool mentionsForward =
          !webWithoutNative &&
          !mentionsSame &&
          _mentionsExtend(currentMentions, mentions);
      final bool mentionsStale =
          !webWithoutNative &&
          !mentionsSame &&
          _mentionsExtend(mentions, currentMentions);
      if (!webWithoutNative &&
          ((!mentionsSame && !mentionsForward && !mentionsStale) ||
              (graphForward && mentionsStale) ||
              (graphStale && mentionsForward))) {
        return ImportResult(
          name: name,
          error: '已有这本书的不同资料：两端人物索引分叉，未覆盖本地资料；请分别导出备份',
        );
      }
      final int currentFrontier = storage.integer(
        liveStatus['frontier'] ?? 0,
        '本地整理进度',
        high: book['len']! as int,
      );
      final int incomingFrontier = storage.integer(
        sourceStatus['frontier'] ?? 0,
        '整理进度',
        high: book['len']! as int,
      );
      if (!webWithoutNative &&
          ((graphForward || mentionsForward) &&
                  incomingFrontier < currentFrontier ||
              (graphStale || mentionsStale) &&
                  incomingFrontier > currentFrontier)) {
        return ImportResult(
          name: name,
          error: '两端整理进度与人物资料不一致，未覆盖本地资料；请分别导出备份',
        );
      }
      final Json importedStatus = <String, Object?>{...sourceStatus};
      if (importedStatus['state'] != 'done') {
        importedStatus
          ..['state'] = 'paused'
          ..['error'] = null
          ..['updated'] = DateTime.now().millisecondsSinceEpoch / 1000;
      }
      final bool takeIncomingStatus =
          !webWithoutNative &&
          (incomingFrontier > currentFrontier ||
              ((graphForward || mentionsForward) &&
                  liveStatus['state'] != 'done') ||
              (importedStatus['state'] == 'done' &&
                  liveStatus['state'] != 'done' &&
                  incomingFrontier == currentFrontier));
      final Json nextStatus = <String, Object?>{
        ...(takeIncomingStatus ? importedStatus : liveStatus),
      };
      final Object? qualityRaw = nextStatus['quality'];
      if (qualityRaw is Json &&
          (mergedBook['chapters']! as List<Object?>).every(
            (Object? row) =>
                row is Json &&
                row['spoil'] is bool &&
                row['spoilSource'] == 'model',
          )) {
        final Object? pendingRaw = qualityRaw['pending'];
        if (pendingRaw is List<Object?> &&
            pendingRaw.contains('chapter-titles')) {
          final List<Object?> remaining = pendingRaw
              .where((Object? item) => item != 'chapter-titles')
              .toList();
          nextStatus['quality'] = <String, Object?>{
            ...qualityRaw,
            'pending': remaining,
            'state': remaining.isEmpty ? 'verified' : 'pending',
          };
        }
      }
      for (final MapEntry<String, Uint8List> entry in assets.entries) {
        final File image = File('${dest.path}/img/${entry.key}');
        if (!image.existsSync() ||
            FileSystemEntity.isLinkSync(image.path) ||
            !_same(image.readAsBytesSync(), entry.value)) {
          return ImportResult(name: name, error: '两端书籍图片不同，未覆盖本地资料');
        }
      }
      final List<Json> currentPersonal = notebook.restore(
        _strictRead(File('${dest.path}/notebook.json'), missing: <Object?>[]),
        currentBook,
      );
      final List<Json> currentManual = manual_entities.manualRestore(
        _strictRead(
          File('${dest.path}/manual-entities.json'),
          missing: <Object?>[],
        ),
        currentBook,
      );
      final List<Json> mergedPersonal = _mergePersonal(
        currentPersonal,
        personal,
        currentBook,
      );
      final List<Json> mergedManual = _mergeManual(
        currentManual,
        manual,
        currentBook,
      );
      final Json? oldTransfer = _webTransfer(dest);
      final Json? mergedPreparation = _mergePreparation(
        _validatedWebPreparation(oldTransfer?['preparation']),
        webPreparation,
      );
      final Progress? currentProgress = lib.progressOf(id);
      final int oldCutoff = currentProgress?.cutoff ?? 0;
      final int mergedCutoff = math.max(oldCutoff, cutoff ?? 0);
      final bool takeIncomingPosition =
          pos != null &&
          (currentProgress == null ||
              sourceTime > currentProgress.t ||
              (sourceTime == currentProgress.t && pos > currentProgress.pos));
      final int mergedPos = takeIncomingPosition
          ? pos
          : currentProgress?.pos ?? pos ?? 0;
      final double mergedTime = takeIncomingPosition
          ? sourceTime
          : currentProgress?.t ?? sourceTime;
      final int validCutoff = math.max(mergedPos, mergedCutoff);
      final bool notesChanged = !_same(currentPersonal, mergedPersonal);
      final bool bookChanged = !_same(currentBook, mergedBook);
      final bool manualChanged = !_same(currentManual, mergedManual);
      final bool graphChanged = graphForward;
      final bool mentionsChanged = mentionsForward;
      final bool statusChanged = !_same(liveStatus, nextStatus);
      final bool progressChanged = currentProgress == null
          ? pos != null
          : mergedPos != currentProgress.pos ||
                validCutoff != currentProgress.cutoff ||
                mergedTime != currentProgress.t;
      final Json? chosenState = webState ?? oldTransfer?['state'] as Json?;
      final Object? mappedPos = webState == null
          ? (oldTransfer == null ? null : oldTransfer['mapped_pos'])
          : _chapterOffset(
              book,
              webState['chapter']! as int,
              webState['fraction']! as double,
            );
      final Object? notebookDigest = webState == null
          ? (oldTransfer == null ? null : oldTransfer['notebook_digest'])
          : _digest(_webNotebook(webState, book));
      final Json? nextTransfer =
          chosenState == null && mergedPreparation == null
          ? null
          : <String, Object?>{
              'state': ?chosenState,
              'preparation': ?mergedPreparation,
              'mapped_pos': mappedPos,
              'notebook_digest': notebookDigest,
            };
      final bool transferChanged =
          nextTransfer != null && !_same(oldTransfer, nextTransfer);
      if (bookChanged ||
          notesChanged ||
          manualChanged ||
          progressChanged ||
          transferChanged ||
          graphChanged ||
          mentionsChanged ||
          statusChanged) {
        _backupBeforeMerge(lib, dest, id);
        final File marker = File('${dest.path}/$_mergeMarkerName');
        if (marker.existsSync()) {
          throw const ValueError('上次跨端合并未恢复，已停止写入');
        }
        writeJson(marker, <String, Object?>{
          'id': id,
          'book': currentBook,
          'notebook': currentPersonal,
          'manual_entities': currentManual,
          'web_transfer': oldTransfer,
          'progress': currentProgress?.toJson(),
          'kg': currentGraph,
          'status': liveStatus,
          'mentions': currentMentions,
        });
        try {
          if (bookChanged) {
            writeJson(File('${dest.path}/book.json'), mergedBook);
          }
          if (graphChanged) {
            writeJson(File('${dest.path}/kg.json'), graph);
          }
          if (mentionsChanged) {
            _writeMentions(dest, mentions);
          }
          if (statusChanged) {
            writeJson(File('${dest.path}/status.json'), nextStatus);
          }
          if (notesChanged) {
            writeJson(File('${dest.path}/notebook.json'), mergedPersonal);
          }
          if (manualChanged) {
            writeJson(File('${dest.path}/manual-entities.json'), mergedManual);
          }
          if (transferChanged) {
            writeJson(File('${dest.path}/$_webTransferName'), nextTransfer);
          }
          if (progressChanged) {
            lib.saveProgress(
              id,
              mergedPos,
              validCutoff,
              book['len']! as int,
              timestamp: mergedTime,
            );
          }
          marker.deleteSync();
        } on Object {
          recoverPendingBackupMerges(lib.root);
          if (currentProgress == null) {
            lib.progress.remove(id);
          } else {
            lib.progress[id] = currentProgress;
          }
          rethrow;
        }
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
        if (webState != null || webPreparation != null)
          'web-transfer': <String, Object?>{
            'state': ?webState,
            'preparation': ?webPreparation,
            'mapped_pos': pos,
            'notebook_digest': webState == null
                ? _digest(personal)
                : _digest(_webNotebook(webState, book)),
          },
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
      try {
        lib.saveProgress(
          id,
          pos,
          cutoff,
          book['len']! as int,
          timestamp: sourceTime,
        );
      } on Object {
        // saveProgress mutates its in-memory index before the atomic file
        // write. Revert both publications when that write fails, so a retry
        // cannot mistake a partial first import for a completed restore.
        lib.progress.remove(id);
        if (dest.existsSync()) dest.deleteSync(recursive: true);
        rethrow;
      }
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
