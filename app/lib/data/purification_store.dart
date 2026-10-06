import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../reader/text_purification.dart';
import 'library.dart' show writeJson;

/// Atomic local storage, separate from immutable books and generated knowledge.
/// A damaged store stays on disk and is never silently replaced with empty data.
class PurificationStore extends ChangeNotifier {
  PurificationStore(this.file) {
    try {
      if (file.existsSync()) {
        if (file.lengthSync() > 512 * 1024) {
          throw const FormatException('规则文件过大');
        }
        _rules = _decode(jsonDecode(file.readAsStringSync()), portable: false);
      }
    } on Object {
      error = '净化规则暂时无法读取。原文件已保留，请恢复规则文件后重新打开这本书';
    }
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
    writeJson(file, _encode(next, portable: false));
    _rules = next;
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
    if (data.length > 128 * 1024) throw const FormatException('规则文件过大');
    final List<PurificationRule> imported = previewImport(data, bookId);
    if (imported.isNotEmpty) _save(<PurificationRule>[..._rules, ...imported]);
    return imported.length;
  }

  List<PurificationRule> previewImport(String data, String bookId) {
    if (data.length > 128 * 1024) throw const FormatException('规则文件过大');
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
