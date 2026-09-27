import 'dart:io';

import 'library.dart';

/// When the reader last opened each person card (for 「之后又发生了 3 件事」).
class SeenStore {
  SeenStore._();

  static final SeenStore instance = SeenStore._();
  File? _file;
  Json _data = <String, Object?>{};

  void attach(File file) {
    _file = file;
    _data = (readJson(file) as Json?) ?? <String, Object?>{};
  }

  int? get(String book, String person) =>
      ((_data[book] as Json?)?[person] as num?)?.toInt();

  /// The furthest position the reader has reached in [book].
  int maxRead(String book, int current) {
    final int stored = get(book, '__max') ?? 0;
    if (current > stored) mark(book, '__max', current);
    return current > stored ? current : stored;
  }

  void mark(String book, String person, int cutoff) {
    final Json m = (_data[book] as Json?) ?? <String, Object?>{};
    final int old = (m[person] as num?)?.toInt() ?? 0;
    if (cutoff <= old) return;
    m[person] = cutoff;
    _data[book] = m;
    final File? f = _file;
    if (f != null) writeJson(f, _data);
  }
}
