import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:thusfar_core/thusfar_core.dart' show PyJson;

import 'library.dart';

/// Navigation only. Never pass these entries to chapter-indexed AI processing.
class DirectoryChapter extends Chapter {
  DirectoryChapter(
    super.index,
    super.raw, {
    required this.titleEnd,
    this.source,
  });

  final int titleEnd;
  final Chapter? source;
  bool get verifiedSafe =>
      source?.raw['spoilSource'] == 'model' && source?.raw['spoil'] == false;
}

bool tocTitleRead(Chapter chapter, int readTo) => chapter is DirectoryChapter
    ? chapter.titleEnd <= readTo
    : chapter.o0 < readTo;

enum DirectoryRule {
  automatic('常见中英文章节'),
  chinese('中文章回 / 节 / 篇'),
  volumes('中文分卷 / 部 / 集'),
  english('Chapter / Part / Book'),
  numbered('数字开头，如 001 标题'),
  prefix('自定义固定前缀');

  const DirectoryRule(this.label);
  final String label;
}

const int directoryHeadingLimit = 10000;
const int directoryTitleLimit = 120;
const int directorySidecarByteLimit = 4 * 1024 * 1024;

class DirectoryPreview {
  const DirectoryPreview(this.rule, this.prefix, this.rows, this.skippedLong);
  final DirectoryRule rule;
  final String prefix;
  final List<Json> rows;
  final int skippedLong;
}

/// Fixed, short, bounded inputs only; custom input is a literal prefix, never
/// interpreted as a regular expression. Scanning also runs in a killable isolate.
final RegExp _chinese = RegExp(
  r'^第\s{0,4}[0-9零〇一二三四五六七八九十百千万萬两兩壹贰貳叁參肆伍陆陸柒捌玖拾佰仟]{1,16}\s{0,4}[章回节節篇]',
);
final RegExp _volumes = RegExp(
  r'^第\s{0,4}[0-9零〇一二三四五六七八九十百千万萬两兩]{1,16}\s{0,4}[卷部集]',
);
final RegExp _english = RegExp(
  r'^(chapter|part|book)\s{1,4}[0-9ivxlcdm]{1,16}(?:\b|[.:：])',
  caseSensitive: false,
);
final RegExp _numbered = RegExp(r'^[0-9]{1,8}[ .、:：\-]{1,4}\S');

DirectoryPreview detectDirectory(Json book, DirectoryRule rule, String prefix) {
  prefix = rule == DirectoryRule.prefix ? prefix.trim() : '';
  if (rule == DirectoryRule.prefix &&
      (prefix.isEmpty || prefix.length > 32 || prefix.contains('\n'))) {
    throw const FormatException('请输入 1–32 字的固定前缀，不支持正则表达式');
  }
  final List<Json> rows = <Json>[];
  int skipped = 0;
  for (final Object? value in book['blocks']! as List<Object?>) {
    final Json block = value! as Json;
    if (block['k'] != 'p' && block['k'] != 'h') continue;
    final String text = block['t']! as String;
    // TXT import keeps headings as separate source blocks. Never reparse or
    // normalize the book; UTF-16 offsets refer to this existing source text.
    if (text.length > directoryTitleLimit) {
      skipped++;
      continue;
    }
    final String title = text.trim();
    if (title.isEmpty) continue;
    final bool match = switch (rule) {
      DirectoryRule.automatic =>
        _chinese.hasMatch(title) ||
            _volumes.hasMatch(title) ||
            _english.hasMatch(title),
      DirectoryRule.chinese => _chinese.hasMatch(title),
      DirectoryRule.volumes => _volumes.hasMatch(title),
      DirectoryRule.english => _english.hasMatch(title),
      DirectoryRule.numbered => _numbered.hasMatch(title),
      DirectoryRule.prefix => title.startsWith(prefix),
    };
    if (!match) continue;
    if (rows.length >= directoryHeadingLimit) {
      throw const FormatException('匹配超过 10000 项，请缩小规则范围；目录未更改');
    }
    rows.add(<String, Object?>{
      'title': title,
      'offset': (block['o']! as int) + text.indexOf(title),
    });
  }
  return DirectoryPreview(rule, prefix, rows, skipped);
}

