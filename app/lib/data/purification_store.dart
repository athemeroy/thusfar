import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../reader/text_purification.dart';
import 'library.dart' show Json, writeJson;
import 'reader_customizations.dart';

/// Atomic local storage, separate from immutable books and generated knowledge.
/// A damaged store stays on disk and is never silently replaced with empty data.
class PurificationStore extends ChangeNotifier {
  PurificationStore(this.file) {
    try {
      _rules = readSnapshot(file);
    } on Object {
      error = '净化规则暂时无法读取。原文件已保留，请恢复规则文件后重新打开这本书';
    }
    _loadedStamp = _diskStamp();
  }

  // Covers the worst-case JSON escaping of every valid 64-rule export.
  static const int maxImportBytes = readerPurificationByteLimit;

  /// Strict native snapshots preserve IDs, scope, ordering and disabled rules.
  /// Missing files mean no saved rules; damaged/oversized files must fail.
  static List<PurificationRule> readSnapshot(File file) {
    final FileSystemEntityType type = FileSystemEntity.typeSync(
      file.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.notFound) return <PurificationRule>[];
    if (type != FileSystemEntityType.file) {
      throw const FormatException('规则文件类型无效，现有规则未更改');
    }
    final RandomAccessFile handle = file.openSync();
    try {
      if (handle.lengthSync() > maxImportBytes) {
        throw const FormatException('规则文件过大');
      }
      // Bound actual bytes as well as the advertised size, including a file
      // that grows while a backup or restore is reading it.
      final List<int> bytes = handle.readSync(maxImportBytes + 1);
      if (bytes.length > maxImportBytes) {
        throw const FormatException('规则文件过大');
      }
      return decodeStore(jsonDecode(utf8.decode(bytes, allowMalformed: false)));
    } finally {
      handle.closeSync();
    }
  }

  static List<PurificationRule> decodeStore(Object? raw) {
    if (raw is! Json ||
        raw.length != 3 ||
        !raw.containsKey('rules') ||
        raw['version'] is! int ||
        raw['version'] != 1 ||
        raw['format'] != 'thusfar-purification-store' ||
        utf8.encode(jsonEncode(raw)).length > maxImportBytes) {
      throw const FormatException('规则文件格式无效，现有规则未更改');
    }
    return decodeReaderPurificationRules(raw['rules']);
  }

  static Json encodeStore(List<PurificationRule> rules) {
    final Json result = <String, Object?>{
      'format': 'thusfar-purification-store',
      'version': 1,
      'rules': encodeReaderPurificationRules(rules),
    };
    decodeStore(result);
    return result;
  }

  static List<PurificationRule> mergeRules(
    List<PurificationRule> local,
    List<PurificationRule> incoming,
  ) => mergeReaderPurificationRules(local, incoming);

  String _loadedStamp = '';
  String _diskStamp() {
    final FileStat stat = FileStat.statSync(file.path);
    return '${FileSystemEntity.typeSync(file.path, followLinks: false)}:${stat.size}:${stat.modified.microsecondsSinceEpoch}:${stat.changed.microsecondsSinceEpoch}';
  }

  bool _sameRules(List<PurificationRule> a, List<PurificationRule> b) =>
      jsonEncode(encodeStore(a)) == jsonEncode(encodeStore(b));

  /// Refresh only changed durable data. Progress notifications must not cause
  /// a fresh layout or replace the reader's original-source anchor every page.
  void refresh() {
    if (_loadedStamp == _diskStamp()) return;
    try {
      reload();
    } on Object {
      _loadedStamp = _diskStamp();
      const String message = '净化规则暂时无法读取。原文件已保留，请恢复规则文件后重新打开这本书';
      if (error != message) {
        error = message;
        notifyListeners();
      }
    }
  }

  void reload() {
    final List<PurificationRule> next = readSnapshot(file);
    final bool changed = error != null || !_sameRules(_rules, next);
    _rules = next;
    error = null;
    _loadedStamp = _diskStamp();
    if (changed) notifyListeners();
  }

  static int _sequence = 0;
  static String newRuleId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';

  final File file;
  String? error;
  List<PurificationRule> _rules = <PurificationRule>[];
  List<PurificationRule> get rules =>
      List<PurificationRule>.unmodifiable(_rules);
  List<PurificationRule> forBook(String id) =>
      _rules.where((r) => r.bookId == null || r.bookId == id).toList();

  void _save(List<PurificationRule> next) {
    if (error != null) throw StateError(error!);
    if (next.length > PurificationRule.maxRules) {
      throw const FormatException('最多保存 64 条规则，请先删除不再使用的规则');
    }
    if (next.any((r) => r.error != null)) throw const FormatException('净化规则无效');
    final List<PurificationRule> current = readSnapshot(file);
    if (!_sameRules(current, _rules)) {
      _rules = current;
      _loadedStamp = _diskStamp();
      notifyListeners();
      throw StateError('规则已由恢复或其他页面更新，请检查后重新保存');
    }
    writeJson(file, encodeStore(next));
    _rules = next;
    _loadedStamp = _diskStamp();
    notifyListeners();
  }

