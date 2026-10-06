/// Pure, source-bound reader customization codecs shared by native and Web.
/// Validation never writes files, alters books, or publishes partial results.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:thusfar_core/thusfar_core.dart' show Json;

import '../reader/text_purification.dart';

const int readerPurificationByteLimit = 512 * 1024;
const int readerDirectoryByteLimit = 4 * 1024 * 1024;
const int readerLibraryBookLimit = 10000;
const int _headingLimit = 10000;
const int _titleLimit = 120;
const Set<String> _directoryRules = <String>{
  'automatic',
  'chinese',
  'volumes',
  'english',
  'numbered',
  'prefix',
};
const Set<String> _ruleFields = <String>{
  'id',
  'find',
  'replacement',
  'enabled',
  'bookId',
};

Never _invalid([String detail = '']) => throw FormatException(
  '阅读自定义数据无效${detail.isEmpty ? '' : '：$detail'}，现有设置未更改。',
);

bool _identifier(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= 128 &&
    validUtf16(value) &&
    !value.contains(RegExp(r'[\x00-\x1f\x7f]'));

bool _fields(
  Json value,
  Set<String> required, [
  Set<String> optional = const {},
]) =>
    required.every(value.containsKey) &&
    value.keys.every(
      (String key) => required.contains(key) || optional.contains(key),
    );

void _version(Json value) {
  if (value['version'] is! int || value['version'] != 1) _invalid('版本');
}

Object? _canonical(Object? value, [int depth = 0]) {
  if (depth > 64) _invalid('嵌套过深');
  if (value is Json) {
    final List<String> keys = value.keys.toList()..sort();
    return <String, Object?>{
      for (final String key in keys) key: _canonical(value[key], depth + 1),
    };
  }
  if (value is List<Object?>) {
    return value.map((Object? item) => _canonical(item, depth + 1)).toList();
  }
  if (value == null || value is bool || value is int) return value;
  if (value is double && value.isFinite) return value;
  if (value is String && validUtf16(value)) return value;
  _invalid('非 JSON 数据');
}

/// A deterministic immutable source identity. Chapter spoiler verdicts are
/// generated later and deliberately cannot invalidate reader customizations.
/// Object-key order and mutable display metadata do not affect the identity.
String readerCustomizationSource(Json book) {
  _sourceBook(book);
  final List<Json> chapters = <Json>[
    for (final Object? row in book['chapters']! as List<Object?>)
      <String, Object?>{
        for (final MapEntry<String, Object?> field in (row! as Json).entries)
          if (field.key != 'spoil' && field.key != 'spoilSource')
            field.key: field.value,
      },
  ];
  return crypto.sha256
      .convert(
        utf8.encode(
          jsonEncode(
            _canonical(<String, Object?>{
              'len': book['len'],
              'blocks': book['blocks'],
              'chapters': chapters,
              'notes': book['notes'] ?? <String, Object?>{},
            }),
          ),
        ),
      )
      .toString();
}

/// The outer book importer also validates its full schema. These source checks
/// keep this standalone codec safe without importing native storage/IO code.
void _sourceBook(Json book) {
  final Object? length = book['len'];
  final Object? blocks = book['blocks'];
  final Object? chapters = book['chapters'];
  if (length is! int ||
      length < 0 ||
      length > 120000000 ||
      blocks is! List<Object?> ||
      blocks.isEmpty ||
      blocks.length > 1000000 ||
      chapters is! List<Object?> ||
      chapters.isEmpty ||
      chapters.length > 100000) {
    _invalid('原文结构');
  }
  int previous = -1;
  for (final Object? raw in blocks) {
    if (raw is! Json ||
        !const <String>{'p', 'h', 'img'}.contains(raw['k']) ||
        raw['t'] is! String ||
        raw['o'] is! int) {
      _invalid('原文段落');
    }
    final String text = raw['t']! as String;
    final int offset = raw['o']! as int;
    if (!validUtf16(text) ||
        offset < 0 ||
        offset < previous ||
        offset + text.length > length) {
      _invalid('原文位置');
    }
    previous = offset;
  }
  previous = -1;
  for (final Object? raw in chapters) {
    if (raw is! Json ||
        raw['title'] is! String ||
        !validUtf16(raw['title']! as String) ||
        raw['b0'] is! int ||
        raw['b1'] is! int ||
        raw['o0'] is! int ||
        raw['o1'] is! int) {
      _invalid('原始章节');
    }
    final int first = raw['b0']! as int;
    final int last = raw['b1']! as int;
    final int start = raw['o0']! as int;
    final int end = raw['o1']! as int;
    if (first < 0 ||
        first >= last ||
        last > blocks.length ||
        start < 0 ||
        start < previous ||
        start > end ||
        end > length) {
      _invalid('原始章节位置');
    }
    previous = start;
  }
}

List<PurificationRule> decodeReaderPurificationRules(Object? raw) {
  if (raw is! List<Object?> || raw.length > PurificationRule.maxRules) {
    _invalid('最多保存 64 条规则');
  }
  final List<PurificationRule> result = <PurificationRule>[];
  final Set<String> ids = <String>{};
  for (final Object? row in raw) {
    if (row is! Json ||
        !_fields(row, _ruleFields) ||
        !_identifier(row['id']) ||
        row['find'] is! String ||
        row['replacement'] is! String ||
        row['enabled'] is! bool ||
        (row['bookId'] != null && !_identifier(row['bookId']))) {
      _invalid('净化规则');
    }
    final PurificationRule rule = PurificationRule(
      id: row['id']! as String,
      find: row['find']! as String,
      replacement: row['replacement']! as String,
      enabled: row['enabled']! as bool,
      bookId: row['bookId'] as String?,
    );
    if (rule.error != null || !ids.add(rule.id)) _invalid('净化规则或重复标识');
    result.add(rule);
  }
  if (utf8.encode(jsonEncode(raw)).length > readerPurificationByteLimit) {
    _invalid('净化规则超过 512 KB');
  }
  return List<PurificationRule>.unmodifiable(result);
}

List<Json> encodeReaderPurificationRules(Iterable<PurificationRule> rules) {
  final List<Json> rows = <Json>[];
  for (final PurificationRule rule in rules) {
    if (rows.length >= PurificationRule.maxRules) _invalid('最多保存 64 条规则');
    rows.add(<String, Object?>{
      'id': rule.id,
      'find': rule.find,
      'replacement': rule.replacement,
      'enabled': rule.enabled,
      'bookId': rule.bookId,
    });
  }
  decodeReaderPurificationRules(rows);
  return rows;
}

String _semantics(PurificationRule rule) =>
    jsonEncode(<Object?>[rule.find, rule.replacement, rule.bookId]);

/// Preserve every local rule and its order/enabled preference. Identical IDs
/// with different text or scope conflict, even if another rule is a duplicate.
/// Incoming-only IDs retain their source order/enabled states, including
/// semantic duplicates; repeat imports remain idempotent.
List<PurificationRule> mergeReaderPurificationRules(
  List<PurificationRule> local,
  List<PurificationRule> incoming,
) {
  encodeReaderPurificationRules(local);
  encodeReaderPurificationRules(incoming);
  final Map<String, String> identities = <String, String>{
    for (final PurificationRule rule in local) rule.id: _semantics(rule),
  };
  final Set<String> seen = identities.values.toSet();
  final List<PurificationRule> result = <PurificationRule>[...local];
  for (final PurificationRule rule in incoming) {
    final String signature = _semantics(rule);
    if (identities.containsKey(rule.id) && identities[rule.id] != signature) {
      _invalid('同一净化规则已在两端修改');
    }
    identities[rule.id] = signature;
    // Only pre-existing local semantics take precedence. Distinct incoming
    // IDs can deliberately differ in enabled state; collapsing them changes
    // appearance on a fresh restore (for example disabled-first/enabled-next).
    if (!seen.contains(signature)) result.add(rule);
  }
  encodeReaderPurificationRules(result);
  return List<PurificationRule>.unmodifiable(result);
}

bool _confirmedTxt(Json meta, bool hasSourceTxt, bool hasSourceEpub) {
  if (hasSourceEpub) return false;
  final Object? name = meta['filename'];
  if (name is String && name.isNotEmpty) {
    return name.toLowerCase().endsWith('.txt');
  }
  return hasSourceTxt;
}

/// Validate both enabled and disabled sidecars. A reset's minimal disabled
/// sidecar remains minimal; a disabled sidecar with rows retains all its rows.
Json? validatedReaderDirectory(
  Object? raw, {
  required Json book,
  required String bookId,
  String? destinationBookId,
  required Json meta,
  bool hasSourceTxt = false,
  bool hasSourceEpub = false,
}) {
  if (raw == null) return null;
  _sourceBook(book);
  final String destination = destinationBookId ?? bookId;
  if (!_identifier(bookId) ||
      !_identifier(destination) ||
      raw is! Json ||
      !_fields(
        raw,
        const <String>{'version', 'bookId', 'length', 'enabled'},
        const <String>{'rule', 'prefix', 'rows'},
      ) ||
      raw['bookId'] != bookId ||
      raw['length'] is! int ||
      raw['length'] != book['len'] ||
      raw['enabled'] is! bool ||
      !_confirmedTxt(meta, hasSourceTxt, hasSourceEpub)) {
    _invalid('目录来源');
  }
  _version(raw);
  final bool hasRows =
      raw.containsKey('rows') ||
      raw.containsKey('rule') ||
      raw.containsKey('prefix');
  if (raw['enabled'] == true || hasRows) {
    final Object? prefix = raw['prefix'];
    final Object? rows = raw['rows'];
    if (!_directoryRules.contains(raw['rule']) ||
        prefix is! String ||
        !validUtf16(prefix) ||
        prefix.length > 32 ||
        prefix.contains('\n') ||
        prefix.contains('\r') ||
        (raw['rule'] == 'prefix' && prefix.trim().isEmpty) ||
        rows is! List<Object?> ||
        rows.isEmpty ||
        rows.length > _headingLimit) {
      _invalid('目录规则');
    }
    final List<Object?> blocks = book['blocks']! as List<Object?>;
    int previous = -1;
    for (final Object? row in rows) {
      if (row is! Json ||
          !_fields(row, const <String>{'title', 'offset'}) ||
          row['title'] is! String ||
          row['offset'] is! int) {
        _invalid('目录行');
      }
      final String title = row['title']! as String;
      final int offset = row['offset']! as int;
      if (title.isEmpty ||
          title.length > _titleLimit ||
          !validUtf16(title) ||
          offset <= previous ||
          offset < 0 ||
          offset + title.length > (book['len']! as int)) {
        _invalid('目录位置');
      }
      // Exactly the reader's blockAt lookup, including equal-offset blocks.
      int lo = 0;
      int hi = blocks.length - 1;
      while (lo < hi) {
        final int mid = (lo + hi + 1) ~/ 2;
        if (((blocks[mid]! as Json)['o']! as int) <= offset) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      final Json block = blocks[lo]! as Json;
      final String text = block['t']! as String;
      final int relative = offset - (block['o']! as int);
      if ((block['k'] != 'p' && block['k'] != 'h') ||
          text.length > _titleLimit ||
          text.trim() != title ||
          relative != text.indexOf(title) ||
          relative < 0 ||
          relative + title.length > text.length ||
          text.substring(relative, relative + title.length) != title) {
        _invalid('目录与原文不符');
      }
      previous = offset;
    }
  }
  final Json result = <String, Object?>{
    ...(_canonical(raw)! as Json),
    'bookId': destination,
  };
  // This schema contains only strings, integers, booleans and lists/maps.
  // Dart's compact UTF-8 JSON matches native sidecar byte escaping, without
  // invoking PyJson's native collection-type checks on JavaScript maps.
  if (utf8.encode(jsonEncode(result)).length > readerDirectoryByteLimit) {
    _invalid('目录数据超过 4 MB');
  }
  return result;
}

Json? validatedReaderCustomizations(
  Object? raw, {
  required Json book,
  required String bookId,
  String? destinationBookId,
  required Json meta,
  bool hasSourceTxt = false,
  bool hasSourceEpub = false,
}) {
  if (raw == null) return null; // Older exports made no customization claim.
  final String destination = destinationBookId ?? bookId;
  if (!_identifier(bookId) ||
      !_identifier(destination) ||
      raw is! Json ||
      !_fields(
        raw,
        const <String>{
          'version',
          'bookId',
          'source',
          'purification',
          'directory',
        },
        const <String>{'globalRulesOmitted'},
      ) ||
      raw['bookId'] != bookId ||
      raw['source'] != readerCustomizationSource(book)) {
    _invalid('原文标识');
  }
  _version(raw);
  if (raw.containsKey('globalRulesOmitted') &&
      (raw['globalRulesOmitted'] is! int ||
          (raw['globalRulesOmitted']! as int) < 0 ||
          (raw['globalRulesOmitted']! as int) > PurificationRule.maxRules)) {
    _invalid('全局规则计数');
  }
  final List<PurificationRule> rules = decodeReaderPurificationRules(
    raw['purification'],
  );
  if (rules.any((PurificationRule rule) => rule.bookId != bookId)) {
    _invalid('单本书不能携带全局或其他书籍规则');
  }
  final Json? directory = validatedReaderDirectory(
    raw['directory'],
    book: book,
    bookId: bookId,
    destinationBookId: destination,
    meta: meta,
    hasSourceTxt: hasSourceTxt,
    hasSourceEpub: hasSourceEpub,
  );
  return <String, Object?>{
    'version': 1,
    'bookId': destination,
    'source': raw['source'],
    'purification': encodeReaderPurificationRules(
      rules.map(
        (PurificationRule rule) => PurificationRule(
          id: rule.id,
          find: rule.find,
          replacement: rule.replacement,
          enabled: rule.enabled,
          bookId: destination,
        ),
      ),
    ),
    'directory': directory,
    if (raw.containsKey('globalRulesOmitted'))
      'globalRulesOmitted': raw['globalRulesOmitted'],
  };
}

Json exportReaderCustomizations({
  required Json book,
  required String bookId,
  required List<PurificationRule> rules,
  Object? directory,
  required Json meta,
  bool hasSourceTxt = false,
  bool hasSourceEpub = false,
}) {
  encodeReaderPurificationRules(rules); // Never hide a corrupt root store.
  return validatedReaderCustomizations(
    <String, Object?>{
      'version': 1,
      'bookId': bookId,
      'source': readerCustomizationSource(book),
      'purification': encodeReaderPurificationRules(
        rules.where((PurificationRule rule) => rule.bookId == bookId),
      ),
      'directory': directory,
      'globalRulesOmitted': rules
          .where((PurificationRule rule) => rule.bookId == null)
          .length,
    },
    book: book,
    bookId: bookId,
    meta: meta,
    hasSourceTxt: hasSourceTxt,
    hasSourceEpub: hasSourceEpub,
  )!;
}

/// Every archived native book ID must match its verified immutable fingerprint
/// in [sources]; extra source records are allowed. Before remapping, the
/// coordinator must verify each destination has that same fingerprint.
Json validatedReaderLibrary(
  Object? raw, {
  required Map<String, String> sources,
  Map<String, String> destinationBookIds = const <String, String>{},
}) {
  if (raw is! Json ||
      !_fields(raw, const <String>{
        'format',
        'version',
        'books',
        'purification',
      }) ||
      raw['format'] != 'thusfar-reader-library' ||
      raw['books'] is! List<Object?> ||
      sources.length > readerLibraryBookLimit ||
      destinationBookIds.keys.any((String id) => !sources.containsKey(id))) {
    _invalid('完整书库格式');
  }
  _version(raw);
  final List<Object?> books = raw['books']! as List<Object?>;
  if (books.length > readerLibraryBookLimit) _invalid('完整书库原文列表');
  final Set<String> seen = <String>{};
  final Set<String> destinations = <String>{};
  final List<Json> validatedBooks = <Json>[];
  for (final Object? row in books) {
    if (row is! Json ||
        !_fields(row, const <String>{'bookId', 'source'}) ||
        !_identifier(row['bookId']) ||
        row['source'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(row['source']! as String)) {
      _invalid('完整书库原文标识');
    }
    final String id = row['bookId']! as String;
    final String destination = destinationBookIds[id] ?? id;
    if (!seen.add(id) ||
        sources[id] != row['source'] ||
        !_identifier(destination) ||
        !destinations.add(destination)) {
      _invalid('完整书库原文不符或目标重复');
    }
    validatedBooks.add(<String, Object?>{
      'bookId': destination,
      'source': row['source'],
    });
  }
  final List<PurificationRule> rules = decodeReaderPurificationRules(
    raw['purification'],
  );
  if (rules.any(
    (PurificationRule rule) =>
        rule.bookId != null && !seen.contains(rule.bookId),
  )) {
    _invalid('净化规则指向完整书库之外的书籍');
  }
  return <String, Object?>{
    'format': 'thusfar-reader-library',
    'version': 1,
    'books': validatedBooks,
    'purification': encodeReaderPurificationRules(
      rules.map(
        (PurificationRule rule) => PurificationRule(
          id: rule.id,
          find: rule.find,
          replacement: rule.replacement,
          enabled: rule.enabled,
          bookId: destinationBookIds[rule.bookId] ?? rule.bookId,
        ),
      ),
    ),
  };
}