void _scanDirectory((SendPort, String, int, String) request) {
  try {
    final File file = File('${request.$2}/book.json');
    if (file.lengthSync() > 256 * 1024 * 1024) {
      throw const FormatException('书籍数据超过 256 MB，暂不能扫描；目录未更改');
    }
    final Json raw = jsonDecode(file.readAsStringSync()) as Json;
    final DirectoryPreview preview = detectDirectory(
      raw,
      DirectoryRule.values[request.$3],
      request.$4,
    );
    request.$1.send(<String, Object?>{
      'rows': preview.rows,
      'skipped': preview.skippedLong,
    });
  } on Object catch (e) {
    request.$1.send(<String, Object?>{'error': '$e'});
  }
}

/// Cancel/close/timeout kills the worker, including a scan still decoding JSON.
class DirectoryScan {
  DirectoryScan(
    String bookDirectory,
    DirectoryRule rule,
    String prefix, {
    Duration timeout = const Duration(seconds: 20),
  }) {
    _port.listen((Object? message) {
      if (_done.isCompleted) return;
      if (message is! Json || message['error'] != null) {
        _finishError(message is Json ? '${message['error']}' : '扫描意外中断，请重试');
        return;
      }
      _done.complete(
        DirectoryPreview(
          rule,
          rule == DirectoryRule.prefix ? prefix.trim() : '',
          (message['rows']! as List<Object?>).cast<Json>(),
          message['skipped']! as int,
        ),
      );
      _stop();
    });
    _timer = Timer(timeout, () => _finishError('扫描超时，已停止；请缩小规则范围后重试'));
    Isolate.spawn(
      _scanDirectory,
      (_port.sendPort, bookDirectory, rule.index, prefix),
      onError: _port.sendPort,
      onExit: _port.sendPort,
    ).then((Isolate isolate) {
      _isolate = isolate;
      if (_done.isCompleted) isolate.kill(priority: Isolate.immediate);
    }, onError: (Object error) => _finishError('无法启动扫描，请重试'));
  }

  final ReceivePort _port = ReceivePort();
  final Completer<DirectoryPreview?> _done = Completer<DirectoryPreview?>();
  Isolate? _isolate;
  Timer? _timer;
  Future<DirectoryPreview?> get result => _done.future;

  void _stop() {
    _timer?.cancel();
    _port.close();
    _isolate?.kill(priority: Isolate.immediate);
  }

  void _finishError(String message) {
    if (_done.isCompleted) return;
    _done.completeError(FormatException(message));
    _stop();
  }

  void cancel() {
    if (_done.isCompleted) return;
    _done.complete(null);
    _stop();
  }
}

final Expando<ReaderDirectory> _directories = Expando<ReaderDirectory>();

extension BookNavigationDirectory on BookData {
  ReaderDirectory get directory => _directories[this] ??= ReaderDirectory(this);
}

/// A local sidecar affects only directory/search navigation. A failed write
/// preserves the previous list; reset never mutates the canonical book file.
class ReaderDirectory extends ChangeNotifier {
  ReaderDirectory(this.book) {
    if (!_file.existsSync()) return;
    try {
      if (_file.lengthSync() > directorySidecarByteLimit) {
        throw const FormatException();
      }
      final Object? value = readJson(_file);
      if (value is! Json ||
          value['version'] != 1 ||
          value['bookId'] != book.id ||
          value['length'] != book.length ||
          value['enabled'] is! bool ||
          !supportsCorrection) {
        throw const FormatException();
      }
      if (value['enabled'] == false) return;
      final String name = value['rule']! as String;
      rule = DirectoryRule.values.firstWhere((r) => r.name == name);
      prefix = value['prefix']! as String;
      if (prefix.length > 32 ||
          prefix.contains('\n') ||
          (rule == DirectoryRule.prefix && prefix.trim().isEmpty)) {
        throw const FormatException();
      }
      _override = previewEntries(
        (value['rows']! as List<Object?>).cast<Json>(),
      );
    } on Object {
      _override = null;
      rule = DirectoryRule.automatic;
      prefix = '';
      error = '已保存的修正目录无法读取或与原文不符，现使用原目录。可重新预览或恢复原目录';
    }
  }

  final BookData book;
  File get _file => File('${book.entry.dir.path}/reader-directory.json');
  List<Chapter>? _override;
  String? error;
  DirectoryRule rule = DirectoryRule.automatic;
  String prefix = '';
  bool get enabled => _override != null;
  List<Chapter> get chapters => _override ?? book.chapters;