  void put(PurificationRule rule) {
    final int index = _rules.indexWhere((r) => r.id == rule.id);
    final List<PurificationRule> next = <PurificationRule>[..._rules];
    if (index < 0) {
      next.add(rule);
    } else {
      next[index] = rule;
    }
    _save(next);
  }

  void remove(String id) => _save(_rules.where((r) => r.id != id).toList());
  void move(String id, int delta, String bookId) {
    final List<PurificationRule> visible = forBook(bookId);
    final int index = visible.indexWhere((r) => r.id == id);
    final int target = index + delta;
    if (index < 0 || target < 0 || target >= visible.length) return;
    final List<PurificationRule> next = <PurificationRule>[..._rules];
    final int a = next.indexOf(visible[index]),
        b = next.indexOf(visible[target]);
    final PurificationRule value = next[a];
    next[a] = next[b];
    next[b] = value;
    _save(next);
  }

  String exportForBook(String id) => const JsonEncoder.withIndent(
    '  ',
  ).convert(_encode(forBook(id), portable: true));

  /// Portable book rules bind to the book the user is importing into. Import
  /// appends rules; it never changes or deletes existing rules, even on failure.
  int importForBook(String data, String bookId) {
    final List<PurificationRule> imported = previewImport(data, bookId);
    if (imported.isNotEmpty) _save(<PurificationRule>[..._rules, ...imported]);
    return imported.length;
  }

  List<PurificationRule> previewImport(String data, String bookId) {
    if (data.length > maxImportBytes ||
        utf8.encode(data).length > maxImportBytes) {
      throw const FormatException('规则文件过大');
    }
    final List<PurificationRule> decoded;
    try {
      decoded = _decode(jsonDecode(data), portable: true, bookId: bookId);
    } on FormatException {
      throw const FormatException('规则文件格式无效，现有规则未更改');
    }
    String signature(PurificationRule rule) => jsonEncode(<Object?>[
      rule.find,
      rule.replacement,
      rule.enabled,
      rule.bookId,
    ]);
    final Set<String> seen = _rules.map(signature).toSet();
    return decoded.where((rule) => seen.add(signature(rule))).toList();
  }

  static Map<String, Object?> _encode(
    List<PurificationRule> rules, {
    required bool portable,
  }) => <String, Object?>{
    'format': portable ? 'thusfar-purification' : 'thusfar-purification-store',
    'version': 1,
    'rules': <Object?>[
      for (final PurificationRule rule in rules)
        <String, Object?>{
          if (!portable) 'id': rule.id,
          'find': rule.find,
          'replacement': rule.replacement,
          'enabled': rule.enabled,
          if (portable)
            'scope': rule.bookId == null ? 'global' : 'book'
          else
            'bookId': rule.bookId,
        },
    ],
  };

  static List<PurificationRule> _decode(
    Object? raw, {
    required bool portable,
    String? bookId,
  }) {
    const FormatException invalid = FormatException('规则文件格式无效，现有规则未更改');
    if (raw is! Map<String, Object?> ||
        raw['version'] != 1 ||
        raw['format'] !=
            (portable
                ? 'thusfar-purification'
                : 'thusfar-purification-store') ||
        raw['rules'] is! List<Object?>) {
      throw invalid;
    }
    final List<Object?> rows = raw['rules']! as List<Object?>;
    if (rows.length > PurificationRule.maxRules) throw invalid;
    final List<PurificationRule> rules = <PurificationRule>[];
    final Set<String> ids = <String>{};
    final String prefix = newRuleId();
    for (final Object? value in rows) {
      if (value is! Map<String, Object?> ||
          value['find'] is! String ||
          value['replacement'] is! String ||
          value['enabled'] is! bool ||
          (portable
              ? !<Object?>['global', 'book'].contains(value['scope'])
              : value['id'] is! String ||
                    (value['bookId'] != null && value['bookId'] is! String))) {
        throw invalid;
      }
      final String id = portable
          ? '$prefix-${rules.length}'
          : value['id']! as String;
      if (id.isEmpty || !ids.add(id)) throw invalid;
      final PurificationRule rule = PurificationRule(
        id: id,
        find: value['find']! as String,
        replacement: value['replacement']! as String,
        enabled: value['enabled']! as bool,
        bookId: portable
            ? (value['scope'] == 'book' ? bookId : null)
            : value['bookId'] as String?,
      );
      if (rule.error != null) throw invalid;
      rules.add(rule);
    }
    return rules;
  }
}

/// Bound memory before reading untrusted picker data. Unknown or stale file
/// sizes still receive the same actual-byte limit, and overflow cancels the
/// stream without appending the oversized chunk to the buffer.
Future<String> readPurificationImport(
  Stream<List<int>> stream, {
  int reportedSize = 0,
}) async {
  if (reportedSize > PurificationStore.maxImportBytes) {
    throw const FormatException('规则文件过大');
  }
  final BytesBuilder bytes = BytesBuilder(copy: false);
  await for (final List<int> chunk in stream) {
    if (chunk.length > PurificationStore.maxImportBytes - bytes.length) {
      throw const FormatException('规则文件过大');
    }
    bytes.add(chunk);
  }
  try {
    return utf8.decode(bytes.takeBytes(), allowMalformed: false);
  } on FormatException {
    throw const FormatException('规则文件不是有效的文字文件');
  }
}