  bool get supportsCorrection {
    try {
      final Json? meta =
          readJson(File('${book.entry.dir.path}/meta.json')) as Json?;
      final Object? name = meta?['filename'];
      if (File('${book.entry.dir.path}/source.epub').existsSync()) return false;
      if (name is String && name.isNotEmpty) {
        return name.toLowerCase().endsWith('.txt');
      }
      return File('${book.entry.dir.path}/source.txt').existsSync();
    } on Object {
      return false;
    }
  }

  int chapterAt(int offset) {
    final List<Chapter> entries = chapters;
    int lo = 0;
    int hi = entries.length - 1;
    while (lo < hi) {
      final int mid = (lo + hi + 1) ~/ 2;
      if (entries[mid].o0 <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  List<Chapter> previewEntries(List<Json> rows) {
    if (rows.isEmpty || rows.length > directoryHeadingLimit) {
      throw const FormatException('没有可应用的目录，请换一条规则');
    }
    final Map<int, Chapter> original = <int, Chapter>{
      for (final Chapter chapter in book.chapters) chapter.o0: chapter,
    };
    final List<Chapter> entries = <Chapter>[];
    int previous = -1;
    for (final Json row in rows) {
      final Object? offset = row['offset'];
      final Object? title = row['title'];
      if (offset is! int ||
          title is! String ||
          title.isEmpty ||
          title.length > directoryTitleLimit ||
          offset <= previous ||
          offset < 0 ||
          offset + title.length > book.length) {
        throw const FormatException('目录与原文不符，请重新预览');
      }
      final Block block = book.blocks[book.blockAt(offset)];
      final int relative = offset - block.o;
      if ((block.kind != 'p' && block.kind != 'h') ||
          block.text.length > directoryTitleLimit ||
          block.text.trim() != title ||
          relative != block.text.indexOf(title) ||
          relative < 0 ||
          relative + title.length > block.text.length ||
          block.text.substring(relative, relative + title.length) != title) {
        throw const FormatException('目录与原文不符，请重新预览');
      }
      if (entries.isEmpty && offset > 0) {
        entries.add(
          DirectoryChapter(0, <String, Object?>{
            'title': '开始',
            'o0': 0,
            'o1': offset,
            'depth': 0,
          }, titleEnd: 0),
        );
      }
      final Chapter? canonical = original[offset];
      entries.add(
        DirectoryChapter(
          entries.length,
          <String, Object?>{
            'title': title,
            'o0': offset,
            'o1': book.length,
            'depth': 0,
          },
          titleEnd: offset + title.length,
          source: canonical?.title == title ? canonical : null,
        ),
      );
      previous = offset;
    }
    return List<Chapter>.unmodifiable(entries);
  }

  void apply(DirectoryPreview preview) {
    if (!supportsCorrection) throw const FormatException('仅支持已确认来源为 TXT 的书籍');
    final String savedPrefix = preview.rule == DirectoryRule.prefix
        ? preview.prefix.trim()
        : '';
    if (preview.rule == DirectoryRule.prefix &&
        (savedPrefix.isEmpty ||
            savedPrefix.length > 32 ||
            savedPrefix.contains('\n'))) {
      throw const FormatException('请输入 1–32 字的固定前缀，不支持正则表达式');
    }
    final List<Chapter> next = previewEntries(preview.rows);
    final Json payload = <String, Object?>{
      'version': 1,
      'bookId': book.id,
      'length': book.length,
      'enabled': true,
      'rule': preview.rule.name,
      'prefix': savedPrefix,
      'rows': preview.rows,
    };
    // A short UTF-16 heading can expand sixfold when controls are JSON escaped.
    // Check the exact encoder used by writeJson so every successful apply can
    // be reopened under the same byte limit, without replacing a valid sidecar.
    final int bytes = utf8
        .encode(PyJson.encode(payload, ensureAscii: false, compact: true))
        .length;
    if (bytes > directorySidecarByteLimit) {
      throw const FormatException('目录数据超过 4 MB，请缩小规则范围；当前目录未更改');
    }
    writeJson(_file, payload);
    _override = next;
    rule = preview.rule;
    prefix = savedPrefix;
    error = null;
    notifyListeners();
  }

  void reset() {
    // Atomic replacement also recovers from an unreadable previous sidecar.
    writeJson(_file, <String, Object?>{
      'version': 1,
      'bookId': book.id,
      'length': book.length,
      'enabled': false,
    });
    _override = null;
    error = null;
    rule = DirectoryRule.automatic;
    prefix = '';
    notifyListeners();
  }
}
